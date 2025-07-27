"""MCP Server configuration using existing Percolate environment variables"""

import os
from typing import Optional, List
from pydantic import Field
try:
    from pydantic_settings import BaseSettings
except ImportError:
    from pydantic import BaseSettings

from percolate.utils.env import (
    SYSTEM_USER_ID, 
    SYSTEM_USER_ROLE_LEVEL,
    from_env_or_project
)


class MCPSettings(BaseSettings):
    """
    MCP Server configuration settings.
    
    Uses existing Percolate environment variables and configuration patterns.
    """
    
    # Server identification
    mcp_server_name: str = Field(
        default="percolate-mcp",
        description="Name of the MCP server for identification"
    )
    
    mcp_server_version: str = Field(
        default="0.1.0",
        description="Version of the MCP server"
    )
    
    mcp_server_instructions: str = Field(
        default="Access Percolate entities, search capabilities, function evaluation, and knowledge base through MCP tools",
        description="Instructions shown to clients about this MCP server's capabilities"
    )
    
    # API endpoint configuration
    api_endpoint: str = Field(
        default_factory=lambda: from_env_or_project('P8_API_ENDPOINT', 'https://api.percolationlabs.ai'),
        description="Percolate API endpoint URL"
    )
    
    # Database configuration (for direct DB mode)
    pg_host: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_PG_HOST', None),
        description="PostgreSQL host"
    )
    pg_port: int = Field(
        default_factory=lambda: int(from_env_or_project('P8_PG_PORT', '5432')),
        description="PostgreSQL port"
    )
    pg_database: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_PG_DATABASE', None),
        description="PostgreSQL database name"
    )
    pg_user: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_PG_USER', None),
        description="PostgreSQL user"
    )
    pg_password: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_PG_PASSWORD', None),
        description="PostgreSQL password"
    )
    
    # Mode selection
    use_api_mode: bool = Field(
        default_factory=lambda: from_env_or_project('P8_USE_API_MODE', 'true').lower() == 'true',
        description="Use API mode (default: true). Set to false for direct database access."
    )
    
    # Authentication - supports bearer token or OAuth
    api_key: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_API_KEY', None),
        description="API key for bearer token authentication. Uses P8_API_KEY from environment or account settings."
    )
    
    oauth_token: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_OAUTH_TOKEN', None),
        description="OAuth access token as alternative to API key"
    )
    
    # User identification
    user_email: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('X_User_Email', from_env_or_project('P8_USER_EMAIL', None)),
        description="User email for authentication context. Uses X_User_Email or P8_USER_EMAIL from environment. Required when using bearer token."
    )
    
    # User context - uses existing system user by default
    user_id: str = Field(
        default_factory=lambda: from_env_or_project('P8_USER_ID', SYSTEM_USER_ID),
        description="User ID for row-level security. Defaults to system user if not specified"
    )
    
    user_groups: Optional[List[str]] = Field(
        default_factory=lambda: from_env_or_project('P8_USER_GROUPS', '').split(',') if from_env_or_project('P8_USER_GROUPS', '') else None,
        description="Comma-separated list of user groups for access control"
    )
    
    role_level: int = Field(
        default_factory=lambda: int(from_env_or_project('P8_ROLE_LEVEL', str(SYSTEM_USER_ROLE_LEVEL))),
        description="User role level for access control (1=admin, higher numbers = more restricted)"
    )
    
    # Default resource configuration
    default_agent: str = Field(
        default_factory=lambda: from_env_or_project('P8_DEFAULT_AGENT', 'p8.Resources'),
        description="Default agent for chat/operations (e.g., 'executive-ExecutiveResources')"
    )
    
    default_namespace: str = Field(
        default_factory=lambda: from_env_or_project('P8_DEFAULT_NAMESPACE', 'p8'),
        description="Default namespace for file uploads and resource operations"
    )
    
    default_entity: str = Field(
        default_factory=lambda: from_env_or_project('P8_DEFAULT_ENTITY', 'Resources'),
        description="Default entity for resource operations"
    )
    
    # Model configuration
    default_model: str = Field(
        default_factory=lambda: from_env_or_project('P8_DEFAULT_MODEL', 'gpt-4o-mini'),
        description="Default language model to use for agent operations"
    )
    
    default_vision_model: str = Field(
        default_factory=lambda: from_env_or_project('P8_DEFAULT_VISION_MODEL', 'gpt-4o'),
        description="Default vision model for image processing"
    )
    
    # Server configuration
    mcp_port: int = Field(
        default_factory=lambda: int(from_env_or_project('P8_MCP_PORT', '8001')),
        description="Port for HTTP mode MCP server"
    )
    
    log_level: str = Field(
        default_factory=lambda: from_env_or_project('P8_LOG_LEVEL', 'INFO'),
        description="Logging level (DEBUG, INFO, WARNING, ERROR)"
    )
    
    # Agent configuration
    agent_max_depth: int = Field(
        default=3,
        description="Default maximum recursion depth for agent operations"
    )
    
    agent_allow_help: bool = Field(
        default=True,
        description="Whether agents can access help functions"
    )
    
    # Runtime flags
    is_desktop_extension: bool = Field(
        default_factory=lambda: os.getenv('P8_MCP_DESKTOP_EXT', 'false').lower() == 'true',
        description="Whether running as a desktop extension (DXT)"
    )
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        # Use P8_ prefix for any custom env vars
        env_prefix = "P8_"


def get_mcp_settings() -> MCPSettings:
    """Get the current MCP settings instance"""
    return MCPSettings()


# For backward compatibility
settings = get_mcp_settings()