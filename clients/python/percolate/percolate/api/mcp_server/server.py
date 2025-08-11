"""FastMCP server for Percolate"""

import logging
from fastmcp import FastMCP
from .config import get_mcp_settings, get_server_info
from .auth import get_auth_handler
from .repository_factory import create_repository
from .tools import create_entity_tools, create_function_tools, create_help_tools, create_file_tools, create_chat_tools, create_memory_tools

logger = logging.getLogger(__name__)


def get_request_context():
    """Get the current request context if available"""
    try:
        from starlette.requests import Request
        from contextvars import ContextVar
        import asyncio
        
        # Try to get current request from FastAPI/Starlette context
        # This is a fallback - ideally we'd pass context explicitly
        task = asyncio.current_task()
        if task and hasattr(task, '_request_context'):
            return getattr(task, '_request_context')
    except:
        pass
    return None


def create_repository_for_request(auth_context: dict = None):
    """Create repository with per-request auth context"""
    settings = get_mcp_settings()
    
    # If we have auth context from request, use it
    if auth_context:
        return create_repository(auth_context=auth_context)
    
    # Fallback to default settings
    return create_repository(
        user_id=settings.user_id,
        user_groups=settings.user_groups,
        role_level=settings.role_level,
        user_email=settings.user_email
    )


def create_mcp_server() -> FastMCP:
    """Create and configure the FastMCP server"""
    settings = get_mcp_settings()
    
    # Configure logging
    logging.getLogger().setLevel(getattr(logging, settings.log_level.upper()))
    
    # Create MCP server with optional auth
    auth_handler = get_auth_handler()
    
    # Get server info with About section prepended to instructions
    server_info = get_server_info(settings)
    
    mcp = FastMCP(
        name=server_info["name"],
        version=server_info["version"],
        instructions=server_info["instructions"],
        auth=auth_handler
    )
    
    # Use context-aware repository factory for per-request context
    from .context import repository_factory
    
    # Register tools with the context-aware repository factory
    create_entity_tools(mcp, repository_factory)
    create_function_tools(mcp, repository_factory)
    create_help_tools(mcp, repository_factory)
    create_file_tools(mcp, repository_factory)
    create_chat_tools(mcp, repository_factory)
    create_memory_tools(mcp, repository_factory)
    
    logger.info(f"Created MCP server: {settings.mcp_server_name} v{settings.mcp_server_version}")
    if auth_handler:
        logger.info("Authentication enabled")
    else:
        logger.warning("No authentication configured - server is open access")
    
    return mcp


def run_stdio():
    """Run the MCP server in stdio mode"""
    # Set desktop extension flag
    import os
    os.environ["P8_MCP_DESKTOP_EXT"] = "true"
    
    mcp = create_mcp_server()
    logger.info("Starting Percolate MCP server in stdio mode...")
    mcp.run(transport="stdio")


if __name__ == "__main__":
    run_stdio()