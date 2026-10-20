TARGET=$(echo "$CLAIM" | jq -r '.evidence.candidates[0].node_id')
mcp decide_judgement "{\"id\": \"$J\", \"verdict\": {\"decision\": \"bind\", \"target\": \"$TARGET\"},
  \"reason\": \"Initial and surname match Priya Raman, the only candidate: a person on the team list\"}" \
| jq -c '{status, decided_by, tier}'
