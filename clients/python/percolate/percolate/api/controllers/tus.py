"""
Tus protocol controller for the Percolate API.
Handles file uploading using the tus.io protocol, a protocol for resumable uploads.
"""

import os
import uuid
import json
import shutil
import tempfile
import asyncio
from typing import Optional, Dict, Any, List, Tuple, Union
from datetime import datetime, timezone, timedelta
from fastapi import HTTPException, Request, Response
from pathlib import Path
import percolate as p8
from percolate.utils import logger, make_uuid
from percolate.services.S3Service import S3Service
from percolate.models.media.tus import (
    TusFileUpload,
    TusFileChunk,
    TusUploadStatus,
    TusUploadMetadata,
    TusUploadPatchResponse,
    TusUploadCreationResponse
)
from .resource_creator import create_resources_from_upload

# Configuration options
DEFAULT_CHUNK_SIZE = 5 * 1024 * 1024  # 5MB
DEFAULT_EXPIRATION_DELTA = timedelta(days=1)  # Uploads expire after 1 day by default

# Determine storage path with fallback mechanism
# Try configured path first, fall back to temp directory if necessary
TUS_STORAGE_PATH = os.environ.get("TUS_STORAGE_PATH")
STORAGE_PATH = None

# Try primary storage path if configured
if TUS_STORAGE_PATH:
    # Check if path exists and is writable
    try:
        if not os.path.exists(TUS_STORAGE_PATH):
            os.makedirs(TUS_STORAGE_PATH, exist_ok=True)
            
        # Test if we can write to the directory
        test_file = os.path.join(TUS_STORAGE_PATH, ".write_test")
        with open(test_file, "w") as f:
            f.write("test")
        os.remove(test_file)
        
        STORAGE_PATH = TUS_STORAGE_PATH
        logger.info(f"Using configured storage for TUS uploads: {STORAGE_PATH}")
    except Exception as e:
        logger.warning(f"Cannot use configured TUS_STORAGE_PATH: {str(e)}")

# Fall back to temp directory if primary path couldn't be used
if not STORAGE_PATH:
    STORAGE_PATH = os.path.join(tempfile.gettempdir(), "tus_uploads")
    logger.warning(f"Using fallback local storage for TUS uploads: {STORAGE_PATH}")
    # Ensure the fallback directory exists
    os.makedirs(STORAGE_PATH, exist_ok=True)

# API path configuration
TUS_API_ROOT_PATH = os.environ.get("TUS_API_PATH", "/tus")  # API base path

# Determine if we should use S3 for storage
# If we're using local temp dir, we should definitely use S3 for persistence
USE_S3 = os.environ.get("TUS_USE_S3", "true").lower() in ('true', '1', 't')
USE_DIRECT_S3 = os.environ.get("TUS_DIRECT_S3", "false").lower() in ('true', '1', 't')
S3_BUCKET = os.environ.get("TUS_S3_BUCKET", "percolate")

# Determine if we should use direct S3 upload based on storage path
# If we're using a temporary or local path, we should use S3 directly
# to ensure files aren't lost when pods are terminated
SHARED_STORAGE = STORAGE_PATH != os.path.join(tempfile.gettempdir(), "tus_uploads")
DIRECT_S3 = USE_DIRECT_S3 or not SHARED_STORAGE

# Log storage configuration
logger.info(f"TUS uploads storage path: {STORAGE_PATH}")
logger.info(f"TUS API path: {TUS_API_ROOT_PATH}")
logger.info(f"Storage type: {'Shared persistent storage' if SHARED_STORAGE else 'Local temporary storage'}")
logger.info(f"S3 upload settings: USE_S3={USE_S3}, DIRECT_S3={DIRECT_S3}, S3_BUCKET={S3_BUCKET}")

# Create storage directory if it doesn't exist
os.makedirs(STORAGE_PATH, exist_ok=True)

