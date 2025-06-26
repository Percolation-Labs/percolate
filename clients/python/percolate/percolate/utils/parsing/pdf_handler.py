"""
PDF Handler module for extracting content from PDF files.

This module provides a unified interface for working with PDF files,
supporting text extraction, image extraction, and LLM-enhanced analysis.
"""

import io
import os
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Any, Union, Optional, BinaryIO, Tuple

from PIL import Image

import logging

# Use standard logging instead of percolate logger to avoid circular imports
logger = logging.getLogger("percolate.parsing.pdf_handler")

# Try to import PDF libraries with graceful fallbacks
try:
    import pypdf
    HAS_PYPDF = True
except ImportError:
    HAS_PYPDF = False
    logger.warning("pypdf not available, PDF text extraction will be limited")

try:
    import fitz  # PyMuPDF
    HAS_FITZ = True
except ImportError:
    HAS_FITZ = False
    logger.warning("fitz (PyMuPDF) not available, PDF image extraction will be limited")


class PDFHandler:
    """
    Handler for PDF files with comprehensive extraction capabilities.
    """

    def can_handle(self, file_path: str) -> bool:
        """Check if this handler can process the file."""
        return Path(file_path).suffix.lower() == '.pdf' and (HAS_PYPDF or HAS_FITZ)
    
    def read(self, file_stream: Union[BinaryIO, bytes], **kwargs) -> Dict[str, Any]:
        """
        Read PDF and return a dictionary with text content and metadata.
        Enhanced version for comprehensive PDF parsing.
        
        Args:
            file_stream: File-like object or bytes containing the PDF
            **kwargs: Additional arguments for controlling extraction
                - min_image_size: Minimum dimensions for images to extract (default: (300, 300))
                
        Returns:
            Dict with text_pages, images, image_info, num_pages, and metadata
        """
        if not (HAS_PYPDF or HAS_FITZ):
            raise ImportError("PDF support requires pypdf or PyMuPDF (fitz)")
        
        start_time = time.time()
        
        # Ensure we have a file-like object
        if isinstance(file_stream, bytes):
            logger.debug(f"PDF read: Converting {len(file_stream)} bytes to BytesIO")
            pdf_stream = io.BytesIO(file_stream)
        else:
            logger.debug(f"PDF read: Using provided stream")
            pdf_stream = file_stream
            
        # Initialize result structure
        result = {
            'text_pages': [],
            'images': [],
            'image_info': [],
            'num_pages': 0,
            'metadata': {}
        }
        
        # Prefer fitz (PyMuPDF) as it's faster and more capable
        if HAS_FITZ:
            try:
                # Reset stream position
                if hasattr(pdf_stream, 'seek'):
                    pdf_stream.seek(0)
                
                with fitz.open(stream=pdf_stream, filetype="pdf") as pdf_document:
                    # Extract text from each page
                    for page_num in range(pdf_document.page_count):
                        page = pdf_document.load_page(page_num)
                        text = page.get_text()
                        result['text_pages'].append(text)
                    
                    result['num_pages'] = pdf_document.page_count
                    
                    # Extract metadata
                    metadata = pdf_document.metadata
                    if metadata:
                        result['metadata'] = {
                            'title': metadata.get('title', ''),
                            'author': metadata.get('author', ''),
                            'subject': metadata.get('subject', ''),
                            'creation_date': metadata.get('creationDate', ''),
                            'creator': metadata.get('creator', '')
                        }
                    
                    # Extract images
                    min_image_size = kwargs.get('min_image_size', (300, 300))
                    for page_num in range(pdf_document.page_count):
                        page = pdf_document.load_page(page_num)
                        page_images = []
                        
                        for img in page.get_images(full=True):
                            try:
                                xref = img[0]
                                base_image = pdf_document.extract_image(xref)
                                image_bytes = base_image["image"]
                                image = Image.open(io.BytesIO(image_bytes))
                                
                                # Filter out small images (likely logos/decorations)
                                if image.size[0] >= min_image_size[0] and image.size[1] >= min_image_size[1]:
                                    page_images.append(image)
                            except Exception as img_error:
                                logger.warning(f"Error extracting image: {img_error}")
                        
                        result['images'].append(page_images)
                        result['image_info'].append(page.get_image_info())
            except Exception as e:
                logger.error(f"Error extracting with fitz: {str(e)}")
                # If fitz fails, fall back to pypdf if available
                if HAS_PYPDF:
                    return self._read_with_pypdf(pdf_stream, **kwargs)
                else:
                    raise
        
        # Only use pypdf if fitz is not available
        elif HAS_PYPDF:
            return self._read_with_pypdf(pdf_stream, **kwargs)
        else:
            raise ImportError("PDF support requires either PyMuPDF (fitz) or pypdf")
        
        # Ensure num_pages is accurate
        if result['num_pages'] == 0 and result['text_pages']:
            result['num_pages'] = len(result['text_pages'])
        
        # Include raw bytes for further processing if needed
        if isinstance(file_stream, bytes):
            result['raw_bytes'] = file_stream
        elif isinstance(pdf_stream, io.BytesIO):
            pdf_stream.seek(0)
            result['raw_bytes'] = pdf_stream.read()
        
        return result
    
    def _read_with_pypdf(self, pdf_stream: Union[BinaryIO, bytes], **kwargs) -> Dict[str, Any]:
        """Fallback method to read PDF with pypdf when fitz is not available."""
        # Initialize result structure
        result = {
            'text_pages': [],
            'images': [],
            'image_info': [],
            'num_pages': 0,
            'metadata': {}
        }
        
        try:
            # Ensure we have a proper stream
            if isinstance(pdf_stream, bytes):
                pdf_stream = io.BytesIO(pdf_stream)
            elif not hasattr(pdf_stream, 'seek'):
                pdf_stream = io.BytesIO(pdf_stream.read())
            
            pdf_stream.seek(0)
            pdf_reader = pypdf.PdfReader(stream=pdf_stream)
            
            # Extract text from each page
            for page_num in range(len(pdf_reader.pages)):
                page = pdf_reader.pages[page_num]
                text = page.extract_text()
                result['text_pages'].append(text.replace('\n \n', ' '))  # Clean text
            
            # Add metadata
            if pdf_reader.metadata:
                result['metadata'] = {
                    'title': pdf_reader.metadata.get('/Title', ''),
                    'author': pdf_reader.metadata.get('/Author', ''),
                    'subject': pdf_reader.metadata.get('/Subject', ''),
                    'creation_date': pdf_reader.metadata.get('/CreationDate', ''),
                    'creator': pdf_reader.metadata.get('/Creator', '')
                }
            
            result['num_pages'] = len(pdf_reader.pages)
            
            # Include raw bytes for further processing if needed
            if isinstance(pdf_stream, io.BytesIO):
                pdf_stream.seek(0)
                result['raw_bytes'] = pdf_stream.read()
            
        except Exception as e:
            logger.error(f"Error extracting text with pypdf: {str(e)}")
            raise
        
        return result
        
    def write(self, file_stream: BinaryIO, data: bytes) -> None:
        """Write PDF bytes to file."""
        if isinstance(data, bytes):
            file_stream.write(data)
        else:
            raise ValueError("PDF writing requires bytes input")
    
    def extract_text(self, pdf_data: Union[Dict[str, Any], bytes, BinaryIO]) -> str:
        """
        Extract plain text content from PDF data.
        
        Args:
            pdf_data: PDF data as dictionary from read(), bytes, or file-like object
            
        Returns:
            Extracted text content with page markers
        """
        # Handle dictionary from read()
        if isinstance(pdf_data, dict) and 'text_pages' in pdf_data:
            # Join all text pages with page markers for clarity
            pages = []
            for i, page_text in enumerate(pdf_data['text_pages']):
                pages.append(f"--- Page {i+1} ---\n{page_text}")
            return "\n\n".join(pages)
        
        # Handle raw bytes
        elif isinstance(pdf_data, bytes) or (isinstance(pdf_data, dict) and 'raw_bytes' in pdf_data):
            if not HAS_PYPDF:
                return "[PDF extraction requires pypdf]"
                
            # Get the raw bytes
            raw_bytes = pdf_data if isinstance(pdf_data, bytes) else pdf_data.get('raw_bytes')
            
            if not raw_bytes:
                return "[No PDF content available]"
            
            # Create a PDF reader
            pdf_file = io.BytesIO(raw_bytes)
            pdf_reader = pypdf.PdfReader(pdf_file)
            
            # Extract text from all pages
            pages = []
            for i, page in enumerate(pdf_reader.pages):
                page_text = page.extract_text()
                if page_text:
                    pages.append(f"--- Page {i+1} ---\n{page_text}")
                else:
                    pages.append(f"--- Page {i+1} ---\n[No extractable text]")
            
            # Join all pages and return
            return "\n\n".join(pages)
        
        # Handle file-like object
        elif hasattr(pdf_data, 'read'):
            # Read the data into memory
            pdf_bytes = pdf_data.read()
            
            # Process as bytes
            return self.extract_text(pdf_bytes)
            
        else:
            # If all else fails, return generic message
            return "[PDF content could not be extracted]"
    
    def convert_pdf_to_images(self, pdf_data: Union[Dict[str, Any], bytes, BinaryIO], uri: str = None) -> List[Image.Image]:
        """
        Convert PDF pages to PIL Images for analysis.
        
        Args:
            pdf_data: PDF data as dictionary from read(), bytes, or file-like object
            uri: Optional URI for the PDF file (can be used for direct file access)
            
        Returns:
            List of PIL Image objects, one per page
        """
        # First try pdf2image method (requires poppler)
        images = self._try_pdf2image_conversion(pdf_data, uri)
        if images:
            return images
            
        # Fallback to fitz method if pdf2image fails
        images = self._try_fitz_conversion(pdf_data)
        if images:
            return images
        
        # If both methods failed, raise an exception
        raise Exception(
            "Failed to convert PDF pages to images. "
            "Both pdf2image and fitz (PyMuPDF) conversion methods failed. "
            "Extended PDF processing requires successful page-to-image conversion. "
            "Please ensure poppler-utils and/or PyMuPDF are properly installed."
        )
    
    def _try_pdf2image_conversion(self, pdf_data: Union[Dict[str, Any], bytes, BinaryIO], uri: str = None) -> List[Image.Image]:
        """Try to convert PDF to images using pdf2image (preferred method)."""
        try:
            from pdf2image import convert_from_path, convert_from_bytes
            
            # If we have a URI and it's a local file, use convert_from_path
            if uri and os.path.exists(uri.replace('file://', '')):
                path = uri.replace('file://', '')
                logger.info(f"Converting PDF pages to images using pdf2image convert_from_path for {path}")
                images = convert_from_path(path)
                logger.info(f"Successfully converted {len(images)} pages to images using convert_from_path")
                return images
            
            # Otherwise, get bytes and use convert_from_bytes
            if isinstance(pdf_data, dict) and 'raw_bytes' in pdf_data:
                raw_bytes = pdf_data['raw_bytes']
            elif isinstance(pdf_data, bytes):
                raw_bytes = pdf_data
            elif hasattr(pdf_data, 'read'):
                # Ensure we're at the beginning
                if hasattr(pdf_data, 'seek'):
                    pdf_data.seek(0)
                raw_bytes = pdf_data.read()
            else:
                logger.warning("Could not extract bytes from PDF data")
                return None
                
            logger.info("Converting PDF pages to images using pdf2image convert_from_bytes")
            images = convert_from_bytes(raw_bytes)
            logger.info(f"Successfully converted {len(images)} pages to images using convert_from_bytes")
            return images
            
        except ImportError:
            logger.warning("pdf2image not available, falling back to fitz rendering")
            return None
        except Exception as e:
            logger.warning(f"pdf2image conversion failed: {e}, falling back to fitz rendering")
            return None
            
    def _try_fitz_conversion(self, pdf_data: Union[Dict[str, Any], bytes, BinaryIO]) -> List[Image.Image]:
        """Try to convert PDF to images using PyMuPDF (fitz)."""
        if not HAS_FITZ:
            logger.error("fitz (PyMuPDF) not available for PDF page rendering")
            return None
            
        try:
            # Get bytes from PDF data
            if isinstance(pdf_data, dict) and 'raw_bytes' in pdf_data:
                raw_bytes = pdf_data['raw_bytes']
            elif isinstance(pdf_data, bytes):
                raw_bytes = pdf_data
            elif hasattr(pdf_data, 'read'):
                # Ensure we're at the beginning
                if hasattr(pdf_data, 'seek'):
                    pdf_data.seek(0)
                raw_bytes = pdf_data.read()
            else:
                logger.error("Could not extract bytes from PDF data for fitz")
                return None
                
            logger.info("Converting PDF pages to images using fitz")
            pdf_document = fitz.open(stream=raw_bytes, filetype="pdf")
            images = []
            
            for page_num in range(pdf_document.page_count):
                page = pdf_document.load_page(page_num)
                # Render page as image (default DPI is 72, increase for better quality)
                pix = page.get_pixmap(matrix=fitz.Matrix(2, 2))  # 2x scale for better quality
                img_data = pix.tobytes("png")
                image = Image.open(io.BytesIO(img_data))
                images.append(image)
            
            pdf_document.close()
            logger.info(f"Successfully converted {len(images)} pages to images using fitz")
            return images
        except Exception as e:
            logger.error(f"Fitz PDF page conversion failed: {e}")
            return None
    
    def extract_images_from_pdf(self, pdf_data: Dict[str, Any], min_size: Tuple[int, int] = (300, 300)) -> List[Image.Image]:
        """
        Extract images from PDF pages.
        
        Args:
            pdf_data: PDF data dictionary from read()
            min_size: Minimum image dimensions to extract
            
        Returns:
            List of PIL Image objects
        """
        # If images were already extracted during read()
        if isinstance(pdf_data, dict) and 'images' in pdf_data and pdf_data['images']:
            images = []
            for page_images in pdf_data['images']:
                images.extend(page_images)
            return images
        
        # Otherwise, try to extract them now
        if not HAS_FITZ:
            logger.warning("PyMuPDF not available for image extraction")
            return []
            
        try:
            # Get raw bytes
            if isinstance(pdf_data, dict) and 'raw_bytes' in pdf_data:
                raw_bytes = pdf_data['raw_bytes']
            else:
                logger.warning("No raw bytes available in PDF data for image extraction")
                return []
                
            pdf_document = fitz.open(stream=raw_bytes, filetype="pdf")
            all_images = []
            
            for page_num in range(pdf_document.page_count):
                page = pdf_document.load_page(page_num)
                for img in page.get_images(full=True):
                    try:
                        xref = img[0]
                        base_image = pdf_document.extract_image(xref)
                        image_bytes = base_image["image"]
                        image = Image.open(io.BytesIO(image_bytes))
                        
                        # Filter out small images
                        if image.size[0] >= min_size[0] and image.size[1] >= min_size[1]:
                            all_images.append(image)
                    except Exception as e:
                        logger.warning(f"Failed to extract image: {e}")
            
            pdf_document.close()
            return all_images
            
        except Exception as e:
            logger.error(f"Error extracting images from PDF: {e}")
            return []
    
    def read_chunks(self, file_input: Union[str, BinaryIO, bytes, Dict[str, Any]], mode: str = "simple", chunk_size: int = 1000, chunk_overlap: int = 200, **kwargs):
        """
        Generator that yields chunks of content from the PDF.
        
        Args:
            file_input: File path/URL (str), file-like object, bytes, or dict containing the PDF data
            mode: "simple" for text only, "extended" for text + image analysis
            chunk_size: Maximum size of each chunk
            chunk_overlap: Overlap between chunks
            **kwargs: Additional arguments including file_name and uri
            
        Yields:
            Chunks of text content
        """
        # Check if we received a file path/URL (string)
        if isinstance(file_input, str):
            logger.debug(f"read_chunks: Reading PDF from path/URL: {file_input}")
            
            # Handle different URI schemes
            if file_input.startswith(('s3://', 'http://', 'https://', 'file://')):
                # Use FileSystemService to read the file
                from percolate.services.FileSystemService import FileSystemService
                fs = FileSystemService()
                file_bytes = fs.read_bytes(file_input)
                
                # Now process with fitz
                if HAS_FITZ:
                    pdf_document = fitz.open(stream=file_bytes, filetype="pdf")
                else:
                    # Fallback to read method
                    pdf_data = self.read(file_bytes, **kwargs)
                    for page_num, page_text in enumerate(pdf_data['text_pages']):
                        if not page_text.strip():
                            continue
                        page_content = f"--- Page {page_num + 1} ---\n{page_text}"
                        for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                            yield chunk
                    return
            else:
                # Local file path
                if HAS_FITZ:
                    pdf_document = fitz.open(file_input)
                else:
                    # Read file and use read method
                    with open(file_input, 'rb') as f:
                        file_bytes = f.read()
                    pdf_data = self.read(file_bytes, **kwargs)
                    for page_num, page_text in enumerate(pdf_data['text_pages']):
                        if not page_text.strip():
                            continue
                        page_content = f"--- Page {page_num + 1} ---\n{page_text}"
                        for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                            yield chunk
                    return
        
        # Check if we received already-processed PDF data (dict from read())
        elif isinstance(file_input, dict) and 'text_pages' in file_input:
            logger.debug("read_chunks: Received pre-processed PDF data (dict)")
            pdf_data = file_input
            
            # Process the already-extracted text
            for page_num, page_text in enumerate(pdf_data['text_pages']):
                if not page_text.strip():
                    continue
                    
                page_content = f"--- Page {page_num + 1} ---\n{page_text}"
                
                # In extended mode with pre-processed data, we can't add image descriptions
                # since we don't have access to the raw PDF anymore
                if mode == "extended" and 'images' in pdf_data and page_num < len(pdf_data['images']):
                    if pdf_data['images'][page_num]:
                        page_content += "\n\n[Note: This page contains images that were extracted during initial processing]"
                
                for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                    yield chunk
            return
        
        # Handle bytes and file-like objects
        else:
            # Normal processing for bytes/streams
            if not HAS_FITZ:
                # Fallback to the old method if fitz is not available
                pdf_data = self.read(file_input, **kwargs)
                for page_num, page_text in enumerate(pdf_data['text_pages']):
                    if not page_text.strip():
                        continue
                    page_content = f"--- Page {page_num + 1} ---\n{page_text}"
                    for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                        yield chunk
                return
            
            # Use fitz for efficient streaming processing
            if isinstance(file_input, bytes):
                pdf_document = fitz.open(stream=file_input, filetype="pdf")
            else:
                # For file-like objects, we need to ensure it's seekable
                if hasattr(file_input, 'seek'):
                    file_input.seek(0)
                pdf_document = fitz.open(stream=file_input, filetype="pdf")
        
        try:
            if mode == "simple":
                # Simple mode: process pages one at a time for memory efficiency
                for page_num in range(pdf_document.page_count):
                    page = pdf_document.load_page(page_num)
                    page_text = page.get_text()
                    
                    if not page_text.strip():
                        continue
                        
                    # Add page marker
                    page_content = f"--- Page {page_num + 1} ---\n{page_text}"
                    
                    # Chunk the page content
                    for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                        yield chunk
        
            else:  # extended mode
                # Extended mode: analyze pages and detect images
                file_name = kwargs.get('file_name', 'document.pdf')
                
                # Process each page
                for page_num in range(pdf_document.page_count):
                    page = pdf_document.load_page(page_num)
                    page_content_parts = []
                    
                    # Start with page marker
                    page_content_parts.append(f"--- Page {page_num + 1} ---")
                    
                    # Add text content
                    text_content = page.get_text().strip()
                    if text_content:
                        page_content_parts.append(text_content)
                    
                    # Check for images on this page
                    images_on_page = []
                    page_images = page.get_images(full=True)
                    logger.debug(f"Page {page_num + 1}: Found {len(page_images)} image(s)")
                    
                    for img in page_images:
                        try:
                            xref = img[0]
                            base_image = pdf_document.extract_image(xref)
                            image_bytes = base_image["image"]
                            image = Image.open(io.BytesIO(image_bytes))
                            
                            # Check if image is larger than 150x150
                            width, height = image.size
                            logger.debug(f"  Image size: {width}x{height}")
                            if width > 150 and height > 150:
                                images_on_page.append(image)
                                logger.debug(f"  -> Added large image")
                        except Exception as e:
                            logger.warning(f"Error extracting image on page {page_num + 1}: {e}")
                    
                    # If we found significant images, describe them
                    if images_on_page:
                        try:
                            from percolate.services.llm.ImageInterpreter import get_image_interpreter
                            interpreter = get_image_interpreter()
                            
                            if interpreter.is_available():
                                page_content_parts.append("\n[IMAGES FOUND ON PAGE]")
                                
                                for img_idx, image in enumerate(images_on_page):
                                    prompt = """
                                    Describe this image from a PDF document. Focus on:
                                    1. What the image shows (diagrams, charts, photos, etc.)
                                    2. Any text visible in the image
                                    3. The key information or meaning conveyed
                                    4. How it relates to document content
                                    
                                    Be concise but comprehensive.
                                    """
                                    
                                    result = interpreter.describe_images(
                                        images=image,
                                        prompt=prompt,
                                        context=f"Image {img_idx + 1} from PDF page {page_num + 1}",
                                        max_tokens=500
                                    )
                                    
                                    if result["success"]:
                                        page_content_parts.append(f"\nImage {img_idx + 1}: {result['content']}")
                                    else:
                                        page_content_parts.append(f"\nImage {img_idx + 1}: [Failed to analyze]")
                            else:
                                page_content_parts.append("\n[Images detected but image interpreter not available]")
                        except Exception as e:
                            logger.error(f"Error analyzing images on page {page_num + 1}: {e}")
                            page_content_parts.append("\n[Images detected but analysis failed]")
                    
                    # Combine all parts for this page
                    page_content = "\n".join(page_content_parts)
                    
                    # Chunk the page content
                    for chunk in self._create_text_chunks(page_content, chunk_size, chunk_overlap):
                        yield chunk
        
        finally:
            # Always close the PDF document
            pdf_document.close()
    
    def _create_text_chunks(self, text: str, chunk_size: int, chunk_overlap: int) -> List[str]:
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
    
    def extract_extended_content(self, pdf_data: Dict[str, Any], file_name: str, uri: str = None) -> str:
        """
        Extract extended content from PDF using LLM vision analysis of page images.
        
        Args:
            pdf_data: Dictionary containing PDF data from read()
            file_name: Name of the PDF file
            uri: Optional URI for the PDF file
            
        Returns:
            Enhanced text with LLM analysis of page contents
        """
        try:
            # Get image interpreter service
            from percolate.services.llm.ImageInterpreter import get_image_interpreter
            interpreter = get_image_interpreter()
            
            if not interpreter.is_available():
                logger.warning("Image interpreter not available, falling back to simple PDF parsing")
                return self.extract_text(pdf_data)
            
            # Convert PDF pages to images for LLM analysis
            page_images = self.convert_pdf_to_images(pdf_data, uri)
            
            if not page_images:
                logger.warning("No page images generated, falling back to simple PDF parsing")
                return self.extract_text(pdf_data)
            
            logger.info(f"Analyzing {len(page_images)} PDF pages with LLM vision")
            
            # Analyze each page with LLM
            analyzed_pages = []
            for i, page_image in enumerate(page_images):
                try:
                    prompt = """
                    Extract the content from the pdf image. the pdf image may be text or tabular or visual images and diagrams.
                    if its mostly text just focus on the text meaning and ignore visual layout etc.
                    if its a a diagram focus on the meaning the diagram imports.
                    read it as a human would to take the meaning of the document
                    
                    Provide a comprehensive description that captures both the textual content and visual elements if images are used otherwise just focus on text content meaning.
                    """
                    
                    result = interpreter.describe_images(
                        images=page_image,
                        prompt=prompt,
                        context=f"PDF page {i+1} from document '{file_name}'",
                        max_tokens=2000
                    )
                    
                    if result["success"]:
                        page_content = f"=== PAGE {i+1} ===\n{result['content']}\n"
                        analyzed_pages.append(page_content)
                        logger.info(f"Successfully analyzed page {i+1}")
                    else:
                        logger.warning(f"Failed to analyze page {i+1}: {result.get('error', 'Unknown error')}")
                        # Fallback to simple text for this page
                        if i < len(pdf_data.get('text_pages', [])):
                            simple_text = pdf_data['text_pages'][i]
                            page_content = f"=== PAGE {i+1} (TEXT ONLY) ===\n{simple_text}\n"
                            analyzed_pages.append(page_content)
                
                except Exception as e:
                    logger.error(f"Error analyzing page {i+1}: {str(e)}")
                    # Fallback to simple text for this page
                    if i < len(pdf_data.get('text_pages', [])):
                        simple_text = pdf_data['text_pages'][i]
                        page_content = f"=== PAGE {i+1} (TEXT ONLY) ===\n{simple_text}\n"
                        analyzed_pages.append(page_content)
            
            # Combine all analyzed pages
            full_content = "\n".join(analyzed_pages)
            
            # Add summary information
            summary = f"""
DOCUMENT ANALYSIS SUMMARY:
- Document: {file_name}
- Total Pages: {len(page_images)}
- Analysis Method: LLM Vision + Text Extraction
- Pages Successfully Analyzed: {len([p for p in analyzed_pages if 'TEXT ONLY' not in p])}

FULL CONTENT:
{full_content}
"""
            
            logger.info(f"Extended PDF analysis complete: {len(full_content)} characters")
            return summary
            
        except Exception as e:
            logger.error(f"Error in extended PDF processing: {str(e)}")
            logger.info("Falling back to simple PDF parsing")
            return self.extract_text(pdf_data)


# Global PDF handler instance for easy access
_pdf_handler = None

def get_pdf_handler() -> PDFHandler:
    """Get a global PDF handler instance."""
    global _pdf_handler
    if _pdf_handler is None:
        _pdf_handler = PDFHandler()
    return _pdf_handler