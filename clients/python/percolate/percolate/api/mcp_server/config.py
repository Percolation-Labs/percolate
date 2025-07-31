"""MCP Server configuration using existing Percolate environment variables"""

import os
from typing import Optional, List, Dict
from pydantic import Field
try:
    from pydantic_settings import BaseSettings
except ImportError:
    from pydantic import BaseSettings


# Standalone environment utilities for DXT compatibility
def from_env_or_project(env_var: str, default: str = None) -> str:
    """Get value from environment variable with fallback to default"""
    return os.getenv(env_var, default)

# System user constants for DXT compatibility
SYSTEM_USER_ID = "00000000-0000-0000-0000-000000000000"
SYSTEM_USER_ROLE_LEVEL = 1


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
        default="""Access Percolate through MCP tools:

ENTITY TOOLS:
- get_entity: Fetch specific nodes by name with fuzzy matching
- entity_search: Powerful semantic search using detailed natural language queries. Be specific and descriptive! OR find all instances of a type (use entity_name="p8.Agent" to discover all available entity types)

SEARCH & DISCOVERY:
- function_search: Find available functions/tools
- resource_search: Search uploaded resources and documents
- search_memories: Semantic search through stored memories

AI INTERACTION:
- ask_the_agent: Ask deeper questions about the company/data this MCP server is configured for. Get insights, analysis, and detailed information through the AI agent (uses P8_DEFAULT_AGENT from environment)
- help: Get AI-powered assistance

EXECUTION & STORAGE:
- function_eval: Execute discovered functions
- file_upload: Upload files to Percolate
- add_memory/list_memories/get_memory: Store and retrieve memories

WORKFLOW:
1. Start with entity_search using entity_name="p8.Agent" to discover entity types
2. Search within specific entity types for targeted results
3. Use ask_the_agent for deeper questions, insights, and analysis about your company data
4. Combine tools: find functions with search, then execute with function_eval""",
        description="Instructions shown to clients about this MCP server's capabilities"
    )
    
    # Additional About section for custom preamble
    mcp_about_section: str = Field(
        default_factory=lambda: from_env_or_project('P8_MCP_ABOUT', ''),
        description="Additional About section content to prepend to system instructions. Use P8_MCP_ABOUT environment variable to set custom context."
    )
    
    # API endpoint configuration
    api_endpoint: str = Field(
        default_factory=lambda: from_env_or_project('P8_API_ENDPOINT', from_env_or_project('P8_TEST_DOMAIN', 'https://api.percolationlabs.ai')),
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
    
    # Authentication - supports bearer token
    api_key: Optional[str] = Field(
        default_factory=lambda: from_env_or_project('P8_API_KEY', from_env_or_project('P8_TEST_BEARER_TOKEN', None)),
        description="API key for bearer token authentication. Uses P8_API_KEY or P8_TEST_BEARER_TOKEN from environment or account settings.",
        json_schema_extra={"secret": True}  # Mark as secret for security
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
        description="Default agent for chat/operations (e.g., 'executive-ExecutiveResources'). Set P8_DEFAULT_AGENT environment variable during install.",
        json_schema_extra={"env_var": "P8_DEFAULT_AGENT"}  # Indicate this should be read from environment
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


def get_server_info(settings: MCPSettings) -> Dict[str, str]:
    """Get server information with About section prepended to instructions"""
    instructions_parts = []
    
    # Add About section if configured
    if settings.mcp_about_section:
        instructions_parts.append(settings.mcp_about_section.strip())
        instructions_parts.append("")  # Add blank line separator
    
    # Add the main MCP server instructions
    instructions_parts.append(settings.mcp_server_instructions)
    
    return {
        "name": settings.mcp_server_name,
        "version": settings.mcp_server_version,
        "instructions": "\n".join(instructions_parts)
    }


# For backward compatibility
settings = get_mcp_settings()