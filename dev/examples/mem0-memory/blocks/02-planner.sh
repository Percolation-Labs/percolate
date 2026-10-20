MAYA=$(percolate auth token --email maya@example.com --ttl 28800)
LEO=$(percolate auth token --email leo@example.com --ttl 28800)
curl -s $REST/rpc/upsert_agent -H 'Content-Profile: agentic' \
  -H "Authorization: Bearer $MAYA" -H 'Content-Type: application/json' \
  -d '{"p_spec": {"name": "maya-planner", "model": "openai:gpt-4o-mini",
       "system_prompt": "You help Maya plan trips and meals. Before you suggest anything, look up what you know about her with the query tool: LOOKUP \"Maya Okafor\", then GRAPH it.",
       "tools": [{"server": "harbour-query", "tools": ["query"]}]}}' | jq -c '{name, visibility}'
