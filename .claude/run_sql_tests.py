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
            # Split into individual statements
            statements = [s.strip() for s in sql_content.split(';') if s.strip()]
            
            for i, statement in enumerate(statements):
                # Skip empty statements
                if not statement or statement.startswith('--'):
                    continue
                
                print(f"\n--- Statement {i+1} ---")
                print(statement[:200] + '...' if len(statement) > 200 else statement)
                
                try:
                    cur.execute(statement)
                    
                    # If it's a SELECT statement, fetch results
                    if statement.strip().upper().startswith('SELECT'):
                        rows = cur.fetchall()
                        if rows:
                            # Get column names
                            columns = [desc[0] for desc in cur.description]
                            print(f"\n{', '.join(columns)}")
                            print('-' * 50)
                            for row in rows[:10]:  # Limit output to 10 rows
                                print(row)
                            if len(rows) > 10:
                                print(f"... ({len(rows)} total rows)")
                        else:
                            print("No results returned")
                    else:
                        conn.commit()
                        print("Statement executed successfully")
                        
                except psycopg2.Error as e:
                    print(f"Error: {e}")
                    conn.rollback()

def main():
    """Run all SQL test files."""
    
    # First run the SQL functions to create them
    # Get the percolate root directory
    script_path = os.path.abspath(__file__)
    base_dir = '/Users/sirsh/code/mr_saoirse/percolate'
    functions_dir = os.path.join(base_dir, 'extension/sql-staging/p8_pg_functions/search')
    test_dir = os.path.join(base_dir, '.claude/sql_tests')
    
    # Create functions
    print("\nCreating SQL functions...")
    for func_file in ['get_resource_metrics.sql', 'file_upload_search.sql']:
        filepath = os.path.join(functions_dir, func_file)
        if os.path.exists(filepath):
            execute_sql_file(filepath)
        else:
            print(f"Function file not found: {filepath}")
    
    # Run test queries
    print("\n\nRunning test queries...")
    for test_file in ['check_schema.sql', 'check_data.sql', 'test_search_functions.sql']:
        filepath = os.path.join(test_dir, test_file)
        if os.path.exists(filepath):
            execute_sql_file(filepath)
        else:
            print(f"Test file not found: {filepath}")

if __name__ == "__main__":
    main()