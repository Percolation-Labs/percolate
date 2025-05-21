#!/usr/bin/env python3
"""Test all parameter permutations for the resource search functions."""

import psycopg2
import sys
from contextlib import contextmanager

# Database connection parameters for port 5438
DB_PARAMS = {
    'host': 'localhost',
    'port': 5438,
    'database': 'app',
    'user': 'postgres',
    'password': 'postgres'
}

@contextmanager
def get_connection():
    """Get a database connection with automatic cleanup."""
    conn = None
    try:
        conn = psycopg2.connect(**DB_PARAMS)
        yield conn
    except psycopg2.Error as e:
        print(f"Database error: {e}")
        sys.exit(1)
    finally:
        if conn:
            conn.close()

def execute_sql_file(filepath):
    """Execute SQL from a file."""
    print(f"\nDeploying functions from: {filepath}")
    
    with open(filepath, 'r') as f:
        sql_content = f.read()
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(sql_content)
                conn.commit()
                print("✅ Functions deployed successfully")
            except psycopg2.Error as e:
                print(f"❌ Error deploying functions: {e}")
                conn.rollback()
                return False
    return True

def test_function(test_name, query, expected_columns=None):
    """Test a function with a specific query."""
    print(f"\n--- {test_name} ---")
    print(f"Query: {query[:100]}...")
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(query)
                rows = cur.fetchall()
                
                if expected_columns:
                    columns = [desc[0] for desc in cur.description]
                    print(f"Columns: {columns}")
                    if columns != expected_columns:
                        print(f"❌ Column mismatch! Expected: {expected_columns}")
                        return False
                
                print(f"✅ Success - returned {len(rows)} rows")
                if rows:
                    print(f"Sample row: {rows[0][:5]}...")  # Show first 5 columns
                return True
                
            except psycopg2.Error as e:
                print(f"❌ Error: {e}")
                return False

def test_all_permutations():
    """Test all parameter permutations for both functions."""
    
    # Deploy the functions first
    filepath = '/Users/sirsh/code/mr_saoirse/percolate/extension/sql-staging/p8_pg_functions/search/resource_search_functions.sql'
    if not execute_sql_file(filepath):
        print("Failed to deploy functions")
        return
    
    print("\n" + "="*60)
    print("Testing get_resource_metrics function")
    print("="*60)
    
    # Expected columns for get_resource_metrics
    metrics_columns = ['uri', 'resource_name', 'chunk_count', 'total_chunk_size', 
                      'avg_chunk_size', 'max_date', 'categories', 'semantic_score', 'user_id']
    
    # Test all permutations of get_resource_metrics
    test_function("All defaults", 
                 "SELECT * FROM p8.get_resource_metrics()",
                 metrics_columns)
    
    test_function("With user_id only", 
                 "SELECT * FROM p8.get_resource_metrics(p_user_id := '123e4567-e89b-12d3-a456-426614174000')",
                 metrics_columns)
    
    test_function("With limit only", 
                 "SELECT * FROM p8.get_resource_metrics(p_limit := 5)",
                 metrics_columns)
    
    test_function("With user_id and limit", 
                 "SELECT * FROM p8.get_resource_metrics(p_user_id := '123e4567-e89b-12d3-a456-426614174000', p_limit := 5)",
                 metrics_columns)
    
    # Semantic search tests (will fail if no embeddings, but should handle gracefully)
    test_function("With query_text only", 
                 "SELECT * FROM p8.get_resource_metrics(p_query_text := 'test document')",
                 metrics_columns)
    
    test_function("With all parameters", 
                 "SELECT * FROM p8.get_resource_metrics(p_user_id := '123e4567-e89b-12d3-a456-426614174000', p_query_text := 'test document', p_limit := 3)",
                 metrics_columns)
    
    print("\n" + "="*60)
    print("Testing file_upload_search function")
    print("="*60)
    
    # Expected columns for file_upload_search
    upload_columns = ['upload_id', 'filename', 'content_type', 'total_size', 'uploaded_size',
                     'status', 'created_at', 'updated_at', 's3_uri', 'tags', 'resource_id',
                     'resource_uri', 'resource_name', 'chunk_count', 'resource_size', 
                     'indexed_at', 'semantic_score']
    
    # Test all permutations of file_upload_search
    test_function("All defaults", 
                 "SELECT * FROM p8.file_upload_search()",
                 upload_columns)
    
    test_function("With user_id only", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := '123e4567-e89b-12d3-a456-426614174000')",
                 upload_columns)
    
    test_function("With tags only", 
                 "SELECT * FROM p8.file_upload_search(p_tags := ARRAY['test', 'document'])",
                 upload_columns)
    
    test_function("With limit only", 
                 "SELECT * FROM p8.file_upload_search(p_limit := 5)",
                 upload_columns)
    
    test_function("With user_id and tags", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := '123e4567-e89b-12d3-a456-426614174000', p_tags := ARRAY['test'])",
                 upload_columns)
    
    test_function("With tags and limit", 
                 "SELECT * FROM p8.file_upload_search(p_tags := ARRAY['test'], p_limit := 3)",
                 upload_columns)
    
    # Semantic search tests
    test_function("With query_text only", 
                 "SELECT * FROM p8.file_upload_search(p_query_text := 'important document')",
                 upload_columns)
    
    test_function("With query_text and user_id", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := '123e4567-e89b-12d3-a456-426614174000', p_query_text := 'test')",
                 upload_columns)
    
    test_function("With query_text and tags", 
                 "SELECT * FROM p8.file_upload_search(p_query_text := 'test', p_tags := ARRAY['document'])",
                 upload_columns)
    
    test_function("With all parameters", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := '123e4567-e89b-12d3-a456-426614174000', p_query_text := 'test', p_tags := ARRAY['doc'], p_limit := 2)",
                 upload_columns)
    
    # Edge cases
    print("\n" + "="*60)
    print("Testing edge cases")
    print("="*60)
    
    test_function("Empty array for tags", 
                 "SELECT * FROM p8.file_upload_search(p_tags := ARRAY[]::TEXT[])")
    
    test_function("NULL parameters explicitly", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := NULL, p_query_text := NULL, p_tags := NULL)")
    
    test_function("Very large limit", 
                 "SELECT * FROM p8.file_upload_search(p_limit := 10000)")
    
    test_function("Non-existent user", 
                 "SELECT * FROM p8.file_upload_search(p_user_id := 'non-existent-user-id')")

if __name__ == "__main__":
    test_all_permutations()