-- PART TWO OF THE SERIES, FOR ZEP USERS: ZEP'S QUICKSTART, CALL FOR CALL, ON PERCOLATE (REM-1018).
--
-- The blocks of "Percolate for Zep users" that need no model, in the article's order, each followed by the
-- assertion that keeps the article true:
--   §1 Ana's history, dated as Zep's reference_time dates a message, and what her conversation added;
--   §2 business data: a reference table of ports bound into the graph, and the catalogue refresh it needs;
--   §3 aiq.dream() ends the port she no longer ships via and binds both ports to their rows;
--   §4 a judge's call on an alias, recorded with who decided and why;
--   §5 why each fact holds, what held in March (GRAPH ... AS OF), and her bookings beside her memory;
--   §6 the context block, read as Ana and as somebody else.
-- The blocks that call a model (the assistant's turns, reflect_session, gpt-4o judging the alias) run against a
-- live stack in dev/examples/zep-memory/run.sh, which runs every block in order. Here the conversation's two facts
-- are written as the extractor wrote them on that run, and the judge's verdict is the one it returned.
--
-- WHAT WOULD MAKE IT FAIL. Declare ships_via many-valued and §3 raises; let register_entity_table widen the
-- catalogue itself and the refusal in §2 raises (it is asserted, so the article's warning goes when the trap does);
-- read the context block as its definer and §6 raises.
--
-- One transaction, rolled back.

\set ON_ERROR_STOP on

\set ana '''00000000-0000-0000-0000-000000101801'''
\set leo '''00000000-0000-0000-0000-000000101802'''
\set as_ana 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000101801"}''; set local role authenticated;'
\set as_leo 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000101802"}''; set local role authenticated;'
\set as_operator 'reset role; reset request.jwt.claims;'

begin;

create function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'zep quickstart article: %', p_what;
    end if;
end $$;
create function pg_temp.ana_graph(p_query text default 'GRAPH "Ana Costa"') returns text language sql as $$
    select string_agg(relation || ' ' || key, ', ' order by relation, key)
      from jsonb_to_recordset(aiq.query(p_query) -> 'rows') as r(relation text, key text)
$$;

-- Setup, as the article's first block: a role that may register text, and two people with no org.
insert into rbac.users (id, email, status) values (:ana, 'ana@zep.test', 'active'), (:leo, 'leo@zep.test', 'active');
insert into rbac.roles (name, description) values ('member', 'an ordinary person') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action) values ('member', 'resources', 'create') on conflict do nothing;
insert into rbac.user_roles (user_id, role) values (:ana, 'member'), (:leo, 'member') on conflict do nothing;
insert into content.channels (name, kind, config, visibility)
values ('memory', 'manual', '{"description": "memories written directly, with no pipeline"}', 'public')
on conflict do nothing;
select aiq.register_graph_vocabulary($v$[
  {"relation": "lives_in",  "single_valued": true},
  {"relation": "works_at"},
  {"relation": "ships_via", "single_valued": true},
  {"relation": "prefers"}
]$v$) ->> 'relations' as relations;

-- §1 Ana registers two memories from before this install, each saying when it was said.
:as_ana
select content.register_text('memory', 'ana-support-2026-01',
  '[{"content": "Ana Costa of Tagus Ceramics, Lisbon: our containers ship via Rotterdam."}]',
  '{"said_at": "2026-01-14T09:30:00Z"}') ->> 'status' as january;
select content.register_text('memory', 'ana-email-2026-03',
  '[{"content": "A. Costa, Logistics, Tagus Ceramics: please keep the inland legs on rail."}]',
  '{"said_at": "2026-03-09T16:00:00Z"}') ->> 'status' as march;
select content.register_text('memory', 'ana-chat-2026-10',
  '[{"content": "From this month our containers go through Felixstowe, and I am now based in our Porto office."}]')
  ->> 'status' as conversation;
:as_operator

-- The article's history block, verbatim.
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Ana Costa"}, {"k":"company","n":"Tagus Ceramics"},
            {"k":"place","n":"Lisbon"}, {"k":"port","n":"Rotterdam"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"lives_in"}, {"s":0,"t":3,"r":"ships_via"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-support-2026-01'),
                    'valid_from', '2026-01-14T09:30:00Z')) ->> 'edges_new' as january;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"A. Costa"}, {"k":"company","n":"Tagus Ceramics"}, {"k":"mode","n":"rail"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-email-2026-03'),
                    'valid_from', '2026-03-09T16:00:00Z')) ->> 'edges_new' as march;
