"""
Embedded Percolate implementation.

This package provides embedded alternatives to PostgreSQL and graph database features
using DuckDB (SQL + vector search) and KuzuDB (graph database) for local, file-based storage.
"""

from .DuckDBService import DuckDBService
from .KuzuDBService import KuzuDBService
from .IcebergModelCatalog import IcebergModelCatalog
from .utils import AsyncIndexBuilder, EmbeddingManager, IndexAudit
