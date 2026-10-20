LEO=$(percolate auth token --email leo@example.com --ttl 3600)
curl -s $REST/rpc/sql_passthrough -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
  -H "Authorization: Bearer $LEO" -H 'Content-Type: application/json' \
  -d "{\"p_statement\": \"select memory.context('Ana Costa') as context\"}" | jq -c '.[0]'
curl -s $REST/rpc/query -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
  -H "Authorization: Bearer $LEO" -H 'Content-Type: application/json' \
  -d '{"p_query": "GRAPH \"Ana Costa\""}' | jq -c '{rows: (.rows | length)}'
