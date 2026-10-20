curl -s $AGENT/chat -H "Authorization: Bearer $LEO" -H 'Content-Type: application/json' \
  -d '{"model": "leo-planner", "stream": false,
       "messages": [{"role": "user", "content": "Where does Maya Okafor live, and is she allergic to anything?"}]}' \
  | jq -r '.choices[0].message.content // .'
