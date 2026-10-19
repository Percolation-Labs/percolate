-- psql, as p8: every fact about Ana, when it held, and the words that said it
select e.relation, k.key as object, e.valid_from::date as held_from, e.valid_to::date as held_to,
       (select string_agg(left(coalesce(c.content, m.content), 60), ' | ')
          from jsonb_array_elements(e.provenance -> 'sources') src
          left join content.resource_chunks c on c.resource_id::text = src ->> 'resource_id'
          left join agentic.messages m on src -> 'message_ids' ? m.id::text) as said,
       (select string_agg(distinct coalesce(src ->> 'agent', 'worker'), ', ')
          from jsonb_array_elements(e.provenance -> 'sources') src) as by
  from aiq.edges e
  join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.src_id = (select n.id from aiq.nodes n join aiq.soft_nodes s on n.entity_type = 'soft' and n.entity_id = s.id
                    where s.key = 'ana costa')
 order by e.valid_from, e.relation;

-- and every name bound to another, by whom, and why
select s.claimed_kind || '/' || s.key as name, r.decided_by, r.tier,
       left(coalesce(r.evidence ->> 'why', r.evidence ->> 'rule'), 70) as why
  from aiq.node_resolutions r join aiq.soft_nodes s on s.id = (r.evidence ->> 'soft_id')::uuid
 order by r.at;
