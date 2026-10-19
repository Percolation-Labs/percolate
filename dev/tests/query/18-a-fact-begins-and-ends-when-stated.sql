-- A WRITER STATES WHEN A FACT BEGAN, AND CLOSES THE ONE IT REPLACES (REM-963).
--
-- aiq.upsert_graph stamped valid_from = now(), so a memory loaded today about
-- something said in January held from today; and the only retraction,
-- aiq.retract_derived, closed everything one agent derived. The Mem0
-- quickstart (content/12) set both columns with operator UPDATEs. Now the
-- context carries valid_from, and aiq.close_edge ends exactly one edge at a
-- stated time. content/12 exercises naming an edge by the memory that asserted
-- it; this file names it by id and checks every refusal.
--
-- WHAT WOULD MAKE IT FAIL. Ignore the context's valid_from and §1 raises.
-- Let close_edge touch more than one edge and §3 raises.

\set ON_ERROR_STOP on

begin;
set local role app_owner;
select aiq.register_graph_vocabulary('[{"relation":"t963_lives_in"}]') \g /dev/null

create function pg_temp.edge(p_dst text) returns aiq.edges language sql as $$
    select e.* from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id
     where e.relation = 't963_lives_in' and k.key = 'place/' || p_dst and k.kind = 'canonical'
$$;

set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"person","n":"Ada T963"},{"k":"place","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"t963_lives_in"}]}',
    '{"agent":"t963","run_id":"r1","valid_from":"2026-01-05T09:00:00Z"}') \g /dev/null
reset role;
set local role app_owner;

-- 1. The edge holds from the stated time, and its source says so.
do $$
declare e aiq.edges := pg_temp.edge('leeds');
begin
    if e.valid_from is distinct from '2026-01-05T09:00:00Z'::timestamptz then
        raise exception 'the edge holds from %, not the stated 2026-01-05', e.valid_from;
    end if;
    if e.provenance->'sources'->0->>'valid_from' is null then
        raise exception 'the source entry does not record the stated valid_from: %', e.provenance;
    end if;
end $$;

-- 2. A later source cannot move the start forward; an earlier one moves it back.
set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"person","n":"Ada T963"},{"k":"place","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"t963_lives_in"}]}',
    '{"agent":"t963","run_id":"r2","valid_from":"2026-03-01T00:00:00Z"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"person","n":"Ada T963"},{"k":"place","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"t963_lives_in"}]}',
    '{"agent":"t963b","run_id":"r3","valid_from":"2025-12-01T00:00:00Z"}') \g /dev/null
reset role;
set local role app_owner;
do $$
begin
    if (pg_temp.edge('leeds')).valid_from is distinct from '2025-12-01T00:00:00Z'::timestamptz then
        raise exception 'the edge should hold from the earliest stated time, 2025-12-01, not %',
            (pg_temp.edge('leeds')).valid_from;
    end if;
end $$;

-- 3. close_edge ends exactly that edge at the stated time, and says who ended it.
set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"person","n":"Ada T963"},{"k":"place","n":"York"}],"edges":[{"s":0,"t":1,"r":"t963_lives_in"}]}',
    '{"agent":"t963","run_id":"r4","valid_from":"2026-01-05T09:00:00Z"}') \g /dev/null
reset role;
set local role app_owner;
select (pg_temp.edge('leeds')).id as leeds_edge \gset
set local role worker;
select aiq.close_edge(json_build_object('edge_id', :'leeds_edge')::jsonb, '2026-06-01T10:00:00Z',
                      '{"agent":"t963","run_id":"r7"}') \g /dev/null
reset role;
set local role app_owner;
do $$
declare l aiq.edges := pg_temp.edge('leeds'); y aiq.edges := pg_temp.edge('york');
begin
    if l.valid_to is distinct from '2026-06-01T10:00:00Z'::timestamptz then
        raise exception 'the closed edge ends at %, not the stated 2026-06-01', l.valid_to;
    end if;
    if l.provenance->'closed'->>'run_id' is distinct from 'r7' then
        raise exception 'the closed edge does not say who closed it: %', l.provenance->'closed';
    end if;
    if y.valid_to is not null then
        raise exception 'closing one edge closed another (York ends %)', y.valid_to;
    end if;
    if not aiq.edge_is_current(l.valid_from, l.valid_to, '2026-03-01')
       or aiq.edge_is_current(l.valid_from, l.valid_to, '2026-07-01') then
        raise exception 'as-of reads disagree with the stated period: % to %', l.valid_from, l.valid_to;
    end if;
    raise notice 'Leeds held % to %, closed by run %', l.valid_from::date, l.valid_to::date,
        l.provenance->'closed'->>'run_id';
end $$;

-- 4. Refusals: a close that names no current edge, one that would end a fact
--    before it began, and times in the future.
set local role worker;
do $$
declare v_york uuid;
begin
    begin
        perform aiq.close_edge('{"resource_id":"00000000-0000-0000-0000-000000000963","relation":"t963_lives_in"}',
                               '2026-06-01', '{}');
        raise exception 'a close naming no edge was accepted';
    exception when raise_exception then
        if sqlerrm not like '%names 0 current edges%' then raise; end if;
    end;
    begin
        perform aiq.close_edge('{"edge_id":"00000000-0000-0000-0000-000000000963"}', now() + interval '1 day', '{}');
        raise exception 'a close in the future was accepted';
    exception when raise_exception then
        if sqlerrm not like '%in the future%' then raise; end if;
    end;
    begin
        perform aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ada T963"},{"k":"place","n":"Hull"}],"edges":[{"s":0,"t":1,"r":"t963_lives_in"}]}',
                                 jsonb_build_object('agent','t963','valid_from', now() + interval '1 day'));
        raise exception 'a valid_from in the future was accepted';
    exception when raise_exception then
        if sqlerrm not like '%in the future%' then raise; end if;
    end;
end $$;
reset role;
set local role app_owner;
select (pg_temp.edge('york')).id as york_edge \gset
select set_config('t963.york', :'york_edge', true) \g /dev/null
set local role worker;
do $$
begin
    perform aiq.close_edge(jsonb_build_object('edge_id', current_setting('t963.york')), '2025-01-01', '{}');
    raise exception 'an edge was closed before it began';
exception when raise_exception then
    if sqlerrm not like '%cannot end then%' then raise; end if;
end $$ ;
reset role;

rollback;
