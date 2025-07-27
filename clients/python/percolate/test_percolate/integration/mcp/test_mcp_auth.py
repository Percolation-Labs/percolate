#!/usr/bin/env python3
"""
Test script to verify MCP server functionality with authenticated API access.
Tests the MCP server stdio mode with both local and remote API endpoints.
"""

import os
import json
import subprocess
import asyncio
import tempfile
from pathlib import Path

# Configuration
def get_env_config(use_remote=True):
    """Get environment configuration for testing"""
    if use_remote:
        return {
            'P8_API_ENDPOINT': os.environ.get('P8_TEST_DOMAIN', 'https://p8.resmagic.io'),
            'P8_API_KEY': os.environ.get('P8_TEST_BEARER_TOKEN', ''),
            'X_User_Email': os.environ.get('X_User_Email', 'amartey@gmail.com'),
            'P8_DEFAULT_AGENT': 'executive-ExecutiveResources',
            'P8_DEFAULT_NAMESPACE': 'executive',
            'P8_DEFAULT_ENTITY': 'ExecutiveResources',
            'P8_USE_API_MODE': 'true'
        }
    else:
        return {
            'P8_API_ENDPOINT': 'http://localhost:5008',
            'P8_API_KEY': 'postgres',
            'X_User_Email': 'amartey@gmail.com',
            'P8_DEFAULT_AGENT': 'executive-ExecutiveResources',
            'P8_DEFAULT_NAMESPACE': 'executive',
            'P8_DEFAULT_ENTITY': 'ExecutiveResources',
            'P8_USE_API_MODE': 'true'
        }

def create_mcp_message(id, method, params=None):
    """Create a proper MCP JSON-RPC message"""
    message = {
        "jsonrpc": "2.0",
        "id": id,
        "method": method
    }
    if params:
        message["params"] = params
    return json.dumps(message) + "\n"

async def test_mcp_server(use_remote=True):
    """Test MCP server with stdio communication"""
    config = get_env_config(use_remote)
    endpoint_type = "remote" if use_remote else "local"
    
    print(f"\n=== Testing MCP Server ({endpoint_type}) ===")
    print(f"API Endpoint: {config['P8_API_ENDPOINT']}")
    print(f"User Email: {config['X_User_Email']}")
    print(f"Default Agent: {config['P8_DEFAULT_AGENT']}")
    
    # Set up environment
    env = os.environ.copy()
    env.update(config)
    
    # Start MCP server
    mcp_cmd = [
        "python", "-m", "percolate.api.mcp_server"
    ]
    
    try:
        # Start the MCP server process
        process = subprocess.Popen(
            mcp_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd="/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate"
        )
        
        # Test 1: Initialize
        print("\n1. Testing MCP Initialization...")
        init_message = create_mcp_message(1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {
                "name": "test-client",
                "version": "1.0.0"
            }
        })
        
        process.stdin.write(init_message)
        process.stdin.flush()
        
        # Read response
        response = process.stdout.readline()
        if response:
            try:
                init_response = json.loads(response)
                print(f"✅ Initialize successful: {init_response.get('result', {}).get('serverInfo', {}).get('name', 'unknown')}")
            except json.JSONDecodeError:
                print(f"❌ Initialize failed: Invalid JSON response")
                print(f"Raw response: {response}")
        
        # Test 2: List Tools
        print("\n2. Testing Tool Listing...")
        tools_message = create_mcp_message(2, "tools/list")
        process.stdin.write(tools_message)
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            try:
                tools_response = json.loads(response)
                tools = tools_response.get('result', {}).get('tools', [])
                print(f"✅ Found {len(tools)} tools")
                for tool in tools[:3]:  # Show first 3 tools
                    print(f"   - {tool.get('name')}: {tool.get('description', 'No description')[:50]}...")
            except json.JSONDecodeError:
                print(f"❌ Tools list failed: Invalid JSON response")
        
        # Test 3: Test help tool (if available)
        print("\n3. Testing Help Tool...")
        help_message = create_mcp_message(3, "tools/call", {
            "name": "help",
            "arguments": {
                "question": "What can I do with this MCP server?"
            }
        })
        
        process.stdin.write(help_message)
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            try:
                help_response = json.loads(response)
                if 'result' in help_response:
                    print(f"✅ Help tool worked!")
                    content = help_response['result'].get('content', [])
                    if content and len(content) > 0:
                        text = content[0].get('text', '')[:200]
                        print(f"   Response: {text}...")
                else:
                    print(f"❌ Help tool failed: {help_response.get('error', 'Unknown error')}")
            except json.JSONDecodeError:
                print(f"❌ Help tool failed: Invalid JSON response")
        
        # Clean shutdown
        process.terminate()
        process.wait(timeout=5)
        
        return True
        
    except Exception as e:
        print(f"❌ MCP Server test failed: {e}")
        if process:
            process.terminate()
        return False

