# FileSystemService

A unified file system service that provides a single interface for file operations across local and S3 storage systems with automatic file type detection and handling.

## Features

- **Unified Interface**: Same API for local and S3 storage
- **Automatic Type Detection**: Automatically handles different file types based on extension
- **Multiple Format Support**: Images, documents, audio, text, and structured data
- **Polars Integration**: Uses Polars for efficient CSV/DataFrame operations
- **Content Chunking**: Built-in intelligent text chunking with simple and extended parsing modes
- **Transcription Services**: Integrated audio/video transcription using OpenAI Whisper
- **Extensible Architecture**: Easy to add new file type handlers

## Supported File Types

### Images
- **Formats**: PNG, JPG, JPEG, TIFF, BMP, GIF, WebP
- **Returns**: PIL.Image objects
- **Dependencies**: `Pillow`

### Text Files
- **Formats**: TXT, MD, HTML, CSS, JS, JSON, XML, YAML
- **Returns**: String content
- **Dependencies**: None

### Structured Data
- **CSV**: Returns Polars DataFrame
- **Parquet**: Returns Polars DataFrame  
- **Excel** (XLS/XLSX): Returns dict of sheet_name -> Polars DataFrame
- **Dependencies**: `polars`, `openpyxl` (for Excel)

### Documents
- **PDF**: Returns dict with text_pages, images, and metadata
- **DOCX**: Returns dict with paragraphs, tables, and full_text
- **Dependencies**: `PyPDF2`, `PyMuPDF` (for PDF), `python-docx` (for DOCX)

### Audio
- **Formats**: WAV, MP3, FLAC, OGG, M4A
- **Returns**: Dict with audio_data, sample_rate, and metadata
- **Dependencies**: `librosa`, `soundfile`

## Installation

Basic installation:
```bash
pip install polars pillow
```

Full installation with all format support:
```bash
pip install polars pillow PyPDF2 PyMuPDF python-docx librosa soundfile openpyxl
```

## Usage

### Simple Top-Level Interface (Recommended)

The easiest way to use the file system is through the top-level `p8.fs` interface:

```python
import percolate as p8

# Read files from anywhere - automatically detects provider
content = p8.fs.read("local_file.txt")                    # Local file
content = p8.fs.read("s3://bucket/file.pdf")              # S3 file  
content = p8.fs.read("https://api.example.com/data.csv")  # HTTP download

# Write files
p8.fs.write("output.txt", "Hello World!")
p8.fs.write("s3://bucket/data.csv", dataframe)

# Copy files between any sources
p8.fs.copy("https://example.com/file.zip", "s3://bucket/downloaded.zip")
p8.fs.copy("s3://bucket/file.pdf", "local_copy.pdf")

# File operations
if p8.fs.exists("s3://bucket/file.txt"):
    files = p8.fs.ls("s3://bucket/prefix/")

# Open file-like objects
with p8.fs.open("s3://bucket/file.txt", "r") as f:
    content = f.read()
```

### Advanced FileSystemService Usage

For more control, use the FileSystemService directly:

```python
from percolate.services import FileSystemService

# Initialize the service
fs = FileSystemService()

# Read various file types
text_content = fs.read("path/to/file.txt")          # Returns string
image = fs.read("path/to/image.png")                # Returns PIL.Image
df = fs.read("path/to/data.csv")                    # Returns polars.DataFrame
pdf_data = fs.read("path/to/document.pdf")          # Returns dict with content

# Write files
fs.write("output.txt", "Hello World!")
fs.write("output.png", image)
fs.write("output.csv", df)

# Copy files
fs.copy("source.txt", "destination.txt")

# Check file existence
if fs.exists("path/to/file.txt"):
    content = fs.read("path/to/file.txt")
```

### S3 Usage

#### AWS S3 Mode (Recommended)
```python
from percolate.services import FileSystemService

# Use standard AWS credentials and S3
fs = FileSystemService(use_aws=True)

# Read from S3
content = fs.read("s3://bucket/path/to/file.txt")
image = fs.read("s3://bucket/images/photo.jpg")

# Write to S3
fs.write("s3://bucket/output/data.csv", df)

# Copy between local and S3
fs.copy("local_file.txt", "s3://bucket/remote_file.txt")
fs.copy("s3://bucket/remote_file.txt", "local_copy.txt")
```

