"""
Audio controller for the Percolate API.
Handles audio file uploading, processing, and management.
"""

import os
import uuid
import json
import shutil
import tempfile
import asyncio
from typing import Optional, Dict, Any, List
from datetime import datetime, timezone
from fastapi import HTTPException, UploadFile
from percolate.utils import make_uuid
import percolate as p8
from percolate.utils import logger
from percolate.services.S3Service import S3Service
from percolate.models.media.audio import (
    AudioFile, 
    AudioChunk, 
    AudioProcessingStatus,
    AudioUploadResponse,
    AudioPipelineConfig,
    AudioPipeline,
    AudioResource
)

# Specify field names to ensure schema compatibility
AUDIO_FILE_FIELDS = "id, userid, project_name, filename, file_size, content_type, duration, upload_date, status, s3_uri, metadata"

# Get the S3 bucket from environment or use default
S3_AUDIO_BUCKET = os.environ.get("S3_AUDIO_BUCKET", "percolate-audio")

async def upload_audio_file(
    file: UploadFile, 
    user_id: Optional[str], 
    project_name: str,
    metadata: Optional[Dict[str, Any]] = None,
    use_s3: bool = True,
    file_key:Optional[str] = None
) -> AudioUploadResponse:
    """
    Upload an audio file to S3 and create an AudioFile record.
    
    Args:
        file: The uploaded file
        user_id: The ID of the user uploading the file (must be a valid UUID)
        project_name: The project name for organizing storage
        metadata: Optional metadata to store with the file
        use_s3: Whether to use S3 for storage (default: True)
        
    Returns:
        AudioUploadResponse with file details
    """
    # Validate user_id is a proper UUID if provided
    if user_id:
        try:
            uuid_obj = uuid.UUID(user_id)
            user_id = str(uuid_obj)  # Normalize the format
            logger.info(f"Using user ID: {user_id}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid user ID provided: {user_id} - will not associate with a user")
            user_id = None  # Reset to None if invalid
    logger.info(f"Starting audio upload: {file.filename}, size: {file.size}, content_type: {file.content_type}")
    
    # Create a temporary file to store the upload
    with tempfile.NamedTemporaryFile(delete=False) as temp_file:
        # Copy content from the uploaded file to the temporary file
        logger.debug("Creating temporary file for upload")
        shutil.copyfileobj(file.file, temp_file)
        temp_file_path = temp_file.name
        logger.debug(f"Temporary file created at: {temp_file_path}")
    
    try:
       
        file_size = os.path.getsize(temp_file_path)
        
        file_id = str(uuid.uuid4()) if not file_key else make_uuid({'file_key': file_key, 'user_id':user_id})
        
        # Initialize with uploading status first
        audio_file = AudioFile(
            id=file_id,
            userid=user_id,
            project_name=project_name,
            filename=file.filename,
            file_size=file_size,
            content_type=file.content_type or "audio/wav",  # Default if not provided
            status=AudioProcessingStatus.UPLOADING,
            s3_uri="",  # Will be set after upload
            metadata=metadata or {}
        )
        
        # Save the initial record to the database
        logger.info(f"Creating audio file record in database: id={file_id}, project={project_name}")
        try:
            p8.repository(AudioFile).update_records([audio_file])
            logger.debug("Successfully created audio file record")
        except Exception as db_error:
            logger.error(f"Error creating audio file record: {str(db_error)}")
            raise HTTPException(status_code=500, detail=f"Database error: {str(db_error)}")
        
        s3_uri = ""
        
        # Upload to S3 or store locally based on preference
        if use_s3:
            try:
                logger.info("Using S3 for file storage")
                s3_service = S3Service()
                
                # Upload the file to S3
                # Build the S3 key
                s3_key = f"{project_name}/audio/{file_id}/{file.filename}"
                s3_uri = f"s3://{s3_service.default_bucket}/{s3_key}"
                
                upload_result = s3_service.upload_file_to_uri(
                    s3_uri=s3_uri,
                    file_path_or_content=temp_file_path,
                    content_type=file.content_type or "audio/wav"
                )
                
                # Get the S3 URI from the upload result
                s3_uri = upload_result.get("uri")
                if not s3_uri:
                    # Construct URI if not provided by the service
                    s3_uri = f"s3://{s3_service.default_bucket}/{project_name}/audio/{file_id}/{file.filename}"
                
                logger.info(f"File uploaded to S3: {s3_uri}")
                audio_file.s3_uri = s3_uri
                audio_file.metadata["storage_type"] = "s3"
                
            except Exception as s3_error:
                logger.error(f"Error uploading to S3: {str(s3_error)}", exc_info=True)
                logger.warning("Falling back to local storage")
                use_s3 = False
        
        # Use local storage if S3 is disabled or failed
        if not use_s3:
            logger.info("Using local storage for file")
            permanent_dir = os.path.join(tempfile.gettempdir(), "percolate_audio_storage")
            os.makedirs(permanent_dir, exist_ok=True)
            permanent_path = os.path.join(permanent_dir, f"{file_id}_{file.filename}")
            
            try:
                logger.info(f"Copying temp file to permanent location: {permanent_path}")
                shutil.copy(temp_file_path, permanent_path)
                
                # Set the file URI to point to the local path
                s3_uri = f"file://{permanent_path}"
                audio_file.s3_uri = s3_uri
                audio_file.metadata["storage_type"] = "local"
                audio_file.metadata["local_path"] = permanent_path
                
                logger.info("File successfully copied to permanent location")
            except Exception as copy_error:
                logger.error(f"Error copying file to permanent location: {str(copy_error)}", exc_info=True)
                raise HTTPException(status_code=500, detail="Failed to store audio file")
        
        # Update the file status
        logger.info("Updating file status to UPLOADED")
        audio_file.status = AudioProcessingStatus.UPLOADED
        try:
            p8.repository(AudioFile).update_records([audio_file])
            logger.debug("File status updated successfully")
        except Exception as update_error:
            logger.error(f"Error updating file status: {str(update_error)}")
            raise HTTPException(status_code=500, detail="Failed to update file status")
                
        # Store storage type in metadata for background processing
        if not hasattr(audio_file, 'metadata') or audio_file.metadata is None:
            audio_file.metadata = {}
        audio_file.metadata["use_s3"] = use_s3
        
        # Update record to save the storage type
        try:
            p8.repository(AudioFile).update_records([audio_file])
        except Exception as e:
            logger.warning(f"Could not save storage type to metadata: {str(e)}")
        return AudioUploadResponse(
            file_id=audio_file.id,
            filename=audio_file.filename,
            status=audio_file.status,
            s3_uri=audio_file.s3_uri
        )
    
    finally:
        # Clean up the temporary file
        if os.path.exists(temp_file_path):
            os.unlink(temp_file_path)
            logger.debug(f"Removed temporary file: {temp_file_path}")

