select d.summary as place, p.valid_from::date as held_from,
       coalesce(p.valid_to::date::text, 'now') as until, c.content as said
  from aiq.edge_periods p
  join aiq.nodes d on d.id = p.dst_id
  cross join lateral jsonb_array_elements(p.provenance->'sources') src
  join content.resource_chunks c on c.resource_id::text = src->>'resource_id'
 where p.relation = 'lives_in'
 order by p.valid_from;
