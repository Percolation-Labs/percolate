"""
Example MCP client with OAuth authentication for Percolate

This example shows how to connect to Percolate's MCP server using OAuth.
Compatible with Claude Code, Claude Desktop, and other MCP clients.
"""

import asyncio
import os
from typing import Optional

# Install with: pip install fastmcp
from fastmcp import Client
from fastmcp.client.auth import OAuth
from fastmcp.client.transports import StreamableHttpTransport


async def example_bearer_auth():
    """Example using bearer token authentication"""
    
    # For bearer token auth, set environment variables
    os.environ["PERCOLATE_API_KEY"] = "sk-your-api-key"
    os.environ["PERCOLATE_USER_EMAIL"] = "user@example.com"
    
    # Create transport without OAuth (will use bearer token from env)
    transport = StreamableHttpTransport(
        url="http://localhost:8000/mcp/",
        headers={
            "Authorization": f"Bearer {os.environ['PERCOLATE_API_KEY']}",
            "X-User-Email": os.environ["PERCOLATE_USER_EMAIL"]
        }
    )
    
    async with Client(transport=transport) as client:
        # List available tools
        tools = await client.list_tools()
        print("\nAvailable tools:")
        for tool in tools:
            print(f"  - {tool.name}: {tool.description}")
        
        # Call a tool
        result = await client.call_tool(
            "search",
            arguments={"query": "AI safety"}
        )
        print(f"\nSearch result: {result}")


async def example_oauth_flow():
    """Example using OAuth authentication flow"""
    
    # Create transport with OAuth
    transport = StreamableHttpTransport(
        url="http://localhost:8000/mcp/",
        auth=OAuth(
            mcp_url="http://localhost:8000/mcp/"
        )
    )
    
    async with Client(transport=transport) as client:
        # OAuth flow will be triggered automatically if needed
        # Browser will open for authentication
        
        # List available tools
        tools = await client.list_tools()
        print("\nAvailable tools:")
        for tool in tools:
            print(f"  - {tool.name}: {tool.description}")
        
        # List available prompts
        prompts = await client.list_prompts()
        print("\nAvailable prompts:")
        for prompt in prompts:
            print(f"  - {prompt.name}: {prompt.description}")
        
        # Get a prompt
        if prompts:
            prompt_result = await client.get_prompt(
                prompts[0].name,
                arguments={}
            )
            print(f"\nPrompt content: {prompt_result}")


def get_claude_desktop_config():
    """Generate Claude Desktop configuration"""
    
    config = {
        "mcpServers": {
            "percolate": {
                "transport": "http",
                "url": "http://localhost:8000/mcp/",
                "env": {
                    # Option 1: Bearer token auth
                    "PERCOLATE_API_KEY": "sk-your-api-key",
                    "PERCOLATE_USER_EMAIL": "user@example.com"
                    
                    # Option 2: OAuth (remove env vars above)
                    # OAuth flow will trigger automatically
                }
            }
        }
    }
    
    return config


def get_claude_code_config():
    """Generate Claude Code configuration"""
    
    config = {
        "percolate": {
            "transport": "http",
            "url": "http://localhost:8000/mcp/",
            "auth": {
                "type": "oauth",
                "authorization_url": "http://localhost:8000/auth/authorize",
                "token_url": "http://localhost:8000/auth/token",
                "pkce": True
            }
        }
    }
    
    return config


async def main():
    """Run examples"""
    
    print("=== Percolate MCP OAuth Examples ===\n")
    
    # Show configuration examples
    print("Claude Desktop configuration:")
    print(f"{get_claude_desktop_config()}\n")
    
    print("Claude Code configuration:")
    print(f"{get_claude_code_config()}\n")
    
    # Run bearer auth example
    print("\n--- Bearer Token Authentication ---")
    try:
        await example_bearer_auth()
    except Exception as e:
        print(f"Bearer auth failed: {e}")
    
    # Run OAuth flow example
    print("\n--- OAuth Flow Authentication ---")
    print("Note: This will open a browser for authentication")
    try:
        await example_oauth_flow()
    except Exception as e:
        print(f"OAuth flow failed: {e}")


if __name__ == "__main__":
    asyncio.run(main())