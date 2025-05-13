# Audio Processing Pipeline

The audio processing pipeline in Percolate handles audio file uploading, chunking, transcription, and storage. It supports both S3 and local file storage for flexibility.

## Features

- **Audio file uploading**: Upload audio files through the API.
- **Voice Activity Detection (VAD)**: Automatically detect speech segments using Silero-VAD.
- **Audio chunking**: Split audio into meaningful chunks for transcription.
- **Transcription**: Transcribe audio chunks using OpenAI Whisper API.
- **Dual storage mode**: Store files locally or in S3 based on configuration.
- **Fallback mechanisms**: Energy-based VAD if Silero is unavailable, mock transcription if OpenAI API is unavailable.

## Installation Requirements

- Python 3.9+
- PostgreSQL database
- FFmpeg (for audio processing)
- Optional: PyTorch and torchaudio (for Silero-VAD)
- Optional: pydub (for audio manipulation)
- Optional: AWS S3 or compatible object storage

## Environment Variables

```
# Database settings
P8_PG_HOST=localhost
P8_PG_PORT=15432
P8_PG_USER=your_username
P8_PG_PASSWORD=your_password
P8_PG_DATABASE=percolate

# S3 settings (optional)
S3_URL=your-s3-endpoint.com
S3_ACCESS_KEY=your_access_key
S3_SECRET=your_secret_key
S3_AUDIO_BUCKET=percolate-audio

# OpenAI API (optional)
OPENAI_API_KEY=your_openai_api_key
```

## API Endpoints

### Upload an Audio File

```bash
curl -X POST http://localhost:5008/audio/upload \
  -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
  -F "file=@path/to/your/audio.mp3" \
  -F "project_name=your_project" \
  -F "metadata={\"description\":\"Test audio file\"}"
```

### Get Transcription

```bash
curl -s -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
  http://localhost:5008/audio/transcription/your_file_id | jq
```

### List Audio Files

```bash
curl -s -H "Authorization: Bearer $P8_TEST_BEARER_TOKEN" \
  http://localhost:5008/audio/files?project_name=your_project | jq
```

## Local Testing

For testing without a database connection, the API can use local test files. Use the provided script to create test files:

```bash
python create_test_chunks.py
```

This will create a test file with chunks and provide a file ID to use with the transcription endpoint.

To test the transcription endpoint with a test file:

```bash
python test_transcription_endpoint.py --file-id your_test_file_id
```

To list available test files:

```bash
python test_transcription_endpoint.py --list
```

## Architecture

### AudioProcessor Class

The `AudioProcessor` class in `percolate/services/media/audio/processor.py` is the core of the pipeline:

```python
class AudioProcessor:
    def __init__(
        self, 
        vad_threshold: float = 0.5, 
        energy_threshold: float = -35, 
        skip_transcription: bool = False,
        use_s3: bool = False
    ):
        # ...
```

Set `use_s3=True` to use S3 storage, or `False` for local storage.

### Processing Stages

1. **File Upload**: Files are uploaded through the API and temporarily stored.
2. **Voice Activity Detection**: Speech segments are detected using either:
   - Silero-VAD (if PyTorch is available)
   - Energy-based VAD (fallback method)
3. **Chunking**: Audio is split into chunks based on detected speech segments.
4. **Transcription**: Chunks are transcribed using OpenAI's Whisper API.
5. **Storage**: Chunks are stored either in S3 or locally based on the configuration.

### Data Models

- **AudioFile**: Represents an uploaded audio file.
- **AudioChunk**: Represents a segment of an audio file with its transcription.
- **AudioPipeline**: Tracks the pipeline execution for a specific file.
- **AudioProcessingStatus**: Enum-like class for tracking processing status.

## Troubleshooting

### Database Connection Issues

If you encounter database connection issues, check the following:

1. Verify PostgreSQL is running: `pg_isready -h localhost -p 15432`
2. Check environment variables: `echo $P8_PG_PORT` (should be 15432)
3. Run the database test script: `python test_db_connection.py`

### Missing Audio Chunks

If chunks are not appearing in transcription results:

1. Verify chunks are being created: Check logs for "Saved X chunk records to database"
2. Check test data: `python test_transcription_endpoint.py --list`
3. Test with a sample file: `python create_test_chunks.py` and use the generated file ID

### S3 Issues

If S3 storage isn't working:

1. Check S3 environment variables
2. Set `use_s3=False` to use local storage instead
3. Check S3 client logs for specific error messages

## Performance Considerations

- The pipeline is designed to handle files up to 100MB
- Large files may require more memory and longer processing times
- Transcription can be resource-intensive, especially for long files
- Consider running the pipeline asynchronously for production use