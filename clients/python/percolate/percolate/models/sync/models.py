"""
Models for file synchronization with external services.
"""

import uuid
import enum
import datetime
from typing import Optional, List, Dict, Any, Union
from pydantic import Field, model_validator
from enum import Enum

from ..AbstractModel import AbstractModel, AbstractEntityModel
from .. import DefaultEmbeddingField, KeyField
from percolate.utils import make_uuid
import percolate as p8


# Define as constants instead of enums for better database compatibility
class SyncStatus:
    """Status of a sync operation"""
    PENDING = "pending"
    SYNCING = "syncing"
    SUCCESS = "success"
    FAILED = "failed"
    CANCELLED = "cancelled"


class SyncFileStatus:
    """Status of a file in the sync process"""
    PENDING = "pending"
    SYNCED = "synced"
    FAILED = "failed"
    DELETED = "deleted"


class SyncProvider(str, Enum):
    """Supported external providers for sync"""
    GOOGLE_DRIVE = "google_drive"
    BOX = "box"
    DROPBOX = "dropbox"
    ONEDRIVE = "onedrive"


class SyncCredential(AbstractEntityModel):
    """
    Secure storage for OAuth2 tokens and related credentials for external services.
    Includes refresh token support for long-term access.
    """
    model_config = {'namespace': 'p8'}
    id: uuid.UUID | str = Field(description="Unique ID for the credential")
    provider: str = Field(description="The provider (e.g., google_drive, box, dropbox)")
    userid: uuid.UUID | str = Field(description="The user ID that owns this credential")
    
    # OAuth tokens
    access_token: str = Field(description="OAuth2 access token")
    refresh_token: Optional[str] = Field(None, description="OAuth2 refresh token for offline access")
    token_expiry: Optional[datetime.datetime] = Field(None, description="Timestamp when the access token expires")
    
    # Additional provider-specific data
    provider_user_id: Optional[str] = Field(None, description="User ID or email in the provider's system")
    provider_metadata: Optional[Dict[str, Any]] = Field(default_factory=dict, description="Additional provider-specific metadata")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'userid': values['userid'], 'provider': values['provider']})
        return values


class SyncConfig(AbstractEntityModel):
    """
    Configuration for synchronizing content from external services.
    Defines what content should be synced, how often, and filtering criteria.
    """
    model_config = {'namespace': 'p8'}
    id: uuid.UUID | str = Field(description="Unique ID for the sync configuration")
    name: str = Field(description="User-friendly name for this sync configuration")
    provider: str = Field(description="The provider (e.g., google_drive, box, dropbox)")
    userid: uuid.UUID | str = Field(description="The user ID that owns this configuration")
    
    # Sync settings
    enabled: bool = Field(True, description="Whether this sync configuration is enabled")
    sync_interval_hours: int = Field(24, description="How often to sync in hours (default: daily)")
    last_sync_at: Optional[datetime.datetime] = Field(None, description="When the last sync operation completed")
    next_sync_at: Optional[datetime.datetime] = Field(None, description="When the next sync should occur")
    
    # Filter criteria
    include_folders: List[str] = Field(default_factory=list, description="List of folder names or IDs to include")
    exclude_folders: List[str] = Field(default_factory=list, description="List of folder names or IDs to exclude")
    include_file_types: List[str] = Field(default_factory=list, description="File types to include (e.g., 'pdf', 'doc')")
    exclude_file_types: List[str] = Field(default_factory=list, description="File types to exclude")
    
    # Provider-specific settings
    provider_config: Dict[str, Any] = Field(default_factory=dict, description="Provider-specific configuration settings")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'userid': values['userid'], 'provider': values['provider'], 'name': values['name']})
        
        # Calculate next_sync_at if not provided
        if not values.get('next_sync_at') and values.get('last_sync_at'):
            hours = values.get('sync_interval_hours', 24)
            last_sync = values.get('last_sync_at')
            values['next_sync_at'] = last_sync + datetime.timedelta(hours=hours)
            
        return values


class SyncFile(AbstractModel):
    """
    Represents a file that is being tracked for synchronization.
    Maintains metadata about the remote file and its local copy.
    """
    model_config = {"arbitrary_types_allowed": True, 'namespace': 'p8'}
     
    id: uuid.UUID | str = Field(description="Unique ID for the synced file record")
    config_id: uuid.UUID | str = Field(description="The sync configuration this file belongs to")
    userid: uuid.UUID | str = Field(description="The user ID that owns this file")
    
    # Remote file info
    remote_id: str = Field(description="File ID in the remote system")
    remote_path: str = Field(description="Full path in the remote system")
    remote_name: str = Field(description="Filename in the remote system")
    remote_type: str = Field(description="MIME type or file extension")
    remote_size: Optional[int] = Field(None, description="File size in bytes")
    remote_modified_at: Optional[datetime.datetime] = Field(None, description="Last modified timestamp in the remote system")
    remote_created_at: Optional[datetime.datetime] = Field(None, description="Created timestamp in the remote system")
    remote_metadata: dict = Field(default_factory=dict, description="Additional metadata from the remote system")
    
    # Local file info
    s3_uri: Optional[str] = Field(None, description="S3 URI where the file is stored locally")
    local_size: Optional[int] = Field(None, description="Size of the local copy in bytes")
    local_modified_at: Optional[datetime.datetime] = Field(None, description="When the local copy was last modified")
    local_checksum: Optional[str] = Field(None, description="Checksum of the local file")
    
    # Sync status - use string instead of enum for database compatibility
    status: str = Field(SyncFileStatus.PENDING, description="Current status of the file sync")
    last_sync_at: Optional[datetime.datetime] = Field(None, description="When this file was last synced")
    sync_attempts: int = Field(0, description="Number of sync attempts for this file")
    error_message: Optional[str] = Field(None, description="Error message if sync failed")
    
    # Ingestion status
    ingested: bool = Field(False, description="Whether this file has been ingested into Percolate")
    resource_id: Optional[uuid.UUID | str] = Field(None, description="Resource ID if the file has been ingested")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({
                'config_id': values['config_id'],
                'remote_id': values['remote_id']
            })
        return values


