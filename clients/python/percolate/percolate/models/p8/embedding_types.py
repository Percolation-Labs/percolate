"""
Embedding data models and types for Percolate.

This module defines the standardized models for storing and managing
embeddings across different database backends.
"""

from pydantic import BaseModel, Field
import typing
import uuid
import datetime


class EmbeddingRecord(BaseModel):
    """Embedding record model for storing vectors in the database."""
    
    model_config = {
        'namespace': 'common',
        'table_name': 'embeddingrecord'
    }
    
    id: str = Field(description="Unique identifier for the embedding")
    source_record_id: str = Field(description="ID of the source record this embedding represents")
    column_name: str = Field(description="Name of the field/column being embedded")
    embedding: typing.List[float] = Field(description="Embedding vector values")
    embedding_name: str = Field(description="Name/identifier of the embedding model used")
    created_at: datetime.datetime = Field(
        default_factory=datetime.datetime.now,
        description="Timestamp when the embedding was created"
    )