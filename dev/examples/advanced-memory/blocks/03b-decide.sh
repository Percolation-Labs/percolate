TARGET=$(echo "$CLAIM" | jq -r '.evidence.candidates[0].node_id')
REASON='Session, 3 March: "P. Raman: DuckDB read a year of the harbour logs in four seconds, so I would move the harbour analytics to it." Session, 12 January, of the only candidate: "Priya Raman, harbour analytics lead: the Harbour Rewrite stays on Postgres for now." The same initial and surname, both on the harbour analytics.'
mcp decide_judgement "$(jq -cn --arg id "$J" --arg t "$TARGET" --arg r "$REASON" '{id: $id, verdict: {decision: "bind", target: $t}, reason: $r}')" \
| jq -c '{status, decided_by, tier}'
