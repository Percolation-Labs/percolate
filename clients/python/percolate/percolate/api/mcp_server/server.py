"""FastMCP server for Percolate"""

import logging
from fastmcp import FastMCP
from .config import get_mcp_settings
from .auth import get_auth_handler
from .repository_factory import create_repository
from .tools import create_entity_tools, create_function_tools, create_help_tools, create_file_tools, create_chat_tools, create_memory_tools

logger = logging.getLogger(__name__)


def create_mcp_server() -> FastMCP:
    """Create and configure the FastMCP server"""
    settings = get_mcp_settings()
    
    # Configure logging
    logging.getLogger().setLevel(getattr(logging, settings.log_level.upper()))
    
    # Create MCP server with optional auth
    auth_handler = get_auth_handler()
    
    mcp = FastMCP(
        name=settings.mcp_server_name,
        version=settings.mcp_server_version,
        instructions=settings.mcp_server_instructions,
        auth=auth_handler
    )
    
    # Create repository with user context (auto-selects DB or API mode)
    repository = create_repository(
        user_id=settings.user_id,
        user_groups=settings.user_groups,
        role_level=settings.role_level,
        user_email=settings.user_email
    )
    
    # Register tools
    create_entity_tools(mcp, repository)
    create_function_tools(mcp, repository)
    create_help_tools(mcp, repository)
    create_file_tools(mcp, repository)
    create_chat_tools(mcp, repository)
    create_memory_tools(mcp, repository)
    
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