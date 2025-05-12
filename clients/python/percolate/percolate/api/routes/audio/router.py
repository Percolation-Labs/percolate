"""
Audio router for the Percolate API.
Handles audio file uploading, processing, and management endpoints.
"""

from typing import List, Optional, Dict, Any
from fastapi import APIRouter, Depends, UploadFile, File, Form, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse

from percolate.api.controllers import audio as audio_controller
from percolate.models.media.audio import (
    AudioFile,
    AudioUploadResponse,
    AudioProcessingStatus
)
from percolate.api.routes.auth import get_api_key
import logging

# Configure logger
logger = logging.getLogger("audio.router")
logger.setLevel(logging.DEBUG)

router = APIRouter(
    dependencies=[Depends(get_api_key)],
    responses={404: {"description": "Not found"}},
)

@router.post("/upload", response_model=AudioUploadResponse)
async def upload_audio(
    file: UploadFile = File(...),
    project_name: str = Form(...),
    metadata: Optional[str] = Form(None),
    user_id: Optional[str] = Form(None)
):
    """
    Upload an audio file for processing.
    
    This endpoint accepts a streaming upload of audio files and stores them
    temporarily in S3. The file will be queued for processing through the
    audio pipeline.
    
    - **file**: The audio file to upload
    - **project_name**: The project to associate the file with
    - **metadata**: Optional JSON metadata to store with the file
    """
    # Parse metadata if provided
    parsed_metadata = {}
    if metadata:
        import json
        try:
            parsed_metadata = json.loads(metadata)
        except json.JSONDecodeError:
            raise HTTPException(status_code=400, detail="Invalid metadata format. Must be valid JSON.")
    
    # Check if file is an audio file
    content_type = file.content_type or ""
    if not content_type.startswith("audio/") and not content_type.startswith("video/"):
        raise HTTPException(
            status_code=400, 
            detail="File must be an audio file. Supported formats: MP3, WAV, AAC, OGG, FLAC."
        )
    
    # Use the provided user_id or a default if not provided
    req_user_id = user_id or "api-key-user"
    
    # Upload the file using the controller
    try:
        response = await audio_controller.upload_audio_file(
            file=file,
            user_id=req_user_id,
            project_name=project_name,
            metadata=parsed_metadata
        )
        return response
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error uploading file: {str(e)}")

@router.get("/files/{file_id}", response_model=AudioFile)
async def get_audio_file(
    file_id: str
):
    """
    Get details about an audio file by ID.
    
    - **file_id**: The ID of the audio file
    """
    try:
        file = await audio_controller.get_audio_file(file_id)
        return file
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error retrieving file: {str(e)}")

@router.get("/files", response_model=List[AudioFile])
async def list_audio_files(
    project_name: str
):
    """
    List all audio files for a project.
    
    - **project_name**: The project to list files for
    """
    try:
        # Use test user ID since we're using API key auth
        user_id = "api-key-user"
        files = await audio_controller.list_project_audio_files(
            project_name=project_name,
            user_id=user_id
        )
        return files
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error listing files: {str(e)}")

@router.delete("/files/{file_id}")
async def delete_audio_file(
    file_id: str,
    background_tasks: BackgroundTasks
):
    """
    Delete an audio file and all its processed data.
    
    - **file_id**: The ID of the audio file to delete
    """
    try:
        # Get the file
        file = await audio_controller.get_audio_file(file_id)
        
        # Delete the file in the background
        background_tasks.add_task(audio_controller.delete_audio_file, file_id)
        
        return JSONResponse(content={"message": "File deletion initiated", "file_id": file_id})
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error deleting file: {str(e)}")

