#!/usr/bin/env python
"""Test searching for pet store functions"""

import asyncio
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport
import os

async def test_pet_function_search():
    """Test searching for pet store functions"""
    # Set up environment
    env = os.environ.copy()
    
    # Create transport
    runner_script = Path("test_percolate/integration/mcp/run_server.py")
    transport = PythonStdioTransport(
        script_path=runner_script,
        env=env
    )
    
    # Use client as context manager
    async with Client(transport=transport) as client:
        print("Connected to MCP server\n")
        
        # Search for pet functions with a specific query
        queries = [
            "find pets by status",
            "get pet by id",
            "pet store inventory",
            "find pets"
        ]
        
        for query in queries:
            print(f"\nSearching for: '{query}'")
            try:
                result = await client.call_tool(
                    "function_search",
                    {
                        "params": {
                            "query": query,
                            "limit": 5
                        }
                    }
                )
                
                # Access the actual structured data from FastMCP result
                if hasattr(result, 'structured_content') and 'result' in result.structured_content:
                    data = result.structured_content['result']
                else:
                    data = result.data if hasattr(result, 'data') else result
                
                if isinstance(data, list) and data:
                    print(f"Found {len(data)} functions")
                    for i, func in enumerate(data):
                        if isinstance(func, dict):
                            print(f"\n{i+1}. {func.get('name', 'N/A')}")
                            print(f"   Description: {func.get('description', 'N/A')[:100]}...")
                            print(f"   Endpoint: {func.get('endpoint', 'N/A')}")
                        else:
                            print(f"\n{i+1}. {func} (type: {type(func).__name__})")
                else:
                    print("No functions found")
                    
            except Exception as e:
                print(f"Error: {e}")
                
        # Test function evaluation
        print("\n\nTesting function evaluation:")
        print("Calling get_pet_findByStatus with status='available'")
        
        try:
            eval_result = await client.call_tool(
                "function_eval",
                {
                    "params": {
                        "function_name": "get_pet_findByStatus",
                        "args": {"status": "available"}
                    }
                }
            )
            
            # Access the actual structured data from FastMCP result
            if hasattr(eval_result, 'structured_content') and 'result' in eval_result.structured_content:
                data = eval_result.structured_content['result']
            else:
                data = eval_result.data if hasattr(eval_result, 'data') else eval_result
            
            if isinstance(data, dict):
                print(f"Success: {data.get('success', False)}")
                if data.get('success'):
                    print(f"Result: {data.get('result', 'N/A')}")
                else:
                    print(f"Error: {data.get('error', 'N/A')}")
                    
        except Exception as e:
            print(f"Error calling function: {e}")

if __name__ == "__main__":
    asyncio.run(test_pet_function_search())