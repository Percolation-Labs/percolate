#!/usr/bin/env python
"""Test function search directly"""

import asyncio
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport
import os

async def test_function_search():
    """Test function search directly"""
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
        
        # Search for functions
        result = await client.call_tool(
            "function_search",
            {
                "params": {
                    "query": "search",
                    "limit": 5
                }
            }
        )
        
        print(f"Result type: {type(result)}")
        data = result.data if hasattr(result, 'data') else result
        print(f"Data type: {type(data)}")
        print(f"Data: {data}")
        
        if isinstance(data, list):
            print(f"\nFound {len(data)} functions")
            for i, item in enumerate(data[:3]):
                print(f"\n{i+1}. Type: {type(item)}")
                if hasattr(item, '__dict__'):
                    print(f"   Dict: {item.__dict__}")
                elif isinstance(item, dict):
                    print(f"   Dict: {item}")
                else:
                    print(f"   Value: {item}")

if __name__ == "__main__":
    asyncio.run(test_function_search())