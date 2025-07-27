#!/usr/bin/env python3
"""Debug MCP parameter validation issue"""

import asyncio
import os
import sys
from mcp import ClientSession
from mcp.client.stdio import stdio_client, StdioServerParameters
from pathlib import Path

async def test_mcp_tools():
    """Test MCP tools to debug parameter issue"""
    
    # Configure environment for API mode
    env = os.environ.copy()
    env.update({
        "P8_DEFAULT_AGENT": "p8-Resources",
        "P8_USE_API_MODE": "true",
        "P8_LOG_LEVEL": "DEBUG"
    })
    
    print("🧪 Debugging MCP Tools")
    print("=" * 60)
    
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
            
            # Test different tools to see which ones work
            test_tools = [
                {
                    "name": "help",
                    "args": {
                        "query": "Test query",
                        "context": "Testing MCP",
                        "max_depth": 2
                    }
                },
                {
                    "name": "entity_search", 
                    "args": {
                        "query": "test",
                        "limit": 5
                    }
                },
                {
                    "name": "ask_one",
                    "args": {
                        "query": "What kind of resources do you have access to?",
                        "agent": "p8-Resources",
                        "stream": True
                    }
                }
            ]
            
            for test_tool in test_tools:
                print(f"\n{'='*60}")
                print(f"🧪 Testing tool: {test_tool['name']}")
                print(f"📝 Arguments: {test_tool['args']}")
                print(f"{'='*60}")
                
                try:
                    # Try wrapping arguments in 'params' 
                    wrapped_args = {"params": test_tool["args"]}
                    print(f"🔧 Trying wrapped args: {wrapped_args}")
                    
                    result = await session.call_tool(
                        name=test_tool["name"],
                        arguments=wrapped_args
                    )
                    
                    if result:
                        print("✅ Tool call successful!")
                        if hasattr(result, 'content'):
                            for content in result.content:
                                if hasattr(content, 'type') and content.type == "text":
                                    print(f"📝 Response: {content.text[:200]}...")
                                else:
                                    print(f"📝 Content: {str(content)[:200]}...")
                        else:
                            print(f"📝 Raw result: {str(result)[:200]}...")
                    else:
                        print("❌ Tool call returned empty result")
                        
                except Exception as e:
                    print(f"❌ Tool call failed: {e}")
                    import traceback
                    traceback.print_exc()
                
                await asyncio.sleep(1)  # Small delay between tests
            
            print("\n✅ Debug test completed!")

if __name__ == "__main__":
    asyncio.run(test_mcp_tools())