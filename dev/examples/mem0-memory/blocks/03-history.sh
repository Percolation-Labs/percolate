reg() { curl -s $REST/rpc/register_text -H 'Content-Profile: content' -H "Authorization: Bearer $MAYA" \
          -H 'Content-Type: application/json' -d "$1" | jq -c '{status, resource_id}'; }
reg '{"p_channel": "memory", "p_external_id": "maya-home-2026-01",
      "p_chunks": [{"content": "Maya lives in Leeds."}], "p_metadata": {"said_at": "2026-01-05T09:00:00Z"}}'
reg '{"p_channel": "memory", "p_external_id": "maya-home-2026-06",
      "p_chunks": [{"content": "Maya moved to Lisbon for a job at Harbour Health."}], "p_metadata": {"said_at": "2026-06-01T10:00:00Z"}}'
