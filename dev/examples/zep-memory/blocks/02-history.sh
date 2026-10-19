ANA=$(percolate auth token --email ana@example.com)
reg() { curl -s $REST/rpc/register_text -H 'Content-Profile: content' -H "Authorization: Bearer $ANA" \
          -H 'Content-Type: application/json' -d "$1" | jq -c '{status, resource_id}'; }
reg '{"p_channel": "memory", "p_external_id": "ana-support-2026-01",
      "p_chunks": [{"content": "Ana Costa of Tagus Ceramics, Lisbon: our containers ship via Rotterdam."}],
      "p_metadata": {"said_at": "2026-01-14T09:30:00Z"}}'
reg '{"p_channel": "memory", "p_external_id": "ana-email-2026-03",
      "p_chunks": [{"content": "A. Costa, Logistics, Tagus Ceramics: please keep the inland legs on rail."}],
      "p_metadata": {"said_at": "2026-03-09T16:00:00Z"}}'
