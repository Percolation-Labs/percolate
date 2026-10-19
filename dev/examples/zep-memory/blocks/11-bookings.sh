STMT="select b.id, b.departs, p.name as booked_via, d.summary as ships_via_by_then
        from crm.bookings b
        join crm.ports p on p.id = b.port_id
        left join aiq.edges e on e.relation = 'ships_via' and aiq.edge_is_current(e.valid_from, e.valid_to, b.departs)
                             and e.src_id = (select node_id from aiq.lookup('Ana Costa'))
        left join aiq.nodes d on d.id = e.dst_id
       order by b.departs"
curl -s $REST/rpc/sql_passthrough -H 'Content-Profile: aiq' -H 'Accept-Profile: aiq' \
  -H "Authorization: Bearer $ANA" -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg s "$STMT" '{p_statement: $s}')" | jq -c '.[]'
