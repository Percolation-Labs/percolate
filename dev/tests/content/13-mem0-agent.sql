-- PART TWO OF THE SERIES, FOR MEM0 USERS: THE READER'S OWN AGENT, WITH NO SECOND MODEL (REM-959, REM-1055).
--
-- The blocks of "Percolate for Mem0 folks" that need no model, in the article's order, each followed by the
-- assertion that keeps the article true:
--   §1 Maya's history, dated, the June memory closing January's home, and what held in March;
--   §2 her bookings beside her memory, as her and as Leo;
--   §3 what her conversation said, landed as her agent landed it: agent:<Maya>, citing what she wrote;
--   §4 a second reader types Harbour Health an organization; dream queues the pair, her agent binds it, and the
--      twin settles: one works_at fact with two sources;
--   §5 Leo reads none of it.
-- The blocks that call a model (the planners' turns, the note's and the search's embeddings) or the reader's own
-- agent (reading and judging over MCP) run against a live stack in dev/examples/mem0-memory/run.sh. Here the
-- conversation's facts are written as Maya's agent landed them on that run, and the judgement is decided with the
-- calls her agent made (claim_judgement and complete_judgement are what claim_judgement and decide_judgement call).
--
-- WHAT WOULD MAKE IT FAIL. Let dream bind two kinds by name alone and §4's queue is empty; let a twin stay open
-- after its pair is bound and §4 raises; read an edge without its source's policy and §5 raises.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set maya '''00000000-0000-0000-0000-000000101901'''
\set leo  '''00000000-0000-0000-0000-000000101902'''
\set as_maya 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000101901"}''; set local role authenticated;'
\set as_leo  'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000101902"}''; set local role authenticated;'
\set as_operator 'reset role; reset request.jwt.claims;'

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'mem0 agent article: %', p_what;
    end if;
end $$;
create function pg_temp.maya_graph(p_query text default 'GRAPH "Maya Okafor"') returns text language sql as $$
    select string_agg(relation || ' ' || key, ', ' order by relation, key)
      from jsonb_to_recordset(aiq.query(p_query) -> 'rows') as r(relation text, key text)
$$;

-- Setup, as the article's first block: a role that may register text, two people with no org, the relations.
insert into rbac.users (id, email, status) values (:maya, 'maya@example.com', 'active'), (:leo, 'leo@example.com', 'active');
insert into rbac.roles (name, description) values ('member', 'an ordinary person') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('member', 'resources', 'create') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values (:maya, 'member'), (:leo, 'member') on conflict do nothing;
select aiq.register_graph_vocabulary('[{"relation":"lives_in"},{"relation":"works_at"},
 {"relation":"diet"},{"relation":"allergic_to"},{"relation":"prefers"}]') ->> 'relations' as relations;
insert into content.channels (name, kind, config, visibility)
values ('memory', 'manual', '{"description": "memories written directly, with no pipeline"}', 'public')
on conflict do nothing;

-- §1 Maya registers her history, each memory saying when it was said, and the worker writes what each says.
:as_maya
select content.register_text('memory', 'maya-home-2026-01', '[{"content": "Maya lives in Leeds."}]',
  '{"said_at": "2026-01-05T09:00:00Z"}') ->> 'status' as january;
select content.register_text('memory', 'maya-home-2026-06', '[{"content": "Maya moved to Lisbon for a job at Harbour Health."}]',
  '{"said_at": "2026-06-01T10:00:00Z"}') ->> 'status' as june;
:as_operator

-- The article's history block (dev/examples/mem0-memory/blocks/04), pasted as a reader pastes it.
-- block: mem0-history
-- psql, as p8: the worker writes what each memory says, from when it was said; June closes January's home
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Leeds"}],"edges":[{"s":0,"t":1,"r":"lives_in"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-01'),
                    'valid_from', '2026-01-05T09:00:00Z')) ->> 'edges_new' as january;
select aiq.close_edge(jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-01'),
                                         'relation', 'lives_in'),
 '2026-06-01T10:00:00Z',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-06'))) as closed;
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"place","n":"Lisbon"},{"k":"company","n":"Harbour Health"}],
   "edges":[{"s":0,"t":1,"r":"lives_in"},{"s":0,"t":2,"r":"works_at"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-home-2026-06'),
                    'valid_from', '2026-06-01T10:00:00Z')) ->> 'edges_new' as june;
-- /block
-- CI's database holds the demo fixtures, so every count below is of Maya's own facts, by her node's id.
select distinct e.src_id as maya_node from aiq.edges e, jsonb_array_elements(e.provenance -> 'sources') src
 where src ->> 'resource_id' = (select id::text from content.resources where external_id = 'maya-home-2026-01') \gset
select pg_temp.check((select string_agg(d.summary || ' ' || p.valid_from::date || ' ' || coalesce(p.valid_to::date::text, 'now'), ', '
                                        order by p.valid_from)
                        from aiq.edge_periods p join aiq.nodes d on d.id = p.dst_id
                       where p.relation = 'lives_in' and p.src_id = :'maya_node') = 'Leeds 2026-01-05 2026-06-01, Lisbon 2026-06-01 now',
    '§1: Leeds held from January until June, when Lisbon began');
:as_maya
select pg_temp.check(pg_temp.maya_graph($q$GRAPH "Maya Okafor" AS OF '2026-03-01'$q$) = 'lives_in place/leeds',
    '§1: as of March she lived in Leeds: ' || coalesce(pg_temp.maya_graph($q$GRAPH "Maya Okafor" AS OF '2026-03-01'$q$), 'nothing'));
select pg_temp.check(pg_temp.maya_graph() = 'lives_in place/lisbon, works_at company/harbour health',
    '§1: now she lives in Lisbon and works at Harbour Health: ' || coalesce(pg_temp.maya_graph(), 'nothing'));
:as_operator

-- §2 The article's bookings block (blocks/07), pasted as a reader pastes it, then the join, as Maya and as Leo.
-- block: mem0-bookings
create schema if not exists travel;
create table if not exists travel.bookings (id int primary key, departs date not null, destination text not null, owner_id uuid not null);
with maya as (select id from rbac.users where email = 'maya@example.com')
insert into travel.bookings select b.*, maya.id from maya, (values
  (1, date '2026-03-14', 'Edinburgh'), (2, date '2026-07-02', 'Porto'), (3, date '2026-11-20', 'Madrid'))
  b(id, departs, destination)
on conflict (id) do nothing;
grant usage on schema travel to authenticated;
grant select on travel.bookings to authenticated;
alter table travel.bookings enable row level security;
drop policy if exists owner_reads on travel.bookings;
create policy owner_reads on travel.bookings for select using (owner_id = (select rbac.current_user_id()));
-- /block
create temp table maya_node as select :'maya_node'::uuid as id;
grant select on maya_node to authenticated;
create function pg_temp.leaving_from() returns text language sql as $$
    select string_agg(b.destination || ' ' || d.summary, ', ' order by b.departs) from travel.bookings b
      join aiq.edge_periods p on p.relation = 'lives_in' and aiq.edge_is_current(p.valid_from, p.valid_to, b.departs)
                             and p.src_id = (select id from pg_temp.maya_node)
      join aiq.nodes d on d.id = p.dst_id
$$;
:as_maya
select pg_temp.check(pg_temp.leaving_from() = 'Edinburgh Leeds, Porto Lisbon, Madrid Lisbon',
    '§2: each trip leaves from where she lived when it departed: ' || coalesce(pg_temp.leaving_from(), 'nothing'));
:as_leo
select pg_temp.check(pg_temp.leaving_from() is null, '§2: Leo gets no rows');
:as_operator

-- §3 What her conversation said, landed as her agent landed it on the article's run: from now, citing what she wrote.
:as_maya
select content.register_text('memory', 'maya-chat-2026-10',
  '[{"content": "I am vegetarian and allergic to peanuts. Where should I eat near the office tonight?"}]') ->> 'status' as conversation;
:as_operator
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"diet","n":"vegetarian"},{"k":"food","n":"peanuts"}],
   "edges":[{"s":0,"t":1,"r":"diet"},{"s":0,"t":2,"r":"allergic_to"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-chat-2026-10'),
                    'agent', 'agent:' || :maya)) ->> 'edges_new' as conversation;
:as_maya
select pg_temp.check(pg_temp.maya_graph() = 'allergic_to food/peanuts, diet diet/vegetarian, lives_in place/lisbon, works_at company/harbour health',
    '§3: her agent''s two facts land on the same Maya: ' || coalesce(pg_temp.maya_graph(), 'nothing'));
:as_operator

-- §4 The article's signature block (blocks/10b), pasted as a reader pastes it.
:as_maya
select content.register_text('memory', 'maya-signature-2026-09', '[{"content": "Maya Okafor, Data Lead, Harbour Health, Lisbon."}]',
  '{"said_at": "2026-09-15T08:00:00Z"}') ->> 'status' as signature;
:as_operator
-- block: mem0-signature
-- psql, as p8: another reader, signature-reader, reads her email signature and types Harbour Health an organization
select aiq.upsert_graph(
 '{"nodes":[{"k":"person","n":"Maya Okafor"},{"k":"organization","n":"Harbour Health"}],"edges":[{"s":0,"t":1,"r":"works_at"}]}',
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'maya-signature-2026-09'),
                    'agent', 'signature-reader', 'valid_from', '2026-09-15T08:00:00Z')) ->> 'edges_new' as signature;
-- where she works, each fact with its sources
select k.key as object, e.valid_from::date as held_from, jsonb_array_length(e.provenance->'sources') as sources,
       (select string_agg(c.content, ' | ')
          from jsonb_array_elements(e.provenance->'sources') src
          join content.resource_chunks c on c.resource_id::text = src->>'resource_id') as said
  from aiq.edges e
  join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.relation = 'works_at'
 order by e.valid_from;
-- /block
select pg_temp.check((select count(*) from aiq.edges where src_id = :'maya_node' and relation = 'works_at') = 2,
    '§4: two kinds of Harbour Health are two nodes, so two works_at facts');
select pg_temp.check((select r - 'since' - 'until' = '{"superseded": 0, "promoted_exact": 0, "promotion_refused": 0,
                              "soft_left_for_a_judge": 7, "queued_for_a_judge": 2}'::jsonb from aiq.dream() r),
    '§4: dream decides nothing by rule here, and queues the one pair it cannot, from both sides');
:as_maya
select pg_temp.check((select count(*) from aiq.judgements where status = 'open' and evidence ->> 'key' = 'harbour health') = 2,
    '§4: both sides of the Harbour Health pair wait for Maya''s agent');
select pg_temp.check((select (aiq.claim_judgement(null, j.id) -> 'evidence' -> 'said') @> '[{"relation": "works_at"}]'
                        from aiq.judgements j
                       where j.status = 'open' and j.evidence ->> 'key' = 'harbour health'
                         and j.evidence ->> 'claimed_kind' = 'organization'),
    '§4: the claim shows what was said about the organization');
select pg_temp.check((select aiq.complete_judgement(j.id,
                         jsonb_build_object('decision', 'bind', 'target', j.evidence -> 'candidates' -> 0 -> 'node_id'),
                         'Same name, Harbour Health, written as an organization in her signature and a company in her June memory; Maya Okafor works at each, and nothing either said conflicts.')
                         ->> 'status' = 'decided'
                        from aiq.judgements j
                       where j.status = 'claimed' and j.evidence ->> 'key' = 'harbour health'),
    '§4: her agent binds the organization to the company');
select pg_temp.check((select count(*) from aiq.judgements
                       where status = 'moot' and evidence ? 'settled_by'
                         and evidence ->> 'key' = 'harbour health' and evidence ->> 'claimed_kind' = 'company') = 1,
    '§4: the twin settles with its pair, naming the judgement that bound it');
:as_operator
select pg_temp.check((select count(*) filter (where r.tier = 'agent' and r.decided_by = 'agent:' || :maya) = 1
                        from aiq.node_resolutions r join aiq.soft_nodes s on s.id = (r.evidence ->> 'soft_id')::uuid
                       where s.key = 'harbour health'),
    '§4: the binding is recorded as Maya''s agent''s');
select pg_temp.check((select string_agg(k.key || ' ' || e.valid_from::date || ' ' || jsonb_array_length(e.provenance -> 'sources'), ', ')
                        from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
                       where e.src_id = :'maya_node' and e.relation = 'works_at'
                         and aiq.edge_is_current(e.valid_from, e.valid_to, now()))
                     = 'company/harbour health 2026-06-01 2',
    '§4: one works_at fact, from June, with both memories behind it');

-- §5 Leo reads none of it.
:as_leo
select pg_temp.check(pg_temp.maya_graph() is null, '§5: Leo reads nothing of Maya''s graph');
select pg_temp.check((select count(*) from aiq.edges where src_id = :'maya_node') = 0,
    '§5: Leo reads no edge of Maya''s');
:as_operator

rollback;
