#!/usr/bin/env python3
"""
Test MCP server in stdio mode with proper JSON-RPC protocol.
"""

import os
import sys
import json
import subprocess
import asyncio
from pathlib import Path

# Add percolate to path
sys.path.insert(0, str(Path(__file__).parent / "clients/python/percolate"))

def create_json_rpc_message(id, method, params=None):
    """Create a proper JSON-RPC 2.0 message"""
    msg = {
        "jsonrpc": "2.0",
        "id": id,
        "method": method
    }
    if params is not None:
        msg["params"] = params
    return json.dumps(msg)

async def test_mcp_stdio():
    """Test MCP server in stdio mode with proper protocol"""
    
    # Configure environment
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
    
    print("🧪 Testing MCP Server in STDIO Mode")
    print("=" * 60)
    print(f"API Endpoint: {env['P8_API_ENDPOINT']}")
    print(f"User Email: {env['X_User_Email']}")
    
    # Start MCP server process
    cmd = [sys.executable, "-m", "percolate.api.mcp_server"]
    cwd = str(Path(__file__).parent / "clients/python/percolate")
    
    process = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        cwd=cwd,
        bufsize=1  # Line buffered
    )
    
    try:
        # Wait a bit for server to start
        await asyncio.sleep(0.5)
        
        # 1. Initialize
        print("\n1. Sending initialize request...")
        init_msg = create_json_rpc_message(
            1,
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "roots": {"listChanged": True},
                    "sampling": {}
                },
                "clientInfo": {
                    "name": "percolate-test",
                    "version": "1.0.0"
                }
            }
        )
        
        process.stdin.write(init_msg + "\n")
        process.stdin.flush()
        
        # Read response
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                server_info = data["result"]["serverInfo"]
                print(f"✅ Initialized: {server_info['name']} v{server_info['version']}")
                capabilities = data["result"]["capabilities"]
                print(f"   Capabilities: {list(capabilities.keys())}")
            else:
                print(f"❌ Initialize failed: {data}")
        
        # 2. List tools
        print("\n2. Listing tools...")
        tools_msg = create_json_rpc_message(2, "tools/list")  # No params
        process.stdin.write(tools_msg + "\n")
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                tools = data["result"]["tools"]
                print(f"✅ Found {len(tools)} tools:")
                for tool in tools:
                    print(f"   - {tool['name']}: {tool['description'][:50]}...")
            else:
                print(f"❌ List tools failed: {data}")
        
        # 3. Test help tool
        print("\n3. Testing help tool...")
        help_msg = create_json_rpc_message(
            3,
            "tools/call",
            {
                "name": "help",
                "arguments": {
                    "query": "What is the executive namespace used for?",
                    "context": "I want to understand ExecutiveResources",
                    "max_depth": 2
                }
            }
        )
        
        process.stdin.write(help_msg + "\n")
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                content = data["result"]["content"]
                if content and len(content) > 0:
                    text = content[0].get("text", "")
                    print(f"✅ Help response: {text[:150]}...")
            else:
                print(f"❌ Help tool failed: {data}")
        
        # 4. Test entity search
        print("\n4. Testing entity search...")
        search_msg = create_json_rpc_message(
            4,
            "tools/call",
            {
                "name": "entity_search", 
                "arguments": {
                    "query": "Executive",
                    "limit": 3
                }
            }
        )
        
        process.stdin.write(search_msg + "\n")
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                content = data["result"]["content"]
                if content and len(content) > 0:
                    text = content[0].get("text", "")
                    print(f"✅ Entity search response: {text[:150]}...")
            else:
                print(f"❌ Entity search failed: {data}")
        
        # 5. Test file upload
        print("\n5. Testing file upload...")
        upload_msg = create_json_rpc_message(
            5,
            "tools/call",
            {
                "name": "file_upload",
                "arguments": {
                    "file_content": "Test content for executive namespace via MCP stdio mode",
                    "filename": "mcp_executive_stdio_test.txt",
                    "namespace": "executive",
                    "entity_name": "ExecutiveResources",
                    "task_id": "mcp-stdio-test"
                }
            }
        )
        
        process.stdin.write(upload_msg + "\n")
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                content = data["result"]["content"]
                if content and len(content) > 0:
                    text = content[0].get("text", "")
                    print(f"✅ File upload response: {text[:150]}...")
            else:
                print(f"❌ File upload failed: {data}")
        
        # 6. Test function search
        print("\n6. Testing function search...")
        func_msg = create_json_rpc_message(
            6,
            "tools/call",
            {
                "name": "function_search",
                "arguments": {
                    "query": "search",
                    "limit": 3
                }
            }
        )
        
        process.stdin.write(func_msg + "\n")
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            data = json.loads(response)
            if "result" in data:
                content = data["result"]["content"]
                if content and len(content) > 0:
                    text = content[0].get("text", "")
                    print(f"✅ Function search response: {text[:150]}...")
            else:
                print(f"❌ Function search failed: {data}")
        
        # Clean shutdown
        print("\n7. Shutting down...")
        process.terminate()
        await asyncio.sleep(0.5)
        
        # Check for any errors
        stderr_output = process.stderr.read()
        if stderr_output and "ERROR" in stderr_output:
            print(f"\n⚠️  Server errors:\n{stderr_output}")
        
    except Exception as e:
        print(f"\n❌ Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

async def test_direct_api():
    """Test the API endpoints directly to verify they work"""
    print("\n" + "="*60)
    print("Testing Direct API Access")
    print("="*60)
    
    import httpx
    
    headers = {
        "Authorization": f"Bearer {os.environ.get('P8_TEST_BEARER_TOKEN', '')}",
        "X-User-Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "Content-Type": "application/json"
    }
    
    base_url = os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io")
    
    async with httpx.AsyncClient() as client:
        # Test auth
        print("\n1. Testing authentication...")
        response = await client.get(f"{base_url}/auth/ping", headers=headers)
        if response.status_code == 200:
            print(f"✅ Auth successful: {response.json()}")
        else:
            print(f"❌ Auth failed: {response.status_code}")
        
        # Test entity search
        print("\n2. Testing entity search API...")
        response = await client.get(
            f"{base_url}/entities/search",
            headers=headers,
            params={"query": "Executive", "limit": 3}
        )
        if response.status_code == 200:
            data = response.json()
            print(f"✅ Found {len(data)} entities")
        else:
            print(f"❌ Entity search failed: {response.status_code} - {response.text}")

async def main():
    """Run all tests"""
    print("🧪 Percolate MCP Server STDIO Mode Testing")
    print("=" * 60)
    
    # Test stdio mode
    await test_mcp_stdio()
    
    # Test direct API
    await test_direct_api()
    
    print("\n" + "="*60)
    print("✅ Testing Complete!")
    print("="*60)
    print("\nMCP Server Configuration:")
    print(f"- API: {os.environ.get('P8_TEST_DOMAIN', 'https://p8.resmagic.io')}")
    print(f"- User: {os.environ.get('X_User_Email', 'amartey@gmail.com')}")
    print("- Namespace: executive")
    print("- Entity: ExecutiveResources")
    print("- Agent: executive-ExecutiveResources")
    print("\nReady for Claude Desktop and DXT integration!")

if __name__ == "__main__":
    asyncio.run(main())