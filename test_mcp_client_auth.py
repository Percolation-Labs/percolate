#!/usr/bin/env python3
"""
Test MCP server with authenticated API access using FastMCP client.
Tests both local and remote API endpoints with proper authentication.
"""

import os
import sys
import asyncio
import tempfile
from pathlib import Path

# Add percolate to Python path
sys.path.insert(0, str(Path(__file__).parent / "clients/python/percolate"))

async def test_mcp_with_api_auth(use_remote=True):
    """Test MCP server with API authentication"""
    from fastmcp.client import Client, PythonStdioTransport
    
    # Configure environment for API mode
    env = os.environ.copy()
    
    if use_remote:
        print("🌐 Testing with Remote API")
        env.update({
            "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
            "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
            "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
            "P8_USE_API_MODE": "true",
            "P8_DEFAULT_AGENT": "executive-ExecutiveResources",
            "P8_DEFAULT_NAMESPACE": "executive", 
            "P8_DEFAULT_ENTITY": "ExecutiveResources",
            "P8_LOG_LEVEL": "INFO"
        })
    else:
        print("🏠 Testing with Local API")
        env.update({
            "P8_API_ENDPOINT": "http://localhost:5008",
            "P8_API_KEY": "postgres",
            "X_User_Email": "amartey@gmail.com",
            "P8_USE_API_MODE": "true",
            "P8_DEFAULT_AGENT": "executive-ExecutiveResources",
            "P8_DEFAULT_NAMESPACE": "executive",
            "P8_DEFAULT_ENTITY": "ExecutiveResources",
            "P8_LOG_LEVEL": "INFO"
        })
    
    print(f"API Endpoint: {env['P8_API_ENDPOINT']}")
    print(f"User Email: {env['X_User_Email']}")
    print(f"Default Agent: {env['P8_DEFAULT_AGENT']}")
    
    # Create transport for stdio mode
    transport = PythonStdioTransport(
        script_path=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env,
        cwd=str(Path(__file__).parent / "clients/python/percolate")
    )
    
    # Create MCP client
    client = Client(transport=transport)
    
    try:
        # Connect to server
        print("\n1. Connecting to MCP server...")
        await client.connect()
        print("✅ Connected to MCP server")
        
        # List available tools
        print("\n2. Listing available tools...")
        tools = await client.list_tools()
        print(f"✅ Found {len(tools)} tools:")
        for tool in tools:
            print(f"   - {tool['name']}: {tool.get('description', 'No description')[:60]}...")
        
        # Test help tool
        print("\n3. Testing help tool...")
        try:
            help_result = await client.call_tool(
                "help",
                {
                    "query": "What entities are available in the executive namespace?",
                    "context": "I want to understand the ExecutiveResources entity",
                    "max_depth": 3
                }
            )
            print(f"✅ Help tool response: {str(help_result)[:200]}...")
        except Exception as e:
            print(f"❌ Help tool failed: {e}")
        
        # Test entity search
        print("\n4. Testing entity search...")
        try:
            search_result = await client.call_tool(
                "entity_search", 
                {
                    "query": "Executive",
                    "limit": 5
                }
            )
            print(f"✅ Entity search result: {str(search_result)[:200]}...")
        except Exception as e:
            print(f"❌ Entity search failed: {e}")
        
        # Test file upload
        print("\n5. Testing file upload...")
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            f.write("Test content for MCP file upload to executive namespace")
            test_file = f.name
        
        try:
            # Read file content for upload
            with open(test_file, 'r') as f:
                file_content = f.read()
            
            upload_result = await client.call_tool(
                "file_upload",
                {
                    "file_content": file_content,
                    "filename": "mcp_test_executive.txt",
                    "namespace": env['P8_DEFAULT_NAMESPACE'],
                    "entity_name": env['P8_DEFAULT_ENTITY'],
                    "task_id": "mcp-executive-test"
                }
            )
            print(f"✅ File upload result: {str(upload_result)[:200]}...")
        except Exception as e:
            print(f"❌ File upload failed: {e}")
        finally:
            # Clean up test file
            if os.path.exists(test_file):
                os.unlink(test_file)
        
        # Test function search
        print("\n6. Testing function search...")
        try:
            function_result = await client.call_tool(
                "function_search",
                {
                    "query": "search",
                    "limit": 3
                }
            )
            print(f"✅ Function search result: {str(function_result)[:200]}...")
        except Exception as e:
            print(f"❌ Function search failed: {e}")
        
    except Exception as e:
        print(f"\n❌ Error during testing: {e}")
        import traceback
        traceback.print_exc()
    finally:
        print("\n7. Disconnecting...")
        await client.disconnect()
        print("✅ Disconnected from MCP server")

