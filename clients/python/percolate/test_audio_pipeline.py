#!/usr/bin/env python3
"""
Script to test the audio processing pipeline.
This is a simplified version of the audio processing pipeline for testing purposes.
"""

import os
import asyncio
import uuid
from pydub import AudioSegment
import logging
from pathlib import Path
import tempfile
from datetime import datetime, timezone

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("audio_test")

# Test file path
TEST_AUDIO_FILE = "/Users/sirsh/Downloads/INST_018.wav"

class AudioProcessor:
    """Simplified audio processor for testing."""
    
    def __init__(self, vad_threshold=0.5, energy_threshold=-35):
        self.vad_threshold = vad_threshold
        self.energy_threshold = energy_threshold
        
        # Check for PyTorch availability
        self.torch_available = False
        try:
            import torch
            import torchaudio
            self.torch_available = True
            logger.info(f"PyTorch is available: {torch.__version__}")
        except ImportError:
            logger.info("PyTorch is not available - will use energy-based VAD")
        
        self.openai_api_key = os.environ.get("OPENAI_API_KEY")
    
    def _energy_based_vad(self, audio, threshold_db=-35, min_silence_ms=500, min_speech_ms=250):
        """
        Detect speech segments using simple energy-based VAD.
        
        Args:
            audio: PyDub AudioSegment
            threshold_db: Energy threshold in dB
            min_silence_ms: Minimum silence duration in ms
            min_speech_ms: Minimum speech segment duration in ms
            
        Returns:
            List of (start_ms, end_ms) segments
        """
        logger.info(f"Using energy-based VAD with threshold {threshold_db} dB")
        
        # Process in 10ms windows
        window_ms = 10
        segments = []
        is_speech = False
        current_segment_start = 0
        silence_start = 0
        
        # Process the audio in windows
        for i in range(0, len(audio), window_ms):
            segment = audio[i:i+window_ms]
            energy_db = segment.dBFS
            
            if energy_db > threshold_db:
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
                            segments.append((current_segment_start, silence_start))
        
        # Add the final segment if needed
        if is_speech and len(audio) - current_segment_start >= min_speech_ms:
            segments.append((current_segment_start, len(audio)))
        
        # Convert milliseconds to seconds
        segments_sec = [(start / 1000.0, end / 1000.0) for start, end in segments]
        
        logger.info(f"Found {len(segments_sec)} speech segments")
        return segments_sec
    
    async def transcribe_chunk(self, audio_chunk, chunk_path):
        """Simulate transcription for testing."""
        # In a real implementation, this would call the Whisper API
        chunk_duration = len(audio_chunk) / 1000.0
        if self.openai_api_key:
            try:
                import requests
                import time
                
                url = "https://api.openai.com/v1/audio/transcriptions"
                headers = {
                    "Authorization": f"Bearer {self.openai_api_key}"
                }
                
                # Add retry logic with exponential backoff
                max_retries = 2
                retry_delay = 1  # seconds
                
                for retry in range(max_retries):
                    try:
                        if retry > 0:
                            logger.info(f"Retry attempt {retry}/{max_retries-1}...")
                            
                        logger.info(f"Sending file to OpenAI Whisper API (REST)")
                        
                        with open(chunk_path, "rb") as audio_file:
                            files = {
                                "file": (os.path.basename(chunk_path), audio_file, "audio/wav")
                            }
                            data = {
                                "model": "whisper-1",
                                "response_format": "text"
                            }
                            
                            logger.info("Sending request to OpenAI API...")
                            response = requests.post(url, headers=headers, files=files, data=data, timeout=60)
                            
                            if response.status_code == 200:
                                transcription = response.text.strip()
                                logger.info(f"Transcription successful: {transcription[:50]}...")
                                return transcription, 0.9
                            else:
                                logger.error(f"Error from OpenAI API: {response.status_code} - {response.text}")
                                if retry < max_retries - 1:
                                    logger.info(f"Waiting {retry_delay} seconds before retrying...")
                                    time.sleep(retry_delay)
                                    retry_delay *= 2  # Exponential backoff
                                    continue
                                return f"API error: {response.status_code}", 0.0
                    
                    except Exception as e:
                        logger.error(f"Request error: {e}")
                        if retry < max_retries - 1:
                            logger.info(f"Waiting {retry_delay} seconds before retrying...")
                            time.sleep(retry_delay)
                            retry_delay *= 2  # Exponential backoff
                        else:
                            return f"Transcription error: {e}", 0.0
            except Exception as e:
                logger.error(f"Transcription setup error: {e}")
                return f"Setup error: {e}", 0.0
                
        return f"Simulated transcription for speech segment of {chunk_duration:.2f} seconds", 0.8
    
    async def process_file(self, file_path):
        """Process an audio file with real processing."""
        logger.info(f"Processing audio file: {file_path}")
        
        file_path = Path(file_path)
        if not file_path.exists():
            logger.error(f"Error: File not found: {file_path}")
            return False
        
        # Generate a file ID
        file_id = str(uuid.uuid4())
        logger.info(f"Assigned file ID: {file_id}")
        
        try:
            # Load the audio using PyDub
            audio = AudioSegment.from_file(file_path)
            
            # Get audio properties
            duration_sec = len(audio) / 1000.0
            file_size = os.path.getsize(file_path)
            
            logger.info(f"Audio file loaded: {file_path.name}")
            logger.info(f"Duration: {duration_sec:.2f} seconds")
            logger.info(f"File size: {file_size} bytes")
            logger.info(f"Channels: {audio.channels}")
            logger.info(f"Frame rate: {audio.frame_rate} Hz")
            
            # Detect speech segments
            logger.info("Detecting speech segments...")
            
            # Use PyTorch/Silero if available, otherwise use energy-based VAD
            speech_segments = None
            
            if self.torch_available:
                logger.info("Attempting to use Silero VAD...")
                try:
                    import torch
                    import torchaudio
                    
                    # Convert to format expected by torch
                    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
                        temp_path = temp_file.name
                        audio.export(temp_path, format="wav")
                    
                    # Load with torchaudio
                    waveform, sample_rate = torchaudio.load(temp_path)
                    if waveform.shape[0] > 1:  # Convert to mono if stereo
                        waveform = torch.mean(waveform, dim=0, keepdim=True)
                    
                    # Get the Silero VAD model
                    model, utils = torch.hub.load(
                        repo_or_dir='snakers4/silero-vad',
                        model='silero_vad',
                        force_reload=False
                    )
                    
                    # Unpack utilities
                    (get_speech_timestamps, _, _, _, _) = utils
                    
                    # Run VAD with configured threshold
                    speech_timestamps = get_speech_timestamps(
                        waveform[0], 
                        model,
                        threshold=self.vad_threshold,
                        sampling_rate=sample_rate
                    )
                    
                    # Convert to seconds
                    speech_segments = [
                        (ts['start'] / sample_rate, ts['end'] / sample_rate) 
                        for ts in speech_timestamps
                    ]
                    
                    logger.info(f"Silero VAD detected {len(speech_segments)} speech segments")
                    
                    # Clean up
                    os.unlink(temp_path)
                except Exception as e:
                    logger.error(f"Error using Silero VAD: {e}")
                    speech_segments = None
            
            # Fall back to energy-based VAD if needed
            if speech_segments is None:
                speech_segments = self._energy_based_vad(
                    audio, 
                    threshold_db=self.energy_threshold
                )
            
            # Process chunks
            logger.info("Processing speech segments into chunks...")
            results = []
            
            for i, (start_time, end_time) in enumerate(speech_segments):
                logger.info(f"Processing chunk {i+1}/{len(speech_segments)}: {start_time:.2f}s - {end_time:.2f}s")
                
                # Extract the segment from the audio
                chunk_audio = audio[int(start_time * 1000):int(end_time * 1000)]
                
                # Save it to a temporary file
                with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
                    temp_path = temp_file.name
                    chunk_audio.export(temp_path, format="wav")
                    logger.info(f"Saved chunk to temporary file: {temp_path}")
                
                # Transcribe the chunk
                logger.info(f"Transcribing chunk {i+1}/{len(speech_segments)}...")
                transcription, confidence = await self.transcribe_chunk(chunk_audio, temp_path)
                
                chunk_info = {
                    "id": str(uuid.uuid4()),
                    "start_time": start_time,
                    "end_time": end_time,
                    "duration": end_time - start_time,
                    "transcription": transcription,
                    "confidence": confidence
                }
                results.append(chunk_info)
                
                # Clean up temporary file
                try:
                    os.unlink(temp_path)
                except Exception as e:
                    logger.warning(f"Could not delete temporary file {temp_path}: {e}")
                
                logger.info(f"Completed chunk {i+1}/{len(speech_segments)}")
            
            # Compile full transcription
            full_transcription = "\n\n".join([
                f"[{chunk['start_time']:.2f}s - {chunk['end_time']:.2f}s]: {chunk['transcription']}"
                for chunk in results
            ])
            
            logger.info("Audio processing completed successfully")
            logger.info(f"Found {len(results)} chunks")
            logger.info(f"Full transcription:\n{full_transcription}")
            
            return results
        
        except Exception as e:
            logger.error(f"Error processing audio: {e}")
            import traceback
            logger.error(traceback.format_exc())
            return None

