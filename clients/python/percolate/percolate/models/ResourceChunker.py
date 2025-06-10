"""
DEPRECATED: ResourceChunker has moved to percolate.utils.parsing.ResourceChunker
Import from there instead.
"""

# This file is deprecated - import from percolate.utils.parsing.ResourceChunker instead
from percolate.utils.parsing.ResourceChunker import (
    ResourceChunker, 
    get_resource_chunker, 
    create_resource_chunker,
    extract_pdf_content,
    ResourceHandler,
    PDFResourceHandler,
    TextResourceHandler,
    CSVResourceHandler,
    ExcelResourceHandler,
    DocxResourceHandler,
    PPTXResourceHandler,
    ImageResourceHandler
)

# Keep only the imports - the actual implementation has moved