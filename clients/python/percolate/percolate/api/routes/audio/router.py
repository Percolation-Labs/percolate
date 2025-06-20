"""
Audio router for the Percolate API.
Handles audio file uploading, processing, and management endpoints.
"""

import os
import json
import uuid
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, Depends, UploadFile, File, Form, HTTPException, BackgroundTasks
from fastapi.responses import JSONResponse

from percolate.api.controllers import audio as audio_controller
from percolate.models.media.audio import (
    AudioFile,
    AudioChunk,
    AudioUploadResponse,
    AudioProcessingStatus
)
from percolate.api.routes.auth import get_api_key
from percolate.utils import logger
import percolate as p8

router = APIRouter(
    dependencies=[Depends(get_api_key)],
    responses={404: {"description": "Not found"}},
)

# Helper functions

def parse_metadata(metadata_str: Optional[str]) -> Dict[str, Any]:
    """Parse JSON metadata string into a dictionary."""
    if not metadata_str:
        return {}
    
    try:
        return json.loads(metadata_str)
    except json.JSONDecodeError:
        raise HTTPException(status_code=400, detail="Invalid metadata format. Must be valid JSON.")

def validate_audio_file(file: UploadFile) -> None:
    """Validate that the uploaded file is an audio file."""
    content_type = file.content_type or ""
    if not content_type.startswith("audio/") and not content_type.startswith("video/"):
        raise HTTPException(
            status_code=400, 
            detail="File must be an audio file. Supported formats: MP3, WAV, AAC, OGG, FLAC."
        )

def get_test_data_chunks(file_id: str) -> List:
    """Try to load chunks from test data if available."""
    test_data_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__))))), 
        "test_data"
    )
    complete_record_path = os.path.join(test_data_dir, f"{file_id}_complete_record.json")
    
    if not os.path.exists(complete_record_path):
        return []
        
    try:
        logger.info(f"Found test data for file ID: {file_id}")
        with open(complete_record_path, 'r') as f:
            record = json.load(f)
            chunks_data = record.get('chunks', [])
            
            # Convert to AudioChunk models
            chunks = [AudioChunk(**chunk_data) for chunk_data in chunks_data]
            
            logger.info(f"Loaded {len(chunks)} chunks from test data")
            return chunks
    except Exception as e:
        logger.error(f"Error loading test data: {e}")
        return []

def get_chunks_from_db(file_id: str) -> List:
    """Get audio chunks from the database for a file."""
    try:
        logger.debug(f"Querying for chunks with audio_file_id: {file_id}")
        chunks = p8.repository(AudioChunk).select(audio_file_id=file_id, order_by="start_time")
        logger.info(f"Found {len(chunks)} chunks in the database")
        return chunks
    except Exception as e:
        logger.error(f"Error getting chunks from database: {str(e)}")
        return []

def process_chunk_for_response(chunk) -> Dict:
    """Convert a chunk to a dictionary for API response."""
    try:
        # Convert to dictionary if it's a model object
        if hasattr(chunk, 'model_dump'):
            chunk_dict = chunk.model_dump()
        elif isinstance(chunk, dict):
            chunk_dict = chunk
        else:
            # Convert to AudioChunk object first
            chunk_dict = AudioChunk(**chunk).model_dump()
        
        # Get metadata if available
        metadata = chunk_dict.get('metadata', {}) or {}
        
        # Check if there's an error in metadata
        error = metadata.get('error', '')
        transcription_status = metadata.get('transcription_status', '')
        
        # Get the transcription
        transcription = chunk_dict.get('transcription', '')
        
        # If there's an error and no transcription, add a status note
        if error and transcription_status == 'failed' and not transcription:
            transcription_note = f"[Transcription failed]"
        else:
            transcription_note = transcription
        
        # Return a standardized format
        response = {
            "id": str(chunk_dict.get('id', '')),
            "start_time": chunk_dict.get('start_time', 0),
            "end_time": chunk_dict.get('end_time', 0),
            "duration": chunk_dict.get('duration', 0),
            "transcription": transcription_note,
            "confidence": chunk_dict.get('confidence', 0)
        }
        
        # Add error information if available
        if error:
            response["error"] = error
            response["transcription_status"] = transcription_status
            
        return response
    except Exception as e:
        logger.error(f"Error processing chunk: {str(e)}")
        return {
            "id": "error",
            "start_time": 0,
            "end_time": 0,
            "duration": 0,
            "transcription": "",
            "error": f"Error processing chunk: {str(e)}",
            "transcription_status": "error",
            "confidence": 0
        }

