# Percolate Audio Processing Module

## Overview

The Audio Processing module provides capabilities for:
- Voice Activity Detection (VAD) using Silero-VAD or energy-based detection
- Audio chunking based on speech segments
- Transcription using OpenAI Whisper API
- Storage of both audio files and transcriptions

## Components

1. **Models**: Located in `percolate/models/media/audio.py`
   - `AudioFile`: Metadata for uploaded audio files
   - `AudioChunk`: Speech segments extracted from audio files
   - `AudioPipeline`: Processing pipeline tracking
   - `AudioResource`: Audio resource storage
   
2. **Controller**: Located in `percolate/api/controllers/audio.py`
   - Handles file uploads, status tracking, and management
   - Interfaces with S3 for file storage
   
3. **Router**: Located in `percolate/api/routes/audio/router.py`
   - RESTful API endpoints for audio operations
   
4. **Service**: Located in `percolate/services/media/audio/processor.py`
   - Audio processing pipeline implementation
   - Voice activity detection
   - Audio chunking
   - Transcription with OpenAI Whisper API

## Database Tables

The audio models are registered in the PostgreSQL database:
- `public."AudioFile"` - Audio file metadata
- `public."AudioChunk"` - Audio chunk data with transcriptions
- `public."AudioPipeline"` - Pipeline tracking
- `public."AudioResource"` - Resource storage
- Corresponding embedding tables in the `p8_embeddings` schema

## API Endpoints

- `POST /audio/upload` - Upload an audio file
  - Parameters: `file`, `project_name`, `metadata` (optional), `user_id` (optional)
- `GET /audio/files/{file_id}` - Get audio file details
- `GET /audio/files` - List audio files for a project
- `DELETE /audio/files/{file_id}` - Delete an audio file
- `GET /audio/status/{file_id}` - Get processing status
- `POST /audio/reprocess/{file_id}` - Reprocess a failed file
  - Parameters: `user_id` (optional)
- `GET /audio/transcription/{file_id}` - Get transcription
- `POST /audio/admin/register-models` - Register audio models

## Setup

### Initial Database Setup

The audio models must be registered in the database before use:

```python
from percolate.models.media.audio import register_audio_models
results = register_audio_models()
```

### Environment Variables

Required environment variables:
- `S3_URL` - S3 storage endpoint
- `S3_ACCESS_KEY` - S3 access key
- `S3_SECRET` - S3 secret key
- `S3_AUDIO_BUCKET` - S3 bucket for audio storage (default: "percolate-audio")
- `OPENAI_API_KEY` - OpenAI API key for Whisper transcription

### Docker Deployment

Use the specialized `Dockerfile.media` to build a container with all required dependencies:

```bash
docker build -t percolationlabs/percolate-media:latest -f Dockerfile.media .
```

## Testing

The audio processing pipeline has been tested with:
- Voice activity detection using Silero-VAD
- Audio chunking based on speech segments
- Transcription via direct REST API calls to OpenAI Whisper
- End-to-end processing with the test file: INST_018.wav (located in the Downloads folder)

### End-to-End API Testing

A dedicated end-to-end API test script is available to test the complete processing pipeline:

```bash
python test_audio_api_end_to_end.py --audio /Users/sirsh/Downloads/INST_018.wav --host localhost --port 5008 --token YOUR_AUTH_TOKEN
```

#### Starting the API Server

To start the API server:
```bash
# First stop the docker container if it's running
docker compose stop percolate-api

# Set required environment variables
export P8_PG_HOST=localhost
export P8_PG_PORT=15432
export P8_PG_USER=postgres
export P8_PG_DBNAME=app
export P8_PG_PASSWORD=your_password  # Set to the value from P8_TEST_BEARER_TOKEN
export P8_TEST_BEARER_TOKEN=your_token  # This is used for authentication
export OPENAI_API_KEY=your_openai_key  # For transcription
export S3_AUDIO_BUCKET="percolate-audio"  # Audio bucket name

# Start the server in the foreground (for debugging)
cd /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate
uvicorn percolate.api.main:app --port 5008 --log-level debug

# OR start the server in the background
cd /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate
uvicorn percolate.api.main:app --port 5008 --log-level debug &
```

Note: The PostgreSQL database must be running on port 15432 (not the default 5432).

#### Manual Testing with curl

Once the server is running, you can test the audio pipeline with curl:

```bash
# 1. Register audio models (only needed once)
curl -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" http://localhost:5008/audio/admin/register-models -X POST

# 2. Upload a large audio file (80+ MB)
curl -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
     -F "file=@/Users/sirsh/Downloads/INST_018.wav;type=audio/wav" \
     -F "project_name=test-project" \
     -F "user_id=12345678-1234-1234-1234-123456789012" \
     http://localhost:5008/audio/upload

# 3. Check processing status (replace with your file_id)
curl -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
     http://localhost:5008/audio/status/YOUR_FILE_ID

# 4. Get transcription results (replace with your file_id)
curl -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
     http://localhost:5008/audio/transcription/YOUR_FILE_ID
```

#### Important Notes:

1. Storage modes:
   - The audio pipeline supports both S3 and local storage modes
   - Local storage is used by default when testing (no S3 required)
   - For S3 mode, set the proper S3 credentials in the environment
   - To use local storage mode, set `use_s3=False` in the `AudioProcessor` initialization

