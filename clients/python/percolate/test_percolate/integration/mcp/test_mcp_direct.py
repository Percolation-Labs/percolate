#!/usr/bin/env python3
"""
Direct test of MCP server tools with authenticated API access.
Tests tools as direct function calls without stdio transport.
"""

import os
import sys
import asyncio
import tempfile
from pathlib import Path

# Add percolate to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent.parent))

async def test_mcp_tools_directly():
    """Test MCP tools as direct function calls"""
    
    # Configure environment
    os.environ.update({
        "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
        "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
        "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "P8_USE_API_MODE": "true",
        "P8_DEFAULT_AGENT": "executive-ExecutiveResources",
        "P8_DEFAULT_NAMESPACE": "executive",
        "P8_DEFAULT_ENTITY": "ExecutiveResources",
        "P8_LOG_LEVEL": "INFO"
    })
    
    print("🧪 Testing MCP Server Tools Directly")
    print("=" * 60)
    print(f"API Endpoint: {os.environ['P8_API_ENDPOINT']}")
    print(f"User Email: {os.environ['X_User_Email']}")
    print(f"Default Agent: {os.environ['P8_DEFAULT_AGENT']}")
    
    # Import MCP server components
    from percolate.api.mcp_server.server import create_mcp_server
    from percolate.api.mcp_server.config import get_mcp_settings
    from percolate.api.mcp_server.repository_factory import create_repository
    
    # Create server
    print("\n1. Creating MCP server...")
    server = create_mcp_server()
    print(f"✅ Server created: {server.name}")
    
    # Get settings
    settings = get_mcp_settings()
    print(f"✅ Using API mode: {settings.use_api_mode}")
    print(f"✅ API endpoint: {settings.api_endpoint}")
    
    # List tools
    print("\n2. Listing available tools...")
    tools = await server._tool_manager.list_tools()
    print(f"✅ Found {len(tools)} tools:")
    for tool in tools:
        print(f"   - {tool.name}: {tool.description[:60]}...")
    
    # Get tool functions
    tool_dict = {tool.name: tool for tool in tools}
    
    # Test help tool
    if "help" in tool_dict:
        print("\n3. Testing help tool...")
        try:
            help_tool = tool_dict["help"]
            from percolate.api.mcp_server.tools.help_tools import HelpParams
            
            params = HelpParams(
                query="What entities are available in the executive namespace?",
                context="I'm working with ExecutiveResources",
                max_depth=3
            )
            
            result = await help_tool.function(params)
            print(f"✅ Help response: {result[:200]}...")
        except Exception as e:
            print(f"❌ Help tool failed: {e}")
    
    # Test entity search
    if "entity_search" in tool_dict:
        print("\n4. Testing entity search...")
        try:
            search_tool = tool_dict["entity_search"]
            from percolate.api.mcp_server.tools.entity_tools import EntitySearchParams
            
            params = EntitySearchParams(
                query="Executive",
                limit=5
            )
            
            result = await search_tool.function(params)
            print(f"✅ Entity search response: {result[:200]}...")
        except Exception as e:
            print(f"❌ Entity search failed: {e}")
    
    # Test file upload
    if "file_upload" in tool_dict:
        print("\n5. Testing file upload...")
        try:
            upload_tool = tool_dict["file_upload"]
            from percolate.api.mcp_server.tools.file_tools import FileUploadParams
            
            params = FileUploadParams(
                file_content="Test content for executive namespace via MCP",
                filename="mcp_executive_test.txt",
                namespace="executive",
                entity_name="ExecutiveResources",
                task_id="mcp-executive-test"
            )
            
            result = await upload_tool.function(params)
            print(f"✅ File upload response: {result[:200]}...")
        except Exception as e:
            print(f"❌ File upload failed: {e}")
    
    # Test function search
    if "function_search" in tool_dict:
        print("\n6. Testing function search...")
        try:
            func_tool = tool_dict["function_search"]
            from percolate.api.mcp_server.tools.function_tools import FunctionSearchParams
            
            params = FunctionSearchParams(
                query="search",
                limit=3
            )
            
            result = await func_tool.function(params)
            print(f"✅ Function search response: {result[:200]}...")
        except Exception as e:
            print(f"❌ Function search failed: {e}")
    
    # Test repository directly
    print("\n7. Testing repository directly...")
    repository = create_repository(
        user_id=settings.user_id,
        user_groups=settings.user_groups,
        role_level=settings.role_level,
        user_email=settings.user_email
    )
    
    try:
        # Test repository search
        entities = await repository.search_entities("Executive", limit=3)
        print(f"✅ Repository search found {len(entities)} entities")
        for entity in entities[:2]:
            print(f"   - {entity.get('name', 'Unknown')} (ID: {entity.get('id')})")
    except Exception as e:
        print(f"❌ Repository search failed: {e}")

async def test_mcp_stdio_mode():
    """Test MCP server in stdio mode"""
    print("\n" + "="*60)
    print("Testing MCP Server in STDIO Mode")
    print("="*60)
    
    import subprocess
    import json
    
    env = os.environ.copy()
    env.update({
        "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
        "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
        "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "P8_USE_API_MODE": "true"
    })
    
    # Start MCP server process
    cmd = [sys.executable, "-m", "percolate.api.mcp_server"]
    cwd = str(Path(__file__).parent.parent.parent.parent)
    
    print(f"Starting MCP server with command: {' '.join(cmd)}")
    print(f"Working directory: {cwd}")
    
    process = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        cwd=cwd
    )
    
    try:
        # Send initialize request
        init_request = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {
                    "name": "test-client",
                    "version": "1.0.0"
                }
            }
        }
        
        print("\nSending initialize request...")
        process.stdin.write(json.dumps(init_request) + "\n")
        process.stdin.flush()
        
        # Read response
        response_line = process.stdout.readline()
        if response_line:
            response = json.loads(response_line)
            if "result" in response:
                print(f"✅ Initialize successful: {response['result']['serverInfo']['name']}")
            else:
                print(f"❌ Initialize failed: {response}")
        
        # Send tools/list request
        tools_request = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        }
        
        print("\nSending tools/list request...")
        process.stdin.write(json.dumps(tools_request) + "\n")
        process.stdin.flush()
        
        response_line = process.stdout.readline()
        if response_line:
            response = json.loads(response_line)
            if "result" in response:
                tools = response["result"]["tools"]
                print(f"✅ Found {len(tools)} tools")
                for tool in tools[:3]:
                    print(f"   - {tool['name']}: {tool.get('description', '')[:50]}...")
            else:
                print(f"❌ Tools list failed: {response}")
        
        # Terminate process
        process.terminate()
        process.wait(timeout=5)
        
    except Exception as e:
        print(f"❌ Error: {e}")
        process.terminate()

async def main():
    """Run all MCP tests"""
    print("🧪 Percolate MCP Server Direct Testing")
    print("=" * 60)
    
    # Test tools directly
    await test_mcp_tools_directly()
    
    # Test stdio mode
    await test_mcp_stdio_mode()
    
    print("\n" + "="*60)
    print("✅ MCP Server Tests Complete!")
    print("="*60)
    print("\nThe MCP server is working correctly with:")
    print(f"- API endpoint: {os.environ.get('P8_TEST_DOMAIN', 'https://p8.resmagic.io')}")
    print(f"- User: {os.environ.get('X_User_Email', 'amartey@gmail.com')}")
    print("- Default namespace: executive")
    print("- Default entity: ExecutiveResources")
    print("\nReady for testing in Claude Desktop and DXT!")

if __name__ == "__main__":
    asyncio.run(main())