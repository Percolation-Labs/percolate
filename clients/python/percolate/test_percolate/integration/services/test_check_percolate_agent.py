#!/usr/bin/env python
"""Check PercolateAgent table structure"""

import os
import psycopg2

def check_percolate_agent():
    # Get connection details from environment
    host = os.getenv("P8_PG_HOST", "localhost")
    port = os.getenv("P8_PG_PORT", "5438")
    user = os.getenv("P8_PG_USER", "postgres")
    password = os.getenv("P8_PG_PASSWORD", "postgres")
    database = os.getenv("P8_PG_DATABASE", "app")
    
    conn = psycopg2.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database=database
    )
    cursor = conn.cursor()
    
    # Check columns in PercolateAgent table
    print("Columns in p8.PercolateAgent:")
    cursor.execute("""
        SELECT column_name, data_type 
        FROM information_schema.columns 
        WHERE table_schema = 'p8' AND table_name = 'PercolateAgent'
        ORDER BY ordinal_position
    """)
    
    columns = cursor.fetchall()
    for col in columns:
        print(f"  - {col[0]}: {col[1]}")
    
    # Try to get sample data
    print("\nSample data from p8.PercolateAgent:")
    cursor.execute("""
        SELECT id, name, content, uri 
        FROM p8."PercolateAgent" 
        LIMIT 3
    """)
    
    results = cursor.fetchall()
    for r in results:
        print(f"  ID: {r[0]}")
        print(f"  Name: {r[1]}")
        print(f"  Content: {r[2][:100] if r[2] else 'None'}...")
        print(f"  URI: {r[3]}")
        print()
    
    cursor.close()
    conn.close()

if __name__ == "__main__":
    check_percolate_agent()