async def process_audio_file(file_id: str, user_id: Optional[str] = None, use_s3: bool = True) -> None:
    """
    Process an uploaded audio file asynchronously.
    
    Args:
        file_id: The ID of the audio file to process
        user_id: Optional user ID to associate with processed chunks (must be a valid UUID)
        use_s3: Whether to use S3 for storage (default: True)
    """
    logger.info(f"Processing audio file: {file_id} (use_s3={use_s3})")
 
    # Get the audio file - make sure we're always using string IDs
    file_id_str = str(file_id)
    
    # Validate user_id is a proper UUID if provided
    if user_id:
        try:
            uuid_obj = uuid.UUID(user_id)
            user_id = str(uuid_obj)  # Normalize the format
            logger.info(f"Using provided user ID: {user_id}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid user ID provided: {user_id} - will not associate chunks with a user")
            user_id = None  # Reset to None if invalid
    
    try:
        audio_file = p8.repository(AudioFile).get_by_id(id=file_id_str, as_model=True)
    except Exception as get_error:
        logger.error(f"Error retrieving audio file {file_id}: {str(get_error)}")
        return
    
    if not audio_file:
        logger.warning(f"Audio file {file_id} not found for processing")
        return
    
    # If no user_id is provided, try to use the one from the audio file (validating it's a UUID)
    if not user_id and hasattr(audio_file, 'userid') and audio_file.userid:
        try:
            # Validate the UUID from the audio file
            uuid_obj = uuid.UUID(str(audio_file.userid))
            user_id = str(uuid_obj)
            logger.info(f"Using userid from audio file: {user_id}")
        except (ValueError, TypeError):
            logger.warning(f"Invalid userid in audio file: {audio_file.userid} - will not associate chunks with a user")
            user_id = None
    
    # Update status to processing
    audio_file.status = AudioProcessingStatus.PROCESSING
    audio_file.metadata["queued_at"] = datetime.now(timezone.utc).isoformat()
    if user_id:
        audio_file.metadata["processed_by_user_id"] = user_id
    logger.info(f"Updating file {file_id} status to PROCESSING")
    p8.repository(AudioFile).update_records([audio_file])
    
    # Create a pipeline record
    pipeline = AudioPipeline(
        audio_file_id=file_id,
        status=AudioProcessingStatus.PROCESSING,
        config={"use_s3": use_s3}
    )
    p8.repository(AudioPipeline).update_records([pipeline])
    
    try:
        # Import and use the AudioProcessor
        from percolate.services.media.audio import AudioProcessor
        
        # Initialize the processor with appropriate storage mode
        processor = AudioProcessor(use_s3=use_s3)
        logger.info(f"Initialized AudioProcessor with use_s3={use_s3}")
        
        # Process the file with the user_id
        success = await processor.process_file(file_id, user_id)
        
        if success:
            # Update pipeline status
            pipeline.status = AudioProcessingStatus.COMPLETED
            pipeline.completed_at = datetime.now(timezone.utc)
            p8.repository(AudioPipeline).update_records([pipeline])
            
            # Double check if the file was properly processed by verifying chunks
            chunks = p8.repository(AudioChunk).select(audio_file_id=str(file_id))
            if not chunks:
                logger.warning(f"Audio processing completed but no chunks found for file {file_id}")
                
                # Update to warning status
                audio_file.status = AudioProcessingStatus.WARNING
                audio_file.metadata["warning"] = "No chunks were found after processing"
                p8.repository(AudioFile).update_records([audio_file])
            else:
                logger.info(f"Audio processing completed successfully with {len(chunks)} chunks for file {file_id}")
                
                # Update audio file with chunk count
                audio_file.metadata["chunk_count"] = len(chunks)
                p8.repository(AudioFile).update_records([audio_file])
        else:
            # Update pipeline status
            pipeline.status = AudioProcessingStatus.FAILED
            pipeline.error_message = "Processing failed"
            pipeline.completed_at = datetime.now(timezone.utc)
            p8.repository(AudioPipeline).update_records([pipeline])
            
            # Update file status too
            audio_file.status = AudioProcessingStatus.FAILED
            audio_file.metadata["error"] = "Processing failed"
            p8.repository(AudioFile).update_records([audio_file])
            
            logger.error(f"Audio processing failed for file {file_id}")
            
    except Exception as e:
        logger.error(f"Error processing audio file {file_id}: {str(e)}", exc_info=True)
        
        # Update the audio file status
        audio_file.status = AudioProcessingStatus.FAILED
        audio_file.metadata["error"] = str(e)
        p8.repository(AudioFile).update_records([audio_file])
        
        # Update pipeline status too
        pipeline.status = AudioProcessingStatus.FAILED
        pipeline.error_message = str(e)
        pipeline.completed_at = datetime.now(timezone.utc)
        p8.repository(AudioPipeline).update_records([pipeline])

