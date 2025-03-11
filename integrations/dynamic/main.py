from mcp.server import Server, NotificationOptions
import asyncio
import mcp.types as types
import requests

app = Server("p8")


PERCOLATE_HOST = f"http://127.0.0.1:5000"

@app.list_tools()
async def list_tools() -> list[types.Tool]:
    """List available tools."""
    url = f"{PERCOLATE_HOST}/tools"
    response = requests.get(url, params={'scheme':'anthropic'})
    """checks TODO"""
    return [types.Tool(**t) for t in response.json()]


@app.call_tool()
async def eval_tool(name: str, arguments: dict) -> list:
    """eval any function in percolate by name and arguments"""
    url = f"{PERCOLATE_HOST}/tools/eval"
    response = requests.post(url, json={
        'name': name,'arguments': arguments
    })
    """checks TODO"""
    return response.json()

 
async def main() -> None:
    """Main entry point for server."""
    # Import here to avoid issues with event loops
    from mcp.server.stdio import stdio_server

    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())