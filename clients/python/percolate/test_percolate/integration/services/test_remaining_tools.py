#!/usr/bin/env python
"""Test remaining MCP tools: file upload, resource search, and help"""

import asyncio
import tempfile
import os
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport

async def test_remaining_tools():
    """Test file upload, resource search, and help functionality"""
    # Set up environment
    env = os.environ.copy()
    
    # Create transport
    runner_script = Path("percolate/api/mcp_server/tests/run_server.py")
    transport = PythonStdioTransport(
        script_path=runner_script,
        env=env
    )
    
    # Use client as context manager
    async with Client(transport=transport) as client:
        print("Connected to MCP server\n")
        
        # Test 1: Help functionality
        print("=== Testing Help Functionality ===")
        try:
            result = await client.call_tool(
                "help",
                {
                    "params": {
                        "query": "How do I search for functions?",
                        "context": "I'm trying to use the MCP server",
                        "max_depth": 3
                    }
                }
            )
            
            # Access the actual structured data from FastMCP result
            if hasattr(result, 'structured_content') and 'result' in result.structured_content:
                data = result.structured_content['result']
            else:
                data = result.data if hasattr(result, 'data') else result
            
            print(f"Help result type: {type(data)}")
            if isinstance(data, str):
                print(f"Help response: {data[:200]}...")
            else:
                print(f"Help response: {data}")
                
        except Exception as e:
            print(f"Help test error: {e}")
        
        # Test 2: Resource Search
        print("\n=== Testing Resource Search ===")
        try:
            result = await client.call_tool(
                "resource_search",
                {
                    "params": {
                        "query": "documentation",
                        "resource_type": "text",
                        "limit": 5
                    }
                }
            )
            
            # Access the actual structured data from FastMCP result
            if hasattr(result, 'structured_content') and 'result' in result.structured_content:
                data = result.structured_content['result']
            else:
                data = result.data if hasattr(result, 'data') else result
            
            print(f"Resource search result type: {type(data)}")
            if isinstance(data, list):
                print(f"Found {len(data)} resources")
                for i, resource in enumerate(data[:3]):
                    if isinstance(resource, dict):
                        print(f"  {i+1}. {resource.get('name', 'N/A')} - {resource.get('description', 'N/A')[:50]}...")
            else:
                print(f"Resource search response: {data}")
                
        except Exception as e:
            print(f"Resource search test error: {e}")
        
        # Test 3: File Upload
        print("\n=== Testing File Upload ===")
        try:
            # Create a temporary test file
            with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
                f.write("This is a test file for MCP upload functionality.\n")
                f.write("It contains some sample text content.\n")
                temp_file_path = f.name
            
            try:
                result = await client.call_tool(
                    "file_upload",
                    {
                        "params": {
                            "file_path": temp_file_path,
                            "description": "Test file for MCP upload",
                            "tags": ["test", "mcp", "upload"]
                        }
                    }
                )
                
                # Access the actual structured data from FastMCP result
                if hasattr(result, 'structured_content') and 'result' in result.structured_content:
                    data = result.structured_content['result']
                else:
                    data = result.data if hasattr(result, 'data') else result
                
                print(f"File upload result type: {type(data)}")
                if isinstance(data, dict):
                    if data.get('success'):
                        print(f"File uploaded successfully!")
                        print(f"  Resource ID: {data.get('resource_id')}")
                        print(f"  File size: {data.get('file_size')} bytes")
                        print(f"  S3 URL: {data.get('s3_url', 'N/A')}")
                        print(f"  Status: {data.get('status')}")
                    else:
                        print(f"File upload failed: {data.get('error')}")
                else:
                    print(f"File upload response: {data}")
                    
            finally:
                # Clean up temp file
                os.unlink(temp_file_path)
                
        except Exception as e:
            print(f"File upload test error: {e}")
        
        print("\n=== Testing Entity Retrieval ===")
        try:
            # Test getting a known entity
            result = await client.call_tool(
                "get_entity",
                {
                    "params": {
                        "entity_id": "96d1a2ff-045b-55cc-a7de-543d1d3cccf8",
                        "entity_type": "Agent"
                    }
                }
            )
            
            # Access the actual structured data from FastMCP result
            if hasattr(result, 'structured_content') and 'result' in result.structured_content:
                data = result.structured_content['result']
            else:
                data = result.data if hasattr(result, 'data') else result
            
            print(f"Entity retrieval result type: {type(data)}")
            if isinstance(data, dict) and not data.get('error'):
                print(f"Entity retrieved successfully!")
                print(f"  ID: {data.get('id')}")
                print(f"  Name: {data.get('name')}")
                print(f"  Description: {data.get('description', 'N/A')[:100]}...")
            else:
                print(f"Entity retrieval response: {data}")
                
        except Exception as e:
            print(f"Entity retrieval test error: {e}")

if __name__ == "__main__":
    asyncio.run(test_remaining_tools())