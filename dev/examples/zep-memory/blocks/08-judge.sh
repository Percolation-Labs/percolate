NOTES=$(psql "$P8_DSN" -Atc "select string_agg(c.content, ' / ' order by r.external_id) from content.resource_chunks c
          join content.resources r on r.id = c.resource_id where r.external_id like 'ana-%'")
VERDICT=$(jq -n --arg notes "$NOTES" '{model: "gpt-4o", temperature: 0,
    messages: [{role: "user", content: ("Are \"A. Costa\" and \"Ana Costa\" the same person? Decide from these notes alone, and give your reason in one sentence: " + $notes)}],
    response_format: {type: "json_schema", json_schema: {name: "verdict", strict: true, schema: {type: "object",
      additionalProperties: false, required: ["same", "why"],
      properties: {same: {type: "boolean"}, why: {type: "string"}}}}}}' \
  | curl -s https://api.openai.com/v1/chat/completions -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H 'Content-Type: application/json' -d @- | jq -r '.choices[0].message.content')
echo "$VERDICT"
psql "$P8_DSN" -v verdict="$VERDICT" <<'SQL'
select aiq.promote_soft_node(
         (select id from aiq.soft_nodes where key = 'a. costa'),
         (select n.id from aiq.nodes n join aiq.soft_nodes s on n.entity_type = 'soft' and n.entity_id = s.id
           where s.key = 'ana costa'),
         'gpt-4o', 'llm', :'verdict'::jsonb) ->> 'moved' as moved
 where (:'verdict'::jsonb ->> 'same')::boolean;
SQL
