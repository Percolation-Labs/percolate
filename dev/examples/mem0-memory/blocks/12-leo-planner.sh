curl -s $REST/rpc/upsert_agent -H 'Content-Profile: agentic' \
  -H "Authorization: Bearer $LEO" -H 'Content-Type: application/json' \
  -d '{"p_spec": {"name": "leo-planner", "model": "openai:gpt-4o-mini",
       "system_prompt": "You help Leo plan trips. Answer questions about people by looking them up with the query tool: LOOKUP the name, then GRAPH it. Say so when the tool finds nothing.",
       "tools": [{"server": "harbour-query", "tools": ["query"]}]}}' | jq -c '{name, visibility}'
