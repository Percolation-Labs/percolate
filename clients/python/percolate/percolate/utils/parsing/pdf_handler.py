"""
PDF Handler module for extracting content from PDF files.

This module provides a unified interface for working with PDF files,
supporting text extraction, image extraction, and LLM-enhanced analysis.
"""

import io
import os
import tempfile
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
        
        # Ensure we have a file-like object
        if isinstance(file_stream, bytes):
            pdf_stream = io.BytesIO(file_stream)
        else:
            pdf_stream = file_stream
            
        # Initialize result structure
        result = {
            'text_pages': [],
            'images': [],
            'image_info': [],
            'num_pages': 0,
            'metadata': {}
        }
        
        # Extract text using pypdf if available
        if HAS_PYPDF:
            try:
                # If file stream doesn't have proper methods, wrap it
                if not hasattr(pdf_stream, 'seek'):
                    pdf_stream = io.BytesIO(pdf_stream.read())
                
                pdf_stream.seek(0)  # Ensure we're at the beginning
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
            except Exception as e:
                logger.error(f"Error extracting text with pypdf: {str(e)}")
                # We'll continue with fitz if available
        
        # Extract images using PyMuPDF if available
        if HAS_FITZ:
            try:
                # Reset stream position
                pdf_stream.seek(0)
                
                with fitz.open(stream=pdf_stream, filetype="pdf") as pdf_document:
                    # If we didn't get text with pypdf, extract it with fitz
                    if not result['text_pages'] and result['num_pages'] == 0:
                        for page_num in range(pdf_document.page_count):
                            page = pdf_document.load_page(page_num)
                            text = page.get_text()
                            result['text_pages'].append(text)
                        result['num_pages'] = pdf_document.page_count
                    
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
                logger.error(f"Error extracting images with fitz: {str(e)}")
        
        # Ensure num_pages is accurate
        if result['num_pages'] == 0 and result['text_pages']:
            result['num_pages'] = len(result['text_pages'])
        
        # Include raw bytes for further processing if needed
        if isinstance(file_stream, io.BytesIO):
            file_stream.seek(0)
            result['raw_bytes'] = file_stream.read()
        
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