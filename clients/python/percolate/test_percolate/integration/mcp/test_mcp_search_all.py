#!/usr/bin/env python
"""Test MCP server to search for any entities"""

import asyncio
from pathlib import Path
from fastmcp.client import Client, PythonStdioTransport
import os

async def test_search_all():
    """Test searching for all entities"""
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
        
        # Test 1: Search for anything with empty query
        print("Test 1: Search with empty query")
        try:
            result = await client.call_tool(
                "entity_search",
                {
                    "params": {
                        "query": "",
                        "limit": 10
                    }
                }
            )
            data = result.data if hasattr(result, 'data') else result
            print(f"Found {len(data)} entities")
            for item in data[:5]:  # Show first 5
                if hasattr(item, 'model_dump'):
                    print(f"  - {item.model_dump()}")
                else:
                    print(f"  - {item}")
        except Exception as e:
            print(f"Error: {e}")
        
        print("\nTest 2: Search for 'agent'")
        try:
            result = await client.call_tool(
                "entity_search",
                {
                    "params": {
                        "query": "agent",
                        "limit": 10
                    }
                }
            )
            data = result.data if hasattr(result, 'data') else result
            print(f"Found {len(data)} entities matching 'agent'")
            for item in data[:5]:
                if hasattr(item, 'model_dump'):
                    print(f"  - {item.model_dump()}")
                else:
                    print(f"  - {item}")
        except Exception as e:
            print(f"Error: {e}")
            
        print("\nTest 3: Try to get a specific agent by ID")
        # Try different ID formats
        for agent_id in ["p8.Agent", "p8.PercolateAgent", "PercolateAgent"]:
            print(f"\nTrying ID: {agent_id}")
            try:
                result = await client.call_tool(
                    "get_entity",
                    {
                        "params": {
                            "entity_id": agent_id,
                            "entity_type": "Agent"
                        }
                    }
                )
                data = result.data if hasattr(result, 'data') else result
                print(f"Result: {data}")
            except Exception as e:
                print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(test_search_all())