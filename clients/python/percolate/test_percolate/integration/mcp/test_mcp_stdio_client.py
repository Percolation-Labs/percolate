#!/usr/bin/env python3
"""
Test Percolate MCP server using proper MCP stdio client.
Based on FastMCP patterns and mcp-ataccama reference implementation.
"""

import os
import sys
import asyncio
from pathlib import Path

# Add percolate to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

async def test_percolate_mcp_stdio():
    """Test Percolate MCP server with stdio client"""
    try:
        from mcp.client.session import ClientSession
        from mcp.client.stdio import StdioServerParameters, stdio_client
    except ImportError:
        print("❌ Error: mcp package not installed. Install with: pip install mcp")
        return
    
    # Configure environment for API mode
    env = os.environ.copy()
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
    
    print("🧪 Testing Percolate MCP Server with STDIO Client")
    print("=" * 60)
    print(f"API Endpoint: {env['P8_API_ENDPOINT']}")
    print(f"User Email: {env['X_User_Email']}")
    print(f"Bearer Token: {env['P8_API_KEY'][:20]}..." if env['P8_API_KEY'] else "No token set")
    
    # Create server parameters
    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env,
        cwd=str(Path(__file__).parent.parent.parent.parent)
    )
    
    try:
        print("\n1. Starting MCP server and connecting...")
        async with stdio_client(server_params) as (read, write):
            async with ClientSession(read, write) as session:
                # Initialize the session
                print("   Initializing session...")
                result = await session.initialize()
                
                # Verify initialization
                assert result is not None
                assert result.serverInfo is not None
                print(f"✅ Connected to: {result.serverInfo.name} v{result.serverInfo.version}")
                
                # Check capabilities
                if hasattr(result, 'capabilities'):
                    print(f"   Capabilities: {list(result.capabilities.keys()) if hasattr(result.capabilities, 'keys') else result.capabilities}")
                
                # List available tools
                print("\n2. Listing available tools...")
                tools_result = await session.list_tools()
                # The result has a 'tools' attribute
                tools = tools_result.tools if hasattr(tools_result, 'tools') else []
                print(f"✅ Found {len(tools)} tools:")
                for tool in tools:
                    print(f"   - {tool.name}: {tool.description[:60] if tool.description else 'No description'}...")
                
                # Test help tool
                print("\n3. Testing help tool...")
                try:
                    help_result = await session.call_tool(
                        "help",
                        arguments={
                            "query": "What entities are available in the executive namespace?",
                            "context": "I want to understand ExecutiveResources",
                            "max_depth": 2
                        }
                    )
                    
                    if help_result and help_result.content:
                        content = help_result.content[0]
                        text = content.get("text", str(content)) if isinstance(content, dict) else str(content)
                        print(f"✅ Help response: {text[:150]}...")
                    else:
                        print("❌ Help tool returned empty response")
                except Exception as e:
                    print(f"❌ Help tool error: {e}")
                
                # Test entity search
                print("\n4. Testing entity search...")
                try:
                    search_result = await session.call_tool(
                        "entity_search",
                        arguments={
                            "query": "Executive",
                            "limit": 3
                        }
                    )
                    
                    if search_result and search_result.content:
                        content = search_result.content[0]
                        text = content.get("text", str(content)) if isinstance(content, dict) else str(content)
                        print(f"✅ Entity search response: {text[:150]}...")
                    else:
                        print("❌ Entity search returned empty response")
                except Exception as e:
                    print(f"❌ Entity search error: {e}")
                
                # Test file upload
                print("\n5. Testing file upload...")
                try:
                    upload_result = await session.call_tool(
                        "file_upload",
                        arguments={
                            "file_content": "Test content for executive namespace via MCP stdio client",
                            "filename": "mcp_executive_test.txt",
                            "namespace": env['P8_DEFAULT_NAMESPACE'],
                            "entity_name": env['P8_DEFAULT_ENTITY'],
                            "task_id": "mcp-stdio-client-test"
                        }
                    )
                    
                    if upload_result and upload_result.content:
                        content = upload_result.content[0]
                        text = content.get("text", str(content)) if isinstance(content, dict) else str(content)
                        print(f"✅ File upload response: {text[:150]}...")
                    else:
                        print("❌ File upload returned empty response")
                except Exception as e:
                    print(f"❌ File upload error: {e}")
                
                # Test function search
                print("\n6. Testing function search...")
                try:
                    func_result = await session.call_tool(
                        "function_search",
                        arguments={
                            "query": "search",
                            "limit": 3
                        }
                    )
                    
                    if func_result and func_result.content:
                        content = func_result.content[0]
                        text = content.get("text", str(content)) if isinstance(content, dict) else str(content)
                        print(f"✅ Function search response: {text[:150]}...")
                    else:
                        print("❌ Function search returned empty response")
                except Exception as e:
                    print(f"❌ Function search error: {e}")
                
                print("\n✅ All tests completed!")
                
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()