-- What gpt-4o read from her message on the article's run, landed as reflect_session lands it: from now.
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Ana Costa"}, {"k":"port","n":"Felixstowe"}, {"k":"office","n":"Porto office"}],
  "edges": [{"s":0,"t":1,"r":"ships_via"}, {"s":0,"t":2,"r":"works_at"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-chat-2026-10'))) ->> 'edges_new' as conversation;

:as_ana
select pg_temp.check(pg_temp.ana_graph() =
    'lives_in place/lisbon, ships_via port/felixstowe, ships_via port/rotterdam, works_at company/tagus ceramics, '
    'works_at office/porto office',
    '§1: before reconciling, Ana''s graph holds both ports and the office as an employer: ' || pg_temp.ana_graph());
:as_leo
select pg_temp.check(pg_temp.ana_graph() is null, '§1: Leo reads nothing of Ana''s graph');
:as_operator

-- §2 The article's business-data block, verbatim, but for the refresh, which is held back to show the trap.
create schema if not exists crm;
create table if not exists crm.ports (id uuid primary key default gen_random_uuid(), name text not null unique);
select aiq.register_entity_table('port', 'crm.ports', 'n.name', 'n.name', 'rbac.shared_org_id()');
insert into crm.ports (name) values ('Rotterdam'), ('Felixstowe'), ('Gothenburg') on conflict do nothing;

create table if not exists crm.bookings (id int primary key, departs date not null,
  port_id uuid not null references crm.ports, owner_id uuid not null);
with ana as (select id from rbac.users where email = 'ana@zep.test')
insert into crm.bookings select b.id, b.departs, p.id, ana.id
  from ana, (values (1, date '2026-11-03', 'Rotterdam'), (2, date '2026-11-24', 'Felixstowe')) b(id, departs, port)
  join crm.ports p on p.name = b.port
on conflict (id) do nothing;
grant usage on schema crm to authenticated;
grant select on crm.ports, crm.bookings to authenticated;
alter table crm.bookings enable row level security;
create policy owner_reads on crm.bookings for select using (owner_id = (select rbac.current_user_id()));

-- Without the refresh, dream counts both promotions as refused and says nothing of why. In a savepoint, so the
-- article's own run below starts from the same state.
savepoint before_refresh;
select pg_temp.check((select (r ->> 'promotion_refused')::int = 2 and (r ->> 'promoted_exact')::int = 0
                        from aiq.dream() r),
    '§2: with the catalogue not widened to ports, dream refuses both promotions');
rollback to savepoint before_refresh;
select aiq.register_graph_vocabulary() ->> 'relations' as relations;

-- §3 Dream.
select pg_temp.check((select r - 'since' - 'until' = '{"superseded": 1, "promoted_exact": 2, "promotion_refused": 0,
                              "soft_left_for_a_judge": 6}'::jsonb from aiq.dream() r),
    '§3: dream ends Rotterdam and binds the two ports, and leaves six names for a judge');
:as_ana
select pg_temp.check(pg_temp.ana_graph() =
    'lives_in place/lisbon, ships_via felixstowe, works_at company/tagus ceramics, works_at office/porto office',
    '§3: after dream, Ana ships via the Felixstowe row only: ' || pg_temp.ana_graph());
:as_operator

-- §4 The judge's call, recorded. The verdict is the one gpt-4o returned on the article's run.
\set verdict '{"same": true, "why": "Both notes refer to individuals associated with Tagus Ceramics, suggesting that \\"A. Costa\\" and \\"Ana Costa\\" are likely the same person."}'
select aiq.promote_soft_node(
         (select id from aiq.soft_nodes where key = 'a. costa'),
         (select n.id from aiq.nodes n join aiq.soft_nodes s on n.entity_type = 'soft' and n.entity_id = s.id
           where s.key = 'ana costa'),
         'gpt-4o', 'llm', :'verdict'::jsonb) ->> 'moved' as moved
 where (:'verdict'::jsonb ->> 'same')::boolean;
:as_ana
select pg_temp.check(pg_temp.ana_graph() like '%prefers mode/rail%', '§4: rail moved onto Ana with the alias');
:as_operator

-- §5 Why, as of, and her bookings beside her memory.
select pg_temp.check((select string_agg(s.claimed_kind || '/' || s.key || ' ' || r.decided_by || ' ' || r.tier, ', '
                                         order by r.at)
                        from aiq.node_resolutions r join aiq.soft_nodes s on s.id = (r.evidence ->> 'soft_id')::uuid
                       where s.key in ('rotterdam', 'felixstowe', 'a. costa'))
                     in ('port/rotterdam dream registry, port/felixstowe dream registry, person/a. costa gpt-4o llm',
                         'port/felixstowe dream registry, port/rotterdam dream registry, person/a. costa gpt-4o llm'),
    '§5: three bindings, each with who made it');
select pg_temp.check((select e.valid_to is not null and e.valid_from = '2026-01-14T09:30:00Z'
                        from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
                       where e.relation = 'ships_via' and k.key = 'rotterdam'),
    '§5: the Rotterdam fact held from January and has ended, rather than being deleted');
:as_ana
select pg_temp.check(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-03-01'$q$) =
    'lives_in place/lisbon, ships_via rotterdam, works_at company/tagus ceramics',
    '§5: as of March she shipped via Rotterdam: ' || coalesce(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-03-01'$q$), 'nothing'));
select pg_temp.check((select string_agg(b.id || ' ' || p.name || ' ' || d.summary, ', ' order by b.departs)
                        from crm.bookings b
                        join crm.ports p on p.id = b.port_id
                        left join aiq.edges e on e.relation = 'ships_via'
                                             and aiq.edge_is_current(e.valid_from, e.valid_to, b.departs)
                        left join aiq.nodes d on d.id = e.dst_id) = '1 Rotterdam Felixstowe, 2 Felixstowe Felixstowe',
    '§5: the 3 November booking routes via Rotterdam after she moved to Felixstowe');
:as_operator

-- §6 The article's context block, verbatim.
create schema if not exists memory;
grant usage on schema memory to authenticated;
create or replace function memory.context(p_name text) returns text
language sql stable security invoker as $$
  select string_agg(format('- %s %s %s (%s to %s)', s.summary, replace(e.relation, '_', ' '), d.summary,
                           e.valid_from::date, coalesce(e.valid_to::date::text, 'now')),
                    E'\n' order by e.valid_to nulls last, e.valid_from)
    from aiq.lookup(p_name) l
    join aiq.edges e on e.src_id = l.node_id
    join aiq.nodes s on s.id = e.src_id
    join aiq.nodes d on d.id = e.dst_id
$$;
grant execute on function memory.context(text) to authenticated;
:as_ana
select pg_temp.check(memory.context('Ana Costa') like '- Ana Costa ships via Rotterdam (2026-01-14 to %)%'
                     and memory.context('Ana Costa') like '%- Ana Costa ships via Felixstowe (% to now)%'
                     and memory.context('Ana Costa') like '%- Ana Costa prefers rail (2026-03-09 to now)%',
    E'§6: Ana''s context block names the ended port first, with its dates:\n' || coalesce(memory.context('Ana Costa'), 'nothing'));
:as_leo
select pg_temp.check(memory.context('Ana Costa') is null, '§6: the same call as Leo returns nothing');
:as_operator

rollback;
