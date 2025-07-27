#!/usr/bin/env python3
"""
Test Mode 2: JWT Provider simulation
Shows how JWT tokens work with user info embedded
"""

import os
import sys
import asyncio
import httpx
import json
import jwt
from datetime import datetime, timedelta

# Test configuration
BASE_URL = "http://localhost:5008"
JWT_SECRET = "test-jwt-secret-key"

# Our test users
SIRSH_EMAIL = "sirsh.test@example.com"
SIRSH_ID = "dda63cb0-845b-5594-a833-ff2eaa9bbd00"
SIRSH_NAME = "Sirsh Authenticated User"

JANE_EMAIL = "jane.test@example.com"
JANE_ID = "6b2c165a-b954-57db-8785-f9e6b11653e0"
JANE_NAME = "Jane JWT Test User"


def create_jwt_token(user_data, token_type="access", expiry_hours=1):
    """Create a JWT token with user info"""
    now = datetime.utcnow()
    
    payload = {
        "sub": user_data["id"],
        "email": user_data["email"],
        "name": user_data["name"],
        "role_level": user_data.get("role_level", 10),
        "groups": user_data.get("groups", []),
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(hours=expiry_hours)).timestamp()),
        "iss": BASE_URL,
        "aud": "percolate-api",
        "token_type": token_type,
        "jti": f"{token_type}-{user_data['id'][:8]}-{int(now.timestamp())}"
    }
    
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


async def demonstrate_jwt_mode():
    """Demonstrate how Mode 2 JWT authentication would work"""
    
    print("Mode 2: JWT Provider Demonstration")
    print("=" * 60)
    
    # Create JWT tokens for our users
    sirsh_jwt = create_jwt_token({
        "id": SIRSH_ID,
        "email": SIRSH_EMAIL,
        "name": SIRSH_NAME,
        "role_level": 10,
        "groups": ["test_group", "mode1_auth"]
    })
    
    jane_jwt = create_jwt_token({
        "id": JANE_ID,
        "email": JANE_EMAIL,
        "name": JANE_NAME,
        "role_level": 5,
        "groups": ["test_group", "mode2_jwt", "internal"]
    })
    
    expired_jwt = create_jwt_token({
        "id": SIRSH_ID,
        "email": SIRSH_EMAIL,
        "name": SIRSH_NAME,
        "role_level": 10,
        "groups": ["test_group"]
    }, expiry_hours=-1)  # Already expired!
    
    print("\n1. JWT Token Structure:")
    print(f"   Sirsh's JWT (first 50 chars): {sirsh_jwt[:50]}...")
    
    # Decode to show contents (skip verification for display)
    sirsh_payload = jwt.decode(sirsh_jwt, options={"verify_signature": False})
    print(f"\n   Decoded payload:")
    print(json.dumps(sirsh_payload, indent=4))
    
    print("\n2. Key differences from Mode 1:")
    print("   - No X-User-Email header needed (email is in JWT)")
    print("   - Token contains all user info (no DB lookup needed)")
    print("   - Token has expiration time")
    print("   - Can include custom claims (groups, role_level, etc.)")
    
    print("\n3. Authentication flow in Mode 2:")
    print("   Step 1: POST /auth/authorize with bearer token")
    print("   Step 2: Get authorization code")
    print("   Step 3: POST /auth/token to exchange code for JWT")
    print("   Step 4: Use JWT for all API requests")
    
    print("\n4. Positive test cases (when server is in JWT mode):")
    print("   a) Valid JWT - should authenticate successfully")
    print("   b) JWT contains user info - no DB lookup needed")
    print("   c) Different users have different JWTs with their info")
    
    print("\n5. Negative test cases:")
    print("   a) Expired JWT - should return 401 TokenExpiredError")
    
    # Show expired token
    try:
        jwt.decode(expired_jwt, JWT_SECRET, algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        print("      ✓ Expired token correctly rejected by JWT library")
    
    print("   b) Invalid signature - should return 401")
    invalid_jwt = sirsh_jwt[:-10] + "tamperedXX"
    
    print("   c) No token - should return 401")
    print("   d) Malformed JWT - should return 401")
    
    print("\n6. Refresh token flow:")
    refresh_token = create_jwt_token({
        "id": SIRSH_ID,
        "email": SIRSH_EMAIL,
        "name": SIRSH_NAME,
        "role_level": 10,
        "groups": ["test_group"]
    }, token_type="refresh", expiry_hours=24*30)  # 30 days
    
    print("   - Refresh tokens are long-lived (30 days)")
    print("   - POST /auth/token with grant_type=refresh_token")
    print("   - Returns new access token (1 hour)")
    
    print("\n7. How endpoints use JWT authentication:")
    print("""
    # The middleware automatically decodes JWT and provides user info
    
    @app.get("/api/data")
    async def get_data(auth: AuthContext = Depends(get_auth)):
        # auth.email comes from JWT payload, not header
        # auth.metadata contains role_level and groups from JWT
        return {
            "message": f"Hello {auth.email}",
            "your_name": auth.metadata.get("name"),  # From JWT
            "your_groups": auth.metadata.get("groups")  # From JWT
        }
    
    # No database lookup needed - everything is in the JWT!
    """)
    
    print("\n8. Security considerations:")
    print("   - JWT secret must be kept secure")
    print("   - Tokens should use HTTPS in production")
    print("   - Short expiration for access tokens (1 hour)")
    print("   - Refresh tokens stored securely")
    print("   - Consider JWT revocation strategy")


async def test_with_running_server():
    """Test against running server (if in JWT mode)"""
    
    print("\n\n=== Testing Against Server ===")
    
    if os.environ.get("AUTH_MODE") != "percolate":
        print("\n⚠️  Server is not in JWT mode")
        print("To test JWT mode, restart server with:")
        print("  AUTH_MODE=percolate JWT_SECRET=test-jwt-secret-key python -m percolate.api")
        return
    
    async with httpx.AsyncClient() as client:
        # Test introspection endpoint with different token types
        print("\n1. Testing token introspection:")
        
        # Introspect postgres token (Mode 1 style)
        response = await client.post(
            f"{BASE_URL}/auth/introspect",
            data={"token": "postgres"}
        )
        if response.status_code == 200:
            print("   Postgres token: Still works for backward compatibility")
        
        # In JWT mode, the server would accept JWT tokens directly


async def main():
    """Run JWT mode demonstration"""
    
    await demonstrate_jwt_mode()
    await test_with_running_server()
    
    print("\n" + "=" * 60)
    print("Summary of Mode 2 (JWT Provider):")
    print("- JWT tokens contain complete user information")
    print("- No X-User-Email header needed") 
    print("- Tokens expire and can be refreshed")
    print("- More efficient (no DB lookup per request)")
    print("- Supports custom claims for authorization")
    print("\nTo fully test, restart server with AUTH_MODE=percolate")


if __name__ == "__main__":
    asyncio.run(main())