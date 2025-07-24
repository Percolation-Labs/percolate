#!/usr/bin/env python
"""Test direct database access to see what's available"""

import os
import psycopg2
import json

def test_direct_db():
    """Connect directly to database and check what's available"""
    
    # Get connection details from environment
    host = os.getenv("P8_PG_HOST", "localhost")
    port = os.getenv("P8_PG_PORT", "5438")
    user = os.getenv("P8_PG_USER", "postgres")
    password = os.getenv("P8_PG_PASSWORD", "postgres")
    database = os.getenv("P8_PG_DATABASE", "app")
    
    print(f"Connecting to {host}:{port}/{database} as {user}")
    
    try:
        # Connect to database
        conn = psycopg2.connect(
            host=host,
            port=port,
            user=user,
            password=password,
            database=database
        )
        cursor = conn.cursor()
        
        # Check what tables exist
        print("\n1. Tables in p8 schema:")
        cursor.execute("""
            SELECT table_name 
            FROM information_schema.tables 
            WHERE table_schema = 'p8' 
            ORDER BY table_name
        """)
        tables = cursor.fetchall()
        for table in tables[:10]:  # Show first 10
            print(f"  - {table[0]}")
        
        # Check Agent table
        print("\n2. Sample records from p8.Agent:")
        cursor.execute("""
            SELECT id, name, description 
            FROM p8."Agent" 
            LIMIT 5
        """)
        agents = cursor.fetchall()
        for agent in agents:
            print(f"  - ID: {agent[0]}")
            print(f"    Name: {agent[1]}")
            print(f"    Desc: {agent[2][:100] if agent[2] else 'None'}...")
            
        # Check for p8.Agent specifically
        print("\n3. Looking for 'p8.Agent' by name:")
        cursor.execute("""
            SELECT id, name, description 
            FROM p8."Agent" 
            WHERE name = 'p8.Agent' OR name = 'p8.PercolateAgent'
        """)
        results = cursor.fetchall()
        for result in results:
            print(f"  - ID: {result[0]}")
            print(f"    Name: {result[1]}")
            print(f"    Desc: {result[2][:100] if result[2] else 'None'}...")
            
        # Check PercolateAgent table (Resources)
        print("\n4. Sample records from p8.PercolateAgent:")
        cursor.execute("""
            SELECT id, name, description 
            FROM p8."PercolateAgent" 
            LIMIT 5
        """)
        percolate_agents = cursor.fetchall()
        for pa in percolate_agents:
            print(f"  - ID: {pa[0]}")
            print(f"    Name: {pa[1]}")
            print(f"    Desc: {pa[2][:100] if pa[2] else 'None'}...")
            
        cursor.close()
        conn.close()
        
    except Exception as e:
        print(f"\nError: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_direct_db()