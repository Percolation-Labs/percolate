-- MEM0'S QUICKSTART, CALL FOR CALL, ON PERCOLATE (REM-959).
--
-- Each block is one call from Mem0's quickstart -- add, search, get_all, get,
-- update, history, delete -- then its user/agent/run scopes and its entity
-- graph, then the two things Mem0 does not do: say why a memory changed, and
-- return nothing to a reader without permission. `specs/design/core-product.md`
-- §2.2 is the brief. The article that walks these blocks is the Percolate
-- writing piece "Percolate for Mem0 folks"; a block changed here is a block
-- changed there.
--
-- A call with no Percolate equivalent prints `GAP` and the card that owns it,
-- rather than being left out. Self-contained: no dev/init fixture is read, the
-- vectors are three hand-written dimensions (home, work, food) so the test
-- needs no embedding service, and the file rolls back.

\set ON_ERROR_STOP on

\set maya  '''00000000-0000-0000-0000-0000000959a1'''
\set leo   '''00000000-0000-0000-0000-0000000959b1'''
\set maya_org '''00000000-0000-0000-0000-0000000959a0'''
\set leo_org  '''00000000-0000-0000-0000-0000000959b0'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-0000000959a1","orgs":["00000000-0000-0000-0000-0000000959a0"]}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-0000000959b1","orgs":["00000000-0000-0000-0000-0000000959b0"]}''; set local role authenticated;'
\set as_operator 'reset role; reset request.jwt.claims;'

begin;

-- ---------------------------------------------------------------------
-- 0. SETUP, once per deployment. Mem0's `user_id` is a filter argument on
-- every call; here it is who the caller is, and each person is a tenant (an
-- org of one). A fresh core ships no roles, so writing needs a role carrying
-- resources:create. The embedding model is registered by the extension's
-- owner, which has to own the space to maintain it.
-- ---------------------------------------------------------------------
set local role app_owner;
insert into rbac.users (id, email) values (:maya, 'maya@mem0.test'), (:leo, 'leo@mem0.test');
insert into rbac.orgs (id, slug, name) values (:maya_org, 'mem0-maya', 'Maya'), (:leo_org, 'mem0-leo', 'Leo');
insert into rbac.org_members (org_id, user_id, role) values (:maya_org, :maya, 'member'), (:leo_org, :leo, 'member');
insert into rbac.roles (name) values ('member') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('member', 'resources', 'create') on conflict do nothing;
insert into rbac.user_roles values (:maya, 'member'), (:leo, 'member') on conflict do nothing;
insert into content.channels (name, kind, org_id, visibility)
    values ('memory', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
    values ('mem0-demo-3d', 3, null, 'vector_cosine_ops', false, 'home, work, food: written by hand');
select aiq.register_embedding_space('mem0-demo-3d') \g /dev/null
-- Mem0's entity graph has no relation vocabulary; this one is closed, and a
-- relation it does not hold is dropped and named in the receipt.
select aiq.register_graph_vocabulary('[{"relation":"lives_in"},{"relation":"works_at"},
    {"relation":"diet"},{"relation":"prefers"},{"relation":"allergic_to"}]') \g /dev/null
reset role;

-- ---------------------------------------------------------------------
-- 1. ADD.  m.add(messages, user_id="maya", agent_id=..., run_id=...)
--
-- Three writes, by three parties, as in the product: the user registers the
-- text, the embedder stores its vector, the extractor writes the fact into the
-- graph with provenance naming the memory, the agent and the run.
-- ---------------------------------------------------------------------
:as_maya
-- as Maya
select (content.register_text('memory', 'm-home', '[{"content":"Maya lives in Leeds."}]',
 null, null, :maya_org, '{"agent":"planner","run":"r01","quote":"I''m up in Leeds."}')->>'resource_id') as m_home \gset
select (content.register_text('memory', 'm-work', '[{"content":"Maya works at Northwind Analytics."}]',
            null, null, :maya_org, '{"agent":"planner","run":"r01"}')->>'resource_id') as m_work \gset
select (content.register_text('memory', 'm-food', '[{"content":"Maya is vegetarian."}]',
            null, null, :maya_org, '{"agent":"coach","run":"r02"}')->>'resource_id') as m_food \gset
select (content.register_text('memory', 'm-gym', '[{"content":"Maya prefers evening workouts."}]',
            null, null, :maya_org, '{"agent":"coach","run":"r02"}')->>'resource_id') as m_gym \gset
:as_leo
select (content.register_text('memory', 'l-home', '[{"content":"Leo lives in Leeds."}]',
            null, null, :leo_org, '{"agent":"planner","run":"r09"}')->>'resource_id') as l_home \gset
:as_operator

-- the embedder's write (worker-side; it computed these from the text)
insert into "aiq"."emb_mem0_demo_3d" (chunk_id, embedding)
select c.id, v.e::vector
  from (values (:'m_home', '[1,0,0]'), (:'m_work', '[0,1,0]'), (:'m_food', '[0,0,1]'),
               (:'m_gym', '[0.1,0.3,0.6]'), (:'l_home', '[1,0,0]')) v(rid, e)
  join content.resource_chunks c on c.resource_id = v.rid::uuid;
select set_config('mem0.m_food', :'m_food', true) \g /dev/null

-- the extractor's write. Mem0 links entities to a memory; this states the
-- relation between them, and says which memory, agent and run said so.
set local role worker;
-- as the worker
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Maya Okafor"},{"k":"soft","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}',
 json_build_object('resource_id', :'m_home', 'agent', 'planner', 'run_id', 'r01', 'valid_from', '2026-01-05T09:00:00Z', 'org_id', :maya_org)::jsonb);
select aiq.upsert_graph(g::jsonb, c::jsonb) from (values
  ('{"nodes":[{"k":"soft","n":"Maya Okafor"},{"k":"soft","n":"Northwind Analytics"}],"edges":[{"s":0,"t":1,"r":"works_at"}]}',
   json_build_object('resource_id', :'m_work', 'agent', 'planner', 'run_id', 'r01', 'valid_from', '2026-01-05T09:00:00Z', 'org_id', :maya_org)::text),
  ('{"nodes":[{"k":"soft","n":"Maya Okafor"},{"k":"soft","n":"vegetarian"}],"edges":[{"s":0,"t":1,"r":"diet"}]}',
   json_build_object('resource_id', :'m_food', 'agent', 'coach', 'run_id', 'r02', 'valid_from', '2026-01-05T09:00:00Z', 'org_id', :maya_org)::text),
  ('{"nodes":[{"k":"soft","n":"Leo Brandt"},{"k":"soft","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}',
   json_build_object('resource_id', :'l_home', 'agent', 'planner', 'run_id', 'r09', 'valid_from', '2026-01-05T09:00:00Z', 'org_id', :leo_org)::text)
) x(g, c) \g /dev/null
reset role;


-- ---------------------------------------------------------------------
-- 2. SEARCH.  m.search("where does Maya live?", filters={"user_id": "maya"})
--
-- No user filter: the caller IS the filter. SEARCH fuses the lexical and the
-- vector rank (RRF), the same two halves Mem0 2.x scores.
-- ---------------------------------------------------------------------
:as_maya
do $$
declare v jsonb := aiq.query('SEARCH "where does Maya live" FROM chunks USING mem0-demo-3d LIMIT 3', '[1,0,0]');
begin
    if v->'rows'->0->>'content' is distinct from 'Maya lives in Leeds.' then
        raise exception 'search: expected Maya''s home first, got %', v->'rows';
    end if;
    if v::text like '%Leo lives%' then
        raise exception 'search returned Leo''s memory to Maya: %', v->'rows';
    end if;
    raise notice 'search   -> %', v->'rows'->0->>'content';
end $$;

-- ---------------------------------------------------------------------
-- 3. GET_ALL and GET.  m.get_all(filters={"user_id": "maya"}); m.get(id)
-- A memory is a row. get_all is a select; row policy does the scoping.
-- ---------------------------------------------------------------------
do $$
declare n int;
begin
    select count(*) into n from content.resources r join content.channels ch on ch.id = r.channel_id
     where ch.name = 'memory';
    if n <> 4 then raise exception 'get_all: Maya should see her 4 memories, saw %', n; end if;
    raise notice 'get_all  -> % memories', n;
end $$;
select r.external_id, c.content from content.resources r
  join content.resource_chunks c on c.resource_id = r.id where r.id = :'m_work';

-- ---------------------------------------------------------------------
-- 4. SCOPES.  filters={"user_id": "maya", "agent_id": "coach"} / run_id
--
-- agent and run are on every memory and on every edge's provenance. GAP:
-- p8ql cannot filter SEARCH by them, so the scoped search is SQL over it.
-- ---------------------------------------------------------------------
do $$
declare v text[];
begin
    select array_agg(c.content order by h.rrf_score desc) into v
      from aiq.search('chunks', 'what does Maya eat', '[0,0,1]', 'mem0-demo-3d', 10) h
      join content.resource_chunks c on c.id = h.chunk_id
      join content.resources r on r.id = c.resource_id
     where r.metadata->>'agent' = 'coach';
    if v is distinct from array['Maya is vegetarian.', 'Maya prefers evening workouts.'] then
        raise exception 'agent scope: expected the coach''s two memories, got %', v;
    end if;
    raise notice 'agent_id=coach -> %', v;
    raise notice 'GAP REM-965: p8ql SEARCH has no filter on a memory''s agent or run; scoped search is SQL';
end $$;

-- ---------------------------------------------------------------------
-- 5. UPDATE.  m.update(memory_id, "Maya lives in Lisbon.")
--
-- Two ways. In place, register_text rewrites the text and keeps the old text,
-- with when it was replaced, in the memory's `replaced` list. The way that keeps the record: add the new memory and
-- close the fact it replaces, so the old one ends instead of vanishing.
-- ---------------------------------------------------------------------
select (content.register_text('memory', 'm-home-2', '[{"content":"Maya lives in Lisbon."}]',
            null, null, :maya_org,
            '{"agent":"planner","run":"r07","quote":"We moved to Lisbon for Harbour Health."}')->>'resource_id') as m_home2 \gset
:as_operator
insert into "aiq"."emb_mem0_demo_3d" (chunk_id, embedding)
select id, '[1,0,0]' from content.resource_chunks where resource_id = :'m_home2';
-- The new memory closes exactly the fact it replaces, at the time it was said,
-- and states when the new one began (REM-963).
set local role worker;
select aiq.close_edge(json_build_object('resource_id', :'m_home', 'relation', 'lives_in')::jsonb,
    '2026-06-01T10:00:00Z', json_build_object('resource_id', :'m_home2', 'agent', 'planner', 'run_id', 'r07')::jsonb);
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Maya Okafor"},{"k":"soft","n":"Lisbon"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}',
    json_build_object('resource_id', :'m_home2', 'agent', 'planner', 'run_id', 'r07', 'valid_from', '2026-06-01T10:00:00Z', 'org_id', :maya_org)::jsonb);
reset role;

-- In place: the text is replaced and the old text is kept, readable to whoever
-- can read the memory (REM-966).
:as_maya
select content.register_text('memory', 'm-work', '[{"content":"Maya works at Harbour Health."}]',
           null, null, :maya_org)->>'resource_id' = :'m_work' as same_memory \gset
\if :same_memory
\else
    \echo 'update in place registered a second memory instead of replacing m-work'
    select 1/0;
\endif
do $$
declare r record;
begin
    select c.content, res.metadata->'replaced' as replaced into r
      from content.resources res
      join content.channels ch on ch.id = res.channel_id and ch.name = 'memory'
      join content.resource_chunks c on c.resource_id = res.id
     where res.external_id = 'm-work';
    if r.content is distinct from 'Maya works at Harbour Health.' then
        raise exception 'update in place: expected the new text, got %', r.content;
    end if;
    if jsonb_array_length(r.replaced) is distinct from 1 or r.replaced->0->>'text' not like '%Northwind%'
       or (r.replaced->0->>'replaced_at')::timestamptz is null then
        raise exception 'update in place: expected the Northwind text kept with its time, got %', r.replaced;
    end if;
    raise notice 'update in place -> same memory; replaced: % at %', r.replaced->0->>'text', r.replaced->0->>'replaced_at';
end $$;
-- Saving the same words again replaces nothing.
select content.register_text('memory', 'm-work', '[{"content":"Maya works at Harbour Health."}]',
           null, null, :maya_org)->>'status' as resave \gset
do $$
begin
    if (select jsonb_array_length(res.metadata->'replaced') from content.resources res
          join content.channels ch on ch.id = res.channel_id and ch.name = 'memory'
         where res.external_id = 'm-work') is distinct from 1 then
        raise exception 'an unchanged save added to the replaced list';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. HISTORY, AND WHY A MEMORY CHANGED.  m.history(memory_id)
--
-- Mem0's history lists ADD/UPDATE events with the time of the write. Here each
-- period of the fact carries when it held, and the memory, quote, agent and
-- run that said so. This is the first thing Mem0 does not do.
-- ---------------------------------------------------------------------
:as_maya
do $$
declare r record; n int := 0;
begin
    for r in
        select d.summary as place, p.valid_from, p.valid_to,
               res.metadata->>'quote' as quote, s->>'agent' as agent, s->>'run_id' as run
          from aiq.edge_periods p
          join aiq.nodes src on src.id = p.src_id and src.summary = 'Maya Okafor'
          join aiq.nodes d on d.id = p.dst_id
          cross join jsonb_array_elements(p.provenance->'sources') s
          join content.resources res on res.id = (s->>'resource_id')::uuid
         where p.relation = 'lives_in'
         order by p.valid_from
    loop
        n := n + 1;
        raise notice 'history  -> % from % to %, said to % in % ("%")',
            r.place, r.valid_from::date, coalesce(r.valid_to::date::text, 'now'), r.agent, r.run, r.quote;
    end loop;
    if n <> 2 then raise exception 'history: expected Leeds then Lisbon, got % periods', n; end if;
end $$;

-- and "where did Maya live in March?" is a predicate, not a second store
do $$
declare v text;
begin
    select d.summary into v from aiq.edges e
      join aiq.nodes s on s.id = e.src_id and s.summary = 'Maya Okafor'
      join aiq.nodes d on d.id = e.dst_id
     where e.relation = 'lives_in' and aiq.edge_is_current(e.valid_from, e.valid_to, '2026-03-01');
    if v is distinct from 'Leeds' then raise exception 'as of March: expected Leeds, got %', v; end if;
    select d.summary into v from aiq.edges e
      join aiq.nodes s on s.id = e.src_id and s.summary = 'Maya Okafor'
      join aiq.nodes d on d.id = e.dst_id
     where e.relation = 'lives_in' and aiq.edge_is_current(e.valid_from, e.valid_to, now());
    if v is distinct from 'Lisbon' then raise exception 'now: expected Lisbon, got %', v; end if;
    raise notice 'as of 2026-03-01 -> Leeds; now -> Lisbon';
end $$;

-- ---------------------------------------------------------------------
-- 7. GRAPH MEMORY.  Mem0 2.x links extracted entity names to memories; the
-- relation between them is not stored. GRAPH walks typed, dated relations.
-- Soft nodes are keyed `soft/<name>`.
-- ---------------------------------------------------------------------
do $$
declare v jsonb := aiq.query('GRAPH "soft/maya okafor" DEPTH 1');
begin
    if jsonb_array_length(coalesce(v->'rows', '[]')) = 0 then
        raise exception 'graph: Maya''s node has no neighbours: %', v;
    end if;
    raise notice 'graph    -> % rows from soft/maya okafor', jsonb_array_length(v->'rows');
end $$;

-- ---------------------------------------------------------------------
-- 8. DELETE.  m.delete(memory_id)
--
-- The owner deletes the row, and what it alone supported goes with it: its
-- chunks (foreign key), their vectors (trg_forget_vectors) and the graph
-- facts no other memory asserts (trg_forget_deleted_sources). A fact another
-- memory also asserts stays, on that memory's word alone (REM-964).
-- ---------------------------------------------------------------------
-- a second memory asserting a fact m-work already asserts
select (content.register_text('memory', 'm-employer', '[{"content":"Maya is at Northwind."}]',
            null, null, :maya_org, '{"agent":"planner","run":"r03"}')->>'resource_id') as m_employer \gset
:as_operator
select set_config('mem0.m_employer', :'m_employer', true) \g /dev/null
set local role worker;
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Maya Okafor"},{"k":"soft","n":"Northwind Analytics"}],"edges":[{"s":0,"t":1,"r":"works_at"}]}',
 json_build_object('resource_id', :'m_employer', 'agent', 'planner', 'run_id', 'r03', 'valid_from', '2026-02-01T09:00:00Z', 'org_id', :maya_org)::jsonb) \g /dev/null
reset role;
:as_maya
do $$
declare n int;
begin
    delete from content.resources where id = current_setting('mem0.m_food')::uuid;
    get diagnostics n = row_count;
    if n <> 1 then raise exception 'delete as the owner removed % rows of m-food', n; end if;
    delete from content.resources where id = current_setting('mem0.m_employer')::uuid;
    raise notice 'delete as the owner -> m-food and m-employer';
end $$;
:as_leo
do $$
declare n int;
begin
    -- a non-owner deletes nothing, even a row they could otherwise see
    delete from content.resources where external_id = 'm-home';
    get diagnostics n = row_count;
    if n <> 0 then raise exception 'Leo deleted % of Maya''s memories', n; end if;
end $$;
:as_operator
do $$
declare v_food uuid := current_setting('mem0.m_food')::uuid; n int;
begin
    select count(*) into n from content.resources where id = v_food;
    if n <> 0 then raise exception 'delete: m-food is still there'; end if;
    select count(*) into n from content.resource_chunks where resource_id = v_food;
    if n <> 0 then raise exception 'delete: % chunks of m-food remain', n; end if;
    -- its one vector was [0,0,1]; m-gym's is the only other on the food axis
    select count(*) into n from aiq.emb_mem0_demo_3d where embedding = '[0,0,1]';
    if n <> 0 then raise exception 'delete: m-food''s vector remains'; end if;
    select count(*) into n from aiq.edges where relation = 'diet';
    if n <> 0 then raise exception 'delete: the diet fact only m-food asserted remains (% rows)', n; end if;
    select count(*) into n from aiq.edges
     where relation = 'works_at' and valid_to is null
       and jsonb_array_length(provenance->'sources') = 1
       and provenance->'sources'->0->>'run_id' = 'r01';
    if n <> 1 then
        raise exception 'delete: the works_at fact m-work also asserts should stand on m-work alone, got % rows', n;
    end if;
    select count(*) into n from content.resources where external_id = 'm-home';
    if n <> 1 then raise exception 'delete: Leo''s delete removed m-home'; end if;
    raise notice 'delete    -> m-food: 0 rows, 0 chunks, 0 vectors, 0 diet edges; works_at stands on m-work';
end $$;
:as_maya
do $$
declare n int;
begin
    select count(*) into n from content.resources where external_id = 'm-food';
    if n <> 0 then raise exception 'Maya still reads m-food'; end if;
    select count(*) into n from aiq.edges where relation = 'diet';
    if n <> 0 then raise exception 'Maya still reads the diet fact'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 9. A READER WITHOUT PERMISSION GETS NOTHING BACK. The second thing Mem0
-- does not do: its user_id is an argument, so any caller holding the client
-- can pass Maya's. Here Leo asks Maya's questions, as himself.
-- ---------------------------------------------------------------------
:as_leo
do $$
declare v jsonb; n int;
begin
    v := aiq.query('SEARCH "where does Maya live" FROM chunks USING mem0-demo-3d LIMIT 10', '[1,0,0]');
    if (v->'rows')::text like '%Maya%' then raise exception 'Leo''s search returned Maya''s memory: %', v->'rows'; end if;
    select count(*) into n from content.resources where owner_id = '00000000-0000-0000-0000-0000000959a1';
    if n <> 0 then raise exception 'Leo can read % of Maya''s memories', n; end if;
    v := aiq.query('GRAPH "soft/maya okafor" DEPTH 1');
    if jsonb_array_length(coalesce(v->'rows', '[]')) <> 0 then
        raise exception 'Leo can walk Maya''s graph: %', v->'rows';
    end if;
    select count(*) into n from aiq.edges e join aiq.nodes s on s.id = e.src_id where s.summary = 'Maya Okafor';
    if n <> 0 then raise exception 'Leo can read % of Maya''s facts', n; end if;
    raise notice 'Leo reads Maya''s memories: 0 search hits, 0 rows, 0 graph rows, 0 facts';
end $$;
:as_operator

-- ---------------------------------------------------------------------
-- 10. A MEMORY WITH NO ORG. Everything above is written in the person's own
-- org. Registered with none, the memory is private to its owner, and so are
-- the facts extracted from it: before REM-962 they were written as shared
-- reference data, and Leo read this one from aiq.edges.
-- ---------------------------------------------------------------------
:as_maya
select (content.register_text('memory', 'm-allergy', '[{"content":"Maya is allergic to peanuts."}]')->>'resource_id') as m_allergy \gset
:as_operator
set local role worker;
select aiq.upsert_graph('{"nodes":[{"k":"soft","n":"Maya O."},{"k":"soft","n":"peanuts"}],"edges":[{"s":0,"t":1,"r":"allergic_to"}]}',
    json_build_object('resource_id', :'m_allergy', 'agent', 'coach', 'run_id', 'r03')::jsonb) \g /dev/null
reset role;
:as_leo
do $$
declare n_mem int; n_fact int;
begin
    select count(*) into n_mem from content.resources where external_id = 'm-allergy';
    select count(*) into n_fact from aiq.edges where relation = 'allergic_to';
    raise notice 'no-org memory: Leo reads % of the memory and % of the fact it produced', n_mem, n_fact;
    if n_mem <> 0 or n_fact <> 0 then
        raise exception 'Leo reads % of Maya''s no-org memory and % of the fact it produced '
            '(REM-962: a fact is no more visible than the memory it came from)', n_mem, n_fact;
    end if;
end $$;
:as_operator

rollback;
