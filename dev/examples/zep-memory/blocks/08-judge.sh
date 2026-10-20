open_item() { mcp list_judgements '{"status": "open"}' | jq -r --arg l "$1" --arg k "$2" '.result[] | select(.label == $l and .claimed_kind == $k) | .id'; }
decide() { mcp decide_judgement "$(jq -cn --arg id "$1" --argjson v "$2" --arg r "$3" '{id: $id, verdict: $v, reason: $r}')" \
             | jq -c '{status, verdict: .verdict.decision, tier, decided_by}'; }
bind() {
  J=$(open_item "$1" "$2")
  T=$(mcp claim_judgement "{\"id\": \"$J\"}" | jq -r '.evidence.candidates[0].node_id')
  decide "$J" "{\"decision\": \"bind\", \"target\": \"$T\"}" "$3"
}
twin() {
  J=$(open_item "$1" "$2")
  mcp claim_judgement "{\"id\": \"$J\"}" > /dev/null
  decide "$J" '{"decision": "none"}' "$3"
}
bind 'A. Costa' person 'The March email is signed A. Costa, Logistics, Tagus Ceramics; Ana Costa works at Tagus Ceramics. A. is Ana.'
twin 'Ana Costa' person 'Decided with its twin: A. Costa is now this node.'
bind 'Tagus Ceramics' organization 'One company, typed as a company in January and an organization in March.'
twin 'Tagus Ceramics' company 'Decided with its twin: the organization is now this node.'