async def main():
    """Main function."""
    if not os.path.exists(TEST_AUDIO_FILE):
        logger.error(f"Test audio file not found: {TEST_AUDIO_FILE}")
        return 1
    
    # Process the file
    processor = AudioProcessor(
        vad_threshold=0.5,
        energy_threshold=-35
    )
    
    logger.info(f"Processing {TEST_AUDIO_FILE}")
    logger.info(f"VAD threshold: {processor.vad_threshold}")
    logger.info(f"Energy threshold: {processor.energy_threshold} dB")
    
    # Create a shorter sample for testing (first 30 seconds)
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
        temp_path = temp_file.name
        audio = AudioSegment.from_file(TEST_AUDIO_FILE)
        # Take just the first 30 seconds
        short_audio = audio[:30000]
        logger.info(f"Created shorter test sample (30 seconds) at {temp_path}")
        short_audio.export(temp_path, format="wav")
        
        # Process the shorter file
        results = await processor.process_file(temp_path)
        
        # Clean up
        try:
            os.unlink(temp_path)
        except:
            pass
    
    if results:
        logger.info(f"Processing completed successfully")
        logger.info(f"Found {len(results)} chunks")
        
        # Log a sample of the results
        for i, chunk in enumerate(results[:3]):  # Show up to 3 chunks
            logger.info(f"Chunk {i+1}: {chunk['start_time']:.2f}s - {chunk['end_time']:.2f}s")
            logger.info(f"  Transcription: {chunk['transcription'][:80]}...")
        
        if len(results) > 3:
            logger.info(f"... and {len(results) - 3} more chunks")
        
        return 0
    else:
        logger.error("Processing failed")
        return 1

if __name__ == "__main__":
    asyncio.run(main())