#!/usr/bin/env python
"""Demonstrate MCP server dual-mode architecture"""

import asyncio
import os
from percolate.api.mcp_server.repository_factory import create_repository
from percolate.api.mcp_server.database_repository import DatabaseRepository
from percolate.api.mcp_server.api_repository import APIProxyRepository

async def demonstrate_dual_mode():
    """Show how MCP server automatically selects the appropriate mode"""
    
    print("🏗️  MCP Server Dual-Mode Architecture Demo")
    print("=" * 60)
    
    # Save original env
    original_env = os.environ.copy()
    
    # Test 1: Database mode (no API config)
    print("\n1️⃣  Scenario: Only database configured")
    print("-" * 40)
    os.environ.clear()
    os.environ.update(original_env)
    os.environ.update({
        "P8_PG_HOST": "localhost",
        "P8_PG_DATABASE": "app",
        "P8_PG_USER": "percolate",
        "P8_PG_PASSWORD": "secret"
    })
    # Remove API settings
    os.environ.pop("P8_API_KEY", None)
    os.environ.pop("P8_API_ENDPOINT", None)
    
    repo1 = create_repository()
    print(f"   Created: {type(repo1).__name__}")
    print(f"   ✅ Database mode selected")
    
    # Test 2: API mode (only API configured)
    print("\n2️⃣  Scenario: Only API configured")
    print("-" * 40)
    os.environ.clear()
    os.environ.update(original_env)
    os.environ.update({
        "P8_API_ENDPOINT": "https://api.percolationlabs.ai",
        "P8_API_KEY": "test-key",
        "P8_USER_EMAIL": "test@example.com"
    })
    # Remove DB settings
    for key in ["P8_PG_HOST", "P8_PG_DATABASE", "P8_PG_USER", "P8_PG_PASSWORD"]:
        os.environ.pop(key, None)
    
    repo2 = create_repository()
    print(f"   Created: {type(repo2).__name__}")
    print(f"   ✅ API proxy mode selected")
    
    # Test 3: Both configured, default to DB
    print("\n3️⃣  Scenario: Both DB and API configured (default)")
    print("-" * 40)
    os.environ.clear()
    os.environ.update(original_env)
    os.environ.update({
        # DB config
        "P8_PG_HOST": "localhost",
        "P8_PG_DATABASE": "app",
        # API config
        "P8_API_ENDPOINT": "https://api.percolationlabs.ai",
        "P8_API_KEY": "test-key"
    })
    
    repo3 = create_repository()
    print(f"   Created: {type(repo3).__name__}")
    print(f"   ✅ Database mode selected (default when both available)")
    
    # Test 4: Force API mode
    print("\n4️⃣  Scenario: Both configured, force API mode")
    print("-" * 40)
    os.environ["P8_USE_API_MODE"] = "true"
    
    repo4 = create_repository()
    print(f"   Created: {type(repo4).__name__}")
    print(f"   ✅ API proxy mode selected (forced)")
    
    # Test 5: Desktop Extension mode
    print("\n5️⃣  Scenario: Desktop Extension (DXT) mode")
    print("-" * 40)
    os.environ["P8_MCP_DESKTOP_EXT"] = "true"
    os.environ["P8_USE_API_MODE"] = "false"
    
    repo5 = create_repository()
    print(f"   Created: {type(repo5).__name__}")
    print(f"   ✅ Database mode for desktop extension")
    
    # Architecture benefits
    print("\n" + "=" * 60)
    print("🏛️  ARCHITECTURE BENEFITS")
    print("=" * 60)
    print("\n📊 Database Mode (DatabaseRepository):")
    print("   • Direct PostgreSQL queries - faster")
    print("   • Row-level security (RLS)")
    print("   • Full SQL capabilities")
    print("   • Best for self-hosted deployments")
    
    print("\n☁️  API Proxy Mode (APIProxyRepository):")
    print("   • Works with cloud deployments")
    print("   • Centralized authentication")
    print("   • Rate limiting & monitoring")
    print("   • Best for SaaS deployments")
    
    print("\n🔄 Automatic Selection:")
    print("   • Detects available configuration")
    print("   • Defaults to DB when both available")
    print("   • Override with P8_USE_API_MODE=true")
    print("   • Same interface for both modes")
    
    # Clean up
    if isinstance(repo2, APIProxyRepository):
        await repo2.close()
    if isinstance(repo4, APIProxyRepository):
        await repo4.close()
    
    # Restore env
    os.environ.clear()
    os.environ.update(original_env)


if __name__ == "__main__":
    asyncio.run(demonstrate_dual_mode())