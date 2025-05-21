#!/usr/bin/env python3
"""Check the p8_Resources_embeddings table structure."""

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

def main():
    """Check Resources embedding table structure."""
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Check column structure
            print("Columns in p8_embeddings.p8_Resources_embeddings:")
            cur.execute("""
                SELECT column_name, data_type 
                FROM information_schema.columns 
                WHERE table_schema = 'p8_embeddings' 
                AND table_name = 'p8_Resources_embeddings'
                ORDER BY ordinal_position;
            """)
            
            for col in cur.fetchall():
                print(f"  {col[0]}: {col[1]}")
            
            # Check sample data
            print("\nSample data from p8_Resources_embeddings:")
            cur.execute("""
                SELECT source_record_id, column_name, embedding_name,
                       octet_length(embedding_vector::text) as embedding_size
                FROM p8_embeddings."p8_Resources_embeddings"
                LIMIT 5;
            """)
            
            rows = cur.fetchall()
            if rows:
                for row in rows:
                    print(f"  ID: {row[0]}, Column: {row[1]}, Name: {row[2]}, Embedding size: {row[3]}")
            else:
                print("  No data found")
            
            # Check if embeddings exist for any resources
            print("\nChecking Resources with embeddings:")
            cur.execute("""
                SELECT COUNT(DISTINCT r.id) as resources_with_embeddings
                FROM p8."Resources" r
                JOIN p8_embeddings."p8_Resources_embeddings" e 
                ON e.source_record_id = r.id;
            """)
            
            count = cur.fetchone()[0]
            print(f"  Resources with embeddings: {count}")

if __name__ == "__main__":
    main()