"""
Utility functions for working with embeddings in Percolate.

This module provides standardized methods for generating and managing
text embeddings across different providers and models.
"""

import json
import typing
import requests
import uuid
import datetime
from loguru import logger
from percolate.utils import make_uuid

def get_embedding(text: str, model: str = "text-embedding-ada-002", api_key: str = None, 
                  scheme: str = "openai", api_base: str = None) -> typing.List[float]:
    """Get embedding for a single text string
    
    Args:
        text: Text to embed
        model: Name of the embedding model to use
        api_key: API key for the provider
        scheme: Provider scheme ('openai', 'anthropic', etc.)
        api_base: Optional API base URL override
        
    Returns:
        Embedding vector as list of floats
    """
    return get_embeddings([text], model, api_key, scheme, api_base)[0]

def get_embeddings(texts: typing.List[str], model: str = "text-embedding-ada-002", 
                   api_key: str = None, scheme: str = "openai", 
                   api_base: str = None) -> typing.List[typing.List[float]]:
    """Get embeddings for multiple texts in a single batch request
    
    This is much more efficient than calling get_embedding for each text.
    
    Args:
        texts: List of texts to embed
        model: Name of the embedding model to use
        api_key: API key for the provider
        scheme: Provider scheme ('openai', 'anthropic', etc.)
        api_base: Optional API base URL override
        
    Returns:
        List of embedding vectors
    """
    if not texts:
        return []
        
    # Prepare request based on provider scheme
    if scheme == "openai":
        url = api_base or "https://api.openai.com/v1/embeddings"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}"
        }
        data = {
            "model": model,
            "input": texts
        }
    elif scheme == "anthropic":
        # Placeholder for when Anthropic supports embeddings
        raise ValueError(f"Embedding not supported for {scheme}")
    else:
        raise ValueError(f"Embedding scheme {scheme} not supported")
    
    # Make request
    try:
        response = requests.post(url, headers=headers, data=json.dumps(data))
        
        if response.status_code != 200:
            logger.error(f"Embedding request failed with status {response.status_code}: {response.text}")
            raise Exception(f"Embedding request failed: {response.text}")
            
        # Parse response based on provider
        if scheme == "openai":
            embeddings = [item["embedding"] for item in response.json()["data"]]
        
        return embeddings
    except Exception as e:
        logger.error(f"Error generating embeddings: {e}")
        raise

def prepare_embedding_records(records: typing.List[dict], embedding_vectors: typing.List[typing.List[float]], 
                              field: str = "description", model: str = "default") -> typing.List[dict]:
    """Create database-ready embedding records from text records and their vectors
    
    Args:
        records: List of record dictionaries (must have 'id' field)
        embedding_vectors: Corresponding embedding vectors
        field: Name of the field that was embedded
        model: Identifier for the embedding model used
        
    Returns:
        List of embedding records ready for database insertion
    """
    from percolate.models.p8.embedding_types import EmbeddingRecord
    
    embedding_records = []
    
    for record, vector in zip(records, embedding_vectors):
        if "id" not in record:
            logger.warning(f"Record missing 'id' field, skipping")
            continue
            
        # Generate deterministic ID based on source record, field, and model
        embedding_id = make_uuid({"source": record["id"], "field": field, "model": model})
        
        # Create properly structured embedding record
        embedding_record = EmbeddingRecord(
            id=str(embedding_id),
            source_record_id=str(record["id"]),
            column_name=field,
            embedding=vector,
            embedding_name=model,
            created_at=datetime.datetime.now()
        )
        
        embedding_records.append(embedding_record)
        
    return embedding_records