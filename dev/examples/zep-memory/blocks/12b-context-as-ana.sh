curl -s $REST/rpc/sql_passthrough -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
  -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d "{\"p_statement\": \"select memory.context('Ana Costa') as context\"}" | jq -r '.[0].context'
