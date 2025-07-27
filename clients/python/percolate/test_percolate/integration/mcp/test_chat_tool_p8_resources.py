#!/usr/bin/env python3
"""Test the MCP chat tool with p8-Resources agent"""

import asyncio
import os
import sys
from mcp import ClientSession
from mcp.client.stdio import stdio_client, StdioServerParameters
from mcp.types import (
    CallToolRequest,
    CallToolResult
)
from pathlib import Path

# Set the default agent to p8-Resources
os.environ["P8_DEFAULT_AGENT"] = "p8-Resources"

async def test_chat_tool():
    """Test the ask_one tool with p8-Resources agent"""
    
    # Configure environment for local API mode
    env = os.environ.copy()
    env.update({
        "P8_DEFAULT_AGENT": "p8-Resources",
        "P8_USE_API_MODE": "false",  # Use direct mode instead of external API
        "P8_LOG_LEVEL": "INFO"
    })
    
    print(f"🚀 Starting MCP server...")
    print(f"📌 Using API URL: {env.get('P8_API_URL', 'Not set')}")
    print(f"🔑 Using API Key: {env.get('P8_API_KEY', 'Not set')[:10]}...")
    print(f"🤖 Default Agent: p8-Resources")
    print()
    
    # Create server parameters
    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env,
        cwd=str(Path(__file__).parent / "clients/python/percolate")
    )
    
    async with stdio_client(server_params) as (read, write):
        async with ClientSession(read, write) as session:
            print("✅ MCP session established")
            
            # Initialize the session
            await session.initialize()
            print("✅ Session initialized")
            
            # List available tools
            tools = await session.list_tools()
            print(f"\n📚 Available tools: {[tool.name for tool in tools.tools]}")
            
            # Find the ask_one tool
            ask_one_tool = next((t for t in tools.tools if t.name == "ask_one"), None)
            if ask_one_tool:
                print(f"✅ Found 'ask_one' tool: {ask_one_tool.description}")
            else:
                print("❌ 'ask_one' tool not found!")
                return
            
            # Test queries for p8-Resources agent
            test_queries = [
                {
                    "query": "What kind of resources do you have access to?",
                    "description": "Basic capability query"
                },
                {
                    "query": "Can you list some of the data or documents you can access?",
                    "description": "Resource listing query"
                },
                {
                    "query": "Tell me about the Percolate platform and its features",
                    "description": "Platform information query"
                }
            ]
            
            for i, test in enumerate(test_queries, 1):
                print(f"\n{'='*60}")
                print(f"🧪 Test {i}: {test['description']}")
                print(f"❓ Query: {test['query']}")
                print(f"{'='*60}\n")
                
                # Prepare the tool call
                request = CallToolRequest(
                    method="tools/call",
                    params={
                        "name": "ask_one",
                        "arguments": {
                            "query": test["query"],
                            "agent": "p8-Resources",  # Explicitly specify the agent
                            "stream": True
                        }
                    }
                )
                
                try:
                    # Call the tool with proper parameter wrapping
                    print("⏳ Calling ask_one tool...")
                    result = await session.call_tool(
                        name="ask_one",
                        arguments={
                            "params": {
                                "query": test["query"],
                                "agent": "p8-Resources",
                                "stream": True
                            }
                        }
                    )
                    
                    if result:
                        print("✅ Tool call successful!")
                        print("\n📝 Response:")
                        print("-" * 40)
                        if hasattr(result, 'content'):
                            for content in result.content:
                                if hasattr(content, 'type') and content.type == "text":
                                    print(content.text)
                                else:
                                    print(f"Content: {content}")
                        else:
                            print(f"Result: {result}")
                        print("-" * 40)
                    else:
                        print("❌ Tool call returned empty result")
                        
                except Exception as e:
                    print(f"❌ Error during tool call: {e}")
                    import traceback
                    traceback.print_exc()
                
                # Small delay between tests
                if i < len(test_queries):
                    await asyncio.sleep(2)
            
            print("\n✅ All tests completed!")

if __name__ == "__main__":
    print("🧪 Testing MCP Chat Tool with p8-Resources Agent")
    print("=" * 60)
    asyncio.run(test_chat_tool())