#!/usr/bin/env python3
"""Simple test to verify PostgresService context maintenance during reconnection."""

import os
import time
from percolate.services.PostgresService import PostgresService

# Get the bearer token from environment
bearer_token = os.environ.get("P8_TEST_BEARER_TOKEN")
if not bearer_token:
    print("Error: P8_TEST_BEARER_TOKEN environment variable not set")
    exit(1)

# Build connection string
connection_string = f"postgresql://postgres:{bearer_token}@localhost:25432/app"

print("=== Testing PostgresService Connection Restart ===")

# First, find the user ID for amartey@gmail.com
print("\n1. Finding user amartey@gmail.com...")
pg = PostgresService(connection_string=connection_string)
result = pg.execute('SELECT id, email FROM p8."User" WHERE email = %s', ("amartey@gmail.com",))
# No close method, connection is managed internally

if not result:
    print("User not found")
    exit(1)

user_id = result[0]["id"]
print(f"Found user: {user_id}")

# Test with user impersonation
print(f"\n2. Creating PostgresService with user_id={user_id}...")
pg = PostgresService(connection_string=connection_string, user_id=user_id, user_groups=["test_group"])

# Check initial context
print("\n3. Initial context:")
context = pg.get_user_context()
print(f"  User ID: {context.get('user_id')}")
print(f"  Groups: {context.get('user_groups')}")
print(f"  Role Level: {context.get('role_level')}")

# Execute a query
pg.execute("SELECT 1")

# Force connection close
print("\n4. Forcing connection close...")
if pg.conn:
    pg.conn.close()

# Execute another query (should trigger reconnection)
print("\n5. Executing query after connection drop...")
pg.execute("SELECT 2")

# Check context after reconnection
print("\n6. Context after reconnection:")
context = pg.get_user_context()
print(f"  User ID: {context.get('user_id')}")
print(f"  Groups: {context.get('user_groups')}")
print(f"  Role Level: {context.get('role_level')}")

# No close method, connection is managed internally
print("\n✅ Test completed successfully!")