async def update_transcription(chunk_id: str, transcription: str, confidence: float = 0.0) -> bool:
    """
    Update the transcription for an audio chunk.
    
    Args:
        chunk_id: The ID of the audio chunk
        transcription: The new transcription text
        confidence: Confidence score for the transcription (0.0-1.0)
        
    Returns:
        True if successful, False otherwise
    """
    logger.info(f"Updating transcription for chunk: {chunk_id}")
    
    try:
        # Get the chunk
        chunk = p8.repository(AudioChunk).get_by_id(id=chunk_id, as_model=True)
        if not chunk:
            logger.warning(f"Chunk {chunk_id} not found")
            return False
            
        # Update transcription and confidence
        chunk.transcription = transcription
        chunk.confidence = confidence
        chunk.updated_at = datetime.now(timezone.utc)
        
        # Save updates
        p8.repository(AudioChunk).update_records([chunk])
        logger.info(f"Successfully updated transcription for chunk {chunk_id}")
        
        return True
    except Exception as e:
        logger.error(f"Error updating transcription for chunk {chunk_id}: {str(e)}")
        return False

async def get_audio_file(file_id: str) -> AudioFile:
    """
    Get an audio file by ID.
    
    Args:
        file_id: The ID of the audio file
        
    Returns:
        AudioFile object
        
    Raises:
        HTTPException: If the file is not found
    """
    logger.info(f"Getting audio file with ID: {file_id}")
    
    # Special handling for test data
    test_data_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__)))), "test_data")
    complete_record_path = os.path.join(test_data_dir, f"{file_id}_complete_record.json")
    
    # Check if we have test data for this file ID
    if os.path.exists(complete_record_path):
        logger.info(f"Found test data for file ID: {file_id}")
        try:
            with open(complete_record_path, 'r') as f:
                record = json.load(f)
                file_data = record.get('file', {})
                
                # Convert to AudioFile model
                audio_file = AudioFile(**file_data)
                logger.debug(f"Created AudioFile model from test data: {file_id}")
                return audio_file
        except Exception as e:
            logger.error(f"Error loading test data: {e}")
            # Continue with normal database lookup
    
    try:
        audio_file = p8.repository(AudioFile).get_by_id(id=str(file_id), as_model=True)
        if not audio_file:
            logger.warning(f"Audio file with ID {file_id} not found")
            raise HTTPException(status_code=404, detail="Audio file not found")
            
        logger.debug(f"Found audio file with status: {audio_file.status}")
        return audio_file
    except Exception as e: 
        logger.error(f"Error retrieving audio file {file_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error retrieving audio file: {str(e)}")
        
