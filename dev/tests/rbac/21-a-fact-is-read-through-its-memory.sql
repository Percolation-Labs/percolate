-- A FACT IS NO MORE VISIBLE THAN THE MEMORY IT CAME FROM (REM-962).
--
-- aiq.upsert_graph runs for a worker extracting on somebody's behalf, and it
-- took the fact's scope from the CONTEXT the worker passed, never from the
-- resource the fact was read out of. A context with no org_id is the shared
-- tier, and the shared tier projected `public`: so Maya's private memory "Maya
-- is allergic to peanuts", registered with no org, became a public edge Leo
-- could read from aiq.edges -- while the memory itself stayed private and Leo
-- read none of it. Inside an org the same shape gave every member a fact from
-- one member's private resource. And the document node projected from the
-- resource had the same default, so the memory's title was public too.
--
--   1. no org: Leo reads no node, edge or document from Maya's private memory,
--      directly, through GRAPH and through the walk; Maya reads all three;
--   2. one org: an org member reads nothing from another member's PRIVATE
--      resource in that org;
--   3. a fact is read through ANY source the caller may read: the same edge
--      asserted from Leo's own memory is Leo's to read;
--   4. reference data is unchanged: an extraction with no resource stays
--      public, nodes and edge;
--   5. a context naming a different org from its resource is refused;
--   7. two owners naming the same things: Leo reads all 8 of his facts and none
--      of Maya's, though Maya named five of his entities first, because a thing
--      named in a private memory is its owner's node;
--   8. no source, signed in: the candidates are the writer's, and claims with no
--      user id are refused (REM-1012);
--   6. the control: with the edge's source gate removed, Leo reads Maya's fact,
--      so §1 can fail. (Last, because it rewrites the policy.)
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-0000000962a1'''
\set leo  '''00000000-0000-4000-8000-0000000962b2'''
\set org  '''00000000-0000-4000-8000-0000000962c0'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000962a1"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000962b2"}''; set local role authenticated;'

begin;
set local role app_owner;

insert into rbac.users (id, email, status) values
    (:maya, 'rem962-maya@example.test', 'active'),
    (:leo,  'rem962-leo@example.test',  'active');
