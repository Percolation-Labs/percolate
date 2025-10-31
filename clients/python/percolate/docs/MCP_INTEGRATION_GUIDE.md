# Percolate MCP Server - Client Integration Guide

This guide shows how to integrate the Percolate MCP server with various MCP clients like Claude Desktop, VS Code extensions, and Claude Code.

## Production Endpoint

**MCP Server URL**: `https://p8.resmagic.io/mcp`

## Authentication Requirements

MCP clients must provide authentication via:

1. **Bearer Token**: OAuth JWT token with embedded user email (preferred)
2. **Environment Variables**: User email via `P8_USER_EMAIL` in client config
3. **API Key + Config**: API key with email from MCP server settings

### Authentication Priority Order:
1. Email from JWT token claims (`email`, `user_email`, `preferred_username`, `sub`)
2. Email from `P8_USER_EMAIL` environment variable in client config
3. Email from server configuration settings
4. Fallback to placeholder email for testing

## Getting Your Bearer Token

### Method 1: From Web Interface
1. Log into Percolate web interface at https://p8.resmagic.io
2. Open browser developer tools → Network tab
3. Make any API request (refresh page, search, etc.)
4. Copy the `Authorization: Bearer` token from any request headers

### Method 2: From Environment Variables
If you have Percolate set up locally:
```bash
echo $P8_TEST_BEARER_TOKEN
```

## Claude Desktop Integration

### Configuration

Add this to your Claude Desktop configuration file:

**Location**: 
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

**Configuration**:
```json
{
  "mcpServers": {
    "percolate": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-fetch"],
      "env": {
        "MCP_SERVER_URL": "https://p8.resmagic.io/mcp",
        "MCP_SERVER_AUTH": "Bearer your-percolate-token-here",
        "P8_USER_EMAIL": "your-email@company.com"
      }
    }
  }
}
```

**Important**: The user email should be embedded in the JWT token or passed via the `P8_USER_EMAIL` environment variable. Custom headers are not supported in MCP client configurations.

### Usage Example

Once configured, Claude will have access to Percolate tools:

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

## VS Code MCP Extension Integration

For VS Code extensions that support MCP:

### Configuration (example for MCP extensions)

```json
{
  "mcp.servers": {
    "percolate": {
      "url": "https://p8.resmagic.io/mcp",
      "auth": {
        "type": "bearer",
        "token": "your-percolate-token-here"
      },
      "env": {
        "P8_USER_EMAIL": "your-email@company.com"
      }
    }
  }
}
```

**Note**: The exact configuration format depends on the specific VS Code MCP extension being used. Check the extension documentation for the correct syntax.

## Claude Code Integration

For Claude Code CLI tool, you can configure MCP servers through environment variables or config files.

### Environment Variables
```bash
export MCP_PERCOLATE_URL="https://p8.resmagic.io/mcp"
export MCP_PERCOLATE_TOKEN="your-percolate-token-here"
export MCP_PERCOLATE_EMAIL="your-email@company.com"
```

## Available Tools

Once connected, you'll have access to these Percolate tools:

### Entity Management
- **`get_entity`** - Retrieve specific entities by name with fuzzy matching
  - Example: `get_entity("KT-2011")` → finds entity details
- **`entity_search`** - Semantic search across entities using natural language
  - Example: `entity_search("machine learning models for fraud detection")`

### AI-Powered Analysis
- **`ask_the_agent`** - AI-powered insights and analysis about your company data
  - Example: `ask_the_agent("What are the main security risks in our system?")`

### Function Discovery & Execution
- **`function_search`** - Find available functions/tools
- **`function_eval`** - Execute discovered functions

### File Operations
- **`file_upload`** - Upload files to Percolate
- **`resource_search`** - Search uploaded resources and documents

### Memory Management
- **`add_memory`** - Store information for later retrieval
- **`search_memories`** - Search through stored memories
- **`list_memories`** - List all stored memories

### Help & Support
- **`help`** - Get AI-powered assistance with MCP server usage

## Security & Permissions

- **Bearer Token Authentication**: Every request validates your token
- **Row-Level Security**: Only see data you have permissions for
- **Real-time Access**: Direct connection to live Percolate instance
- **Audit Trail**: All MCP tool usage logged in Percolate audit system
- **Session Management**: Token refresh handled automatically

## Troubleshooting

### Connection Issues

**Test the endpoint directly**:
```bash
curl -X POST "https://p8.resmagic.io/mcp" \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}'
```

**Note**: The user email should be embedded in the JWT token. For testing purposes, you can also set the `X-User-Email` header, but this is not the standard MCP approach.

**Expected Response**: HTTP 307 (redirect) indicates MCP server is working correctly

### Authentication Issues
- Verify bearer token is valid and not expired
- Check token has appropriate permissions in Percolate
- Ensure token format is correct: `Bearer p8-xxxxx...` or OAuth JWT format
- Verify user email matches your Percolate account

### Tool Access Issues
- Verify user has access to requested entities/functions
- Check row-level security policies in Percolate
- Review audit logs for permission denials

### Common Error Messages

1. **"Bearer token required"** → Missing or malformed Authorization header
2. **"Invalid bearer token"** → Token is expired or invalid
3. **"Entity not found"** → Entity doesn't exist or you don't have access
4. **HTTP 404** → Check URL is exactly `https://p8.resmagic.io/mcp`
5. **HTTP 307 + empty response** → Normal behavior, MCP protocol is working

## Advanced Configuration

### Custom Agent Configuration

You can specify which Percolate agent to use by setting environment variables:

```bash
# Use a specific agent for AI-powered tools
export P8_DEFAULT_AGENT="executive-ExecutiveResources"

# Use a specific model
export P8_DEFAULT_MODEL="gpt-4o"

# Add custom context about your MCP usage
export P8_MCP_ABOUT="Internal company knowledge base for engineering team"
```

### Role-Based Access

The MCP server automatically detects your role from your bearer token and provides appropriate tools:

- **Executive**: Access to board materials, executive summaries, strategic insights
- **Manager**: Team performance metrics, departmental analytics
- **Developer**: Technical documentation, code analysis, debugging tools
- **Analyst**: Data insights, reporting tools, visualization

## Example Workflows

### 1. Entity Discovery
```
1. Search for entity types: entity_search(entity_name="p8.Agent", query="")
2. Explore specific type: entity_search(entity_name="p8.Model", query="classification")
3. Get specific entity: get_entity("MyModel")
```

### 2. AI-Powered Analysis
```
1. Ask broad questions: ask_the_agent("What are our main data quality issues?")
2. Get specific insights: ask_the_agent("How is our fraud detection model performing?")
3. Strategic analysis: ask_the_agent("What opportunities exist in our customer data?")
```

### 3. Function Discovery & Execution
```
1. Search functions: function_search("email validation")
2. Execute function: function_eval("validate_email", {"email": "test@company.com"})
3. Chain operations: Use results from one function as input to another
```

## Support

For issues with MCP integration:

1. Check the troubleshooting section above
2. Verify your authentication credentials
3. Test the endpoint directly with curl
4. Review Percolate audit logs for detailed error information
5. Contact your system administrator for token or permission issues

## Security Best Practices

1. **Secure Token Storage**: Never commit tokens to version control
2. **Token Rotation**: Regularly refresh your bearer tokens
3. **Principle of Least Privilege**: Only request access to data you need
4. **Audit Monitoring**: Regularly review audit logs for unexpected usage
5. **Environment Isolation**: Use different tokens for development/production