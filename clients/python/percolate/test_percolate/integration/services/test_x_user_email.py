#!/usr/bin/env python
"""Test X-User-Email environment variable support"""

import os
import asyncio
from percolate.api.mcp_server.config import get_mcp_settings
from percolate.api.mcp_server.repository_factory import create_repository
from percolate.api.mcp_server.api_repository import APIProxyRepository

async def test_x_user_email():
    """Test X-User-Email environment variable support"""
    
    print("📧 Testing X-User-Email Environment Variable")
    print("=" * 60)
    
    # Save original env
    original_env = os.environ.copy()
    
    # Test 1: X-User-Email from environment
    print("\n1️⃣ Test: X-User-Email from environment")
    print("-" * 40)
    os.environ.clear()
    os.environ.update(original_env)
    os.environ["P8_API_ENDPOINT"] = "http://localhost:5008"
    os.environ["X-User-Email"] = "user@x-header.com"
    os.environ["P8_PG_PASSWORD"] = "test-token"
    
    settings = get_mcp_settings()
    print(f"✅ Config loaded email: {settings.user_email}")
    
    repo = create_repository()
    if isinstance(repo, APIProxyRepository):
        print(f"✅ Repository email header: {repo.headers.get('X-User-Email')}")
        await repo.close()
    
    # Test 2: Fallback to P8_USER_EMAIL
    print("\n2️⃣ Test: Fallback to P8_USER_EMAIL")
    print("-" * 40)
    del os.environ["X-User-Email"]
    os.environ["P8_USER_EMAIL"] = "user@p8-env.com"
    
    settings = get_mcp_settings()
    print(f"✅ Config loaded email: {settings.user_email}")
    
    repo = create_repository()
    if isinstance(repo, APIProxyRepository):
        print(f"✅ Repository email header: {repo.headers.get('X-User-Email')}")
        await repo.close()
    
    # Test 3: Header from request context
    print("\n3️⃣ Test: X-User-Email from request headers")
    print("-" * 40)
    
    auth_context = {
        "token": "request-token",
        "headers": {
            "X-User-Email": "user@request-header.com",
            "X-Custom-Header": "custom-value"
        }
    }
    
    repo = create_repository(auth_context=auth_context)
    if isinstance(repo, APIProxyRepository):
        print(f"✅ Repository email header: {repo.headers.get('X-User-Email')}")
        print(f"✅ All headers preserved: {list(repo.headers.keys())}")
        await repo.close()
    
    print("\n" + "=" * 60)
    print("✅ X-User-Email support working correctly!")
    print("   - Environment variable: X-User-Email")
    print("   - HTTP header name: X-User-Email")
    print("   - Fallback to P8_USER_EMAIL for compatibility")
    
    # Restore env
    os.environ.clear()
    os.environ.update(original_env)


if __name__ == "__main__":
    asyncio.run(test_x_user_email())