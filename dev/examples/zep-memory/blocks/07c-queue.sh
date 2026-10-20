mcp list_judgements '{"status": "open"}' | jq -c '.result[] | {label, claimed_kind, candidates: [.candidate_nodes[] | "\(.summary) (\(.candidate))"]}'
