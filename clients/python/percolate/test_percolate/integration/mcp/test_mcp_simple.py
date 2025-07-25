#!/usr/bin/env python
"""Simple MCP integration test using existing database"""

import os
import sys
import asyncio
from pathlib import Path

# Add parent path for imports
sys.path.insert(0, str(Path(__file__).parent))

# Set up environment for existing Percolate database
os.environ.update({
    "P8_PG_HOST": "localhost",
    "P8_PG_PORT": "5438",
    "P8_PG_USER": "postgres", 
    "P8_PG_PASSWORD": "postgres",
    "P8_PG_DATABASE": "percolate",
    "P8_API_KEY": "test-api-key",
    "P8_USER_EMAIL": "test@percolate.local",
    "P8_MCP_DESKTOP_EXT": "true",
    "P8_LOG_LEVEL": "INFO"
})

async def test_mcp_get_agent():
    """Test MCP server to get p8.Agent entity"""
    from fastmcp.client import Client, PythonStdioTransport
    
    # Create transport
    transport = PythonStdioTransport(
        script_path="-m",
        args=["percolate.api.mcp_server"],
        env=os.environ.copy()
    )
    
    # Create MCP client
    client = Client(transport=transport)
    
    try:
        # Connect to server
        print("Connecting to MCP server...")
        await client.connect()
        print("✓ Connected to MCP server")
        
        # List available tools
        tools = await client.list_tools()
        print(f"\n✓ Available tools: {[t['name'] for t in tools]}")
        
        # Test get_entity for p8.Agent
        print("\nTesting get_entity for p8.Agent...")
        result = await client.call_tool(
            "get_entity",
            {
                "entity_id": "p8.Agent",
                "entity_type": "Model"
            }
        )
        
        if isinstance(result, dict):
            if "error" in result:
                print(f"✗ Error: {result['error']}")
            else:
                print("✓ Successfully retrieved p8.Agent!")
                print(f"  ID: {result.get('id')}")
                print(f"  Type: {result.get('type')}")
                print(f"  Name: {result.get('name')}")
                desc = result.get('description', 'N/A')
                if desc and len(desc) > 100:
                    desc = desc[:100] + "..."
                print(f"  Description: {desc}")
        
        # Test entity_search
        print("\n\nTesting entity_search for 'Agent'...")
        search_result = await client.call_tool(
            "entity_search",
            {
                "query": "Agent",
                "limit": 3
            }
        )
        
        if isinstance(search_result, list):
            print(f"✓ Found {len(search_result)} entities")
            for i, entity in enumerate(search_result):
                if isinstance(entity, dict) and "error" not in entity:
                    print(f"  {i+1}. {entity.get('name', 'Unknown')} (ID: {entity.get('id')})")
        
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
    finally:
        await client.disconnect()
        print("\n✓ Disconnected from MCP server")

if __name__ == "__main__":
    asyncio.run(test_mcp_get_agent())