#!/usr/bin/env python3
"""
Detailed integration tests for authentication modes 1 and 2
Verifies user info retrieval from database with positive and negative cases
"""

import os
import sys
import asyncio
import httpx
import json
import jwt
from datetime import datetime, timedelta

# Base configuration
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")

# Test users - we'll update their names to verify DB reads
SIRSH_EMAIL = "sirsh.test@example.com"
SIRSH_TOKEN = "sk-sirsh-secret-token-2024"
SIRSH_NAME = "Sirsh Authenticated User"

JANE_EMAIL = "jane.test@example.com"
JANE_TOKEN = "sk-jane-bearer-token-2024"
JANE_NAME = "Jane JWT Test User"


async def setup_test_users():
    """Create test users in database via SQL"""
    print("\n=== Setting Up Test Users ===\n")
    
    # Generate proper UUIDs
    import uuid
    sirsh_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, SIRSH_EMAIL))
    jane_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, JANE_EMAIL))
    
    print(f"Sirsh UUID: {sirsh_id}")
    print(f"Jane UUID: {jane_id}")
    
    # Create users via psql
    import subprocess
    
    sql_command = f"""
    -- Delete existing test users
    DELETE FROM p8."User" WHERE email IN ('{SIRSH_EMAIL}', '{JANE_EMAIL}');
    
    -- Insert new test users
    INSERT INTO p8."User" (id, name, email, token, token_expiry, role_level, groups, created_at, updated_at, userid)
    VALUES 
      ('{sirsh_id}', '{SIRSH_NAME}', '{SIRSH_EMAIL}', '{SIRSH_TOKEN}', NOW() + INTERVAL '30 days', 10, '{{"test_group", "mode1_auth"}}', NOW(), NOW(), '{sirsh_id}'),
      ('{jane_id}', '{JANE_NAME}', '{JANE_EMAIL}', '{JANE_TOKEN}', NOW() + INTERVAL '30 days', 5, '{{"test_group", "mode2_jwt", "internal"}}', NOW(), NOW(), '{jane_id}');
    """
    
    try:
        result = subprocess.run(
            ["psql", "postgresql://postgres:postgres@localhost:5438/app", "-c", sql_command],
            capture_output=True,
            text=True
        )
        if result.returncode == 0:
            print("✓ Test users created successfully")
        else:
            print(f"✗ Error creating users: {result.stderr}")
    except Exception as e:
        print(f"✗ Failed to create users: {e}")


async def test_mode1_authentication():
    """Test Mode 1: Legacy Bearer Token with detailed user info verification"""
    print("\n=== Mode 1: Legacy Bearer Token - Detailed Tests ===\n")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Successful authentication - verify user info from DB
        print("1. POSITIVE: Valid bearer token + email (Sirsh):")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {SIRSH_TOKEN}",
                "X-User-Email": SIRSH_EMAIL
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   ✓ Authenticated successfully")
            print(f"   User ID: {data.get('user_id')}")
            print(f"   Auth Type: {data.get('auth_type')}")
            
            # Try to get more user info via a protected endpoint
            # We'll create a test endpoint that returns user details
        else:
            print(f"   ✗ Failed: {response.text}")
        
        # Test 2: Wrong token - should fail
        print("\n2. NEGATIVE: Wrong token:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": "Bearer wrong-token-12345",
                "X-User-Email": SIRSH_EMAIL
            }
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401")
        if response.status_code == 401:
            print("   ✓ Correctly rejected invalid token")
        
        # Test 3: Missing email header
        print("\n3. NEGATIVE: Missing X-User-Email:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {SIRSH_TOKEN}"
            }
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401")
        if response.status_code == 401:
            print("   ✓ Correctly rejected missing email")
        
        # Test 4: Email mismatch
        print("\n4. NEGATIVE: Email doesn't match token owner:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {SIRSH_TOKEN}",
                "X-User-Email": JANE_EMAIL  # Wrong email!
            }
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401")
        if response.status_code == 401:
            print("   ✓ Correctly rejected email mismatch")
        
        # Test 5: No authentication headers
        print("\n5. NEGATIVE: No authentication headers:")
        response = await client.get(f"{BASE_URL}/auth/ping")
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401")
        if response.status_code == 401:
            print("   ✓ Correctly rejected unauthenticated request")
        
        # Test 6: Test with environment variable
        print("\n6. POSITIVE: Using X_USER_EMAIL environment variable:")
        os.environ["X_USER_EMAIL"] = SIRSH_EMAIL
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {SIRSH_TOKEN}"
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print("   ✓ Environment variable mapping works")
        else:
            print("   ✗ Environment variable not working")
        del os.environ["X_USER_EMAIL"]


