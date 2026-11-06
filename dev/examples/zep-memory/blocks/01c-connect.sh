ANA=$(percolate auth token --email ana@example.com --ttl 28800)
LEO=$(percolate auth token --email leo@example.com --ttl 28800)
cat > ana-mcp.json <<JSON
{"mcpServers": {"percolate": {"type": "http", "url": "http://localhost:$P8_QUERY_MCP_PORT",
                              "headers": {"Authorization": "Bearer $ANA"}}}}
JSON
mcp() { curl -s http://localhost:$P8_QUERY_MCP_PORT -H "Authorization: Bearer $ANA" \
          -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
          -d "$(jq -cn --arg t "$1" --argjson a "$2" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $t, arguments: $a}}')" \
        | jq '.result.structuredContent // .result // .'; }
mcp list_judgements '{}'
