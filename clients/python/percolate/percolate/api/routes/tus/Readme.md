# Tus Protocol File Upload API

This module implements the [tus.io](https://tus.io) protocol for resumable file uploads in Percolate. The implementation follows the tus protocol version 1.0.0 and supports multiple extensions.

## Tus Protocol Overview

Tus is an open protocol for resumable file uploads. It allows clients to upload large files reliably by breaking them into chunks that can be resumed if the connection is interrupted.

## Implementation Details

This implementation provides robust file upload capabilities with:

1. **S3 Integration**: Finalized files are stored in S3 with structured paths
2. **File Tagging**: Support for up to 3 tags per file for organization
3. **User Association**: Files are associated with users through session or API
4. **Project Organization**: Files are organized by project
5. **Search**: Support for searching uploads by tag and text
6. **Automatic Resource Creation**: Uploaded files are automatically processed to create searchable resources

## Supported Extensions

- **creation**: Allows creating upload resources
- **creation-with-upload**: Allows combining the creation and initial upload in a single request
- **expiration**: Supports upload expiration to automatically clean up incomplete uploads
- **termination**: Allows clients to explicitly cancel uploads

## Authentication

Authentication is handled through:
1. Session-based authentication (for web clients)
2. API key authentication (for programmatic access)

## Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| OPTIONS | `/tus/` | Discovery endpoint, returns capabilities |
| POST | `/tus/` | Create a new upload |
| HEAD | `/tus/{upload_id}` | Get information about an upload |
| PATCH | `/tus/{upload_id}` | Upload a chunk |
| DELETE | `/tus/{upload_id}` | Delete an upload |
| GET | `/tus/` | List uploads (non-standard endpoint) |
| POST | `/tus/{upload_id}/finalize` | Finalize upload (non-standard endpoint) |
| POST | `/tus/{upload_id}/extend` | Extend expiration (non-standard endpoint) |

## Storage

Uploads can be stored:
1. Locally in a temporary directory (configurable via `TUS_STORAGE_PATH`)
2. In S3 when uploads are finalized (configurable via `TUS_USE_S3`)

## Configuration

The following environment variables can be used to configure the Tus server:

- `TUS_STORAGE_PATH`: Path for storing uploads (default: system temp directory)
- `TUS_USE_S3`: Whether to use S3 for storage (default: true)
- `TUS_S3_BUCKET`: S3 bucket for storing finalized uploads (default: "percolate")
- `TUS_MAX_SIZE`: Maximum allowed upload size in bytes (default: 5GB)
- `TUS_DEFAULT_EXPIRATION`: Default upload expiration in seconds (default: 86400 - 24 hours)

## Example Usage

### Browser-based upload with [tus-js-client](https://github.com/tus/tus-js-client)

```javascript
const upload = new tus.Upload(file, {
  endpoint: "https://api.percolate.com/tus/",
  metadata: {
    filename: file.name,
    filetype: file.type
  },
  retryDelays: [0, 3000, 5000, 10000, 20000],
  onError: (error) => {
    console.log("Upload failed: " + error)
  },
  onProgress: (bytesUploaded, bytesTotal) => {
    const percentage = ((bytesUploaded / bytesTotal) * 100).toFixed(2)
    console.log(`Upload progress: ${percentage}%`)
  },
  onSuccess: () => {
    console.log("Upload complete")
    
    // After upload completes, finalize it
    fetch(`${upload.url}/finalize`, { method: 'POST' })
      .then(response => response.json())
      .then(data => console.log("Finalized upload:", data))
  }
})

// Start the upload
upload.start()
```

### Python upload with [tuspy](https://github.com/tus/tus-py-client)

```python
from tusclient.client import TusClient

# Create a client
client = TusClient("https://api.percolate.com/tus/")

# Create an uploader
uploader = client.uploader("path/to/file.mp4", metadata={"filename": "video.mp4"})

# Start the upload
uploader.upload()

# After upload completes, finalize it
import requests
requests.post(f"https://api.percolate.com/tus/{uploader.upload_url.split('/')[-1]}/finalize")
```

## Working with Uploads

After an upload is finalized, it's available in the database and can be accessed through the `TusFileUpload` model. The file content can be accessed through the local path or S3 URI depending on the storage configuration.

## Testing

For comprehensive testing, use the provided test scripts:

1. **Python API Tests**:
   ```bash
   python -m percolate.test_tus_api
   ```

2. **Bash/Curl Tests**:
   ```bash
   ./percolate/test_tus_curl.sh
   ```

3. **Database/S3 Tests**:
   ```bash
   python -m percolate.test_tus_db
   ```

4. **Verification Tool**:
   ```bash
   # List all uploads
   python -m percolate.verify_tus_uploads --list
   
   # Show details for a specific upload
   python -m percolate.verify_tus_uploads --show <upload_id>
   
   # Verify S3 storage
   python -m percolate.verify_tus_uploads --list --verify-s3
   ```

For more details, see [TESTING.md](./TESTING.md) and [IMPLEMENTATION.md](./IMPLEMENTATION.md).

## Automatic Resource Creation

After a file is uploaded and finalized, Percolate automatically creates searchable resources based on the file type:

### Audio Files (.wav, .mp3, etc.)
- Audio files are processed through the audio pipeline
- Audio is transcribed using the configured transcription service
- Transcriptions are chunked and stored as searchable resources
- Each resource includes metadata about timestamps and confidence scores

### Document Files (.pdf, .txt, .docx, .doc)
- Text is extracted from documents using appropriate parsers
- Content is chunked into searchable segments with overlap
- Each chunk is stored as a resource with metadata
- Resources maintain references to the original S3 URI

### Resource Structure
Each created resource includes:
- `content`: The actual text content (transcription or document text)
- `uri`: Reference to the original file in S3
- `user_id`: The user who uploaded the file
- `metadata`: Additional information about the source and processing
- `ordinal`: The chunk order for maintaining sequence
- `category`: Type of resource (audio_transcription, document, etc.)

Resources can be queried through the standard Percolate resources API, enabling semantic search across all uploaded content.


HTTPS - always check this

  Location header: https://eepis.percolationlabs.ai/tus/3ca3e70d-3858-1823-cdd7-c56e259110f3
  ✅ SUCCESS: HTTPS URL returned

  Both tests passed:
  1. Regular upload returns HTTPS URLs
  2. Upload with X-Forwarded-Proto header also returns HTTPS URLs