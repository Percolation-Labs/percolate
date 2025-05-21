#!/usr/bin/env python3
"""Check the relationships between Resources and TusFileUpload tables."""

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
    """Check relationships between tables."""
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Check if there's an embedding_id link
            print("Checking for common IDs between tables...")
            
            # Check TusFileUpload
            cur.execute("""
                SELECT 
                    COUNT(*) as total_uploads,
                    COUNT(resource_id) as uploads_with_resource_id,
                    COUNT(embedding_id) as uploads_with_embedding_id
                FROM public."TusFileUpload";
            """)
            row = cur.fetchone()
            print(f"\nTusFileUpload stats:")
            print(f"  Total uploads: {row[0]}")
            print(f"  With resource_id: {row[1]}")
            print(f"  With embedding_id: {row[2]}")
            
            # Check Resources
            cur.execute("""
                SELECT 
                    COUNT(*) as total_resources,
                    COUNT(DISTINCT uri) as unique_uris,
                    COUNT(DISTINCT userid) as unique_users
                FROM p8."Resources";
            """)
            row = cur.fetchone()
            print(f"\nResources stats:")
            print(f"  Total resources: {row[0]}")
            print(f"  Unique URIs: {row[1]}")
            print(f"  Unique users: {row[2]}")
            
            # Look for common patterns
            print("\nChecking if S3 URIs match...")
            cur.execute("""
                SELECT COUNT(*)
                FROM public."TusFileUpload" t
                JOIN p8."Resources" r ON r.uri = t.s3_uri
                WHERE t.s3_uri IS NOT NULL AND r.uri IS NOT NULL;
            """)
            count = cur.fetchone()[0]
            print(f"  Resources matching s3_uri: {count}")
            
            # Check specific examples
            print("\nSample uploads with resource_id:")
            cur.execute("""
                SELECT id, filename, resource_id, s3_uri
                FROM public."TusFileUpload"
                WHERE resource_id IS NOT NULL
                LIMIT 5;
            """)
            for row in cur.fetchall():
                print(f"  ID: {row[0]}, File: {row[1]}, Resource ID: {row[2]}, S3 URI: {row[3]}")
            
            # Check for matching URIs
            print("\nSample Resources that might match uploads:")
            cur.execute("""
                SELECT DISTINCT r.uri, r.name, t.filename
                FROM p8."Resources" r
                JOIN public."TusFileUpload" t ON r.uri = t.s3_uri
                WHERE t.s3_uri IS NOT NULL
                LIMIT 5;
            """)
            for row in cur.fetchall():
                print(f"  URI: {row[0]}, Name: {row[1]}, Upload: {row[2]}")

if __name__ == "__main__":
    main()