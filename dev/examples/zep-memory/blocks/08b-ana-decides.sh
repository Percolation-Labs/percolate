aiq() { curl -s $REST/rpc/$1 -H 'Content-Profile: aiq' -H "Authorization: Bearer $ANA" \
          -H 'Content-Type: application/json' -d "$2"; }
for J in $(mcp list_judgements '{"status": "to_human"}' | jq -r '.result[] | select(.label == "A. Costa") | .id'); do
  T=$(aiq claim_judgement "{\"p_id\": \"$J\"}" | jq -r '.evidence.candidates[0].node_id')
  aiq complete_judgement "$(jq -cn --arg j "$J" --arg t "$T" '{p_id: $j, p_verdict: {decision: "bind", target: $t},
       p_tier: "human", p_reason: "That is me: I sign my email A. Costa, Logistics."}')" \
    | jq -c '{label: "A. Costa", status, verdict: .verdict.decision, tier}'
done
for J in $(mcp list_judgements '{"status": "to_human"}' | jq -r '.result[] | select(.label == "Ana Costa") | .id'); do
  aiq claim_judgement "{\"p_id\": \"$J\"}" > /dev/null
  aiq complete_judgement "$(jq -cn --arg j "$J" '{p_id: $j, p_verdict: {decision: "none"},
       p_tier: "human", p_reason: "Settled when I bound A. Costa to me."}')" \
    | jq -c '{label: "Ana Costa", status, verdict: .verdict.decision, tier}'
done
