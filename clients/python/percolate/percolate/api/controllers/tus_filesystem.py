"""
TUS protocol controller - Filesystem only implementation.
Stores chunks on shared filesystem for pod affinity.
Generates S3 URLs for future use but doesn't upload.
"""

import os
import uuid
import json
import shutil
import tempfile
from typing import Optional, Dict, Any, List, Union
from datetime import datetime, timezone, timedelta
from fastapi import HTTPException, Request, Response, BackgroundTasks
from pathlib import Path
import percolate as p8
from percolate.utils import logger, make_uuid
from percolate.models.media.tus import (
    TusFileUpload,
    TusFileChunk,
    TusUploadStatus,
    TusUploadMetadata,
    TusUploadPatchResponse,
    TusUploadCreationResponse
)
from .resource_creator import create_resources_from_upload

# Configuration
DEFAULT_CHUNK_SIZE = 5 * 1024 * 1024  # 5MB
DEFAULT_EXPIRATION_DELTA = timedelta(days=1)
STORAGE_PATH = os.environ.get("TUS_STORAGE_PATH", "/tmp/tus_uploads")
TUS_API_ROOT_PATH = os.environ.get("TUS_API_PATH", "/tus")
S3_BUCKET = os.environ.get("TUS_S3_BUCKET", "percolate")

# Create storage directory if it doesn't exist
os.makedirs(STORAGE_PATH, exist_ok=True)

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
            metadata[key] = value
            
    return metadata

