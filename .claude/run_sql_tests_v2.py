#!/usr/bin/env python3
"""Run SQL tests against the Percolate database on port 5438."""

import psycopg2
import sys
import os
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
    """Execute SQL from a file and display results."""
    print(f"\n{'='*60}")
    print(f"Running: {filepath}")
    print('='*60)
    
    with open(filepath, 'r') as f:
        sql_content = f.read()
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                # Execute the entire file content at once (for function creation)
                cur.execute(sql_content)
                conn.commit()
                print("SQL executed successfully")
                
                # If it's a SELECT statement, fetch results
                if sql_content.strip().upper().startswith('SELECT'):
                    rows = cur.fetchall()
                    if rows:
                        columns = [desc[0] for desc in cur.description]
                        print(f"\n{', '.join(columns)}")
                        print('-' * 50)
                        for row in rows[:10]:
                            print(row)
                        if len(rows) > 10:
                            print(f"... ({len(rows)} total rows)")
                    else:
                        print("No results returned")
                        
            except psycopg2.Error as e:
                print(f"Error: {e}")
                conn.rollback()

def create_functions_manually():
    """Create the functions by running commands directly."""
    print("\nCreating functions manually...")
    
    with get_connection() as conn:
        with conn.cursor() as cur:
            try:
                # Check schema first
                cur.execute("""
                    SELECT column_name, data_type 
                    FROM information_schema.columns 
                    WHERE table_schema = 'p8' 
                    AND table_name = 'Resources'
                    ORDER BY ordinal_position;
                """)
                print("\nColumns in p8.Resources:")
                for row in cur.fetchall():
                    print(f"  {row[0]}: {row[1]}")
                
                # Check for resource_id column
                cur.execute("""
                    SELECT column_name 
                    FROM information_schema.columns 
                    WHERE table_schema = 'p8' 
                    AND table_name = 'Resources'
                    AND column_name = 'resource_id';
                """)
                if cur.fetchone():
                    print("\nFound resource_id column in p8.Resources")
                else:
                    print("\n⚠️  resource_id column NOT found in p8.Resources")
                
                # Check TusFileUpload columns
                cur.execute("""
                    SELECT column_name, data_type 
                    FROM information_schema.columns 
                    WHERE table_schema = 'public' 
                    AND table_name = 'TusFileUpload'
                    ORDER BY ordinal_position;
                """)
                print("\nColumns in public.TusFileUpload:")
                for row in cur.fetchall():
                    print(f"  {row[0]}: {row[1]}")
                
            except psycopg2.Error as e:
                print(f"Error checking schema: {e}")

def main():
    """Run all SQL test files."""
    
    # Get the percolate root directory
    base_dir = '/Users/sirsh/code/mr_saoirse/percolate'
    functions_dir = os.path.join(base_dir, 'extension/sql-staging/p8_pg_functions/search')
    test_dir = os.path.join(base_dir, '.claude/sql_tests')
    
    # First check the schema
    create_functions_manually()
    
    # Run test queries
    print("\n\nRunning test queries...")
    for test_file in ['check_schema.sql', 'check_data.sql']:
        filepath = os.path.join(test_dir, test_file)
        if os.path.exists(filepath):
            execute_sql_file(filepath)
        else:
            print(f"Test file not found: {filepath}")

if __name__ == "__main__":
    main()