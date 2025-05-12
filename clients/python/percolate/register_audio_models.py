#!/usr/bin/env python3
"""
Script to register audio models with the database using a direct connection string.
This bypasses any global or environment default settings.
"""

import os
import psycopg2
import logging
import uuid
from typing import Dict, Any, List, Optional
from pathlib import Path

# Configure logging
logging.basicConfig(level=logging.INFO, 
                   format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("register_audio")

def register_models(connection_string: str) -> Dict[str, str]:
    """
    Register audio models directly using the provided connection string.
    
    Args:
        connection_string: PostgreSQL connection string
        
    Returns:
        Dict mapping model names to registration results
    """
    from percolate.models.media.audio import (
        AudioFile,
        AudioChunk,
        AudioPipeline,
        AudioResource
    )
    
    models = [
        AudioFile,
        AudioChunk,
        AudioPipeline,
        AudioResource
    ]
    
    results = {}
    conn = None
    
    try:
        logger.info(f"Connecting to database...")
        conn = psycopg2.connect(connection_string)
        
        for model in models:
            model_name = model.__name__
            logger.info(f"Registering model: {model_name}")
            
            try:
                # Generate registration SQL
                create_table_sql = generate_create_table_sql(model)
                
                # Execute the SQL
                with conn.cursor() as cursor:
                    cursor.execute(create_table_sql)
                
                results[model_name] = "Registered successfully"
                logger.info(f"Successfully registered {model_name}")
            except Exception as e:
                error_msg = f"Failed: {str(e)}"
                results[model_name] = error_msg
                logger.error(f"Error registering {model_name}: {error_msg}")
        
        # Commit the changes
        conn.commit()
        
    except Exception as e:
        logger.error(f"Database error: {str(e)}")
        if conn:
            conn.rollback()
    finally:
        if conn:
            conn.close()
    
    return results

def generate_create_table_sql(model: Any) -> str:
    """
    Generate SQL to create a table for the model.
    
    Args:
        model: Pydantic model class
        
    Returns:
        SQL string for creating the table
    """
    from percolate.models.media.audio import AudioFile, AudioChunk, AudioPipeline, AudioResource
    
    # Get model information
    model_name = model.get_model_name()
    namespace = model.get_model_namespace()
    table_name = f'{namespace}."{model_name}"'
    
    # Start building the SQL
    sql_parts = [
        f"DROP TABLE IF EXISTS {table_name} CASCADE;",
        f"CREATE TABLE IF NOT EXISTS {table_name} ("
    ]
    
    # Add columns based on model fields
    columns = []
    for field_name, field in model.model_fields.items():
        field_type = field.annotation
        db_type = map_type_to_db(field_type)
        
        # Handle nullable fields
        nullable = "NULL" if field.is_optional() else "NOT NULL"
        
        # Special handling for the ID field
        if field_name == "id":
            columns.append(f"  {field_name} UUID PRIMARY KEY DEFAULT gen_random_uuid()")
        else:
            columns.append(f"  {field_name} {db_type} {nullable}")
    
    # Join columns and close statement
    sql_parts.append(", ".join(columns))
    sql_parts.append(");")
    
    # Create embedding triggers if needed
    if model == AudioChunk:
        # Add embedding triggers for the transcription field
        embedding_schema = "p8_embeddings"
        embedding_table = f'{embedding_schema}."{namespace}_{model_name}_embeddings"'
        
        sql_parts.extend([
            f"DROP TABLE IF EXISTS {embedding_table} CASCADE;",
            f"CREATE TABLE IF NOT EXISTS {embedding_table} (",
            f"  id UUID PRIMARY KEY REFERENCES {table_name}(id) ON DELETE CASCADE,",
            f"  embedding VECTOR(1536)",
            f");"
        ])
    
    return "\n".join(sql_parts)

def map_type_to_db(field_type: Any) -> str:
    """Map Python/Pydantic types to PostgreSQL types."""
    import inspect
    import datetime
    import uuid
    
    # Handle Optional types
    origin = getattr(field_type, "__origin__", None)
    if origin is not None:
        # Handle Optional[X]
        if origin is typing.Union:
            args = getattr(field_type, "__args__", [])
            if type(None) in args:  # This is Optional[X]
                # Extract the actual type (the non-None one)
                actual_type = next(arg for arg in args if arg is not type(None))
                return map_type_to_db(actual_type)
        
        # Handle List, Dict, etc.
        if origin is list or origin == typing.List:
            return "JSONB"
        if origin is dict or origin == typing.Dict:
            return "JSONB"
    
    # Basic types
    if field_type is str or field_type == str:
        return "TEXT"
    elif field_type is int or field_type == int:
        return "INTEGER"
    elif field_type is float or field_type == float:
        return "FLOAT"
    elif field_type is bool or field_type == bool:
        return "BOOLEAN"
    elif field_type is datetime.datetime or field_type == datetime.datetime:
        return "TIMESTAMP WITH TIME ZONE"
    elif field_type is uuid.UUID or field_type == uuid.UUID:
        return "UUID"
    
    # Default to JSONB for complex types
    return "JSONB"

if __name__ == "__main__":
    # Get the bearer token
    bearer_token = os.environ.get('P8_TEST_BEARER_TOKEN')
    if not bearer_token:
        logger.error("P8_TEST_BEARER_TOKEN environment variable not set")
        exit(1)
    
    # Build connection string
    connection_string = f"postgresql://postgres:{bearer_token}@localhost:15432/app"
    
    # Register models
    results = register_models(connection_string)
    
    # Print results
    print("\nRegistration Results:")
    for model, result in results.items():
        print(f"- {model}: {result}")