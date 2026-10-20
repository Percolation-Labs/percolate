MSG=$(mcp read_session "{\"session_id\": \"$SESSION\"}" | jq -r '.result[0].message_id')
mcp land_message_facts "{\"message_id\": \"$MSG\", \"graph\": {
  \"nodes\": [{\"k\": \"person\", \"n\": \"Ana Costa\"}, {\"k\": \"port\", \"n\": \"Felixstowe\"}, {\"k\": \"place\", \"n\": \"Porto\"}],
  \"edges\": [{\"s\": 0, \"t\": 1, \"r\": \"ships_via\"}, {\"s\": 0, \"t\": 2, \"r\": \"based_in\"}]}}" \
  | jq -c '{edges_new, edges_merged, node_residence}'