def create_placeholder_chunk(file_id: str) -> Dict:
    """Create a placeholder chunk when no chunks are found."""
    placeholder_duration = 30.0
    placeholder_id = str(uuid.uuid4())
    placeholder_transcription = "No transcription available - this is a placeholder"
    
    # Try to save this placeholder to the database
    try:
        placeholder_chunk = AudioChunk(
            id=placeholder_id,
            audio_file_id=file_id,
            start_time=0.0,
            end_time=placeholder_duration,
            duration=placeholder_duration,
            s3_uri=f"file://placeholder/{placeholder_id}.wav",
            transcription=placeholder_transcription,
            confidence=0.0
        )
        p8.repository(AudioChunk).update_records([placeholder_chunk])
        logger.info(f"Saved placeholder chunk to database: {placeholder_id}")
    except Exception as e:
        logger.error(f"Error saving placeholder chunk: {str(e)}")
    
    return {
        "id": placeholder_id,
        "start_time": 0.0,
        "end_time": placeholder_duration,
        "duration": placeholder_duration,
        "transcription": placeholder_transcription,
        "confidence": 0.0
    }

# API Endpoints

@router.post("/upload", response_model=AudioUploadResponse)
async def upload_audio(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    project_name: str = Form(...),
    metadata: Optional[str] = Form(None),
    user_id: Optional[str] = Form(None),
    file_key: Optional[str] = Form(None),
    process_audio: bool = Form(True)
):
    """
    Upload an audio file for processing.
    
    This endpoint accepts a streaming upload of audio files and stores them
    temporarily in S3. The file will be queued for processing through the
    audio pipeline.
    
    - **file**: The audio file to upload
    - **project_name**: The project to associate the file with
    - **metadata**: Optional JSON metadata to store with the file
    - **user_id**: Optional user ID to associate with the file
    - **process_audio**: Whether to process the audio file after upload (default: True)
    """
    validate_audio_file(file)
    parsed_metadata = parse_metadata(metadata)
    
    # Use the provided user_id or a default
    req_user_id = user_id or "api-key-user"
    
    try:
        response = await audio_controller.upload_audio_file(
            file=file,
            user_id=req_user_id,
            project_name=project_name,
            metadata=parsed_metadata,
            file_key=file_key
        )
        
        # Start processing in background if requested
        if process_audio:
            logger.info(f"Starting background audio processing for file: {response.file_id}")
            
            # Get storage type from file's metadata
            use_s3 = True  # Default to using S3
            try:
                file = await audio_controller.get_audio_file(response.file_id)
                if hasattr(file, 'metadata') and file.metadata and 'use_s3' in file.metadata:
                    use_s3 = file.metadata.get('use_s3', True)
                    logger.info(f"Using storage mode from metadata: use_s3={use_s3}")
            except Exception as e:
                logger.warning(f"Could not retrieve storage mode from metadata: {str(e)}. Using default: use_s3={use_s3}")
            
            # Add task to background_tasks    
            background_tasks.add_task(
                audio_controller.process_audio_file,
                response.file_id,
                req_user_id,
                use_s3
            )
            logger.info(f"Background processing task queued for file: {response.file_id}")
        
        return response
    except Exception as e:
        logger.error(f"Error uploading file: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Error uploading file: {str(e)}")

@router.get("/files/{file_id}", response_model=AudioFile)
async def get_audio_file(file_id: str):
    """
    Get details about an audio file by ID.
    
    - **file_id**: The ID of the audio file
    """
    try:
        return await audio_controller.get_audio_file(file_id)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error retrieving file: {str(e)}")

