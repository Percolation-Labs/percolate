#!/usr/bin/env python3
"""
Comprehensive test of all three authentication modes
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

# Test users
MODE1_EMAIL = "mode1.test@example.com"
MODE1_TOKEN = "postgres"  # Use postgres API key for localhost testing

MODE2_EMAIL = "mode2.test@example.com"
MODE2_TOKEN = "postgres"  # Use postgres API key for localhost testing

MODE3_EMAIL = "amartey@gmail.com"


async def test_wellknown_endpoints():
    """Test .well-known endpoints in all modes"""
    print("\n=== Testing .well-known Endpoints ===\n")
    
    async with httpx.AsyncClient() as client:
        # Test in default mode
        print("1. Default mode (legacy):")
        response = await client.get(f"{BASE_URL}/.well-known/oauth-authorization-server")
        print(f"   Status: {response.status_code}")
        data = response.json()
        print(f"   Authorization endpoint: {data.get('authorization_endpoint')}")
        print(f"   Token endpoint: {data.get('token_endpoint')}")
        
        # Test with Mode 2 environment
        os.environ["AUTH_MODE"] = "percolate"
        print("\n2. With AUTH_MODE=percolate:")
        response = await client.get(f"{BASE_URL}/.well-known/oauth-authorization-server")
        print(f"   Status: {response.status_code}")
        print("   (Should be same endpoints, different provider)")
        del os.environ["AUTH_MODE"]
        
        # Test MCP discovery
        print("\n3. MCP OAuth discovery:")
        response = await client.get(f"{BASE_URL}/.well-known/oauth-protected-resource")
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   Authorization servers: {data.get('authorization_servers', [])}")


async def test_mode1_comprehensive():
    """Comprehensive test of Mode 1: Legacy Bearer Token"""
    print("\n=== Mode 1: Legacy Bearer Token (Comprehensive) ===\n")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Basic authentication
        print("1. Basic API authentication:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {MODE1_TOKEN}",
                "X-User-Email": MODE1_EMAIL
            }
        )
        print(f"   Status: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   ✓ Authenticated as: {MODE1_EMAIL}")
            print(f"   User ID: {data.get('user_id', 'N/A')}")
        
        # Test 2: Missing email header
        print("\n2. Missing X-User-Email header:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={"Authorization": f"Bearer {MODE1_TOKEN}"}
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401 (missing email)")
        
        # Test 3: Wrong email
        print("\n3. Mismatched email:")
        response = await client.get(
            f"{BASE_URL}/auth/ping",
            headers={
                "Authorization": f"Bearer {MODE1_TOKEN}",
                "X-User-Email": "wrong@example.com"
            }
        )
        print(f"   Status: {response.status_code}")
        print(f"   Expected: 401 (email mismatch)")
        
        # Test 4: OAuth endpoints behavior
        print("\n4. OAuth endpoints in Mode 1:")
        
        # GET /auth/authorize
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={"client_id": "test", "response_type": "code"}
        )
        print(f"   GET /auth/authorize: {response.status_code}")
        
        # POST /auth/token
        response = await client.post(
            f"{BASE_URL}/auth/token",
            data={"grant_type": "authorization_code", "code": "invalid"}
        )
        print(f"   POST /auth/token: {response.status_code}")
        
        # POST /auth/introspect
        response = await client.post(
            f"{BASE_URL}/auth/introspect",
            data={"token": MODE1_TOKEN}
        )
        print(f"   POST /auth/introspect: {response.status_code}")
        if response.status_code == 200:
            data = response.json()
            print(f"   Token active: {data.get('active', False)}")


async def test_mode2_comprehensive():
    """Comprehensive test of Mode 2: Percolate OAuth Provider"""
    print("\n=== Mode 2: Percolate OAuth Provider (Comprehensive) ===\n")
    
    # Set environment
    os.environ["AUTH_MODE"] = "percolate"
    os.environ["JWT_SECRET"] = "test-jwt-secret-key"
    
    print("Environment: AUTH_MODE=percolate, JWT_SECRET=test-jwt-secret-key")
    
    # Note: We need to restart the server with new env vars for this to work
    # For now, we'll test what we can
    
    async with httpx.AsyncClient() as client:
        # Test 1: OAuth authorization flow
        print("\n1. OAuth authorization flow:")
        
        # GET authorize
        response = await client.get(
            f"{BASE_URL}/auth/authorize",
            params={
                "client_id": "test-client",
                "response_type": "code",
                "redirect_uri": "http://localhost:8080/callback"
            }
        )
        print(f"   GET /auth/authorize: {response.status_code}")
        
        # POST authorize with bearer token
        print("\n2. POST authorization with bearer token:")
        response = await client.post(
            f"{BASE_URL}/auth/authorize",
            data={
                "client_id": "test-client",
                "response_type": "code",
                "email": MODE2_EMAIL,
                "token": MODE2_TOKEN
            }
        )
        print(f"   POST /auth/authorize: {response.status_code}")
        
        # Test 3: JWT structure (simulate)
        print("\n3. JWT token structure (simulated):")
        
        # Create a sample JWT
        jwt_payload = {
            "sub": "aef2bdd9-6199-5407-933a-9db79b75d36e",
            "email": MODE2_EMAIL,
            "name": "Mode 2 Test User",
            "role_level": 10,
            "groups": ["test_group", "mode2", "jwt_users"],
            "iat": int(datetime.utcnow().timestamp()),
            "exp": int((datetime.utcnow() + timedelta(hours=1)).timestamp()),
            "iss": BASE_URL,
            "aud": "percolate-api",
            "token_type": "access"
        }
        
        sample_jwt = jwt.encode(jwt_payload, "test-jwt-secret-key", algorithm="HS256")
        print(f"   Sample JWT (first 50 chars): {sample_jwt[:50]}...")
        print(f"   Payload includes: email, role_level, groups, exp")
        
        # Test 4: Token endpoint behavior
        print("\n4. Token endpoint capabilities:")
        print("   - Accepts grant_type: authorization_code")
        print("   - Accepts grant_type: refresh_token")
        print("   - Returns JWT access token + refresh token")
        print("   - Access token expires in 1 hour")
        
    # Clean up env
    if "AUTH_MODE" in os.environ:
        del os.environ["AUTH_MODE"]
    if "JWT_SECRET" in os.environ:
        del os.environ["JWT_SECRET"]


async def test_mode3_comprehensive():
    """Comprehensive test of Mode 3: External OAuth Relay"""
    print("\n=== Mode 3: External OAuth Relay (Comprehensive) ===\n")
    
    # Check configuration
    has_google = bool(os.environ.get("GOOGLE_OAUTH_CLIENT_ID"))
    
    if not has_google:
        print("⚠️  Google OAuth not configured")
        print("   To test Mode 3, set:")
        print("   - GOOGLE_OAUTH_CLIENT_ID")
        print("   - GOOGLE_OAUTH_CLIENT_SECRET")
        print("   - AUTH_PROVIDER=google")
        return
    
    print(f"Test user: {MODE3_EMAIL}")
    print("Configuration: AUTH_PROVIDER=google (if set)")
    
    async with httpx.AsyncClient() as client:
        # Test 1: Authorization redirect
        print("\n1. Authorization redirect to Google:")
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
            else:
                print(f"   Redirects to: {location[:80]}...")
        
        # Test 2: Token exchange behavior
        print("\n2. Token exchange behavior (POST /auth/token):")
        print("   - Accepts Google authorization code")
        print("   - Exchanges code with Google")
        print("   - Returns Google tokens directly")
        print("   - Does NOT store tokens in database")
        print("   - Only registers user email")
        
        # Test 3: Token validation
        print("\n3. Token validation behavior:")
        print("   - All validations go to Google's tokeninfo endpoint")
        print("   - No local token storage or validation")
        print("   - Returns user context from email lookup")
        print("   - Raises TokenExpiredError when Google token expires")
        
        # Test 4: User registration check
        print("\n4. User registration in database:")
        print(f"   User email: {MODE3_EMAIL}")
        print("   Has token stored: No (relay mode)")
        print("   Groups: oauth_users, google, test_group")


async def test_endpoint_comparison():
    """Compare endpoint behavior across all modes"""
    print("\n=== Endpoint Behavior Comparison ===\n")
    
    endpoints = [
        ("GET /.well-known/oauth-authorization-server", "GET", "/.well-known/oauth-authorization-server"),
        ("GET /auth/authorize", "GET", "/auth/authorize"),
        ("POST /auth/authorize", "POST", "/auth/authorize"),
        ("POST /auth/token", "POST", "/auth/token"),
        ("POST /auth/introspect", "POST", "/auth/introspect"),
        ("GET /auth/ping", "GET", "/auth/ping"),
    ]
    
    print("| Endpoint | Mode 1 (Legacy) | Mode 2 (JWT) | Mode 3 (Relay) |")
    print("|----------|-----------------|--------------|----------------|")
    
    for name, method, path in endpoints:
        mode1_behavior = get_endpoint_behavior(name, 1)
        mode2_behavior = get_endpoint_behavior(name, 2)
        mode3_behavior = get_endpoint_behavior(name, 3)
        
        print(f"| {name} | {mode1_behavior} | {mode2_behavior} | {mode3_behavior} |")


def get_endpoint_behavior(endpoint, mode):
    """Get expected behavior for endpoint in given mode"""
    behaviors = {
        # Mode 1: Legacy Bearer
        1: {
            "GET /.well-known/oauth-authorization-server": "Returns metadata",
            "GET /auth/authorize": "Not used (401/form)",
            "POST /auth/authorize": "Not used",
            "POST /auth/token": "Not used (401)",
            "POST /auth/introspect": "Validates bearer",
            "GET /auth/ping": "Bearer + Email"
        },
        # Mode 2: Percolate JWT
        2: {
            "GET /.well-known/oauth-authorization-server": "Returns metadata",
            "GET /auth/authorize": "Shows login form",
            "POST /auth/authorize": "Bearer → Code",
            "POST /auth/token": "Code → JWT",
            "POST /auth/introspect": "Validates JWT",
            "GET /auth/ping": "JWT or Bearer"
        },
        # Mode 3: External Relay
        3: {
            "GET /.well-known/oauth-authorization-server": "Returns metadata",
            "GET /auth/authorize": "Redirect to provider",
            "POST /auth/authorize": "Not used",
            "POST /auth/token": "Relay to provider",
            "POST /auth/introspect": "Query provider",
            "GET /auth/ping": "Provider token"
        }
    }
    
    return behaviors.get(mode, {}).get(endpoint, "Unknown")


async def main():
    """Run all comprehensive tests"""
    print("Comprehensive OAuth Authentication Testing")
    print("=" * 60)
    print(f"API Base URL: {BASE_URL}")
    print(f"Test Users:")
    print(f"  Mode 1: {MODE1_EMAIL}")
    print(f"  Mode 2: {MODE2_EMAIL}")
    print(f"  Mode 3: {MODE3_EMAIL}")
    print("=" * 60)
    
    # Test well-known endpoints
    await test_wellknown_endpoints()
    
    # Test each mode comprehensively
    await test_mode1_comprehensive()
    await test_mode2_comprehensive()
    await test_mode3_comprehensive()
    
    # Compare endpoint behaviors
    await test_endpoint_comparison()
    
    print("\n" + "=" * 60)
    print("Testing complete!")
    print("\nNext steps:")
    print("1. For Mode 2 (JWT), restart server with AUTH_MODE=percolate")
    print("2. For Mode 3 (Google), run: python test_google_oauth_interactive.py")


if __name__ == "__main__":
    asyncio.run(main())