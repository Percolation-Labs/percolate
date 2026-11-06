curl -s -X DELETE "$REST/resources?external_id=eq.ana-email-2026-03" -H 'Content-Profile: content' \
  -H "Authorization: Bearer $ANA" -H 'Prefer: return=representation' | jq -c '[.[] | {external_id, said_at: .metadata.said_at}]'
q 'GRAPH "Ana Costa"' | jq -r '.rows[] | "\(.relation)\t\(.key)"' | sort