@router.get("/files", response_model=List[AudioFile])
async def list_audio_files(project_name: str):
    """
    List all audio files for a project.
    
    - **project_name**: The project to list files for
    """
    try:
        # Use test user ID since we're using API key auth
        user_id = "api-key-user"
        return await audio_controller.list_project_audio_files(project_name, user_id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error listing files: {str(e)}")

@router.delete("/files/{file_id}")
async def delete_audio_file(file_id: str, background_tasks: BackgroundTasks):
    """
    Delete an audio file and all its processed data.
    
    - **file_id**: The ID of the audio file to delete
    """
    try:
        # Get the file to verify it exists
        await audio_controller.get_audio_file(file_id)
        
        # Delete the file in the background
        background_tasks.add_task(audio_controller.delete_audio_file, file_id)
        logger.info(f"Background deletion task queued for file: {file_id}")
        
        return JSONResponse(content={"message": "File deletion initiated", "file_id": file_id})
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error deleting file: {str(e)}")

@router.get("/status/{file_id}")
async def get_processing_status(file_id: str):
    """
    Get the current processing status of an audio file.
    
    - **file_id**: The ID of the audio file
    """
    try:
        file = await audio_controller.get_audio_file(file_id)
        
        # Extract metadata with defaults
        metadata = file.metadata or {}
        
        return {
            "file_id": str(file.id),
            "status": file.status,
            "progress": metadata.get("progress", 0),
            "error": metadata.get("error", None),
            "queued_at": metadata.get("queued_at", None)
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error getting status: {str(e)}")

@router.post("/reprocess/{file_id}")
async def reprocess_file(file_id: str, background_tasks: BackgroundTasks, user_id: Optional[str] = None):
    """
    Re-process an audio file that previously failed.
    
    This endpoint resets the status of a failed file to UPLOADED
    and resubmits it to the processing queue.
    
    - **file_id**: The ID of the audio file to reprocess
    """
    try:
        logger.info(f"Reprocessing audio file: {file_id}")
        
        # Get the file
        file = await audio_controller.get_audio_file(file_id)
        
        # Reset file status
        file.status = AudioProcessingStatus.UPLOADED
        if "error" in file.metadata:
            del file.metadata["error"]
        
        # Update file and resubmit for processing
        await audio_controller.update_audio_file(file)
        background_tasks.add_task(audio_controller.process_audio_file, file_id, user_id)
        
        return {"message": f"File {file_id} resubmitted for processing", "status": "QUEUED"}
    except HTTPException:
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
        
        chunks = get_chunks_from_db(file_id)
        processed_chunks = []
        full_text_segments = []
        
        for chunk in chunks:
            chunk_dict = process_chunk_for_response(chunk)
            processed_chunks.append(chunk_dict)
            
            transcription = chunk_dict.get('transcription', '')
            # Only add non-empty transcriptions to the full text
            if transcription and not (transcription.startswith('[') and transcription.endswith(']')):
                start_time = chunk_dict.get('start_time', 0)
                end_time = chunk_dict.get('end_time', 0)
                full_text_segments.append(f"[{start_time:.2f}s - {end_time:.2f}s]: {transcription}")
            # If there's an error, add a placeholder noting the failure
            elif 'error' in chunk_dict:
                start_time = chunk_dict.get('start_time', 0)
                end_time = chunk_dict.get('end_time', 0)
                # Don't add the actual error message to the transcript
                full_text_segments.append(f"[{start_time:.2f}s - {end_time:.2f}s]: [Transcription unavailable]")
        
        # Add placeholder if no chunks found
        if not processed_chunks:
            placeholder = create_placeholder_chunk(file_id)
            processed_chunks.append(placeholder)
            full_text_segments.append(placeholder["transcription"])
        
        # Compile full transcription
        full_text = "\n\n".join(full_text_segments)
        
        return {
            "file_id": str(file.id),
            "status": file.status,
            "chunks": processed_chunks,
            "transcription": full_text,
            "metadata": file.metadata
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error retrieving transcription: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Error retrieving transcription: {str(e)}")

@router.post("/chunks/{chunk_id}/update")
async def update_chunk_transcription(
    chunk_id: str, 
    transcription: str = Form(...),
    confidence: float = Form(0.0)
):
    """
    Update the transcription of an audio chunk.
    
    - **chunk_id**: The ID of the audio chunk to update
    - **transcription**: The new transcription text
    - **confidence**: Optional confidence score (0.0-1.0)
    """
    try:
        success = await audio_controller.update_transcription(chunk_id, transcription, confidence)
        if success:
            return {"message": "Transcription updated successfully", "chunk_id": chunk_id}
        else:
            raise HTTPException(status_code=400, detail="Failed to update transcription")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error updating transcription: {str(e)}")

@router.get("/chunks/{file_id}")
async def get_file_chunks(file_id: str):
    """
    Get all chunks for an audio file.
    
    - **file_id**: The ID of the audio file
    """
    try:
        chunks = await audio_controller.get_audio_chunks(file_id)
        return [process_chunk_for_response(chunk) for chunk in chunks]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error retrieving chunks: {str(e)}")

# Admin endpoints

@router.post("/admin/register-models", include_in_schema=False)
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