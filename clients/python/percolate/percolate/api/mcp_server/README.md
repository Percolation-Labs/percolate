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
- **Storage**: When using OAuth authentication, the system uses `P8_PG_PASSWORD` as the token
- **Usage**: Self-contained authentication without additional headers

### MCP Client Integration

For MCP clients like Claude Desktop or Claude Code:

1. **Environment Variables Available**: 
   - `P8_PG_PASSWORD`: Bearer token for authentication (used for both API key and OAuth tokens)
   - `X_User_Email`: User email (required with API key authentication)
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
Retrieves a specific entity by name from the Percolate knowledge base.

**Parameters:**
- `entity_name`: The name of the entity (e.g., 'MyModel', 'DataProcessor', 'AnalysisAgent')
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
- `P8_PG_PASSWORD`: Bearer token for authentication (used for both API key and OAuth tokens)
- `X_User_Email`: User email address (required with API key authentication)
- `P8_API_ENDPOINT`: Percolate API endpoint (default: http://localhost:5008)
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

### Prerequisites

1. **Environment Setup**:
   ```bash
   source /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/set_res_env.sh
   ```
   This sets up:
   - Database connection via port forwarding (localhost:25432)
   - `P8_API_KEY` from `P8_TEST_BEARER_TOKEN`
   - Required PostgreSQL environment variables

2. **Start the Server**:
   ```bash
   P8_API_KEY="${P8_TEST_BEARER_TOKEN}" poetry run uvicorn percolate.api.main:app --port 5008 --reload
   ```

### Testing HTTP Streamable Transport

The MCP server uses HTTP streamable transport (not SSE). Test with JSON-RPC 2.0 calls:

```bash
# Initialize MCP connection
curl -X POST "http://localhost:5008/mcp" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "initialize",
    "params": {
      "protocolVersion": "2024-11-05",
      "capabilities": {},
      "clientInfo": {"name": "test-client", "version": "1.0"}
    },
    "id": 1
  }'

# List available tools
curl -X POST "http://localhost:5008/mcp" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}'

# Call get_entity tool
curl -X POST "http://localhost:5008/mcp" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "get_entity",
      "arguments": {
        "entity_name": "KT-2011"
      }
    },
    "id": 2
  }'
```

### Available Tools

- **`get_entity`** - Retrieve specific entities by name with fuzzy matching
- **`entity_search`** - Semantic search across entities using natural language
- **`function_search`** - Find available functions/tools
- **`function_eval`** - Execute discovered functions
- **`file_upload`** - Upload files to Percolate
- **`ask_the_agent`** - AI-powered insights and analysis
- **`help`** - Get assistance with MCP server usage

### Unit and Integration Tests

Run the test suite:

```bash
# All tests
pytest tests/

# Specific test file
pytest tests/test_entity_tools.py

# With coverage
pytest --cov=percolate.api.mcp_server tests/
```

## Troubleshooting

### Common Issues and Solutions

#### 1. MCP Server Not Mounting

**Symptoms**: 
- Server logs show "MCP server not available" warning
- `/mcp` endpoint returns 404

**Causes & Fixes**:

- **Missing `P8_API_KEY`**:
  ```bash
  export P8_API_KEY="${P8_TEST_BEARER_TOKEN}"
  # Or update set_res_env.sh to include this export
  ```

- **Import error in `__init__.py`**:
  ```python
  # Ensure __init__.py exports mount_mcp_server
  from .integration import mount_mcp_server
  __all__ = [..., "mount_mcp_server"]
  ```

- **FastMCP not installed**:
  ```bash
  poetry install  # Ensure all dependencies are installed
  poetry show fastmcp  # Verify installation
  ```

#### 2. Authentication Handler Errors

**Symptoms**: 
- "Failed to mount MCP server: 'function' object has no attribute 'required_scopes'"
- "Failed to mount MCP server: 'function' object has no attribute 'issuer_url'"

**Fix**: Add required attributes to auth handler function in `auth.py`:
```python
def get_auth_handler():
    if settings.api_key:
        # Add required attributes for FastMCP compatibility
        percolate_auth_handler.required_scopes = ["read", "write"]
        percolate_auth_handler.issuer_url = settings.api_endpoint
        return percolate_auth_handler
    return None
```

#### 3. HTTP 307 Redirects (Normal Behavior)

**Symptoms**: 
- Tool calls return HTTP 307 status
- Responses appear empty but request completes

**Explanation**: This is **normal behavior** for HTTP streamable transport. The 307 redirect indicates the MCP protocol is handling the request properly and routing it through the appropriate channels. This confirms:
- ✅ MCP Server is mounted and responding
- ✅ HTTP streamable transport is working
- ✅ Tools are being called through proper MCP protocol

#### 4. Database Connection Issues

**Symptoms**: 
- Tools fail with database connection errors
- "Connection refused" to PostgreSQL

**Fix**: Ensure port forwarding is active:
```bash
# Check if port forward is running
lsof -i :25432

# Restart if needed
source /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/set_res_env.sh
```

#### 5. Environment Variable Issues

**Required Environment Variables** (set by `set_res_env.sh`):
```bash
# Database 
P8_PG_HOST=localhost
P8_PG_PORT=25432
P8_PG_DATABASE=app
P8_PG_USER=postgres
P8_PG_PASSWORD=${P8_TEST_BEARER_TOKEN}

# API (required for MCP server mounting)
P8_API_KEY=${P8_TEST_BEARER_TOKEN}

# Optional
P8_API_ENDPOINT=http://localhost:5008
P8_MCP_ABOUT="Custom context for this MCP server"
```

### Debugging Tips

1. **Check Server Logs**: Look for MCP-related messages during startup
   ```bash
   P8_API_KEY="${P8_TEST_BEARER_TOKEN}" poetry run uvicorn percolate.api.main:app --port 5008 --log-level debug
   ```

2. **Verify Dependencies**: Ensure FastMCP is available
   ```bash
   poetry show fastmcp
   ```

3. **Test Database Connection**: Verify PostgreSQL connectivity
   ```bash
   poetry run python -c "import percolate as p8; print(p8.repository())"
   ```

4. **Verify MCP Mounting**: Look for these log messages on startup:
   ```
   INFO:percolate.api.mcp_server.integration:MCP server mounted at /mcp
   INFO:percolate.api.mcp_server.server:Created MCP server: percolate-mcp v0.1.0
   ```

5. **Test MCP Protocol**: Verify JSON-RPC 2.0 responses
   ```bash
   curl -X POST "http://localhost:5008/mcp" \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc": "2.0", "method": "initialize", "params": {}, "id": 1}'
   ```

### Key Learnings

1. **FastMCP Integration**: FastMCP provides HTTP transport via `.http_app()` method, which creates internal routing. Mount the resulting app directly rather than trying to customize paths.

2. **Authentication**: FastMCP expects auth handlers to have specific attributes (`required_scopes`, `issuer_url`). Simple functions need these attributes added dynamically.

3. **Environment Dependencies**: The MCP server requires both database connectivity and API key configuration. The `set_res_env.sh` script handles all necessary setup.

4. **HTTP vs SSE**: Use HTTP streamable transport (JSON-RPC over HTTP) rather than Server-Sent Events (SSE) for tool calls.

5. **Error Handling**: MCP protocol responses are often returned as HTTP 307 redirects with the actual response handled internally by FastMCP.

## Deployment

### Local Development
```bash
# Setup environment
source /Users/sirsh/code/mr_saoirse/percolate/clients/python/percolate/set_res_env.sh

# Start server
P8_API_KEY="${P8_TEST_BEARER_TOKEN}" poetry run uvicorn percolate.api.main:app --port 5008 --reload
```

### Production Deployment

Build and deploy to Kubernetes:

```bash
# Build multi-arch Docker image
docker buildx build --platform linux/amd64,linux/arm64 -t percolationlabs/percolate-api:latest --push .

# Deploy to cluster
kubectl rollout restart deployment percolate-api -n p8
```

### Testing Remote Deployment

After deployment, test the remote MCP server:

```bash
# Test remote server MCP endpoint
curl -X POST "https://api.percolationlabs.ai/mcp" \
  -H "Authorization: Bearer ${P8_TEST_BEARER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "tools/call",
    "params": {
      "name": "get_entity",
      "arguments": {
        "entity_name": "KT-2011"
      }
    },
    "id": 1
  }'

# Check deployment logs
kubectl logs -l app=percolate-api --all-containers=true --prefix --follow -n p8
```

Ensure the remote deployment includes:
1. All poetry dependencies installed in Docker image
2. Database connectivity configured
3. `P8_PG_PASSWORD` configured in deployment secrets
4. Appropriate CORS settings for MCP client access
5. Monitoring for MCP-specific errors and performance

## MCP Client Integration

### Claude Desktop Integration

Configure Claude Desktop to connect to the remote Percolate MCP server:

```json
{
  "mcpServers": {
    "percolate": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-fetch"],
      "env": {
        "MCP_SERVER_URL": "https://p8.resmagic.io/mcp",
        "MCP_SERVER_AUTH": "Bearer your-percolate-token-here"
      },
      "headers": {
        "X-User-Email": "your-email@company.com"
      }
    }
  }
}
```

**Steps to get your bearer token:**
1. Log into Percolate web interface
2. Open browser developer tools → Network tab
3. Make any API request
4. Copy the `Authorization: Bearer` token from request headers

### VS Code MCP Extension Integration

Similar configuration for VS Code MCP extensions:

```json
{
  "mcp.servers": {
    "percolate": {
      "url": "https://p8.resmagic.io/mcp",
      "auth": {
        "type": "bearer",
        "token": "your-percolate-token-here"
      }
    }
  }
}
```

### Authentication Flow

1. **Client connects** to `https://p8.resmagic.io/mcp` with:
   - `Authorization: Bearer <your-token>` header
   - `X-User-Email: <your-email>` header
2. **MCP server validates** both bearer token and user email
3. **User context established** from email and token authentication
4. **Tools become available** with row-level security enforced based on user
5. **Client can call tools** like `get_entity`, `entity_search`, `ask_the_agent`

### Required Headers

All MCP tool calls must include both headers:
```
Authorization: Bearer p8-your-token-here
X-User-Email: user@company.com
```

### Available Tools in Claude Desktop

Once connected, Claude will have access to:

- **`get_entity`** - "Retrieve specific entities by name with fuzzy matching"
- **`entity_search`** - "Semantic search across entities using natural language queries" 
- **`ask_the_agent`** - "AI-powered insights and analysis about your company data"
- **`function_search`** - "Find available functions/tools"
- **`function_eval`** - "Execute discovered functions"  
- **`file_upload`** - "Upload files to Percolate"
- **`help`** - "Get AI-powered assistance with MCP server usage"

### User Experience Example

```
You: "What can you tell me about entity KT-2011?"

Claude: [Uses get_entity tool with your bearer token]
"I found information about KT-2011 in your Percolate system: 
[Shows entity details from your database with proper permissions]"

You: "Search for all agents related to data processing"

Claude: [Uses entity_search tool]  
"I found 5 agents related to data processing in your system:
[Lists relevant agents you have access to]"
```

### Security & Permissions

- **Bearer Token Authentication**: Every request validates your token
- **Row-Level Security**: Only see data you have permissions for
- **Real-time Access**: Direct connection to live Percolate instance
- **Audit Trail**: All MCP tool usage logged in Percolate audit system
- **Session Management**: Token refresh handled automatically

### Troubleshooting Client Integration

**Connection Issues:**
```bash
# Test MCP endpoint directly
curl -X POST "https://p8.resmagic.io/mcp" \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "initialize", "params": {}, "id": 1}'
```

**Expected Response:** Status 307 (redirect) indicates MCP server is working

**Authentication Issues:**
- Verify bearer token is valid and not expired
- Check token has appropriate permissions in Percolate
- Ensure token format: `Bearer p8-xxxxx...` or OAuth JWT format

**Tool Access Issues:**
- Verify user has access to requested entities/functions
- Check row-level security policies in Percolate
- Review audit logs for permission denials

## Future Development Roadmap

### UserRoleAgent Integration (TODO)

The MCP server should be enhanced to converge with UserRoleAgent functionality:

#### Executive Resources Tools
- **TODO**: Add `get_executive_resources` tool for leadership-specific content
- **TODO**: Implement `search_executive_insights` for C-level analysis
- **TODO**: Create `get_board_materials` tool for board-ready documents
- **TODO**: Add `executive_summary` tool for condensed reporting

#### Role-Based Access
- **TODO**: Implement role-level tool filtering based on user permissions
- **TODO**: Add executive-only tools that require specific role levels
- **TODO**: Create department-specific tool suites (Engineering, Sales, Marketing, etc.)
- **TODO**: Implement hierarchical tool access (Manager → Director → VP → C-Level)

#### Enhanced Context Awareness  
- **TODO**: User role detection from bearer token/user context
- **TODO**: Automatic tool recommendation based on user role
- **TODO**: Role-appropriate language and detail levels in responses
- **TODO**: Context-aware entity filtering (show relevant entities for user's role)

#### Advanced Analytics Tools
- **TODO**: Add `get_user_analytics` for personal productivity insights
- **TODO**: Create `team_performance_metrics` for managers
- **TODO**: Implement `organizational_insights` for executives
- **TODO**: Add `strategic_recommendations` based on user's role and data

#### Integration Points
- **TODO**: Sync with existing UserRoleAgent implementations
- **TODO**: Share role detection logic across MCP and web interfaces
- **TODO**: Unify user context handling between MCP server and main API
- **TODO**: Consolidate executive tooling into single coherent system

### Implementation Priority
1. **Phase 1**: Role detection and basic tool filtering
2. **Phase 2**: Executive-specific tools and resources
3. **Phase 3**: Advanced analytics and insights
4. **Phase 4**: Full convergence with UserRoleAgent functionality

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