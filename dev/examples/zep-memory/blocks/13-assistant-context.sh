curl -s $REST/rpc/upsert_agent -H 'Content-Profile: agentic' \
  -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d '{"p_spec": {"name": "ana-assistant", "model": "openai:gpt-4o",
       "system_prompt": "You help Ana Costa with her freight bookings. First read what you know about her, with the query tool, in SQL: select memory.context('"'"'Ana Costa'"'"'). Each line says when it held, and a line that has ended is history. Her bookings are crm.bookings (id, departs, port_id) joined to crm.ports (id, name). When she asks about a booking, compare its port with the port she ships via now, and say so if they differ.",
       "tools": [{"server": "harbour-query", "tools": ["query"]}]}}' | jq -c '{name, visibility}'
curl -s $AGENT/chat -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d '{"model": "ana-assistant", "stream": false, "messages": [{"role": "user", "content":
       "Is my booking on 3 November going through the right port?"}]}' \
  | jq -r '.choices[0].message.content // .'
