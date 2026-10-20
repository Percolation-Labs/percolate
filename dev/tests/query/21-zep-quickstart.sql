-- PART TWO OF THE SERIES, FOR ZEP USERS: ZEP'S QUICKSTART, CALL FOR CALL, ON PERCOLATE (REM-1018).
--
-- The blocks of "Percolate for Zep users" that need no model, in the article's order, each followed by the
-- assertion that keeps the article true:
--   §1 Ana's history, dated as Zep's reference_time dates a message, and what her conversation added;
--   §2 business data: a reference table of ports bound into the graph, and the catalogue refresh it needs;
--   §3 aiq.dream() ends the port she no longer ships via and binds both ports to their rows;
--   §4 the reader's own agent deciding what dream queued, each verdict recorded as agent:<Ana>;
--   §5 why each fact holds, what held in March (GRAPH ... AS OF), and her bookings beside her memory;
--   §6 the context block, read as Ana and as somebody else.
-- The blocks that call a model (the assistant's turns) or the reader's own agent (reading and judging over MCP) run against a
-- live stack in dev/examples/zep-memory/run.sh, which runs every block in order. Here the conversation's two facts
-- are written as Ana's agent read them on that run, and the judgements are decided with the calls her agent made
-- over MCP (claim_judgement and complete_judgement are what claim_judgement and decide_judgement call).
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
  {"relation": "based_in",  "single_valued": true},
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

-- The article's history block (dev/examples/zep-memory/blocks/03), pasted as a reader pastes it.
-- block: zep-history
-- psql, as p8: the worker writes what each memory says, from when it was said
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Ana Costa"}, {"k":"company","n":"Tagus Ceramics"},
            {"k":"place","n":"Lisbon"}, {"k":"port","n":"Rotterdam"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"based_in"}, {"s":0,"t":3,"r":"ships_via"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-support-2026-01'),
                    'valid_from', '2026-01-14T09:30:00Z')) ->> 'edges_new' as january;
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"A. Costa"}, {"k":"organization","n":"Tagus Ceramics"}, {"k":"mode","n":"rail"}],
  "edges": [{"s":0,"t":1,"r":"works_at"}, {"s":0,"t":2,"r":"prefers"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-email-2026-03'),
                    'valid_from', '2026-03-09T16:00:00Z')) ->> 'edges_new' as march;
-- an older reader, reader-v0, read the same email and got it wrong
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"A. Costa"}, {"k":"mode","n":"road"}],
  "edges": [{"s":0,"t":1,"r":"prefers"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-email-2026-03'),
                    'agent', 'reader-v0', 'run_id', 'mar-09', 'valid_from', '2026-03-09T16:00:00Z')) ->> 'edges_new' as misread;
-- /block
-- What Ana's agent read from her message on the article's run, landed as land_message_facts lands it: from now.
select aiq.upsert_graph($g$
 {"nodes": [{"k":"person","n":"Ana Costa"}, {"k":"port","n":"Felixstowe"}, {"k":"place","n":"Porto"}],
  "edges": [{"s":0,"t":1,"r":"ships_via"}, {"s":0,"t":2,"r":"based_in"}]}$g$,
 jsonb_build_object('resource_id', (select id from content.resources where external_id = 'ana-chat-2026-10'),
                    'agent', 'agent:' || :ana)) ->> 'edges_new' as conversation;

:as_ana
select pg_temp.check(pg_temp.ana_graph() =
    'based_in place/lisbon, based_in place/porto, ships_via port/felixstowe, ships_via port/rotterdam, '
    'works_at company/tagus ceramics',
    '§1: before reconciling, Ana''s graph holds both ports and both homes: ' || pg_temp.ana_graph());
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
select pg_temp.check((select r - 'since' - 'until' = '{"superseded": 2, "promoted_exact": 2, "promotion_refused": 0,
                              "soft_left_for_a_judge": 8, "queued_for_a_judge": 4}'::jsonb from aiq.dream() r),
    '§3: dream ends Rotterdam and Lisbon, binds the two ports, and queues four of the eight names it leaves');
:as_ana
select pg_temp.check(pg_temp.ana_graph() =
    'based_in place/porto, ships_via felixstowe, works_at company/tagus ceramics',
    '§3: after dream, Ana ships via the Felixstowe row only, and is based in Porto: ' || pg_temp.ana_graph());
:as_operator

-- §4 Ana's agent decides what dream queued, as Ana. Each pair is queued from both sides; binding one side settles
-- its twin, which goes moot naming the judgement that bound it (from 0.2.27; on 0.2.26 the agent closed it with none).
:as_ana
create function pg_temp.decide(p_key text, p_kind text, p_bind boolean, p_reason text) returns text
language plpgsql as $$
declare j uuid; t uuid;
begin
    select id into j from aiq.judgements
     where status = 'open' and evidence ->> 'key' = p_key and evidence ->> 'claimed_kind' = p_kind;
    if j is null then raise exception 'zep quickstart article: §4: nothing queued for % (%)', p_key, p_kind; end if;
    perform aiq.claim_judgement(null, j);
    if p_bind then
        select (c ->> 'node_id')::uuid into t
          from aiq.judgements q, jsonb_array_elements(q.evidence -> 'candidates') c where q.id = j limit 1;
        return aiq.complete_judgement(j, jsonb_build_object('decision', 'bind', 'target', t), p_reason) ->> 'status';
    end if;
    return aiq.complete_judgement(j, '{"decision": "none"}', p_reason) ->> 'status';
end $$;
select pg_temp.check((select count(*) from aiq.judgements where status = 'open') = 4,
    '§4: the four queued items wait for Ana''s agent');
