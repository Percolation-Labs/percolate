"""
File synchronization service for external providers.

This service manages synchronization of files from external storage providers 
(e.g., Google Drive) to Percolate's S3 storage.
"""

import asyncio
import uuid
import time
import datetime
from typing import Dict, List, Optional, Any, Union, Tuple, TypedDict, NamedTuple
from pathlib import Path
import tempfile
import io
import logging
from pydantic import BaseModel

# Import these at the top level for audio processing
from percolate.models.media.audio import AudioProcessingStatus

import percolate as p8
from percolate.utils import logger
from percolate.models.sync import (
    SyncProvider,
    SyncConfig,
    SyncFile,
    SyncLog,
    SyncStatus,
    SyncFileStatus,
    GoogleDriveProvider
)
from percolate.services.S3Service import S3Service
from percolate.api.routes.integrations.services.GoogleService import DriveService


class SyncResult(NamedTuple):
    """Result of a sync operation"""
    success: bool
    log_id: str
    files_synced: int
    files_failed: int
    message: str


class FileSync:
    """
    Service for synchronizing files from external providers to S3.
    Maintains tracking information in the database and handles special file types.
    
    Features:
    - Syncs files from external providers (Google Drive, etc.) to S3
    - Tracks sync status and metadata in the database
    - Supports differential sync (only syncs changed files)
    - Ingests content into the Percolate knowledge graph
    - Special handling for audio files (.wav, .mp3) with automatic transcription
    """
    
    def __init__(self, s3_service: S3Service = None):
        """
        Initialize the file sync service.
        
        Args:
            s3_service: Optional S3Service instance. If not provided, one will be created.
        """
        self.s3_service = s3_service or S3Service()
    
    def _get_target_model(self, config: SyncConfig):
        """
        Get the target model for a sync configuration.
        Creates an Abstract model if needed.
        
        Args:
            config: Sync configuration
            
        Returns:
            The target model class (Resources or a dynamically created model)
        """
        from percolate.models.p8.types import Resources
        from percolate.models.AbstractModel import AbstractModel
        from percolate.models.p8.db_types import AccessLevel
        
        # Get target model info from config metadata
        metadata = config.provider_metadata or {}
        target_namespace = metadata.get("target_namespace", "p8")
        target_model_name = metadata.get("target_model_name", "Resources")
        access_level_value = metadata.get("access_level", AccessLevel.PUBLIC.value)
        
        # Convert access level value to enum if needed
        if isinstance(access_level_value, int):
            access_level = AccessLevel(access_level_value)
        else:
            access_level = AccessLevel.PUBLIC
        
        # If using default Resources model, return it directly
        if target_namespace == "p8" and target_model_name == "Resources":
            return Resources
        
        # Create Abstract model that inherits from Resources
        logger.info(f"Creating dynamic model: {target_namespace}.{target_model_name}")
        
        # Create the model dynamically with access_level
        target_model = AbstractModel.create_model(
            name=target_model_name,
            namespace=target_namespace,
            description=f"Synced content from {config.provider.value}",
            fields={},  # No additional fields, inherits from Resources
            access_level=access_level,  # Pass access level directly
            inherit_config=True,  # Inherit config from Resources parent
            __base__=Resources  # Inherit from Resources
        )
        
        return target_model
    
    @staticmethod
    async def store_oauth_credentials(token: dict, user_email: str = None) -> bool:
        """
        Store OAuth credentials for a user to enable file synchronization.
        This method is called during the OAuth callback flow when sync_files=True.
        
        Args:
            token: OAuth token dictionary containing access_token, refresh_token, etc.
            user_email: Email address of the user (used to find or create user record)
            
        Returns:
            bool: True if credentials were successfully stored, False otherwise
        """
        if not token or "refresh_token" not in token:
            logger.warning("Cannot store credentials: Missing refresh token")
            return False
            
        if not user_email:
            user_info = token.get("userinfo", {})
            user_email = user_info.get("email")
            if not user_email:
                logger.warning("Cannot store credentials: Missing user email")
                return False
        
        try:
            import percolate as p8
            from percolate.models.sync import SyncCredential
            from percolate.models.p8.types import User
            import time
            from datetime import datetime
            
            # Look up or create user
            user_repo = p8.repository(User)
            users = user_repo.execute("SELECT * FROM p8.\"User\" WHERE email = %s", data=(user_email,))
            
            if users:
                user_id = users[0]['id']
            else:
                # Create new user if not found
                user_info = token.get("userinfo", {})
                user = User(
                    id=User.id_from_email(user_email),
                    email=user_email, 
                    name=user_info.get("name", user_email)
                )
                user_repo.update_records(user)
                user_id = user.id
            
            # Create or update sync credential
            expires_at = datetime.fromtimestamp(int(time.time()) + token.get("expires_in", 3600))
            user_info = token.get("userinfo", {})
            
            cred = SyncCredential(
                userid=user_id,
                provider="google_drive",
                access_token=token["access_token"],
                refresh_token=token["refresh_token"],
                token_expiry=expires_at,
                provider_user_id=user_email,
                provider_metadata={
                    "name": user_info.get("name"),
                    "picture": user_info.get("picture"),
                    "scopes": token.get("scope", "").split(" ")
                }
            )
            
            p8.repository(SyncCredential).update_records(cred)
            
            logger.info(f"Stored sync credentials for user {user_email}")
            return True
            
        except Exception as e:
            logger.error(f"Error storing sync credentials: {str(e)}")
            return False
    
    async def sync_user_content(self, user_id: str, force: bool = False) -> SyncResult:
        """
        Synchronize content for a specific user, based on their sync configurations.
        
        Args:
            user_id: User ID to sync content for
            force: If True, sync all configurations regardless of next_sync_at
            
        Returns:
            SyncResult with sync statistics
        """
        # Get all sync configurations for this user
        configs = p8.repository(SyncConfig).select(userid=user_id, enabled=True)
        
        if not configs:
            logger.info(f"No sync configurations found for user {user_id}")
            return SyncResult(
                success=True,
                log_id="",
                files_synced=0,
                files_failed=0,
                message="No sync configurations found"
            )
        
        # Convert to model objects if they're dictionaries
        config_models = []
        for config in configs:
            if isinstance(config, dict):
                config_models.append(SyncConfig.model_parse(config))
            else:
                config_models.append(config)
        
        results = []
        for config in config_models:
            # Only sync if it's time to do so
            now = datetime.datetime.now(datetime.timezone.utc)
            
            # If force is True, next_sync_at is not set, or next_sync_at is in the past, perform sync
            should_sync = False
            logger.info(f"Checking if config {config.id} needs syncing: next_sync_at={config.next_sync_at}, now={now}, force={force}")
            
            if force:
                logger.info(f"Config {config.id} being forced to sync regardless of schedule")
                should_sync = True
            elif not config.next_sync_at:
                logger.info(f"Config {config.id} has no next_sync_at, will sync")
                should_sync = True
            elif config.next_sync_at and isinstance(config.next_sync_at, datetime.datetime):
                # Make sure both are timezone aware for comparison
                next_sync = config.next_sync_at
                if next_sync.tzinfo is None:
                    # Make timezone aware if it's not
                    next_sync = next_sync.replace(tzinfo=datetime.timezone.utc)
                should_sync = next_sync <= now
                logger.info(f"Config {config.id} next_sync={next_sync}, should_sync={should_sync}")
            
            if should_sync:
                try:
                    result = await self._sync_config(config)
                    results.append(result)
                    
                    # Only update sync times if successful
                    if result.success:
                        config.last_sync_at = now
                        config.next_sync_at = now + datetime.timedelta(hours=config.sync_interval_hours)
                        p8.repository(SyncConfig).update_records(config)
                        logger.info(f"Updated next sync time for config {config.id} to {config.next_sync_at}")
                    else:
                        # If sync failed, retry in 1 hour
                        retry_time = now + datetime.timedelta(hours=1)
                        config.next_sync_at = retry_time
                        p8.repository(SyncConfig).update_records(config)
                        logger.info(f"Sync failed for config {config.id}, will retry at {retry_time}")
                except Exception as e:
                    logger.error(f"Error in sync_config: {str(e)}")
                    # Still add a default failed result
                    results.append(SyncResult(
                        success=False,
                        log_id="",
                        files_synced=0,
                        files_failed=0,
                        message=f"Error in sync_config: {str(e)}"
                    ))
        
        # Aggregate results
        total_success = all(r.success for r in results)
        total_synced = sum(r.files_synced for r in results)
        total_failed = sum(r.files_failed for r in results)
        
        # Return aggregate results
        if not results:
            return SyncResult(
                success=True,
                log_id="",
                files_synced=0,
                files_failed=0,
                message="No configurations needed syncing at this time"
            )
        else:
            last_log_id = results[-1].log_id
            return SyncResult(
                success=total_success,
                log_id=last_log_id,
                files_synced=total_synced,
                files_failed=total_failed,
                message=f"Synced {total_synced} files, {total_failed} failed"
            )
    
    async def sync_all_due(self, force: bool = False) -> Dict[str, SyncResult]:
        """
        Sync all configurations that are due for sync.
        This is intended to be called by a scheduled task.
        
        Args:
            force: If True, sync all enabled configurations regardless of next_sync_at
            
        Returns:
            Dictionary mapping user IDs to their sync results
        """
        # Find all configs that are due for sync
        now = datetime.datetime.now(datetime.timezone.utc)
        repository = p8.repository(SyncConfig)
        
        # Query for configs that are enabled and due for sync - make sure to handle timezone-aware comparisons
        # First get all enabled configs
        configs = repository.execute(
            "SELECT * FROM p8.\"SyncConfig\" WHERE enabled = TRUE"
        )
        
        # Filter manually for those that are due (or include all if force=True)
        due_configs = []
        for config in configs or []:
            if force:
                # If forcing, include all enabled configs
                due_configs.append(config)
                logger.info(f"Including config {config.get('id')} due to force flag")
            elif not config.get("next_sync_at"):
                # Include configs with no next_sync_at
                due_configs.append(config)
                logger.info(f"Including config {config.get('id')} with no next_sync_at")
            else:
                # Make sure both are timezone aware for comparison
                next_sync = config["next_sync_at"]
                if hasattr(next_sync, "tzinfo") and next_sync.tzinfo is None:
                    # Make timezone aware if it's not
                    next_sync = next_sync.replace(tzinfo=datetime.timezone.utc)
                if next_sync <= now:
                    due_configs.append(config)
                    logger.info(f"Including config {config.get('id')} that is due: {next_sync} <= {now}")
        
        configs = due_configs
        
        if not configs:
            logger.info("No configurations due for sync")
            return {}
        
        # Group by user_id
        user_configs = {}
        for config in configs:
            user_id = str(config["userid"])
            if user_id not in user_configs:
                user_configs[user_id] = []
            user_configs[user_id].append(config)
        
        # Sync for each user
        results = {}
        for user_id, configs in user_configs.items():
            try:
                # Convert to proper SyncConfig objects
                config_objects = [SyncConfig.model_parse(config) for config in configs]
                
                # Sync each config and aggregate results
                user_results = []
                for config in config_objects:
                    try:
                        result = await self._sync_config(config)
                        user_results.append(result)
                        
                        # Only update sync times if successful
                        if result.success:
                            config.last_sync_at = now
                            config.next_sync_at = now + datetime.timedelta(hours=config.sync_interval_hours)
                            repository.update_records(config)
                            logger.info(f"Updated next sync time for config {config.id} to {config.next_sync_at}")
                        else:
                            # If sync failed, retry in 1 hour
                            retry_time = now + datetime.timedelta(hours=1)
                            config.next_sync_at = retry_time
                            repository.update_records(config)
                            logger.info(f"Sync failed for config {config.id}, will retry at {retry_time}")
                    except Exception as e:
                        logger.error(f"Error in sync_config: {str(e)}")
                        # Add a default failed result
                        user_results.append(SyncResult(
                            success=False,
                            log_id="",
                            files_synced=0,
                            files_failed=0,
                            message=f"Error in sync_config: {str(e)}"
                        ))
                        
                        # Set retry for failed sync
                        retry_time = now + datetime.timedelta(hours=1)
                        config.next_sync_at = retry_time
                        repository.update_records(config)
                        logger.error(f"Sync error for config {config.id}, will retry at {retry_time}")
                
                # Aggregate results for this user
                total_success = all(r.success for r in user_results)
                total_synced = sum(r.files_synced for r in user_results)
                total_failed = sum(r.files_failed for r in user_results)
                
                log_id = user_results[-1].log_id if user_results else ""
                
                results[user_id] = SyncResult(
                    success=total_success,
                    log_id=log_id,
                    files_synced=total_synced,
                    files_failed=total_failed,
                    message=f"Synced {total_synced} files, {total_failed} failed"
                )
            
            except Exception as e:
                logger.error(f"Error syncing for user {user_id}: {str(e)}")
                results[user_id] = SyncResult(
                    success=False,
                    log_id="",
                    files_synced=0,
                    files_failed=0,
                    message=f"Error: {str(e)}"
                )
        
        return results
    
    async def _sync_config(self, config: SyncConfig) -> SyncResult:
        """
        Synchronize a specific configuration.
        
        Args:
            config: The sync configuration to process
            
        Returns:
            SyncResult with sync statistics
        """
        # Create a sync log entry
        sync_log = SyncLog(
            id=str(uuid.uuid4()),
            config_id=config.id,
            userid=config.userid,
            status="syncing",  # Use string literal instead of SyncStatus.SYNCING
            started_at=datetime.datetime.now(datetime.timezone.utc)
        )
        log_repo = p8.repository(SyncLog)
        log_repo.update_records(sync_log)
        
        try:
            # Dispatch to provider-specific sync method
            if config.provider == SyncProvider.GOOGLE_DRIVE:
                result = await self._sync_google_drive(config, sync_log)
            else:
                raise ValueError(f"Unsupported provider: {config.provider}")
            
            # Update the log with success status
            sync_log.status = "success"  # Use string literal instead of SyncStatus.SUCCESS
            sync_log.completed_at = datetime.datetime.now(datetime.timezone.utc)
            sync_log.files_synced = result.files_synced
            sync_log.files_failed = result.files_failed
            log_repo.update_records(sync_log)
            
            return result
            
        except Exception as e:
            logger.error(f"Error during sync: {str(e)}")
            
            # Update the log with failure status
            sync_log.status = "failed"  # Use string literal instead of SyncStatus.FAILED
            sync_log.completed_at = datetime.datetime.now(datetime.timezone.utc)
            sync_log.error_message = str(e)
            log_repo.update_records(sync_log)
            
            return SyncResult(
                success=False,
                log_id=str(sync_log.id),
                files_synced=0,
                files_failed=0,
                message=f"Error: {str(e)}"
            )
    
    async def _sync_google_drive(self, config: SyncConfig, sync_log: SyncLog) -> SyncResult:
        """
        Synchronize files from Google Drive.
        
        Args:
            config: Sync configuration
            sync_log: Log entry to update
            
        Returns:
            SyncResult with sync statistics
        """
        # Get provider-specific configuration
        provider_config_data = p8.repository(GoogleDriveProvider).select(userid=config.userid)
        
        # Use default settings if no provider config exists
        if not provider_config_data:
            provider_config = GoogleDriveProvider(
                userid=config.userid
            )
            p8.repository(GoogleDriveProvider).update_records(provider_config)
        else:
            # Convert to model if it's a dictionary
            provider_data = provider_config_data[0]
            if isinstance(provider_data, dict):
                provider_config = GoogleDriveProvider.model_parse(provider_data)
            else:
                provider_config = provider_data
        
        # Get Google Drive service
        drive_service = await DriveService.from_user_id(config.userid)
        
        # Sync my Drive if configured
        files_synced = 0
        files_failed = 0
        detailed_log = []
        
        # Check if we have a specific folder_id in the config metadata
        folder_id = config.provider_metadata.get("folder_id") if config.provider_metadata else None
        
        if folder_id:
            # Sync specific folder from metadata
            folder_result = await self._sync_google_drive_folder(
                drive_service, 
                config,
                folder_id,
                include_folders=config.include_folders,
                exclude_folders=config.exclude_folders,
                include_file_types=config.include_file_types,
                exclude_file_types=config.exclude_file_types
            )
            
            files_synced += folder_result["synced"]
            files_failed += folder_result["failed"]
            detailed_log.extend(folder_result["logs"])
        elif provider_config.include_my_drive:
            # Fallback to default behavior if no specific folder
            my_drive_result = await self._sync_google_drive_folder(
                drive_service, 
                config,
                "root",  # Root folder ID
                include_folders=config.include_folders,
                exclude_folders=config.exclude_folders,
                include_file_types=config.include_file_types,
                exclude_file_types=config.exclude_file_types
            )
            
            files_synced += my_drive_result["synced"]
            files_failed += my_drive_result["failed"]
            detailed_log.extend(my_drive_result["logs"])
        
        # Sync shared drives if configured
        if provider_config.include_shared_drives:
            # List shared drives
            shared_drives = await drive_service.list_shared_drives()
            
            for drive in shared_drives:
                drive_result = await self._sync_google_drive_folder(
                    drive_service,
                    config,
                    drive["id"],  # Shared drive ID
                    include_folders=config.include_folders,
                    exclude_folders=config.exclude_folders,
                    include_file_types=config.include_file_types,
                    exclude_file_types=config.exclude_file_types,
                    is_shared_drive=True
                )
                
                files_synced += drive_result["synced"]
                files_failed += drive_result["failed"]
                detailed_log.extend(drive_result["logs"])
        
        # Update sync log with detailed results
        sync_log.files_total = files_synced + files_failed
        sync_log.files_synced = files_synced
        sync_log.files_failed = files_failed
        sync_log.detailed_log = detailed_log
        
        return SyncResult(
            success=files_failed == 0,
            log_id=str(sync_log.id),
            files_synced=files_synced,
            files_failed=files_failed,
            message=f"Synced {files_synced} files, {files_failed} failed"
        )
    
    async def _sync_google_drive_folder(
        self,
        drive_service: DriveService,
        config: SyncConfig,
        folder_id: str,
        include_folders: List[str] = None,
        exclude_folders: List[str] = None,
        include_file_types: List[str] = None,
        exclude_file_types: List[str] = None,
        is_shared_drive: bool = False
    ) -> Dict[str, Any]:
        """
        Sync files from a specific Google Drive folder.
        
        Args:
            drive_service: Google Drive service instance
            config: Sync configuration
            folder_id: Folder ID to sync
            include_folders: List of folder names to include
            exclude_folders: List of folder names to exclude
            include_file_types: List of file extensions to include
            exclude_file_types: List of file extensions to exclude
            is_shared_drive: Whether this is a shared drive
            
        Returns:
            Dictionary with sync statistics and logs
        """
        # List files in the folder
        files = await drive_service.list_files(
            folder_id=folder_id,
            recursive=True,  # Always recursive for now
            file_fields="id, name, mimeType, parents, createdTime, modifiedTime, size, md5Checksum, webViewLink"
        )
        
        # Apply filters
        filtered_files = self._filter_files(
            files,
            include_folders=include_folders,
            exclude_folders=exclude_folders,
            include_file_types=include_file_types,
            exclude_file_types=exclude_file_types
        )
        
        # Get existing sync records for this config
        sync_file_repo = p8.repository(SyncFile)
        existing_files = sync_file_repo.select(config_id=config.id)
        
        # Create a map of remote_id -> SyncFile for quick lookups
        # Handle both dict and object returns from select()
        existing_file_map = {}
        for f in existing_files:
            if isinstance(f, dict):
                if 'remote_id' in f and f['remote_id']:
                    existing_file_map[f['remote_id']] = f
            else:
                if hasattr(f, 'remote_id') and f.remote_id:
                    existing_file_map[f.remote_id] = f
        
        # Pre-filter files to skip those that are already synced and up-to-date
        files_to_process = []
        skipped_count = 0
        
        for file in filtered_files:
            # Skip folders
            if file.get("mimeType") == "application/vnd.google-apps.folder":
                continue
                
            file_id = file.get("id")
            file_name = file.get("name")
            modified_time = datetime.datetime.fromisoformat(
                file.get("modifiedTime").replace("Z", "+00:00")
            ) if "modifiedTime" in file else None
            
            existing_file = existing_file_map.get(file_id)
            
            # Skip if file is already synced and hasn't been modified
            if existing_file:
                # Handle both dict and object types
                status = existing_file.get('status') if isinstance(existing_file, dict) else existing_file.status
                remote_modified = existing_file.get('remote_modified_at') if isinstance(existing_file, dict) else existing_file.remote_modified_at
                
                if status == "synced":
                    if not modified_time or not remote_modified:
                        # Can't compare times, include the file to be safe
                        files_to_process.append(file)
                    else:
                        # Make sure both datetimes are timezone-aware for comparison
                        if remote_modified.tzinfo is None:
                            remote_modified = remote_modified.replace(tzinfo=datetime.timezone.utc)
                        if modified_time.tzinfo is None:
                            modified_time = modified_time.replace(tzinfo=datetime.timezone.utc)
                            
                        if modified_time <= remote_modified:
                            # File hasn't been modified since last sync
                            logger.debug(f"Skipping already synced file: {file_name}")
                            skipped_count += 1
                            continue
                        else:
                            # File has been modified, need to re-sync
                            files_to_process.append(file)
                else:
                    # Not synced yet, process it
                    files_to_process.append(file)
            else:
                # New file, process it
                files_to_process.append(file)
        
        logger.info(f"Processing {len(files_to_process)} files, skipped {skipped_count} already synced files")
        filtered_files = files_to_process
        
        # Process each file
        synced = 0
        failed = 0
        logs = []
        
        for file in filtered_files:
            try:
                # Skip folders - we only sync files
                if file.get("mimeType") == "application/vnd.google-apps.folder":
                    continue
                
                file_id = file.get("id")
                file_name = file.get("name")
                file_type = file.get("mimeType")
                modified_time = datetime.datetime.fromisoformat(
                    file.get("modifiedTime").replace("Z", "+00:00")
                ) if "modifiedTime" in file else None
                
                # Check if we already have this file
                # Always create a SyncFile object - it will have deterministic ID
                sync_file = SyncFile(
                    config_id=config.id,
                    userid=config.userid,
                    remote_id=file_id,
                    remote_path=self._get_file_path(file),
                    remote_name=file_name,
                    remote_type=file_type,
                    remote_size=file.get("size"),
                    remote_modified_at=modified_time,
                    remote_created_at=datetime.datetime.fromisoformat(
                        file.get("createdTime").replace("Z", "+00:00")
                    ) if "createdTime" in file else None,
                    remote_metadata={
                        "webViewLink": file.get("webViewLink"),
                        "md5Checksum": file.get("md5Checksum")
                    },
                    status="pending"  # Default status for new files
                )
                
                # Check if we need to sync this file
                existing_file = existing_file_map.get(file_id)
                should_sync = False
                
                if not existing_file:
                    # New file, always sync
                    should_sync = True
                    logger.info(f"New file detected: {file_name}")
                else:
                    # Handle both dict and object types
                    status = existing_file.get('status') if isinstance(existing_file, dict) else existing_file.status
                    remote_modified = existing_file.get('remote_modified_at') if isinstance(existing_file, dict) else existing_file.remote_modified_at
                    
                    if status != "synced":
                        # File exists but not successfully synced
                        should_sync = True
                        logger.info(f"Re-syncing incomplete file: {file_name} (status: {status})")
                    elif modified_time and remote_modified:
                        # Make sure both datetimes are timezone-aware for comparison
                        if remote_modified.tzinfo is None:
                            remote_modified = remote_modified.replace(tzinfo=datetime.timezone.utc)
                        if modified_time.tzinfo is None:
                            modified_time = modified_time.replace(tzinfo=datetime.timezone.utc)
                            
                        if modified_time > remote_modified:
                            # File has been modified since last sync
                            should_sync = True
                            logger.info(f"File modified since last sync: {file_name}")
                        else:
                            # File is up to date
                            logger.debug(f"File already synced and up to date: {file_name}")
                    else:
                        # File is up to date
                        logger.debug(f"File already synced and up to date: {file_name}")
                
                if should_sync:
                    # Update sync_file with existing data if available
                    if existing_file:
                        if isinstance(existing_file, dict):
                            sync_file.status = existing_file.get('status', 'pending')
                            sync_file.s3_uri = existing_file.get('s3_uri')
                            sync_file.ingested = existing_file.get('ingested', False)
                            sync_file.resource_id = existing_file.get('resource_id')
                            sync_file.last_sync_at = existing_file.get('last_sync_at')
                            sync_file.sync_attempts = existing_file.get('sync_attempts', 0)
                            sync_file.error_message = existing_file.get('error_message')
                        else:
                            sync_file.status = existing_file.status
                            sync_file.s3_uri = existing_file.s3_uri
                            sync_file.ingested = existing_file.ingested
                            sync_file.resource_id = existing_file.resource_id
                            sync_file.last_sync_at = existing_file.last_sync_at
                            sync_file.sync_attempts = existing_file.sync_attempts
                            sync_file.error_message = existing_file.error_message
                    
                    sync_result = await self._sync_google_drive_file(
                        drive_service,
                        config,
                        file,
                        sync_file
                    )
                    
                    if sync_result["success"]:
                        synced += 1
                    else:
                        failed += 1
                    
                    logs.append(sync_result["log"])
            
            except Exception as e:
                logger.error(f"Error processing file {file.get('name')}: {str(e)}")
                failed += 1
                logs.append({
                    "file_id": file.get("id"),
                    "file_name": file.get("name"),
                    "status": "error",
                    "message": str(e)
                })
        
        return {
            "synced": synced,
            "failed": failed,
            "logs": logs
        }
    
    async def _sync_google_drive_file(
        self,
        drive_service: DriveService,
        config: SyncConfig,
        file_info: Dict[str, Any],
        sync_file: SyncFile
    ) -> Dict[str, Any]:
        """
        Sync a single Google Drive file.
        
        Args:
            drive_service: Google Drive service
            config: Sync configuration
            file_info: File metadata from Google Drive
            sync_file: Sync file record
            
        Returns:
            Dictionary with sync result and log entry
        """
        file_id = file_info.get("id")
        file_name = file_info.get("name")
        mime_type = file_info.get("mimeType")
        
        try:
            # Update sync file record
            sync_file.status = "syncing" # Use string literal instead of SyncFileStatus.SYNCING
            sync_file.last_sync_at = datetime.datetime.now(datetime.timezone.utc)
            sync_file.sync_attempts += 1
            p8.repository(SyncFile).update_records(sync_file)
            
            # Determine appropriate export format for Google workspace files
            export_format = None
            if mime_type.startswith("application/vnd.google-apps"):
                if mime_type == "application/vnd.google-apps.document":
                    export_format = "application/pdf"
                elif mime_type == "application/vnd.google-apps.spreadsheet":
                    export_format = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                elif mime_type == "application/vnd.google-apps.presentation":
                    export_format = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            
            # Download file content
            logger.debug(f"Downloading {file_name} (ID: {file_id}, Type: {mime_type}, Export: {export_format})")
            try:
                content, content_type = await drive_service.get_file_content(file_id, export_format)
                logger.debug(f"Downloaded {file_name}: {len(content)} bytes, content_type={content_type}")
            except Exception as download_error:
                error_type = type(download_error).__name__
                error_msg = str(download_error) if str(download_error) else f"{error_type} (no message)"
                logger.error(f"Failed to download {file_name}: {error_type}: {error_msg}")
                raise
            
            # Generate S3 path
            s3_path = f"file_sync/{config.userid}/{file_id}"
            if export_format:
                # Add appropriate extension for exported files
                if export_format == "application/pdf":
                    s3_path += ".pdf"
                elif export_format == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
                    s3_path += ".xlsx"
                elif export_format == "application/vnd.openxmlformats-officedocument.presentationml.presentation":
                    s3_path += ".pptx"
            
            # Upload to S3
            try:
                # Build the S3 URI
                s3_uri = f"s3://{self.s3_service.default_bucket}/percolate/{s3_path}"
                
                logger.debug(f"Uploading {file_name} to S3: {s3_uri} ({len(content)} bytes)")
                
                # Use direct bytes upload since we have the content in memory
                s3_result = self.s3_service.upload_filebytes_to_uri(
                    s3_uri=s3_uri,
                    file_content=content,
                    content_type=content_type
                )
                
                logger.debug(f"Successfully uploaded {file_name} to S3: {s3_result.get('uri')}")
            except Exception as e:
                error_type = type(e).__name__
                error_msg = str(e) if str(e) else f"{error_type} (no message)"
                logger.error(f"Error uploading {file_name} to S3: {error_type}: {error_msg}")
                # Log traceback for S3 errors
                import traceback
                logger.debug(f"S3 upload error traceback:\n{traceback.format_exc()}")
                raise
            
            # Update sync file record with success
            sync_file.status = "synced" # Use string literal instead of SyncFileStatus.SYNCED
            sync_file.s3_uri = s3_result.get("uri")
            sync_file.local_size = len(content)
            sync_file.local_modified_at = datetime.datetime.now(datetime.timezone.utc)
            sync_file.error_message = None
            
            # If not already ingested, trigger ingestion
            if not sync_file.ingested:
                # Get the target model for this sync configuration
                target_model = self._get_target_model(config)
                
                # Handle different content types
                if content_type.startswith("text/"):
                    # For text content, pass directly
                    text_content = content.decode("utf-8")
                    
                    # Use the target model's chunked_resource_from_text if available
                    if hasattr(target_model, 'chunked_resource_from_text'):
                        resources = target_model.chunked_resource_from_text(
                            text=text_content,
                            uri=sync_file.s3_uri,
                            name=file_name,
                            userid=config.userid
                        )
                    else:
                        # Fallback to creating instances directly
                        from percolate.models.p8.types import Resources
                        resources = Resources.chunked_resource_from_text(
                            text=text_content,
                            uri=sync_file.s3_uri,
                            name=file_name,
                            userid=config.userid
                        )
                    
                    # Update resources (using smart upsert) with the target model's repository
                    for resource in resources:
                        p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resources[0].id if resources else None
                    logger.info(f"Created {len(resources)} {target_model.get_model_full_name()} resources for {file_name}")
                
                # Handle PDF files - create resource
                elif content_type == "application/pdf" or file_name.lower().endswith(".pdf"):
                    # Create a resource for the PDF file
                    logger.info(f"Processing PDF file: {file_name}")
                    resource_id = str(uuid.uuid4())
                    
                    # For PDFs, we create a placeholder resource for now
                    # In a real implementation, we'd extract text from PDF
                    resource = target_model(
                        id=resource_id,
                        name=file_name,
                        category="document",
                        content=f"PDF Document: {file_name}",  # Placeholder content
                        uri=sync_file.s3_uri,
                        metadata={
                            "content_type": content_type,
                            "file_size": len(content),
                            "source": "file_sync"
                        },
                        userid=config.userid
                    )
                    
                    p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resource_id
                    logger.info(f"Created {target_model.get_model_full_name()} resource for PDF file: {file_name} with ID {resource_id}")
                
                # Handle Office documents (DOCX, XLSX, PPTX)
                elif file_name.lower().endswith((".docx", ".xlsx", ".pptx")) or content_type in [
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                ]:
                    logger.info(f"Processing Office document: {file_name}")
                    resource_id = str(uuid.uuid4())
                    
                    # Create a resource for the document
                    resource = target_model(
                        id=resource_id,
                        name=file_name,
                        category="document",
                        content=f"Document: {file_name}",  # Placeholder content
                        uri=sync_file.s3_uri,
                        metadata={
                            "content_type": content_type,
                            "file_size": len(content),
                            "source": "file_sync"
                        },
                        userid=config.userid
                    )
                    
                    p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resource_id
                    logger.info(f"Created {target_model.get_model_full_name()} resource for Office document: {file_name} with ID {resource_id}")
                
                # Handle audio files (.wav, .mp3) - trigger transcription
                elif content_type in ["audio/wav", "audio/x-wav", "audio/mp3", "audio/mpeg"] or \
                     file_name.lower().endswith((".wav", ".mp3")):
                    
                    # Create an AudioFile entry for transcription
                    from percolate.models.media.audio import AudioFile
                    # AudioProcessingStatus already imported at the top
                    
                    # Create a unique ID for the audio file
                    audio_file_id = str(uuid.uuid4())
                    
                    # Create the AudioFile record
                    audio_file = AudioFile(
                        id=audio_file_id,
                        userid=config.userid,  # Using consistent field naming convention
                        project_name="percolate",
                        filename=file_name,
                        file_size=len(content),
                        content_type=content_type,
                        status=AudioProcessingStatus.UPLOADED,
                        s3_uri=s3_result.get("uri")
                    )
                    
                    # Save the AudioFile record
                    p8.repository(AudioFile).update_records(audio_file)
                    
                    # Trigger async audio processing
                    try:
                        from percolate.services.media.audio.processor import AudioProcessor
                        
                        # Schedule audio processing using a background task
                        # Define a separate function to handle processing
                        async def process_audio_file(file_id, userid):
                            try:
                                processor = AudioProcessor(use_s3=True)
                                await processor.process_file(file_id, userid)
                                logger.info(f"Completed audio processing for file ID {file_id}")
                            except Exception as process_error:
                                logger.error(f"Error in audio processing task: {str(process_error)}")
                        
                        # Schedule the task to run in background
                        # Convert userid to string to ensure it's compatible
                        userid_str = str(config.userid) if config.userid else None
                        
                        # Need to be careful with asyncio.create_task - it needs a proper event loop
                        # Wrap in try/except to handle potential event loop issues
                        try:
                            asyncio.create_task(process_audio_file(audio_file_id, userid_str))
                        except RuntimeError as loop_error:
                            # If we're not in an event loop, log and note that audio will need manual processing
                            logger.warning(f"Could not create async task: {str(loop_error)}. Audio will need manual processing.")
                            # Store the error but don't fail the sync
                            if not sync_file.remote_metadata:
                                sync_file.remote_metadata = {}
                            sync_file.remote_metadata["audio_processing_pending"] = True
                            sync_file.remote_metadata["audio_processing_note"] = "Async task creation failed - will need manual processing"
                        
                        # Mark as ingested since it's being handled by the audio pipeline
                        sync_file.ingested = True
                        sync_file.resource_id = audio_file_id
                        
                        # Add metadata about the audio processing
                        if not sync_file.remote_metadata:
                            sync_file.remote_metadata = {}
                        sync_file.remote_metadata["audio_processing"] = {
                            "audio_file_id": audio_file_id,
                            "status": "processing",
                            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()
                        }
                        
                        logger.info(f"Audio file {file_name} sent for transcription with ID {audio_file_id}")
                    except Exception as e:
                        error_type = type(e).__name__
                        error_msg = str(e) if str(e) else f"{error_type} (no message)"
                        logger.error(f"Error scheduling audio transcription for {file_name}: {error_type}: {error_msg}")
                        
                        # Log traceback for debugging
                        import traceback
                        logger.debug(f"Audio processing error traceback:\n{traceback.format_exc()}")
                        
                        # Don't mark as ingested if there was an error
                        sync_file.ingested = False
                        if not sync_file.remote_metadata:
                            sync_file.remote_metadata = {}
                        sync_file.remote_metadata["audio_processing_error"] = f"{error_type}: {error_msg}"
            
            # Update sync file
            p8.repository(SyncFile).update_records(sync_file)
            
            return {
                "success": True,
                "log": {
                    "file_id": file_id,
                    "file_name": file_name,
                    "status": "synced",
                    "s3_uri": sync_file.s3_uri,
                    "size": sync_file.local_size
                }
            }
        
        except Exception as e:
            # Get more detailed error information
            error_type = type(e).__name__
            error_msg = str(e) if str(e) else f"{error_type} (no message)"
            
            # Log with more detail including traceback
            logger.error(f"Error syncing file {file_name}: {error_type}: {error_msg}")
            
            # Log the full traceback for debugging
            import traceback
            logger.debug(f"Full traceback for {file_name}:\n{traceback.format_exc()}")
            
            # Update sync file record with failure
            sync_file.status = "failed" # Use string literal instead of SyncFileStatus.FAILED
            sync_file.error_message = f"{error_type}: {error_msg}"
            p8.repository(SyncFile).update_records(sync_file)
            
            return {
                "success": False,
                "log": {
                    "file_id": file_id,
                    "file_name": file_name,
                    "status": "failed",
                    "message": str(e)
                }
            }
    
    def _filter_files(
        self,
        files: List[Dict[str, Any]],
        include_folders: List[str] = None,
        exclude_folders: List[str] = None,
        include_file_types: List[str] = None,
        exclude_file_types: List[str] = None
    ) -> List[Dict[str, Any]]:
        """
        Filter files based on configuration criteria.
        
        Args:
            files: List of file objects from Google Drive
            include_folders: List of folder names to include
            exclude_folders: List of folder names to exclude
            include_file_types: List of file extensions to include
            exclude_file_types: List of file extensions to exclude
            
        Returns:
            Filtered list of files
        """
        # Convert filter lists to lowercase for case-insensitive comparison
        include_folders = [f.lower() for f in (include_folders or [])]
        exclude_folders = [f.lower() for f in (exclude_folders or [])]
        include_file_types = [t.lower() for t in (include_file_types or [])]
        exclude_file_types = [t.lower() for t in (exclude_file_types or [])]
        
        filtered = []
        for file in files:
            file_name = file.get("name", "")
            file_path = self._get_file_path(file)
            
            # Check folder filters
            if include_folders and not any(folder.lower() in file_path.lower() for folder in include_folders):
                continue
            
            if exclude_folders and any(folder.lower() in file_path.lower() for folder in exclude_folders):
                continue
            
            # Check file type filters
            file_ext = Path(file_name).suffix.lower().lstrip(".")
            
            if include_file_types and file_ext and file_ext not in include_file_types:
                continue
            
            if exclude_file_types and file_ext and file_ext in exclude_file_types:
                continue
            
            filtered.append(file)
        
        return filtered
    
    def _get_file_path(self, file: Dict[str, Any]) -> str:
        """
        Get a string representation of the file path.
        This is simplified for now - in a real implementation we would
        recursively build the full path.
        
        Args:
            file: File metadata from Google Drive
            
        Returns:
            A string representation of the file path
        """
        # For simplicity, just return the file name for now
        # In a real implementation, we would build the full path
        return file.get("name", "")
        
    async def flush_non_ingested_files(self, user_id: str = None) -> Dict[str, Any]:
        """
        Flush all non-ingested files to resources.
        This finds all files that have been synced to S3 but not yet ingested as resources
        and processes them to create appropriate resource objects.
        
        Args:
            user_id: Optional user ID to limit flushing to a specific user's files
            
        Returns:
            Dictionary with flush statistics
        """
        from percolate.models.p8.types import Resources
        
        # Query SyncFile records that are synced but not ingested
        query_conditions = {"status": "synced", "ingested": False}
        if user_id:
            query_conditions["userid"] = user_id
            
        sync_files = p8.repository(SyncFile).select(**query_conditions)
        
        if not sync_files:
            logger.info(f"No non-ingested files found for {'user ' + user_id if user_id else 'any user'}")
            return {
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "files_processed": 0,
                "files_successful": 0,
                "files_failed": 0
            }
            
        logger.info(f"Flushing {len(sync_files)} non-ingested files to resources")
        
        # Process each file
        successful = 0
        failed = 0
        processed = 0
        
        for sync_file in sync_files:
            try:
                # Convert to model if it's a dictionary
                if isinstance(sync_file, dict):
                    sync_file = SyncFile.model_parse(sync_file)
                    
                # Get the file's S3 URI
                s3_uri = sync_file.s3_uri
                if not s3_uri:
                    logger.warning(f"Skipping file {sync_file.id} - no S3 URI found")
                    continue
                    
                # Determine file type based on name or content type
                file_name = sync_file.remote_name
                content_type = sync_file.remote_type
                
                # Get file content from S3
                try:
                    content = self.s3_service.download_file_from_uri(s3_uri)
                    if not content or not content.get("content"):
                        logger.warning(f"Skipping file {sync_file.id} - failed to download content")
                        continue
                    
                    file_content = content.get("content")
                except Exception as e:
                    logger.error(f"Error downloading file {sync_file.id} from S3: {str(e)}")
                    continue
                
                # Process based on content type
                processed += 1
                
                # Look up the sync config to get user ID
                config = None
                if sync_file.config_id:
                    configs = p8.repository(SyncConfig).select(id=sync_file.config_id)
                    if configs:
                        config = SyncConfig.model_parse(configs[0]) if isinstance(configs[0], dict) else configs[0]
                
                # Get the user ID from sync_file or config
                userid = sync_file.userid or (config.userid if config else None)
                
                # Get the target model for this sync configuration
                target_model = self._get_target_model(config) if config else Resources
                
                if content_type.startswith("text/") or file_name.lower().endswith((".txt", ".md", ".html")):
                    # Handle text files
                    text_content = file_content.decode("utf-8")
                    
                    # Use the target model's chunked_resource_from_text if available
                    if hasattr(target_model, 'chunked_resource_from_text'):
                        resources = target_model.chunked_resource_from_text(
                            text=text_content,
                            uri=s3_uri,
                            name=file_name,
                            userid=userid
                        )
                    else:
                        # Fallback to Resources
                        resources = Resources.chunked_resource_from_text(
                            text=text_content,
                            uri=s3_uri,
                            name=file_name,
                            userid=userid
                        )
                    
                    # Update resources with target model repository
                    for resource in resources:
                        p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resources[0].id if resources else None
                    p8.repository(SyncFile).update_records(sync_file)
                    
                    successful += 1
                    logger.info(f"Flushed text file {file_name} to {target_model.get_model_full_name()}")
                    
                elif content_type == "application/pdf" or file_name.lower().endswith(".pdf"):
                    # Handle PDF files
                    resource_id = str(uuid.uuid4())
                    
                    # Create a resource for the PDF
                    resource = target_model(
                        id=resource_id,
                        name=file_name,
                        category="document",
                        content=f"PDF Document: {file_name}",  # Placeholder content
                        uri=s3_uri,
                        metadata={
                            "content_type": content_type,
                            "file_size": len(file_content),
                            "source": "file_sync"
                        },
                        userid=userid
                    )
                    
                    p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resource_id
                    p8.repository(SyncFile).update_records(sync_file)
                    
                    successful += 1
                    logger.info(f"Flushed PDF file {file_name} to {target_model.get_model_full_name()}")
                    
                elif file_name.lower().endswith((".docx", ".xlsx", ".pptx")) or content_type in [
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                ]:
                    # Handle Office documents
                    resource_id = str(uuid.uuid4())
                    
                    # Create a resource for the document
                    resource = target_model(
                        id=resource_id,
                        name=file_name,
                        category="document",
                        content=f"Document: {file_name}",  # Placeholder content
                        uri=s3_uri,
                        metadata={
                            "content_type": content_type,
                            "file_size": len(file_content),
                            "source": "file_sync"
                        },
                        userid=userid
                    )
                    
                    p8.repository(target_model).update_records(resource)
                    
                    # Mark as ingested
                    sync_file.ingested = True
                    sync_file.resource_id = resource_id
                    p8.repository(SyncFile).update_records(sync_file)
                    
                    successful += 1
                    logger.info(f"Flushed document file {file_name} to {target_model.get_model_full_name()}")
                    
                elif content_type in ["audio/wav", "audio/x-wav", "audio/mp3", "audio/mpeg"] or \
                     file_name.lower().endswith((".wav", ".mp3")):
                    # Handle audio files
                    from percolate.models.media.audio import AudioFile, AudioProcessingStatus
                    
                    # Create an AudioFile entry for transcription
                    audio_file_id = str(uuid.uuid4())
                    
                    # Create the AudioFile record
                    audio_file = AudioFile(
                        id=audio_file_id,
                        userid=userid,
                        project_name="percolate",
                        filename=file_name,
                        file_size=len(file_content),
                        content_type=content_type,
                        status=AudioProcessingStatus.UPLOADED,
                        s3_uri=s3_uri
                    )
                    
                    # Save the AudioFile record
                    p8.repository(AudioFile).update_records(audio_file)
                    
                    # Mark as ingested and linked to the audio file
                    sync_file.ingested = True
                    sync_file.resource_id = audio_file_id
                    p8.repository(SyncFile).update_records(sync_file)
                    
                    # Schedule audio processing as a separate task
                    # instead of calling processor directly in this method
                    logger.info(f"Created AudioFile record for {file_name} - will be processed by audio pipeline")
                    successful += 1
                    
                else:
                    # Handle unknown file types
                    logger.warning(f"Skipping file {file_name} - unknown content type {content_type}")
                    failed += 1
                    
            except Exception as e:
                logger.error(f"Error flushing file {getattr(sync_file, 'remote_name', sync_file.id)}: {str(e)}")
                failed += 1
        
        return {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "files_processed": processed,
            "files_successful": successful,
            "files_failed": failed
        }


