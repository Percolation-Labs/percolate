"""Integration helpers for mounting MCP server in the main API"""

from typing import Optional
from fastapi import FastAPI
import logging
from .server import create_mcp_server
from .config import get_mcp_settings

logger = logging.getLogger(__name__)


def mount_mcp_server(app: FastAPI, path: str = "/mcp") -> Optional[FastAPI]:
    """
    Mount MCP server on the main FastAPI app.
    
    This should be called after the main app is created but before starting.
    The MCP server will share the app's lifespan.
    
    Args:
        app: The main FastAPI application
        path: Path to mount MCP server (default: /mcp)
        
    Returns:
        The MCP FastAPI app if mounted, None if not configured
    """
    settings = get_mcp_settings()
    
    # Only mount if API key is configured
    if not settings.api_key:
        logger.info("MCP server not mounted - no P8_API_KEY configured")
        return None
    
    try:
        # Create MCP server
        mcp = create_mcp_server()
        
        # Get HTTP app with the mount path
        mcp_app = mcp.http_app(path=path)
        
        # Mount the MCP app
        app.mount(path, mcp_app)
        
        logger.info(f"MCP server mounted at {path}")
        # Note: FastMCP doesn't expose tools list directly, tools are accessible via the MCP protocol
        
        return mcp_app
        
    except Exception as e:
        logger.error(f"Failed to mount MCP server: {e}")
        return None