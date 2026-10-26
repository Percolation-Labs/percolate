# Step 5: time. A fact that changed: the hallway lighting budget was $150, then the user raised it to $160. Walk the
# question offline from the sample's recorded verdicts, as step 3 does, then land what the walk read as edges that
# hold from the moment each message was said, and ask the graph what the answer is now and what it was before.
RUN=$(psql "$P8_DSN" -Atq <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'channel', q.metadata->>'channel',
         'question', q.metadata || jsonb_build_object('id', q.metadata->>'qid', 'text', q.metadata->>'question'),
         'replay', 'replay:' || (q.metadata->>'qid'),
         'offline', true))
  from content.resources q
 where q.uri = 'question:1M:22:knowledge_update:1';
SQL
)
until [ "$(psql "$P8_DSN" -Atc "select status not in ('pending', 'running') from workflow.runs where id = '$RUN'")" = t ]; do
  sleep 2
done

psql "$P8_DSN" -v run="$RUN" <<'SQL'
-- The evidence the walk read, and when each message was said. The answer key marks which reads are evidence here;
-- in use a decider would.
create temp view evidence as
select r.wave, r.doc, x.id, (x.metadata->>'said_at')::timestamptz as said_at, x.metadata->>'terms_text' as said
  from aiq.walk_reads(:'run') r
  join content.resources x on x.uri = r.doc
 where r.doc in (select jsonb_array_elements_text(aiq.walk_summary(:'run')->'question'->'gold'));
select wave, doc, said_at, said from evidence order by said_at;

-- Each piece lands as an edge from the question to the document, holding from when it was said. The graph's
-- vocabulary takes the relation first; then aiq.upsert_graph writes it, as part two lands what a memory says.
select 'answered_in' as relation from aiq.register_graph_vocabulary(
  '[{"relation": "answered_in", "description": "a document answers the question, or part of it, from when it was said"}]');
select e.doc, aiq.upsert_graph(
         jsonb_build_object('nodes', jsonb_build_array(jsonb_build_object('k', 'document', 'n', 'question:1M:22:knowledge_update:1'),
                                                       jsonb_build_object('k', 'document', 'n', e.doc)),
                            'edges', '[{"s": 0, "t": 1, "r": "answered_in"}]'::jsonb),
         jsonb_build_object('resource_id', e.id, 'valid_from', e.said_at, 'agent', 'walk')) ->> 'edges_new' as landed
  from evidence e order by e.said_at;

-- On a knowledge update the latest word holds: the last message ends the earlier ones' edges at the moment it was
-- said. Here that follows from the question's type; in use a decider would judge that /688 changes what /671 and
-- /675 said rather than adding to it.
select e.doc, aiq.close_edge(jsonb_build_object('resource_id', e.id, 'relation', 'answered_in'), l.said_at,
                             jsonb_build_object('resource_id', l.id, 'agent', 'walk')) ->> 'valid_to' as ended
  from evidence e, (select * from evidence order by said_at desc limit 1) l
 where e.id <> l.id order by e.said_at;

-- One query, two moments: the answer now, and as of 00:11:20 on 12 August 2024, between the two budgets. Time is
-- the graph's own: aiq.edge_is_current reads each edge's valid_from and valid_to.
select t.asked, d.summary as document, x.metadata->>'terms_text' as said
  from (values (1, 'now', now()), (2, '2024-08-12 00:11:20', timestamptz '2024-08-12 00:11:20+00')) t(n, asked, at)
  join aiq.nodes q on q.entity_type = 'document'
                  and q.entity_id = (select id from content.resources where uri = 'question:1M:22:knowledge_update:1')
  join aiq.edges a on a.src_id = q.id and a.relation = 'answered_in' and aiq.edge_is_current(a.valid_from, a.valid_to, t.at)
  join aiq.nodes d on d.id = a.dst_id
  join content.resources x on x.id = d.entity_id
 order by t.n, x.metadata->>'said_at';
SQL
