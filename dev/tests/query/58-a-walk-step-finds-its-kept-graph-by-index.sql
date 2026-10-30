-- A WALK STEP FINDS ITS KEPT GRAPH THROUGH AN INDEX, NOT A SCAN OF EVERY RESOURCE (REM-1228).
--
-- Every reading of a run (walk_state, so every read and judge step) takes its graph from the kept document the start
-- step recorded, and walk_graph, walk_start and a replay find documents by uri. content.resources had no index on
-- uri, so each of those lookups scanned the table under RLS: on 30 Oct, at 40,000 resources, 8 ms a lookup as a
-- signed-in reader against 0.04 ms with idx_resources_uri, growing with every document the stack holds.
--
-- Time is the symptom and a timing test is flaky, so this counts the mechanism: beside 2,000 more resources, twenty
-- readings of a finished walk's graph may not scan content.resources twenty times. Without the index they do.


\set ON_ERROR_STOP on

begin;

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
      from generate_series(1, 2000) i;
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

analyze content.resources;

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/2','wt/3']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r      uuid;
    before bigint;
    scans  bigint;
    n      int := (select count(*) from content.resources);
begin
    perform aiq.walk_index(inp);
    r := workflow.start_workflow('walk_fixture_run', inp);
    perform workflow.drain_sql_steps(r);
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the fixture walk did not finish: %', (select status from workflow.runs where id = r);
    end if;
    if (select aiq.walk_run_graph(r)) is null then
        raise exception 'the fixture walk has no graph to read, so this test cannot see the lookup';
    end if;
    before := (select seq_scan from pg_stat_xact_user_tables where relid = 'content.resources'::regclass);
    for i in 1..20 loop
        perform aiq.walk_run_graph(r);
    end loop;
    scans := (select seq_scan from pg_stat_xact_user_tables where relid = 'content.resources'::regclass) - before;
    if scans >= 20 then
        raise exception 'twenty readings of a walk''s graph scanned content.resources % times beside % resources: '
                        'the kept graph is found by a scan, not by idx_resources_uri (REM-1228)', scans, n;
    end if;
    raise notice 'query/58: twenty readings of a walk''s graph scanned content.resources % time(s) beside % resources',
                 scans, n;
end $$;

rollback;
