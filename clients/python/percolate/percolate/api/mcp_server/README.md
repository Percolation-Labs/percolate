# Percolate MCP Server

A Model Context Protocol (MCP) server for Percolate that provides tools for entity management, search, function evaluation, and knowledge base access through the PercolateAgent.

## Architecture Overview

The Percolate MCP server is built using [FastMCP](https://gofastmcp.com/llms-full.txt) and supports both stdio (for desktop extensions) and HTTP (streaming) modes with bearer token authentication.

### Directory Structure

```
mcp/
├── percolate_mcp/
│   ├── __init__.py
│   ├── server.py              # FastMCP server setup and configuration
│   ├── main.py                # FastAPI app for HTTP mode
│   ├── config.py              # Settings and configuration management
│   ├── auth/
│   │   ├── __init__.py
│   │   └── bearer_auth.py     # Bearer token authentication provider
│   ├── tools/
│   │   ├── __init__.py
│   │   ├── entity_tools.py    # get_entity and entity_search tools
│   │   ├── function_tools.py  # function_search_eval tool
│   │   └── help_tools.py      # help tool using PercolateAgent
│   └── utils/
│       ├── __init__.py
│       └── client.py          # Percolate client utilities
├── tests/
│   ├── __init__.py
│   ├── test_entity_tools.py
│   ├── test_function_tools.py
│   ├── test_help_tools.py
│   └── test_auth.py
├── scripts/
│   └── dxt/
│       ├── manifest.json      # Desktop extension manifest
│       └── build_dxt.sh       # DXT build script
└── README.md                  # This file
```

## Authentication

The MCP server supports two authentication methods:

### Method 1: API Key + User Email
- **API Key**: Bearer token stored in `P8_PG_PASSWORD` environment variable
- **User Email**: Must be provided via `X-User-Email` header or `X_User_Email` environment variable
- **Usage**: Both API key and user email are required for authentication

### Method 2: JWT Token
- **JWT Token**: Contains embedded user context (user ID, email, groups, role level)
- **Storage**: Stored in `P8_OAUTH_TOKEN` environment variable
- **Usage**: Self-contained authentication without additional headers

### MCP Client Integration

For MCP clients like Claude Desktop or Claude Code:

1. **Environment Variables Available**: 
   - `P8_PG_PASSWORD`: Bearer token for API key authentication
   - `P8_OAUTH_TOKEN`: JWT token for OAuth authentication
   - `X_User_Email`: User email (required with bearer token)
   - `P8_API_ENDPOINT`: Percolate API endpoint URL

2. **Authentication Flow**:
   - When environment variables are set → Use stored credentials
   - When environment variables are not set → User prompted to log in
   - Login page or OAuth provider (Google) handles token acquisition
   - Clients manage token refresh automatically

3. **Token Propagation**:
   - MCP context carries authentication token in requests
   - Tokens are passed down to underlying repositories (PostgreSQL, API clients)
   - Row-level security enforced throughout the system

## Tools

### 1. Entity Tools (`entity_tools.py`)

#### `get_entity`
Retrieves a specific entity by ID from the Percolate knowledge base.

**Parameters:**
- `entity_id`: The unique identifier of the entity
- `entity_type`: Type of entity (optional, for type-specific retrieval)

#### `entity_search`
Searches for entities based on query parameters, similar to the model runner pattern.

**Parameters:**
- `query`: Search query string
- `filters`: Optional filters (type, tags, etc.)
- `limit`: Maximum number of results (default: 10)

### 2. Function Tools (`function_tools.py`)

#### `function_search_eval`
Searches for functions/tools and evaluates their relevance or executes them.

**Parameters:**
- `query`: Function search query
- `evaluate`: Whether to evaluate the function (default: false)
- `params`: Parameters for function execution (if evaluate=true)

### 3. Help Tools (`help_tools.py`)

#### `help`
Uses the PercolateAgent to search the knowledge base and provide contextual help.

**Parameters:**
- `query`: Help query
- `context`: Additional context for the search
- `max_depth`: Maximum recursion depth for agent (default: 3)

## Deployment Modes

### Stdio Mode (Desktop Extension)

For use with desktop MCP clients:

```bash
python -m percolate.api.mcp_server.server
```

### HTTP Mode (Streaming Server)

For HTTP-based deployment with streaming support:

```bash
python -m percolate.api.mcp_server.main
```

The HTTP server:
- Supports streaming responses (not SSE)
- Mounts at `/mcp` endpoint
- Includes health check at `/health`
- Configurable port via `P8_MCP_PORT` (default: 8001)

## Configuration

Environment variables:
- `P8_PG_PASSWORD`: Bearer token for API key authentication
- `P8_OAUTH_TOKEN`: JWT token for OAuth authentication  
- `X_User_Email`: User email address (required with bearer token)
- `P8_API_ENDPOINT`: Percolate API endpoint (default: https://api.percolationlabs.ai)
- `P8_MCP_PORT`: HTTP server port (default: 8001)
- `P8_LOG_LEVEL`: Logging level (default: INFO)
- `P8_USE_API_MODE`: Use API mode vs direct database (default: true)
- `P8_USER_ID`: User ID for row-level security (defaults to system user)
- `P8_USER_GROUPS`: Comma-separated list of user groups
- `P8_ROLE_LEVEL`: User role level for access control

## Building Desktop Extension (DXT)

To build the desktop extension package:

```bash
cd scripts/dxt
./build_dxt.sh
```

This creates a `.dxt` package that can be installed in desktop MCP clients.

## Testing

Run the test suite:

```bash
# All tests
pytest tests/

# Specific test file
pytest tests/test_entity_tools.py

# With coverage
pytest --cov=percolate.api.mcp_server tests/
```

## Integration with Percolate

The MCP server integrates directly with Percolate's Python client library, providing:
- Direct access to entities and models
- Function discovery and execution
- Agent-based knowledge search
- Row-level security through user context

## Development

### Adding New Tools

1. Create a new module in `tools/`
2. Implement tool functions with FastMCP decorators
3. Register tools in `server.py`
4. Add corresponding tests
5. Update documentation

### Example Tool Implementation

```python
from fastmcp import FastMCP

def create_example_tools(mcp: FastMCP):
    @mcp.tool(
        name="example_tool",
        description="An example tool",
        annotations={
            "hint": {"readOnlyHint": True},
            "tags": ["example", "demo"]
        }
    )
    async def example_tool(param: str) -> str:
        # Tool implementation
        return f"Result for {param}"
```

## Security Considerations

- All tools respect Percolate's row-level security
- Bearer tokens should be kept secure
- Token validation happens on every request
- User context is propagated to all Percolate operations

## Resources

- [FastMCP Documentation](https://gofastmcp.com/llms-full.txt)
- [Model Context Protocol Specification](https://modelcontextprotocol.io/)
- [Percolate Documentation](../../../README.md)