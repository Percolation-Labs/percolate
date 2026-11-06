cat > maya-mcp.json <<JSON
{"mcpServers": {"percolate": {"type": "http", "url": "http://localhost:$P8_QUERY_MCP_PORT",
                              "headers": {"Authorization": "Bearer $MAYA"}}}}
JSON
mcp() { curl -s http://localhost:$P8_QUERY_MCP_PORT -H "Authorization: Bearer $MAYA" \
          -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
          -d "$(jq -cn --arg t "$1" --argjson a "$2" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $t, arguments: $a}}')" \
        | jq '.result.structuredContent // .result // .'; }
mcp list_judgements '{}'
