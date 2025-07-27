#!/usr/bin/env python3
"""
Test script for Mode A: Bearer Token Authentication
Run the local MCP server and test authentication flow
"""

import os
import sys
import asyncio
import httpx
from datetime import datetime, timedelta

# Add percolate to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import percolate as p8
from percolate.models.p8.types import User
from percolate.utils import make_uuid

# Test configuration
TEST_EMAIL = "test.mode.a@example.com"
TEST_TOKEN = "sk-test-mode-a-1234567890"
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")


def create_test_user():
    """Create a test user for Mode A authentication"""
    print(f"Creating test user: {TEST_EMAIL}")
    
    user_id = make_uuid(TEST_EMAIL)
    user = User(
        id=user_id,
        name="Test Mode A User",
        email=TEST_EMAIL,
        token=TEST_TOKEN,
        token_expiry=datetime.utcnow() + timedelta(days=365),  # Long-lived token
        role_level=10,  # Partner level
        groups=["test_group"]
    )
    
    # Save user to database
    user_repo = p8.repository(User)
    user_repo.upsert_records(user)
    
    print(f"✓ Test user created with token: {TEST_TOKEN}")
    return user


async def test_bearer_auth():
    """Test Mode A authentication flow"""
    print("\n=== Testing Mode A: Bearer Token Authentication ===\n")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Authentication with header
        print("1. Testing with X-User-Email header...")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print("   ✓ Authentication successful with header")
        else:
            print(f"   ✗ Authentication failed: {response.text}")
        
        # Test 2: Authentication with environment variable
        print("\n2. Testing with X_USER_EMAIL environment variable...")
        os.environ["X_USER_EMAIL"] = TEST_EMAIL
        
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}"
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print("   ✓ Authentication successful with env var")
        else:
            print(f"   ✗ Authentication failed: {response.text}")
        
        del os.environ["X_USER_EMAIL"]
        
        # Test 3: MCP OAuth flow
        print("\n3. Testing MCP OAuth flow...")
        
        # Get authorization code
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={
                "response_type": "code",
                "client_id": "test-client",
                "redirect_uri": "http://localhost:8080/callback"
            },
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        
        if response.status_code == 200:
            auth_code = response.json().get("code")
            print(f"   ✓ Got authorization code: {auth_code[:10]}...")
            
            # Exchange code for token
            response = await client.post(
                f"{BASE_URL}/auth/token",
                data={
                    "grant_type": "authorization_code",
                    "code": auth_code,
                    "client_id": "test-client"
                }
            )
            
            if response.status_code == 200:
                token_data = response.json()
                print(f"   ✓ Token exchange successful")
                print(f"   Access token: {token_data.get('access_token', '')[:20]}...")
            else:
                print(f"   ✗ Token exchange failed: {response.text}")
        else:
            print(f"   ✗ Authorization failed: {response.text}")
        
        # Test 4: Auth ping
        print("\n4. Testing auth ping endpoint...")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {TEST_TOKEN}",
                "X-User-Email": TEST_EMAIL
            }
        )
        
        if response.status_code == 200:
            data = response.json()
            print(f"   ✓ Auth ping successful")
            print(f"   User: {data.get('user', {}).get('email', 'Unknown')}")
        else:
            print(f"   ✗ Auth ping failed: {response.text}")


def cleanup_test_user():
    """Remove test user"""
    print("\nCleaning up test user...")
    user_repo = p8.repository(User)
    user_id = make_uuid(TEST_EMAIL)
    
    try:
        user = User(id=user_id)
        user_repo.delete_records(user)
        print("✓ Test user removed")
    except:
        print("✗ Could not remove test user (may not exist)")


def main():
    """Main test runner"""
    print("Mode A Authentication Test")
    print("=" * 50)
    print(f"API Endpoint: {BASE_URL}")
    print(f"Test Email: {TEST_EMAIL}")
    print(f"Test Token: {TEST_TOKEN}")
    print("=" * 50)
    
    # Create test user
    try:
        create_test_user()
    except Exception as e:
        print(f"✗ Failed to create test user: {e}")
        return
    
    # Run tests
    try:
        asyncio.run(test_bearer_auth())
    except Exception as e:
        print(f"\n✗ Test failed with error: {e}")
    finally:
        # Cleanup
        cleanup_test_user()
    
    print("\n" + "=" * 50)
    print("Test complete!")
    
    # Instructions for running MCP server
    print("\nTo test with MCP server:")
    print("1. Start the API server: python -m percolate.api")
    print("2. In another terminal, run this script: python test_auth_mode_a.py")
    print("\nEnvironment variables for Mode A:")
    print(f"export X_USER_EMAIL={TEST_EMAIL}")
    print(f"export PERCOLATE_API_KEY={TEST_TOKEN}")


if __name__ == "__main__":
    main()