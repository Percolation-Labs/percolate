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
from percolate.utils.parsing.providers import get_content_provider_for_uri
from percolate.services.S3Service import S3Service
import mimetypes


def chunk_text(text: str, chunk_size: int = 2000, overlap: int = 200) -> List[str]:
    """
    Split text into chunks with overlap.
    
    Args:
        text: The text to chunk
        chunk_size: Size of each chunk in characters
        overlap: Number of characters to overlap between chunks
        
    Returns:
        List of text chunks
    """
    if not text:
        return []
        
    chunks = []
    start = 0
    text_length = len(text)
    
    while start < text_length:
        end = start + chunk_size
        
        # If this is not the last chunk, try to break at a sentence or word boundary
        if end < text_length:
            # Look for sentence boundaries
            for sep in ['. ', '! ', '? ', '\n\n', '\n']:
                last_sep = text.rfind(sep, start, end)
                if last_sep > start + chunk_size // 2:  # Only use if it's in the second half
                    end = last_sep + len(sep)
                    break
            else:
                # If no sentence boundary, try to break at a word
                last_space = text.rfind(' ', start, end)
                if last_space > start:
                    end = last_space + 1
        
        chunks.append(text[start:min(end, text_length)].strip())
        start = end - overlap if end < text_length else text_length
        
    return chunks


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
            s3_bucket=upload.s3_bucket,
            s3_key=upload.s3_key,
            file_size=upload.total_size or 0,
            content_type=upload.content_type or 'audio/x-wav',
            user_id=user_id,
            project_name=upload.project_name or 'default',
            status=AudioProcessingStatus.UPLOADED,
            uploaded_at=datetime.now(timezone.utc),
            metadata={
                'tus_upload_id': str(upload.id),
                'source': 'tus_upload',
                'original_filename': upload.filename
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
            
            # Convert each chunk to a resource
            for idx, chunk in enumerate(chunks):
                # Skip chunks without transcription
                if not chunk.transcription:
                    logger.warning(f"Skipping chunk {chunk.id} - no transcription")
                    continue
                
                # Create resource from chunk
                resource = Resources(
                    name=f"{upload.filename} - Segment {idx + 1}",
                    category="audio_transcription",
                    content=chunk.transcription,
                    summary=f"Audio segment {idx + 1}: {chunk.transcription[:100]}..." if len(chunk.transcription) > 100 else chunk.transcription,
                    ordinal=idx,
                    uri=s3_uri,
                    metadata={
                        'source_type': 'audio',
                        'audio_file_id': str(audio_file_id),
                        'chunk_id': str(chunk.id),
                        'original_filename': upload.filename,
                        'start_time': chunk.start_time,
                        'end_time': chunk.end_time,
                        'duration': chunk.duration,
                        'timestamp': chunk.start_time,
                        'confidence': chunk.confidence or 0.0,
                        'tus_upload_id': str(upload.id),
                        'file_type': '.wav',
                        'chunk_index': idx,
                        'total_chunks': len(chunks)
                    },
                    userid=user_id,
                    resource_timestamp=datetime.now(timezone.utc)
                )
                resources.append(resource)
            
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
    Create resources from document files (PDF, TXT, DOCX).
    
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
        # Get appropriate content provider
        provider = get_content_provider_for_uri(upload.filename)
        
        # Extract text from document
        # For S3 files, we need to download first or use signed URL
        s3_service = S3Service()
        
        # Download file temporarily for processing
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=Path(upload.filename).suffix) as tmp_file:
            # Download from S3 using the URI directly
            result = s3_service.download_file_from_uri(s3_uri, tmp_file.name)
            
            # Extract text
            text_content = provider.extract_text(tmp_file.name)
        
        # Chunk the text for better searchability
        chunks = chunk_text(text_content, chunk_size=2000, overlap=200)
        
        # Create resources from chunks
        for idx, chunk in enumerate(chunks):
            resource = Resources(
                name=f"{upload.filename} - Part {idx + 1}",
                category="document",
                content=chunk,
                summary=f"Content chunk {idx + 1} from {upload.filename}",
                ordinal=idx,
                uri=s3_uri,
                metadata={
                    'source_type': 'document',
                    'original_filename': upload.filename,
                    'file_type': Path(upload.filename).suffix,
                    'chunk_index': idx,
                    'total_chunks': len(chunks),
                    'tus_upload_id': str(upload.id)
                },
                userid=user_id,
                resource_timestamp=datetime.now(timezone.utc)
            )
            resources.append(resource)
            
        # Save all resources
        if resources:
            p8.repository(Resources).update_records(resources)
        
        # Update upload with resource references
        resource_ids = [str(r.id) for r in resources]
        upload.resource_id = resource_ids[0] if resource_ids else None
        upload.upload_metadata['resource_ids'] = resource_ids
        upload.upload_metadata['resource_count'] = len(resources)
        upload.upload_metadata['content_extracted'] = True
        p8.repository(TusFileUpload).update_records([upload])
        
        logger.info(f"Created {len(resources)} document resources for upload {upload.id}")
        
    except Exception as e:
        logger.error(f"Error creating document resources: {str(e)}")
        # Update upload metadata to indicate failure
        upload.upload_metadata['resource_creation_error'] = str(e)
        upload.upload_metadata['content_extracted'] = False
        p8.repository(TusFileUpload).update_records([upload])
        
    return resources