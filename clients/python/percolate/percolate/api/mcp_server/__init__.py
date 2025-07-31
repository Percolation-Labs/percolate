"""Percolate MCP Server Package"""

# Only import exceptions for DXT - no FastAPI integration needed
from .exceptions import (
    MCPException,
    EntityNotFoundError,
    AuthenticationError,
    AuthorizationError,
    ValidationError,
    RepositoryError,
    APIError,
    FunctionExecutionError,
    FileOperationError
)

__version__ = "0.1.0"
__all__ = [
    "MCPException",
    "EntityNotFoundError",
    "AuthenticationError",
    "AuthorizationError", 
    "ValidationError",
    "RepositoryError",
    "APIError",
    "FunctionExecutionError",
    "FileOperationError"
]

# FastAPI integration can be imported explicitly when needed:
# from .integration import mount_mcp_server