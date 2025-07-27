#!/usr/bin/env python3
"""
Test OAuth endpoints behavior in all three authentication modes
"""

import os
import sys
import asyncio
import httpx
import json
from datetime import datetime, timedelta

# Base configuration
BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")

# Test users for each mode
MODE1_EMAIL = "mode1.test@example.com"
MODE1_TOKEN = "postgres"  # Use postgres API key for localhost testing

MODE2_EMAIL = "mode2.test@example.com"
MODE2_TOKEN = "postgres"  # Use postgres API key for localhost testing

MODE3_EMAIL = "amartey@gmail.com"  # For Google OAuth testing


async def test_wellknown_endpoints():
    """Test .well-known endpoints (should work in all modes)"""
    print("\n=== Testing .well-known Endpoints ===\n")
    
    async with httpx.AsyncClient() as client:
        # OAuth Authorization Server metadata
        response = await client.get(f"{BASE_URL}/.well-known/oauth-authorization-server")
        print("1. OAuth Authorization Server metadata:")
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   Issuer: {data.get('issuer')}")
            print(f"   Authorization endpoint: {data.get('authorization_endpoint')}")
            print(f"   Token endpoint: {data.get('token_endpoint')}")
            print(f"   Supported scopes: {data.get('scopes_supported')}")
        
        # OAuth Protected Resource metadata (for MCP)
        response = await client.get(f"{BASE_URL}/.well-known/oauth-protected-resource")
        print("\n2. OAuth Protected Resource metadata:")
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   Resource: {data.get('resource')}")
            print(f"   Authorization servers: {data.get('authorization_servers')}")


