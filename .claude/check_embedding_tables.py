#!/usr/bin/env python3
"""Check for embedding tables in p8_embeddings schema."""

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
    """Check for embedding tables."""
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            # Check if p8_embeddings schema exists
            print("Checking for p8_embeddings schema...")
            cur.execute("""
                SELECT schema_name 
                FROM information_schema.schemata 
                WHERE schema_name = 'p8_embeddings';
            """)
            
            if not cur.fetchone():
                print("  p8_embeddings schema not found!")
                return
            
            print("  p8_embeddings schema exists")
            
            # List tables in p8_embeddings
            print("\nTables in p8_embeddings schema:")
            cur.execute("""
                SELECT table_name 
                FROM information_schema.tables 
                WHERE table_schema = 'p8_embeddings'
                ORDER BY table_name;
            """)
            
            rows = cur.fetchall()
            if rows:
                for row in rows:
                    print(f"  {row[0]}")
            else:
                print("  No tables found")
            
            # Check structure of any embedding tables
            print("\nLooking for Resources embedding table...")
            cur.execute("""
                SELECT table_name 
                FROM information_schema.tables 
                WHERE table_schema = 'p8_embeddings'
                AND table_name LIKE '%resources%'
                ORDER BY table_name;
            """)
            
            rows = cur.fetchall()
            if rows:
                # Check column structure of first found table
                table_name = rows[0][0]
                print(f"\nColumns in p8_embeddings.{table_name}:")
                cur.execute(f"""
                    SELECT column_name, data_type 
                    FROM information_schema.columns 
                    WHERE table_schema = 'p8_embeddings' 
                    AND table_name = %s
                    ORDER BY ordinal_position;
                """, (table_name,))
                
                for col in cur.fetchall():
                    print(f"  {col[0]}: {col[1]}")
            else:
                print("  No Resources-related embedding table found")

if __name__ == "__main__":
    main()