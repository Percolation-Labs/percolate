#!/usr/bin/env python
"""Test MCP authentication fallback behavior"""

import os
import asyncio
from percolate.api.mcp_server.repository_factory import create_repository
from percolate.api.mcp_server.api_repository import APIProxyRepository

async def test_auth_fallback():
    """Test authentication fallback from request -> env -> default"""
    
    print("🔐 MCP Authentication Fallback Test")
    print("=" * 60)
    
    # Save original env
    original_env = os.environ.copy()
    
    # Test 1: Auth from request context
    print("\n1️⃣ Test: Authentication from request context")
    print("-" * 40)
    os.environ["P8_API_ENDPOINT"] = "http://localhost:5008"
    os.environ["P8_USE_API_MODE"] = "true"  # Force API mode
    
    auth_context = {
        "token": "request-token-123",
        "headers": {
            "X-User-Email": "user@request.com",
            "X-Custom-Header": "custom-value"
        }
    }
    
    repo1 = create_repository(auth_context=auth_context)
    if isinstance(repo1, APIProxyRepository):
        print(f"✅ Token: {repo1.headers.get('Authorization')}")
        print(f"✅ Email: {repo1.headers.get('X-User-Email')}")
        print(f"✅ Custom header passed: {'X-Custom-Header' in repo1.headers}")
        await repo1.close()
    
    # Test 2: Fallback to P8_API_KEY
    print("\n2️⃣ Test: Fallback to P8_API_KEY environment variable")
    print("-" * 40)
    os.environ["P8_API_KEY"] = "env-api-key-456"
    os.environ["P8_USER_EMAIL"] = "user@env.com"
    
    repo2 = create_repository()  # No auth context
    if isinstance(repo2, APIProxyRepository):
        print(f"✅ Token: {repo2.headers.get('Authorization')}")
        print(f"✅ Email: {repo2.headers.get('X-User-Email')}")
        await repo2.close()
    
    # Test 3: Fallback to P8_PG_PASSWORD
    print("\n3️⃣ Test: Fallback to P8_PG_PASSWORD when no API key")
    print("-" * 40)
    del os.environ["P8_API_KEY"]
    os.environ["P8_PG_PASSWORD"] = "db-password-789"
    
    repo3 = create_repository()  # No auth context
    if isinstance(repo3, APIProxyRepository):
        print(f"✅ Token: {repo3.headers.get('Authorization')}")
        print(f"✅ Email: {repo3.headers.get('X-User-Email')}")
        await repo3.close()
    
    # Test 4: Ultimate fallback to "postgres"
    print("\n4️⃣ Test: Ultimate fallback to 'postgres' default")
    print("-" * 40)
    del os.environ["P8_PG_PASSWORD"]
    del os.environ["P8_USER_EMAIL"]
    
    repo4 = create_repository()  # No auth context
    if isinstance(repo4, APIProxyRepository):
        print(f"✅ Token: {repo4.headers.get('Authorization')}")
        print(f"✅ Email: {repo4.headers.get('X-User-Email') or 'None'}")
        await repo4.close()
    
    # Test 5: DXT scenario
    print("\n5️⃣ Test: Desktop Extension (DXT) scenario")
    print("-" * 40)
    os.environ["P8_MCP_DESKTOP_EXT"] = "true"
    os.environ["P8_API_KEY"] = "dxt-user-token"
    os.environ["P8_USER_EMAIL"] = "dxt-user@example.com"
    
    repo5 = create_repository()
    if isinstance(repo5, APIProxyRepository):
        print(f"✅ DXT Token: {repo5.headers.get('Authorization')}")
        print(f"✅ DXT Email: {repo5.headers.get('X-User-Email')}")
        await repo5.close()
    
    print("\n" + "=" * 60)
    print("📝 Summary:")
    print("- Request context has highest priority")
    print("- Falls back to P8_API_KEY environment variable")
    print("- Falls back to P8_PG_PASSWORD if no API key")
    print("- Ultimate fallback to 'postgres' for dev")
    print("- DXT can set auth via environment variables")
    
    # Restore env
    os.environ.clear()
    os.environ.update(original_env)


if __name__ == "__main__":
    asyncio.run(test_auth_fallback())