select pg_temp.decide('a. costa', 'person', true,
    'Same surname and initial, a person both times; each is linked to a Tagus Ceramics, and nothing either says conflicts.');
select pg_temp.decide('tagus ceramics', 'organization', true,
    'Same name, Tagus Ceramics; the only difference is the kind each was written as, and nothing either says conflicts.');
select pg_temp.check((select count(*) from aiq.judgements
                       where status = 'moot' and evidence ? 'settled_by'
                         and (evidence ->> 'key', evidence ->> 'claimed_kind')
                             in (('ana costa', 'person'), ('tagus ceramics', 'company'))) = 2,
    '§4: each twin settled with its pair: moot, naming the judgement that bound it');
:as_operator
:as_ana
select pg_temp.check(pg_temp.ana_graph() like '%prefers mode/rail%' and pg_temp.ana_graph() like '%prefers mode/road%'
                     and pg_temp.ana_graph() not like '%organization/tagus ceramics%',
    '§4: rail and the misread road moved onto Ana, and the company typed two ways is one: ' || pg_temp.ana_graph());
:as_operator
-- The misreading reader's run is withdrawn: what only it said ends, and stays readable.
select pg_temp.check((select r ->> 'retracted' = '1' and r ->> 'withdrawn' = '0' from aiq.retract_derived('reader-v0') r),
    '§4: retracting reader-v0 ends its one fact');
:as_ana
select pg_temp.check(pg_temp.ana_graph() not like '%mode/road%', '§4: road is gone from the present graph');
:as_operator

-- §5 Why, as of, and her bookings beside her memory.
select pg_temp.check((select count(*) filter (where r.tier = 'registry' and r.decided_by = 'dream') = 2
                            and count(*) filter (where r.tier = 'agent' and r.decided_by = 'agent:' || :ana) = 2
                        from aiq.node_resolutions r join aiq.soft_nodes s on s.id = (r.evidence ->> 'soft_id')::uuid
                       where s.key in ('rotterdam', 'felixstowe', 'a. costa', 'tagus ceramics')),
    '§5: four bindings, each with who made it');
-- REM-1013, scoped: a withdrawn fact is ended today, so a read of March still says she preferred road.
-- This assertion records the gap; when retraction becomes an appended record it fails, and goes.
select pg_temp.check((select e.valid_from = '2026-03-09T16:00:00Z' and e.valid_to is not null
                        from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
                       where e.relation = 'prefers' and k.key = 'mode/road'),
    '§5: the withdrawn road fact reads as held from March (REM-1013)');
select pg_temp.check((select e.valid_to is not null and e.valid_from = '2026-01-14T09:30:00Z'
                        from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
                       where e.relation = 'ships_via' and k.key = 'rotterdam'),
    '§5: the Rotterdam fact held from January and has ended, rather than being deleted');
:as_ana
select pg_temp.check(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-03-01'$q$) =
    'based_in place/lisbon, ships_via rotterdam, works_at company/tagus ceramics',
    '§5: as of March she shipped via Rotterdam: ' || coalesce(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-03-01'$q$), 'nothing'));
select pg_temp.check(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-05-01'$q$) =
    'based_in place/lisbon, prefers mode/rail, prefers mode/road, ships_via rotterdam, works_at company/tagus ceramics',
    '§5: as of May the withdrawn road preference still reads as held (REM-1013): '
    || coalesce(pg_temp.ana_graph($q$GRAPH "Ana Costa" AS OF '2026-05-01'$q$), 'nothing'));
select pg_temp.check((select string_agg(b.id || ' ' || p.name || ' ' || d.summary, ', ' order by b.departs)
                        from crm.bookings b
                        join crm.ports p on p.id = b.port_id
                        left join aiq.edges e on e.relation = 'ships_via'
                                             and aiq.edge_is_current(e.valid_from, e.valid_to, b.departs)
                        left join aiq.nodes d on d.id = e.dst_id) = '1 Rotterdam Felixstowe, 2 Felixstowe Felixstowe',
    '§5: the 3 November booking routes via Rotterdam after she moved to Felixstowe');
:as_operator

-- §6 The article's context block (blocks/12), pasted as a reader pastes it.
-- block: zep-context
-- psql, as p8: a context block is a query, so it is a function anyone may call and that runs as its caller
create schema if not exists memory;
grant usage on schema memory to authenticated;
create or replace function memory.context(p_name text) returns text
language sql stable security invoker as $$
  select string_agg(format('- %s %s %s (%s to %s)', s.summary, replace(e.relation, '_', ' '), d.summary,
                           e.valid_from::date, coalesce(e.valid_to::date::text, 'now')),
                    E'\n' order by e.valid_to nulls last, e.valid_from, e.relation desc)
    from aiq.lookup(p_name) l
    join aiq.edges e on e.src_id = l.node_id
    join aiq.nodes s on s.id = e.src_id
    join aiq.nodes d on d.id = e.dst_id
$$;
grant execute on function memory.context(text) to authenticated;
-- /block
:as_ana
select pg_temp.check(memory.context('Ana Costa') like '- Ana Costa ships via Rotterdam (2026-01-14 to %)%'
                     and memory.context('Ana Costa') like '%- Ana Costa ships via Felixstowe (% to now)%'
                     and memory.context('Ana Costa') like '%- Ana Costa prefers rail (2026-03-09 to now)%',
    E'§6: Ana''s context block names the ended port first, with its dates:\n' || coalesce(memory.context('Ana Costa'), 'nothing'));
:as_leo
select pg_temp.check(memory.context('Ana Costa') is null, '§6: the same call as Leo returns nothing');
:as_operator

rollback;