#### Custom S3 Provider Mode
```python
from percolate.services import FileSystemService, S3Service

# For custom S3 providers (Hetzner, etc.)
s3_service = S3Service()  # Uses S3_ environment variables
fs = FileSystemService(s3_service)

# Same API as above
content = fs.read("s3://bucket/path/to/file.txt")
```

### File Information

```python
info = fs.get_file_info("path/to/file.pdf")
print(info)
# Output:
# {
#     'exists': True,
#     'path': 'path/to/file.pdf',
#     'extension': '.pdf',
#     'name': 'file.pdf',
#     'storage_type': 'local',
#     'has_handler': True,
#     'handler_type': 'PDFHandler',
#     'mime_type': 'application/pdf'
# }
```

### Working with Specific File Types

#### Images
```python
from PIL import Image

# Read image
img = fs.read("photo.jpg")  # Returns PIL.Image
print(f"Image size: {img.size}")

# Create and write image
new_img = Image.new('RGB', (100, 100), color='red')
fs.write("red_square.png", new_img)
```

#### DataFrames
```python
import polars as pl

# Read CSV
df = fs.read("data.csv")  # Returns polars.DataFrame
print(df.head())

# Create and write DataFrame
new_df = pl.DataFrame({
    "name": ["Alice", "Bob"],
    "age": [25, 30]
})
fs.write("people.csv", new_df)
fs.write("people.parquet", new_df)  # More efficient storage
```

#### PDF Documents
```python
# Read PDF
pdf_data = fs.read("document.pdf")
print(f"Number of pages: {pdf_data['num_pages']}")
print(f"First page text: {pdf_data['text_pages'][0]}")

# Access extracted images
for page_num, page_images in enumerate(pdf_data['images']):
    for img_num, img in enumerate(page_images):
        fs.write(f"pdf_image_p{page_num}_i{img_num}.png", img)
```

#### Audio Files
```python
# Read audio
audio_data = fs.read("song.wav")
print(f"Duration: {audio_data['duration']} seconds")
print(f"Sample rate: {audio_data['sample_rate']} Hz")

# Access audio array for processing
import numpy as np
audio_array = audio_data['audio_data']
# Apply audio processing...

# Write processed audio
processed_data = {
    'audio_data': audio_array,
    'sample_rate': audio_data['sample_rate']
}
fs.write("processed_song.wav", processed_data)
```

## Architecture

### Provider Pattern
The service uses a provider pattern to abstract storage backends:
- `LocalFileSystemProvider`: Handles local file operations
- `S3FileSystemProvider`: Handles S3 operations via S3Service

### Handler Pattern
File type handlers implement the `FileTypeHandler` interface:
- `can_handle()`: Determines if the handler supports a file type
- `read()`: Reads and parses the file into appropriate Python objects
- `write()`: Writes Python objects to files

### Adding Custom Handlers

```python
from percolate.services.FileSystemService import FileTypeHandler, FileSystemProvider

class CustomHandler(FileTypeHandler):
    def can_handle(self, file_path: str) -> bool:
        return Path(file_path).suffix.lower() == '.custom'
    
    def read(self, provider: FileSystemProvider, file_path: str, **kwargs):
        data = provider.read_bytes(file_path)
        # Custom parsing logic
        return parsed_data
    
    def write(self, provider: FileSystemProvider, file_path: str, data, **kwargs):
        # Custom serialization logic
        serialized = serialize(data)
        provider.write_bytes(file_path, serialized)

# Register the handler
fs = FileSystemService()
fs.register_handler(CustomHandler())
```

## Error Handling

The service gracefully handles missing dependencies and unsupported formats:

- **Missing Dependencies**: Handlers that require optional dependencies will not be registered if imports fail
- **Unsupported Formats**: Falls back to raw bytes for unknown file types
- **Handler Failures**: If a specific handler fails, falls back to raw bytes with a warning

## Environment Variables

### AWS S3 Mode (`use_aws=True`)
For standard AWS S3 operations:

```bash
# Required for AWS S3 mode
AWS_ACCESS_KEY_ID=your_aws_key
AWS_SECRET_ACCESS_KEY=your_aws_secret

# Optional - defaults to 'percolate' if not set
S3_DEFAULT_BUCKET=your_bucket_name
```

### Custom S3 Provider Mode
For custom S3 providers (Hetzner, MinIO, etc.):

```bash
# Custom S3 credentials take precedence
S3_ACCESS_KEY=your_access_key
S3_SECRET=your_secret_key
S3_URL=your_s3_endpoint.com
S3_DEFAULT_BUCKET=your_bucket

# Fallback to AWS credentials if S3_ vars not set
AWS_ACCESS_KEY_ID=your_aws_key  
AWS_SECRET_ACCESS_KEY=your_aws_secret
```

## Performance Considerations

- **Large Files**: The service loads entire files into memory. Successfully tested with 105MB files
- **S3 Operations**: Network overhead for uploads/downloads. Large files (28MB TIF) handle well
- **Audio Files**: Audio processing can be memory-intensive for long recordings
- **PDF Images**: PDF image extraction can be slow for documents with many high-resolution images
- **File Integrity**: Uses raw bytes for uploads to preserve exact file fidelity, then parses on download

## Production Testing Results

The FileSystemService has been thoroughly tested with real-world files:

- **20 diverse file types** tested successfully
- **File sizes**: 554 bytes to 105MB
- **Success rate**: 100% for S3 round-trip operations
- **Formats tested**: Images (JPEG, PNG, TIFF), Documents (PDF, DOCX, HTML), Data (CSV, Parquet), Binary (ZIP, PKL), and more
- **AWS S3 Integration**: Fully validated with `use_aws=True` mode

### File Copy Operations

For reliable file copying that preserves exact binary content:

```python
# Read raw bytes (bypasses handlers)
raw_data = fs.read_bytes("source_file.pdf")

# Write raw bytes (preserves exact file structure)
fs.write("destination_file.pdf", raw_data)

# Or use the copy method (does this automatically)
fs.copy("source_file.pdf", "s3://bucket/destination_file.pdf")
```

## Integration with Existing Code

The FileSystemService is designed to work alongside your existing parsing providers:

```python
# In your chunked resource provider
from percolate.services import FileSystemService

class ChunkedResourceProvider:
    def __init__(self):
        self.fs = FileSystemService()
    
    def process_file(self, file_path: str):
        # Let FileSystemService handle the complexity
        content = self.fs.read(file_path)
        
        # Now you have the appropriate Python object
        if isinstance(content, str):
            # Handle text content
            return self.chunk_text(content)
        elif hasattr(content, 'text_pages'):
            # Handle PDF
            return self.chunk_pdf(content)
        elif hasattr(content, 'columns'):
            # Handle DataFrame
            return self.chunk_dataframe(content)
        # ... etc
```

This approach removes the file reading complexity from your chunked resource provider, letting you focus on the chunking logic.

## Advanced Usage

### S3Service Integration

The FileSystemService integrates seamlessly with the existing S3Service:

```python
from percolate.services import FileSystemService, S3Service

# Custom S3 configuration
s3_service = S3Service(
    access_key="custom_key",
    secret_key="custom_secret", 
    endpoint_url="https://custom.s3.endpoint.com",
    use_aws=False  # Use custom S3 provider
)

fs = FileSystemService(s3_service)

# AWS mode (recommended for standard AWS S3)
fs_aws = FileSystemService(use_aws=True)
```

### Error Handling Best Practices

```python
try:
    content = fs.read("s3://bucket/file.pdf")
    if isinstance(content, dict) and 'text_pages' in content:
        # Successfully parsed PDF
        process_pdf_content(content)
    elif isinstance(content, bytes):
        # Fell back to raw bytes (no handler or handler failed)
        process_raw_content(content)
except Exception as e:
    logger.error(f"Failed to read file: {e}")
    # Handle error appropriately
```

### Batch Operations

For processing multiple files efficiently:

```python
def process_files_batch(file_paths: List[str], s3_prefix: str):
    fs = FileSystemService(use_aws=True)
    
    for file_path in file_paths:
        try:
            # Upload raw bytes for preservation
            raw_data = fs.read_bytes(file_path)
            s3_path = f"{s3_prefix}/{Path(file_path).name}"
            fs.write(s3_path, raw_data)
            
            # Then read and process with handlers
            processed_content = fs.read(s3_path)
            yield processed_content
            
        except Exception as e:
            logger.warning(f"Failed to process {file_path}: {e}")
            continue
```

## Top-Level Interface (`p8.fs`)

### Automatic Provider Detection

The `p8.fs` interface automatically detects the appropriate provider based on URI scheme:

- **Local files**: `/path/to/file.txt` → LocalFileSystemProvider
- **S3 files**: `s3://bucket/file.txt` → S3FileSystemProvider (auto-detects AWS vs custom)  
- **HTTP(S) URLs**: `https://example.com/file.txt` → HTTP downloader + parser

### HTTP/HTTPS Support

The top-level interface includes HTTP(S) support for reading files from web URLs:

```python
import percolate as p8

# Download and parse various formats from HTTP
csv_data = p8.fs.read("https://data.gov/dataset.csv")           # Returns polars.DataFrame
image = p8.fs.read("https://example.com/photo.jpg")             # Returns PIL.Image
text = p8.fs.read("https://api.github.com/repos/user/repo")     # Returns JSON string

# Copy from HTTP to S3
p8.fs.copy("https://example.com/dataset.csv", "s3://bucket/data.csv")

# Check if HTTP resource exists
if p8.fs.exists("https://api.example.com/data.json"):
    data = p8.fs.read("https://api.example.com/data.json")

# Open HTTP resources as file-like objects
with p8.fs.open("https://example.com/data.txt", "r") as f:
    content = f.read()
```

### Smart Credential Detection

The `p8.fs` interface automatically chooses the best S3 configuration:

```python
# Automatically uses AWS mode if only AWS credentials are available
# Uses custom S3 mode if S3_ environment variables are set
content = p8.fs.read("s3://bucket/file.txt")

# No need to specify use_aws=True - it's detected automatically
```

### Complete API Reference

```python
import percolate as p8

# Core operations
content = p8.fs.read(path)              # Read and parse any file type
raw_bytes = p8.fs.read_bytes(path)      # Read raw bytes
p8.fs.write(path, data)                 # Write data (type-aware)
p8.fs.copy(source, dest)                # Copy between any providers
exists = p8.fs.exists(path)             # Check if file/URL exists
files = p8.fs.ls(directory)             # List files/directories
info = p8.fs.get_file_info(path)        # Get file metadata

# File-like operations
with p8.fs.open(path, mode) as f:       # Open file-like object
    content = f.read()
```

## Content Chunking

The FileSystemService includes built-in intelligent content chunking capabilities for creating chunked resources from any supported file type.

### Features

- **Simple Mode**: Basic text extraction with no LLM costs
- **Extended Mode**: Enhanced parsing with LLM integration 
- **Audio/Video Transcription**: Automatic transcription using OpenAI Whisper API
- **Flexible Input**: Supports regular paths, file://, s3://, and HTTP(S) URLs
- **Intelligent Chunking**: Configurable chunk sizes with word-boundary awareness
- **Overlap Support**: Configurable overlap between chunks for context preservation

### Basic Usage

```python
from percolate.models.p8.types import Resources

# Simple chunking - basic text extraction (fast, no API costs)
resources = Resources.chunked_resource(
    uri="/path/to/document.pdf",
    parsing_mode="simple",
    chunk_size=1000,
    chunk_overlap=200
)

# Extended chunking - enhanced parsing (may use LLM services)
resources = Resources.chunked_resource(
    uri="/path/to/document.pdf", 
    parsing_mode="extended",
    chunk_size=1000,
    chunk_overlap=200
)
```

### File Type Support

#### Text Files (TXT, MD, HTML, etc.)
```python
# Direct text chunking
resources = Resources.chunked_resource(
    uri="file:///path/to/article.md",
    parsing_mode="simple",
    chunk_size=500
)
```