2. User ID format:
   - The user_id parameter must be in UUID format (e.g., 12345678-1234-1234-1234-123456789012)
   - Using non-UUID strings may cause processing errors
   - The user_id is passed from the file to the individual chunks for tracking

3. Processing large files:
   - The 80MB test file takes approximately 24 seconds to upload
   - Processing time depends on the file size, speech content, and available hardware
   - Chunking based on speech detection makes processing more efficient

4. Database connection:
   - The PostgreSQL database must be running on port 15432 (not the default 5432)
   - Set environment variable P8_PG_PORT=15432
   - For testing without a database, use the provided test scripts

## Implementation Notes

1. The audio processor uses direct REST API calls to OpenAI's Whisper service rather than using the SDK, for better flexibility and control.
2. For large files, chunking based on speech detection makes transcription more efficient and accurate.
3. The implementation handles retry logic with exponential backoff for API resilience.
4. PostgreSQL tables store the file metadata and transcription results for querying.
5. User IDs can be passed through the API and will be stored in the `user_id` field on `AudioFile` models and the `userid` field on `AudioChunk` models (following Percolate's naming convention).
6. The transcription endpoint has been enhanced to:
   - Process chunks with proper error handling
   - Correctly convert UUID strings to UUID objects
   - Support test data for development without a database
   - Generate well-formatted transcriptions with timestamps
   - Provide detailed debug logging

## Audio Processing Pipeline Details

The audio processing pipeline has been enhanced with:

1. **Dual Storage Modes**:
   - **S3 Mode**: Files and chunks are stored in S3 buckets (default)
   - **Local Mode**: Files and chunks are stored in local temporary files (set `use_s3=False`)
   - Both modes maintain the same workflow and data model

2. **Voice Activity Detection (VAD)**:
   - **Silero-VAD** (Primary): High-quality ML-based voice detection when PyTorch is available
   - **Energy-based VAD** (Fallback): Simple energy threshold-based detection when PyTorch is unavailable
   - Detection parameters are configurable for both methods

3. **Segment Optimization**:
   - **Merging**: Segments with small gaps (default: < 0.3s) are merged to reduce fragmentation
   - **Splitting**: Long segments (default: > 30s) are split to meet API limits
   - **Filtering**: Very short segments (default: < 0.5s) are removed to avoid noise
   - All thresholds are configurable

### Audio Processor Configuration

The `AudioProcessor` class accepts the following configuration parameters:

```python
processor = AudioProcessor(
    vad_threshold=0.5,      # Silero-VAD threshold (0.0-1.0), higher = more aggressive
    energy_threshold=-35,   # Energy threshold in dB for fallback VAD
    skip_transcription=False,  # Skip transcription step if needed
    use_s3=True             # Use S3 storage (True) or local temp files (False)
)
```

### Testing the Pipeline

#### Full Pipeline Testing

A test script (`test_audio_full_pipeline.py`) is provided to test the audio processing pipeline:

```bash
python test_audio_full_pipeline.py --audio path/to/your/audio.wav [options]

Options:
  --s3                        Use S3 storage mode (default: local mode)
  --vad-threshold VAD_THRESHOLD
                              Silero VAD threshold (0.0-1.0, higher = more aggressive)
  --energy-threshold ENERGY_THRESHOLD
                              Energy threshold in dB for fallback VAD
  --max-length MAX_LENGTH     Maximum segment length in seconds (OpenAI API limit)
  --min-length MIN_LENGTH     Minimum segment length in seconds to keep
  --merge-threshold MERGE_THRESHOLD
                              Merge segments with gaps smaller than this (seconds)
```

#### Testing With Mock Data

For testing without a database connection, use these scripts:

1. Create test files with chunks:
```bash
python create_test_chunks.py
```

2. Test the transcription endpoint with the created file:
```bash
python test_transcription_endpoint.py --file-id YOUR_FILE_ID
```

3. List available test files:
```bash
python test_transcription_endpoint.py --list
```

#### Debugging Database Connections

If you're having trouble connecting to the database:

```bash
python test_db_connection.py
```

This script will test connections with different port configurations and provide recommendations.

### Temporary File Management

The audio processor automatically manages temporary files:
- Files are created in system temporary directories
- All temp files are tracked and cleaned up after processing
- Clean-up occurs even if processing fails (using `finally` block)
- Temporary directories use unique prefixes for easy identification

## Data Model Details

### AudioFile Model

```python
class AudioFile(AbstractModel):
    """Model representing an uploaded audio file"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    user_id: str
    project_name: str
    filename: str
    file_size: int
    content_type: str
    duration: Optional[float] = None
    upload_date: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    status: str = AudioProcessingStatus.UPLOADING
    s3_uri: str
    chunks: Optional[List["AudioChunk"]] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
```

### AudioChunk Model

```python
class AudioChunk(AbstractModel):
    """Model representing a chunk of an audio file for processing"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID = Field(default_factory=uuid.uuid4)
    audio_file_id: uuid.UUID
    start_time: float
    end_time: float
    duration: float
    s3_uri: str
    transcription: Optional[str] = DefaultEmbeddingField(default='', description='transcribed audio is a resource')
    confidence: Optional[float] = None
    speaker_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
    userid: Optional[str|uuid.UUID] = Field(default=None, description="the audio chunk belongs to a user")
```