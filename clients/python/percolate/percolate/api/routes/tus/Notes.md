# Tus Protocol Implementation for Percolate

This document summarizes the implementation of the [tus.io](https://tus.io) protocol for resumable file uploads in Percolate.

## Overview

The implementation provides a robust file upload system with the following features:

1. **Tus Protocol Compliance**: Implements version 1.0.0 of the protocol
2. **Resumable Uploads**: Allows clients to resume interrupted uploads
3. **Chunked Uploading**: Supports uploading large files in chunks
4. **S3 Storage Integration**: Stores finalized files in S3
5. **Tagging System**: Supports up to 3 tags per file for organization
6. **Search Capabilities**: Provides text search and interface for future semantic search

## Components

### 1. Models

- `TusFileUpload`: Tracks upload metadata, status, and location
- `TusFileChunk`: Tracks individual chunks of a file upload

### 2. Controller

The `tus_controller.py` module provides all the business logic:

- Creating uploads
- Processing chunks
- Finalizing uploads
- S3 integration
- Search and listing
- Tag management

### 3. Router

The `router.py` module implements the API endpoints:

- Standard Tus protocol endpoints (OPTIONS, POST, HEAD, PATCH, DELETE)
- Extended endpoints for:
  - Listing uploads
  - Finalizing uploads
  - Managing tags
  - Searching uploads
  - Semantic search (interface for future implementation)

## Authentication

Authentication is handled through:
1. Session-based authentication for web clients
2. API key authentication for programmatic access

## Features

### File Tag Support

Files can be tagged in multiple ways:
- During upload via metadata
- After upload via PUT endpoint
- Tags are stored with the file and searchable

### S3 Integration

Completed uploads are stored in S3:
- Uses project/user/upload_id path structure for consistent organization
- S3 URI, bucket, and key stored directly on the upload record
- Uses S3Service for consistent integration with Percolate

### Resource Integration

Integration with the Percolate resource system is supported:
- `resource_id` field for linking to created resources
- S3 URI can be used as a join key for resource association
- Path structure allows identifying files by user and project

### Search Capabilities

The implementation includes flexible search options:
- Search by tag, user, filename, and project
- Text search across filenames and metadata
- Placeholder for future semantic search integration

## Usage Examples

### JavaScript (Browser)

```javascript
const upload = new tus.Upload(file, {
  endpoint: "https://api.percolate.com/tus/",
  metadata: {
    filename: file.name,
    filetype: file.type,
    tags: "tag1,tag2,tag3"
  },
  onSuccess: function() {
    // Finalize the upload
    fetch(`${upload.url}/finalize`, { method: 'POST' })
      .then(response => response.json())
      .then(data => console.log("Finalized:", data));
  }
});

upload.start();
```

### Python

```python
from tusclient.client import TusClient

client = TusClient("https://api.percolate.com/tus/")
uploader = client.uploader("path/to/file.mp4", metadata={
  "filename": "video.mp4",
  "tags": "tag1,tag2,tag3"
})

uploader.upload()

# After upload, finalize it
import requests
requests.post(f"https://api.percolate.com/tus/{uploader.url.split('/')[-1]}/finalize")
```

## Testing

Two test scripts are provided:

1. `test_tus_api.py`: Python-based test for all endpoints
2. `test_tus_curl.sh`: Bash/curl-based test for quick verification

See `TESTING.md` for detailed testing instructions.