"""
Audio processor for Percolate.
Handles the audio file processing pipeline including:
- Voice Activity Detection (VAD)
- Audio chunking
- Transcription
- Storage (either locally in /tmp or in S3)
"""

import os
import tempfile
import uuid
import shutil
from typing import List, Dict, Any, Optional, Tuple
from datetime import datetime, timezone
import asyncio
import json
import boto3
from botocore.exceptions import ClientError
from pathlib import Path

import percolate as p8
from percolate.utils import logger
from percolate.services.S3Service import S3Service
from percolate.models.media.audio import (
    AudioFile,
    AudioChunk,
    AudioProcessingStatus,
    AudioPipelineConfig
)

class AudioProcessor:
    """
    Audio processor for the Percolate audio pipeline.
    
    This class handles the processing of audio files through the pipeline:
    1. Voice Activity Detection (VAD)
    2. Chunking
    3. Transcription
    4. Storage (either locally in /tmp or in S3)
    """
    
    def __init__(
        self, 
        vad_threshold: float = 0.5, 
        energy_threshold: float = -35, 
        skip_transcription: bool = False,
        use_s3: bool = False
    ):
        """
        Initialize the audio processor.
        
        Args:
            vad_threshold: Voice activity detection threshold (0.0-1.0)
            energy_threshold: Energy threshold for fallback VAD (in dB)
            skip_transcription: Skip the transcription step
            use_s3: If True, use S3 for storage; otherwise, use local temporary files
        """
        self.vad_threshold = vad_threshold
        self.energy_threshold = energy_threshold
        self.skip_transcription = skip_transcription
        self.use_s3 = use_s3
        self.temp_files = []  # Track temporary files for cleanup
        
        # Initialize S3 service if needed
        self.s3_service = None
        if self.use_s3:
            try:
                self.s3_service = S3Service()
                logger.info("S3 service initialized successfully")
            except Exception as e:
                logger.error(f"Failed to initialize S3 service: {e}")
                logger.warning("Falling back to local storage")
                self.use_s3 = False
        
        # Check for PyTorch availability
        self.torch_available = False
        try:
            import torch
            import torchaudio
            self.torch_available = True
            logger.info(f"PyTorch is available: {torch.__version__}")
        except ImportError:
            logger.info("PyTorch is not available - will use energy-based VAD")
        
        from percolate.services.llm.LanguageModel import try_get_open_ai_key
        # Check for OpenAI API key
        self.openai_api_key = os.environ.get("OPENAI_API_KEY") or try_get_open_ai_key()
        self.openai_available = self.openai_api_key is not None
        if self.openai_available:
            logger.info("OpenAI API key found, will use REST API for transcription")
        else:
            logger.info("OpenAI API key not found, will use placeholder transcription")
    
    async def process_file(self, file_id: str, userid: Optional[str] = None) -> bool:
        """
        Process an audio file through the pipeline.
        
        Args:
            file_id: ID of the audio file to process
            userid: Optional user ID to associate with chunks (must be a valid UUID)
            
        Returns:
            bool: True if processing was successful
        """
        logger.info(f"Starting to process audio file: {file_id} (use_s3={self.use_s3})")
        
        # Ensure file_id is a string
        file_id = str(file_id)
        
        # Validate userid is a proper UUID if provided
        if userid:
            try:
                uuid_obj = uuid.UUID(userid)
                userid = str(uuid_obj)  # Normalize the format
                logger.info(f"Using user ID: {userid}")
            except (ValueError, TypeError):
                logger.warning(f"Invalid user ID provided: {userid} - will not associate chunks with a user")
                userid = None  # Reset to None if invalid
        
        # Get the audio file record
        audio_file = self._get_audio_file(file_id)
        if not audio_file:
            return False
        
        try:
            # Update to processing status
            self._update_audio_status(audio_file, AudioProcessingStatus.PROCESSING)
            
            # Set up a semantic directory structure for this processing job
            # Use a single root temp directory for all files related to this job
            job_dir = tempfile.mkdtemp(prefix=f"audio_job_{file_id}_")
            self.temp_files.append(job_dir)  # Track for cleanup
            logger.info(f"Created job directory: {job_dir}")
            
            # Create a specific directory for the audio file
            audio_dir = os.path.join(job_dir, "audio")
            os.makedirs(audio_dir, exist_ok=True)
            
            # Create a specific directory for chunks
            chunks_dir = os.path.join(job_dir, "chunks")
            os.makedirs(chunks_dir, exist_ok=True)
            
            # Define the local file path explicitly with the file ID
            local_file_path = os.path.join(audio_dir, f"{file_id}_{audio_file.filename}")
            
            # Download the audio file
            local_file_path = self._download_audio_file(audio_file, local_file_path)
            if not local_file_path:
                raise Exception("Failed to download audio file")
            
            # Detect speech segments and update status
            self._update_audio_status(audio_file, AudioProcessingStatus.CHUNKING)
            speech_segments = self._detect_speech_segments(local_file_path) 
            
            # Transcribe and process chunks
            self._update_audio_status(audio_file, AudioProcessingStatus.TRANSCRIBING)
            chunk_records = await self._process_speech_chunks(
                audio_file, speech_segments, chunks_dir, userid
            )
            
            # Save chunks to database
            if not self._save_chunks_to_database(chunk_records, file_id):
                raise Exception("Failed to save chunks to database")
            
            # Update file status to completed
            self._complete_audio_processing(audio_file, len(chunk_records))
            
            logger.info(f"Successfully processed audio file: {file_id}")
            return True
            
        except Exception as e:
            logger.error(f"Error processing audio file {file_id}: {str(e)}")
            import traceback
            logger.error(f"Traceback: {traceback.format_exc()}")
            
            # Update the file status
            audio_file.status = AudioProcessingStatus.FAILED
            audio_file.metadata["error"] = str(e)
            p8.repository(AudioFile).update_records([audio_file])
            
            return False
        finally:
            # Clean up temporary files
            self._cleanup_temp_files()
    
    def _get_audio_file(self, file_id: str) -> Optional[AudioFile]:
        """Get the audio file record from the database."""
        return p8.repository(AudioFile).get_by_id(id=str(file_id),as_model=True)

            
    def _update_audio_status(self, audio_file: AudioFile, status: AudioProcessingStatus) -> None:
        """Update the audio file status in the database."""
        audio_file.status = status
        p8.repository(AudioFile).update_records([audio_file])
    
    def _download_audio_file(self, audio_file: AudioFile, local_file_path: str) -> Optional[str]:
        """
        Download the audio file to a specific local path.
        
        Args:
            audio_file: The AudioFile object with metadata
            local_file_path: The specific path where the file should be saved
            
        Returns:
            The path to the downloaded file or None if download failed
        """
        logger.info(f"Downloading audio file to: {local_file_path}")
        
        # Make sure parent directory exists
        os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
        
        # Add the file path to our tracked temp files
        self.temp_files.append(local_file_path)
        logger.debug(f"Tracking audio file: {local_file_path}")
        
        if self.use_s3:
            try:
                return self._download_from_s3(audio_file.s3_uri, local_file_path)
            except Exception as e:
                logger.error(f"Error downloading from S3: {e}")
                return None
        else:
            return self._handle_local_file(audio_file.s3_uri, local_file_path)
    
    def _download_from_s3(self, s3_uri: str, local_file_path: str) -> str:
        """Download a file from S3 to a local path using the S3Service."""
        if not self.s3_service:
            raise Exception("S3 service not available")
        
        if not s3_uri:
            raise ValueError("Empty S3 URI provided")
            
        if not s3_uri.startswith("s3://"):
            raise ValueError(f"Invalid S3 URI format: {s3_uri}, must start with s3://")
            
        try:
            logger.info(f"Downloading from S3: {s3_uri}")
            
            # Use the simplified URI-based download method
            result = self.s3_service.download_file_from_uri(s3_uri, local_file_path)
            
            logger.info(f"S3 download complete: {result.get('size', 0)} bytes")
            return local_file_path
            
        except Exception as e:
            logger.error(f"Error downloading from S3: {str(e)}")
            raise
    
    def _handle_local_file(self, file_uri: str, local_file_path: str) -> str:
        """Handle a local file URI or fall back to test files."""
        logger.info(f"Using local file path directly (in a real implementation)")
        
        # Check if the s3_uri is actually a local file URI
        if file_uri.startswith("file://"):
            local_source_path = file_uri.replace("file://", "")
            if os.path.exists(local_source_path):
                logger.info(f"Using local file from URI: {local_source_path}")
                shutil.copy(local_source_path, local_file_path)
                return local_file_path
            logger.warning(f"Local file not found at {local_source_path}")
        else:
            logger.warning(f"URI {file_uri} is not a local file URI")
        
        # Fall back to test files
        return self._use_test_file(local_file_path)
    
    def _use_test_file(self, local_file_path: str) -> str:
        """Use a test file as a fallback."""
        test_dir = Path("/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/notebooks/recipes/temp")
        test_files = list(test_dir.glob("chunk_*.wav"))
        
        if test_files:
            # Prefer chunk_1.wav if available
            for test_file in test_files:
                if test_file.name == "chunk_1.wav":
                    logger.info(f"Using chunk_1.wav test file which should be longer")
                    shutil.copy(str(test_file), local_file_path)
                    return local_file_path
            
            # Otherwise use the first test file
            test_file = str(test_files[0])
            logger.info(f"Using test file for demonstration: {test_file}")
            shutil.copy(test_file, local_file_path)
            return local_file_path
        else:
            # Create a placeholder file as last resort
            logger.warning("No test files found. Creating a placeholder file.")
            with open(local_file_path, "w") as f:
                f.write("Placeholder audio content")
            return local_file_path
    
    def _detect_speech_segments(self, audio_path: str) -> List[Tuple[float, float]]:
        """Detect speech segments in the audio file."""
        # Try Silero-VAD first, then fall back to energy-based VAD
        speech_segments = None
        
        if self.torch_available:
            try:
                logger.info("Attempting to use Silero-VAD for speech detection...")
                speech_segments = self._silero_vad(audio_path)
                logger.info(f"Silero-VAD detected {len(speech_segments)} raw speech segments")
            except Exception as e:
                logger.error(f"Silero-VAD failed: {e}, falling back to energy-based VAD")
                speech_segments = None
        
        # Fall back to energy-based VAD if needed
        if speech_segments is None:
            logger.info("Using energy-based VAD for speech detection...")
            speech_segments = self._energy_based_vad(audio_path)
            logger.info(f"Energy-based VAD detected {len(speech_segments)} raw speech segments")
        
        # Post-process the speech segments
        logger.info("Post-processing speech segments...")
        speech_segments = self._process_speech_segments(
            speech_segments,
            max_segment_length=30.0,  # Max 30 seconds for OpenAI API
            min_segment_length=0.5,   # Minimum 0.5 seconds to keep a segment
            merge_threshold=3.0       # Merge segments with gaps less than 3.0 seconds
        )
        logger.info(f"After post-processing: {len(speech_segments)} speech segments")
        
        return speech_segments
    
    async def _process_speech_chunks(
        self,
        audio_file: AudioFile,
        speech_segments: List[Tuple[float, float]],
        chunks_dir: str,
        userid: Optional[str]
    ) -> List[AudioChunk]:
        """Process speech segments into audio chunks and transcribe them."""
        chunk_records = []
        
        # Get the source audio file path from our semantic directory structure
        # The audio file was saved to audio_dir with a specific naming pattern
        file_id = str(audio_file.id)
        
        # Get the parent directory of chunks_dir (which is the job_dir)
        job_dir = os.path.dirname(chunks_dir)
        audio_dir = os.path.join(job_dir, "audio")
        source_audio_path = os.path.join(audio_dir, f"{file_id}_{audio_file.filename}")
        
        if not os.path.exists(source_audio_path):
            raise Exception(f"Source audio file not found at expected path: {source_audio_path}")
        
        # Ensure chunks directory exists
        os.makedirs(chunks_dir, exist_ok=True)
        
        for i, (start_time, end_time) in enumerate(speech_segments):
            logger.info(f"Processing chunk {i+1}/{len(speech_segments)}: {start_time:.2f}s - {end_time:.2f}s")
            
            # Create a unique ID for this chunk
            chunk_id = str(uuid.uuid4())
            chunk_filename = f"chunk_{i+1}_{chunk_id}.wav"
            chunk_path = os.path.join(chunks_dir, chunk_filename)
            
            # Extract the audio segment - pass the source audio path directly
            self._extract_audio_segment(source_audio_path, chunk_path, start_time, end_time)
            
            # Upload the chunk to S3 if using S3
            chunk_s3_uri = self._upload_chunk(audio_file, chunk_path, chunk_filename)
            
            # Create the chunk record - only include user_id if it's a valid UUID
            chunk_data = {
                "id": chunk_id,
                "audio_file_id": audio_file.id,
                "start_time": start_time,
                "end_time": end_time,
                "duration": end_time - start_time,
                "s3_uri": chunk_s3_uri,
                "transcription": "",  # Will update after transcription
                "confidence": 0.0,    # Will update after transcription
            }
            
            # Only add userid if it's a valid UUID - otherwise leave it blank
            if userid:
                try:
                    # Validate the UUID - will raise ValueError if invalid
                    uuid_obj = uuid.UUID(userid)
                    # Only add if it's a valid UUID
                    chunk_data["userid"] = str(uuid_obj)
                    logger.debug(f"Using valid UUID for userid: {userid}")
                except (ValueError, TypeError):
                    # If it's not a valid UUID, don't include it at all
                    logger.warning(f"Ignoring invalid UUID for userid: {userid}")
                    # No userid will be added to chunk_data
                
            chunk = AudioChunk(**chunk_data)
            
            # Save the chunk record to the database immediately
            try:
                p8.repository(AudioChunk).update_records([chunk])
                logger.info(f"Saved initial chunk record {chunk_id} to database")
            except Exception as e:
                logger.error(f"Error saving initial chunk record: {e}")
                # Continue processing - we'll try to save again later
            
            # Transcribe the chunk - with proper error handling
            try:
                transcription, confidence = await self.transcribe_audio(chunk_path)
                
                # Update the chunk with transcription
                chunk.transcription = transcription
                chunk.confidence = confidence
                
                # Update the chunk record in the database with transcription
                try:
                    p8.repository(AudioChunk).update_records([chunk])
                    logger.info(f"Updated chunk {chunk_id} with transcription")
                except Exception as e:
                    logger.error(f"Error updating chunk with transcription: {e}")
                    # Continue processing other chunks
                
                logger.info(f"Processed chunk {i+1}: {transcription[:50]}...")
            except Exception as e:
                # Log the transcription error but don't add it to the transcription field
                error_message = f"Transcription failed: {str(e)}"
                logger.error(f"Error transcribing chunk {i+1}: {error_message}")
                
                # If it's an SSL error, add more context
                if "SSL" in str(e) or "ssl" in str(e):
                    logger.info("SSL error detected - this might be due to network/certificate issues")
                
                # Keep transcription field empty for failed transcriptions
                chunk.transcription = ""
                chunk.confidence = 0.0
                
                # Store error in metadata instead
                if not hasattr(chunk, 'metadata') or chunk.metadata is None:
                    chunk.metadata = {}
                chunk.metadata["error"] = error_message
                chunk.metadata["transcription_status"] = "failed"
                
                # Update the chunk in the database with the error in metadata
                try:
                    p8.repository(AudioChunk).update_records([chunk])
                    logger.info(f"Updated chunk {chunk_id} with transcription error in metadata")
                except Exception as db_error:
                    logger.error(f"Error updating chunk with transcription error: {db_error}")
                    # Continue processing other chunks
                
                logger.info(f"Chunk {i+1} marked with error in metadata: {error_message[:50]}...")
            
            # Add the chunk to our records regardless of transcription success
            chunk_records.append(chunk)
            
            # Add a small delay between API calls to avoid rate limiting
            if i < len(speech_segments) - 1:  # Don't delay after the last chunk
                await asyncio.sleep(0.5)
        
        return chunk_records
    
    def _extract_audio_segment(self, source_audio_path: str, chunk_path: str, start_time: float, end_time: float) -> None:
        """
        Extract an audio segment from a source file and save to a chunk file.
        
        Args:
            source_audio_path: The full path to the source audio file
            chunk_path: The full path where the chunk should be saved
            start_time: Start time of the segment in seconds
            end_time: End time of the segment in seconds
        """
        try:
            # Use PyDub to extract the chunk
            from pydub import AudioSegment
            
            # Verify source file exists
            if not os.path.exists(source_audio_path):
                raise FileNotFoundError(f"Source audio file not found: {source_audio_path}")
            
            # Load the audio file
            logger.info(f"Loading audio file from {source_audio_path}")
            audio = AudioSegment.from_file(source_audio_path)
            
            # Extract the chunk (convert seconds to milliseconds)
            start_ms = int(start_time * 1000)
            end_ms = int(end_time * 1000)
            
            # Validate that the segment is within the audio duration
            if start_ms > len(audio) or end_ms > len(audio):
                logger.warning(f"Segment time range ({start_ms}-{end_ms}ms) exceeds audio duration ({len(audio)}ms)")
                # Adjust to audio length if needed
                start_ms = min(start_ms, len(audio))
                end_ms = min(end_ms, len(audio))
                if start_ms == end_ms:
                    # If both are at the end, move start back to create a small segment
                    start_ms = max(0, end_ms - 1000)  # Create at least a 1 second chunk
            
            audio_chunk = audio[start_ms:end_ms]
            
            # Set parameters for WAV file to ensure compatibility but don't use FFMPEG directly
            # - Set to mono channel (required by some speech APIs)
            # - Set to 16kHz sample rate (preferred by OpenAI Whisper)
            if audio_chunk.channels > 1:
                audio_chunk = audio_chunk.set_channels(1)
            audio_chunk = audio_chunk.set_frame_rate(16000)
            
            # Make sure the chunks directory exists
            os.makedirs(os.path.dirname(chunk_path), exist_ok=True)
            
            # Export the chunk to a file without using FFMPEG parameters
            logger.info(f"Exporting audio chunk to {chunk_path} (mono, 16kHz)")
            
            # Simple export without FFMPEG parameters
            audio_chunk.export(
                chunk_path, 
                format="wav"
                # No FFMPEG parameters to avoid errors
            )
            
            # Verify the file was created and is not empty
            if not os.path.exists(chunk_path) or os.path.getsize(chunk_path) == 0:
                raise Exception(f"Failed to create valid audio file at {chunk_path}")
            
            # Add the chunk path to temp files for tracking
            self.temp_files.append(chunk_path)
                
        except Exception as e:
            # Log the error clearly with no fallbacks
            logger.error(f"Error extracting audio chunk: {e}")
            # Instead of a fallback, raise an exception to fail explicitly
            raise Exception(f"Failed to extract audio segment: {e}")
        
        except ImportError:
            # Log that PyDub is required and don't create fallbacks
            logger.error("PyDub is required for audio processing but not available")
            raise ImportError("PyDub library is required for audio processing")
    
    def _upload_chunk(self, audio_file: AudioFile, chunk_path: str, chunk_filename: str) -> str:
        """Upload an audio chunk to S3 or use local path."""
        if self.use_s3 and self.s3_service:
            try:
                # Create the S3 URI for this chunk
                project_name = audio_file.project_name
                chunk_prefix = f"audio/{audio_file.id}/chunks"
                
                # Create the full URI
                s3_uri = self.s3_service.create_s3_uri(
                    project_name=project_name,
                    file_name=chunk_filename,
                    prefix=chunk_prefix
                )
                
                # Upload to S3 using URI-based method
                with open(chunk_path, "rb") as chunk_file:
                    upload_result = self.s3_service.upload_file_to_uri(
                        s3_uri=s3_uri,
                        file_path_or_content=chunk_file,
                        content_type="audio/wav"
                    )
                    return upload_result.get("uri") or s3_uri
            except Exception as e:
                logger.error(f"Error uploading chunk to S3: {e}")
                raise
        else:
            # For local mode, the URI is the local file path
            return f"file://{chunk_path}"
    
    def _save_chunks_to_database(self, chunk_records: List[AudioChunk], file_id: str) -> bool:
        """Save chunk records to the database."""
        if not chunk_records:
            logger.warning("No chunks to save")
            return True
        
        logger.info(f"Saving {len(chunk_records)} chunk records to database")
        logger.debug(f"Chunk records: {[str(c.id) for c in chunk_records]}")
        
        # Debug print first chunk's transcription
        if chunk_records:
            logger.debug(f"First chunk transcription: {chunk_records[0].transcription[:100]}")
        
        try:
            # Insert each chunk separately to ensure proper database records
            for chunk in chunk_records:
                logger.debug(f"Inserting chunk with ID {chunk.id}")
                p8.repository(AudioChunk).update_records([chunk])
            
            logger.info("All chunks saved successfully")
            
            # Debug check - verify chunks exist in the database
            file_id_str = str(file_id)
            verification_chunks = p8.repository(AudioChunk).select(audio_file_id=file_id_str)
            logger.info(f"Verification: Found {len(verification_chunks)} chunks in database for file {file_id}")
            
            return True
        except Exception as db_error:
            logger.error(f"Error saving chunks to database: {str(db_error)}")
            return False
    
    def _complete_audio_processing(self, audio_file: AudioFile, chunk_count: int) -> None:
        """Mark audio processing as complete and update metadata."""
        audio_file.status = AudioProcessingStatus.COMPLETED
        audio_file.metadata["completed_at"] = datetime.now(timezone.utc).isoformat()
        audio_file.metadata["chunk_count"] = chunk_count
        
        # Export chunks as a single Resource
        self.export_resource_for_file_chunks(audio_file)
        
        p8.repository(AudioFile).update_records([audio_file])
        
    def export_resource_for_file_chunks(self, audio_file: AudioFile) -> None:
        """
        Combine all chunks for an audio file into a single Resource object.
        
        This allows other parts of the system to easily access the full transcription
        as a standard Resource, while the individual chunks remain available for
        fine-grained access.
        
        expect:
        1. Single Resource per Audio File: Instead of creating separate resources for each chunk, we now create one consolidated resource per audio file that contains all transcriptions with timestamps.
        2. Matching URIs: The resource's URI now matches the original audio file's S3 URI (from TusFileUpload), ensuring proper joins in the database.
        3. Preserved Chunk Details: All chunk information is preserved in the resource's metadata, including:
            - Individual chunk IDs
            - Start/end times and durations
            - Transcription confidence scores
            - Total chunk count and transcribed chunk count
        4. Formatted Transcription: The content now includes timestamps for each segment in the format:
        [0.0s - 5.2s]: First transcription segment

        [5.2s - 10.4s]: Second transcription segment

        This solution ensures that:
        - Database queries can properly join TusFileUpload to Resources via the S3 URI
        - The full transcription is searchable as a single document
        - Individual chunk details remain accessible through metadata
        - The original file relationship is maintained
        
        Args:
            audio_file: The AudioFile whose chunks should be combined
        """
        from percolate.models.p8.types import Resources
        import percolate as p8
        from percolate.utils import make_uuid
           
        try:
            # Get all chunks for this file and sort them by start time
            chunks = p8.repository(AudioChunk).select(
                audio_file_id=str(audio_file.id)
            )
            
            chunks = sorted(chunks, key=lambda chunk: getattr(chunk, 'start_time', 0) if hasattr(chunk, 'start_time') else 0)
            
            # Format transcriptions with timestamps
            full_text_parts = []
            for chunk in chunks:
                if chunk.get('transcription'):
                    start_time = chunk.get('start_time', 0)
                    end_time = chunk.get('end_time', 0) 
                    text = chunk['transcription']
                    full_text_parts.append(f"[{start_time:.1f}s - {end_time:.1f}s]: {text}")
            
            full_text = "\n\n".join(full_text_parts)
       
            resource_id = make_uuid(audio_file.s3_uri)
            
            # Create the Resource
            resource = Resources(
                id=resource_id,
                name=audio_file.filename,
                category="audio_transcription",
                content=full_text,
                uri=audio_file.s3_uri,  # This ensures it matches the TusFileUpload s3_uri
                metadata={
                    "audio_file_id": str(audio_file.id),
                    "content_type": audio_file.content_type,
                    "chunk_count": len(chunks),
                    "transcribed_chunks": len(full_text_parts),
                    "source": "audio_transcription",
                    "chunk_details": [
                        {
                            "chunk_id": str(chunk.get('id')),
                            "start_time": chunk.get('start_time', 0),
                            "end_time": chunk.get('end_time', 0),
                            "duration": chunk.get('duration', 0),
                            "confidence": chunk.get('confidence', 0.0)
                        }
                        for chunk in chunks if chunk.get('transcription')
                    ]
                },
                userid=next(
                    (chunk.get('userid') for chunk in chunks if chunk.get('userid')), 
                    None
                ),
                resource_timestamp=datetime.now(timezone.utc)
            )
            
            # Save the Resource
            p8.repository(Resources).update_records([resource])
            logger.info(f"Created Resource {resource_id} for audio file {audio_file.id} with {len(chunks)} chunks")
            
        except Exception as e:
            logger.error(f"Error creating Resource for audio file {audio_file.id}: {str(e)}")
            import traceback
            logger.error(f"Traceback: {traceback.format_exc()}")
            # Don't re-raise - this is a non-critical operation
    
    def _cleanup_temp_files(self):
        """Clean up any temporary files/directories created during processing."""
        for path in self.temp_files:
            try:
                if os.path.isdir(path):
                    shutil.rmtree(path)
                    logger.info(f"Removed temporary directory: {path}")
                elif os.path.isfile(path):
                    os.unlink(path)
                    logger.info(f"Removed temporary file: {path}")
            except Exception as e:
                logger.warning(f"Error cleaning up temporary path {path}: {e}")
        
        # Clear the list
        self.temp_files = []
    
    def _silero_vad(self, audio_path, threshold=0.5, min_speech_ms=250, min_silence_ms=500):
        """
        Detect speech segments using Silero-VAD.
        
        Args:
            audio_path: Path to the audio file
            threshold: VAD threshold (0.0-1.0)
            min_speech_ms: Minimum speech segment duration in ms
            min_silence_ms: Minimum silence duration in ms
            
        Returns:
            List of (start_time, end_time) tuples in seconds
        """
        logger.info(f"Running Silero-VAD on {audio_path} with threshold {threshold}")
        
        try:
            import torch
            import torchaudio
            
            # Convert to format expected by torch
            with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
                temp_path = temp_file.name
                self.temp_files.append(temp_path)  # Track for cleanup
                
                # If using PyDub, convert to the right format first
                try:
                    from pydub import AudioSegment
                    audio = AudioSegment.from_file(audio_path)
                    # Set to mono if needed for better VAD
                    if audio.channels > 1:
                        audio = audio.set_channels(1)
                    # Export to temp file
                    audio.export(temp_path, format="wav")
                    logger.info(f"Converted audio to mono WAV for Silero VAD")
                except ImportError:
                    # If PyDub isn't available, just copy the file
                    import shutil
                    shutil.copy(audio_path, temp_path)
                    logger.info(f"Copied audio file for Silero VAD")
            
            # Load with torchaudio
            waveform, sample_rate = torchaudio.load(temp_path)
            if waveform.shape[0] > 1:  # Convert to mono if still stereo
                waveform = torch.mean(waveform, dim=0, keepdim=True)
            
            # Get the Silero VAD model
            logger.info("Loading Silero VAD model...")
            model, utils = torch.hub.load(
                repo_or_dir='snakers4/silero-vad',
                model='silero_vad',
                force_reload=False
            )
            
            # Unpack utilities
            (get_speech_timestamps, _, _, _, _) = utils
            
            # Run VAD with configured threshold
            logger.info(f"Running Silero VAD inference with threshold={threshold}...")
            speech_timestamps = get_speech_timestamps(
                waveform[0], 
                model,
                threshold=threshold,
                sampling_rate=sample_rate,
                min_speech_duration_ms=min_speech_ms,
                min_silence_duration_ms=min_silence_ms
            )
            
            # Convert to seconds
            speech_segments = [
                (ts['start'] / sample_rate, ts['end'] / sample_rate) 
                for ts in speech_timestamps
            ]
            
            logger.info(f"Silero VAD detected {len(speech_segments)} speech segments")
            
            # If no segments were found, use the whole file
            if not speech_segments:
                logger.warning("No speech segments detected with Silero VAD, using the entire file")
                # Get file duration from waveform
                duration_sec = waveform.shape[1] / sample_rate
                speech_segments = [(0.0, duration_sec)]
            
            return speech_segments
            
        except Exception as e:
            logger.error(f"Error using Silero VAD: {e}")
            import traceback
            logger.error(traceback.format_exc())
            # Return None to trigger fallback to energy-based VAD
            return None
    
    def _energy_based_vad(self, audio_path, threshold_db=-35, min_silence_ms=500, min_speech_ms=250):
        """
        Detect speech segments using simple energy-based VAD.
        
        Args:
            audio_path: Path to the audio file
            threshold_db: Energy threshold in dB
            min_silence_ms: Minimum silence duration in ms
            min_speech_ms: Minimum speech segment duration in ms
            
        Returns:
            List of (start_time, end_time) tuples in seconds
        """
        logger.info(f"Running energy-based VAD on {audio_path} with threshold {threshold_db} dB")
        
        try:
            # Check if PyDub is available
            from pydub import AudioSegment
            
            # Try to load the audio file
            try:
                audio = AudioSegment.from_file(audio_path)
                logger.info(f"Loaded audio file: duration={len(audio)/1000.0}s, channels={audio.channels}")
                
                # Process in 10ms windows
                window_ms = 10
                segments = []
                is_speech = False
                current_segment_start = 0
                silence_start = 0
                
                # Process the audio in windows
                for i in range(0, len(audio), window_ms):
                    segment = audio[i:i+window_ms]
                    # Use dBFS (dB relative to full scale) for energy measurement
                    energy_db = segment.dBFS
                    
                    if energy_db > threshold_db and energy_db != float('-inf'):
                        # This is a speech window
                        if not is_speech:
                            is_speech = True
                            current_segment_start = i
                        # Reset silence counter
                        silence_start = 0
                    else:
                        # This is a silence window
                        if is_speech:
                            # Count silence
                            if silence_start == 0:
                                silence_start = i
                            
                            # If silence is long enough, end the segment
                            if i - silence_start >= min_silence_ms:
                                is_speech = False
                                # Only add segments that are long enough
                                if silence_start - current_segment_start >= min_speech_ms:
                                    segments.append((current_segment_start / 1000.0, silence_start / 1000.0))
                
                # Add the final segment if needed
                if is_speech and len(audio) - current_segment_start >= min_speech_ms:
                    segments.append((current_segment_start / 1000.0, len(audio) / 1000.0))
                
                logger.info(f"Found {len(segments)} speech segments")
                
                # If no segments were found, use the whole file
                if not segments:
                    logger.warning("No speech segments detected, using the entire file")
                    segments = [(0.0, len(audio) / 1000.0)]
                
                return segments
                
            except Exception as audio_error:
                logger.error(f"Error processing audio file: {audio_error}")
                # Fall back to simulated segments
        
        except ImportError:
            logger.warning("PyDub not available, using simulated speech segments")
        
        # If we can't process the audio or encounter an error, return a single segment covering the whole file
        # In a real application we might want to improve this fallback with better error handling
        logger.info("Using simulated speech segments for the whole file")
        # Assume a 60-second file
        duration = 60.0
        return [(0.0, duration)]
    
    def _process_speech_segments(self, 
                               segments: List[Tuple[float, float]], 
                               max_segment_length: float = 30.0,
                               min_segment_length: float = 0.5, 
                               merge_threshold: float = 0.3) -> List[Tuple[float, float]]:
        """
        Process speech segments to optimize for API calls and reduce fragmentation.
        
        This function:
        1. Merges segments that are too close together (gap < merge_threshold)
        2. Splits segments that are too long for API limits
        3. Removes segments that are too short to be useful
        
        Args:
            segments: List of (start_time, end_time) tuples in seconds
            max_segment_length: Maximum length of a segment in seconds (for API limits)
            min_segment_length: Minimum length of a segment to keep in seconds
            merge_threshold: Merge segments with gaps smaller than this (in seconds)
            
        Returns:
            Processed list of (start_time, end_time) tuples
        """
        if not segments:
            logger.warning("No segments to process")
            return segments
        
        logger.info(f"Processing {len(segments)} speech segments")
        logger.info(f"Parameters: max_length={max_segment_length}s, min_length={min_segment_length}s, merge_threshold={merge_threshold}s")
        
        # 1. Sort segments by start time
        sorted_segments = sorted(segments, key=lambda x: x[0])
        
        # 2. Merge segments that are close together
        merged_segments = []
        current_start, current_end = sorted_segments[0]
        
        for start, end in sorted_segments[1:]:
            # If this segment starts soon after the previous one ends, merge them
            if start - current_end <= merge_threshold:
                # Extend the current segment
                current_end = end
            else:
                # Add the current segment and start a new one
                merged_segments.append((current_start, current_end))
                current_start, current_end = start, end
        
        # Add the last segment
        merged_segments.append((current_start, current_end))
        
        logger.info(f"After merging: {len(merged_segments)} segments")
        
        # 3. Split segments that are too long
        split_segments = []
        for start, end in merged_segments:
            duration = end - start
            
            if duration > max_segment_length:
                # Split into chunks of max_segment_length
                logger.info(f"Splitting segment of {duration:.2f}s into smaller chunks")
                num_chunks = int(duration / max_segment_length) + 1
                chunk_duration = duration / num_chunks
                
                # Create evenly sized chunks
                for i in range(num_chunks):
                    chunk_start = start + (i * chunk_duration)
                    chunk_end = min(start + ((i + 1) * chunk_duration), end)
                    split_segments.append((chunk_start, chunk_end))
            else:
                # Keep as is
                split_segments.append((start, end))
        
        logger.info(f"After splitting: {len(split_segments)} segments")
        
        # 4. Filter out segments that are too short
        filtered_segments = [
            (start, end) for start, end in split_segments 
            if (end - start) >= min_segment_length
        ]
        
        logger.info(f"After filtering: {len(filtered_segments)} segments")
        
        # 5. Final sanity check - make sure we have at least one segment
        if not filtered_segments:
            logger.warning("All segments were filtered out. Using the first original segment.")
            if segments:
                filtered_segments = [segments[0]]
        
        # Log each final segment
        for i, (start, end) in enumerate(filtered_segments):
            logger.info(f"Segment {i+1}: {start:.2f}s - {end:.2f}s (duration: {end-start:.2f}s)")
        
        return filtered_segments
        
    async def transcribe_audio(self, audio_path: str) -> Tuple[str, float]:
        """
        Transcribe an audio file using the OpenAI Whisper API via direct REST calls.
        
        Args:
            audio_path: Path to the audio file
            
        Returns:
            Tuple of (transcription, confidence)
            
        Raises:
            Exception: If transcription fails for any reason
        """
        logger.info(f"Transcribing audio file: {audio_path}")
        
        # Check if the OpenAI API key is available
        api_key = self.openai_api_key
        if not api_key:
            logger.error("OpenAI API key not available")
            raise Exception("OpenAI API key not available in environment")
        
        # Verify the file exists and is a valid audio file
        if not os.path.exists(audio_path):
            logger.error(f"Audio file does not exist: {audio_path}")
            raise FileNotFoundError(f"Audio file not found: {audio_path}")
        
        # Check if file is too small to be valid audio
        if os.path.getsize(audio_path) < 100:  # Arbitrary minimum size
            logger.error(f"Audio file is too small to be valid: {audio_path} ({os.path.getsize(audio_path)} bytes)")
            raise ValueError(f"Audio file is too small to be valid: {audio_path}")
        
        # Attempt to transcribe the audio file
        import requests
        import ssl
        from urllib3.util.ssl_ import create_urllib3_context
        
        # Create a custom SSL context to handle modern TLS
        ssl_context = create_urllib3_context()
        ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
        
        # Create a session with retry logic and proper SSL configuration
        session = requests.Session()
        
        # Configure retries
        from urllib3.util.retry import Retry
        from requests.adapters import HTTPAdapter
        
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("https://", adapter)
        
        url = "https://api.openai.com/v1/audio/transcriptions"
        headers = {
            "Authorization": f"Bearer {api_key}"
        }
        
        logger.info(f"Sending file to OpenAI Whisper API: {audio_path}")
        
        # Open the file in binary mode
        with open(audio_path, "rb") as audio_file:
            # Prepare the file for upload with explicit MIME type
            files = {
                "file": (os.path.basename(audio_path), audio_file, "audio/wav")
            }
            
            # Set up the data payload
            data = {
                "model": "whisper-1",
                "response_format": "text"
            }
            
            # Send the request with a timeout and SSL error handling
            logger.info("Sending request to OpenAI API...")
            try:
                response = session.post(url, headers=headers, files=files, data=data, timeout=60)
            except requests.exceptions.SSLError as ssl_error:
                logger.error(f"SSL error occurred: {ssl_error}")
                # Try once more with a fresh session
                logger.info("Retrying with a fresh session...")
                new_session = requests.Session()
                new_session.mount("https://", adapter)
                response = new_session.post(url, headers=headers, files=files, data=data, timeout=60)
            
            # Handle the response
            if response.status_code == 200:
                # Successful transcription
                transcription = response.text.strip()
                confidence = 0.9  # OpenAI doesn't provide confidence scores
                
                logger.info(f"Transcription successful: {transcription[:50]}...")
                return transcription, confidence
            else:
                # API error
                error_text = response.text
                error_msg = f"OpenAI API error: {response.status_code} - {error_text}"
                logger.error(error_msg)
                
                if "not a valid audio file" in error_text.lower():
                    raise ValueError(f"Invalid audio format: OpenAI requires valid WAV files")
                else:
                    raise Exception(error_msg)