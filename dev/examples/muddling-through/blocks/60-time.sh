# Step 5: time, on two clocks. A fact that changed: the hallway lighting budget was $150, then the user raised it to
# $160. Walk the question offline from the sample's recorded verdicts, as step 3 does, land what the walk read as edges
# that hold from the moment each message was said, in two landings, and ask the graph what the budget was at two
# moments of the conversation, as the agent knew it after each landing.
# The recorded verdicts were given under span 2 and cap 10, the defaults before 0.2.33, so the walk is pinned to them:
# under wider settings it would raise leads its replay never judged.
RUN=$(psql "$P8_DSN" -Atq <<'SQL'
select workflow.start_workflow('walk', jsonb_build_object(
         'channel', q.metadata->>'channel',
         'question', q.metadata || jsonb_build_object('id', q.metadata->>'qid', 'text', q.metadata->>'question'),
         'replay', 'replay:' || (q.metadata->>'qid'),
         'offline', true, 'settings', jsonb_build_object('span', 2, 'cap', 10)))
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
-- Two landings, staged so the second clock has something to show. BEAM has no such gap: the walk read all three
-- messages in its first wave. Here the agent records the two $150 messages first and hears about the raise later, as
-- it would if the conversation reached it in two parts. Two seconds stand in for the days between.
create temp view landing as
select e.doc, e.said_at, e.said_at = max(e.said_at) over () as last,
       jsonb_build_object('nodes', jsonb_build_array(jsonb_build_object('k', 'document', 'n', 'question:1M:22:knowledge_update:1'),
                                                     jsonb_build_object('k', 'document', 'n', e.doc)),
                          'edges', '[{"s": 0, "t": 1, "r": "answered_in"}]'::jsonb) as graph,
       jsonb_build_object('resource_id', e.id, 'valid_from', e.said_at, 'agent', 'walk') as context
  from evidence e;
select 1 as landing, doc, aiq.upsert_graph(graph, context) ->> 'edges_new' as landed from landing where not last order by said_at;
select 'two seconds later' as pause from pg_sleep(2);
select 2 as landing, doc, aiq.upsert_graph(graph, context) ->> 'edges_new' as landed from landing where last;

-- On a knowledge update the latest word holds: the last message ends the earlier ones' edges at the moment it was
-- said. Here that follows from the question's type; in use a decider would judge that /688 changes what /671 and
-- /675 said rather than adding to it.
select e.doc, aiq.close_edge(jsonb_build_object('resource_id', e.id, 'relation', 'answered_in'), l.said_at,
                             jsonb_build_object('resource_id', l.id, 'agent', 'walk')) ->> 'valid_to' as ended
  from evidence e, (select * from evidence order by said_at desc limit 1) l
 where e.id <> l.id order by e.said_at;

-- Every edge now carries two clocks. valid_from and valid_to say when the budget held, in the conversation's time.
-- created_at says when the agent recorded the edge, and close_edge recorded when it learned the edge had ended.
create temp view answers as
select a.id as edge, d.summary as document, (regexp_match(x.metadata->>'terms_text', '\$\d+'))[1] as budget,
       a.valid_from, a.valid_to, a.created_at as recorded, (a.provenance->'closed'->>'at')::timestamptz as end_recorded
  from aiq.nodes q
  join aiq.edges a on a.src_id = q.id and a.relation = 'answered_in'
  join aiq.nodes d on d.id = a.dst_id
  join content.resources x on x.id = d.entity_id
 where q.entity_type = 'document'
   and q.entity_id = (select id from content.resources where uri = 'question:1M:22:knowledge_update:1');
select document, budget, valid_from as held_from, valid_to as held_until,
       case when recorded = first then 'first landing' else 'second landing' end as recorded_in,
       case when end_recorded > first then 'second landing' end as end_recorded_in
  from answers, (select min(recorded) as first from answers) f
 order by valid_from;

-- One query, both clocks: the budget at two moments in the conversation, as the agent knew it after the first
-- landing and as it knows it now. aiq.edges_as_of(valid_at, known_at) reads both from the edges themselves: an edge
-- counts once it was recorded, and its end only once that end was recorded too.
select k.known, t.held, a.document, a.budget
  from (values (1, 'after the first landing', (select min(recorded) from answers)), (2, 'now', now())) k(n, known, at)
 cross join (values (1, '2024-08-12 00:11:20', timestamptz '2024-08-12 00:11:20+00'), (2, 'now', now())) t(n, held, at)
 cross join lateral aiq.edges_as_of(t.at, k.at) e
  join answers a on a.edge = e.id
 order by k.n, t.n, a.valid_from;

-- What the memory had wrong, and over which stretch of each clock: in the conversation, from 00:11:28, when the
-- budget changed; in the agent, from when it recorded the old budget until it recorded the change.
select o.document as held_wrong, o.budget as said, n.budget as actually, n.valid_from as wrong_from,
       n.recorded > o.recorded as corrected_later
  from answers o join answers n on n.valid_from = o.valid_to and n.valid_to is null
 order by o.valid_from;
SQL
