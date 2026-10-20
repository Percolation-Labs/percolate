mcp list_judgements '{}' | jq -c '.result[] | {label, claimed_kind, status, candidates: [.candidate_nodes[]? | {summary, entity_type, sim}]}'
