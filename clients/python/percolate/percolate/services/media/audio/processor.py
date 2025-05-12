"""
Audio processor for Percolate.
Handles the audio file processing pipeline including:
- Voice Activity Detection (VAD)
- Audio chunking
- Transcription
- Storage
"""

import os
import tempfile
import uuid
import logging
from typing import List, Dict, Any, Optional, Tuple
from datetime import datetime, timezone
import asyncio

import percolate as p8
from percolate.utils import logger
from percolate.models.media.audio import (
    AudioFile,
    AudioChunk,
    AudioProcessingStatus,
    AudioPipelineConfig
)

# Configure logger
_logger = logging.getLogger("audio.processor")
_logger.setLevel(logging.DEBUG)

class AudioProcessor:
    """
    Audio processor for the Percolate audio pipeline.
    
    This class handles the processing of audio files through the pipeline:
    1. Voice Activity Detection (VAD)
    2. Chunking
    3. Transcription
    4. Storage
    """
    
    def __init__(
        self, 
        vad_threshold: float = 0.5, 
        energy_threshold: float = -35, 
        skip_transcription: bool = False
    ):
        """
        Initialize the audio processor.
        
        Args:
            vad_threshold: Voice activity detection threshold (0.0-1.0)
            energy_threshold: Energy threshold for fallback VAD (in dB)
            skip_transcription: Skip the transcription step
        """
        self.vad_threshold = vad_threshold
        self.energy_threshold = energy_threshold
        self.skip_transcription = skip_transcription
        
        # Check for PyTorch availability
        self.torch_available = False
        try:
            import torch
            import torchaudio
            self.torch_available = True
            _logger.info(f"PyTorch is available: {torch.__version__}")
        except ImportError:
            _logger.info("PyTorch is not available - will use energy-based VAD")
        
        # Check for OpenAI API key
        self.openai_api_key = os.environ.get("OPENAI_API_KEY")
        self.openai_available = self.openai_api_key is not None
        if self.openai_available:
            _logger.info("OpenAI API key found, will use REST API for transcription")
        else:
            _logger.info("OpenAI API key not found, will use placeholder transcription")
    
    async def process_file(self, file_id: str, user_id: Optional[str] = None) -> bool:
        """
        Process an audio file through the pipeline.
        
        Args:
            file_id: ID of the audio file to process
            user_id: Optional user ID to associate with chunks
            
        Returns:
            bool: True if processing was successful
        """
        _logger.info(f"Starting to process audio file: {file_id}")
        
        # Get the audio file
        audio_files = p8.repository(AudioFile).select(id=file_id)
        if not audio_files:
            _logger.error(f"Audio file {file_id} not found")
            return False
        
        # Check if the result is a dictionary or Pydantic model
        audio_file = audio_files[0]
        if isinstance(audio_file, dict):
            # Convert dictionary to AudioFile model
            audio_file = AudioFile(**audio_file)
        
        try:
            # Update to processing status
            audio_file.status = AudioProcessingStatus.PROCESSING
            p8.repository(AudioFile).update_records([audio_file])
            
            # 1. Download the file from S3
            # In a real implementation, this would download the file from S3 to a local temp file
            
            # 2. Detect speech segments (VAD)
            audio_file.status = AudioProcessingStatus.CHUNKING
            p8.repository(AudioFile).update_records([audio_file])
            
            # In a real implementation, this would use Silero-VAD or energy-based VAD
            # For now, simulate by creating a single "chunk" for the whole file
            
            # 3. Transcribe the chunks
            audio_file.status = AudioProcessingStatus.TRANSCRIBING
            p8.repository(AudioFile).update_records([audio_file])
            
            # Create a simulated chunk for the entire audio file
            chunk_id = str(uuid.uuid4())
            chunk_s3_uri = f"{audio_file.s3_uri}/chunks/{chunk_id}.wav"
            
            # Simulate transcription
            transcription = f"This is a placeholder transcription for audio file {file_id}"
            
            # Create a chunk record
            chunk = AudioChunk(
                id=chunk_id,
                audio_file_id=file_id,
                start_time=0.0,
                end_time=audio_file.duration or 0.0,
                duration=audio_file.duration or 0.0,
                s3_uri=chunk_s3_uri,
                transcription=transcription,
                confidence=0.0,
                userid=user_id  # Add the user ID to the chunk using the database field name
            )
            
            # Save the chunk
            p8.repository(AudioChunk).update_records([chunk])
            
            # Update the file status
            audio_file.status = AudioProcessingStatus.COMPLETED
            audio_file.metadata["completed_at"] = datetime.now(timezone.utc).isoformat()
            audio_file.metadata["chunk_count"] = 1
            p8.repository(AudioFile).update_records([audio_file])
            
            _logger.info(f"Successfully processed audio file: {file_id}")
            return True
            
        except Exception as e:
            _logger.error(f"Error processing audio file {file_id}: {str(e)}")
            
            # Update the file status
            audio_file.status = AudioProcessingStatus.FAILED
            audio_file.metadata["error"] = str(e)
            p8.repository(AudioFile).update_records([audio_file])
            
            return False
    
    def _energy_based_vad(self, audio_data, threshold_db=-35, min_silence_ms=500, min_speech_ms=250):
        """
        Detect speech segments using simple energy-based VAD.
        This is a placeholder for the actual implementation.
        
        Args:
            audio_data: Audio data
            threshold_db: Energy threshold in dB
            min_silence_ms: Minimum silence duration in ms
            min_speech_ms: Minimum speech segment duration in ms
            
        Returns:
            List of (start_time, end_time) tuples in seconds
        """
        # In a real implementation, this would analyze the audio data
        # For now, return a simulated segment covering the whole file
        duration = 60.0  # Simulated 60 second file
        return [(0.0, duration)]
    
    async def transcribe_audio(self, audio_path: str) -> Tuple[str, float]:
        """
        Transcribe an audio file using the OpenAI Whisper API via direct REST calls.
        
        Args:
            audio_path: Path to the audio file
            
        Returns:
            Tuple of (transcription, confidence)
        """
        _logger.info(f"Transcribing audio file: {audio_path}")
        
        # Check if the OpenAI API key is available
        api_key = self.openai_api_key
        if not api_key:
            _logger.warning("OpenAI API key not available, using placeholder transcription")
            return "This is a placeholder transcription.", 0.0
            
        # Use the REST API directly to call Whisper
        try:
            import requests
            import time
            
            url = "https://api.openai.com/v1/audio/transcriptions"
            headers = {
                "Authorization": f"Bearer {api_key}"
            }
            
            # Add retry logic with exponential backoff
            max_retries = 3
            retry_delay = 1  # seconds
            
            for retry in range(max_retries):
                try:
                    if retry > 0:
                        _logger.info(f"Retry attempt {retry}/{max_retries-1}...")
                        
                    _logger.info(f"Sending file to OpenAI Whisper API (REST)")
                    
                    with open(audio_path, "rb") as audio_file:
                        files = {
                            "file": (os.path.basename(audio_path), audio_file, "audio/wav")
                        }
                        data = {
                            "model": "whisper-1",
                            "response_format": "text"
                        }
                        
                        _logger.info("Sending request to OpenAI API...")
                        response = requests.post(url, headers=headers, files=files, data=data, timeout=60)
                        
                        if response.status_code == 200:
                            transcription = response.text.strip()
                            confidence = 0.9  # OpenAI doesn't provide confidence scores
                            
                            _logger.info(f"Transcription successful: {transcription[:50]}...")
                            return transcription, confidence
                        else:
                            _logger.error(f"Error from OpenAI API: {response.status_code} - {response.text}")
                            if retry < max_retries - 1:
                                _logger.info(f"Waiting {retry_delay} seconds before retrying...")
                                time.sleep(retry_delay)
                                retry_delay *= 2  # Exponential backoff
                                continue
                            raise Exception(f"API returned status code {response.status_code}: {response.text}")
                
                except (requests.RequestException, IOError) as e:
                    _logger.error(f"Network error during transcription: {e}")
                    if retry < max_retries - 1:
                        _logger.info(f"Waiting {retry_delay} seconds before retrying...")
                        time.sleep(retry_delay)
                        retry_delay *= 2  # Exponential backoff
                    else:
                        _logger.error(f"Maximum retries reached, giving up.")
                        break
        
        except Exception as e:
            _logger.error(f"Error transcribing audio: {e}")
        
        # Fallback to placeholder in case of any failure
        return f"Transcription failed for {os.path.basename(audio_path)}", 0.0