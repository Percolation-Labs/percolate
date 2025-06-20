"""
Tus protocol router for the Percolate API.
Implements the tus.io protocol for resumable file uploads.

Tus Protocol Version: 1.0.0
Extensions: creation, expiration, termination, creation-with-upload
"""

import os
import uuid
import base64
from typing import List, Optional, Dict, Any
from datetime import datetime, timedelta
from fastapi import APIRouter, Request, Response, Header, Depends, BackgroundTasks, Query, Path, HTTPException
from fastapi.responses import JSONResponse
from datetime import timezone
import percolate as p8
from percolate.api.controllers import tus_filesystem as tus_controller
from percolate.models.media.tus import (
    TusFileUpload,
    TusFileChunk,
    TusUploadStatus,
    TusUploadMetadata,
    TusUploadPatchResponse,
    TusUploadCreationResponse
)
from percolate.utils import logger
from pydantic import BaseModel
from ..auth import get_user_id, HybridAuth

# Create an instance of HybridAuth
hybrid_auth = HybridAuth()
from . import get_project_name

# Constants for Tus protocol
TUS_VERSION = "1.0.0"
TUS_EXTENSIONS = "creation,creation-with-upload,expiration,termination"
TUS_MAX_SIZE = int(os.environ.get("TUS_MAX_SIZE", str(5 * 1024 * 1024 * 1024)))  # 5GB default
TUS_API_VERSION = os.environ.get("TUS_API_VERSION", "v1")
TUS_API_PATH = os.environ.get("TUS_API_PATH", "/tus")
DEFAULT_EXPIRATION = int(os.environ.get("TUS_DEFAULT_EXPIRATION", "86400"))  # 24 hours in seconds

# Create the router
router = APIRouter()

# Helper functions

def log_model(model: BaseModel, prefix: str = "") -> None:
    """Log the details of a Pydantic model"""
    if not model:
        logger.info(f"{prefix} Model is None")
        return
        
    try:
        # Convert to dict and log
        model_dict = model.model_dump() if hasattr(model, 'model_dump') else model.dict()
        
        # Remove large data fields
        if 'upload_metadata' in model_dict and model_dict['upload_metadata']:
            metadata_size = len(str(model_dict['upload_metadata']))
            model_dict['upload_metadata'] = f"<{metadata_size} bytes of metadata>"
            
        logger.info(f"{prefix} {model.__class__.__name__}: {model_dict}")
    except Exception as e:
        logger.error(f"Error logging model: {str(e)}")

def tus_response_headers(response: Response, upload_id: Optional[str] = None, upload_offset: Optional[int] = None, expiry: Optional[datetime] = None):
    """Add standard Tus response headers to a response"""
    response.headers["Tus-Resumable"] = TUS_VERSION
    response.headers["Tus-Version"] = TUS_VERSION
    response.headers["Tus-Extension"] = TUS_EXTENSIONS
    response.headers["Tus-Max-Size"] = str(TUS_MAX_SIZE)
    
    if upload_id:
        location = f"{TUS_API_PATH}/{upload_id}"
        response.headers["Location"] = location
        
    if upload_offset is not None:
        response.headers["Upload-Offset"] = str(upload_offset)
        
    if expiry:
        response.headers["Upload-Expires"] = expiry.strftime("%a, %d %b %Y %H:%M:%S GMT")

# Tus protocol endpoints

@router.options(
    "/",
    include_in_schema=True,
)
async def tus_options(response: Response):
    """
    Handle OPTIONS request - Tus discovery endpoint
    
    Returns information about the Tus server capabilities
    """
    logger.info("Tus OPTIONS request received")
    
    # Add Tus headers
    tus_response_headers(response)
    
    response.status_code = 204
    return response

