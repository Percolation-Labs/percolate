"""
Resource creation handler for uploaded files.
Automatically creates resources from uploaded files based on their type.
"""
import os
import uuid
import tempfile
from typing import Optional, List, Dict, Any
from datetime import datetime, timezone
from pathlib import Path
import percolate as p8
from percolate.utils import logger, make_uuid
from percolate.models.p8.types import Resources
from percolate.models.media.tus import TusFileUpload
from percolate.models.media.audio import AudioFile
from percolate.services.media.audio.processor import AudioProcessor
from percolate.services.S3Service import S3Service
import mimetypes




async def create_resources_from_upload(upload_id: str) -> List[Resources]:
    """
    Create resources from a TUS upload based on file type.
    
    Args:
        upload_id: The TUS upload ID
        
    Returns:
        List of created Resource objects
    """
    logger.info(f"Creating resources for upload: {upload_id}")
    
    try:
        # Get the upload record
        upload = p8.repository(TusFileUpload).get_by_id(str(upload_id),as_model=True)
        if not upload:
            logger.error(f"Upload not found: {upload_id}")
            return []
            
        # Get file details
        filename = upload.filename
        content_type = upload.content_type or mimetypes.guess_type(filename)[0]
        s3_uri = upload.s3_uri
        user_id = upload.user_id
        
        if not s3_uri:
            logger.warning(f"No S3 URI for upload {upload_id}, skipping resource creation")
            return []
        
        logger.info(f"Processing file: {filename} (type: {content_type}) for user: {user_id}")
        
        # Route based on content type
        if content_type and content_type.startswith('audio/'):
            return await create_audio_resources(upload, s3_uri, user_id)
        elif filename.lower().endswith(('.pdf', '.txt', '.docx', '.doc')):
            return await create_document_resources(upload, s3_uri, user_id)
        else:
            logger.warning(f"Unsupported file type for resource creation: {content_type} ({filename})")
            return []
            
    except Exception as e:
        logger.error(f"Error creating resources from upload {upload_id}: {str(e)}")
        return []


async def create_audio_resources(upload: TusFileUpload, s3_uri: str, user_id: Optional[str]) -> List[Resources]:
    """
    Create resources from audio file with transcription using the audio controller flow.
    
    Args:
        upload: The TUS upload record
        s3_uri: The S3 URI of the uploaded file
        user_id: The user ID who uploaded the file
        
    Returns:
        List of created Resource objects
    """
    logger.info(f"Creating audio resources for: {upload.filename}")
    resources = []
    
    try:
        # Import the audio processing function
        from percolate.api.controllers.audio import process_audio_file
        from percolate.models.media.audio import AudioFile, AudioChunk, AudioProcessingStatus
        
        # Create an AudioFile record following the audio controller pattern
        audio_file = AudioFile(
            filename=upload.filename,
            s3_uri=s3_uri,
            file_size=upload.total_size or 0,
            content_type=upload.content_type or 'audio/x-wav',
            user_id=str(user_id),  # Database requires user_id as text
            userid=user_id,  # Model field
            project_name=upload.project_name or 'default',
            status=AudioProcessingStatus.UPLOADED,
            upload_date=datetime.now(timezone.utc),  # Fixed: was uploaded_at
            metadata={
                'tus_upload_id': str(upload.id),
                'source': 'tus_upload',
                'original_filename': upload.filename,
                's3_bucket': upload.s3_bucket,
                's3_key': upload.s3_key
            }
        )
        
        # Save the audio file record
        p8.repository(AudioFile).update_records([audio_file])
        audio_file_id = str(audio_file.id)
        logger.info(f"Created AudioFile record: {audio_file_id}")
        
        # Process the audio file using the audio controller flow
        # This handles VAD, chunking, and transcription
        await process_audio_file(audio_file_id, user_id=user_id, use_s3=True)
        
        # Get the processed audio file to check status
        audio_file = p8.repository(AudioFile).get_by_id(audio_file_id, as_model=True)
        
        if audio_file.status == AudioProcessingStatus.COMPLETED:
            # Get the processed chunks
            chunks = p8.repository(AudioChunk).select(audio_file_id=audio_file_id)
            logger.info(f"Found {len(chunks)} chunks for audio file {audio_file_id}")
            
            # Create a single resource that combines all chunks
            # This ensures the resource URI matches the TusFileUpload s3_uri
            if chunks:
                # Combine all transcriptions
                full_transcription = []
                transcribed_chunks = []
                
                for idx, chunk in enumerate(chunks):
                    if chunk.transcription:
                        full_transcription.append(f"[{chunk.start_time:.1f}s - {chunk.end_time:.1f}s]: {chunk.transcription}")
                        transcribed_chunks.append(chunk)
                
                if full_transcription:
                    # Create a single resource for the entire audio file
                    resource = Resources(
                        name=upload.filename,
                        category="audio_transcription",
                        content="\n\n".join(full_transcription),
                        summary=f"Audio transcription with {len(transcribed_chunks)} segments",
                        ordinal=0,
                        uri=s3_uri,  # This matches the TusFileUpload s3_uri
                        metadata={
                            'source_type': 'audio',
                            'audio_file_id': str(audio_file_id),
                            'original_filename': upload.filename,
                            'tus_upload_id': str(upload.id),
                            'file_type': '.wav',
                            'total_chunks': len(chunks),
                            'transcribed_chunks': len(transcribed_chunks),
                            'total_duration': sum(chunk.duration for chunk in chunks),
                            'chunk_details': [
                                {
                                    'chunk_id': str(chunk.id),
                                    'start_time': chunk.start_time,
                                    'end_time': chunk.end_time,
                                    'duration': chunk.duration,
                                    'confidence': chunk.confidence or 0.0
                                }
                                for chunk in transcribed_chunks
                            ]
                        },
                        userid=user_id,
                        resource_timestamp=datetime.now(timezone.utc)
                    )
                    resources.append(resource)
                else:
                    logger.warning(f"No transcribed chunks found for audio file {audio_file_id}")
            
            # Save all resources
            if resources:
                p8.repository(Resources).update_records(resources)
                logger.info(f"Created {len(resources)} audio resources from {len(chunks)} chunks")
                
                # Update upload with resource references
                resource_ids = [str(r.id) for r in resources]
                upload.resource_id = resource_ids[0] if resource_ids else None
                upload.upload_metadata['resource_ids'] = resource_ids
                upload.upload_metadata['resource_count'] = len(resources)
                upload.upload_metadata['audio_file_id'] = str(audio_file_id)
                upload.upload_metadata['chunk_count'] = len(chunks)
                upload.upload_metadata['transcribed_chunks'] = len(resources)
                p8.repository(TusFileUpload).update_records([upload])
            else:
                # No transcribed chunks
                logger.warning(f"No transcribed chunks found for audio file {audio_file_id}")
                upload.upload_metadata['resource_creation_warning'] = "No transcribed chunks found"
                upload.upload_metadata['audio_file_id'] = str(audio_file_id)
                upload.upload_metadata['chunk_count'] = len(chunks)
                p8.repository(TusFileUpload).update_records([upload])
        else:
            # Audio processing failed
            error_msg = audio_file.metadata.get('error', 'Audio processing failed')
            logger.error(f"Audio processing failed: {error_msg}")
            upload.upload_metadata['resource_creation_error'] = error_msg
            upload.upload_metadata['audio_file_id'] = str(audio_file_id)
            upload.upload_metadata['audio_status'] = str(audio_file.status)
            p8.repository(TusFileUpload).update_records([upload])
        
    except Exception as e:
        logger.error(f"Error creating audio resources: {str(e)}")
        # Update upload metadata to indicate failure
        upload.upload_metadata['resource_creation_error'] = str(e)
        p8.repository(TusFileUpload).update_records([upload])
        
    return resources


