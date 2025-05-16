"""
DOCX content provider for extracting text from Word documents.
"""
import tempfile
from pathlib import Path
from percolate.utils import logger
from abc import ABC, abstractmethod
import requests
from urllib.parse import urlparse
from docx import Document
import mammoth
import html2text


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


class DOCXContentProvider(BaseContentProvider):
    """Content provider for Microsoft Word documents."""
    
    def extract_text(self, uri: str) -> str:
        """Extract text from a DOCX file."""
        path = resolve_path_or_download(uri)
        
        try:
            # First try with python-docx for simple text extraction
            doc = Document(str(path))
            paragraphs = []
            for paragraph in doc.paragraphs:
                if paragraph.text.strip():
                    paragraphs.append(paragraph.text)
            
            # If we got text, return it
            if paragraphs:
                return '\n\n'.join(paragraphs)
            
            # Fallback to mammoth for more complex documents
            logger.info("Falling back to mammoth for DOCX extraction")
            with open(str(path), "rb") as docx_file:
                result = mammoth.convert_to_markdown(docx_file)
                
                if result.messages:
                    for message in result.messages:
                        logger.warning(f"DOCX conversion warning: {message}")
                
                return result.value
                
        except Exception as e:
            logger.error(f"Error extracting text from DOCX: {e}")
            # Final fallback - try mammoth HTML conversion
            try:
                with open(str(path), "rb") as docx_file:
                    result = mammoth.convert_to_html(docx_file)
                    h = html2text.HTML2Text()
                    h.ignore_links = False
                    return h.handle(result.value)
            except Exception as e2:
                logger.error(f"Failed all DOCX extraction methods: {e2}")
                raise