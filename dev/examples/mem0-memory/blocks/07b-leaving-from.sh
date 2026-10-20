STMT="select b.departs, b.destination, d.summary as leaving_from from travel.bookings b
      join aiq.edge_periods p on p.relation = 'lives_in' and aiq.edge_is_current(p.valid_from, p.valid_to, b.departs)
      join aiq.nodes d on d.id = p.dst_id order by b.departs"
sp() { curl -s $REST/rpc/sql_passthrough -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
         -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
         -d "$(jq -cn --arg s "$STMT" '{p_statement: $s}')"; }
sp "$MAYA" | jq -c .
sp "$LEO"  | jq -c .