async def create_document_resources(upload: TusFileUpload, s3_uri: str, user_id: Optional[str]) -> List[Resources]:
    """
    Create resources from document files (PDF, TXT, DOCX) using FileSystemService.
    
    Args:
        upload: The TUS upload record
        s3_uri: The S3 URI of the uploaded file
        user_id: The user ID who uploaded the file
        
    Returns:
        List of created Resource objects
    """
    logger.info(f"Creating document resources for: {upload.filename}")
    resources = []
    
    try:
        # Use FileSystemService for unified chunking like admin router
        from percolate.services.FileSystemService import FileSystemService
        
        fs = FileSystemService()
        
        # Default to extended mode for all document processing
        parsing_mode = "extended"
        
        # Generate chunks using FileSystemService
        chunk_generator = fs.read_chunks(
            path=s3_uri,
            mode=parsing_mode,
            chunk_size=2000,
            chunk_overlap=200,
            userid=user_id,
            name=upload.filename,
            save_to_db=False  # We'll handle resource creation manually
        )
        
        # Convert generator to list and create resources
        resources = list(chunk_generator)
        
        # Update resource metadata to include TUS upload info
        for resource in resources:
            if not resource.metadata:
                resource.metadata = {}
            resource.metadata.update({
                'tus_upload_id': str(upload.id),
                'source': 'tus_upload',
                'original_filename': upload.filename,
                's3_bucket': upload.s3_bucket,
                's3_key': upload.s3_key
            })
        
        # Save all resources to database
        if resources:
            p8.repository(Resources).update_records(resources)
        
        # Update upload with resource references
        resource_ids = [str(r.id) for r in resources]
        upload.resource_id = resource_ids[0] if resource_ids else None
        upload.upload_metadata['resource_ids'] = resource_ids
        upload.upload_metadata['resource_count'] = len(resources)
        upload.upload_metadata['content_extracted'] = True
        upload.upload_metadata['parsing_mode'] = parsing_mode
        p8.repository(TusFileUpload).update_records([upload])
        
        logger.info(f"Created {len(resources)} document resources for upload {upload.id} using {parsing_mode} mode")
        
    except Exception as e:
        logger.error(f"Error creating document resources: {str(e)}")
        # Update upload metadata to indicate failure
        upload.upload_metadata['resource_creation_error'] = str(e)
        upload.upload_metadata['content_extracted'] = False
        p8.repository(TusFileUpload).update_records([upload])
        
    return resources