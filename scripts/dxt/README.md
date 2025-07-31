# Percolate MCP Server

This extension provides MCP (Model Context Protocol) access to Percolate entities, functions, and memory.

## Installation

1. Install the DXT package in Claude Desktop:
   - Open Claude Desktop
   - Go to Extensions
   - Install `percolate-mcp.dxt`

2. During installation, you'll be prompted to configure:
   - **User Email** (required): Your email address for identification
   - **API Bearer Token** (required): Your P8 API bearer token for authentication
   - **About Section** (optional): Additional context for the MCP server

## Configuration

The extension uses the following configuration (set during installation):
- Bearer token is passed as `P8_TEST_BEARER_TOKEN` environment variable
- User email is passed as `P8_USER_EMAIL` and `X_User_Email`
- API endpoint defaults to `https://p8.resmagic.io`

## Features

- Entity search and management
- Function discovery and execution
- Memory operations
- File operations
- Chat completions with Percolate agents

## Building

To rebuild the extension after making changes:

```bash
./build.sh
dxt pack
mv dxt.dxt percolate-mcp.dxt
```

## Platform Compatibility

**Important**: This extension includes bundled Python dependencies to work without system packages. However, some dependencies (like `pydantic_core`) contain platform-specific compiled extensions (.so files on macOS, .pyd on Windows).

The bundled dependencies will only work on the platform where they were built. For cross-platform distribution:

1. Build separate packages for each platform
2. Or, ensure Claude Desktop has the required packages pre-installed:
   - fastmcp
   - httpx
   - pydantic

Claude Desktop appears to have these common packages pre-installed, so the extension should work without bundled dependencies in most cases.

## Known Limitations

- Memory tools require user email configuration
- File upload paths must be absolute
- Chat streaming may have latency depending on model/agent complexity