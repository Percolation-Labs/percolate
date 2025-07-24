"""
OAuth utility functions for well-known endpoints
"""

from fastapi.responses import JSONResponse


async def oauth_metadata(oauth_server):
    """
    OAuth 2.1 Authorization Server Metadata
    https://www.rfc-editor.org/rfc/rfc8414
    """
    return JSONResponse(oauth_server.get_oauth_metadata())


async def mcp_oauth_metadata(oauth_server):
    """
    MCP OAuth discovery endpoint
    Returns information about the authorization server protecting this resource
    """
    base_url = oauth_server.base_url
    return JSONResponse({
        "authorization_server": f"{base_url}/.well-known/oauth-authorization-server"
    })