mcp() {
  curl -s http://localhost:$P8_QUERY_MCP_PORT/mcp -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg n "$1" --argjson a "$2" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $n, arguments: $a}}')" \
  | jq -c '.result.structuredContent'
}
J=$(mcp list_judgements '{}' | jq -r '.result[] | select(.candidates > 0) | .id')
TARGET=$(mcp claim_judgement "{\"id\": \"$J\"}" | jq -r '.evidence.candidates[0].node_id')
mcp decide_judgement "{\"id\": \"$J\", \"verdict\": {\"decision\": \"bind\", \"target\": \"$TARGET\"},
  \"reason\": \"P. Raman prefers DuckDB in the March session, on the same team list and project as Priya Raman\"}" \
| jq -c '{status, decided_by, tier}'
