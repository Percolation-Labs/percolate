"""FastAPI app for MCP server HTTP mode"""

from fastapi import FastAPI
from .server import create_mcp_server
from .config import get_mcp_settings


def create_mcp_http_app() -> FastAPI:
    """Create FastAPI app with MCP server mounted"""
    settings = get_mcp_settings()
    
    # Create MCP server
    mcp = create_mcp_server()
    
    # Get the HTTP app from MCP with path
    mcp_app = mcp.http_app(path="/mcp")
    
    # Create FastAPI app with shared lifespan
    app = FastAPI(
        title=f"{settings.mcp_server_name} HTTP Interface",
        version=settings.mcp_server_version,
        description=settings.mcp_server_instructions,
        lifespan=mcp_app.lifespan  # Share MCP's lifespan
    )
    
    # Mount MCP app
    app.mount("/", mcp_app)
    
    return app


# Create app instance for uvicorn
app = create_mcp_http_app()