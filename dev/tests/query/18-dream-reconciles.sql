-- Dream reconciles what knit landed, by construction only (REM-961).
--
-- aiq.dream() supersedes edges of relations declared single-valued and
-- promotes soft nodes whose key is exactly one typed node's. It makes no
-- judgement about meaning. The checks:
--   1. a single-valued relation keeps one current value per subject, and the
--      older edge ends where the newer begins, still readable as of before;
--   2. a relation nobody declared keeps every value (prefers is many-valued);
--   3. a soft node whose exact typed target appears later is promoted at tier
--      'registry'; an alias with no exact match is left for a judge;
--   4. a second run does nothing, and a dream run of the `dream` workflow
--      starts where the last one ended (REM-1163: the engine keeps the window).
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'dream: %', p_what;
    end if;
end $$;

-- The vocabulary: lives_in holds one value at a time; prefers is undeclared.
select aiq.register_graph_vocabulary('[{"relation":"lives_in","single_valued":true},{"relation":"prefers"}]');
select pg_temp.check((select single_valued from aiq.graph_vocabulary where relation = 'lives_in') is true
                 and (select single_valued from aiq.graph_vocabulary where relation = 'prefers') is null,
    'register_graph_vocabulary did not record lives_in as single-valued and leave prefers undeclared');

-- Knit, in three sessions. Maya moves; she prefers two things; a company is
-- named before anything typed has its name, and an alias names Acme loosely.
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Maya Q18"},{"k":"place","n":"Leeds"},{"k":"thing","n":"morning workouts"}],
  "edges":[{"s":0,"t":1,"r":"lives_in"},{"s":0,"t":2,"r":"prefers"}]}', '{"agent":"knit","run_id":"q18-r1"}');
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Maya Q18"},{"k":"place","n":"Manchester"},{"k":"thing","n":"evening workouts"},
  {"k":"company","n":"Quillon Q18"},{"k":"company","n":"Acme Corp Q18"}],
  "edges":[{"s":0,"t":1,"r":"lives_in"},{"s":0,"t":2,"r":"prefers"}]}', '{"agent":"knit","run_id":"q18-r2"}');
-- Dated, so the first session is a day before the second.
update aiq.edges set valid_from = now() - interval '2 days' where provenance->'sources' @> '[{"run_id":"q18-r1"}]';
update aiq.edges set valid_from = now() - interval '1 day'  where provenance->'sources' @> '[{"run_id":"q18-r2"}]';

-- The typed company appears after the knit, with exactly the soft node's name.
insert into demo.companies (id, name, org_id)
select gen_random_uuid(), 'Quillon Q18', s.org_id from aiq.soft_nodes s where s.key = 'quillon q18' limit 1;

create temp table q18_maya on commit drop as
select k.node_id as id from aiq.node_keys k where k.key = 'person/maya q18' and k.kind = 'canonical';
create temp view q18_current as
select e.relation, k.key as value
  from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id and k.kind = 'canonical'
 where e.src_id = (select id from q18_maya) and aiq.edge_is_current(e.valid_from, e.valid_to, now());

select pg_temp.check((select count(*) from q18_current where relation = 'lives_in') = 2,
    'the fixture should start with two current lives_in edges');

-- First run.
select aiq.dream() as first \gset
\echo :first
select pg_temp.check((:'first'::jsonb->>'superseded')::int >= 1, 'nothing was superseded: ' || :'first');
select pg_temp.check((select array_agg(value) from q18_current where relation = 'lives_in') = '{place/manchester}',
    '1. lives_in should hold only Manchester now');
select pg_temp.check((select e.valid_to from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id
                       where e.src_id = (select id from q18_maya) and e.relation = 'lives_in' and k.key = 'place/leeds')
                     = (select e.valid_from from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id
                       where e.src_id = (select id from q18_maya) and e.relation = 'lives_in' and k.key = 'place/manchester'),
    '1. Leeds should end exactly where Manchester begins');
select pg_temp.check(exists (select 1 from aiq.edges e join aiq.node_keys k on k.node_id = e.dst_id
                      where e.src_id = (select id from q18_maya) and e.relation = 'lives_in' and k.key = 'place/leeds'
                        and aiq.edge_is_current(e.valid_from, e.valid_to, now() - interval '36 hours')
                        and e.provenance->'sources' @> '[{"run_id":"q18-r1"}]'),
    '1. as of before the move Leeds should still be read, with its provenance');
select pg_temp.check((select count(*) from q18_current where relation = 'prefers') = 2,
    '2. an undeclared relation lost a value: prefers is many-valued');
select pg_temp.check((select s.resolved_node_id is not null from aiq.soft_nodes s where s.key = 'quillon q18'),
    '3. the soft node with an exact typed target was not promoted');
select pg_temp.check(exists (select 1 from aiq.node_resolutions r where r.tier = 'registry' and r.decided_by = 'dream'),
    '3. the promotion did not record tier registry, decided by dream');
select pg_temp.check((select s.resolved_node_id is null from aiq.soft_nodes s where s.key = 'acme corp q18'),
    '3. an alias with no exact match was promoted: that is a judge''s call');

-- Second run: nothing left to do.
select aiq.dream() as second \gset
\echo :second
select pg_temp.check((:'second'::jsonb->>'superseded')::int = 0 and (:'second'::jsonb->>'promoted_exact')::int = 0,
    '4. a second run changed something: ' || :'second');
-- Two scheduled-style runs, through the engine: the second starts where the
-- first ended. Defined disabled, so nothing ticks it.
select aiq.schedule_dream('0 0 1 1 *', false);
select workflow.start_workflow('dream', '{}') as run_a \gset
select workflow.start_workflow('dream', '{}') as run_b \gset
create temp view q18_runs as
select t.run_id, t.status, t.output->'result' as receipt
  from workflow.tasks t where t.run_id in (:'run_a', :'run_b') and t.step_key = 'reconcile';
select pg_temp.check((select count(*) from q18_runs where status = 'succeeded') = 2,
    '4. the dream workflow did not run its step: ' || (select string_agg(status, ', ') from q18_runs));
select pg_temp.check((select receipt->>'since' from q18_runs where run_id = :'run_b')
                   = (select receipt->>'until' from q18_runs where run_id = :'run_a'),
    '4. the second dream run did not start where the first ended');

do $$ begin raise notice 'query/18: dream supersedes a declared single-valued relation, keeps a many-valued one, promotes only an exact match, and a second run does nothing'; end $$;
rollback;
