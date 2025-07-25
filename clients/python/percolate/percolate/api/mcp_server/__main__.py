"""Entry point for running MCP server standalone"""

import sys
from .server import run_stdio


def main():
    """Main entry point for standalone MCP server"""
    if len(sys.argv) > 1 and sys.argv[1] == "http":
        # HTTP mode runs through the main API
        print("For HTTP mode, run the main Percolate API server.")
        print("The MCP server is available at /mcp endpoint.")
        sys.exit(1)
    else:
        run_stdio()


if __name__ == "__main__":
    main()