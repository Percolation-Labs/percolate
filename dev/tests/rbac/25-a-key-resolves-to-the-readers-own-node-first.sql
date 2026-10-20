-- A KEY RESOLVES TO THE READER'S OWN NODE FIRST (REM-976).
--
-- With per-owner private nodes (REM-962) one key can name a node in each scope:
-- Maya's private "Leeds rem976" and the public one. Two gaps followed.
--
--   1. LOOKUP returned both to Maya, who reads both, and GRAPH refused the key
--      as naming 2 nodes. Now each reader gets the nearest scope (their own,
--      then the org's, then public), and the GRAPH receipt names which;
--   2. aiq.resolve_ref matched across every scope on the tier, so Leo's
--      private mention of "Leeds rem976" found Maya's node beside the public one,
--      called it ambiguous, and missed. A private mention now binds only to a
--      node its owner can read, its owner's own first. An org mention never
--      binds to a private node;
--   3. two kinds under one key are still two rows, so GRAPH still refuses them.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-4000-8000-0000000976a1'''
\set leo  '''00000000-0000-4000-8000-0000000976b2'''
\set org  '''00000000-0000-4000-8000-0000000976c0'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000976a1"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-4000-8000-0000000976b2"}''; set local role authenticated;'

begin;
set local role app_owner;

insert into rbac.users (id, email, status) values
    (:maya, 'rem976-maya@example.test', 'active'),
    (:leo,  'rem976-leo@example.test',  'active');
insert into rbac.orgs (id, slug, name) values (:org, 'rem976-org', 'REM-976 org');
insert into rbac.org_members (org_id, user_id) values (:org, :maya), (:org, :leo);
insert into content.channels (name, kind, org_id, visibility)
    values ('rem976', 'manual', rbac.shared_org_id(), 'public') on conflict do nothing;

-- A typed kind with a node per scope: the public Leeds, and Maya's own.
create table public.rem976_place (id uuid primary key default gen_random_uuid(), name text not null,
                                  org_id uuid, visibility text not null, owner_id uuid);
select aiq.register_entity_table('rem976_place', 'public.rem976_place', 'n.name', 'n.name', 'n.org_id',
                                 p_visibility_expr => 'n.visibility') \g /dev/null
insert into public.rem976_place (id, name, org_id, visibility, owner_id) values
    ('00000000-0000-4000-8000-0000000976e1', 'Leeds rem976', rbac.shared_org_id(), 'public', null),
    ('00000000-0000-4000-8000-0000000976e2', 'Leeds rem976', rbac.shared_org_id(), 'private', :maya);
select aiq.register_graph_vocabulary('[{"relation":"rem976_lives_in"}]') \g /dev/null

create temp table rem976_ids as
    select (select id from aiq.nodes where entity_id = '00000000-0000-4000-8000-0000000976e1') as pub,
           (select id from aiq.nodes where entity_id = '00000000-0000-4000-8000-0000000976e2') as maya;
grant select on rem976_ids to authenticated, worker;

insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility, owner_id)
select v.id::uuid, c.id, v.ext, 'memo://rem976/' || v.ext, v.title, 'ready', v.org::uuid, v.vis, v.owner::uuid
  from content.channels c,
       (values ('00000000-0000-4000-8000-0000000976d1', 'maya-home', 'Maya''s home',
                rbac.shared_org_id()::text, 'private', :maya),
               ('00000000-0000-4000-8000-0000000976d2', 'leo-home', 'Leo''s home',
                rbac.shared_org_id()::text, 'private', :leo),
               ('00000000-0000-4000-8000-0000000976d3', 'team-home', 'The team''s office',
                :org, 'org', :maya)) v(id, ext, title, org, vis, owner)
 where c.name = 'rem976';
reset role;

-- 1. LOOKUP and GRAPH: each reader's nearest scope, named in the receipt.
:as_maya
do $$
declare
    v   jsonb;
    ids rem976_ids;
