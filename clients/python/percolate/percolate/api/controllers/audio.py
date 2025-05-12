"""
Audio controller for the Percolate API.
Handles audio file uploading, processing, and management.
"""

import os
import uuid
import shutil
import tempfile
import asyncio
from typing import Optional, Dict, Any, List
from datetime import datetime, timezone
from fastapi import HTTPException, UploadFile
import boto3
from botocore.exceptions import ClientError

import percolate as p8
from percolate.utils import logger
from percolate.models.media.audio import (
    AudioFile, 
    AudioChunk, 
    AudioProcessingStatus,
    AudioUploadResponse,
    AudioPipelineConfig,
    AudioPipeline,
    AudioResource
)

# Add additional logging
import logging
_logger = logging.getLogger("audio.controller")
_logger.setLevel(logging.DEBUG)

# S3 Configuration
S3_URL = os.environ.get("S3_URL", "")
S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "")
S3_SECRET = os.environ.get("S3_SECRET", "")
S3_AUDIO_BUCKET = os.environ.get("S3_AUDIO_BUCKET", "percolate-audio")

def get_s3_client():
    """Create and return an S3 client."""
    endpoint_url = None
    if S3_URL:
        if not S3_URL.startswith("http"):
            endpoint_url = f"https://{S3_URL}"
        else:
            endpoint_url = S3_URL
    
    logger.debug(f"Creating S3 client with endpoint: {endpoint_url}")
    
    # For Hetzner S3, we need to use 's3' signature version and path addressing style
    return boto3.client(
        's3',
        endpoint_url=endpoint_url,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET,
        config=boto3.session.Config(
            signature_version='s3',
            s3={'addressing_style': 'path'}
        )
    )

async def upload_audio_file(
    file: UploadFile, 
    user_id: Optional[str], 
    project_name: str,
    metadata: Optional[Dict[str, Any]] = None
) -> AudioUploadResponse:
    """
    Upload an audio file to S3 and create an AudioFile record.
    
    Args:
        file: The uploaded file
        user_id: The ID of the user uploading the file
        project_name: The project name for organizing storage
        metadata: Optional metadata to store with the file
        
    Returns:
        AudioUploadResponse with file details
    """
    logger.info(f"Starting audio upload: {file.filename}, size: {file.size}, content_type: {file.content_type}")
    
    # Create a temporary file to store the upload
    with tempfile.NamedTemporaryFile(delete=False) as temp_file:
        # Copy content from the uploaded file to the temporary file
        logger.debug(f"Creating temporary file for upload")
        shutil.copyfileobj(file.file, temp_file)
        temp_file_path = temp_file.name
        logger.debug(f"Temporary file created at: {temp_file_path}")
    
    try:
        # Get file size
        file_size = os.path.getsize(temp_file_path)
        
        # Create a unique key for S3
        file_id = str(uuid.uuid4())
        s3_key = f"{project_name}/audio/{file_id}/{file.filename}"
        
        # Create the file record first
        audio_file = AudioFile(
            id=file_id,
            user_id=user_id,
            project_name=project_name,
            filename=file.filename,
            file_size=file_size,
            content_type=file.content_type or "audio/mpeg",  # Default if not provided
            status=AudioProcessingStatus.UPLOADING,
            s3_uri=f"s3://{S3_AUDIO_BUCKET}/{s3_key}",
            metadata=metadata or {}
        )
        
        # Save the file record to the database
        logger.info(f"Creating audio file record in database: id={file_id}, project={project_name}")
        try:
            p8.repository(AudioFile).update_records([audio_file])
            logger.debug(f"Successfully created audio file record")
        except Exception as db_error:
            logger.error(f"Error creating audio file record: {str(db_error)}")
            raise
        
        # Upload the file to S3
        s3_client = get_s3_client()
        
        # For testing, we'll assume the bucket exists and continue
        # In production, you'd want proper bucket creation and validation
        logger.info(f"Checking S3 bucket: {S3_AUDIO_BUCKET}")
        try:
            s3_client.head_bucket(Bucket=S3_AUDIO_BUCKET)
            logger.debug(f"Bucket {S3_AUDIO_BUCKET} exists")
        except ClientError as e:
            # Just log the error and continue, assuming the bucket will be created manually
            logger.warning(f"Error checking bucket: {str(e)}")
            # We'll try to use an existing bucket from the environment as a fallback
            fallback_bucket = os.environ.get("S3_DEFAULT_BUCKET", "percolate")
            logger.info(f"Using fallback bucket: {fallback_bucket}")
            # Use the fallback bucket for this upload
            s3_bucket = fallback_bucket
            # Update the file's S3 URI to use the fallback bucket
            audio_file.s3_uri = f"s3://{s3_bucket}/{s3_key}"
            # Update the record with the new URI
            p8.repository(AudioFile).update_records([audio_file])

          
            
        # Determine which bucket to use
        s3_bucket = fallback_bucket if 'fallback_bucket' in locals() else S3_AUDIO_BUCKET
        # Upload the file
        logger.info(f"Uploading file to S3 bucket: {s3_bucket}, key: {s3_key}")
        try:
            with open(temp_file_path, 'rb') as data:
                logger.debug(f"Starting S3 upload...")
                # For Hetzner S3, use a simpler approach with fewer metadata fields
                logger.debug(f"Using simplified S3 upload for Hetzner S3")
                s3_client.upload_fileobj(
                    data,
                    s3_bucket,
                    s3_key,
                    ExtraArgs={
                        'ContentType': audio_file.content_type
                    }
                )
                logger.info(f"File successfully uploaded to S3")
        except Exception as s3_error:
            logger.error(f"Error uploading to S3: {str(s3_error)}")
            raise
        
        # Update the file status
        logger.info(f"Updating file status to UPLOADED")
        audio_file.status = AudioProcessingStatus.UPLOADED
        try:
            p8.repository(AudioFile).update_records([audio_file])
            logger.debug(f"File status updated successfully")
        except Exception as update_error:
            logger.error(f"Error updating file status: {str(update_error)}")
            raise
        
        # Trigger async processing with user_id
        asyncio.create_task(process_audio_file(file_id, user_id))
        
        # Return response
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

