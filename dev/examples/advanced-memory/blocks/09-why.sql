select e.relation, k.key, e.valid_from::date as held_from, e.valid_to::date as held_to,
       jsonb_path_query_array(e.provenance, '$.sources[*].run_id') as runs
  from aiq.edges e
  join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.src_id = (select node_id from aiq.lookup('Priya Raman'))
 order by e.valid_from, e.relation;

select s.claimed_kind || '/' || s.key as name, r.decided_by, r.tier,
       coalesce(r.evidence ->> 'why', r.evidence ->> 'rule') as why,
       (r.evidence -> 'name' ->> 'kept')::boolean as name_kept
  from aiq.node_resolutions r join aiq.soft_nodes s on s.id = (r.evidence ->> 'soft_id')::uuid
 order by r.at;
