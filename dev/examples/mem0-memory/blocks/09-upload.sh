cat > maya-preferences.md <<'MD'
# Travel preferences

Maya Okafor travels with her partner, Ana Ribeiro. She prefers trains to flights
inside Europe, and window seats when she has to fly. She works at Harbour Health
and books her work trips through its travel desk.
MD
DOC=$(curl -s http://localhost:$P8_CONTENT_PORT/files -H "Authorization: Bearer $MAYA" \
  -H 'Content-Type: text/markdown' -H 'x-p8-title: Maya travel preferences' \
  --data-binary @maya-preferences.md | jq -r '.resource_id // .')
echo $DOC
show $(psql "$P8_DSN" -Atc "select id from workflow.runs where external_id = 'ingest:$DOC'")
