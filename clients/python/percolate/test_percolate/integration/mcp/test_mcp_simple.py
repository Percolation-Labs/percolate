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
    
    # Create transport using the run_server.py script
    runner_script = Path(__file__).parent / "run_server.py"
    transport = PythonStdioTransport(
        script_path=str(runner_script),
        env=os.environ.copy()
    )
    
    # Create and connect client using context manager
    async with Client(transport=transport) as client:
        print("✓ Connected to MCP server")
        
        # List available tools
        tools = await client.list_tools()
        print(f"\n✓ Available tools: {[t.name if hasattr(t, 'name') else t.get('name', str(t)) for t in tools]}")
        
        # Test get_entity for p8.Agent
        print("\nTesting get_entity for p8.Agent...")
        result = await client.call_tool(
            "get_entity",
            {
                "params": {
                    "entity_name": "p8.Agent",
                    "entity_type": "Agent"
                }
            }
        )
        
        # Extract the actual result from the MCP response
        from percolate.api.mcp_server.utils import extract_tool_result
        result = extract_tool_result(result)
        
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
                "params": {
                    "query": "Agent",
                    "limit": 3
                }
            }
        )
        
        # Extract the result
        search_result = extract_tool_result(search_result)
        
        if isinstance(search_result, list):
            print(f"✓ Found {len(search_result)} entities")
            for i, entity in enumerate(search_result):
                if isinstance(entity, dict) and "error" not in entity:
                    print(f"  {i+1}. {entity.get('name', 'Unknown')} (ID: {entity.get('id')})")
        
        print("\n✓ Test completed successfully")

if __name__ == "__main__":
    asyncio.run(test_mcp_get_agent())