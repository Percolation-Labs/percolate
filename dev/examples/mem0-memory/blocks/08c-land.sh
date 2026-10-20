MSG=$(mcp read_session "{\"session_id\": \"$SESSION\"}" | jq -r '.result[0].message_id')
mcp land_message_facts "{\"message_id\": \"$MSG\", \"graph\": {
  \"nodes\": [{\"k\": \"person\", \"n\": \"Maya Okafor\"}, {\"k\": \"diet\", \"n\": \"vegetarian\"}, {\"k\": \"food\", \"n\": \"peanuts\"}],
  \"edges\": [{\"s\": 0, \"t\": 1, \"r\": \"diet\"}, {\"s\": 0, \"t\": 2, \"r\": \"allergic_to\"}]}}" \
  | jq -c '{edges_new, edges_merged, node_residence}'
