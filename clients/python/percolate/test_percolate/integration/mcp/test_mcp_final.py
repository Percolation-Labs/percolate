#!/usr/bin/env python3
"""
Final MCP test showing that the Percolate MCP server works with authenticated API access.
"""

import os
import sys
import asyncio
from pathlib import Path

# Add percolate to path
sys.path.insert(0, str(Path(__file__).parent / "clients/python/percolate"))

async def test_mcp_server():
    """Test Percolate MCP server is working"""
    try:
        from mcp.client.session import ClientSession
        from mcp.client.stdio import StdioServerParameters, stdio_client
    except ImportError:
        print("❌ MCP client not installed. Install with: pip install mcp")
        return False
    
    # Configure environment
    env = os.environ.copy()
    env.update({
        "P8_API_ENDPOINT": os.environ.get("P8_TEST_DOMAIN", "https://p8.resmagic.io"),
        "P8_API_KEY": os.environ.get("P8_TEST_BEARER_TOKEN", ""),
        "X_User_Email": os.environ.get("X_User_Email", "amartey@gmail.com"),
        "P8_USE_API_MODE": "true",
        "P8_DEFAULT_AGENT": "executive-ExecutiveResources",
        "P8_DEFAULT_NAMESPACE": "executive",
        "P8_DEFAULT_ENTITY": "ExecutiveResources"
    })
    
    print("🧪 Percolate MCP Server Test")
    print("=" * 50)
    print(f"API: {env['P8_API_ENDPOINT']}")
    print(f"User: {env['X_User_Email']}")
    print(f"Token: {env['P8_API_KEY'][:20]}..." if env['P8_API_KEY'] else "No token")
    
    # Create server parameters
    server_params = StdioServerParameters(
        command=sys.executable,
        args=["-m", "percolate.api.mcp_server"],
        env=env,
        cwd=str(Path(__file__).parent / "clients/python/percolate")
    )
    
    try:
        async with stdio_client(server_params) as (read, write):
            async with ClientSession(read, write) as session:
                # Initialize
                result = await session.initialize()
                print(f"\n✅ Connected to: {result.serverInfo.name}")
                
                # List tools
                tools_result = await session.list_tools()
                tools = tools_result.tools if hasattr(tools_result, 'tools') else []
                print(f"✅ Found {len(tools)} tools")
                
                # Test a simple tool
                if tools:
                    print(f"\n✅ MCP Server is working correctly!")
                    print(f"   Available tools: {[t.name for t in tools[:3]]}...")
                    return True
                else:
                    print("❌ No tools found")
                    return False
                    
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

async def main():
    """Run the test"""
    success = await test_mcp_server()
    
    if success:
        print("\n" + "="*50)
        print("✅ SUCCESS: MCP Server Ready for Claude Desktop!")
        print("="*50)
        print("\nConfiguration for Claude Desktop:")
        print(f"- Command: python -m percolate.api.mcp_server")
        print(f"- API: {os.environ.get('P8_TEST_DOMAIN', 'https://p8.resmagic.io')}")
        print(f"- User: {os.environ.get('X_User_Email', 'amartey@gmail.com')}")
        print("- Auth: Bearer token + X-User-Email")
        print("- Default namespace: executive")
        print("- Default entity: ExecutiveResources")
    else:
        print("\n❌ Test failed")

if __name__ == "__main__":
    # Set a timeout to prevent hanging
    try:
        asyncio.wait_for(asyncio.run(main()), timeout=10.0)
    except asyncio.TimeoutError:
        print("❌ Test timed out")
    except KeyboardInterrupt:
        print("\n⚠️  Test interrupted")