async def process_audio_file(file_id: str, user_id: Optional[str] = None) -> None:
    """
    Process an uploaded audio file asynchronously.
    
    Args:
        file_id: The ID of the audio file to process
        user_id: Optional user ID to associate with processed chunks
    """
    logger.info(f"Processing audio file: {file_id}")
    _logger.info(f"Processing audio file with ID: {file_id}, user_id: {user_id}")
    
    # Get the audio file
    audio_files = p8.repository(AudioFile).select(id=file_id)
    if not audio_files:
        logger.warning(f"Audio file {file_id} not found for processing")
        return
    
    # Check if the result is a dictionary or Pydantic model
    audio_file = audio_files[0]
    if isinstance(audio_file, dict):
        logger.info(f"Converting dictionary to AudioFile model in process_audio_file")
        # Convert dictionary to AudioFile model
        audio_file = AudioFile(**audio_file)
    
    # If no user_id is provided, use the one from the audio file
    if not user_id and hasattr(audio_file, 'user_id'):
        user_id = audio_file.user_id
        logger.info(f"Using user_id from audio file: {user_id}")
    
    # Update status to processing
    audio_file.status = AudioProcessingStatus.PROCESSING
    audio_file.metadata["queued_at"] = datetime.now(timezone.utc).isoformat()
    if user_id:
        audio_file.metadata["processed_by_user_id"] = user_id
    logger.info(f"Updating file {file_id} status to PROCESSING")
    p8.repository(AudioFile).update_records([audio_file])
    
    # In a real implementation, we would add this to a job queue
    # For now, we'll just call the processing function directly
    try:
        # Create a pipeline record
        pipeline = AudioPipeline(
            audio_file_id=file_id,
            status=AudioProcessingStatus.PROCESSING,
            config={}
        )
        p8.repository(AudioPipeline).update_records([pipeline])
        
        # Import and use the AudioProcessor 
        # This would be implemented in a separate module
        from percolate.services.media.audio import AudioProcessor
        processor = AudioProcessor()
        
        # Process the file with the user_id
        success = await processor.process_file(file_id, user_id)
        
        if success:
            # Update pipeline status
            pipeline.status = AudioProcessingStatus.COMPLETED
            pipeline.completed_at = datetime.now(timezone.utc)
            p8.repository(AudioPipeline).update_records([pipeline])
            
            logger.info(f"Audio processing completed successfully for file {file_id}")
        else:
            # Update pipeline status
            pipeline.status = AudioProcessingStatus.FAILED
            pipeline.error_message = "Processing failed"
            pipeline.completed_at = datetime.now(timezone.utc)
            p8.repository(AudioPipeline).update_records([pipeline])
            
            logger.error(f"Audio processing failed for file {file_id}")
            
    except Exception as e:
        logger.error(f"Error processing audio file {file_id}: {str(e)}")
        
        # Update the audio file status
        audio_file.status = AudioProcessingStatus.FAILED
        audio_file.metadata["error"] = str(e)
        p8.repository(AudioFile).update_records([audio_file])
        
        # Update pipeline status if it exists
        try:
            pipelines = p8.repository(AudioPipeline).select(audio_file_id=file_id)
            if pipelines:
                pipeline = pipelines[0]
                if isinstance(pipeline, dict):
                    pipeline = AudioPipeline(**pipeline)
                
                pipeline.status = AudioProcessingStatus.FAILED
                pipeline.error_message = str(e)
                pipeline.completed_at = datetime.now(timezone.utc)
                p8.repository(AudioPipeline).update_records([pipeline])
        except Exception as pipeline_error:
            logger.error(f"Error updating pipeline status: {str(pipeline_error)}")

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
    try:
        audio_files = p8.repository(AudioFile).select(id=file_id)
        if not audio_files:
            logger.warning(f"Audio file with ID {file_id} not found")
            raise HTTPException(status_code=404, detail="Audio file not found")
        
        # Check if the result is a dictionary or Pydantic model
        audio_file = audio_files[0]
        if isinstance(audio_file, dict):
            logger.info(f"Converting dictionary to AudioFile model")
            # Convert dictionary to AudioFile model
            audio_file = AudioFile(**audio_file)
        
        logger.debug(f"Found audio file with status: {audio_file.status}")
        return audio_file
    except Exception as e:
        if not isinstance(e, HTTPException):
            logger.error(f"Error retrieving audio file {file_id}: {str(e)}")
            raise HTTPException(status_code=500, detail=f"Error getting audio file: {str(e)}")
        raise

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
    if user_id:
        return p8.repository(AudioFile).select(project_name=project_name, user_id=user_id)
    else:
        return p8.repository(AudioFile).select(project_name=project_name)

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
    audio_files = p8.repository(AudioFile).select(id=file_id)
    if not audio_files:
        raise HTTPException(status_code=404, detail="Audio file not found")
    
    audio_file = audio_files[0]
    
    # Delete from S3
    try:
        s3_client = get_s3_client()
        
        # Get the S3 key from the URI
        s3_uri = audio_file.s3_uri
        s3_bucket = s3_uri.split("/")[2]
        s3_key = "/".join(s3_uri.split("/")[3:])
        
        # Delete the file
        s3_client.delete_object(
            Bucket=s3_bucket,
            Key=s3_key
        )
        
        # Delete any chunks
        chunks = p8.repository(AudioChunk).select(audio_file_id=file_id)
        for chunk in chunks:
            # Extract the chunk key from URI
            chunk_uri = chunk.s3_uri
            chunk_bucket = chunk_uri.split("/")[2]
            chunk_key = "/".join(chunk_uri.split("/")[3:])
            
            # Delete the chunk
            s3_client.delete_object(
                Bucket=chunk_bucket,
                Key=chunk_key
            )
            
            # Delete the chunk record
            p8.repository(AudioChunk).delete(id=chunk.id)
        
        # Delete the file record
        p8.repository(AudioFile).delete(id=file_id)
        
        return True
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete audio file: {str(e)}")