#!/usr/bin/env python3
"""Test the corrected SQL functions."""

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

def execute_sql_file(filepath, description):
    """Execute SQL from a file."""
    print(f"\n{'='*60}")
    print(f"Executing: {description}")
    print(f"File: {filepath}")
    print('='*60)
    
    with open(filepath, 'r') as f:
        sql_content = f.read()
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                cur.execute(sql_content)
                conn.commit()
                print("✅ SQL executed successfully")
            except psycopg2.Error as e:
                print(f"❌ Error: {e}")
                conn.rollback()

def test_functions():
    """Test the SQL functions with sample queries."""
    print("\n" + "="*60)
    print("Testing SQL Functions")
    print("="*60)
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Test 1: Get resource metrics
            print("\n--- Test 1: Get all resource metrics ---")
            try:
                cur.execute("SELECT * FROM p8.get_resource_metrics(p_limit := 5);")
                rows = cur.fetchall()
                if rows:
                    for row in rows:
                        print(f"URI: {row[0]}, Chunks: {row[2]}, Size: {row[3]}")
                else:
                    print("No results")
            except psycopg2.Error as e:
                print(f"Error: {e}")
            
            # Test 2: Search file uploads
            print("\n--- Test 2: Search all file uploads ---")
            try:
                cur.execute("SELECT * FROM p8.file_upload_search(p_limit := 5);")
                rows = cur.fetchall()
                if rows:
                    for row in rows:
                        print(f"File: {row[1]}, Status: {row[5]}, Chunks: {row[14]}")
                else:
                    print("No results")
            except psycopg2.Error as e:
                print(f"Error: {e}")
            
            # Test 3: Semantic search (if embeddings exist)
            print("\n--- Test 3: Semantic search test ---")
            try:
                cur.execute("SELECT * FROM p8.get_resource_metrics(p_query_text := 'test', p_limit := 3);")
                rows = cur.fetchall()
                if rows:
                    for row in rows:
                        print(f"URI: {row[0]}, Score: {row[7]}, Chunks: {row[2]}")
                else:
                    print("No results")
            except psycopg2.Error as e:
                print(f"Error: {e}")

def main():
    """Main function."""
    base_dir = '/Users/sirsh/code/mr_saoirse/percolate'
    functions_dir = f'{base_dir}/extension/sql-staging/p8_pg_functions/search'
    
    # Deploy the corrected functions
    execute_sql_file(f'{functions_dir}/get_resource_metrics_v2.sql', 'Resource Metrics Function')
    execute_sql_file(f'{functions_dir}/file_upload_search_v2.sql', 'File Upload Search Function')
    
    # Test the functions
    test_functions()

if __name__ == "__main__":
    main()