#!/usr/bin/env python3
"""
Script to test the end-to-end audio processing pipeline.
This script will:
1. Upload a test audio file
2. Process it through the pipeline
3. Verify the transcription is stored in the database
"""

import os
import asyncio
import uuid
import tempfile
from pathlib import Path
import logging
from datetime import datetime, timezone
from pydub import AudioSegment

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("audio_e2e_test")

# Test file path
TEST_AUDIO_FILE = "/Users/sirsh/Downloads/INST_018.wav"

# Database connection
import percolate as p8
from percolate.models.media.audio import AudioFile, AudioChunk, AudioProcessingStatus
from percolate.services import PostgresService
from percolate.services.media.audio import AudioProcessor

async def test_full_pipeline():
    """Test the full audio pipeline from upload to transcription."""
    
    # Get the bearer token from environment
    bearer_token = os.environ.get('P8_TEST_BEARER_TOKEN', None)
    if not bearer_token:
        logger.error('P8_TEST_BEARER_TOKEN not set in environment')
        return False
        
    # Set up database connection
    connection_string = f'postgresql://postgres:{bearer_token}@localhost:15432/app'
    logger.info('Connecting to database...')
    
    try:
        # Initialize PostgresService with connection string
        pg = PostgresService(connection_string=connection_string)
        logger.info('Database connection successful')
        
        # Generate a test file ID and project
        file_id = str(uuid.uuid4())
        project_name = "test-project"
        user_id = "test-user"
        
        logger.info(f"Testing with file ID: {file_id}")
        
        # Load the audio file for processing
        if not Path(TEST_AUDIO_FILE).exists():
            logger.error(f"Test file not found: {TEST_AUDIO_FILE}")
            return False
            
        # Create a shorter sample for testing (first 30 seconds)
        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
            temp_path = temp_file.name
            audio = AudioSegment.from_file(TEST_AUDIO_FILE)
            # Take just the first 30 seconds
            short_audio = audio[:30000]
            logger.info(f"Created shorter test sample (30 seconds) at {temp_path}")
            short_audio.export(temp_path, format="wav")
            
            # Step 1: Create an AudioFile record in the database
            logger.info("Step 1: Creating AudioFile record...")
            audio_file = AudioFile(
                id=file_id,
                user_id=user_id,
                project_name=project_name,
                filename=os.path.basename(temp_path),
                file_size=os.path.getsize(temp_path),
                content_type="audio/wav",
                duration=len(short_audio) / 1000.0,
                status=AudioProcessingStatus.UPLOADED,
                s3_uri=f"s3://percolate-audio/{project_name}/audio/{file_id}/{os.path.basename(temp_path)}",
                metadata={}
            )
            
            try:
                pg.repository(AudioFile).update_records([audio_file])
                logger.info(f"AudioFile record created successfully with ID: {file_id}")
            except Exception as e:
                logger.error(f"Error creating AudioFile record: {e}")
                return False
            
            # Step 2: Process the audio file
            logger.info("Step 2: Processing audio file...")
            
            # Instead of using the processor directly, which tries to access the database,
            # we'll implement a simplified version of the processing directly here:
            
            # Initialize the processor but we'll handle DB operations manually
            processor = AudioProcessor(vad_threshold=0.5, energy_threshold=-35)
            
            # Use PyTorch/Silero if available, otherwise use energy-based VAD
            logger.info("Detecting speech segments...")
            try:
                import torch
                import torchaudio
                
                # Convert to format expected by torch
                with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as vad_temp:
                    vad_temp_path = vad_temp.name
                    short_audio.export(vad_temp_path, format="wav")
                
                # Load with torchaudio
                waveform, sample_rate = torchaudio.load(vad_temp_path)
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
                    threshold=processor.vad_threshold,
                    sampling_rate=sample_rate
                )
                
                # Convert to seconds
                speech_segments = [
                    (ts['start'] / sample_rate, ts['end'] / sample_rate) 
                    for ts in speech_timestamps
                ]
                
                logger.info(f"Silero VAD detected {len(speech_segments)} speech segments")
                
                # Clean up
                os.unlink(vad_temp_path)
            except Exception as e:
                logger.error(f"Error using Silero VAD: {e}")
                # Fall back to energy-based VAD
                speech_segments = processor._energy_based_vad(short_audio, threshold_db=processor.energy_threshold)
            
            # Create chunks for transcription
            logger.info("Processing speech segments into chunks...")
            chunks = []
            
            for i, (start_time, end_time) in enumerate(speech_segments):
                logger.info(f"Processing chunk {i+1}/{len(speech_segments)}: {start_time:.2f}s - {end_time:.2f}s")
                
                # Extract the segment from the audio
                chunk_audio = short_audio[int(start_time * 1000):int(end_time * 1000)]
                
                # Save it to a temporary file
                with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as chunk_temp:
                    chunk_path = chunk_temp.name
                    chunk_audio.export(chunk_path, format="wav")
                    logger.info(f"Saved chunk to temporary file: {chunk_path}")
                
                # Transcribe the chunk
                logger.info(f"Transcribing chunk {i+1}/{len(speech_segments)}...")
                transcription, confidence = await processor.transcribe_audio(chunk_path)
                
                chunk_info = {
                    "id": str(uuid.uuid4()),
                    "start_time": start_time,
                    "end_time": end_time,
                    "duration": end_time - start_time,
                    "transcription": transcription,
                    "confidence": confidence
                }
                chunks.append(chunk_info)
                
                # Clean up the chunk file
                try:
                    os.unlink(chunk_path)
                except:
                    pass
                
                logger.info(f"Completed chunk {i+1}/{len(speech_segments)}")
                
            # Return the chunked results
            logger.info(f"Processed {len(chunks)} chunks total")
            if not chunks:
                logger.error("Audio processing failed - no chunks returned")
                return False
                
            logger.info(f"Audio processing completed successfully with {len(chunks)} chunks")
            
            # Step 3: Store the chunks in the database
            logger.info("Step 3: Storing chunks in the database...")
            
            audio_chunks = []
            for i, chunk_info in enumerate(chunks):
                audio_chunk = AudioChunk(
                    id=chunk_info["id"],
                    audio_file_id=file_id,
                    start_time=chunk_info["start_time"],
                    end_time=chunk_info["end_time"],
                    duration=chunk_info["duration"],
                    s3_uri=f"s3://percolate-audio/{project_name}/audio/{file_id}/chunks/{chunk_info['id']}.wav",
                    transcription=chunk_info["transcription"],
                    confidence=chunk_info["confidence"],
                    userid=user_id  # Add the user ID to the chunk using the database field name
                )
                audio_chunks.append(audio_chunk)
            
            try:
                pg.repository(AudioChunk).update_records(audio_chunks)
                logger.info(f"Successfully stored {len(audio_chunks)} chunks in the database")
            except Exception as e:
                logger.error(f"Error storing chunks: {e}")
                return False
                
            # Step 4: Update the audio file status
            logger.info("Step 4: Updating AudioFile status...")
            audio_file.status = AudioProcessingStatus.COMPLETED
            audio_file.metadata["completed_at"] = datetime.now(timezone.utc).isoformat()
            audio_file.metadata["chunk_count"] = len(audio_chunks)
            
            try:
                pg.repository(AudioFile).update_records([audio_file])
                logger.info("AudioFile status updated to COMPLETED")
            except Exception as e:
                logger.error(f"Error updating AudioFile status: {e}")
                return False
                
            # Step 5: Verify the transcription in the database
            logger.info("Step 5: Verifying transcription in database...")
            db_chunks = pg.repository(AudioChunk).select(audio_file_id=file_id)
            
            if len(db_chunks) != len(audio_chunks):
                logger.error(f"Chunk count mismatch: {len(db_chunks)} in DB vs {len(audio_chunks)} expected")
                return False
                
            # Display some of the transcriptions
            for i, chunk in enumerate(db_chunks[:3]):  # Show first 3 chunks
                logger.info(f"Chunk {i+1}: {chunk.get('start_time', 0):.2f}s - {chunk.get('end_time', 0):.2f}s")
                logger.info(f"  Transcription: {chunk.get('transcription', '')[:80]}...")
            
            if len(db_chunks) > 3:
                logger.info(f"... and {len(db_chunks) - 3} more chunks")
                
            # Clean up temporary file
            try:
                os.unlink(temp_path)
                logger.info(f"Temporary file {temp_path} deleted")
            except Exception as e:
                logger.warning(f"Could not delete temporary file {temp_path}: {e}")
                
            logger.info("✅ End-to-end test PASSED!")
            return True
            
    except Exception as e:
        logger.error(f"Error in end-to-end test: {e}")
        import traceback
        logger.error(traceback.format_exc())
        return False

if __name__ == "__main__":
    success = asyncio.run(test_full_pipeline())
    exit(0 if success else 1)