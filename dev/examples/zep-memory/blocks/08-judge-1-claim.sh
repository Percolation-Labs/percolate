open_item() { mcp list_judgements '{"status": "open"}' | jq -r --arg l "$1" --arg k "$2" '.result[] | select(.label == $l and .claimed_kind == $k) | .id'; }
claim() { mcp claim_judgement "{\"id\": \"$1\"}" | jq -c '{label: .evidence.label, kind: .evidence.claimed_kind, candidates: [.evidence.candidates[] | {node_id, key, summary, candidate, sim}]}'; }
look() { echo "GRAPH $1:"; mcp query "$(jq -cn --arg q "GRAPH \"$1\"" '{query: $q}')" | jq -c 'if .rows then [.rows[] | "\(.relation) \(.key)"] else . end'; }
decide() { mcp decide_judgement "$(jq -cn --arg id "$1" --argjson v "$2" --arg r "$3" '{id: $id, verdict: $v, reason: $r}')" \
             | jq -c '{status, verdict: .verdict.decision, tier, decided_by}'; }
J=$(open_item 'A. Costa' person); claim $J | tee claim.json; look 'A. Costa'; look 'Ana Costa'
