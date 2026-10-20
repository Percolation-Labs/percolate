select left(m.content, 40) as said, s.summary as subject, e.relation, d.summary as object,
       src ->> 'agent' like 'agent:%' as by_her_agent
  from aiq.edges e
  cross join lateral jsonb_array_elements(e.provenance->'sources') src
  join agentic.messages m on src->'message_ids' ? m.id::text
  join aiq.nodes s on s.id = e.src_id
  join aiq.nodes d on d.id = e.dst_id
 order by e.relation;