async def get_audio_chunks(file_id: str) -> List[AudioChunk]:
    """
    Get all chunks for an audio file.
    
    Args:
        file_id: The ID of the audio file
        
    Returns:
        List of AudioChunk objects
    """
    logger.info(f"Getting chunks for audio file: {file_id}")
    
    # Get all chunks for this file, ordered by start_time
    chunks = p8.repository(AudioChunk).select(
        audio_file_id=file_id, 
        order_by="start_time"
    )
    
    logger.info(f"Found {len(chunks)} chunks for audio file {file_id}")
    return chunks

async def update_audio_file(audio_file: AudioFile) -> AudioFile:
    """
    Update an audio file in the database.
    
    Args:
        audio_file: The AudioFile object to update
        
    Returns:
        Updated AudioFile object
    """
    logger.info(f"Updating audio file with ID: {audio_file.id}")
    try:
        p8.repository(AudioFile).update_records([audio_file])
        logger.debug(f"Successfully updated audio file")
        return audio_file
    except Exception as e:
        logger.error(f"Error updating audio file {audio_file.id}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Error updating audio file: {str(e)}")

async def list_project_audio_files(project_name: str, user_id: Optional[str] = None) -> List[AudioFile]:
    """
    List all audio files for a project.
    
    Args:
        project_name: The name of the project
        user_id: Optional user ID to filter by
        
    Returns:
        List of AudioFile objects
    """
    logger.info(f"Listing audio files for project: {project_name}, user: {user_id or 'any'}")
    
    # Build query based on provided parameters
    query = {"project_name": project_name}
    if user_id:
        # Use explicit SQL query to ensure we're using the right field based on DB schema
        files = p8.repository(AudioFile).execute(
            f"SELECT {AUDIO_FILE_FIELDS} FROM public.\"AudioFile\" WHERE project_name = %s AND userid = %s ORDER BY upload_date DESC",
            data=(project_name, user_id)
        )
        return [AudioFile(**file) for file in files]
        
    # Include order by upload_date desc to show newest first
    files = p8.repository(AudioFile).select(**query, order_by="-upload_date")
    
    logger.info(f"Found {len(files)} audio files")
    return files
 
async def delete_audio_file(file_id: str) -> bool:
    """
    Delete an audio file and all associated chunks.
    
    Args:
        file_id: The ID of the audio file
        
    Returns:
        True if successful
        
    Raises:
        HTTPException: If the file is not found
    """
    logger.info(f"Deleting audio file: {file_id}")
    
    try:
        audio_file = p8.repository(AudioFile).get_by_id(id=file_id, as_model=True)
        if not audio_file:
            logger.warning(f"Audio file {file_id} not found")
            raise HTTPException(status_code=404, detail="Audio file not found")
    except Exception as get_error:
        logger.error(f"Error retrieving audio file {file_id}: {str(get_error)}")
        raise HTTPException(status_code=500, detail=f"Error retrieving audio file: {str(get_error)}")
    
    # Delete from S3 or local storage
    try:
        s3_uri = audio_file.s3_uri
        
        # Check if it's a local file
        if s3_uri.startswith("file://"):
            local_path = s3_uri.replace("file://", "")
            if os.path.exists(local_path):
                os.remove(local_path)
                logger.info(f"Deleted local file: {local_path}")
        else:
            # Use the S3Service to delete the object using URI directly
            s3_service = S3Service()
            
            # Delete the file using the URI-based method
            s3_service.delete_file_by_uri(s3_uri)
            logger.info(f"Deleted S3 object: {s3_uri}")
        
        # Delete any chunks
        chunks = p8.repository(AudioChunk).select(audio_file_id=file_id)
        for chunk in chunks:
            # Extract the chunk URI
            chunk_uri = chunk.s3_uri
            
            # Check if it's a local file
            if chunk_uri.startswith("file://"):
                chunk_path = chunk_uri.replace("file://", "")
                if os.path.exists(chunk_path):
                    os.remove(chunk_path)
                    logger.info(f"Deleted local chunk: {chunk_path}")
            else:
                # Delete the chunk using the URI-based method
                s3_service.delete_file_by_uri(chunk_uri)
                logger.info(f"Deleted S3 chunk: {chunk_uri}")
            
            # Delete the chunk record
            p8.repository(AudioChunk).delete(id=chunk.id)
            logger.debug(f"Deleted chunk record: {chunk.id}")
        
        # Delete the file record
        p8.repository(AudioFile).delete(id=file_id)
        logger.info(f"Deleted audio file record: {file_id}")
        
        return True
    except Exception as e:
        logger.error(f"Error deleting audio file: {str(e)}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Failed to delete audio file: {str(e)}")