@router.post(
    "/",
    status_code=201,
    include_in_schema=True,
)
async def tus_create_upload(
    request: Request,
    response: Response,
    background_tasks: BackgroundTasks,
    user_id: Optional[str] = Depends(hybrid_auth),
    project_name: str = Depends(get_project_name),
    upload_metadata: Optional[str] = Header(None),
    upload_length: Optional[int] = Header(None),
    upload_defer_length: Optional[int] = Header(None),
    content_type: Optional[str] = Header(None),
    content_length: Optional[int] = Header(None)
):
    """
    Handle POST request - Create a new upload
    
    This endpoint creates a new upload and returns its location
    """
    logger.info("Tus upload creation request received")
    
    # Validate Tus version
    if request.headers.get("Tus-Resumable") != TUS_VERSION:
        response.status_code = 412
        response.headers["Tus-Version"] = TUS_VERSION
        return {"error": "Tus version not supported"}
    
    # Validate upload length
    if upload_length is None and upload_defer_length is None:
        response.status_code = 412
        tus_response_headers(response)
        return {"error": "Upload-Length or Upload-Defer-Length required"}
    
    if upload_length is not None and upload_length > TUS_MAX_SIZE:
        response.status_code = 413
        tus_response_headers(response)
        return {"error": "Upload size exceeds maximum allowed"}
    
    # Parse metadata
    metadata = await tus_controller.parse_metadata(upload_metadata or "")
    
    # Get filename from metadata
    filename = metadata.get("filename", f"upload-{uuid.uuid4()}")
    
    # Extract tags from metadata if available
    tags = None
    if metadata.get("tags"):
        try:
            if isinstance(metadata["tags"], str):
                # Split comma-separated tags
                tags = [tag.strip() for tag in metadata["tags"].split(',') if tag.strip()]
            elif isinstance(metadata["tags"], list):
                tags = metadata["tags"]
            # Limit to 3 tags
            if tags and len(tags) > 3:
                tags = tags[:3]
        except Exception as e:
            logger.warning(f"Error processing tags from metadata: {str(e)}")
    
    # Calculate expiration
    expires_in = timedelta(seconds=DEFAULT_EXPIRATION)
    
    # Log the authenticated user
    logger.info(f"TUS create_upload - authenticated user_id: {user_id}")
    
    # Create the upload
    upload_response = await tus_controller.create_upload(
        request=request,
        filename=filename,
        file_size=upload_length or 0,
        metadata=metadata,
        user_id=user_id,
        project_name=project_name,
        content_type=content_type,
        expires_in=expires_in,
        tags=tags
    )
    
    # Log the response model for debugging
    log_model(upload_response, "Upload created:")
    
    # Set Tus response headers
    tus_response_headers(
        response=response, 
        upload_id=str(upload_response.upload_id),
        expiry=upload_response.expires_at
    )
    
    # Add Upload-Expires header
    if upload_response.expires_at:
        response.headers["Upload-Expires"] = upload_response.expires_at.strftime("%a, %d %b %Y %H:%M:%S GMT")
    
    # Handle creation-with-upload extension
    if content_length and content_length > 0:
        # Read the body
        body = await request.body()
        
        # Process the chunk
        await tus_controller.process_chunk(
            upload_id=upload_response.upload_id,
            chunk_data=body,
            content_length=content_length,
            offset=0
        )
        
        # Set the offset header
        response.headers["Upload-Offset"] = str(content_length)
    
    response.status_code = 201
    return response

@router.head(
    "/{upload_id}",
    include_in_schema=True,
)
async def tus_upload_info(
    response: Response,
    upload_id: str = Path(...),
):
    """
    Handle HEAD request - Get upload info
    
    This endpoint returns information about an existing upload
    """
    logger.info(f"Tus HEAD request for upload: {upload_id}")
    
    # Get the upload info
    upload = await tus_controller.get_upload_info(upload_id)
    
    # Set Tus response headers
    tus_response_headers(
        response=response,
        upload_id=str(upload.id),
        upload_offset=upload.uploaded_size,
        expiry=upload.expires_at
    )
    
    # Add custom headers
    response.headers["Upload-Length"] = str(upload.total_size)
    response.headers["Upload-Metadata"] = ""  # We could reconstruct this if needed
    
    # Cache control to prevent caching
    response.headers["Cache-Control"] = "no-store"
    
    response.status_code = 200
    return response

