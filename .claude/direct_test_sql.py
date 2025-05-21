#!/usr/bin/env python3
"""Test SQL function directly against the database."""

import psycopg2
import os
from contextlib import contextmanager

# Database connection parameters
DB_PARAMS = {
    'host': 'localhost',
    'port': 5438,  # Default PostgreSQL port for local dev
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
        raise
    finally:
        if conn:
            conn.close()

def test_sql_function():
    """Test the file_upload_search function directly."""
    
    user_id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Test 1: Simple query without parameters
            print("Test 1: No parameters")
            try:
                cur.execute("""
                    SELECT * FROM p8.file_upload_search(
                        p_user_id := %s,
                        p_query_text := NULL,
                        p_tags := NULL,
                        p_limit := 5
                    )
                """, [user_id])
                
                rows = cur.fetchall()
                print(f"Success: {len(rows)} rows returned")
                if rows:
                    columns = [desc[0] for desc in cur.description]
                    print(f"Columns: {columns}")
                    print(f"First row: {rows[0][:5]}...")
            except Exception as e:
                print(f"Error: {e}")
            
            # Test 2: With tags
            print("\n\nTest 2: With tags")
            try:
                cur.execute("""
                    SELECT * FROM p8.file_upload_search(
                        p_user_id := %s,
                        p_query_text := NULL,
                        p_tags := %s,
                        p_limit := 5
                    )
                """, [user_id, ['test', 'document']])
                
                rows = cur.fetchall()
                print(f"Success: {len(rows)} rows returned")
            except Exception as e:
                print(f"Error: {e}")
            
            # Test 3: With semantic search
            print("\n\nTest 3: With semantic search")
            try:
                cur.execute("""
                    SELECT * FROM p8.file_upload_search(
                        p_user_id := %s,
                        p_query_text := %s,
                        p_tags := NULL,
                        p_limit := 5
                    )
                """, [user_id, 'test document'])
                
                rows = cur.fetchall()
                print(f"Success: {len(rows)} rows returned")
            except Exception as e:
                print(f"Error: {e}")

            # Check if function exists
            print("\n\nChecking if function exists...")
            try:
                cur.execute("""
                    SELECT proname, proargtypes, prosrc
                    FROM pg_proc
                    WHERE proname = 'file_upload_search'
                    AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'p8')
                """)
                
                result = cur.fetchone()
                if result:
                    print(f"Function exists: {result[0]}")
                else:
                    print("Function NOT found!")
            except Exception as e:
                print(f"Error: {e}")

if __name__ == "__main__":
    test_sql_function()