async def create_upload(
    request: Request,
    filename: str,
    file_size: int,
    metadata: Dict[str, Any],
    user_id: Optional[str] = None,
    project_name: str = "default",
    content_type: Optional[str] = None,
    expires_in: timedelta = DEFAULT_EXPIRATION_DELTA,
    tags: Optional[List[str]] = None
) -> TusUploadCreationResponse:
    """
    Create a new Tus file upload.
    """
    logger.info(f"Creating Tus upload for file: {filename}, size: {file_size}")
    
    # Validate user_id is a proper UUID if provided
    if user_id:
        try:
            uuid_obj = uuid.UUID(user_id)
            user_id = str(uuid_obj)
            logger.info(f"Using user ID: {user_id}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid user ID provided: {user_id} - will not associate with a user")
            user_id = None
    
    # Generate a unique upload ID
    upload_id = make_uuid({
        'filename': filename,
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'user_id': user_id or 'anonymous'
    })
    
    # Calculate expiration
    expires_at = datetime.now(timezone.utc) + expires_in
    
    # Create directory for chunks on shared filesystem
    upload_path = os.path.join(STORAGE_PATH, str(upload_id))
    os.makedirs(upload_path, exist_ok=True)
    
    # Build the upload URI
    scheme = request.url.scheme
    host = request.headers.get('host', request.url.netloc)
    upload_uri = f"{scheme}://{host}{TUS_API_ROOT_PATH}/{upload_id}"
    
    # Handle tags
    file_tags = []
    if tags:
        file_tags = tags[:3]
    elif metadata.get('tags'):
        try:
            if isinstance(metadata['tags'], str):
                tag_list = [tag.strip() for tag in metadata['tags'].split(',') if tag.strip()]
                file_tags = tag_list[:3]
            elif isinstance(metadata['tags'], list):
                file_tags = metadata['tags'][:3]
        except Exception as e:
            logger.warning(f"Error processing tags from metadata: {str(e)}")
    
    # Extract user_id from metadata if present
    metadata_user_id = metadata.get('user_id')
    if metadata_user_id:
        logger.info(f"Found user ID in metadata: {metadata_user_id}")
    
    # Use explicitly provided user_id first, then try metadata
    effective_user_id = user_id or metadata_user_id
    if effective_user_id:
        logger.info(f"Setting upload user_id to: {effective_user_id}")
    
    # Generate S3 paths for future use (but don't actually upload)
    user_prefix = effective_user_id or "anonymous"
    s3_key = f"{project_name}/uploads/{user_prefix}/{upload_id}/{filename}"
    s3_bucket = S3_BUCKET
    
    logger.info(f"Generated S3 path (for future use): s3://{s3_bucket}/{s3_key}")
    
    # Create the upload record
    upload = TusFileUpload(
        id=upload_id,
        userid=effective_user_id,
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
        tags=file_tags,
        s3_key=s3_key,
        s3_bucket=s3_bucket,
        s3_uri=f"s3://{s3_bucket}/{s3_key}"
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
    
    return TusUploadCreationResponse(
        upload_id=upload_id,
        location=upload_uri,
        expires_at=expires_at
    )

async def get_upload_info(upload_id: Union[str, uuid.UUID]) -> TusFileUpload:
    """
    Get information about a Tus upload.
    """
    logger.info(f"Getting upload info for: {upload_id}")
    
    try:
        upload_id_str = str(upload_id)
        upload = p8.repository(TusFileUpload).get_by_id(id=upload_id_str, as_model=True)
        
        if not upload:
            logger.warning(f"Upload {upload_id} not found")
            raise HTTPException(status_code=404, detail="Upload not found")
            
        logger.info(f"Retrieved upload: ID={upload.id}, Filename={upload.filename}, Status={upload.status}, Size={upload.total_size}, Uploaded={upload.uploaded_size}")
        
        # Check if upload has expired
        if upload.expires_at:
            current_time = datetime.now(timezone.utc)
            expires_at = upload.expires_at
            
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
                
            if expires_at < current_time:
                logger.warning(f"Upload {upload_id} has expired")
                
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

async def get_upload_info_ignore_expiration(upload_id: Union[str, uuid.UUID]) -> TusFileUpload:
    """
    Get upload info without checking expiration (for resource creation).
    """
    logger.info(f"Getting upload info (ignore expiration) for: {upload_id}")
    
    try:
        upload_id_str = str(upload_id)
        upload = p8.repository(TusFileUpload).get_by_id(id=upload_id_str, as_model=True)
        
        if not upload:
            logger.warning(f"Upload {upload_id} not found")
            raise HTTPException(status_code=404, detail="Upload not found")
            
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
    background_tasks: BackgroundTasks
) -> TusUploadPatchResponse:
    """
    Process a chunk of a Tus upload - store to filesystem only.
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
        
        # Store chunk to filesystem
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        os.makedirs(upload_dir, exist_ok=True)
        
        chunk_filename = f"chunk_{offset:010d}_{content_length}"
        chunk_path = os.path.join(upload_dir, chunk_filename)
        
        with open(chunk_path, "wb") as f:
            f.write(chunk_data)
        
        # Create chunk record
        chunk = TusFileChunk(
            upload_id=upload_id,
            chunk_size=content_length,
            chunk_offset=offset,
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
            logger.info(f"Upload {upload_id} completed - all bytes received")
            
            # Trigger finalization in background
            if background_tasks:
                logger.info(f"Triggering background finalization for upload {upload_id}")
                background_tasks.add_task(finalize_upload, upload_id)
        else:
            # If this is the first chunk, mark as in progress
            if upload.status == TusUploadStatus.INITIATED:
                upload.status = TusUploadStatus.IN_PROGRESS
        
        # Save the upload record
        p8.repository(TusFileUpload).update_records([upload])
        
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

async def finalize_upload(upload_id: Union[str, uuid.UUID]) -> str:
    """
    Finalize a completed upload by assembling chunks and creating resources.
    """
    logger.info(f"Finalizing upload: {upload_id}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        upload_id_str = str(upload.id)
        
        # If upload is not complete, raise error
        if upload.status != TusUploadStatus.COMPLETED:
            raise HTTPException(status_code=400, detail="Upload is not complete")
        
        # Check if already finalized
        if upload.upload_metadata.get("finalized"):
            logger.info(f"Upload {upload_id} already finalized")
            return upload.s3_uri or ""
        
        # Get all chunks for this upload
        chunks = p8.repository(TusFileChunk).select(
            upload_id=upload_id_str
        )
        
        if not chunks:
            logger.warning(f"No chunks found for upload {upload_id}")
            raise HTTPException(status_code=400, detail="No chunks found for this upload")
        
        # Assemble file from chunks
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        final_path = os.path.join(upload_dir, upload.filename)
        
        logger.info(f"Assembling {len(chunks)} chunks into {final_path}")
        
        # Sort chunks by offset
        sorted_chunks = sorted(chunks, key=lambda x: x['chunk_offset'])
        
        with open(final_path, "wb") as outfile:
            for chunk in sorted_chunks:
                chunk_path = chunk['storage_path']
                if os.path.exists(chunk_path):
                    with open(chunk_path, "rb") as infile:
                        outfile.write(infile.read())
                    # Delete chunk file after reading
                    os.remove(chunk_path)
                else:
                    logger.warning(f"Chunk file not found: {chunk_path}")
        
        logger.info(f"File assembled successfully: {final_path}")
        
        # Update upload record
        upload.upload_metadata["finalized"] = True
        upload.upload_metadata["finalized_at"] = datetime.now(timezone.utc).isoformat()
        upload.upload_metadata["storage_type"] = "filesystem"
        upload.upload_metadata["local_path"] = final_path
        upload.upload_metadata["file_size"] = os.path.getsize(final_path)
        
        # Note: S3 upload is commented out for now due to slow connection
        # In future, uncomment this section to enable S3 backup
        '''
        # Upload to S3 in background (when enabled)
        if S3_ENABLED:
            try:
                logger.info(f"Uploading to S3: {upload.s3_uri}")
                s3_service = get_s3_service()
                with open(final_path, 'rb') as f:
                    s3_service.s3_client.put_object(
                        Bucket=upload.s3_bucket,
                        Key=upload.s3_key,
                        Body=f,
                        ContentType=upload.content_type or 'application/octet-stream'
                    )
                upload.upload_metadata["s3_uploaded"] = True
                logger.info(f"S3 upload completed: {upload.s3_uri}")
            except Exception as e:
                logger.error(f"S3 upload failed: {str(e)}")
                upload.upload_metadata["s3_error"] = str(e)
        '''
        
        # Save the upload record
        p8.repository(TusFileUpload).update_records([upload])
        
        # Create resources from the uploaded file
        # In filesystem-only mode, we need to temporarily update the upload record
        # to point to the local file so resource creation can read it
        original_s3_uri = upload.s3_uri
        try:
            # Temporarily set the s3_uri to the local path for resource creation
            upload.s3_uri = f"file://{final_path}"
            p8.repository(TusFileUpload).update_records([upload])
            
            logger.info(f"Creating resources for upload: {upload_id} from local file: {final_path}")
            resources = await create_resources_from_upload(upload_id)
            userid = resources[0].userid if resources else None
            logger.info(f"Created {len(resources)} resources for upload: {upload_id} with userid: {userid}")
            
            # Restore the original S3 URI
            upload.s3_uri = original_s3_uri
            upload.upload_metadata["resources_created"] = True
            upload.upload_metadata["resource_count"] = len(resources)
            p8.repository(TusFileUpload).update_records([upload])
        except Exception as resource_error:
            logger.error(f"Error creating resources: {str(resource_error)}")
            # Restore the original S3 URI
            upload.s3_uri = original_s3_uri
            # Don't fail the finalization, just log the error
            upload.upload_metadata["resource_creation_error"] = str(resource_error)
            p8.repository(TusFileUpload).update_records([upload])
        
        # Return the S3 URI (even though we didn't actually upload)
        return upload.s3_uri or ""
        
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error finalizing upload: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error finalizing upload: {str(e)}")

async def delete_upload(upload_id: Union[str, uuid.UUID]) -> bool:
    """
    Delete a Tus upload and all its chunks.
    """
    logger.info(f"Deleting upload: {upload_id}")
    
    try:
        # Get the upload
        upload = await get_upload_info(upload_id)
        upload_id_str = str(upload.id)
        
        # Delete chunks from database
        chunks = p8.repository(TusFileChunk).select(upload_id=upload_id_str)
        for chunk in chunks:
            # Delete the chunk file if it exists
            chunk_path = chunk.get('storage_path')
            if chunk_path and os.path.exists(chunk_path):
                os.remove(chunk_path)
        
        # Delete the upload directory
        upload_dir = os.path.join(STORAGE_PATH, upload_id_str)
        if os.path.exists(upload_dir):
            shutil.rmtree(upload_dir)
        
        # Mark upload as deleted (soft delete)
        upload.status = TusUploadStatus.EXPIRED
        upload.upload_metadata["deleted"] = True
        upload.upload_metadata["deleted_at"] = datetime.now(timezone.utc).isoformat()
        p8.repository(TusFileUpload).update_records([upload])
        
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
    """
    logger.info(f"Listing uploads for user: {user_id or 'any'}, project: {project_name or 'any'}")
    
    try:
        # For now, just get all uploads and filter in memory
        # In production, implement proper SQL filtering
        query = """
            SELECT * FROM "TusFileUpload" 
            ORDER BY created_at DESC
        """
        
        results = p8.repository(TusFileUpload).execute(query)
        
        # Convert to models and filter
        uploads = []
        for row in results:
            upload = TusFileUpload(**row)
            
            # Apply filters
            if user_id and upload.userid != user_id:
                continue
            if project_name and upload.project_name != project_name:
                continue
            if status and upload.status != status:
                continue
            
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
                s3_uri=upload.s3_uri if hasattr(upload, 'uri') else None,
                s3_bucket=upload.s3_bucket if hasattr(upload, 's3_bucket') else None,
                s3_key=upload.s3_key if hasattr(upload, 's3_key') else None
            )
            uploads.append(metadata)
        
        # Apply pagination
        start_idx = offset
        end_idx = offset + limit
        return uploads[start_idx:end_idx]
        
    except Exception as e:
        logger.error(f"Error listing uploads: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error listing uploads: {str(e)}")