insert into rbac.orgs (id, slug, name) values (:org, 'rem962-org', 'REM-962 org');
insert into rbac.org_members (org_id, user_id) values (:org, :maya), (:org, :leo);
insert into content.channels (name, kind, org_id, visibility)
    values ('rem962', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;
-- Two public places as a typed table, so a private memory that names them
-- lands on PUBLIC nodes: the case where the edge's own sources are the only
-- gate (§1's rem962_visited, §3).
create table public.rem962_place (id uuid primary key default gen_random_uuid(),
                                  name text not null, org_id uuid);
select aiq.register_entity_table('rem962_place', 'public.rem962_place', 'n.name', 'n.name', 'n.org_id') \g /dev/null
insert into public.rem962_place (name) values ('Harbour Town rem962'), ('Northland rem962');
select aiq.register_graph_vocabulary('[{"relation":"rem962_allergic_to"},{"relation":"rem962_lives_in"},
    {"relation":"rem962_works_at"},{"relation":"rem962_capital_of"},{"relation":"rem962_visited"},
    {"relation":"rem962_fact"}]') \g /dev/null

-- The memories, written directly as their owners' rows: what register_text
-- writes for a caller with no org (private, owned) and with one (scoped to it).
insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, owner_id)
select v.id::uuid, c.id, v.ext, 'memo://rem962/' || v.ext, v.title, 'ready', v.org::uuid, v.vis, v.owner::uuid
  from content.channels c,
       (values ('00000000-0000-4000-8000-0000000962d1', 'maya-allergy', 'Maya''s allergy',
                rbac.shared_org_id()::text, 'private', :maya),
               ('00000000-0000-4000-8000-0000000962d2', 'maya-home', 'Maya''s home',
                rbac.shared_org_id()::text, 'private', :maya),
               ('00000000-0000-4000-8000-0000000962d3', 'leo-home', 'Leo''s home',
                rbac.shared_org_id()::text, 'private', :leo),
               ('00000000-0000-4000-8000-0000000962d4', 'maya-work', 'Maya''s employer',
                :org, 'private', :maya)) v(id, ext, title, org, vis, owner)
 where c.name = 'rem962';
reset role;

-- The worker's writes, each naming the memory it read. The first passes no
-- org at all, which is what jack's Mem0 quickstart does (REM-959 §10).
set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Maya O. rem962"},{"k":"soft","n":"peanuts rem962"}],
      "edges":[{"s":0,"t":1,"r":"rem962_allergic_to"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000962d1","agent":"coach"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"rem962_place","n":"Harbour Town rem962"},{"k":"rem962_place","n":"Northland rem962"}],
      "edges":[{"s":0,"t":1,"r":"rem962_lives_in"},{"s":0,"t":1,"r":"rem962_visited"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000962d2","agent":"planner"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Maya O. rem962"},{"k":"soft","n":"Northwind rem962"}],
      "edges":[{"s":0,"t":1,"r":"rem962_works_at"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000962d4","agent":"planner",
      "org_id":"00000000-0000-4000-8000-0000000962c0"}') \g /dev/null
reset role;

-- §3's second source and §4's reference data: an operator extraction with no
-- resource, which is deployment configuration and public by construction.
-- Run as app_owner, the way an install or a migration lands reference data.
set local role app_owner;
select aiq.upsert_graph(
    '{"nodes":[{"k":"rem962_place","n":"Harbour Town rem962"},{"k":"rem962_place","n":"Northland rem962"}],
      "edges":[{"s":0,"t":1,"r":"rem962_capital_of"}]}',
    '{"agent":"gazetteer"}') \g /dev/null
reset role;

-- Maya's candidate's node id, read as the owner, so the walk below starts
-- where it would if Leo had learnt the id some other way.
create temp table rem962_seed as
    select nd.id from aiq.nodes nd join aiq.soft_nodes sn on sn.id = nd.entity_id
     where nd.entity_type = 'soft' and sn.key = 'maya o. rem962'
       and sn.org_id = rbac.shared_org_id();
grant select on rem962_seed to authenticated;

create function pg_temp.rem962_facts(p_rel text) returns int as $$
    select count(*)::int from aiq.edges where relation = p_rel
$$ language sql;
create function pg_temp.rem962_nodes(p_label text) returns int as $$
    select count(*)::int from aiq.nodes where summary = p_label
$$ language sql;
grant execute on function pg_temp.rem962_facts(text), pg_temp.rem962_nodes(text) to authenticated;

-- 1. No org. Maya reads her own fact, its nodes and the document; Leo none.
:as_maya
do $$
begin
    if pg_temp.rem962_facts('rem962_allergic_to') <> 1 then
        raise exception 'Maya cannot read the fact extracted from her own memory -- the gate refuses its owner';
    end if;
    if pg_temp.rem962_nodes('peanuts rem962') <> 1 then
        raise exception 'Maya cannot read the node extracted from her own memory';
    end if;
    if pg_temp.rem962_nodes('Maya''s allergy') <> 1 then
        raise exception 'Maya cannot read the document node of her own memory';
    end if;
end $$;
:as_leo
do $$
declare v jsonb;
begin
    if pg_temp.rem962_facts('rem962_allergic_to') <> 0 then
        raise exception 'Leo read the fact extracted from Maya''s private memory from aiq.edges (REM-962)';
    end if;
    if pg_temp.rem962_nodes('peanuts rem962') <> 0 or pg_temp.rem962_nodes('Maya O. rem962') <> 0 then
        raise exception 'Leo read a node extracted from Maya''s private memory from aiq.nodes (REM-962)';
    end if;
    if exists (select 1 from aiq.soft_nodes where key in ('peanuts rem962', 'maya o. rem962')) then
        raise exception 'Leo read a candidate extracted from Maya''s private memory from aiq.soft_nodes (REM-962)';
    end if;
    -- Both places are public typed nodes, so only the edge's own sources
    -- stand between Leo and Maya's fact about them.
    if pg_temp.rem962_facts('rem962_visited') <> 0 then
        raise exception 'Leo read Maya''s private fact between two public names: the edge is gated by its endpoints only (REM-962)';
    end if;
    if pg_temp.rem962_nodes('Maya''s allergy') <> 0 then
        raise exception 'Leo read the document node of Maya''s private memory: its title is public (REM-962)';
    end if;
    v := aiq.query('GRAPH "soft/maya o. rem962" DEPTH 2');
    if v::text like '%peanuts rem962%' then
        raise exception 'GRAPH walked Leo into Maya''s private fact: %', v;
    end if;
    if exists (select 1 from aiq.graph_walk((select id from rem962_seed), 2) w
                where w.summary = 'peanuts rem962') then
        raise exception 'graph_walk from Maya''s candidate reached her private fact as Leo';
    end if;
end $$;

-- 2. One org: Leo is a member of it, the resource is Maya's private one.
do $$
begin
    if pg_temp.rem962_facts('rem962_works_at') <> 0 then
        raise exception 'an org member read the fact from another member''s PRIVATE resource in the org (REM-962)';
    end if;
    if pg_temp.rem962_nodes('Northwind rem962') <> 0 then
        raise exception 'an org member read a node from another member''s PRIVATE resource in the org (REM-962)';
    end if;
end $$;
:as_maya
do $$
begin
    if pg_temp.rem962_facts('rem962_works_at') <> 1 then
        raise exception 'Maya cannot read the fact from her own private resource in her org';
    end if;
end $$;
reset role;

-- 3. The same edge from Leo's own memory: one row, two sources, and Leo reads
-- it through his. Its endpoints are the public places, so the edge's sources
-- are the only gate, and this is where reading through ANY of them is tested
-- rather than through the first.
set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"rem962_place","n":"Harbour Town rem962"},{"k":"rem962_place","n":"Northland rem962"}],
      "edges":[{"s":0,"t":1,"r":"rem962_lives_in"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000962d3","agent":"planner"}') \g /dev/null
reset role;
:as_leo
do $$
begin
    if pg_temp.rem962_facts('rem962_lives_in') <> 1 then
        raise exception 'Leo cannot read a fact his own memory asserted, because Maya''s memory asserted it first';
    end if;
end $$;

-- 4. Reference data: public nodes, public edge, readable by anyone.
do $$
begin
    if pg_temp.rem962_facts('rem962_capital_of') <> 1 then
        raise exception 'reference data with no source resource is no longer public';
    end if;
end $$;
reset role;

-- 5. A context that names another org than its resource.
set local role worker;
do $$
begin
    perform aiq.upsert_graph(
        '{"nodes":[{"k":"soft","n":"x rem962"},{"k":"soft","n":"y rem962"}],
          "edges":[{"s":0,"t":1,"r":"rem962_lives_in"}]}',
        '{"resource_id":"00000000-0000-4000-8000-0000000962d4",
          "org_id":"00000000-0000-4000-8000-000000000000"}');
    raise exception 'upsert_graph accepted a context org that is not its resource''s org';
exception when others then
    if sqlerrm not like '%is not the org of resource%' then raise; end if;
end $$;
do $$
begin
    perform aiq.upsert_graph('{"nodes":[{"k":"soft","n":"z rem962"}],"edges":[]}',
        '{"resource_id":"00000000-0000-4000-8000-0000000962ff"}');
    raise exception 'upsert_graph accepted a resource_id naming no resource';
exception when others then
    if sqlerrm not like '%names no resource%' then raise; end if;
end $$;
reset role;

-- 7. Two owners, eight memories each, five entities in common, Maya first:
-- the shape of jack's 48-fact fixture, where one shared node per name left Leo
-- 3 of his 8. Each memory is private and has no org.
set local role app_owner;
insert into content.resources (id, channel_id, external_id, uri, status, org_id, visibility, owner_id)
select ('00000000-0000-4000-8962-' || lpad(o.n || i::text, 12, '0'))::uuid, c.id,
       'rem962-' || o.who || '-' || i, 'memo://rem962/' || o.who || '/' || i, 'ready',
       rbac.shared_org_id(), 'private', o.owner::uuid
  from content.channels c, generate_series(1, 8) i,
       (values ('1', 'maya', :maya), ('2', 'leo', :leo)) o(n, who, owner)
 where c.name = 'rem962';
reset role;
set local role worker;
do $$
declare
    shared text[] := array['Leeds', 'Northwind Analytics', 'Priya Shah',
                           'morning workouts', 'the half-marathon goal'];
    who text; n text; i int; thing text;
begin
    foreach who in array array['maya', 'leo'] loop
        n := case who when 'maya' then '1' else '2' end;
        for i in 1 .. 8 loop
            thing := case when i <= 5 then shared[i] else who || ' own thing ' || i end;
            perform aiq.upsert_graph(
                jsonb_build_object(
                    'nodes', jsonb_build_array(
                        jsonb_build_object('k', 'soft', 'n', who || ' rem962'),
                        jsonb_build_object('k', 'soft', 'n', thing)),
                    'edges', jsonb_build_array(jsonb_build_object('s', 0, 't', 1, 'r', 'rem962_fact'))),
                jsonb_build_object('resource_id', '00000000-0000-4000-8962-' || lpad(n || i::text, 12, '0'),
                                   'agent', 'planner'));
        end loop;
    end loop;
end $$;
reset role;

create function pg_temp.rem962_own_facts(p_owner uuid) returns table (own int, others int) as $$
    select count(*) filter (where mine)::int, count(*) filter (where not mine)::int
      from (select exists (select 1 from jsonb_array_elements(e.provenance->'sources') src
                             join content.resources r on r.id = (src->>'resource_id')::uuid
                            where r.owner_id = p_owner) as mine
              from aiq.edges e where e.relation = 'rem962_fact') x
$$ language sql;
grant execute on function pg_temp.rem962_own_facts(uuid) to authenticated;

:as_leo
do $$
declare v record;
begin
    select * into v from pg_temp.rem962_own_facts('00000000-0000-4000-8000-0000000962b2');
    if v.own <> 8 or v.others <> 0 then
        raise exception 'Leo reads % of his 8 facts and % of Maya''s -- a thing Maya named first '
                        'took his facts about it with it (REM-962)', v.own, v.others;
    end if;
    if (select count(*) from aiq.soft_nodes where key = 'leeds') <> 1 then
        raise exception 'Leo does not read exactly his own Leeds candidate';
    end if;
end $$;
:as_maya
do $$
declare v record;
begin
    select * into v from pg_temp.rem962_own_facts('00000000-0000-4000-8000-0000000962a1');
    if v.own <> 8 or v.others <> 0 then
        raise exception 'Maya reads % of her 8 facts and % of Leo''s', v.own, v.others;
    end if;
end $$;
reset role;
do $$
begin
    if (select count(*) from aiq.soft_nodes where key = 'leeds' and org_id = rbac.shared_org_id()) <> 2 then
        raise exception 'two owners naming Leeds in private memory should hold two candidates';
    end if;
end $$;

-- 8. No source, signed in (REM-1012): a run carrying Maya's identity lands a
-- graph naming no resource or session. Its candidates are private and hers, so
-- she reads the fact back and Leo does not. On 0.2.23 they were private with
-- no owner, and she read 0. Claims with no user id are refused.
set local role worker;
set local request.jwt.claims = '{"sub":"00000000-0000-4000-8000-0000000962a1"}';
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Maya O. rem1012"},{"k":"soft","n":"cycling rem1012"}],
      "edges":[{"s":0,"t":1,"r":"rem962_fact"}]}',
    '{"agent":"knit"}') \g /dev/null
