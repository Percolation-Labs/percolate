q() { curl -s $REST/rpc/query -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
        -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
        -d "$(jq -cn --arg q "$1" '{p_query: $q}')"; }
q 'GRAPH "Ana Costa"' | jq -r '.rows[] | "\(.relation)\t\(.key)"' | sort
