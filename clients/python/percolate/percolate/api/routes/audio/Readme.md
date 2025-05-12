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
- End-to-end processing with the test file: INST_018.wav

## Implementation Notes

1. The audio processor uses direct REST API calls to OpenAI's Whisper service rather than using the SDK, for better flexibility and control.
2. For large files, chunking based on speech detection makes transcription more efficient and accurate.
3. The implementation handles retry logic with exponential backoff for API resilience.
4. PostgreSQL tables store the file metadata and transcription results for querying.
5. User IDs can be passed through the API and will be stored in the `user_id` field on `AudioFile` models and the `userid` field on `AudioChunk` models (following Percolate's naming convention).

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