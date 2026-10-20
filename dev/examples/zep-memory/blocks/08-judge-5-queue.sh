mcp list_judgements '{}' | jq -c '.result[] | {label, claimed_kind, status}'
