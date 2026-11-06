-- A twin settles with its pair whoever holds it (REM-1313).
--
-- A pair of aliases is queued from both sides, and binding one side evicts the
-- node the other proposed (query/22 §8). The twin went moot only while it was
-- OPEN. On the Zep tutorial's run (6 Nov, 19-0.2.38) the reader's agent had
-- claimed one twin before binding its pair, and had passed another to the
-- person; both stayed live with nothing to bind, and each was closed by hand.
-- The checks, as two signed-in members:
--   1. a twin CLAIMED by another member, lease live, goes moot when its pair
--      is bound, naming the judgement that bound it, and the claim ends;
--   2. a twin passed to a person (to_human) goes moot too;
--   3. its holder deciding it afterwards decides nothing: the answer is moot,
--      already settled, naming that judgement, and nothing is written;
--   4. its holder claiming it again by id is told it is moot.
--
-- WHAT WOULD MAKE IT FAIL. Settle only an open twin, as 0.2.38 did, and 1 and
-- 2 raise; let complete_judgement decide a moot item and 3 raises.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'twin settles: %', p_what;
    end if;
end $$;

\set judge '''00000000-0000-0000-0000-000000006901'''
\set holder '''00000000-0000-0000-0000-000000006902'''
\set as_judge 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000006901","role":"authenticated"}''; set local role authenticated;'
\set as_holder 'reset role; set local request.jwt.claims = ''{"sub":"00000000-0000-0000-0000-000000006902","role":"authenticated"}''; set local role authenticated;'
\set as_engine 'reset role; set local request.jwt.claims = '''';'

insert into rbac.users (id, email, status) values
    (:judge, 'q69-judge@example.com', 'active'), (:holder, 'q69-holder@example.com', 'active')
on conflict (id) do nothing;

-- Two pairs, landed by knit as the engine: a person written two ways, and a
-- company written as two kinds. Each is queued from both sides. The person pair
-- is bound first. Bound the other way round, the second bind fails in
-- promote_soft_node on the unique edge index: a symmetric edge moved onto the
-- target is re-ordered by the catalogue trigger into a row that exists, which
-- the move's not-exists check, asking one orientation only, did not see. That
-- is a defect of its own and not this test's.
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ana Costa Q69"},{"k":"company","n":"Tagus Q69"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q69-1"}');
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"A. Costa Q69"},{"k":"organization","n":"Tagus Q69"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q69-2"}');
select aiq.dream() is not null as dreamt \gset

create function pg_temp.item(p_key text, p_kind text) returns uuid language sql as $$
    select id from aiq.judgements where kind = 'bind' and evidence->>'key' = p_key
       and evidence->>'claimed_kind' = p_kind order by queued_at desc limit 1 $$;
create function pg_temp.node(p_key text) returns uuid language sql as $$
    select node_id from aiq.node_keys where key = p_key and kind = 'canonical' $$;
select pg_temp.item('tagus q69', 'company') as tagus_co, pg_temp.item('tagus q69', 'organization') as tagus_org,
       pg_temp.item('a. costa q69', 'person') as alias, pg_temp.item('ana costa q69', 'person') as ana,
       pg_temp.node('company/tagus q69') as tagus_co_node, pg_temp.node('person/ana costa q69') as ana_node \gset
select pg_temp.check((select count(*) from aiq.judgements
                       where id in (:'tagus_co', :'tagus_org', :'alias', :'ana') and status = 'open') = 4,
    'setup: dream did not queue both sides of both pairs');
select set_config('q69.tagus_co', :'tagus_co', true), set_config('q69.tagus_org', :'tagus_org', true),
       set_config('q69.alias', :'alias', true), set_config('q69.ana', :'ana', true),
       set_config('q69.tagus_co_node', :'tagus_co_node', true), set_config('q69.ana_node', :'ana_node', true);

-- 1. Another member holds Ana Costa (lease live) when the judge binds A. Costa
--    onto her. The held item is the twin.
:as_holder
select aiq.claim_judgement(null, current_setting('q69.ana')::uuid) ->> 'status' as held \gset
:as_judge
select aiq.claim_judgement(null, current_setting('q69.alias')::uuid) is not null as c3 \gset
select aiq.complete_judgement(current_setting('q69.alias')::uuid,
         jsonb_build_object('decision', 'bind', 'target', current_setting('q69.ana_node')),
         'Same initial and surname, same company.') ->> 'status' as bound_alias \gset
:as_engine
select pg_temp.check(:'held' = 'claimed' and :'bound_alias' = 'decided', 'setup: 1 did not hold and bind');
select pg_temp.check((select status = 'moot' and claimed_by is null and lease_until is null
                             and evidence->'settled_by'->>'judgement' = :'alias'
                        from aiq.judgements where id = :'ana'),
    '1. the claimed twin was left held with nothing to bind: '
    || (select status || ' ' || coalesce(evidence->>'candidates', 'null') from aiq.judgements where id = :'ana'));

-- 2. The judge passes Tagus-as-company to the person, then binds Tagus-as-
--    organization onto the company node. The passed item is its twin.
:as_judge
select aiq.claim_judgement(null, current_setting('q69.tagus_co')::uuid) is not null as c1 \gset
select aiq.complete_judgement(current_setting('q69.tagus_co')::uuid, '{"decision": "human"}',
         'Two kinds for one name; the person should say.') ->> 'status' as passed \gset
select aiq.claim_judgement(null, current_setting('q69.tagus_org')::uuid) is not null as c2 \gset
select aiq.complete_judgement(current_setting('q69.tagus_org')::uuid,
         jsonb_build_object('decision', 'bind', 'target', current_setting('q69.tagus_co_node')),
         'Same name, written as two kinds.') ->> 'status' as bound_org \gset
:as_engine
select pg_temp.check(:'passed' = 'to_human' and :'bound_org' = 'decided', 'setup: 2 did not pass and bind');
select pg_temp.check((select status = 'moot' and evidence->'settled_by'->>'judgement' = :'tagus_org'
                        from aiq.judgements where id = :'tagus_co'),
    '2. the to_human twin was left waiting with nothing to bind: '
    || (select status || ' ' || coalesce(evidence->>'candidates', 'null') from aiq.judgements where id = :'tagus_co'));

-- 3. Its holder, unaware, decides it: nothing is decided, and the answer says
--    what settled it.
:as_holder
select aiq.complete_judgement(current_setting('q69.ana')::uuid, '{"decision": "none"}',
         'Nothing left to bind.') as late \gset
:as_engine
select pg_temp.check(:'late'::jsonb->>'status' = 'moot' and (:'late'::jsonb->>'already')::boolean
                     and :'late'::jsonb->'settled_by'->>'judgement' = :'alias',
    '3. a decision on a moot item did not answer that it was already settled: ' || :'late');
select pg_temp.check((select status = 'moot' and verdict is null and decided_by is null and decided_at is null
                        from aiq.judgements where id = :'ana'),
    '3. a decision on a moot item wrote something');

-- 4. Claiming it again by id says it is moot, not that someone holds it.
:as_holder
create function pg_temp.claim_error(p_id uuid) returns text language plpgsql as $$
begin
    perform aiq.claim_judgement(null, p_id);
    return 'claimed';
exception when others then
    return sqlerrm;
end $$;
select pg_temp.claim_error(current_setting('q69.ana')::uuid) as reclaim \gset
:as_engine
select pg_temp.check(:'reclaim' like '%is moot%', '4. a claim on a moot item did not say it is moot: ' || :'reclaim');

\echo 'query/69: a twin settles with its pair, open, claimed or passed to a person'
rollback;
