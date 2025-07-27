# Claude Desktop MCP Configuration for Percolate

This guide shows how to configure Claude Desktop to use the Percolate MCP server with authenticated API access.

## Prerequisites

1. Claude Desktop application installed
2. Percolate API access with:
   - API endpoint URL (e.g., `https://p8.resmagic.io`)
   - Bearer token
   - User email

## Configuration

Add the following to your Claude Desktop MCP configuration file:

### macOS/Linux
Location: `~/.config/claude/claude_desktop_config.json`

### Windows
Location: `%APPDATA%\claude\claude_desktop_config.json`

### Configuration Example

```json
{
  "mcpServers": {
    "percolate": {
      "command": "python",
      "args": ["-m", "percolate.api.mcp_server"],
      "cwd": "/path/to/percolate/clients/python/percolate",
      "env": {
        "P8_API_ENDPOINT": "https://p8.resmagic.io",
        "P8_API_KEY": "your-bearer-token-here",
        "X_User_Email": "your-email@example.com",
        "P8_USE_API_MODE": "true",
        "P8_DEFAULT_AGENT": "executive-ExecutiveResources",
        "P8_DEFAULT_NAMESPACE": "executive",
        "P8_DEFAULT_ENTITY": "ExecutiveResources",
        "P8_LOG_LEVEL": "INFO"
      }
    }
  }
}
```

## Environment Variables

### Required
- `P8_API_ENDPOINT`: The Percolate API URL
- `P8_API_KEY`: Your bearer token for authentication
- `X_User_Email`: Your user email for context

### Optional (with defaults)
- `P8_DEFAULT_AGENT`: Default agent for chat completions (default: `executive-ExecutiveResources`)
- `P8_DEFAULT_NAMESPACE`: Default namespace for uploads (default: `executive`)
- `P8_DEFAULT_ENTITY`: Default entity for resources (default: `ExecutiveResources`)
- `P8_LOG_LEVEL`: Logging level (default: `INFO`)

## Available Tools

Once configured, you'll have access to these MCP tools in Claude Desktop:

1. **help** - Get AI-powered assistance from PercolateAgent
   - Query the knowledge base
   - Get contextual help
   - Adjustable search depth

2. **entity_search** - Search for entities in Percolate
   - Query by name or description
   - Apply filters
   - Limit results

3. **get_entity** - Retrieve specific entity details
   - Get by entity name
   - Optional entity type for faster lookup

4. **function_search** - Find available functions
   - Search by name or description
   - Discover tools and capabilities

5. **function_eval** - Execute functions
   - Run specific functions by name
   - Pass arguments as JSON

6. **file_upload** - Upload files to Percolate
   - Upload content for ingestion
   - Specify namespace and entity
   - Add to ExecutiveResources by default

7. **resource_search** - Search uploaded resources
   - Find documents and files
   - Filter by type
   - Search within namespace

## Testing the Configuration

1. Restart Claude Desktop after updating the configuration
2. In a new conversation, you should see "percolate" listed as an available MCP server
3. Try asking Claude to:
   - "Use the percolate MCP server to search for executive resources"
   - "Help me understand what's available in the executive namespace"
   - "Upload this content to ExecutiveResources: [your content]"

## Troubleshooting

### MCP Server Not Showing
- Ensure the Python path is correct
- Verify the percolate package is installed
- Check the cwd path points to the correct directory

### Authentication Errors
- Verify your bearer token is correct
- Ensure X_User_Email matches your account
- Check the API endpoint URL

### Tool Execution Errors
- Review the P8_LOG_LEVEL output
- Ensure you have permissions for the requested operations
- Check namespace and entity names are correct

## Security Notes

- The bearer token is stored in the Claude Desktop configuration
- Ensure the configuration file has appropriate permissions
- Consider using environment variables for sensitive values
- Tokens should be rotated regularly

## Example Usage

Once configured, you can interact with Percolate directly through Claude:

```
You: Can you search for any executive planning documents in Percolate?

Claude: I'll search for executive planning documents using the Percolate MCP server.

[Uses entity_search tool with query "executive planning"]

I found 3 relevant documents in the executive namespace...
```

This integration allows Claude Desktop to directly access your Percolate knowledge base while maintaining proper authentication and security.