begin
    select * into ids from rem976_ids;
    v := aiq.query('LOOKUP "leeds rem976"');
    if jsonb_array_length(v->'rows') is distinct from 1 or (v->'rows'->0->>'node_id')::uuid is distinct from ids.maya then
        raise exception 'Maya''s LOOKUP should be her own node alone, got %', v->'rows';
    end if;
    v := aiq.query('GRAPH "leeds rem976"');
    if v ? 'error' then
        raise exception 'GRAPH refused a key Maya holds her own node for: %', v->>'error';
    end if;
    if (v->'seed'->>'node_id')::uuid is distinct from ids.maya or v->'seed'->>'scope' is distinct from 'private' then
        raise exception 'GRAPH should walk Maya''s own node and say it is private, got %', v->'seed';
    end if;
end $$;
:as_leo
do $$
declare v jsonb;
begin
    v := aiq.query('GRAPH "leeds rem976"');
    if (v->'seed'->>'node_id')::uuid is distinct from (select pub from rem976_ids)
       or v->'seed'->>'scope' is distinct from 'public' then
        raise exception 'Leo should walk the public node, got %', v;
    end if;
end $$;

-- 2. Binding: each private mention lands on a node its owner reads, its owner's first.
reset role;
set local role worker;
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Leo rem976"},{"k":"rem976_place","n":"Leeds rem976"}],
      "edges":[{"s":0,"t":1,"r":"rem976_lives_in"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000976d2","agent":"planner"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"Maya rem976"},{"k":"rem976_place","n":"Leeds rem976"}],
      "edges":[{"s":0,"t":1,"r":"rem976_lives_in"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000976d1","agent":"planner"}') \g /dev/null
select aiq.upsert_graph(
    '{"nodes":[{"k":"soft","n":"The team rem976"},{"k":"rem976_place","n":"Leeds rem976"}],
      "edges":[{"s":0,"t":1,"r":"rem976_lives_in"}]}',
    '{"resource_id":"00000000-0000-4000-8000-0000000976d3","agent":"planner"}') \g /dev/null
reset role;
do $$
declare
    ids rem976_ids;
    r   record;
begin
    select * into ids from rem976_ids;
    for r in select s.summary as who, e.dst_id
               from aiq.edges e join aiq.nodes s on s.id = e.src_id
              where e.relation = 'rem976_lives_in' loop
        if r.who = 'Leo rem976' and r.dst_id is distinct from ids.pub then
            raise exception 'Leo''s private mention should bind the public Leeds, not %', r.dst_id;
        elsif r.who = 'Maya rem976' and r.dst_id is distinct from ids.maya then
            raise exception 'Maya''s private mention should bind her own Leeds, not %', r.dst_id;
        elsif r.who = 'The team rem976' and r.dst_id is distinct from ids.pub then
            raise exception 'an org mention should bind the public Leeds, never a private node, not %', r.dst_id;
        end if;
    end loop;
    if (select count(*) from aiq.edges where relation = 'rem976_lives_in') is distinct from 3::bigint then
        raise exception 'expected three lives_in facts';
    end if;
    -- And none of them made a soft candidate for the place: each resolved.
    if exists (select 1 from aiq.soft_nodes where key = 'leeds rem976') then
        raise exception 'a mention of Leeds missed the typed node and minted a candidate';
    end if;
end $$;

-- 3. Two kinds under one key are still two rows: the ambiguity GRAPH must refuse.
set local role app_owner;
create table public.rem976_event (id uuid primary key default gen_random_uuid(), name text not null, org_id uuid);
select aiq.register_entity_table('rem976_event', 'public.rem976_event', 'n.name', 'n.name', 'n.org_id') \g /dev/null
insert into public.rem976_event (name, org_id) values ('Leeds rem976', rbac.shared_org_id());
reset role;
:as_leo
do $$
declare v jsonb := aiq.query('GRAPH "leeds rem976"');
begin
    if coalesce(v->>'error', '') not like '%names 2 nodes%' then
        raise exception 'a place and an event under one key should still be refused, got %', v;
    end if;
end $$;

rollback;