async def test_mode1_legacy():
    """Test Mode 1: Legacy Bearer Token"""
    print("\n=== Mode 1: Legacy Bearer Token ===\n")
    
    # First create a test user
    print("Setting up test user...")
    # Note: In a real test, we'd use the database directly
    # For now, we'll assume the user exists or use postgres API key
    
    async with httpx.AsyncClient() as client:
        # Test 1: API access with bearer token
        print("1. Testing API access with bearer token + email header:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": "Bearer postgres",  # Using postgres as test token
                "X-User-Email": MODE1_EMAIL
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print("   ✓ Authentication successful")
            print(f"   Response: {response.json()}")
        else:
            print(f"   ✗ Failed: {response.text}")
        
        # Test 2: OAuth endpoints should not be used
        print("\n2. OAuth /auth/authorize endpoint (should not process bearer):")
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={"client_id": "test", "response_type": "code"}
        )
        print(f"   Status: {response.status_code}")
        print(f"   Note: Should return login form or error, not process bearer token")
        
        # Test 3: Token endpoint should fail
        print("\n3. OAuth /auth/token endpoint (should fail):")
        response = await client.post(
            f"{BASE_URL}/auth/token",
            data={"grant_type": "authorization_code", "code": "dummy"}
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 400/401 (no valid code)")


async def test_mode2_percolate_oauth():
    """Test Mode 2: Percolate as OAuth Provider"""
    print("\n=== Mode 2: Percolate OAuth Provider (JWT) ===\n")
    
    # Set environment for Mode 2
    os.environ["AUTH_MODE"] = "percolate"
    os.environ["JWT_SECRET"] = "test-jwt-secret"
    
    print("Environment set: AUTH_MODE=percolate")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Authorization endpoint
        print("\n1. Testing /auth/authorize endpoint:")
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={
                "client_id": "test-client",
                "response_type": "code",
                "redirect_uri": "http://localhost:8080/callback"
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print("   Should show login form or require bearer token")
        
        # Test 2: Authorization with bearer token (POST)
        print("\n2. Testing authorization with bearer token:")
        response = await client.post(
            f"{BASE_URL}/auth/authorize",
            data={
                "client_id": "test-client",
                "response_type": "code",
                "email": MODE2_EMAIL,
                "token": "postgres"  # Using postgres token for test
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code in [200, 302]:
            print("   Authorization processed")
            if response.status_code == 200:
                data = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
                if "code" in data:
                    print(f"   ✓ Got authorization code: {data['code'][:10]}...")
        
        # Test 3: Token endpoint info
        print("\n3. Token endpoint availability:")
        print(f"   POST {BASE_URL}/auth/token")
        print("   Accepts: authorization_code, refresh_token")
        print("   Returns: JWT access token + refresh token")
        
        # Test 4: Introspection
        print("\n4. Token introspection endpoint:")
        response = await client.post(
            f"{BASE_URL}/auth/introspect",
            data={"token": "dummy-jwt-token"}
        )
        print(f"   Status: {response.status_code}")
        print("   Note: Would validate JWT tokens")
    
    # Clean up environment
    if "AUTH_MODE" in os.environ:
        del os.environ["AUTH_MODE"]
    if "JWT_SECRET" in os.environ:
        del os.environ["JWT_SECRET"]


async def test_mode3_external_oauth():
    """Test Mode 3: External OAuth Provider"""
    print("\n=== Mode 3: External OAuth Provider (Google) ===\n")
    
    # Check if Google OAuth is configured
    if not os.environ.get("GOOGLE_OAUTH_CLIENT_ID"):
        print("⚠️  Google OAuth not configured")
        print("   Set GOOGLE_OAUTH_CLIENT_ID and GOOGLE_OAUTH_CLIENT_SECRET")
        return
    
    print(f"Google OAuth configured for user: {MODE3_EMAIL}")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Authorization endpoint redirects to Google
        print("\n1. Testing /auth/authorize with provider=google:")
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={
                "client_id": "test-client",
                "response_type": "code",
                "provider": "google",
                "redirect_uri": "http://localhost:8080/callback"
            },
            follow_redirects=False
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 302:
            location = response.headers.get("location", "")
            if "accounts.google.com" in location:
                print("   ✓ Redirects to Google OAuth")
                print(f"   Location: {location[:100]}...")
            else:
                print(f"   Redirects to: {location}")
        
        # Test 2: Token endpoint relays to Google
        print("\n2. Token endpoint behavior:")
        print("   POST /auth/token with Google auth code")
        print("   - Exchanges code with Google")
        print("   - Returns Google tokens (not stored)")
        print("   - Registers user email only")
        
        # Test 3: Token validation
        print("\n3. Token validation behavior:")
        print("   All token validations go to Google")
        print("   - No local token storage")
        print("   - TokenExpiredError when Google token expires")
        print("   - User context from email lookup")


async def test_auth_ping_all_modes():
    """Test /auth/ping endpoint in different modes"""
    print("\n=== Testing /auth/ping in All Modes ===\n")
    
    async with httpx.AsyncClient() as client:
        # Mode 1: Bearer + Email
        print("1. Mode 1 - Bearer token + email:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": "Bearer postgres",
                "X-User-Email": "test@example.com"
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            print(f"   Response: {response.json()}")
        
        # Mode 2: JWT would be tested here
        print("\n2. Mode 2 - JWT token:")
        print("   Would accept: Bearer <jwt-token>")
        print("   Email extracted from JWT payload")
        
        # Mode 3: Google token would be tested here
        print("\n3. Mode 3 - Google token:")
        print("   Would accept: Bearer <google-token>")
        print("   Validates against Google, gets email from response")


async def main():
    """Run all tests"""
    print("OAuth Endpoints Testing")
    print("=" * 50)
    print(f"API Base URL: {BASE_URL}")
    print(f"Current AUTH_MODE: {os.environ.get('AUTH_MODE', 'legacy (default)')}")
    print(f"Current AUTH_PROVIDER: {os.environ.get('AUTH_PROVIDER', 'none')}")
    
    # Test well-known endpoints (all modes)
    await test_wellknown_endpoints()
    
    # Test each mode
    await test_mode1_legacy()
    await test_mode2_percolate_oauth()
    await test_mode3_external_oauth()
    
    # Test auth ping
    await test_auth_ping_all_modes()
    
    print("\n" + "=" * 50)
    print("Testing complete!")
    print("\nFor interactive Google OAuth test, run:")
    print("python test_google_oauth_interactive.py")


if __name__ == "__main__":
    asyncio.run(main())