@router.get("/status/{file_id}")
async def get_processing_status(
    file_id: str
):
    """
    Get the current processing status of an audio file.
    
    - **file_id**: The ID of the audio file
    """
    try:
        file = await audio_controller.get_audio_file(file_id)
        
        # Convert the UUID to string to ensure it's JSON serializable
        file_id_str = str(file.id) if file.id else file_id
        
        # Get metadata values with defaults
        progress = file.metadata.get("progress", 0) if hasattr(file, "metadata") and file.metadata else 0
        error = file.metadata.get("error", None) if hasattr(file, "metadata") and file.metadata else None
        queued_at = file.metadata.get("queued_at", None) if hasattr(file, "metadata") and file.metadata else None
        
        # Build the response
        response = {
            "file_id": file_id_str,
            "status": file.status if hasattr(file, "status") else "unknown",
            "progress": progress,
            "error": error,
            "queued_at": queued_at
        }
        
        return response
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error getting status: {str(e)}")

@router.post("/reprocess/{file_id}")
async def reprocess_file(file_id: str, background_tasks: BackgroundTasks, user_id: Optional[str] = None):
    """
    Re-process an audio file that previously failed.
    
    This endpoint resets the status of a failed file to UPLOADED
    and resubmits it to the processing queue.
    
    Args:
        file_id: The ID of the audio file to reprocess
    """
    try:
        logger.info(f"Reprocessing audio file: {file_id}")
        
        # Get the file
        file = await audio_controller.get_audio_file(file_id)
        
        if not file:
            logger.error(f"File not found: {file_id}")
            raise HTTPException(status_code=404, detail=f"File not found")
        
        # Reset file status
        file.status = AudioProcessingStatus.UPLOADED
        if "error" in file.metadata:
            del file.metadata["error"]
        
        # Update file
        logger.info(f"Resetting file {file_id} status to UPLOADED")
        await audio_controller.update_audio_file(file)
        
        # Resubmit for processing
        logger.info(f"Resubmitting file {file_id} for processing")
        background_tasks.add_task(audio_controller.process_audio_file, file_id, user_id)
        logger.info(f"File {file_id} resubmitted for processing with user_id: {user_id}")
        
        return {"message": f"File {file_id} resubmitted for processing", "status": "QUEUED"}
    except HTTPException:
        # Re-raise HTTP exceptions
        raise
    except Exception as e:
        logger.error(f"Error reprocessing file {file_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error reprocessing file: {str(e)}")

@router.get("/transcription/{file_id}")
async def get_transcription(file_id: str):
    """
    Get the transcription of an audio file.
    
    This endpoint retrieves the transcription of a processed audio file,
    including the text content and metadata about each chunk.
    
    - **file_id**: The ID of the audio file
    """
    try:
        # Get the audio file
        file = await audio_controller.get_audio_file(file_id)
        
        # Get the chunks with transcriptions
        chunks = file.chunks or []
        
        # Compile the full transcription
        full_text = "\n\n".join([
            f"[{chunk.start_time:.2f}s - {chunk.end_time:.2f}s]: {chunk.transcription}"
            for chunk in chunks
            if chunk.transcription
        ])
        
        return {
            "file_id": str(file.id),
            "status": file.status,
            "chunks": [
                {
                    "id": str(chunk.id),
                    "start_time": chunk.start_time,
                    "end_time": chunk.end_time,
                    "duration": chunk.duration,
                    "transcription": chunk.transcription,
                    "confidence": chunk.confidence
                }
                for chunk in chunks
            ],
            "transcription": full_text,
            "metadata": file.metadata
        }
    except HTTPException as e:
        raise e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error retrieving transcription: {str(e)}")

@router.post("/admin/register-models")
async def register_models():
    """
    Register all audio models with the Percolate database.
    
    This endpoint is protected and should only be accessible to admin users.
    It manually triggers the model registration process which is normally
    done at application startup.
    """
    try:
        # Import the registration function from models
        from percolate.models.media.audio import register_audio_models
        
        # Register models
        results = register_audio_models()
        
        return {
            "message": "Audio models registration completed",
            "results": results
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error registering models: {str(e)}")