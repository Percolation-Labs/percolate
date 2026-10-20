mcp() {
  curl -s http://localhost:${P8_QUERY_MCP_PORT:?add P8_QUERY_MCP_PORT to .env and source it again} -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg n "$1" --argjson a "$2" '{jsonrpc: "2.0", id: 1, method: "tools/call", params: {name: $n, arguments: $a}}')" \
  | jq -c '.result.structuredContent'
}
J=$(mcp list_judgements '{}' | jq -r '.result[] | select(.candidates > 0) | .id')
CLAIM=$(mcp claim_judgement "{\"id\": \"$J\"}")
echo "$CLAIM" | jq '.evidence | {key, claimed_kind, candidates: [.candidates[] | {key, entity_type, candidate, sim}]}'