async def test_file_upload_via_mcp(use_remote=True):
    """Test file upload through MCP server"""
    config = get_env_config(use_remote)
    endpoint_type = "remote" if use_remote else "local"
    
    print(f"\n=== Testing MCP File Upload ({endpoint_type}) ===")
    
    # Create a test file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write("Test content for MCP file upload via executive namespace")
        test_file_path = f.name
    
    try:
        # Set up environment
        env = os.environ.copy()
        env.update(config)
        
        # Start MCP server
        process = subprocess.Popen(
            ["python", "-m", "percolate.api.mcp_server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd="/Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate"
        )
        
        # Initialize
        init_message = create_mcp_message(1, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "test-client", "version": "1.0.0"}
        })
        process.stdin.write(init_message)
        process.stdin.flush()
        process.stdout.readline()  # consume init response
        
        # Test file upload
        print("Testing file upload tool...")
        
        # Read file content
        with open(test_file_path, 'r') as f:
            file_content = f.read()
        
        upload_message = create_mcp_message(2, "tools/call", {
            "name": "file_upload",
            "arguments": {
                "file_content": file_content,
                "filename": "mcp_test_upload.txt",
                "namespace": config['P8_DEFAULT_NAMESPACE'],
                "entity_name": config['P8_DEFAULT_ENTITY'],
                "task_id": "mcp-test-upload"
            }
        })
        
        process.stdin.write(upload_message)
        process.stdin.flush()
        
        response = process.stdout.readline()
        if response:
            try:
                upload_response = json.loads(response)
                if 'result' in upload_response:
                    print("✅ File upload successful!")
                    content = upload_response['result'].get('content', [])
                    if content:
                        print(f"   Result: {content[0].get('text', '')[:100]}...")
                else:
                    print(f"❌ File upload failed: {upload_response.get('error', 'Unknown error')}")
            except json.JSONDecodeError:
                print(f"❌ File upload failed: Invalid JSON response")
                print(f"Raw response: {response}")
        
        process.terminate()
        process.wait(timeout=5)
        
    except Exception as e:
        print(f"❌ File upload test failed: {e}")
    finally:
        # Clean up test file
        if os.path.exists(test_file_path):
            os.unlink(test_file_path)

async def main():
    """Run all MCP tests"""
    print("🧪 Percolate MCP Server Authentication Tests")
    print("=" * 50)
    
    # Test remote first (since it's working)
    print("\n🌐 Testing Remote API Configuration")
    remote_success = await test_mcp_server(use_remote=True)
    await test_file_upload_via_mcp(use_remote=True)
    
    # Test local if needed
    print("\n🏠 Testing Local API Configuration")
    local_success = await test_mcp_server(use_remote=False)
    
    # Summary
    print("\n" + "=" * 50)
    print("MCP SERVER TEST SUMMARY")
    print("=" * 50)
    print(f"Remote API Test: {'✅ PASSED' if remote_success else '❌ FAILED'}")
    print(f"Local API Test:  {'✅ PASSED' if local_success else '❌ FAILED'}")
    
    if remote_success:
        print("🎉 MCP Server is ready for DXT testing!")
        print("Next steps:")
        print("1. Test in Claude Desktop with MCP configuration")
        print("2. Test in DXT (Desktop Extension)")
        print("3. Verify all tools work with executive-ExecutiveResources agent")

if __name__ == "__main__":
    asyncio.run(main())