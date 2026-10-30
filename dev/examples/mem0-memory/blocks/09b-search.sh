EMB=$(curl -s http://localhost:$P8_CONTENT_PORT/embed -H "Authorization: Bearer $MAYA" \
  -H 'Content-Type: application/json' -d '{"texts": ["how does Maya like to travel"]}' | jq -c '.vectors[0]')
for who in "$MAYA" "$LEO"; do
  curl -s $REST/rpc/query -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' -H "Authorization: Bearer $who" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg q 'SEARCH "how does Maya like to travel" FROM chunks USING bge-small-en-v1.5 LIMIT 3' \
          --argjson e "$EMB" '{p_query: $q, p_embedding: ($e|tostring)}')" | jq -c '{found: (.rows | length)}'
done
