for s in decided moot; do mcp list_judgements "{\"status\": \"$s\"}" | jq -c '.result[] | {label, claimed_kind, status, tier}'; done
