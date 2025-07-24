#!/usr/bin/env python
"""Test searching for entities by name"""

import asyncio
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport
import os

async def test_search_by_name():
    """Test searching for entities by name"""
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
        
        # Search for entities with different queries
        queries = ["", "p8", "Agent", "percolate", "PercolateAgent", "model", "gpt"]
        
        for query in queries:
            print(f"\nSearching for: '{query}'")
            try:
                result = await client.call_tool(
                    "entity_search",
                    {
                        "params": {
                            "query": query,
                            "limit": 5
                        }
                    }
                )
                data = result.data if hasattr(result, 'data') else result
                print(f"Found {len(data)} results")
                
                # Check if we got actual data
                if isinstance(data, list) and data:
                    for i, item in enumerate(data[:3]):  # Show first 3
                        if hasattr(item, 'model_dump'):
                            item_dict = item.model_dump()
                            print(f"  {i+1}. {item_dict}")
                        elif hasattr(item, '__dict__') and item.__dict__:
                            print(f"  {i+1}. {item.__dict__}")
                        else:
                            print(f"  {i+1}. {item} (type: {type(item).__name__})")
                            
            except Exception as e:
                print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(test_search_by_name())