mcp read_session "{\"session_id\": \"$SESSION\"}" | jq -c '.result[] | {at, said, message_id}'