async def test_direct_tool_functions():
    """Test MCP tools as direct function calls"""
    print("\n" + "="*60)
    print("TESTING DIRECT TOOL FUNCTION CALLS")
    print("="*60)
    
    # Set up environment
    os.environ.update({
        "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
        "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
        "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "P8_USE_API_MODE": "true"
    })
    
    # Import and create server components
    from percolate.api.mcp_server.server import create_mcp_server
    from percolate.api.mcp_server.repository_factory import create_repository
    from percolate.api.mcp_server.config import get_mcp_settings
    
    print("\n1. Creating MCP server components...")
    settings = get_mcp_settings()
    print(f"   API Endpoint: {settings.api_endpoint}")
    print(f"   User Email: {settings.user_email}")
    
    # Create repository
    repository = create_repository(
        user_id=settings.user_id,
        user_groups=settings.user_groups,
        role_level=settings.role_level,
        user_email=settings.user_email
    )
    
    # Test repository methods directly
    print("\n2. Testing repository methods directly...")
    
    try:
        # Test help
        print("   Testing get_help...")
        help_result = await repository.get_help(
            "What is Percolate?",
            "I'm a new user",
            max_depth=2
        )
        print(f"   ✅ Help result: {help_result[:100]}...")
    except Exception as e:
        print(f"   ❌ Help failed: {e}")
    
    try:
        # Test entity search
        print("\n   Testing search_entities...")
        entities = await repository.search_entities(
            "Executive",
            filters=None,
            limit=3
        )
        print(f"   ✅ Found {len(entities)} entities")
        for entity in entities[:2]:
            print(f"      - {entity.get('name', 'Unknown')} ({entity.get('id', 'N/A')})")
    except Exception as e:
        print(f"   ❌ Entity search failed: {e}")
    
    try:
        # Test function search
        print("\n   Testing search_functions...")
        functions = await repository.search_functions("search", limit=3)
        print(f"   ✅ Found {len(functions)} functions")
        for func in functions[:2]:
            print(f"      - {func.get('name', 'Unknown')}")
    except Exception as e:
        print(f"   ❌ Function search failed: {e}")

async def main():
    """Run all MCP authentication tests"""
    print("🧪 Percolate MCP Server Authentication Tests")
    print("=" * 60)
    
    # Test with FastMCP client
    print("\n📡 TESTING WITH FASTMCP CLIENT")
    print("=" * 60)
    
    # Test remote API
    await test_mcp_with_api_auth(use_remote=True)
    
    # Test local API (if available)
    # await test_mcp_with_api_auth(use_remote=False)
    
    # Test direct function calls
    await test_direct_tool_functions()
    
    print("\n" + "="*60)
    print("🎉 MCP AUTHENTICATION TESTS COMPLETE")
    print("="*60)
    print("\nNext steps:")
    print("1. Configure Claude Desktop with MCP settings")
    print("2. Test in DXT (Desktop Extension)")  
    print("3. Verify executive-ExecutiveResources agent works")
    print("4. Test file uploads to executive namespace")

if __name__ == "__main__":
    asyncio.run(main())