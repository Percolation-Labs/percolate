curl -s $REST/rpc/upsert_agent -H 'Content-Profile: agentic' \
  -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d '{"p_spec": {"name": "ana-assistant", "model": "openai:gpt-4o-mini",
       "system_prompt": "You help Ana Costa with her freight bookings. Before you answer, look up what you know about her with the query tool: LOOKUP \"Ana Costa\", then GRAPH it.",
       "tools": [{"server": "harbour-query", "tools": ["query"]}]}}' | jq -c '{name, visibility}'
curl -s $AGENT/chat -D ana-headers.txt -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d '{"model": "ana-assistant", "stream": false, "messages": [{"role": "user", "content":
       "From this month our containers go through Felixstowe, and I am now based in our Porto office. Which port will my next booking use?"}]}' \
  | jq -r '.choices[0].message.content // .'
SESSION=$(grep -i x-p8-session-id ana-headers.txt | tr -d '\r' | cut -d' ' -f2)