async def create_upload(
    request: Request,
    filename: str,
    file_size: int,
    metadata: Dict[str, Any],
    userid: Optional[str] = None,  # Changed from user_id to userid
    project_name: str = "default",
    content_type: Optional[str] = None,
    expires_in: timedelta = DEFAULT_EXPIRATION_DELTA,
    tags: Optional[List[str]] = None
) -> TusUploadCreationResponse:
    """
    Create a new Tus file upload.
    
    Args:
        request: The FastAPI request
        filename: Original filename
        file_size: Total file size in bytes
        metadata: Upload metadata
        user_id: Optional user ID
        project_name: Project name
        content_type: MIME type
        expires_in: How long until this upload expires
        
    Returns:
        TusUploadCreationResponse with upload details
    """
    logger.info(f"Creating Tus upload for file: {filename}, size: {file_size}")
    
    # Validate userid is a proper UUID if provided
    if userid:
        try:
            uuid_obj = uuid.UUID(userid)
            userid = str(uuid_obj)
            logger.info(f"Using user ID: {userid}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid user ID provided: {userid} - will not associate with a user")
            userid = None
    
    # Generate a unique upload ID
    upload_id = make_uuid({
        'filename': filename,
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'seed': str(uuid.uuid4())  # Use a random UUID as seed, don't use userid
    })
    
    # Calculate expiration
    expires_at = datetime.now(timezone.utc) + expires_in
    
    # Create directory for chunks
    upload_path = os.path.join(STORAGE_PATH, str(upload_id))
    os.makedirs(upload_path, exist_ok=True)
    
    # Build the upload URI
    # This should be the absolute path to the upload, including hostname and scheme
    # Check X-Forwarded-Proto header first (when behind a proxy/load balancer)
    forwarded_proto = request.headers.get('X-Forwarded-Proto') or request.headers.get('x-forwarded-proto')
    
    if forwarded_proto:
        scheme = forwarded_proto
    else:
        # Log warning when X-Forwarded-Proto is not set
        logger.warning(f"X-Forwarded-Proto header not set by proxy for host: {request.headers.get('host')}")
        scheme = request.url.scheme
    
    # In production, always force HTTPS for *.percolationlabs.ai domains
    host = request.headers.get('host', request.url.netloc)
    if host.endswith('.percolationlabs.ai') or host == 'percolationlabs.ai':
        scheme = 'https'
        if not forwarded_proto:
            logger.warning(f"Forcing HTTPS for {host} due to missing X-Forwarded-Proto header")
    
    upload_uri = f"{scheme}://{host}{TUS_API_ROOT_PATH}/{upload_id}"
    
    # Handle tags - limit to 3 tags
    file_tags = []
    if tags:
        file_tags = tags[:3]  # Limit to max 3 tags
    elif metadata.get('tags'):
        # Try to get tags from metadata if supplied
        try:
            if isinstance(metadata['tags'], str):
                # Split comma-separated tags
                tag_list = [tag.strip() for tag in metadata['tags'].split(',') if tag.strip()]
                file_tags = tag_list[:3]  # Limit to max 3 tags
            elif isinstance(metadata['tags'], list):
                file_tags = metadata['tags'][:3]  # Limit to max 3 tags
        except Exception as e:
            logger.warning(f"Error processing tags from metadata: {str(e)}")
    
    # Extract userid from metadata if present - but only use if it's a valid UUID
    metadata_user_id = None
    if metadata.get('user_id'):
        try:
            # Validate it's a proper UUID
            metadata_uuid = uuid.UUID(metadata['user_id'])
            metadata_user_id = str(metadata_uuid)
            logger.info(f"Found valid UUID user ID in metadata: {metadata_user_id}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid user ID in metadata: {metadata.get('user_id')} - ignoring")
    
    # Use explicitly provided userid first, then try metadata, but leave as None if no valid UUID
    effective_user_id = userid or metadata_user_id
    if effective_user_id:
        logger.info(f"Setting upload userid to: {effective_user_id}")
    else:
        logger.info("No valid user ID available, leaving userid as null")
    
    # Create the upload record
    upload = TusFileUpload(
        id=upload_id,
        userid=effective_user_id,  # Changed from user_id to userid
        filename=filename,
        content_type=content_type,
        total_size=file_size,
        uploaded_size=0,
        status=TusUploadStatus.INITIATED,
        upload_uri=upload_uri,
        upload_metadata=metadata,
        project_name=project_name,
        created_at=datetime.now(timezone.utc),
        updated_at=datetime.now(timezone.utc),
        expires_at=expires_at,
        tags=file_tags
    )
    
    try:
        logger.info(f"Saving upload record to database: id={upload_id}")
        p8.repository(TusFileUpload).update_records([upload])
        logger.debug("Successfully created upload record")
    except Exception as db_error:
        logger.error(f"Error creating upload record: {str(db_error)}")
        # Cleanup the directory if DB save fails
        if os.path.exists(upload_path):
            shutil.rmtree(upload_path)
        raise HTTPException(status_code=500, detail=f"Database error: {str(db_error)}")
    
    # Return the response
    return TusUploadCreationResponse(
        upload_id=upload_id,
        location=upload_uri,
        expires_at=expires_at
    )

async def get_upload_info(upload_id: Union[str, uuid.UUID]) -> TusFileUpload:
    """
    Get information about a Tus upload.
    
    Args:
        upload_id: The ID of the upload
        
    Returns:
        TusFileUpload object
    """
    logger.info(f"Getting upload info for: {upload_id}")
    
    try:
        # Ensure we have a string ID
        upload_id_str = str(upload_id)
        
        # Get the upload from database
        upload = p8.repository(TusFileUpload).get_by_id(id=upload_id_str, as_model=True)
        
        if not upload:
            logger.warning(f"Upload {upload_id} not found")
            raise HTTPException(status_code=404, detail="Upload not found")
            
        # Log detailed info about the retrieved upload
        logger.info(f"Retrieved upload: ID={upload.id}, Filename={upload.filename}, Status={upload.status}, Size={upload.total_size}, Uploaded={upload.uploaded_size}")
        
        # Log S3 info if available
        if hasattr(upload, 's3_uri') and upload.s3_uri:
            logger.info(f"S3 Storage: URI={upload.s3_uri}, Bucket={upload.s3_bucket}, Key={upload.s3_key}")
        elif upload.upload_metadata.get("s3_uri"):
            # For backward compatibility
            logger.info(f"S3 Storage (from metadata): URI={upload.upload_metadata.get('s3_uri')}")
            
        # Log tags if available
        if hasattr(upload, 'tags') and upload.tags:
            logger.info(f"Upload tags: {upload.tags}")
        
        # Check if upload has expired
        if upload.expires_at:
            # Make sure both datetimes are timezone-aware for comparison
            current_time = datetime.now(timezone.utc)
            expires_at = upload.expires_at
            
            # If expires_at is naive (no timezone), assume it's UTC
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
                
            if expires_at < current_time:
                logger.warning(f"Upload {upload_id} has expired")
                
                # Update status to expired if not already
                if upload.status != TusUploadStatus.EXPIRED:
                    upload.status = TusUploadStatus.EXPIRED
                    p8.repository(TusFileUpload).update_records([upload])
                    
                raise HTTPException(status_code=410, detail="Upload expired")
            
        return upload
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting upload info: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Failed to get upload info: {str(e)}")