@router.patch(
    "/{upload_id}",
    include_in_schema=True,
)
async def tus_upload_chunk(
    request: Request,
    response: Response,
    background_tasks: BackgroundTasks,
    upload_id: str = Path(...),
    content_type: Optional[str] = Header(None),
    content_length: Optional[int] = Header(None),
    upload_offset: Optional[int] = Header(None),
):
    """
    Handle PATCH request - Upload a chunk
    
    This endpoint accepts a chunk of data for an existing upload
    """
    logger.info(f"Tus PATCH request for upload: {upload_id}, offset: {upload_offset}")
    
    # Validate Tus version
    if request.headers.get("Tus-Resumable") != TUS_VERSION:
        response.status_code = 412
        response.headers["Tus-Version"] = TUS_VERSION
        return {"error": "Tus version not supported"}
    
    # Validate content type
    if content_type != "application/offset+octet-stream":
        response.status_code = 415
        tus_response_headers(response)
        return {"error": "Content-Type must be application/offset+octet-stream"}
    
    # Validate upload offset
    if upload_offset is None:
        response.status_code = 412
        tus_response_headers(response)
        return {"error": "Upload-Offset header required"}
    
    # Validate content length
    if not content_length or content_length <= 0:
        response.status_code = 412
        tus_response_headers(response)
        return {"error": "Content-Length header required"}
    
    # Get upload info to check current offset
    upload = await tus_controller.get_upload_info(upload_id)
    
    # Verify the offset matches
    if upload.uploaded_size != upload_offset:
        response.status_code = 409
        tus_response_headers(response, upload_id=str(upload.id), upload_offset=upload.uploaded_size)
        return {"error": f"Upload offset does not match: expected {upload.uploaded_size}, got {upload_offset}"}
    
    # Read the chunk data
    chunk_data = await request.body()
    
    # Verify the chunk size matches content length
    if len(chunk_data) != content_length:
        response.status_code = 412
        tus_response_headers(response)
        return {"error": "Content-Length does not match actual data length"}
    
    try:
        # Process the chunk
        patch_response = await tus_controller.process_chunk(
            upload_id=upload_id,
            chunk_data=chunk_data,
            content_length=content_length,
            offset=upload_offset,
            background_tasks=background_tasks
        )
        
        # Set Tus response headers
        tus_response_headers(
            response=response,
            upload_id=str(patch_response.upload_id),
            upload_offset=patch_response.offset,
            expiry=patch_response.expires_at
        )
        
        response.status_code = 204
        return response
    except HTTPException as e:
        # Re-raise HTTP exceptions as they already have proper status codes
        raise
    except Exception as e:
        logger.error(f"Error processing chunk for upload {upload_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error processing chunk: {str(e)}")

@router.delete(
    "/{upload_id}",
    include_in_schema=True,
)
async def tus_delete_upload(
    request: Request,
    response: Response,
    upload_id: str = Path(...),
):
    """
    Handle DELETE request - Terminate an upload
    
    This endpoint deletes an upload and all its chunks
    """
    logger.info(f"Tus DELETE request for upload: {upload_id}")
    
    # Validate Tus version
    if request.headers.get("Tus-Resumable") != TUS_VERSION:
        response.status_code = 412
        response.headers["Tus-Version"] = TUS_VERSION
        return {"error": "Tus version not supported"}
    
    # Delete the upload
    await tus_controller.delete_upload(upload_id)
    
    # Set Tus response headers
    tus_response_headers(response)
    
    response.status_code = 204
    return response

# Additional endpoints beyond Tus protocol spec

@router.get(
    "/",
    include_in_schema=True,
)
async def list_uploads(
    response: Response,
    user_id: Optional[str] = Depends(hybrid_auth),
    project_name: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    tags: Optional[List[str]] = Query(None),
    search: Optional[str] = Query(None),
    limit: int = Query(100, gt=0, le=1000),
    offset: int = Query(0, ge=0),
):
    """
    List uploads with optional filtering
    
    This endpoint allows listing and filtering uploads by different criteria including tags and text search
    """
    logger.info(f"List uploads request: user={user_id}, project={project_name}, status={status}, tags={tags}, search={search}")
    
    # Convert status string to enum if provided
    status_enum = None
    if status:
        try:
            status_enum = TusUploadStatus(status)
        except ValueError:
            response.status_code = 400
            return {"error": f"Invalid status value: {status}"}
    
    # List uploads
    uploads = await tus_controller.list_uploads(
        user_id=user_id,
        project_name=project_name,
        status=status_enum,
        tags=tags,
        search_text=search,
        limit=limit,
        offset=offset
    )
    
    # Set Tus response headers for consistency
    tus_response_headers(response)
    
    # Return the uploads as JSON
    return {
        "uploads": [upload.model_dump() for upload in uploads],
        "count": len(uploads),
        "limit": limit,
        "offset": offset
    }

