#!/usr/bin/env python3
"""Test script to verify PostgresService maintains context during connection restarts."""

import os
import sys
import time
from pathlib import Path

# Add the percolate module to the Python path
sys.path.insert(0, str(Path(__file__).parent / "clients/python/percolate"))

from percolate.services.PostgresService import PostgresService
from percolate.models.p8.types import UserContext

# Get the bearer token from environment
bearer_token = os.environ.get("P8_TEST_BEARER_TOKEN")
if not bearer_token:
    print("Error: P8_TEST_BEARER_TOKEN environment variable not set")
    sys.exit(1)

# Database configuration
db_config = {
    "host": "localhost",
    "port": 25432,
    "database": "app",
    "user": "postgres",
    "password": bearer_token
}

def test_connection_restart_with_context():
    """Test that user context is maintained across connection restarts."""
    print("=== Testing PostgresService Connection Restart with Context ===")
    
    # First, let's find the user ID for amartey@gmail.com
    print("\n1. Finding user ID for amartey@gmail.com...")
    system_service = PostgresService(**db_config)
    
    try:
        result = system_service.execute(
            "SELECT id, email, role_level FROM users WHERE email = %s",
            ("amartey@gmail.com",)
        )
        
        if not result:
            print("User amartey@gmail.com not found in database")
            return
        
        user_id = result[0]["id"]
        user_email = result[0]["email"]
        user_role_level = result[0]["role_level"]
        print(f"Found user: ID={user_id}, Email={user_email}, Role Level={user_role_level}")
        
    except Exception as e:
        print(f"Error finding user: {e}")
        return
    finally:
        system_service.close()
    
    # Now test with user impersonation
    print(f"\n2. Creating PostgresService with user_id={user_id} (impersonating {user_email})...")
    user_service = PostgresService(**db_config, user_id=user_id)
    
    try:
        # Get initial context
        print("\n3. Checking initial user context...")
        initial_context = user_service.get_user_context()
        print(f"Initial context: {initial_context}")
        
        # Execute a query to ensure context is applied
        print("\n4. Executing test query with user context...")
        result = user_service.execute("SELECT current_user, current_database()")
        print(f"Database user: {result[0]['current_user']}, Database: {result[0]['current_database']}")
        
        # Check PostgreSQL session variables
        result = user_service.execute("""
            SELECT 
                current_setting('percolate.user_id', true) as session_user_id,
                current_setting('percolate.user_groups', true) as session_user_groups,
                current_setting('percolate.role_level', true) as session_role_level
        """)
        print(f"Session variables: {result[0]}")
        
        # Force connection close to simulate a connection drop
        print("\n5. Simulating connection drop...")
        if user_service.conn:
            user_service.conn.close()
            print("Connection closed.")
        
        # Wait a bit
        time.sleep(1)
        
        # Execute another query - this should trigger reconnection
        print("\n6. Executing query after connection drop (should trigger reconnection)...")
        result = user_service.execute("SELECT 1 as test")
        print(f"Query successful: {result}")
        
        # Check if context was restored
        print("\n7. Checking if user context was restored after reconnection...")
        restored_context = user_service.get_user_context()
        print(f"Restored context: {restored_context}")
        
        # Verify session variables again
        result = user_service.execute("""
            SELECT 
                current_setting('percolate.user_id', true) as session_user_id,
                current_setting('percolate.user_groups', true) as session_user_groups,
                current_setting('percolate.role_level', true) as session_role_level
        """)
        print(f"Session variables after reconnection: {result[0]}")
        
        # Compare contexts
        print("\n8. Verifying context consistency...")
        if initial_context == restored_context:
            print("✅ SUCCESS: Context maintained across connection restart!")
        else:
            print("❌ FAILURE: Context changed after reconnection")
            print(f"Initial: {initial_context}")
            print(f"Restored: {restored_context}")
        
        # Test with groups
        print("\n9. Testing with user groups...")
        group_service = PostgresService(**db_config, user_id=user_id, user_groups=["admin", "developers"])
        
        # Check context with groups
        group_context = group_service.get_user_context()
        print(f"Context with groups: {group_context}")
        
        # Force reconnection and check again
        if group_service.conn:
            group_service.conn.close()
        
        result = group_service.execute("SELECT 1")
        restored_group_context = group_service.get_user_context()
        print(f"Context with groups after reconnection: {restored_group_context}")
        
        if group_context == restored_group_context:
            print("✅ SUCCESS: Group context maintained across connection restart!")
        else:
            print("❌ FAILURE: Group context changed after reconnection")
        
    except Exception as e:
        print(f"Error during testing: {e}")
        import traceback
        traceback.print_exc()
    finally:
        user_service.close()
        if 'group_service' in locals():
            group_service.close()

def test_multiple_reconnections():
    """Test multiple reconnections to ensure stability."""
    print("\n\n=== Testing Multiple Reconnections ===")
    
    # Get user ID first
    system_service = PostgresService(**db_config)
    result = system_service.execute(
        "SELECT id FROM users WHERE email = %s",
        ("amartey@gmail.com",)
    )
    system_service.close()
    
    if not result:
        print("User not found")
        return
    
    user_id = result[0]["id"]
    service = PostgresService(**db_config, user_id=user_id, user_groups=["test_group"])
    
    try:
        initial_context = service.get_user_context()
        print(f"Initial context: {initial_context}")
        
        # Perform multiple reconnection cycles
        for i in range(3):
            print(f"\n--- Reconnection cycle {i+1} ---")
            
            # Force close
            if service.conn:
                service.conn.close()
            
            # Execute query (triggers reconnection)
            result = service.execute(f"SELECT {i+1} as cycle")
            print(f"Query result: {result}")
            
            # Check context
            current_context = service.get_user_context()
            print(f"Current context: {current_context}")
            
            if current_context != initial_context:
                print(f"❌ Context mismatch on cycle {i+1}")
                break
        else:
            print("\n✅ SUCCESS: Context maintained across all reconnection cycles!")
            
    finally:
        service.close()

if __name__ == "__main__":
    test_connection_restart_with_context()
    test_multiple_reconnections()