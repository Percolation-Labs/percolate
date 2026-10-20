curl -s $AGENT/chat -D maya-headers.txt -H "Authorization: Bearer $MAYA" -H 'Content-Type: application/json' \
  -d '{"model": "maya-planner", "stream": false, "messages": [
       {"role": "user", "content": "I am vegetarian and allergic to peanuts. Where should I eat near the office tonight?"}]}' \
  | jq -r '.choices[0].message.content // .'
SESSION=$(grep -i x-p8-session-id maya-headers.txt | tr -d '\r' | cut -d' ' -f2)
