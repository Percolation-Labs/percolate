"""
Content providers for extracting text from various file formats.
"""
import tempfile
from pathlib import Path
from abc import ABC, abstractmethod
from urllib.parse import urlparse
import requests
import fitz  # PyMuPDF
from percolate import logger

# Try importing docx libraries
try:
    from docx import Document
    has_docx = True
except ImportError:
    has_docx = False
    logger.warning("python-docx not installed, DOCX support limited")

try:
    import mammoth
    has_mammoth = True
except ImportError:
    has_mammoth = False
    logger.warning("mammoth not installed, DOCX support limited")

try:
    import html2text
    has_html2text = True
except ImportError:
    has_html2text = False
    logger.warning("html2text not installed, DOCX HTML conversion not available")


def is_url(uri: str) -> bool:
    parsed = urlparse(uri)
    return parsed.scheme in ("http", "https")


def resolve_path_or_download(uri: str) -> Path:
    if Path(uri).exists():
        return Path(uri)

    if is_url(uri):
        response = requests.get(uri)
        response.raise_for_status()
        suffix = Path(urlparse(uri).path).suffix
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
        tmp.write(response.content)
        tmp.close()
        return Path(tmp.name)

    raise FileNotFoundError(f"Cannot resolve URI: {uri}")


class BaseContentProvider(ABC):
    @abstractmethod
    def extract_text(self, uri: str) -> str:
        ...


class PDFContentProvider(BaseContentProvider):
    def extract_text(self, uri: str) -> str:
        path = resolve_path_or_download(uri)
        with fitz.open(str(path)) as doc:
            return "\n".join(page.get_text() for page in doc)


class DefaultContentProvider(BaseContentProvider):
    def extract_text(self, uri: str) -> str:
        path = resolve_path_or_download(uri)
        return path.read_text()


class DOCXContentProvider(BaseContentProvider):
    """Content provider for Microsoft Word documents."""
    
    def extract_text(self, uri: str) -> str:
        """Extract text from a DOCX file."""
        path = resolve_path_or_download(uri)
        
        # If no libraries available, fall back to basic text extraction
        if not has_docx and not has_mammoth:
            logger.warning("No DOCX libraries available, falling back to simple text extraction")
            return path.read_text(errors='ignore')
        
        try:
            # First try with python-docx for simple text extraction
            if has_docx:
                doc = Document(str(path))
                paragraphs = []
                for paragraph in doc.paragraphs:
                    if paragraph.text.strip():
                        paragraphs.append(paragraph.text)
                
                # If we got text, return it
                if paragraphs:
                    return '\n\n'.join(paragraphs)
            
            # Fallback to mammoth for more complex documents
            if has_mammoth:
                logger.info("Using mammoth for DOCX extraction")
                with open(str(path), "rb") as docx_file:
                    result = mammoth.convert_to_markdown(docx_file)
                    
                    if result.messages:
                        for message in result.messages:
                            logger.warning(f"DOCX conversion warning: {message}")
                    
                    return result.value
                    
        except Exception as e:
            logger.error(f"Error extracting text from DOCX: {e}")
            # Final fallback - try mammoth HTML conversion if available
            if has_mammoth and has_html2text:
                try:
                    with open(str(path), "rb") as docx_file:
                        result = mammoth.convert_to_html(docx_file)
                        h = html2text.HTML2Text()
                        h.ignore_links = False
                        return h.handle(result.value)
                except Exception as e2:
                    logger.error(f"Failed all DOCX extraction methods: {e2}")
            
            # Ultimate fallback
            return path.read_text(errors='ignore')


content_providers = {
    ".pdf": PDFContentProvider(),
    ".docx": DOCXContentProvider(),
    ".doc": DOCXContentProvider(),  # Will handle old doc format too
    ".txt": DefaultContentProvider(),
}

default_provider = DefaultContentProvider()


def get_content_provider_for_uri(uri: str) -> BaseContentProvider:
    """Get the appropriate content provider for a given URI."""
    suffix = Path(urlparse(uri).path).suffix.lower()
    return content_providers.get(suffix, default_provider)