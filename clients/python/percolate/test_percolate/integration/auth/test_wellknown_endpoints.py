#!/usr/bin/env python3
"""
Test OAuth well-known endpoints for all authentication modes
"""

import os
import asyncio
import httpx
import json
import subprocess

BASE_URL = os.environ.get("P8_API_ENDPOINT", "http://localhost:5008")

async def test_wellknown_endpoints(mode_name, env_vars=None):
    """Test well-known endpoints for a specific authentication mode"""
    print(f"\n=== Mode: {mode_name} ===")
    
    if env_vars:
        print("Environment variables:")
        for key, value in env_vars.items():
            print(f"  {key}={value}")
    
    async with httpx.AsyncClient() as client:
        # Test /.well-known/oauth-authorization-server
        print("\n/.well-known/oauth-authorization-server:")
        try:
            response = await client.get(f"{BASE_URL}/.well-known/oauth-authorization-server")
            print(f"  Status: {response.status_code}")
            if response.status_code == 200:
                data = response.json()
                print(f"  Response: {json.dumps(data, indent=2)}")
        except Exception as e:
            print(f"  Error: {e}")
        
        # Test /.well-known/oauth-protected-resource
        print("\n/.well-known/oauth-protected-resource:")
        try:
            response = await client.get(f"{BASE_URL}/.well-known/oauth-protected-resource")
            print(f"  Status: {response.status_code}")
            if response.status_code == 200:
                data = response.json()
                print(f"  Response: {json.dumps(data, indent=2)}")
        except Exception as e:
            print(f"  Error: {e}")

async def main():
    """Test well-known endpoints for all authentication modes"""
    print("OAuth Well-Known Endpoints Test")
    print("=" * 60)
    
    # Mode 1: Legacy Bearer Token (default)
    await test_wellknown_endpoints("Mode 1 - Legacy Bearer Token (Default)")
    
    # Mode 2: Percolate JWT Provider
    print("\n" + "-" * 60)
    print("Note: Mode 2 requires server restart with AUTH_MODE=percolate")
    print("Example well-known response for Mode 2:")
    mode2_response = {
        "issuer": BASE_URL,
        "authorization_endpoint": f"{BASE_URL}/auth/authorize",
        "token_endpoint": f"{BASE_URL}/auth/token",
        "introspection_endpoint": f"{BASE_URL}/auth/introspect",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"],
        "scopes_supported": ["openid", "email", "profile"],
        "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic"],
        "providers": ["percolate"]
    }
    print(json.dumps(mode2_response, indent=2))
    
    # Mode 3: External OAuth Relay (Google)
    print("\n" + "-" * 60)
    print("Note: Mode 3 requires server restart with AUTH_PROVIDER=google")
    print("Example well-known response for Mode 3:")
    mode3_response = {
        "issuer": BASE_URL,
        "authorization_endpoint": f"{BASE_URL}/auth/authorize",
        "token_endpoint": f"{BASE_URL}/auth/token",
        "introspection_endpoint": f"{BASE_URL}/auth/introspect",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"],
        "scopes_supported": ["openid", "email", "profile"],
        "token_endpoint_auth_methods_supported": ["client_secret_post", "client_secret_basic"],
        "providers": ["bearer", "google"]
    }
    print(json.dumps(mode3_response, indent=2))
    
    print("\n" + "=" * 60)
    print("\nKey Differences Between Modes:")
    print("\nMode 1 (Legacy):")
    print("  - 'providers' includes only 'bearer'")
    print("  - No JWT support, only bearer token validation")
    print("  - OAuth endpoints exist but are minimal")
    
    print("\nMode 2 (Percolate JWT):")
    print("  - 'providers' includes 'percolate'")
    print("  - Full JWT token issuance and validation")
    print("  - OAuth flow with JWT access tokens")
    
    print("\nMode 3 (External Relay):")
    print("  - 'providers' includes 'bearer' and external provider (e.g., 'google')")
    print("  - OAuth flow relays to external provider")
    print("  - No local token storage")

if __name__ == "__main__":
    asyncio.run(main())