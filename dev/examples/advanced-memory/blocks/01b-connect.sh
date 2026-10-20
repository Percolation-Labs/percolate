claude mcp add --transport http percolate http://localhost:${P8_QUERY_MCP_PORT:?add P8_QUERY_MCP_PORT to .env and source it again} \
  --header "Authorization: Bearer $TOKEN"
