q() { curl -s $REST/rpc/query -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
        -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg q "$2" '{p_query: $q}')"; }
q "$MAYA" "GRAPH \"Maya Okafor\" AS OF '2026-03-01'" | jq -c '{seed: .seed.key, rows: [.rows[] | {key, relation}]}'
q "$MAYA" 'GRAPH "Maya Okafor"' | jq -c '[.rows[] | {key, relation}]'
