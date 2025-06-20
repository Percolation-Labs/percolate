"""
Resource Chunker for processing files into chunks

This module provides functionality to extract content from files 
and create chunked resources for indexing and searching.
"""

import io
import os
import tempfile
from pathlib import Path
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Union, Literal, BinaryIO, Callable, Tuple

# Import PDF handler
from percolate.utils.parsing.pdf_handler import get_pdf_handler, HAS_PYPDF as HAS_PDF

from percolate.utils import logger, make_uuid

class ResourceHandler:
    """Base class for resource handlers that extract content from different file types."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return False
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from the file data."""
        return ""

class PDFResourceHandler(ResourceHandler):
    """Handler for PDF files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type == 'pdf' and HAS_PDF
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from the PDF data."""
        pdf_handler = get_pdf_handler()
        
        # Handle different input types
        if mode == "simple":
            return pdf_handler.extract_text(file_data)
        else:  # extended mode
            file_name = kwargs.get('file_name', 'document.pdf')
            uri = kwargs.get('uri')
            return pdf_handler.extract_extended_content(file_data, file_name, uri)

class TextResourceHandler(ResourceHandler):
    """Handler for text files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type in ['text', 'markdown', 'md', 'txt', 'html']
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from text data."""
        if isinstance(file_data, str):
            return file_data
        elif isinstance(file_data, bytes):
            return file_data.decode('utf-8', errors='replace')
        elif isinstance(file_data, dict) and 'content' in file_data:
            return file_data['content']
        else:
            return str(file_data)

class CSVResourceHandler(ResourceHandler):
    """Handler for CSV files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type == 'csv'
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from CSV data."""
        if isinstance(file_data, str):
            # Already a string
            return file_data
        elif isinstance(file_data, dict) and 'data' in file_data:
            # CSV data - convert to simple text format
            rows = file_data['data']
            if not rows:
                return ""
            
            # Create simple text representation
            lines = []
            if len(rows) > 0:
                # Add header if available
                headers = list(rows[0].keys())
                lines.append(" | ".join(headers))
                lines.append("-" * len(" | ".join(headers)))
                
                # Add data rows
                for row in rows:
                    values = [str(row.get(h, "")) for h in headers]
                    lines.append(" | ".join(values))
            
            return "\n".join(lines)
        else:
            # Attempt to convert to string
            return str(file_data)

class ExcelResourceHandler(ResourceHandler):
    """Handler for Excel files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type in ['xlsx', 'xls']
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from Excel data."""
        if isinstance(file_data, str):
            # Already a string
            return file_data
        elif isinstance(file_data, dict):
            # Excel data - convert sheets to text format
            lines = []
            for sheet_name, df in file_data.items():
                lines.append(f"=== SHEET: {sheet_name} ===")
                try:
                    if hasattr(df, 'to_pandas'):
                        # Polars DataFrame
                        pandas_df = df.to_pandas()
                        lines.append(pandas_df.to_string(index=False, max_rows=100))
                    elif hasattr(df, 'to_string'):
                        # Pandas DataFrame
                        lines.append(df.to_string(index=False, max_rows=100))
                    elif hasattr(df, 'shape'):
                        # Other DataFrame-like object
                        lines.append(str(df))
                    else:
                        lines.append(str(df))
                except Exception as e:
                    logger.warning(f"Error converting sheet '{sheet_name}' to string: {e}")
                    lines.append(f"[Error displaying sheet data: {e}]")
                lines.append("")  # Add blank line between sheets
            
            return "\n".join(lines)
        else:
            # Attempt to convert to string
            return str(file_data)

class DocxResourceHandler(ResourceHandler):
    """Handler for DOCX files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type in ['docx', 'doc']
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from DOCX data."""
        if isinstance(file_data, str):
            # Already a string
            return file_data
        elif isinstance(file_data, dict):
            # Check if we have structured DOCX data
            if 'paragraphs' in file_data and 'full_text' in file_data:
                return file_data['full_text']
            elif 'paragraphs' in file_data:
                return "\n\n".join(file_data['paragraphs'])
            # Check for other dict formats
            for key in ['content', 'text', 'full_text']:
                if key in file_data:
                    return file_data[key]
            # Fall back to string representation
            return str(file_data)
        else:
            # Attempt to convert to string
            return str(file_data)

