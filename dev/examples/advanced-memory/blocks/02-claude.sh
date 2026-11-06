cat > me-mcp.json <<JSON
{"mcpServers": {"percolate": {"type": "http", "url": "http://localhost:$P8_QUERY_MCP_PORT",
                              "headers": {"Authorization": "Bearer $TOKEN"}}}}
JSON
claude -p 'Work through the judgements waiting for me in Percolate. Claim each open one, read what was said
about each side, and decide it with a reason that quotes what was said. End with one line per judgement: what it
asked, what you decided, and why.' --strict-mcp-config --mcp-config me-mcp.json --allowedTools mcp__percolate
