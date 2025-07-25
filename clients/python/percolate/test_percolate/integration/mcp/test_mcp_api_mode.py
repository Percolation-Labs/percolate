#!/usr/bin/env python
"""Test MCP server in API proxy mode"""

import asyncio
import os
import sys
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport

# Test both database and API modes
async def test_mcp_modes():
    """Test MCP server in both database and API proxy modes"""
    
    print("🧪 Testing MCP Server Modes")
    print("=" * 60)
    
    # Save original env
    original_env = os.environ.copy()
    
    # Test 1: Database Mode (default)
    print("\n1️⃣ Testing Database Mode")
    print("-" * 30)
    
    # Set up database mode environment
    env_db = original_env.copy()
    env_db.update({
        "P8_PG_HOST": "localhost",
        "P8_PG_PORT": "5432",
        "P8_PG_DATABASE": "app",
        "P8_PG_USER": os.getenv("P8_PG_USER", "postgres"),
        "P8_PG_PASSWORD": os.getenv("P8_PG_PASSWORD", ""),
        "P8_USER_EMAIL": "test@percolate.ai",
        "P8_LOG_LEVEL": "INFO"
    })
    
    # Remove API settings to force DB mode
    env_db.pop("P8_API_KEY", None)
    env_db.pop("P8_API_ENDPOINT", None)
    
    success_db = await test_mode("Database", env_db)
    
    # Test 2: API Proxy Mode
    print("\n2️⃣ Testing API Proxy Mode")
    print("-" * 30)
    
    # Check if API is running
    api_endpoint = os.getenv("P8_API_ENDPOINT", "http://localhost:5008")
    api_key = os.getenv("P8_API_KEY")
    
    if not api_key:
        print("⚠️  No P8_API_KEY found - skipping API mode test")
        print("   Set P8_API_KEY to test API proxy mode")
        success_api = False
    else:
        # Set up API mode environment
        env_api = original_env.copy()
        env_api.update({
            "P8_API_ENDPOINT": api_endpoint,
            "P8_API_KEY": api_key,
            "P8_USER_EMAIL": os.getenv("P8_USER_EMAIL", "test@percolate.ai"),
            "P8_USE_API_MODE": "true",  # Force API mode
            "P8_LOG_LEVEL": "INFO"
        })
        
        # Remove DB settings to ensure API mode
        for key in ["P8_PG_HOST", "P8_PG_PORT", "P8_PG_DATABASE", "P8_PG_USER", "P8_PG_PASSWORD"]:
            env_api.pop(key, None)
        
        success_api = await test_mode("API Proxy", env_api)
    
    # Summary
    print("\n" + "=" * 60)
    print("📊 TEST SUMMARY")
    print("=" * 60)
    print(f"✅ Database Mode: {'PASSED' if success_db else 'FAILED'}")
    print(f"{'✅' if success_api else '⚠️'} API Proxy Mode: {'PASSED' if success_api else 'SKIPPED/FAILED'}")
    
    if success_db and success_api:
        print("\n🎉 Both modes working correctly!")
    elif success_db:
        print("\n✅ Database mode working. API mode needs attention.")
    else:
        print("\n⚠️  Issues detected. Check logs above.")


async def test_mode(mode_name: str, env: dict) -> bool:
    """Test a specific MCP mode"""
    try:
        # Create transport with environment
        runner_script = Path("percolate/api/mcp_server/tests/run_server.py")
        transport = PythonStdioTransport(
            script_path=runner_script,
            env=env
        )
        
        # Use client as context manager
        async with Client(transport=transport) as client:
            print(f"✅ Connected to MCP server in {mode_name} mode")
            
            # Test entity retrieval
            try:
                result = await client.call_tool(
                    "get_entity",
                    {
                        "params": {
                            "entity_id": "96d1a2ff-045b-55cc-a7de-543d1d3cccf8",
                            "entity_type": "Agent"
                        }
                    }
                )
                
                data = result.structured_content.get('result', result.data) if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, dict) and "error" not in data:
                    print(f"✅ Entity retrieval working: {data.get('name', 'Unknown')}")
                else:
                    print(f"❌ Entity retrieval failed: {data}")
                    return False
                    
            except Exception as e:
                print(f"❌ Entity test error: {e}")
                return False
            
            # Test function search
            try:
                result = await client.call_tool(
                    "function_search",
                    {
                        "params": {
                            "query": "pet",
                            "limit": 2
                        }
                    }
                )
                
                data = result.structured_content.get('result', result.data) if hasattr(result, 'structured_content') else result.data
                
                if isinstance(data, list):
                    print(f"✅ Function search working: Found {len(data)} functions")
                else:
                    print(f"❌ Function search failed")
                    return False
                    
            except Exception as e:
                print(f"❌ Function search error: {e}")
                return False
            
            print(f"✅ All tests passed for {mode_name} mode")
            return True
            
    except Exception as e:
        print(f"❌ Failed to connect in {mode_name} mode: {e}")
        return False


async def test_api_endpoints():
    """Quick test to verify API is accessible"""
    import httpx
    
    api_endpoint = os.getenv("P8_API_ENDPOINT", "http://localhost:5008")
    api_key = os.getenv("P8_API_KEY")
    
    if not api_key:
        print("⚠️  No API key - skipping API endpoint test")
        return False
    
    print(f"\n🔍 Checking API endpoint: {api_endpoint}")
    
    headers = {
        "Authorization": f"Bearer {api_key}",
        "X-User-Email": os.getenv("P8_USER_EMAIL", "test@percolate.ai")
    }
    
    async with httpx.AsyncClient() as client:
        try:
            # Test auth endpoint
            response = await client.get(f"{api_endpoint}/auth/me", headers=headers)
            if response.status_code == 200:
                print("✅ API authentication working")
                return True
            else:
                print(f"❌ API auth failed: {response.status_code}")
                return False
        except Exception as e:
            print(f"❌ Cannot reach API: {e}")
            return False


if __name__ == "__main__":
    # First check if API is reachable
    api_ok = asyncio.run(test_api_endpoints())
    
    # Then run MCP tests
    asyncio.run(test_mcp_modes())