class PPTXResourceHandler(ResourceHandler):
    """Handler for PPTX files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type in ['pptx', 'ppt']
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from PPTX data."""
        if isinstance(file_data, str):
            # Already a string
            return file_data
        elif isinstance(file_data, dict):
            # Check for common PPTX result keys
            if 'text_content' in file_data:
                return file_data['text_content']
            elif 'slides' in file_data:
                # Extract text from slides
                texts = []
                for slide in file_data['slides']:
                    if isinstance(slide, dict):
                        if 'combined_text' in slide:
                            texts.append(slide['combined_text'])
                        elif 'text' in slide:
                            if isinstance(slide['text'], list):
                                texts.append("\n".join(slide['text']))
                            else:
                                texts.append(str(slide['text']))
                return "\n\n".join(texts)
            # Check for other dict formats
            for key in ['content', 'text']:
                if key in file_data:
                    return file_data[key]
            # Fall back to string representation
            return str(file_data)
        else:
            # Attempt to convert to string
            return str(file_data)

class ImageResourceHandler(ResourceHandler):
    """Handler for image files."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type == 'image'
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from image data."""
        if mode == "simple":
            # In simple mode, just return a placeholder
            file_name = kwargs.get('file_name', 'image.jpg')
            return f"[Image file: {file_name}]"
        else:
            # In extended mode, try to use LLM image analysis
            try:
                from percolate.services.llm.ImageInterpreter import get_image_interpreter
                interpreter = get_image_interpreter()
                
                if not interpreter.is_available():
                    logger.warning("Image interpreter not available for image analysis")
                    return f"Image file: {kwargs.get('file_name', 'image.jpg')} (analysis not available)"
                
                prompt = """
                Analyze this image in detail and provide:
                1. A comprehensive description of what you see
                2. Any text content visible in the image (OCR)
                3. Objects, people, scenes, or subjects present
                4. Colors, composition, and visual style
                5. Any technical diagrams, charts, or structured information
                6. Context clues about the purpose or meaning of the image
                
                Provide a thorough analysis that would be useful for document processing and search.
                """
                
                result = interpreter.describe_images(
                    images=file_data,
                    prompt=prompt,
                    context=f"Image file: {kwargs.get('file_name', 'image.jpg')}",
                    max_tokens=1500
                )
                
                if result["success"]:
                    return f"""
IMAGE ANALYSIS: {kwargs.get('file_name', 'image.jpg')}

{result['content']}

Analysis provided by: {result['provider']} ({result.get('model', 'unknown model')})
"""
                else:
                    return f"Image file: {kwargs.get('file_name', 'image.jpg')} (analysis failed: {result.get('error', 'Unknown error')})"
            
            except Exception as e:
                logger.error(f"Error in extended image processing: {str(e)}")
                return f"Image file: {kwargs.get('file_name', 'image.jpg')} (analysis error: {str(e)})"

class AudioResourceHandler(ResourceHandler):
    """Handler for audio files (WAV, MP3, etc.)."""
    
    def can_handle(self, file_type: str) -> bool:
        """Check if this handler can process the file type."""
        return file_type == 'audio'
    
    def extract_content(self, file_data: Any, file_type: str, mode: str = "simple", **kwargs) -> str:
        """Extract content from audio data."""
        if mode == "simple":
            # In simple mode, just log a warning that this isn't supported
            # and the file should be processed through _chunk_media_resource instead
            file_name = kwargs.get('file_name', 'audio.wav')
            logger.warning(f"Simple mode not supported for audio file {file_name}. Use extended mode for transcription.")
            return f"[Audio file: {file_name}] - Simple mode not supported, use extended mode for transcription."
        else:
            # In extended mode, audio should be handled by _chunk_media_resource
            # This shouldn't be called directly for extended mode, but if it is, return a placeholder
            file_name = kwargs.get('file_name', 'audio.wav')
            return f"[Audio file: {file_name}] - Should be processed through audio transcription pipeline."