async def process_chunk(
    upload_id: Union[str, uuid.UUID],
    chunk_data: bytes,
    content_length: int,
    offset: int,
    background_tasks=None
) -> TusUploadPatchResponse:
    """
    Process a chunk of a Tus upload.
    
    Args:
        upload_id: The ID of the upload
        chunk_data: Binary data for the chunk
        content_length: Length of the chunk data
        offset: Offset where this chunk begins
        background_tasks: Optional FastAPI BackgroundTasks object for async processing
        
    Returns:
        TusUploadPatchResponse with new offset
    """
    logger.info(f"Processing chunk for upload {upload_id}, offset: {offset}, length: {content_length}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        upload_id_str = str(upload.id)
        
        # Verify offset matches expected position
        if upload.uploaded_size != offset:
            logger.warning(f"Conflict: Expected offset {upload.uploaded_size}, got {offset}")
            raise HTTPException(status_code=409, detail=f"Conflict: Expected offset {upload.uploaded_size}")
        
        # Storage path for this upload
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        os.makedirs(upload_dir, exist_ok=True)
        
        # Create a filename for this chunk
        chunk_filename = f"chunk_{offset}_{content_length}"
        chunk_path = os.path.join(upload_dir, chunk_filename)
        
        # Store the chunk
        with open(chunk_path, "wb") as f:
            f.write(chunk_data)
        
        # Create a chunk record
        chunk = TusFileChunk(
            upload_id=upload_id,
            chunk_size=content_length,
            chunk_offset=offset,  # Changed from 'offset' to 'chunk_offset'
            storage_path=chunk_path,
            created_at=datetime.now(timezone.utc)
        )
        
        # Save the chunk record
        p8.repository(TusFileChunk).update_records([chunk])
        
        # Update the upload record
        new_offset = offset + content_length
        upload.uploaded_size = new_offset
        upload.updated_at = datetime.now(timezone.utc)
        
        # If upload is complete, update status
        if new_offset >= upload.total_size:
            upload.status = TusUploadStatus.COMPLETED
            logger.info(f"Upload {upload_id} completed")
            
            # Save the upload record first
            p8.repository(TusFileUpload).update_records([upload])
            
            # Trigger finalization for all completed uploads, regardless of storage type
            try:
                logger.info(f"Triggering finalization for completed upload {upload_id}")
                final_path = await finalize_upload(upload_id, background_tasks=background_tasks)
                logger.info(f"Finalization completed, final path: {final_path}")
                    
            except Exception as e:
                logger.error(f"Error during finalization: {str(e)}")
                # Don't fail the upload, just log the error
                upload.upload_metadata["finalization_error"] = str(e)
                p8.repository(TusFileUpload).update_records([upload])
            
            return TusUploadPatchResponse(
                offset=new_offset,
                upload_id=upload.id,
                expires_at=upload.expires_at
            )
        else:
            # If this is the first chunk, mark as in progress
            if upload.status == TusUploadStatus.INITIATED:
                upload.status = TusUploadStatus.IN_PROGRESS
        
        # Save the upload record
        p8.repository(TusFileUpload).update_records([upload])
        
        # If S3 direct upload is enabled and this is a large file, we could
        # consider uploading chunks to S3 as they arrive, but for now we
        # wait until the file is complete
        
        # Return the new offset
        return TusUploadPatchResponse(
            offset=new_offset,
            upload_id=upload.id,
            expires_at=upload.expires_at
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error processing chunk: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error processing chunk: {str(e)}")

async def upload_to_s3_background(upload_id: str, final_path: str) -> None:
    """
    Background task to upload file to S3.
    
    Args:
        upload_id: The ID of the upload
        final_path: Path to the assembled file
    """
    logger.info(f"Starting background S3 upload for: {upload_id}")
    
    try:
        # Get the upload record
        upload = await get_upload_info(upload_id)
        
        s3_service = S3Service()
        
        # Create key using project and filename
        project = upload.project_name or "default"
        user_prefix = upload.userid  # Keep as null if no user ID
        
        # Create S3 key based on whether we have a user ID or not
        if user_prefix:
            # Use user ID in path structure
            s3_key = f"{project}/uploads/{user_prefix}/{upload_id}/{upload.filename}"
        else:
            # No user ID, use a simplified path without user segment
            s3_key = f"{project}/uploads/unassigned/{upload_id}/{upload.filename}"
        
        # Upload the file to S3 using streaming method
        s3_uri = f"s3://{s3_service.default_bucket}/{s3_key}"
        upload_result = s3_service.upload_file_to_uri(
            s3_uri=s3_uri,
            file_path_or_content=final_path,  # Path string will trigger streaming upload
            content_type=upload.content_type or "application/octet-stream"
        )
        
        # Get the S3 URI from the upload result
        s3_uri = upload_result.get("uri")
        if not s3_uri:
            # Construct URI if not provided by the service
            s3_uri = f"s3://{s3_service.default_bucket}/{s3_key}"
        
        logger.info(f"File uploaded to S3: {s3_uri}")
        
        # Update the upload record with S3 info - using direct fields
        upload.s3_uri = s3_uri
        upload.s3_key = s3_key
        upload.s3_bucket = s3_service.default_bucket
        
        # Also keep in metadata for backward compatibility
        upload.upload_metadata["s3_uri"] = s3_uri
        upload.upload_metadata["s3_key"] = s3_key
        upload.upload_metadata["storage_type"] = "s3"
        
        # Update tags to metadata for S3 search compatibility
        if hasattr(upload, 'tags') and upload.tags:
            upload.upload_metadata["tags"] = upload.tags
            
        # Update status to indicate S3 upload is complete
        upload.upload_metadata["s3_upload_status"] = "completed"
        
        # Save the upload record
        p8.repository(TusFileUpload).update_records([upload])
        
        logger.info(f"S3 upload completed: ID={upload.id}, URI={upload.s3_uri}")
        
        # Create resources from the uploaded file
        try:
            logger.info(f"Creating resources for upload: {upload_id}")
            # Explicitly set save_resources=True to ensure resources are saved
            resources = await create_resources_from_upload(upload_id, save_resources=True)
            logger.info(f"Created {len(resources)} resources for upload: {upload_id}")
            
            # Double-check that resources were created and upload was updated
            if resources:
                # Verify upload has resource_id
                updated_upload = p8.repository(TusFileUpload).get_by_id(upload_id, as_model=True)
                if not (hasattr(updated_upload, 'resource_id') and updated_upload.resource_id):
                    logger.warning(f"Upload {upload_id} doesn't have resource_id after resource creation")
                    # Set it explicitly if needed
                    updated_upload.resource_id = str(resources[0].id)
                    p8.repository(TusFileUpload).update_records([updated_upload])
                    logger.info(f"Explicitly set resource_id={updated_upload.resource_id} for upload {upload_id}")
        except Exception as resource_error:
            logger.error(f"Error creating resources: {str(resource_error)}")
            # Don't fail the S3 upload, just log the error
            upload.upload_metadata["resource_creation_error"] = str(resource_error)
            p8.repository(TusFileUpload).update_records([upload])
        
    except Exception as e:
        logger.error(f"Error uploading to S3: {str(e)}", exc_info=True)
        try:
            # Update the upload record to indicate S3 upload failed
            upload = await get_upload_info(upload_id)
            upload.upload_metadata["storage_type"] = "local"
            upload.upload_metadata["local_path"] = final_path
            upload.upload_metadata["s3_upload_status"] = "failed"
            upload.upload_metadata["s3_upload_error"] = str(e)
            p8.repository(TusFileUpload).update_records([upload])
        except Exception as update_error:
            logger.error(f"Error updating upload record after S3 failure: {str(update_error)}")


async def finalize_upload(upload_id: Union[str, uuid.UUID], background_tasks=None) -> str:
    """
    Finalize a completed upload by assembling chunks and optionally uploading to S3.
    
    This is the central function for file assembly and S3 upload. It handles:
    1. Assembling chunks into a complete file
    2. Uploading to S3 if configured and background tasks available
    3. Marking for deferred S3 upload if background tasks not available
    4. Error handling and recovery for missing chunks
    
    Args:
        upload_id: The ID of the upload
        background_tasks: Optional FastAPI BackgroundTasks for async S3 upload
        
    Returns:
        Path to the assembled file
    """
    logger.info(f"Finalizing upload: {upload_id}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        upload_id_str = str(upload.id)
        
        # If upload is not complete, raise error
        if upload.status != TusUploadStatus.COMPLETED:
            raise HTTPException(status_code=400, detail="Upload is not complete")
            
        # Get filename and check existing status to avoid duplicate work
        filename = upload.filename
            
        # Check if already finalized with S3 URI
        if (hasattr(upload, 's3_uri') and upload.s3_uri) or upload.upload_metadata.get("s3_uri"):
            logger.info(f"Upload {upload_id} already finalized with S3 URI")
            s3_uri = upload.s3_uri if hasattr(upload, 's3_uri') else upload.upload_metadata.get("s3_uri")
            
            # If we already have S3, but want to return a local path, check if local file exists
            if upload.upload_metadata.get("local_path") and os.path.exists(upload.upload_metadata.get("local_path")):
                return upload.upload_metadata.get("local_path")
            
            # Otherwise, indicate this is already processed by returning the S3 URI as the path
            # This is not a real file path, but indicates to the caller that no further action is needed
            return f"s3://{s3_uri}"
        
        # Storage path for this upload
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        final_path = os.path.join(upload_dir, filename)
        
        # Check if the file was already assembled
        if os.path.exists(final_path):
            logger.info(f"Upload {upload_id} already assembled at: {final_path}")
            
            # Mark as locally finalized if not already
            if not upload.upload_metadata.get("storage_type"):
                upload.upload_metadata["storage_type"] = "local"
                upload.upload_metadata["local_path"] = final_path
                upload.upload_metadata["assembly_time"] = datetime.now(timezone.utc).isoformat()
                upload.upload_metadata["assembly_complete"] = True
                p8.repository(TusFileUpload).update_records([upload])
                
            # Check if S3 upload is needed
            if USE_S3 and not upload.upload_metadata.get("s3_uri"):
                if upload.upload_metadata.get("s3_upload_status") != "completed":
                    if background_tasks is not None:
                        logger.info(f"Queuing S3 upload as background task for: {upload_id}")
                        background_tasks.add_task(upload_to_s3_background, upload_id_str, final_path)
                    else:
                        # Mark for deferred S3 processing
                        logger.warning(f"No background tasks available - marking for deferred S3 upload: {upload_id}")
                        upload.upload_metadata["s3_upload_status"] = "pending_deferred"
                        upload.upload_metadata["needs_s3_upload"] = True
                        p8.repository(TusFileUpload).update_records([upload])
                        
                        # Try to trigger immediate processing (non-blocking)
                        try:
                            import asyncio
                            asyncio.create_task(process_pending_s3_resources(limit=1))
                        except Exception:
                            pass
            
            return final_path
        
        # Ensure upload directory exists
        os.makedirs(upload_dir, exist_ok=True)
            
        # Get all chunks for this upload
        chunks = p8.repository(TusFileChunk).select(
            upload_id=upload_id_str
        )
        
        if not chunks:
            # This is a critical error - chunks should exist because the upload is marked as complete
            logger.warning(f"No chunks found for upload {upload_id} - this may indicate distributed storage issues")
            
            # Create an empty placeholder file and flag for recovery
            with open(final_path, "wb") as f:
                # Just write a small header to indicate this is a placeholder
                f.write(b"TUS_UPLOAD_PLACEHOLDER - Will be replaced by S3 content")
            
            # Mark upload for recovery
            upload.upload_metadata["storage_type"] = "placeholder"
            upload.upload_metadata["chunks_missing"] = True
            upload.upload_metadata["recovery_needed"] = True
            upload.upload_metadata["local_path"] = final_path
            p8.repository(TusFileUpload).update_records([upload])
            
            # This is a critical issue that we'll handle according to the storage configuration
            if USE_S3:
                # If using S3, we return the path but mark it for later processing
                logger.warning(f"Upload {upload_id} missing chunks - marking for recovery through scheduler")
                return final_path
            else:
                # Without S3, we can't recover
                raise HTTPException(status_code=400, detail="No chunks found for this upload")
        
        # Assemble the file from chunks
        logger.info(f"Assembling {len(chunks)} chunks for upload {upload_id}")
        missing_chunks = []
        
        # Use FileSystemService for assembly to be consistent with other code
        from percolate.services.FileSystemService import FileSystemService
        fs = FileSystemService()
        
        # First assemble chunks in memory to avoid disk I/O with lots of small files
        assembled_data = bytearray()
        
        # Sort chunks by offset to ensure correct order
        for chunk in sorted(chunks, key=lambda x: x['chunk_offset']):
            chunk_path = chunk['storage_path']
            # Check if chunk file exists
            if os.path.exists(chunk_path):
                try:
                    with open(chunk_path, "rb") as infile:
                        chunk_data = infile.read()
                        assembled_data.extend(chunk_data)
                        logger.debug(f"Added chunk: offset={chunk['chunk_offset']}, size={len(chunk_data)} bytes")
                except Exception as read_error:
                    logger.warning(f"Failed to read chunk {chunk_path}: {str(read_error)}")
                    missing_chunks.append(chunk_path)
            else:
                # Record missing chunk
                missing_chunks.append(chunk_path)
                logger.warning(f"Chunk file missing: {chunk_path}")
        
        # Write the assembled data to the final file
        with open(final_path, "wb") as outfile:
            outfile.write(assembled_data)
        
        # Log any missing chunks
        if missing_chunks:
            logger.warning(f"Upload {upload_id} assembled with {len(missing_chunks)} missing chunks. File may be incomplete.")
            upload.upload_metadata["missing_chunks"] = missing_chunks
            upload.upload_metadata["incomplete_assembly"] = True
        
        logger.info(f"Upload {upload_id} finalized at: {final_path}")
        
        # Mark the upload as locally finalized
        upload.upload_metadata["storage_type"] = "local"
        upload.upload_metadata["local_path"] = final_path
        upload.upload_metadata["assembly_time"] = datetime.now(timezone.utc).isoformat()
        upload.upload_metadata["assembly_complete"] = True
        p8.repository(TusFileUpload).update_records([upload])
        
        # Handle S3 upload based on configuration
        if USE_S3:
            if background_tasks is not None:
                logger.info(f"Queuing S3 upload as background task for: {upload_id}")
                upload.upload_metadata["s3_upload_status"] = "background_queued"
                p8.repository(TusFileUpload).update_records([upload])
                background_tasks.add_task(upload_to_s3_background, upload_id_str, final_path)
            else:
                # Mark for deferred processing
                logger.warning(f"No background tasks available - marking for deferred S3 upload: {upload_id}")
                upload.upload_metadata["s3_upload_status"] = "pending_deferred"
                upload.upload_metadata["needs_s3_upload"] = True
                p8.repository(TusFileUpload).update_records([upload])
                
                # Try to trigger immediate processing (non-blocking)
                try:
                    import asyncio
                    asyncio.create_task(process_pending_s3_resources(limit=1))
                except Exception as scheduler_error:
                    logger.warning(f"Could not trigger immediate processing: {str(scheduler_error)}")
        else:
            logger.info(f"S3 upload disabled - file will remain in local storage: {final_path}")
            
        return final_path
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error finalizing upload: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error finalizing upload: {str(e)}")

async def delete_upload(upload_id: Union[str, uuid.UUID]) -> bool:
    """
    Delete a Tus upload and all its chunks.
    
    Implement this properly for compliance later
    
    Args:
        upload_id: The ID of the upload
        
    Returns:
        True if successful
    """
    logger.info(f"Deleting upload: {upload_id}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        upload_id_str = str(upload.id)
        
        # Delete chunks
        chunks = p8.repository(TusFileChunk).select(upload_id=upload_id_str)
        for chunk in chunks:
            # Delete the chunk file if it exists
            if os.path.exists(chunk['storage_path']):
                os.remove(chunk['storage_path'])
            
            # Delete the chunk record
            #p8.repository(TusFileChunk).delete(id=chunk.id)
        
        # Delete the upload directory
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        if os.path.exists(upload_dir):
            shutil.rmtree(upload_dir)
        
        # Delete the upload record
        #p8.repository(TusFileUpload).delete(id=upload.id)
        
        # If upload was stored in S3, delete from S3
        if upload.upload_metadata.get("storage_type") == "s3" and upload.upload_metadata.get("s3_uri"):
            try:
                s3_service = S3Service()
                #s3_service.delete_file_by_uri(upload.upload_metadata["s3_uri"])
                logger.info(f"Deleted S3 object: {upload.upload_metadata['s3_uri']}")
            except Exception as s3_error:
                logger.error(f"Error deleting from S3: {str(s3_error)}")
                # Continue with deletion even if S3 fails
        
        return True
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error deleting upload: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error deleting upload: {str(e)}")

async def list_uploads(
    user_id: Optional[str] = None,
    project_name: Optional[str] = None,
    status: Optional[TusUploadStatus] = None,
    tags: Optional[List[str]] = None,
    search_text: Optional[str] = None,
    limit: int = 100,
    offset: int = 0
) -> List[TusUploadMetadata]:
    """
    List all uploads matching the given filters.
    
    Args:
        user_id: Optional user ID to filter by
        project_name: Optional project name to filter by
        status: Optional status to filter by
        limit: Maximum number of results
        offset: Offset for pagination
        
    Returns:
        List of uploads
    """
    logger.info(f"Listing uploads for user: {user_id or 'any'}, project: {project_name or 'any'}")
    
    try:
        # Build query filters
        filters = {}
        if user_id:
            try:
                # Validate UUID
                uuid_obj = uuid.UUID(user_id)
                filters["userid"] = str(uuid_obj)
            except (ValueError, TypeError):
                logger.warning(f"Invalid user ID for filtering: {user_id}")
                
        if project_name:
            filters["project_name"] = project_name
            
        if status:
            filters["status"] = status
            

        # Build query with pagination
        query = f"""
            SELECT * FROM "TusFileUpload" 
   
        """
        
        # Execute the query (test only)
        results = p8.repository(TusFileUpload).select_with_predicates(query,filter=filters)
        
        # Log the SQL for debugging
        logger.info(f"Executing SQL query: {query} with ")
        
        # Convert to models
        uploads = []
        for row in results:
            upload = TusFileUpload(**row)
            
            # Log each upload found
            logger.info(f"Found upload: ID={upload.id}, Filename={upload.filename}, Status={upload.status}, Size={upload.total_size}")
            
            # Log S3 details if available
            if hasattr(upload, 's3_uri') and upload.s3_uri:
                logger.info(f"  S3: URI={upload.s3_uri}, Bucket={upload.s3_bucket}, Key={upload.s3_key}")
            
            # Convert to metadata response
            metadata = TusUploadMetadata(
                id=upload.id,
                filename=upload.filename,
                content_type=upload.content_type,
                total_size=upload.total_size,
                uploaded_size=upload.uploaded_size,
                status=upload.status,
                created_at=upload.created_at,
                updated_at=upload.updated_at,
                expires_at=upload.expires_at,
                upload_metadata=upload.upload_metadata,
                tags=upload.tags if hasattr(upload, 'tags') else [],
                resource_id=upload.resource_id if hasattr(upload, 'resource_id') else None,
                has_resource=bool(upload.resource_id) if hasattr(upload, 'resource_id') else False,
                s3_uri=upload.s3_uri if hasattr(upload, 's3_uri') else None,
                s3_bucket=upload.s3_bucket if hasattr(upload, 's3_bucket') else None,
                s3_key=upload.s3_key if hasattr(upload, 's3_key') else None
            )
            uploads.append(metadata)
            
        return uploads
    except Exception as e:
        logger.error(f"Error listing uploads: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error listing uploads: {str(e)}")

async def get_user_files(user_id: Union[str, uuid.UUID], limit: int = 100, offset: int = 0) -> List[TusUploadMetadata]:
    """
    Get all files for a specific user.
    
    Args:
        user_id: The user ID to find files for
        limit: Maximum number of results
        offset: Offset for pagination
        
    Returns:
        List of user's files
    """
    logger.info(f"Finding files for user: {user_id}")
    
    try:
        # Ensure user_id is a string
        user_id_str = str(user_id)
        
        # Query for user's files
        query = """
            SELECT * FROM p8."TusFileUpload" 
            WHERE userid = %s
            ORDER BY created_at DESC
            LIMIT %s OFFSET %s
        """
        
        # Execute the query
        results = p8.repository(TusFileUpload).execute(query, data=(user_id_str, limit, offset))
        
        # Log the results
        logger.info(f"Found {len(results)} files for user {user_id}")
        
        # Convert to models
        uploads = []
        for row in results:
            upload = TusFileUpload(**row)
            
            # Convert to metadata response
            metadata = TusUploadMetadata(
                id=upload.id,
                filename=upload.filename,
                content_type=upload.content_type,
                total_size=upload.total_size,
                uploaded_size=upload.uploaded_size,
                status=upload.status,
                created_at=upload.created_at,
                updated_at=upload.updated_at,
                expires_at=upload.expires_at,
                upload_metadata=upload.upload_metadata,
                tags=upload.tags if hasattr(upload, 'tags') else [],
                resource_id=upload.resource_id if hasattr(upload, 'resource_id') else None,
                has_resource=bool(upload.resource_id) if hasattr(upload, 'resource_id') else False,
                s3_uri=upload.s3_uri if hasattr(upload, 's3_uri') else None,
                s3_bucket=upload.s3_bucket if hasattr(upload, 's3_bucket') else None,
                s3_key=upload.s3_key if hasattr(upload, 's3_key') else None
            )
            uploads.append(metadata)
            
        return uploads
    except Exception as e:
        logger.error(f"Error getting user files: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error getting user files: {str(e)}")

async def extend_expiration(
    upload_id: Union[str, uuid.UUID],
    expires_in: timedelta = DEFAULT_EXPIRATION_DELTA
) -> datetime:
    """
    Extend the expiration of an upload.
    
    Args:
        upload_id: The ID of the upload
        expires_in: New expiration delta
        
    Returns:
        New expiration timestamp
    """
    logger.info(f"Extending expiration for upload: {upload_id}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        
        # Calculate new expiration
        new_expiration = datetime.now(timezone.utc) + expires_in
        
        # Update the record
        upload.expires_at = new_expiration
        upload.updated_at = datetime.now(timezone.utc)
        p8.repository(TusFileUpload).update_records([upload])
        
        return new_expiration
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error extending expiration: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error extending expiration: {str(e)}")

async def parse_metadata(metadata_header: str) -> Dict[str, str]:
    """
    Parse Tus metadata header into a dictionary.
    
    Args:
        metadata_header: Tus metadata header string
        
    Returns:
        Dictionary of metadata key-value pairs
    """
    if not metadata_header:
        return {}
        
    metadata = {}
    for item in metadata_header.split(','):
        if ' ' not in item:
            continue
            
        key, value = item.strip().split(' ', 1)
        try:
            # Tus metadata values are base64 encoded
            from base64 import b64decode
            decoded_value = b64decode(value).decode('utf-8')
            metadata[key] = decoded_value
        except Exception as e:
            logger.warning(f"Failed to decode metadata value {key}: {str(e)}")
            # Keep original value if decoding fails
            metadata[key] = value
            
    return metadata


async def list_pending_s3_resources(limit: int = 20, filter_unprocessable: bool = False) -> List[Dict[str, Any]]:
    """
    List TUS uploads that have been successfully uploaded to S3 but 
    not yet processed to create resources.
    
    Args:
        limit: Maximum number of pending uploads to list
        filter_unprocessable: If True, filter out files with unsupported content types
        
    Returns:
        List of pending upload records
    """
    logger.info(f"Listing pending S3 uploads (limit: {limit}, filter_unprocessable: {filter_unprocessable})...")
    
    # Build a basic query without content type filtering
    basic_query = """
    SELECT * FROM public."TusFileUpload"
    WHERE
        status = 'completed'
        AND s3_uri IS NOT NULL
        AND s3_uri != ''
        AND (resource_id IS NULL)
    """
    
    # Add content type filter if requested
    if filter_unprocessable:
        # List of supported content types for resource creation
        supported_types = [
            'audio/x-wav', 
            'audio/wav',
            'audio/mpeg',
            'audio/mp3',
            'audio/mp4',
            'application/pdf',
            'text/plain',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',  # docx
            'application/msword'  # doc
        ]
        
        # Get the uploads first
        all_uploads = p8.repository(TusFileUpload).execute(
            basic_query + " ORDER BY updated_at DESC LIMIT %s",
            data=(limit*3,)  # Fetch more to account for filtering
        )
        
        # Filter in Python rather than SQL to avoid complex queries
        pending_uploads = [
            upload for upload in all_uploads
            if upload['content_type'] in supported_types or
               (upload['content_type'] and upload['content_type'].startswith('audio/'))
        ]
        
        # Apply the limit after filtering
        pending_uploads = pending_uploads[:limit]
    else:
        # No filtering, just get all pending uploads
        pending_uploads = p8.repository(TusFileUpload).execute(
            basic_query + " ORDER BY updated_at DESC LIMIT %s",
            data=(limit,)
        )
    
    if not pending_uploads:
        logger.info("No pending uploads found that need processing")
        return []
    
    logger.info(f"Found {len(pending_uploads)} pending uploads")
    return pending_uploads

async def get_upload_info_ignore_expiration(upload_id: Union[str, uuid.UUID]) -> TusFileUpload:
    """
    Get information about a Tus upload, ignoring expiration.
    This is used specifically for processing S3 resources where expiration doesn't matter.
    
    Args:
        upload_id: The ID of the upload
        
    Returns:
        TusFileUpload object
    """
    logger.info(f"Getting upload info (ignoring expiration) for: {upload_id}")
    
    try:
        # Ensure we have a string ID
        upload_id_str = str(upload_id)
        
        # Get the upload from database
        upload = p8.repository(TusFileUpload).get_by_id(id=upload_id_str, as_model=True)
        
        if not upload:
            logger.warning(f"Upload {upload_id} not found")
            raise HTTPException(status_code=404, detail="Upload not found")
            
        # Log detailed info about the retrieved upload
        logger.info(f"Retrieved upload: ID={upload.id}, Filename={upload.filename}, Status={upload.status}, Size={upload.total_size}, Uploaded={upload.uploaded_size}")
        
        # If expired but has S3 URI, we ignore expiration
        if upload.expires_at:
            # Make sure both datetimes are timezone-aware for comparison
            current_time = datetime.now(timezone.utc)
            expires_at = upload.expires_at
            
            # If expires_at is naive (no timezone), assume it's UTC
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
                
            if expires_at < current_time:
                logger.warning(f"Upload {upload_id} has expired, but ignoring expiration for S3 processing")
        
        return upload
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting upload info: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Failed to get upload info: {str(e)}")

async def process_pending_s3_resources(limit: int = 20, filter_unprocessable: bool = True) -> Dict[str, Any]:
    """
    Process TUS uploads that have been successfully uploaded to S3 but 
    not yet processed to create resources.
    
    Args:
        limit: Maximum number of pending uploads to process
        filter_unprocessable: If True, skip files with unsupported content types
        
    Returns:
        Dictionary with processing statistics
    """
    from .resource_creator import create_resources_from_upload
    
    # Find uploads that:
    # 1. Have a completed status
    # 2. Have an S3 URI
    # 3. Don't have a resource_id set (indicating resources haven't been created)
    # 4. Optionally filter out files with unsupported content types
    
    logger.info(f"Looking for pending S3 uploads (limit: {limit}, filter_unprocessable: {filter_unprocessable})...")
    
    # Use the centralized function to get pending uploads
    pending_uploads = await list_pending_s3_resources(limit=limit, filter_unprocessable=filter_unprocessable)
    
    if not pending_uploads:
        logger.info("No pending uploads found that need processing")
        return {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "pending_count": 0,
            "processed_count": 0,
            "success_count": 0,
            "failed_count": 0
        }
    
    logger.info(f"Found {len(pending_uploads)} pending uploads to process")
    
    # Process each pending upload
    processed_count = 0
    success_count = 0
    failed_count = 0
    
    for upload_data in pending_uploads:
        upload_id = str(upload_data['id'])
        filename = upload_data.get('filename', 'unknown')
        s3_uri = upload_data.get('s3_uri', '')
        
        logger.info(f"Processing upload {upload_id}: {filename} ({s3_uri})")
        
        try:
            # Call the resource creation function - we'll patch the resource_creator to use
            # get_upload_info_ignore_expiration for S3 processing
            # Explicitly set save_resources=True to ensure resources are saved
            resources = await create_resources_from_upload(upload_id, save_resources=True)
            
            processed_count += 1
            
            if resources:
                success_count += 1
                logger.info(f"Successfully created {len(resources)} resources for upload {upload_id}")
            else:
                failed_count += 1
                logger.warning(f"No resources were created for upload {upload_id}")
                
                # Update the upload record to indicate the failure - use direct repository access to avoid expiration check
                upload = p8.repository(TusFileUpload).get_by_id(id=upload_id, as_model=True)
                if upload:
                    if not hasattr(upload, 'upload_metadata') or upload.upload_metadata is None:
                        upload.upload_metadata = {}
                    upload.upload_metadata["resource_creation_attempted"] = True
                    upload.upload_metadata["resource_creation_failure"] = "No resources were created"
                    upload.upload_metadata["resource_creation_attempt_time"] = datetime.now(timezone.utc).isoformat()
                    p8.repository(TusFileUpload).update_records([upload])
                
        except Exception as e:
            failed_count += 1
            logger.error(f"Error processing upload {upload_id}: {str(e)}")
            
            # Update the upload record to indicate the error - use direct repository access to avoid expiration check
            try:
                upload = p8.repository(TusFileUpload).get_by_id(id=upload_id, as_model=True)
                if upload:
                    if not hasattr(upload, 'upload_metadata') or upload.upload_metadata is None:
                        upload.upload_metadata = {}
                    upload.upload_metadata["resource_creation_attempted"] = True
                    upload.upload_metadata["resource_creation_error"] = str(e)
                    upload.upload_metadata["resource_creation_attempt_time"] = datetime.now(timezone.utc).isoformat()
                    p8.repository(TusFileUpload).update_records([upload])
            except Exception as update_error:
                logger.error(f"Error updating upload record: {str(update_error)}")
    
    # Return statistics
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "pending_count": len(pending_uploads),
        "processed_count": processed_count,
        "success_count": success_count,
        "failed_count": failed_count
    }


async def create_flush_pending_resources_schedule(
    interval_hours: int = 1, 
    user_id: Optional[str] = None
) -> Dict[str, Any]:
    """
    Create a scheduled job to periodically flush pending resources.
    
    Args:
        interval_hours: How often to run the job (in hours)
        user_id: User ID to associate with the schedule
        
    Returns:
        Dictionary with schedule creation result
    """
    try:
        # Import the Schedule model
        from percolate.models.p8.types import Schedule
        import uuid
        
        # Generate a unique ID for the schedule
        schedule_id = str(uuid.uuid4())
        
        # Use a cron schedule string
        # This format runs the job every N hours
        schedule_string = f"0 */{interval_hours} * * *"  # At minute 0, every N hours
        
        # Create the schedule object
        schedule = Schedule(
            id=schedule_id,
            name="Process Pending TUS Uploads",  # Required field
            spec={  # Required field
                "task": "process_pending_s3_resources",
                "description": "Automatically process pending TUS uploads",
                "created_by": "TUS controller",
                "interval_hours": interval_hours
            },
            userid=user_id,
            schedule=schedule_string,
            created_at=datetime.now(timezone.utc),
            disabled_at=None  # Not disabled
        )
        
        # Save the schedule to the database
        p8.repository(Schedule).update_records([schedule])
        
        logger.info(f"Created schedule {schedule_id} to run process_pending_s3_resources every {interval_hours} hour(s)")
        
        return {
            "success": True,
            "schedule_id": schedule_id,
            "name": "Process Pending TUS Uploads",
            "task": schedule.spec["task"],
            "interval_hours": interval_hours,
            "schedule": schedule_string
        }
        
    except Exception as e:
        logger.error(f"Error creating schedule for process_pending_s3_resources: {str(e)}")
        return {
            "success": False,
            "error": str(e)
        }