#!/usr/bin/env python
"""Test MCP server to get p8.Agent entity"""

import asyncio
import subprocess
import json
import os
import sys

async def test_get_agent():
    """Test getting p8.Agent entity via MCP"""
    
    # Set up environment
    env = os.environ.copy()
    env.update({
        "P8_API_KEY": os.getenv("P8_API_KEY", "test-api-key"),
        "P8_USER_EMAIL": os.getenv("P8_USER_EMAIL", "test@percolate.local"),
        "P8_MCP_DESKTOP_EXT": "true",
        "P8_LOG_LEVEL": "DEBUG",
        "P8_PG_HOST": os.getenv("P8_PG_HOST", "localhost"),
        "P8_PG_PORT": os.getenv("P8_PG_PORT", "5433"),
        "P8_PG_USER": os.getenv("P8_PG_USER", "postgres"),
        "P8_PG_PASSWORD": os.getenv("P8_PG_PASSWORD", "postgres"),
        "P8_PG_DATABASE": os.getenv("P8_PG_DATABASE", "test_percolate")
    })
    
    # Start MCP server
    server_proc = subprocess.Popen(
        ["python", "-m", "percolate.api.mcp_server"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True
    )
    
    try:
        # Send initialize request
        initialize_req = {
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {
                    "name": "test-client",
                    "version": "1.0"
                }
            },
            "id": 1
        }
        
        server_proc.stdin.write(json.dumps(initialize_req) + "\n")
        server_proc.stdin.flush()
        
        # Read initialize response
        response = server_proc.stdout.readline()
        print("Initialize response:", response)
        
        # Send initialized notification
        initialized_notif = {
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }
        server_proc.stdin.write(json.dumps(initialized_notif) + "\n")
        server_proc.stdin.flush()
        
        # Call get_entity for p8.Agent
        get_entity_req = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {
                "name": "get_entity",
                "arguments": {
                    "entity_id": "p8.Agent",
                    "entity_type": "Model"
                }
            },
            "id": 2
        }
        
        server_proc.stdin.write(json.dumps(get_entity_req) + "\n")
        server_proc.stdin.flush()
        
        # Read response
        response = server_proc.stdout.readline()
        print("\nGet entity response:", response)
        
        # Parse and display result
        try:
            result = json.loads(response)
            if "result" in result:
                entity_data = result["result"]
                print("\nEntity found:")
                print(f"  ID: {entity_data.get('id')}")
                print(f"  Type: {entity_data.get('type')}")
                print(f"  Name: {entity_data.get('name')}")
                print(f"  Description: {entity_data.get('description', 'N/A')[:100]}...")
            elif "error" in result:
                print(f"\nError: {result['error']}")
        except json.JSONDecodeError:
            print(f"\nFailed to parse response: {response}")
        
    finally:
        # Cleanup
        server_proc.terminate()
        server_proc.wait()

if __name__ == "__main__":
    asyncio.run(test_get_agent())