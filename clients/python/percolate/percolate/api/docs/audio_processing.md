# Audio Processing Pipeline

## Overview

The Percolate Audio Pipeline is a system for processing large audio files through a series of steps:
1. Streaming upload of audio files
2. Voice activity detection (VAD) using Silero-VAD or energy-based detection
3. Intelligent chunking of audio content
4. Transcription using OpenAI Whisper API
5. Storage of both audio and transcriptions using Percolate database

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌────────────────┐     ┌─────────────┐     ┌───────────────┐
│   Upload    │     │  Temporary  │     │ Audio Pipeline │     │  OpenAI     │     │   Percolate   │
│   Endpoint  │────►│  S3 Storage │────►│    Service     │────►│  Whisper    │────►│    Database   │
└─────────────┘     └─────────────┘     └────────────────┘     └─────────────┘     └───────────────┘
                                              │
                                       ┌──────┴──────┐
                                       │  Silero-VAD │
                                       └─────────────┘
```

## API Endpoints

### POST /audio/upload

#### Overview
Uploads an audio file to the server for processing and transcription.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Request
- Content-Type: `multipart/form-data`
- Form parameters:
  - `file` (UploadFile, required): The audio file to upload.
  - `project_name` (string, required): Project to organize files under.
  - `metadata` (string, optional): JSON string with additional metadata.

##### Processing Steps
1. Validate file content type (must be audio/*).
2. Upload file to temporary storage.
3. Create AudioFile record in database.
4. Upload file to S3 storage.
5. Update AudioFile status to UPLOADED.
6. Trigger async processing pipeline.

##### Response
- HTTP 200
- Body:
```json
{
  "file_id": "uuid",
  "filename": "original-filename.wav",
  "status": "uploaded",
  "s3_uri": "s3://bucket/project/audio/file_id/filename"
}
```

##### Errors
- 400 Bad Request: Not an audio file or invalid metadata format.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Upload failure.

### GET /audio/files/{file_id}

#### Overview
Retrieve details about a specific audio file.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body: Full AudioFile object with all details

##### Errors
- 404 Not Found: File does not exist.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Database error.

### GET /audio/files

#### Overview
List all audio files for a project.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Query Parameters
- `project_name` (string, required): Project to list files from.

##### Response
- HTTP 200
- Body: Array of AudioFile objects

##### Errors
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Database error.

### DELETE /audio/files/{file_id}

#### Overview
Delete an audio file and all its associated chunks.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body:
```json
{
  "message": "File deletion initiated",
  "file_id": "uuid"
}
```

##### Errors
- 404 Not Found: File does not exist.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Deletion failure.

### GET /audio/status/{file_id}

#### Overview
Get the current processing status of an audio file.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body:
```json
{
  "file_id": "uuid",
  "status": "processing|completed|failed",
  "progress": 0.75,
  "error": null,
  "queued_at": "2023-05-01T12:00:00Z"
}
```

##### Errors
- 404 Not Found: File does not exist.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Status retrieval failure.

### POST /audio/reprocess/{file_id}

#### Overview
Reset a failed audio file and requeue it for processing.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body:
```json
{
  "message": "File resubmitted for processing",
  "status": "QUEUED"
}
```

##### Errors
- 404 Not Found: File does not exist.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Reprocessing failure.

### GET /audio/transcription/{file_id}

#### Overview
Get the complete transcription for an audio file.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body:
```json
{
  "file_id": "uuid",
  "status": "completed",
  "chunks": [
    {
      "id": "chunk-uuid",
      "start_time": 0.0,
      "end_time": 10.5,
      "duration": 10.5,
      "transcription": "This is the transcribed text for this segment.",
      "confidence": 0.95
    }
  ],
  "transcription": "This is the transcribed text for this segment.",
  "metadata": {}
}
```

##### Errors
- 404 Not Found: File does not exist.
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Transcription retrieval failure.

### POST /audio/admin/register-models

#### Overview
Register all audio models with the Percolate database.

#### Requirements

##### Authentication
- Header: `Authorization: Bearer <api_key>`
- Dependency: `get_api_key`

##### Response
- HTTP 200
- Body:
```json
{
  "message": "Audio models registration completed",
  "results": {
    "AudioFile": "Registered successfully",
    "AudioChunk": "Registered successfully",
    "AudioPipeline": "Registered successfully",
    "AudioResource": "Registered successfully"
  }
}
```

##### Errors
- 401 Unauthorized: Missing/invalid API key.
- 500 Internal Server Error: Registration failure.

## Data Models

### AudioFile

```python
class AudioFile(AbstractModel):
    """Model representing an uploaded audio file"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID
    user_id: str
    project_name: str
    filename: str
    file_size: int
    content_type: str
    duration: Optional[float] = None
    upload_date: datetime
    status: str  # See AudioProcessingStatus values
    s3_uri: str
    chunks: Optional[List["AudioChunk"]] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
```

### AudioChunk

```python
class AudioChunk(AbstractModel):
    """Model representing a chunk of an audio file for processing"""
    model_config = {'namespace': 'public'}
    
    id: uuid.UUID
    audio_file_id: uuid.UUID  # Reference to parent file
    start_time: float
    end_time: float
    duration: float
    s3_uri: str
    transcription: Optional[str] = None
    confidence: Optional[float] = None
    speaker_id: Optional[str] = None
    metadata: Optional[Dict[str, Any]] = Field(default_factory=dict)
```

### AudioProcessingStatus

```python
class AudioProcessingStatus:
    """Status of an audio file in the processing pipeline"""
    UPLOADING = "uploading"
    UPLOADED = "uploaded"
    PROCESSING = "processing"
    CHUNKING = "chunking"
    TRANSCRIBING = "transcribing"
    COMPLETED = "completed"
    FAILED = "failed"
```

## Configuration

### Environment Variables

```
# S3 Configuration
S3_URL=your-s3-url
S3_ACCESS_KEY=your-access-key
S3_SECRET=your-secret-key
S3_AUDIO_BUCKET=percolate-audio

# OpenAI API Configuration
OPENAI_API_KEY=your-openai-api-key

# Enable/Disable features
ENABLE_AUDIO_PROCESSING=true
```

## Deployment

The audio processing service is packaged in a specialized Docker container with additional dependencies for audio processing. Use the `Dockerfile.media` to build the container:

```bash
# Build the container
docker build -t percolationlabs/percolate-media:latest -f Dockerfile.media .

# Run the container with proper environment variables
docker run -p 5009:5008 \
  -e S3_URL=your-s3-url \
  -e S3_ACCESS_KEY=your-access-key \
  -e S3_SECRET=your-secret-key \
  -e OPENAI_API_KEY=your-openai-key \
  percolationlabs/percolate-media:latest
```

## Dependencies

Required dependencies (included in the media Docker container):
- numpy>=1.24.1,<2.0.0
- torch>=2.0.0,<2.3.0
- torchaudio>=2.0.0,<2.3.0
- pydub>=0.25.1
- ffmpeg (system library)
- libsndfile1 (system library)
- openai>=1.0.0
- boto3>=1.26.0

## Error Handling

The audio processing pipeline includes robust error handling with:
- Automatic retries for transcription API calls
- Exponential backoff for transient errors
- Detailed logging for debugging
- Error capture in AudioFile.metadata["error"]
- Ability to reprocess failed files via API endpoint