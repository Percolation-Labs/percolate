CONTEXT=$(curl -s $REST/rpc/sql_passthrough -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
  -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d "{\"p_statement\": \"select memory.context('Ana Costa') as context\"}" | jq -r '.[0].context')
jq -n --arg c "What you know about Ana, each line with when it held:
$CONTEXT" '{model: "ana-assistant", stream: false, messages: [{role: "system", content: $c},
  {role: "user", content: "Is my booking on 3 November going through the right port?"}]}' \
| curl -s $AGENT/chat -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' -d @- \
| jq -r '.choices[0].message.content // .'
