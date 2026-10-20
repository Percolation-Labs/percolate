-- EACH READER OF ONE DOCUMENT IS ITS OWN SOURCE (REM-1058).
--
-- An edge's sources were deduplicated by the document alone. When two readers
-- read Ana's March email as "works_at Tagus Ceramics", the second reading
-- matched the first's entry and was dropped. So retract_derived of the first
-- reader ended a fact the second still supported, or, with no agent on the
-- kept entry, found nothing to withdraw at all. A source is now the reading:
-- the document, the agent and the run.
--
--   1. two agents reading one resource leave two sources, each with its agent;
--   2. the same agent re-running the same run appends nothing;
--   3. retracting one reader withdraws its source and the edge stays current
--      on the other's word; retracting the last one ends it.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;
set local role app_owner;
insert into content.channels (name, kind, org_id, visibility)
    values ('rem1058', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility)
select '00000000-0000-4000-8000-000000105801', c.id, 'ana-march', 'memo://rem1058/ana-march', 'Ana''s March email',
       'ready', rbac.shared_org_id(), 'public'
  from content.channels c where c.name = 'rem1058';
select aiq.register_graph_vocabulary('[{"relation":"rem1058_works_at"}]') \g /dev/null
reset role;

set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Ana rem1058"},{"k":"soft","n":"Tagus Ceramics rem1058"}],
      "edges":[{"s":0,"t":1,"r":"rem1058_works_at"}]}',
    '{"resource_id":"00000000-0000-4000-8000-000000105801","agent":"reader-v0","run_id":"r1"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Ana rem1058"},{"k":"soft","n":"Tagus Ceramics rem1058"}],
      "edges":[{"s":0,"t":1,"r":"rem1058_works_at"}]}',
    '{"resource_id":"00000000-0000-4000-8000-000000105801","agent":"worker","run_id":"r2"}') \g /dev/null
-- The first reader again, same run: a replay, not a new reading.
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Ana rem1058"},{"k":"soft","n":"Tagus Ceramics rem1058"}],
      "edges":[{"s":0,"t":1,"r":"rem1058_works_at"}]}',
    '{"resource_id":"00000000-0000-4000-8000-000000105801","agent":"reader-v0","run_id":"r1"}') \g /dev/null
reset role;

do $$
declare agents text[];
begin
    select array_agg(s->>'agent' order by s->>'agent') into agents
      from aiq.edges e cross join jsonb_array_elements(e.provenance->'sources') s
     where e.relation = 'rem1058_works_at';
    if agents is distinct from array['reader-v0', 'worker'] then
        raise exception 'two readers of one resource should be two sources, each with its agent, got %', agents;
    end if;
end $$;

-- As the owner, the way the derivations that call it run (query/15, query/16).
do $$
declare r jsonb := aiq.retract_derived('reader-v0');
begin
    if (r->>'withdrawn')::int is distinct from 1 or (r->>'retracted')::int is distinct from 0 then
        raise exception 'retracting one reader should withdraw its source and retract nothing, got %', r;
    end if;
end $$;
do $$
declare left_ text[];
begin
    select array_agg(s->>'agent') into left_
      from aiq.edges e cross join jsonb_array_elements(e.provenance->'sources') s
     where e.relation = 'rem1058_works_at' and aiq.edge_is_current(e.valid_from, e.valid_to, now());
    if left_ is distinct from array['worker'] then
        raise exception 'the fact should stand, current, on the other reader''s word alone, got %', left_;
    end if;
end $$;

-- As the owner, the way the derivations that call it run (query/15, query/16).
do $$
declare r jsonb := aiq.retract_derived('worker');
begin
    if (r->>'retracted')::int is distinct from 1 then
        raise exception 'retracting the last reader should end the fact, got %', r;
    end if;
end $$;

rollback;
