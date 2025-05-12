#!/usr/bin/env python3
"""
Script to test the audio API endpoints.
This test will:
1. Set up database connection environment variables
2. Start a FastAPI test client
3. Upload a test audio file
4. Track the processing status
5. Verify the transcription results
"""

import os
import asyncio
import tempfile
from pathlib import Path
import logging
from fastapi.testclient import TestClient
import requests
import json

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("audio_api_test")

# Test file path
TEST_AUDIO_FILE = "/Users/sirsh/Downloads/INST_018.wav"

async def main():
    # Set environment variables
    os.environ["P8_PG_HOST"] = "localhost"
    os.environ["P8_PG_PORT"] = "15432"
    os.environ["P8_PG_USER"] = "postgres"
    os.environ["P8_PG_DBNAME"] = "app"
    
    # Get bearer token from environment
    bearer_token = os.environ.get('P8_TEST_BEARER_TOKEN')
    if not bearer_token:
        logger.error("P8_TEST_BEARER_TOKEN not set")
        return False
    
    os.environ["P8_PG_PASSWORD"] = bearer_token
    os.environ["P8_API_KEY"] = bearer_token
    
    # Import app
    from percolate.api.main import app
    
    # Create test client
    client = TestClient(app)
    
    logger.info("Starting API test...")
    
    # Check if audio file exists
    if not Path(TEST_AUDIO_FILE).exists():
        logger.error(f"Test file not found: {TEST_AUDIO_FILE}")
        return False
    
    # Create a shorter audio sample for testing
    from pydub import AudioSegment
    
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as temp_file:
        temp_path = temp_file.name
        audio = AudioSegment.from_file(TEST_AUDIO_FILE)
        # Take just the first 10 seconds
        short_audio = audio[:10000]
        logger.info(f"Created shorter test sample (10 seconds) at {temp_path}")
        short_audio.export(temp_path, format="wav")
    
    # Test the upload endpoint
    logger.info("Testing /audio/upload endpoint...")
    
    # Set up the API auth headers
    headers = {
        "Authorization": f"Bearer {bearer_token}"
    }
    
    # Set up the form data
    with open(temp_path, "rb") as audio_file:
        files = {
            "file": (Path(temp_path).name, audio_file, "audio/wav")
        }
        data = {
            "project_name": "api-test-project",
            "user_id": "test-user-123"
        }
        
        # Make the request
        logger.info("Uploading audio file...")
        response = client.post(
            "/audio/upload",
            headers=headers,
            files=files,
            data=data
        )
    
    # Check response
    if response.status_code != 200:
        logger.error(f"Upload failed: {response.status_code} - {response.text}")
        return False
    
    # Get the file ID from the response
    response_data = response.json()
    file_id = response_data.get("file_id")
    s3_uri = response_data.get("s3_uri")
    
    logger.info(f"Upload successful. File ID: {file_id}")
    logger.info(f"S3 URI: {s3_uri}")
    
    # Check status endpoint
    logger.info("Testing /audio/status/{file_id} endpoint...")
    
    # Poll status until completed or failed
    max_attempts = 30
    for attempt in range(max_attempts):
        status_response = client.get(
            f"/audio/status/{file_id}",
            headers=headers
        )
        
        if status_response.status_code != 200:
            logger.error(f"Status check failed: {status_response.status_code} - {status_response.text}")
            return False
        
        status_data = status_response.json()
        status = status_data.get("status")
        
        logger.info(f"Current status: {status}")
        
        if status == "completed":
            logger.info("Processing completed successfully")
            break
        elif status == "failed":
            logger.error(f"Processing failed with error: {status_data.get('error')}")
            return False
        
        # Wait before next check
        await asyncio.sleep(2)
    else:
        logger.error("Processing took too long to complete")
        return False
    
    # Get transcription
    logger.info("Testing /audio/transcription/{file_id} endpoint...")
    
    transcription_response = client.get(
        f"/audio/transcription/{file_id}",
        headers=headers
    )
    
    if transcription_response.status_code != 200:
        logger.error(f"Transcription check failed: {transcription_response.status_code} - {transcription_response.text}")
        return False
    
    # Show transcription results
    trans_data = transcription_response.json()
    
    logger.info(f"Transcription succeeded with {len(trans_data.get('chunks', []))} chunks:")
    for i, chunk in enumerate(trans_data.get("chunks", [])[:3]):
        logger.info(f"Chunk {i+1}: {chunk.get('start_time', 0):.2f}s - {chunk.get('end_time', 0):.2f}s")
        logger.info(f"  Transcription: {chunk.get('transcription', '')[:80]}...")
    
    # Clean up
    try:
        os.unlink(temp_path)
        logger.info(f"Temporary file {temp_path} deleted")
    except Exception as e:
        logger.warning(f"Could not delete temporary file {temp_path}: {e}")
    
    logger.info("✅ API Test PASSED!")
    return True

if __name__ == "__main__":
    asyncio.run(main())