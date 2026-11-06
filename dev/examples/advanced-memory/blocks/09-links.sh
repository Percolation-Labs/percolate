claude -p 'In Percolate, run this with the query tool:
select edge_id, fact, candidates from claims.facts_to_link('"'"'bge-small-en-v1.5'"'"')
Each row is a fact from my memory, with the questions nearest it. For each fact, choose the one question it bears
on, as evidence somebody answering that question would want, or none. Print one JSON object per fact, one per line,
and nothing else: {"fact": ..., "edge_id": ..., "question_id": ... or null, "p": your confidence from 0 to 1,
"reason": one sentence}.' --strict-mcp-config --mcp-config me-mcp.json --allowedTools mcp__percolate \
  | grep '^{' > links.jsonl
jq -c '{fact, chose_a_question: (.question_id != null), p, reason}' links.jsonl
psql "$P8_DSN" -X -v links="$(jq -sc . links.jsonl)" <<'SQL'
select set_config('request.jwt.claims', json_build_object('sub',
         (select id from rbac.users where email = 'me@example.com'))::text, false) as me \gset
select count(claims.propose_bears_on((l ->> 'edge_id')::uuid, (l ->> 'question_id')::uuid,
                                     (l ->> 'p')::real, 'Claude: ' || (l ->> 'reason'))) as proposed
  from jsonb_array_elements(:'links'::jsonb) l where l ->> 'question_id' is not null and (l ->> 'p')::real >= 0.5;
SQL