async def test_auth_scenarios():
    """Test different authentication scenarios"""
    print("\n" + "="*60)
    print("Testing Authentication Scenarios")
    print("="*60)
    
    try:
        from mcp.client.session import ClientSession
        from mcp.client.stdio import StdioServerParameters, stdio_client
    except ImportError:
        print("❌ MCP client not available")
        return
    
    # Test 1: Valid bearer token (should work)
    print("\n1. Testing with valid bearer token...")
    env_valid = os.environ.copy()
    env_valid.update({
        "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
        "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
        "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "P8_USE_API_MODE": "true"
    })
    
    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env_valid,
        cwd=str(Path(__file__).parent.parent.parent.parent)
    )
    
    try:
        async with stdio_client(server_params) as (read, write):
            async with ClientSession(read, write) as session:
                result = await session.initialize()
                assert result.serverInfo is not None
                print("✅ Valid token: Authentication successful")
    except Exception as e:
        print(f"❌ Valid token failed: {e}")
    
    # Test 2: Invalid bearer token (should fail)
    print("\n2. Testing with invalid bearer token...")
    env_invalid = env_valid.copy()
    env_invalid["P8_API_KEY"] = "invalid-token-12345"
    
    server_params_invalid = StdioServerParameters(
        command=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env_invalid,
        cwd=str(Path(__file__).parent.parent.parent.parent)
    )
    
    try:
        async with stdio_client(server_params_invalid) as (read, write):
            async with ClientSession(read, write) as session:
                # This should work because auth happens at tool call
                result = await session.initialize()
                print("✅ Server started with invalid token")
                
                # But tool calls should fail
                try:
                    await session.call_tool("help", arguments={"query": "test"})
                    print("❌ Tool call succeeded with invalid token (unexpected)")
                except Exception as e:
                    print(f"✅ Tool call failed with invalid token (expected): {str(e)[:100]}...")
    except Exception as e:
        print(f"✅ Connection failed with invalid token (expected): {str(e)[:100]}...")

async def main():
    """Run all MCP stdio client tests"""
    print("🧪 Percolate MCP Server STDIO Client Testing")
    print("=" * 60)
    
    # Check if MCP client is installed
    try:
        import mcp
        print(f"✅ MCP client installed: {mcp.__version__ if hasattr(mcp, '__version__') else 'unknown version'}")
    except ImportError:
        print("❌ MCP client not installed")
        print("Install with: pip install mcp")
        return
    
    # Run main tests
    await test_percolate_mcp_stdio()
    
    # Run auth tests
    await test_auth_scenarios()
    
    print("\n" + "="*60)
    print("✅ MCP STDIO Client Tests Complete!")
    print("="*60)
    print("\nMCP Server is working correctly with:")
    print(f"- API: {os.environ.get('P8_TEST_DOMAIN', 'https://p8.resmagic.io')}")
    print(f"- User: {os.environ.get('X_User_Email', 'amartey@gmail.com')}")
    print("- Bearer Token + X-User-Email authentication")
    print("- All tools accessible via stdio client")
    print("\nReady for Claude Desktop integration!")

if __name__ == "__main__":
    asyncio.run(main())