#### Documents (PDF, DOCX)
```python
# Extract text from PDF and chunk
resources = Resources.chunked_resource(
    uri="s3://bucket/document.pdf",
    parsing_mode="simple",        # Basic text extraction
    chunk_size=1000,
    chunk_overlap=100
)
```

#### Structured Data (CSV, Excel, JSON)
```python
# Convert structured data to text representation
resources = Resources.chunked_resource(
    uri="/path/to/data.csv",
    parsing_mode="simple",        # Creates table-formatted text
    chunk_size=800
)
```

#### Audio/Video Files
```python
# Audio files require transcription (extended mode only)
try:
    resources = Resources.chunked_resource(
        uri="/path/to/audio.wav",
        parsing_mode="simple"     # This will fail!
    )
except ValueError as e:
    print("Simple mode not supported for audio - transcription required")

# Correct usage - requires OpenAI API key
resources = Resources.chunked_resource(
    uri="/path/to/audio.wav",
    parsing_mode="extended",      # Uses OpenAI Whisper for transcription
    chunk_size=1000
)
```

### Advanced Configuration

```python
# Full configuration example
resources = Resources.chunked_resource(
    uri="https://example.com/document.pdf",
    parsing_mode="simple",
    chunk_size=1200,              # Characters per chunk
    chunk_overlap=150,            # Overlap between chunks
    category="research_doc",      # Custom category
    name="Research Paper",        # Custom name
    userid="user-123",           # Associate with user
    metadata={                   # Additional metadata
        "source": "web_scraping",
        "topic": "machine_learning"
    },
    save_to_db=False             # Save chunks to database
)

print(f"Created {len(resources)} chunks")
for i, chunk in enumerate(resources):
    print(f"Chunk {i+1}: {len(chunk.content)} characters")
    print(f"Metadata: {chunk.metadata}")
```

### Audio Transcription Setup

For audio/video file processing, you need an OpenAI API key:

```bash
# Set OpenAI API key
export OPENAI_API_KEY="your-openai-api-key"
```

```python
# Supported audio/video formats for transcription
audio_formats = ['.wav', '.mp3', '.m4a', '.flac', '.ogg']
video_formats = ['.mp4', '.mov', '.avi', '.mkv']

# Transcription with chunking
resources = Resources.chunked_resource(
    uri="/path/to/meeting.mp4",
    parsing_mode="extended",      # Required for transcription
    chunk_size=800,              # Chunk the transcription
    metadata={
        "meeting_date": "2024-01-15",
        "participants": ["Alice", "Bob"]
    }
)
```

### Chunk Metadata

Each chunk includes rich metadata:

```python
resources = Resources.chunked_resource(uri="/path/to/file.txt", parsing_mode="simple")

chunk = resources[0]
print(chunk.metadata)
# Output:
{
    "source_file": "file.txt",
    "parsing_mode": "simple", 
    "chunk_index": 0,
    "total_chunks": 3,
    "chunk_size": 1000,
    "chunk_overlap": 200,
    "file_type": "text",
    "original_uri": "/path/to/file.txt"
}
```

### Error Handling

```python
try:
    resources = Resources.chunked_resource(
        uri="/path/to/audio.wav",
        parsing_mode="simple"
    )
except ValueError as e:
    if "transcription is required" in str(e):
        print("Audio files need extended mode for transcription")
        # Retry with extended mode
        resources = Resources.chunked_resource(
            uri="/path/to/audio.wav",
            parsing_mode="extended"
        )
except Exception as e:
    print(f"Chunking failed: {e}")
```

### Performance Tips

- **Simple Mode**: Use for fast, cost-free text extraction
- **Extended Mode**: Currently same as simple mode, future LLM enhancements
- **Chunk Size**: Balance between context and processing efficiency
- **Overlap**: 10-20% of chunk_size is usually optimal
- **Batch Processing**: Process multiple files in parallel for better performance

### Integration with Existing Code

The chunking system is backward compatible:

```python
# Old method still works
old_resources = Resources.chunked_resource_old(
    uri="/path/to/file.txt",
    chunk_size=1000
)

# New method with enhanced features
new_resources = Resources.chunked_resource(
    uri="/path/to/file.txt", 
    parsing_mode="simple",
    chunk_size=1000,
    chunk_overlap=200
)
```