class ResourceChunker:
    """
    Service for creating chunked resources from files.
    Supports both simple and extended parsing modes.
    """
    
    def __init__(self, read_function: Optional[Callable] = None, read_bytes_function: Optional[Callable] = None):
        """Initialize the resource chunker with optional functions for file reading."""
        self.read_function = read_function  # Function to read structured data
        self.read_bytes_function = read_bytes_function  # Function to read raw bytes
        self._transcription_service = None
        
        # Register resource handlers
        self._handlers = [
            PDFResourceHandler(),
            TextResourceHandler(),
            CSVResourceHandler(),
            ExcelResourceHandler(),
            DocxResourceHandler(),
            PPTXResourceHandler(),
            ImageResourceHandler(),
            AudioResourceHandler()
        ]
    
    def _get_handler(self, file_type: str) -> ResourceHandler:
        """Get the appropriate handler for the file type."""
        for handler in self._handlers:
            if handler.can_handle(file_type):
                return handler
        # Default to text handler if no specific handler is found
        return TextResourceHandler()
    
    def _get_transcription_service(self):
        """Lazy load transcription service to avoid circular imports."""
        if self._transcription_service is None:
            from percolate.services.llm.TranscriptionService import get_transcription_service
            self._transcription_service = get_transcription_service()
        return self._transcription_service
    
    def chunk_resource_from_uri(
        self,
        uri: str,
        parsing_mode: Literal["simple", "extended"] = "simple",
        chunk_size: int = 1000,
        chunk_overlap: int = 200,
        user_id: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        file_data: Optional[Any] = None
    ) -> List["Resources"]:
        """
        Create chunked resources from a file URI or provided file data.
        
        Args:
            uri: File URI (local file://, S3 s3://, or HTTP/HTTPS URL)
            parsing_mode: "simple" for basic text extraction, "extended" for LLM-enhanced parsing
            chunk_size: Number of characters per chunk
            chunk_overlap: Number of characters to overlap between chunks
            user_id: Optional user ID to associate with resources
            metadata: Optional metadata to include with resources
            file_data: Optional pre-loaded file data (bypasses read_function if provided)
            
        Returns:
            List of Resources representing the chunks
            
        Raises:
            ValueError: If file type is not supported or transcription is required
            Exception: If parsing fails
        """
        from percolate.utils import make_uuid
        from percolate.models.p8.types import Resources
        
        logger.info(f"Chunking resource from URI: {uri} (mode: {parsing_mode})")
        
        # Extract file info from URI
        file_info = self._extract_file_info(uri)
        file_type = file_info['type']
        file_name = file_info['name']
        
        # Check if this is audio/video and handle accordingly
        if file_type in ['audio', 'video']:
            return self._chunk_media_resource(
                uri, file_type, parsing_mode, user_id, metadata
            )
        
        # For other file types, use provided file data or read function
        try:
            # Use provided file data or read from URI
            if file_data is None:
                if self.read_function:
                    file_data = self.read_function(uri)
                else:
                    raise ValueError("No read_function provided and no file_data supplied")
            
            # Use the appropriate handler to extract content
            handler = self._get_handler(file_type)
            
            if parsing_mode == "simple":
                content = handler.extract_content(
                    file_data, 
                    file_type, 
                    mode="simple", 
                    file_name=file_name, 
                    uri=uri
                )
            else:  # extended
                content = handler.extract_content(
                    file_data, 
                    file_type, 
                    mode="extended", 
                    file_name=file_name, 
                    uri=uri
                )
            
            # Create chunks from the content
            chunks = self._create_text_chunks(
                content, chunk_size, chunk_overlap
            )
            
            # Create Resource objects for each chunk
            resources = []
            for i, chunk_text in enumerate(chunks):
                resource_id = make_uuid(f"{uri}_chunk_{i}")
                
                resource = Resources(
                    id=resource_id,
                    name=f"{file_name}_chunk_{i+1}",
                    category=f"{file_type}_chunk",
                    content=chunk_text,
                    uri=uri,
                    metadata={
                        **(metadata or {}),
                        "source_file": file_name,
                        "parsing_mode": parsing_mode,
                        "chunk_index": i,
                        "total_chunks": len(chunks),
                        "chunk_size": chunk_size,
                        "chunk_overlap": chunk_overlap,
                        "file_type": file_type,
                        "original_uri": uri
                    },
                    userid=user_id,
                    resource_timestamp=datetime.now(timezone.utc)
                )
                resources.append(resource)
            
            logger.info(f"Created {len(resources)} chunks from {file_name}")
            return resources
            
        except Exception as e:
            logger.error(f"Error chunking resource from {uri}: {str(e)}")
            raise
    
    def _extract_file_info(self, uri: str) -> Dict[str, str]:
        """Extract file information from URI."""
        # Get filename from URI
        if uri.startswith('http'):
            file_name = uri.split('/')[-1].split('?')[0]  # Remove query params
        else:
            file_name = os.path.basename(uri.replace('file://', '').replace('s3://', ''))
        
        # Determine file type from extension
        ext = Path(file_name).suffix.lower()
        
        if ext in ['.txt', '.md', '.markdown']:
            file_type = 'text'
        elif ext in ['.pdf']:
            file_type = 'pdf'
        elif ext in ['.docx', '.doc']:
            file_type = 'docx'
        elif ext in ['.pptx', '.ppt']:
            file_type = 'pptx'
        elif ext in ['.csv']:
            file_type = 'csv'
        elif ext in ['.xlsx', '.xls']:
            file_type = 'xlsx'
        elif ext in ['.json']:
            file_type = 'json'
        elif ext in ['.html', '.htm']:
            file_type = 'html'
        elif ext in ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff']:
            file_type = 'image'
        elif ext in ['.wav', '.mp3', '.m4a', '.flac', '.ogg']:
            file_type = 'audio'
        elif ext in ['.mp4', '.mov', '.avi', '.mkv']:
            file_type = 'video'
        else:
            file_type = 'unknown'
        
        return {
            'name': file_name,
            'type': file_type,
            'extension': ext
        }
    
    def _chunk_media_resource(
        self,
        uri: str,
        file_type: str,
        parsing_mode: str,
        user_id: Optional[str],
        metadata: Optional[Dict[str, Any]]
    ) -> List["Resources"]:
        """Handle audio/video files that require transcription with intelligent chunking."""
        self._validate_media_processing_requirements(file_type, parsing_mode)
        
        # Parameters for audio chunking and transcription
        max_transcription_size = 10 * 1024 * 1024  # 10MB limit (reduced for memory efficiency)
        chunk_duration_seconds = 5 * 60  # 5 minutes per chunk (reduced for memory efficiency)
        
        logger.info(f"Processing {file_type} file: {uri}")
        
        # Download file to temporary location
        temp_path, file_size = self._download_media_file(uri)
        
        try:
            # Process the audio file
            audio_chunks = self._prepare_audio_chunks(temp_path, file_size, max_transcription_size, chunk_duration_seconds)
            
            # Transcribe all audio chunks
            all_transcriptions, total_duration = self._transcribe_audio_chunks(audio_chunks, temp_path)
            
            # Check if we have any successful transcriptions
            if not all_transcriptions:
                logger.warning("No transcriptions were successful. Cannot create resources.")
                return []
            
            # Process transcriptions and create resource chunks
            return self._create_transcription_resources(
                uri, all_transcriptions, total_duration, file_type, 
                parsing_mode, user_id, metadata, file_size
            )
            
        finally:
            # Clean up main temp file
            if os.path.exists(temp_path):
                os.unlink(temp_path)
                
    def _validate_media_processing_requirements(self, file_type: str, parsing_mode: str) -> None:
        """Validate that we have everything needed to process media files."""
        if parsing_mode == "simple":
            raise ValueError(
                f"Simple parsing mode not supported for {file_type} files. "
                "Transcription is required. Use extended mode or process through audio pipeline."
            )
        
        # For extended mode, we need transcription
        transcription_service = self._get_transcription_service()
        if not transcription_service.is_available():
            raise ValueError(
                "OpenAI API key not available for transcription. "
                "Cannot process audio/video files in extended mode."
            )
            
    def _download_media_file(self, uri: str) -> Tuple[str, int]:
        """Download media file to a temporary location and return path and size."""
        # Create temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix=Path(uri).suffix) as temp_file:
            temp_path = temp_file.name
            
        # Download the file
        if self.read_bytes_function:
            file_data = self.read_bytes_function(uri)
        else:
            raise ValueError("No read_bytes_function provided for media file")
        
        # Write to temporary file
        with open(temp_path, 'wb') as f:
            f.write(file_data)
        
        file_size = len(file_data)
        logger.info(f"Audio file size: {file_size / (1024*1024):.1f}MB")
        
        return temp_path, file_size
    
    def _prepare_audio_chunks(
        self, 
        file_path: str, 
        file_size: int, 
        max_size: int, 
        chunk_duration: int
    ) -> List[Tuple[str, float, float]]:
        """Prepare audio chunks for transcription."""
        transcription_service = self._get_transcription_service()
        
        # Check if file type is supported by transcription service
        if not transcription_service.supports_file_type(file_path):
            raise ValueError(f"File type {Path(file_path).suffix} not supported for transcription")
        
        # Determine if we need to chunk the audio file
        if file_size <= max_size:
            logger.info("File size within transcription limits, processing as single file")
            return [(file_path, 0, None)]  # (path, start_time, end_time)
        else:
            logger.info(f"File size ({file_size / (1024*1024):.1f}MB) exceeds limit, chunking audio")
            return self._chunk_large_audio_file(file_path, max_size, chunk_duration)
    
    def _transcribe_audio_chunks(
        self, 
        audio_chunks: List[Tuple[str, float, Optional[float]]], 
        original_path: str
    ) -> Tuple[List[Dict[str, Any]], float]:
        """Transcribe all audio chunks and return transcriptions with total duration."""
        transcription_service = self._get_transcription_service()
        all_transcriptions = []
        total_duration = 0
        
        for i, (chunk_path, start_time, end_time) in enumerate(audio_chunks):
            logger.info(f"Transcribing audio chunk {i+1}/{len(audio_chunks)}")
            
            try:
                # TranscriptionService.transcribe_file is synchronous
                transcription, confidence = transcription_service.transcribe_file(chunk_path)
                
                # Create timestamped transcription entry
                if start_time is not None and end_time is not None:
                    duration = end_time - start_time
                    timestamp_text = f"[{start_time:.1f}s - {end_time:.1f}s]: {transcription}"
                    total_duration = max(total_duration, end_time)
                else:
                    timestamp_text = transcription
                    duration = None
                
                all_transcriptions.append({
                    'text': transcription,
                    'timestamped_text': timestamp_text,
                    'start_time': start_time,
                    'end_time': end_time,
                    'duration': duration,
                    'confidence': confidence,
                    'chunk_index': i
                })
                
                logger.info(f"Chunk {i+1} transcribed: {len(transcription)} characters")
                
            except Exception as e:
                logger.error(f"Failed to transcribe chunk {i+1}: {e}")
                # Continue with other chunks rather than failing completely
                continue
            finally:
                # Clean up temporary chunk file immediately to free memory
                if chunk_path != original_path and os.path.exists(chunk_path):
                    try:
                        os.unlink(chunk_path)
                        logger.debug(f"Deleted chunk file: {chunk_path}")
                    except Exception as e:
                        logger.warning(f"Failed to delete chunk file {chunk_path}: {e}")
                    
        # Clean up the chunk directory if all chunks have been processed
        if len(audio_chunks) > 0 and audio_chunks[0][0] != original_path:
            chunk_dir = os.path.dirname(audio_chunks[0][0])
            if os.path.exists(chunk_dir) and chunk_dir.startswith(tempfile.gettempdir()):
                try:
                    import shutil
                    shutil.rmtree(chunk_dir)
                    logger.info(f"Cleaned up chunk directory: {chunk_dir}")
                except Exception as e:
                    logger.warning(f"Failed to clean up chunk directory {chunk_dir}: {e}")
        
        return all_transcriptions, total_duration
    
    def _create_transcription_resources(
        self,
        uri: str,
        transcriptions: List[Dict[str, Any]],
        total_duration: float,
        file_type: str,
        parsing_mode: str,
        user_id: Optional[str],
        metadata: Optional[Dict[str, Any]],
        file_size: int
    ) -> List["Resources"]:
        """Create resource chunks from transcriptions."""
        from percolate.utils import make_uuid
        from percolate.models.p8.types import Resources
        
        # Combine all transcriptions into full text
        full_transcription = "\n\n".join([t['timestamped_text'] for t in transcriptions])
        average_confidence = sum(t['confidence'] for t in transcriptions) / len(transcriptions) if transcriptions else 0.0
        
        logger.info(f"Complete transcription: {len(full_transcription)} characters from {len(transcriptions)} chunks")
        
        # For audio transcriptions, we'll use larger chunks to avoid too many small fragments
        chunk_size = 2000  # Larger than default to reduce fragmentation
        chunk_overlap = 200  # Default overlap
        
        logger.info(f"Chunking transcription text with size={chunk_size}, overlap={chunk_overlap}")
        text_chunks = self._create_text_chunks(
            full_transcription,
            chunk_size=chunk_size,
            chunk_overlap=chunk_overlap
        )
        
        # Log the number of chunks created
        logger.info(f"Created {len(text_chunks)} text chunks from transcription ({len(full_transcription)} chars)")
        
        file_info = self._extract_file_info(uri)
        resources = []
        
        for i, chunk_text in enumerate(text_chunks):
            resource = self._create_transcription_resource(
                uri, chunk_text, i, len(text_chunks), file_info, file_type,
                parsing_mode, average_confidence, total_duration, 
                transcriptions, user_id, metadata, file_size
            )
            resources.append(resource)
        
        logger.info(f"Created {len(resources)} transcription resources for {file_info['name']}")
        return resources
    
    def _create_transcription_resource(
        self,
        uri: str,
        chunk_text: str,
        chunk_index: int,
        total_chunks: int,
        file_info: Dict[str, str],
        file_type: str,
        parsing_mode: str,
        confidence: float,
        total_duration: float,
        transcriptions: List[Dict[str, Any]],
        user_id: Optional[str],
        metadata: Optional[Dict[str, Any]],
        file_size: int
    ) -> "Resources":
        """Create a single transcription resource."""
        from percolate.utils import make_uuid
        from percolate.models.p8.types import Resources
        
        resource_id = make_uuid(f"{uri}_transcription_chunk_{chunk_index}")
        
        return Resources(
            id=resource_id,
            name=f"{file_info['name']}_transcription_chunk_{chunk_index+1}",
            category=f"{file_type}_transcription",
            content=chunk_text,
            uri=uri,
            metadata={
                **(metadata or {}),
                "source_file": file_info['name'],
                "parsing_mode": parsing_mode,
                "file_type": file_type,
                "transcription_confidence": confidence,
                "original_uri": uri,
                "transcription_service": "openai_whisper",
                "audio_chunks_processed": len(transcriptions),
                "total_audio_duration_seconds": total_duration,
                "chunk_index": chunk_index,
                "total_chunks": total_chunks,
                "audio_file_size_mb": file_size / (1024*1024),
                "transcription_chunks": [
                    {
                        "start_time": t["start_time"],
                        "end_time": t["end_time"], 
                        "confidence": t["confidence"]
                    } for t in transcriptions
                ]
            },
            userid=user_id,
            resource_timestamp=datetime.now(timezone.utc)
        )
    
    def _chunk_large_audio_file(
        self,
        audio_path: str,
        max_size_bytes: int,
        chunk_duration_seconds: int
    ) -> List[tuple]:
        """
        Chunk a large audio file into smaller pieces for transcription.
        
        Args:
            audio_path: Path to the audio file
            max_size_bytes: Maximum size per chunk in bytes
            chunk_duration_seconds: Maximum duration per chunk in seconds
            
        Returns:
            List of (chunk_path, start_time, end_time) tuples
        """
        try:
            # Try to use pydub for audio processing
            from pydub import AudioSegment
            
            logger.info(f"Loading audio file for chunking: {audio_path}")
            audio = AudioSegment.from_file(audio_path)
            
            # Get audio properties
            duration_seconds = len(audio) / 1000.0
            file_size = os.path.getsize(audio_path)
            
            logger.info(f"Audio duration: {duration_seconds:.1f}s, file size: {file_size / (1024*1024):.1f}MB")
            
            # Calculate number of chunks needed
            # Use the more restrictive of size or time limits
            chunks_by_size = max(1, file_size // max_size_bytes + (1 if file_size % max_size_bytes else 0))
            chunks_by_duration = max(1, int(duration_seconds // chunk_duration_seconds) + (1 if duration_seconds % chunk_duration_seconds else 0))
            
            num_chunks = max(chunks_by_size, chunks_by_duration)
            chunk_duration_ms = len(audio) // num_chunks
            
            logger.info(f"Splitting into {num_chunks} chunks of ~{chunk_duration_ms/1000:.1f}s each")
            
            chunks = []
            chunk_dir = tempfile.mkdtemp(prefix="audio_chunks_")
            logger.info(f"Created temporary chunk directory: {chunk_dir}")
            
            for i in range(num_chunks):
                start_ms = i * chunk_duration_ms
                end_ms = min((i + 1) * chunk_duration_ms, len(audio))
                
                # Extract chunk
                chunk_audio = audio[start_ms:end_ms]
                
                # Save chunk to temporary file
                chunk_filename = f"chunk_{i+1}.wav"
                chunk_path = os.path.join(chunk_dir, chunk_filename)
                
                # Export as WAV
                chunk_audio.export(chunk_path, format="wav")
                
                start_time = start_ms / 1000.0
                end_time = end_ms / 1000.0
                
                chunks.append((chunk_path, start_time, end_time))
                
                logger.info(f"Created chunk {i+1}: {start_time:.1f}s - {end_time:.1f}s ({os.path.getsize(chunk_path) / (1024*1024):.1f}MB)")
                
                # Free memory from the chunk audio segment
                del chunk_audio
            
            return chunks
            
        except ImportError:
            logger.error("pydub is required for audio chunking but not available")
            raise ImportError("pydub library is required for large audio file processing")
        
        except Exception as e:
            logger.error(f"Error chunking audio file: {e}")
            raise Exception(f"Failed to chunk audio file: {e}")
    
    def _create_text_chunks(
        self,
        text: str,
        chunk_size: int,
        chunk_overlap: int
    ) -> List[str]:
        """Create text chunks with overlap."""
        if not text or len(text) <= chunk_size:
            return [text] if text else []
        
        chunks = []
        start = 0
        
        while start < len(text):
            end = start + chunk_size
            
            # If this isn't the last chunk, try to break at word boundaries
            if end < len(text):
                # Look for the last space within the chunk
                last_space = text.rfind(' ', start, end)
                if last_space > start:
                    end = last_space
            
            chunk = text[start:end].strip()
            if chunk:
                chunks.append(chunk)
            
            # Move start position considering overlap
            if end >= len(text):
                break
            start = end - chunk_overlap
            
            # Ensure we don't go backwards
            if len(chunks) > 0 and start <= len(''.join(chunks)) - len(chunks[-1]):
                start = len(''.join(chunks)) - chunk_overlap
        
        return chunks
    
    def save_chunks_to_database(self, resources: List["Resources"]) -> bool:
        """Save chunked resources to the database."""
        try:
            if not resources:
                logger.warning("No resources to save")
                return True
            
            logger.info(f"Saving {len(resources)} chunked resources to database")
            import percolate as p8
            p8.repository(type(resources[0])).update_records(resources)
            logger.info("Successfully saved all chunked resources")
            return True
            
        except Exception as e:
            logger.error(f"Error saving chunked resources: {str(e)}")
            return False


# Factory function to create a ResourceChunker with appropriate read functions
def create_resource_chunker(fs=None):
    """
    Create a ResourceChunker with appropriate read functions.
    
    Args:
        fs: Optional FileSystemService instance to use for reading files.
        
    Returns:
        ResourceChunker instance
    """
    if fs is None:
        # Create a resource chunker without file system functions
        return ResourceChunker()
    else:
        # Create a resource chunker with file system functions
        return ResourceChunker(
            read_function=fs.read,
            read_bytes_function=fs.read_bytes
        )


# Global resource chunker instance
_resource_chunker = None

def get_resource_chunker(fs=None):
    """Get a global resource chunker instance."""
    global _resource_chunker
    if _resource_chunker is None or fs is not None:
        _resource_chunker = create_resource_chunker(fs)
    return _resource_chunker


# For backward compatibility - will be removed in future versions
def extract_pdf_content(pdf_data: Union[Dict[str, Any], bytes]) -> str:
    """
    Extract text content from PDF data.
    
    Args:
        pdf_data: Dictionary containing PDF data or raw bytes
        
    Returns:
        Extracted text content
    """
    # Delegate to our improved PDFHandler implementation
    return get_pdf_handler().extract_text(pdf_data)