@router.post(
    "/{upload_id}/finalize",
    include_in_schema=True,
)
async def finalize_upload(
    response: Response,
    background_tasks: BackgroundTasks,
    upload_id: str = Path(...),
):
    """
    Finalize an upload by assembling chunks
    
    This endpoint takes a completed upload and assembles the chunks into a single file
    """
    logger.info(f"Finalize upload request for: {upload_id}")
    
    # Finalize the upload
    result = await tus_controller.finalize_upload(upload_id)
    
    # Set Tus response headers for consistency
    tus_response_headers(response)
    
    # Get the upload info for response
    upload = await tus_controller.get_upload_info(upload_id)
    
    # Log the upload details
    log_model(upload, "Finalized upload:")
    
    # Log detailed S3 info
    if hasattr(upload, 's3_uri') and upload.s3_uri:
        logger.info(f"File stored in S3 at: Bucket={upload.s3_bucket}, Key={upload.s3_key}, URI={upload.s3_uri}")
        final_location = upload.s3_uri
    elif upload.upload_metadata.get("s3_uri"):
        logger.info(f"File stored in S3 at: URI={upload.upload_metadata.get('s3_uri')}")
        final_location = upload.upload_metadata.get("s3_uri")
    else:
        logger.info(f"File stored locally at: {result}")
        final_location = result
    
    # Return success with file information
    return {
        "upload_id": str(upload.id),
        "filename": upload.filename,
        "size": upload.total_size,
        "content_type": upload.content_type,
        "status": upload.status,
        "s3_uri": upload.s3_uri if hasattr(upload, 's3_uri') else None,
        "s3_bucket": upload.s3_bucket if hasattr(upload, 's3_bucket') else None,
        "s3_key": upload.s3_key if hasattr(upload, 's3_key') else None,
        "location": final_location,
        "storage_type": upload.upload_metadata.get("storage_type", "unknown")
    }

@router.post(
    "/{upload_id}/extend",
    include_in_schema=True,
)
async def extend_upload_expiration(
    response: Response,
    upload_id: str = Path(...),
    expires_in: int = Query(DEFAULT_EXPIRATION, description="Expiration time in seconds"),
):
    """
    Extend the expiration of an upload
    
    This endpoint extends the expiration time of an upload
    """
    logger.info(f"Extend expiration request for upload: {upload_id}, expires_in: {expires_in}")
    
    # Calculate expiration delta
    expires_delta = timedelta(seconds=expires_in)
    
    # Extend the expiration
    new_expiry = await tus_controller.extend_expiration(upload_id, expires_delta)
    
    # Set Tus response headers
    tus_response_headers(response, expiry=new_expiry)
    
    # Return success with new expiration
    return {
        "upload_id": upload_id,
        "expires_at": new_expiry.isoformat()
    }

@router.get(
    "/user/{user_id}/files",
    include_in_schema=True,
)
async def get_user_files_by_id(
    response: Response,
    user_id: str = Path(..., description="User ID to retrieve files for"),
    limit: int = Query(100, gt=0, le=1000),
    offset: int = Query(0, ge=0),
):
    """
    Get files for a specific user by user ID
    
    This endpoint returns all files uploaded by a specific user ID
    """
    logger.info(f"Request for files of user ID: {user_id}")
    
    # Get files for user
    uploads = await tus_controller.get_user_files(
        user_id=user_id,
        limit=limit,
        offset=offset
    )
    
    # Set Tus response headers for consistency
    tus_response_headers(response)
    
    # Return the files as JSON
    return {
        "user_id": user_id,
        "uploads": [upload.model_dump() for upload in uploads],
        "count": len(uploads),
        "limit": limit,
        "offset": offset
    }