# Function to run sync as a scheduled task
async def run_scheduled_sync(force: bool = False) -> Dict[str, Any]:
    """
    Run scheduled sync for all configurations that are due.
    This function is intended to be called by a scheduled task.
    
    Args:
        force: If True, sync all enabled configs regardless of next_sync_at
    
    Returns:
        Dictionary with sync results
    """
    sync_service = FileSync()
    results = await sync_service.sync_all_due(force=force)
    
    return {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "users_synced": len(results),
        "force_used": force,
        "results": {
            user_id: {
                "success": result.success,
                "files_synced": result.files_synced,
                "files_failed": result.files_failed,
                "message": result.message
            }
            for user_id, result in results.items()
        }
    }
    
    


if __name__ == "__main__":
    """a test user id such as 'd704307b-5e26-5f36-b30c-cdf1d2b1549d' can be used to test
    be sure to set the env vars for port and password as instructed
    
    Usage:
    python -m percolate.services.sync.file_sync --user=<user_id> [--force] [--flush]
    
    Options:
    --user=<user_id>  : Specify the user ID to sync or flush
    --force           : Force sync regardless of schedule
    --flush           : Flush non-ingested files to resources
    """
    import asyncio
    import logging
    import sys
    
    # Configure logging
    logging.basicConfig(level=logging.INFO)
    
    # Parse any command line arguments
    force = "--force" in sys.argv
    flush = "--flush" in sys.argv
    user_id = 'd704307b-5e26-5f36-b30c-cdf1d2b1549d'  # Default test user
    
    # Use any user ID provided as argument
    for arg in sys.argv:
        if arg.startswith("--user="):
            user_id = arg.split("=", 1)[1]
    
    # Create sync service
    sync_service = FileSync()
    
    # Determine the operation
    if flush:
        # Run the flush operation
        async def run_flush():
            try:
                print(f"Flushing non-ingested files for user {user_id}...")
                result = await asyncio.wait_for(
                    sync_service.flush_non_ingested_files(user_id=user_id),
                    timeout=300  # 5 minute timeout
                )
                print(f"Flush completed: Processed={result['files_processed']}, Successful={result['files_successful']}, Failed={result['files_failed']}")
                return result
            except asyncio.TimeoutError:
                print("Flush operation timed out")
                return None
        
        # Run the flush operation
        result = asyncio.run(run_flush())
        
        # Exit with success/failure code
        if result:
            sys.exit(0 if result["files_failed"] == 0 else 1)
        else:
            sys.exit(1)
            
    else:
        # Run the sync operation
        async def run_sync():
            try:
                # Run with force=True to sync regardless of schedule
                result = await asyncio.wait_for(
                    sync_service.sync_user_content(user_id=user_id, force=force),
                    timeout=300  # 5 minute timeout
                )
                print(f"Sync result: Success={result.success}, Files synced={result.files_synced}, Files failed={result.files_failed}")
                print(f"Message: {result.message}")
                return result
            except asyncio.TimeoutError:
                print("Sync operation timed out")
                return None
        
        # Run the test
        result = asyncio.run(run_sync())
        
        # Exit with success/failure code based on result
        sys.exit(0 if result and result.success else 1)