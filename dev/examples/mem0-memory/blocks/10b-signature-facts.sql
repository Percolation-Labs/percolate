-- psql, as p8: another reader, signature-reader, reads her email signature and types Harbour Health an organization
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"organization","n":"Harbour Health"}],"edges":[{"s":0,"t":1,"r":"works_at"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-signature-2026-09'),
                    'agent', 'signature-reader', 'valid_from', '2026-09-15T08:00:00Z')) ->> 'edges_new' as signature;
-- where she works, each fact with its sources
select k.key as object, e.valid_from::date as held_from, jsonb_array_length(e.provenance->'sources') as sources,
       (select string_agg(c.content, ' | ')
          from jsonb_array_elements(e.provenance->'sources') src
          join content.resource_chunks c on c.resource_id::text = src->>'resource_id') as said
  from aiq.edges e
  join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.relation = 'works_at'
 order by e.valid_from;
