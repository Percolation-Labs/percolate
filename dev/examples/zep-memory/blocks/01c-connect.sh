ANA=$(percolate auth token --email ana@example.com --ttl 28800)
mcp() { curl -s http://localhost:${P8_QUERY_MCP_PORT:?add P8_QUERY_MCP_PORT to .env and source it again} \
          -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
          -d "$(jq -cn --arg t "$1" --argjson a "$2" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $t, arguments: $a}}')" \
        | jq '.result.structuredContent // .result // .'; }
mcp list_judgements '{}'
