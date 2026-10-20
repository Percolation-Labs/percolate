open_item() { mcp list_judgements '{"status": "open"}' | jq -r --arg l "$1" --arg k "$2" '.result[] | select(.label == $l and .claimed_kind == $k) | .id'; }
claim() { mcp claim_judgement "{\"id\": \"$1\"}" | jq -c '{label: .evidence.label, kind: .evidence.claimed_kind, candidates: [.evidence.candidates[] | {node_id, summary, candidate, sim}]}'; }
look() { echo "GRAPH $1:"; mcp query "$(jq -cn --arg q "GRAPH \"$1\"" '{query: $q}')" | jq -c '[.rows[] | "\(.relation) \(.key)"]'; }
decide() { mcp decide_judgement "$(jq -cn --arg id "$1" --argjson v "$2" --arg r "$3" '{id: $id, verdict: $v, reason: $r}')" \
             | jq -c '{status, verdict: .verdict.decision, tier, decided_by}'; }

J=$(open_item 'A. Costa' person); claim $J | tee claim.json; look 'A. Costa'; look 'Ana Costa'
decide $J "{\"decision\": \"bind\", \"target\": $(jq '.candidates[0].node_id' claim.json)}" \
  'Same surname and initial, a person both times; both work at Tagus Ceramics, and nothing either says conflicts.'
J=$(open_item 'Ana Costa' person); claim $J
decide $J '{"decision": "none"}' 'No candidate left: A. Costa, the one it had, is now this node.'

J=$(open_item 'Tagus Ceramics' organization); claim $J | tee claim.json; look 'Ana Costa'
decide $J "{\"decision\": \"bind\", \"target\": $(jq '.candidates[0].node_id' claim.json)}" \
  'Same name, typed an organization by one reader and a company by another; Ana works at both, so they are one employer.'
J=$(open_item 'Tagus Ceramics' company); claim $J
decide $J '{"decision": "none"}' 'No candidate left: the organization, the one it had, is now this node.'