@router.get(
    "/user/recent",
    include_in_schema=True,
)
async def get_recent_user_uploads(
    response: Response,
    user_id: str = Depends(hybrid_auth),
    limit: int = Query(10, gt=0, le=100),
    project_name: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    tags: Optional[List[str]] = Query(None),
    search: Optional[str] = Query(None),
):
    """
    Get recent uploads for the authenticated user
    
    This endpoint returns the user's most recent uploads, with optional filtering
    by tags and search text
    """
    logger.info(f"Get recent uploads for user: {user_id}, tags: {tags}, search: {search}")
    
    # Validate user is authenticated
    if not user_id:
        response.status_code = 401
        return {"error": "Authentication required"}
    
    # Convert status string to enum if provided
    status_enum = None
    if status:
        try:
            status_enum = TusUploadStatus(status)
        except ValueError:
            response.status_code = 400
            return {"error": f"Invalid status value: {status}"}
    
    # List uploads for the user
    uploads = await tus_controller.list_uploads(
        user_id=user_id,
        project_name=project_name,
        status=status_enum,
        tags=tags,
        search_text=search,
        limit=limit,
        offset=0
    )
    
    # Set Tus response headers for consistency
    tus_response_headers(response)
    
    # Return the uploads as JSON
    return {
        "user_id": user_id,
        "uploads": [upload.model_dump() for upload in uploads],
        "count": len(uploads)
    }
    
@router.put(
    "/{upload_id}/tags",
    include_in_schema=True,
)
async def update_upload_tags(
    response: Response,
    upload_id: str = Path(...),
    tags: List[str] = Query(..., max_items=3),
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """
    Update the tags for an upload
    
    This endpoint allows setting up to 3 tags on an upload for categorization and searching
    """
    logger.info(f"Update tags for upload: {upload_id}, tags: {tags}")
    
    # Log the authenticated user
    logger.info(f"Update tags - authenticated user_id: {user_id}")
    
    # Validate user is authenticated
    if not user_id:
        response.status_code = 401
        return {"error": "Authentication required"}
    
    try:
        # Get the upload
        upload = await tus_controller.get_upload_info(upload_id)
        
        # Check if user is authorized to modify this upload
        if upload.userid and str(upload.userid) != user_id:
            response.status_code = 403
            return {"error": "Not authorized to modify this upload"}
        
        # Update the tags (limit to 3)
        upload.tags = tags[:3] if len(tags) > 3 else tags
        upload.updated_at = datetime.now(timezone.utc)
        
        # Save the changes
        p8.repository(TusFileUpload).update_records([upload])
        
        # If the upload is in S3, update the metadata there too
        if (upload.upload_metadata.get("storage_type") == "s3" and 
            upload.upload_metadata.get("s3_uri")):
            # Update tags in metadata for S3 search compatibility
            upload.upload_metadata["tags"] = upload.tags
            p8.repository(TusFileUpload).update_records([upload])
        
        # Set Tus response headers for consistency
        tus_response_headers(response)
        
        # Return the updated upload
        return {
            "upload_id": str(upload.id),
            "tags": upload.tags,
            "updated_at": upload.updated_at.isoformat()
        }
 
    except Exception as e:
        logger.error(f"Error updating tags: {str(e)}")
        response.status_code = 500
        return {"error": f"Error updating tags: {str(e)}"}
        
@router.get(
    "/search/semantic",
    include_in_schema=True,
)
async def semantic_search(
    response: Response,
    query: str = Query(..., min_length=3),
    user_id: Optional[str] = Depends(hybrid_auth),
    project_name: Optional[str] = Query(None),
    tags: Optional[List[str]] = Query(None),
    limit: int = Query(10, gt=0, le=100),
):
    """
    Semantic search for files using natural language
    
    This endpoint allows searching for files using semantic similarity
    to the provided query. This is a placeholder for future semantic
    search implementation.
    """
    logger.info(f"Semantic search request: query={query}, user={user_id}, project={project_name}")
    
    # Set Tus response headers for consistency
    tus_response_headers(response)
    
    # For now, just use basic text search as a placeholder
    # In the future, this will use semantic embeddings to find similar content
    uploads = await tus_controller.list_uploads(
        user_id=user_id,
        project_name=project_name,
        tags=tags,
        search_text=query,
        limit=limit,
        offset=0
    )
    
    # Return with a note that this is a placeholder implementation
    return {
        "query": query,
        "results": [upload.model_dump() for upload in uploads],
        "count": len(uploads),
        "implementation": "placeholder_text_search",
        "note": "This is a placeholder for semantic search. Currently using basic text matching."
    }