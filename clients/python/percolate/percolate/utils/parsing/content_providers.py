import requests
import tempfile
from pathlib import Path
from urllib.parse import urlparse
from abc import ABC, abstractmethod
from pathlib import Path
import fitz  # PyMuPDF
from percolate import logger

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
            return  "\n".join(page.get_text() for page in doc)
 

class DefaultContentProvider(BaseContentProvider):
    def extract_text(self, uri: str) -> str:
        path = resolve_path_or_download(uri)
        return path.read_text()

# Import DOCXContentProvider after base classes are defined to avoid circular import
from .docx_provider import DOCXContentProvider

content_providers = {
    ".pdf": PDFContentProvider(),
    ".docx": DOCXContentProvider(),
    ".doc": DOCXContentProvider(),  # Will handle old doc format too
}

default_provider = DefaultContentProvider()

def get_content_provider_for_uri(uri: str) -> BaseContentProvider:
    """todo make this way smarter by inspecting web uri metadata etc."""
    if 'arxiv.org/pdf' in uri:
        return content_providers['.pdf']
    
    suffix = Path(urlparse(uri).path).suffix.lower()
    return content_providers.get(suffix, default_provider)