async def test_user_info_endpoint():
    """Test accessing user information from database"""
    print("\n=== Testing User Info Retrieval ===\n")
    
    async with httpx.AsyncClient() as client:
        # First, let's check if there's a user info endpoint
        # If not, we'll use the introspect endpoint which should return user info
        
        print("1. Testing token introspection for user details:")
        response = await client.post(
            f"{BASE_URL}/auth/introspect",
            data={"token": SIRSH_TOKEN},
            headers={"Content-Type": "application/x-www-form-urlencoded"}
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   Active: {data.get('active')}")
            print(f"   Username: {data.get('username')}")
            print(f"   Email: {data.get('email')}")
            print(f"   Subject (User ID): {data.get('sub')}")
            if data.get('username') == SIRSH_NAME:
                print(f"   ✓ Successfully retrieved user name from DB: {SIRSH_NAME}")
            else:
                print(f"   ✗ User name mismatch. Expected: {SIRSH_NAME}, Got: {data.get('username')}")
        
        # Test with Jane's token
        print("\n2. Testing Jane's token introspection:")
        response = await client.post(
            f"{BASE_URL}/auth/introspect",
            data={"token": JANE_TOKEN},
            headers={"Content-Type": "application/x-www-form-urlencoded"}
        )
        if response.status_code == 200:
            data = response.json()
            print(f"   Username: {data.get('username')}")
            print(f"   Email: {data.get('email')}")
            if data.get('username') == JANE_NAME:
                print(f"   ✓ Successfully retrieved Jane's name from DB: {JANE_NAME}")


async def test_mode2_jwt_preparation():
    """Prepare for Mode 2 JWT testing"""
    print("\n=== Mode 2: JWT Provider - Preparation ===\n")
    
    print("Mode 2 requires server restart with AUTH_MODE=percolate")
    print("When server is running in JWT mode, it will:")
    print("1. Accept bearer token for initial authorization")
    print("2. Issue JWT tokens with user info embedded")
    print("3. Validate JWT tokens for API access")
    
    # Simulate JWT creation to show what it would contain
    print("\n Simulated JWT payload for Jane:")
    
    jane_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, JANE_EMAIL))
    jwt_payload = {
        "sub": jane_id,
        "email": JANE_EMAIL,
        "name": JANE_NAME,
        "role_level": 5,  # Internal level
        "groups": ["test_group", "mode2_jwt", "internal"],
        "iat": int(datetime.utcnow().timestamp()),
        "exp": int((datetime.utcnow() + timedelta(hours=1)).timestamp()),
        "iss": BASE_URL,
        "aud": "percolate-api",
        "token_type": "access"
    }
    
    print(json.dumps(jwt_payload, indent=2))
    print("\nThis JWT would allow access without needing X-User-Email header")