set local request.jwt.claims = '{"role":"authenticated"}';
do $$
begin
    perform aiq.upsert_graph('{"nodes":[{"k":"soft","n":"nobody rem1012"}],"edges":[]}', '{"agent":"knit"}');
    raise exception 'upsert_graph wrote a private candidate for claims that name no user';
exception when others then
    if sqlerrm not like '%this caller names no user%' then raise; end if;
end $$;
set local request.jwt.claims = '';
reset role;
do $$
begin
    if exists (select 1 from aiq.soft_nodes where key like '%rem1012'
                and (visibility <> 'private' or owner_id is distinct from
                     '00000000-0000-4000-8000-0000000962a1')) then
        raise exception 'a sourceless candidate written as Maya is not private to her (REM-1012)';
    end if;
end $$;
:as_maya
do $$
begin
    if (select count(*) from aiq.edges e join aiq.nodes s on s.id = e.src_id
          join aiq.soft_nodes n on n.id = s.entity_id and s.entity_type = 'soft'
         where e.relation = 'rem962_fact' and n.key like '%rem1012') <> 1 then
        raise exception 'Maya cannot read the fact she wrote with no source (REM-1012)';
    end if;
end $$;
:as_leo
do $$
begin
    if exists (select 1 from aiq.soft_nodes where key like '%rem1012') then
        raise exception 'Leo reads Maya''s sourceless private candidates';
    end if;
end $$;
reset role;

-- 6. The control: the policy as it was before this fix, endpoints only. Leo
-- then reads Maya's private fact between public names, so §1 can fail.
set local role app_owner;
alter policy edges_via_endpoints on aiq.edges
  using (exists (select 1 from aiq.nodes s where s.id = aiq.edges.src_id)
     and exists (select 1 from aiq.nodes d where d.id = aiq.edges.dst_id));
reset role;
:as_leo
do $$
begin
    if pg_temp.rem962_facts('rem962_visited') <> 1 then
        raise exception 'control: with the source gate off Leo still reads 0 facts, so §1 proves nothing';
    end if;
end $$;
reset role;

rollback;

\echo rbac/21: a fact is read through its memory -- no org, one org, any readable source, reference data, refused context, sourceless writer, control
