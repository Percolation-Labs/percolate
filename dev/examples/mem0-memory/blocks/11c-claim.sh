open_item() { mcp list_judgements '{"status": "open"}' | jq -r --arg l "$1" --arg k "$2" '.result[] | select(.label == $l and .claimed_kind == $k) | .id'; }
said() { jq -c '[.[] | "\(.relation) \(.other): \(.said)"]'; }
claim() { mcp claim_judgement "{\"id\": \"$1\"}" | tee claim.json \
            | jq -c '{label: .evidence.label, kind: .evidence.claimed_kind}'
          echo 'said about it:'; jq '.evidence.said' claim.json | said
          jq -c '.evidence.candidates[] | {candidate: "\(.summary) (\(.candidate), sim \(.sim))", node_id}' claim.json
          echo 'said about the candidate:'; jq '.evidence.candidates[0].said' claim.json | said; }
decide() { mcp decide_judgement "$(jq -cn --arg id "$1" --argjson v "$2" --arg r "$3" '{id: $id, verdict: $v, reason: $r}')" \
             | jq -c '{status, verdict: .verdict.decision, tier, decided_by}'; }
J=$(open_item 'Harbour Health' organization); claim $J
