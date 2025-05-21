#!/usr/bin/env python3
"""Test functions against staging database with real embeddings."""

import psycopg2
import os
import sys
from contextlib import contextmanager

# Database connection parameters for port 15432 staging database
DB_PARAMS = {
    'host': 'localhost',
    'port': 15432,  # Staging database port
    'database': 'app',
    'user': 'postgres',
    'password': os.environ.get('P8_TEST_BEARER_TOKEN')  # Get password from env
}

@contextmanager
def get_connection():
    """Get a database connection with automatic cleanup."""
    conn = None
    try:
        if not DB_PARAMS['password']:
            print("Error: P8_TEST_BEARER_TOKEN environment variable not set")
            sys.exit(1)
        conn = psycopg2.connect(**DB_PARAMS)
        yield conn
    except psycopg2.Error as e:
        print(f"Database error: {e}")
        sys.exit(1)
    finally:
        if conn:
            conn.close()

def check_staging_data():
    """Check what data exists in staging database."""
    print("Checking staging database data...")
    print("="*60)
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Check for resources with embeddings
            print("\n--- Resources with embeddings ---")
            cur.execute("""
                SELECT COUNT(DISTINCT r.id) as resources_with_embeddings,
                       COUNT(DISTINCT r.uri) as unique_uris,
                       COUNT(DISTINCT r.userid) as unique_users
                FROM p8."Resources" r
                JOIN p8_embeddings."p8_Resources_embeddings" e ON e.source_record_id = r.id;
            """)
            row = cur.fetchone()
            print(f"Resources with embeddings: {row[0]}")
            print(f"Unique URIs: {row[1]}")
            print(f"Unique users: {row[2]}")
            
            # Get sample user IDs for testing
            print("\n--- Sample user IDs ---")
            cur.execute("""
                SELECT DISTINCT userid, COUNT(*) as resource_count
                FROM p8."Resources"
                GROUP BY userid
                ORDER BY resource_count DESC
                LIMIT 5;
            """)
            user_ids = []
            for row in cur.fetchall():
                user_ids.append(str(row[0]))
                print(f"User ID: {row[0]}, Resources: {row[1]}")
            
            # Get sample tags for testing
            print("\n--- Sample tags ---")
            cur.execute("""
                SELECT DISTINCT unnest(tags) as tag, COUNT(*) as count
                FROM public."TusFileUpload"
                WHERE tags IS NOT NULL AND array_length(tags, 1) > 0
                GROUP BY tag
                ORDER BY count DESC
                LIMIT 5;
            """)
            tags = []
            for row in cur.fetchall():
                tags.append(row[0])
                print(f"Tag: {row[0]}, Count: {row[1]}")
            
            # Get sample resource text for semantic queries
            print("\n--- Sample resource content ---")
            cur.execute("""
                SELECT DISTINCT substring(content, 1, 100) as sample_content
                FROM p8."Resources"
                WHERE content IS NOT NULL AND length(content) > 50
                LIMIT 5;
            """)
            sample_texts = []
            for row in cur.fetchall():
                sample_texts.append(row[0][:50])
                print(f"Content: {row[0][:50]}...")
                
            return user_ids, tags, sample_texts

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

def test_function(test_name, query):
    """Test a function with a specific query."""
    print(f"\n--- {test_name} ---")
    print(f"Query: {query[:100]}...")
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(query)
                rows = cur.fetchall()
                print(f"✅ Success - returned {len(rows)} rows")
                
                if rows:
                    # Show first result
                    columns = [desc[0] for desc in cur.description]
                    print("\nFirst result:")
                    for i, col in enumerate(columns[:8]):  # Show first 8 columns
                        print(f"  {col}: {rows[0][i]}")
                    
                    # If semantic score exists, show it
                    if 'semantic_score' in columns:
                        score_idx = columns.index('semantic_score')
                        if rows[0][score_idx] is not None:
                            print(f"  semantic_score: {rows[0][score_idx]}")
                
                return True
                
            except psycopg2.Error as e:
                print(f"❌ Error: {e}")
                return False

def test_with_real_data():
    """Test functions with real data from staging database."""
    
    # Deploy the functions
    filepath = '/Users/sirsh/code/mr_saoirse/percolate/extension/sql-staging/p8_pg_functions/search/resource_search_functions.sql'
    if not execute_sql_file(filepath):
        print("Failed to deploy functions")
        return
    
    # Get real data for testing
    user_ids, tags, sample_texts = check_staging_data()
    
    if not user_ids:
        print("No users found in staging database")
        return
    
    print("\n" + "="*60)
    print("Testing get_resource_metrics with real data")
    print("="*60)
    
    # Test with real user ID
    test_user_id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'
    test_function("With real user_id", 
                 f"SELECT * FROM p8.get_resource_metrics(p_user_id := '{test_user_id}', p_limit := 5)")
    
    # Test semantic search with real content
    if sample_texts:
        test_function("Semantic search with real content", 
                     f"SELECT * FROM p8.get_resource_metrics(p_query_text := '{sample_texts[0][:30]}', p_limit := 5)")
    
    # Test semantic search with generic query
    test_function("Semantic search - generic query", 
                 "SELECT * FROM p8.get_resource_metrics(p_query_text := 'test', p_limit := 5)")
    
    print("\n" + "="*60)
    print("Testing file_upload_search with real data")
    print("="*60)
    
    # Test with real user ID
    test_user_id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'
    test_function("With real user_id", 
                 f"SELECT * FROM p8.file_upload_search(p_user_id := '{test_user_id}', p_limit := 5)")
    
    # Test with real tags
    if tags:
        test_function("With real tags", 
                     f"SELECT * FROM p8.file_upload_search(p_tags := ARRAY['{tags[0]}'], p_limit := 5)")
    
    # Test semantic search
    test_function("Semantic search - test query", 
                 "SELECT * FROM p8.file_upload_search(p_query_text := 'test document', p_limit := 5)")
    
    # Test semantic search with user filter
    test_user_id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'
    test_function("Semantic search with user filter", 
                 f"SELECT * FROM p8.file_upload_search(p_user_id := '{test_user_id}', p_query_text := 'data', p_limit := 5)")
    
    # Test complex query
    test_user_id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'
    if tags:
        test_function("Complex query - all parameters", 
                     f"SELECT * FROM p8.file_upload_search(p_user_id := '{test_user_id}', p_query_text := 'test', p_tags := ARRAY['{tags[0]}'], p_limit := 3)")

if __name__ == "__main__":
    print(f"Testing against staging database on port 15432")
    print(f"Password from P8_TEST_BEARER_TOKEN: {'Set' if os.environ.get('P8_TEST_BEARER_TOKEN') else 'Not set'}")
    test_with_real_data()