select k.key as object, e.valid_from::date as held_from, jsonb_array_length(e.provenance->'sources') as sources,
       (select string_agg(c.content, ' | ')
          from jsonb_array_elements(e.provenance->'sources') src
          join content.resource_chunks c on c.resource_id::text = src->>'resource_id') as said
  from aiq.edges e
  join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.relation = 'works_at' and aiq.edge_is_current(e.valid_from, e.valid_to, now())
 order by e.valid_from;
