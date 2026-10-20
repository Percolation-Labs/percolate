EMB=$(curl -s https://api.openai.com/v1/embeddings -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H 'Content-Type: application/json' -d '{"model": "text-embedding-3-small", "input": "how does Maya like to travel"}' \
  | jq -c '.data[0].embedding')
for who in "$MAYA" "$LEO"; do
  curl -s $REST/rpc/query -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' -H "Authorization: Bearer $who" \
    -H 'Content-Type: application/json' \
    -d "$(jq -cn --arg q 'SEARCH "how does Maya like to travel" FROM chunks USING text-embedding-3-small LIMIT 3' \
          --argjson e "$EMB" '{p_query: $q, p_embedding: ($e|tostring)}')" | jq -c '{found: (.rows | length)}'
done