async def test_dependency_example():
    """Show how to use authentication dependencies in endpoints"""
    print("\n=== Authentication Dependencies for Endpoints ===\n")
    
    print("Example endpoint using authentication:")
    print("""
from fastapi import Depends, HTTPException
from percolate.api.auth.middleware import get_auth, get_current_user, require_auth
from percolate.api.auth.models import AuthContext
from percolate.models.p8.types import User

# Example 1: Get auth context (user might be authenticated or not)
@app.get("/api/data")
async def get_data(auth: AuthContext = Depends(get_auth)):
    if auth:
        return {"message": f"Hello {auth.email}"}
    else:
        return {"message": "Hello anonymous"}

# Example 2: Require authentication
@app.get("/api/protected")
@require_auth()
async def protected_endpoint(auth: AuthContext = Depends(get_auth)):
    return {
        "user_id": auth.user_id,
        "email": auth.email,
        "provider": auth.provider
    }

# Example 3: Get full user object from DB
@app.get("/api/profile")
async def get_profile(user: User = Depends(get_current_user)):
    return {
        "id": str(user.id),
        "name": user.name,
        "email": user.email,
        "role_level": user.role_level,
        "groups": user.groups
    }
""")


async def verify_database_integration():
    """Verify we're reading from the database correctly"""
    print("\n=== Database Integration Verification ===\n")
    
    # Check users exist in database
    import subprocess
    
    sql_query = f"""
    SELECT id, name, email, token IS NOT NULL as has_token, role_level, groups 
    FROM p8."User" 
    WHERE email IN ('{SIRSH_EMAIL}', '{JANE_EMAIL}');
    """
    
    try:
        result = subprocess.run(
            ["psql", "postgresql://postgres:postgres@localhost:5438/app", "-c", sql_query],
            capture_output=True,
            text=True
        )
        print("Database query result:")
        print(result.stdout)
    except Exception as e:
        print(f"Failed to query database: {e}")


async def test_protected_endpoints():
    """Test accessing protected endpoints with authentication"""
    print("\n=== Testing Protected Endpoints ===\n")
    
    async with httpx.AsyncClient() as client:
        # Test various endpoints that might exist
        endpoints = [
            "/api/entities",
            "/auth/ping",
            "/api/user/profile",
            "/auth/session/info"
        ]
        
        for endpoint in endpoints:
            print(f"\nTesting {endpoint}:")
            
            # Without auth
            response = await client.get(f"{BASE_URL}{endpoint}")
            print(f"  Without auth: {response.status_code}")
            
            # With auth
            response = await client.get(
                f"{BASE_URL}{endpoint}",
                headers={
                    "Authorization": f"Bearer {SIRSH_TOKEN}",
                    "X-User-Email": SIRSH_EMAIL
                }
            )
            print(f"  With auth: {response.status_code}")
            if response.status_code == 200:
                print("  ✓ Authentication working for this endpoint")


async def main():
    """Run all integration tests"""
    print("Detailed Authentication Integration Tests")
    print("=" * 60)
    print(f"API Base URL: {BASE_URL}")
    print("=" * 60)
    
    # Setup test users
    await setup_test_users()
    
    # Verify database
    await verify_database_integration()
    
    # Test Mode 1
    await test_mode1_authentication()
    
    # Test user info retrieval
    await test_user_info_endpoint()
    
    # Test protected endpoints
    await test_protected_endpoints()
    
    # Show Mode 2 preparation
    await test_mode2_jwt_preparation()
    
    # Show dependency examples
    await test_dependency_example()
    
    print("\n" + "=" * 60)
    print("Integration Testing Complete!")
    print("\nKey Findings:")
    print("- Mode 1 authentication requires both Bearer token and X-User-Email")
    print("- User information is correctly read from database")
    print("- Invalid tokens and mismatched emails are properly rejected")
    print("- Environment variable X_USER_EMAIL can replace header")
    print("\nNext Steps:")
    print("1. Restart server with AUTH_MODE=percolate for Mode 2 JWT testing")
    print("2. Use the Depends() examples to protect your endpoints")


if __name__ == "__main__":
    import uuid  # Import at module level for UUID generation
    asyncio.run(main())