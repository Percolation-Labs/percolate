-- A WALK'S START LOOKS UP ITS KEPT GRAPH ONCE, HOWEVER MANY RESOURCES THE STACK HOLDS (REM-1249).
--
-- walk_start records the kept graph document for its scope (query/45). ec81f997 found it with
-- `where res.uri = aiq.walk_graph_uri(inp, aiq.walk_graph_version(aiq.walk_keys(inp)))` over content.resources:
-- walk_graph_version is STABLE, so in a seq-scan filter Postgres evaluates it once per row, and each evaluation scans
-- the scope's walk edges. On 5801 (29 Oct) that was ~400 visible rows x 55,000 edges under RLS: 238 s as the run's
-- owner against 0.64 s with the version computed once, so the start step, which runs inside the worker's q write-back
-- (complete_task -> cascade -> execute_sql_step -> run_sql, 30 s statement_timeout), was cancelled and q retried.
--
-- Time is the symptom and a timing test is flaky, so this counts the mechanism: the fixture walk starts through the
-- same execute_sql_step path beside 200 more visible resources, and aiq.walk_graph_version may run a constant number
-- of times in that start, not once per resource. Measured on 5801 (2,482 resources): ec81f997's form ran it 1,382
-- times and fails here; 74b13c76's ran it 3 times and passes.


\set ON_ERROR_STOP on

begin;

-- every function call is counted for this transaction (pg_stat_get_xact_function_calls), SQL functions included
set local track_functions = 'all';

create temp table fx(n int, sitting text, pos int, terms text[], near int[]);
insert into fx values
 (1,'a',0,'{hallway,ceiling}','{2}'), (2,'a',1,'{ladder,ceiling}','{1}'), (3,'a',2,'{budget,hallway}','{4}'),
 (4,'a',3,'{moving,vanity}','{3}'), (5,'a',4,'{ladder,rental}','{2}'), (6,'a',5,'{paint}','{1}'),
 (7,'a',6,'{ladder,rental}','{5}'), (8,'a',7,'{paint}','{6}'),
 (11,'b',0,'{risotto}','{12}'), (12,'b',1,'{stock}','{11}'), (13,'b',2,'{parmesan}','{12}'), (14,'b',3,'{rest}','{13}'),
 (15,'b',4,'{bowls}','{14}'), (16,'b',5,'{arancini}','{11}'), (17,'b',6,'{fry}','{16}'), (18,'b',7,'{salt}','{17}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_fixture', gen_random_uuid(), org, 'public', 'wt/' || n from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_fixture', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_fixture';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_fixture_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/36 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/36 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/36 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_fixture' and i.summary = 'wt/' || fx.n
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_fixture_tag' and tg.summary = t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org, jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
      from fx x join fx y on y.sitting = x.sitting and y.pos = x.pos + 1
      join aiq.nodes a on a.entity_type = 'walk_fixture' and a.summary = 'wt/' || x.n
      join aiq.nodes b on b.entity_type = 'walk_fixture' and b.summary = 'wt/' || y.n;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', 0)
      from fx cross join unnest(fx.near) m
      join aiq.nodes a on a.entity_type = 'walk_fixture' and a.summary = 'wt/' || fx.n
      join aiq.nodes b on b.entity_type = 'walk_fixture' and b.summary = 'wt/' || m;
    -- The replay: 'ceiling' yes, 'ladder' a near miss, 'hallway' a plain no, everything else absent.
    insert into content.channels (name, kind, org_id, visibility) values ('walk-fixture', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture:replay', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.4, 'term:hallway', 0.2))::text);
end $$;

do $$
declare org uuid := (select id from rbac.orgs order by id limit 1);
begin
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    select (select id from content.channels where name = 'walk-fixture'), 'walk-fixture:other/' || i, 'other ' || i, org, 'public'
      from generate_series(1, 200) i;
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/2','wt/3']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    fn     oid := 'aiq.walk_graph_version(jsonb)'::regprocedure;
    r      uuid;
    before bigint;
    calls  bigint;
    n      int := (select count(*) from content.resources);
begin
    perform aiq.walk_index(inp);
    -- the start step runs as soon as its task is ready (autorun_sql_steps, the cascade the worker's write-back
    -- takes), so it may already have run inside start_workflow: count from before it
    before := coalesce(pg_stat_get_xact_function_calls(fn), 0);
    r := workflow.start_workflow('walk_fixture_run', inp);
    perform workflow.drain_sql_steps(r);
    calls := coalesce(pg_stat_get_xact_function_calls(fn), 0) - before;
    if (select status from workflow.tasks where run_id = r and step_key = 'start') is distinct from 'succeeded' then
        raise exception 'the fixture walk''s start step did not succeed: %',
            (select error from workflow.tasks where run_id = r and step_key = 'start');
    end if;
    if calls = 0 then
        raise exception 'walk_graph_version was never counted, so this test cannot see the lookup (track_functions?)';
    end if;
    if calls > 5 then
        raise exception 'the start step ran walk_graph_version % times beside % resources: the kept graph''s uri is '
                        'evaluated per row, not once (REM-1249)', calls, n;
    end if;
    raise notice 'query/49: a walk''s start looks up its kept graph once (% call(s) beside % resources)', calls, n;
end $$;

rollback;
