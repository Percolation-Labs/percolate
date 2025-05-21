#!/usr/bin/env python3
"""Check for embedding columns in tables."""

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
    """Check for embedding columns."""
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Check Resources table columns
            print("Checking p8.Resources columns...")
            cur.execute("""
                SELECT column_name, data_type 
                FROM information_schema.columns 
                WHERE table_schema = 'p8' 
                AND table_name = 'Resources'
                AND (column_name LIKE '%embed%' OR data_type = 'vector')
                ORDER BY ordinal_position;
            """)
            
            rows = cur.fetchall()
            if rows:
                for row in rows:
                    print(f"  {row[0]}: {row[1]}")
            else:
                print("  No embedding columns found")
            
            # Check if there's any vector data type
            print("\nChecking for vector type columns in p8 schema...")
            cur.execute("""
                SELECT table_name, column_name, data_type 
                FROM information_schema.columns 
                WHERE table_schema = 'p8' 
                AND data_type = 'vector';
            """)
            
            rows = cur.fetchall()
            if rows:
                for row in rows:
                    print(f"  {row[0]}.{row[1]}: {row[2]}")
            else:
                print("  No vector columns found")

if __name__ == "__main__":
    main()