class SyncLog(AbstractModel):
    """
    Log entry for a synchronization operation.
    Records details about sync runs for auditing and troubleshooting.
    """
    model_config = {"arbitrary_types_allowed": True, "namespace": "p8"}
    
    id: uuid.UUID | str = Field(description="Unique ID for the log entry")
    config_id: uuid.UUID | str = Field(description="The sync configuration that was executed")
    userid: uuid.UUID | str = Field(description="The user ID associated with this sync")
    
    # Execution details
    status: str = Field(SyncStatus.PENDING, description="Status of the sync operation")
    started_at: datetime.datetime = Field(description="When the sync operation started")
    completed_at: Optional[datetime.datetime] = Field(None, description="When the sync operation completed")
    duration_seconds: Optional[int] = Field(None, description="Duration of the sync operation in seconds")
    
    # Results
    files_total: int = Field(0, description="Total number of files found in the remote source")
    files_synced: int = Field(0, description="Number of files successfully synced")
    files_failed: int = Field(0, description="Number of files that failed to sync")
    files_unchanged: int = Field(0, description="Number of files that didn't need sync (unchanged)")
    bytes_synced: int = Field(0, description="Total bytes synced")
    
    # Details
    error_message: Optional[str] = Field(None, description="Error message if the sync failed")
    detailed_log: Optional[List[Dict[str, Any]]] = Field(default_factory=list, description="Detailed log entries for this sync run")
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = str(uuid.uuid4())
            
        # Calculate duration if both timestamps are present
        if values.get('started_at') and values.get('completed_at'):
            started = values.get('started_at')
            completed = values.get('completed_at')
            if isinstance(started, datetime.datetime) and isinstance(completed, datetime.datetime):
                values['duration_seconds'] = int((completed - started).total_seconds())
                
        return values


class GoogleDriveProvider(AbstractEntityModel):
    """
    Google Drive specific provider information.
    Extends the base provider model with Google-specific fields and methods.
    """
    model_config = {'namespace': 'p8'}
    id: uuid.UUID | str = Field(description="Unique ID for this provider configuration")
    name: str = Field("Google Drive", description="Provider name")
    userid: uuid.UUID | str = Field(description="The user ID that owns this provider configuration")
    
    # Google Drive specific settings
    include_shared_drives: bool = Field(True, description="Whether to include shared drives in sync")
    include_my_drive: bool = Field(True, description="Whether to include My Drive in sync")
    recursive_folder_sync: bool = Field(True, description="Whether to sync folders recursively")
    
    # Scope mapping for Google Drive
    required_scopes: List[str] = Field(
        default_factory=lambda: [
            "https://www.googleapis.com/auth/drive.readonly",
            "https://www.googleapis.com/auth/documents.readonly"
        ],
        description="OAuth scopes required for this provider"
    )
    
    @model_validator(mode='before')
    @classmethod
    def _f(cls, values):
        if not values.get('id'):
            values['id'] = make_uuid({'userid': values['userid'], 'provider': 'google_drive'})
        return values


def register_sync_models(connection_string=None):
    """
    Register all sync models with the Percolate database.
    This function should be called during application startup to ensure 
    all sync-related models are properly registered with the database.
    
    Args:
        connection_string: Optional custom database connection string.
            If provided, will use this connection string instead of the default.
            Example: "postgresql://postgres:password@localhost:15432/percolate"
    
    Returns:
        Dict with registration results
    """
    import os
    import percolate as p8
    
    # Set module-specific configuration to use p8 schema instead of sync schema
    for model_class in [SyncCredential, SyncConfig, SyncFile, SyncLog, GoogleDriveProvider]:
        # Set the namespace to p8 in the model_config
        model_class.model_config = {**model_class.model_config, "namespace": "p8"} if hasattr(model_class, "model_config") else {"namespace": "p8"}
    
    models = [
        SyncCredential,
        SyncConfig,
        SyncFile,
        SyncLog,
        GoogleDriveProvider
    ]
    
    results = {}
    
    # Print connection info
    print("Attempting to register sync models in the p8 schema...")
    
    for model in models:
        model_name = model.__name__
        try:
            # Register using p8.repository pattern
            p8.repository(model).register()
            results[model_name] = "Registered successfully"
        except Exception as e:
            results[model_name] = f"Failed: {str(e)}"
    
    print("\nRegistration results:")
    for model, result in results.items():
        print(f"  {model}: {result}")
    
    return results