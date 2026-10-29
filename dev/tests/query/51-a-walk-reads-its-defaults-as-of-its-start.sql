-- A WALK READS ITS DEFAULTS AND WORDINGS AS OF ITS START (REM-1245; Sirsh, M-20261029-142849-f9d4).
--
-- aiq.parameters is append-only: a change closes the current row and adds the next, a delete closes the row, and a
-- closed row never changes. A walk reads its parameters as of its own start, so a default or a decider wording
-- changed later never rewrites a finished walk. On 5801 (29 Oct) walk.describe's default moved from source to lines,
-- and a memoryless replay walk started before settings were recorded (01a187a8) could no longer be read:
-- walk_structure raised 'the replay was judged under another task wording' (cory). That case is part 3 here.
--
-- A change holds from its transaction's start (now()), as a run's created_at does. A test is one transaction, so
-- every change here holds from the same now(): a run is placed before a change by moving its created_at back an hour.

\set ON_ERROR_STOP on

begin;

-- 1. The history itself.
do $$
declare
    past timestamptz := now() - interval '1 hour';
    n    int;
begin
    insert into aiq.parameters (name, part, value, controls, read_by, why)
    values ('walk.query_fiftyone', 'walk', '1', 'query/51', 'query/51', 'query/51');
    -- a row from before this transaction (as every row is, once committed): from -infinity
    if (select valid_from from aiq.parameters where name = 'walk.query_fiftyone') is distinct from '-infinity' then
        raise exception 'a new name did not start from -infinity';
    end if;
    -- seeding again what is there adds no row, as every upgrade does
    select count(*) into n from aiq.parameters;
    insert into aiq.parameters as p (name, part, value, controls, read_by, why)
    select name, part, value, controls, read_by, why from aiq.parameters where name = 'walk.span' and valid_to is null
    on conflict (name) where valid_to is null do update
       set value = excluded.value, controls = excluded.controls, read_by = excluded.read_by, why = excluded.why,
           updated_at = now()
     where p.set_by = 'spec';
    if (select count(*) from aiq.parameters) <> n then
        raise exception 'seeding unchanged values added history';
    end if;
    -- a change closes the row at now() and adds the new value from now(); a second change in the same transaction
    -- changes that new row in place
    update aiq.parameters set value = '2' where name = 'walk.query_fiftyone';
    update aiq.parameters set value = '3', why = 'query/51, again' where name = 'walk.query_fiftyone';
    if (select string_agg(format('%s[%s,%s)', value, case when valid_from = now() then 'now' else valid_from::text end,
                                 case when valid_to = now() then 'now' else coalesce(valid_to::text, '') end), ' ' order by valid_from)
          from aiq.parameters where name = 'walk.query_fiftyone') is distinct from '1[-infinity,now) 3[now,)' then
        raise exception 'the history is %, where it is 1 until now and 3 from now', (select string_agg(format('%s[%s,%s)', value,
            valid_from, valid_to), ' ' order by valid_from) from aiq.parameters where name = 'walk.query_fiftyone');
    end if;
    if aiq.parameter('walk.query_fiftyone', past) <> '1' or aiq.parameter('walk.query_fiftyone') <> '3'
       or aiq.parameter('walk.query_fiftyone', now()) <> '3' or (aiq.parameters_of('walk', past)->>'query_fiftyone') <> '1' then
        raise exception 'as of an hour ago: %, now: %', aiq.parameter('walk.query_fiftyone', past), aiq.parameter('walk.query_fiftyone');
    end if;
    -- a closed row never changes and never goes: statements that match it leave it as it is
    update aiq.parameters set value = '9' where name = 'walk.query_fiftyone' and valid_to is not null;
    delete from aiq.parameters where name = 'walk.query_fiftyone' and valid_to is not null;
    if aiq.parameter('walk.query_fiftyone', past) is distinct from '1' then
        raise exception 'a closed row was changed or deleted';
    end if;
    -- a name cannot be renamed out of its history
    begin
        update aiq.parameters set name = 'walk.query_renamed' where name = 'walk.query_fiftyone';
        raise exception 'a parameter was renamed';
    exception when restrict_violation then null;
    end;
    -- deleting the current row: gone now, and still there as of an hour ago
    delete from aiq.parameters where name = 'walk.query_fiftyone';
    if aiq.parameter('walk.query_fiftyone') is not null or aiq.parameter('walk.query_fiftyone', past) <> '1' then
        raise exception 'a delete did not leave the history';
    end if;
    begin
        perform aiq.parameters_need('walk', array['query_fiftyone']);
        raise exception 'parameters_need read a deleted parameter as current';
    exception when no_data_found then null;
    end;
    if (aiq.parameters_need('walk', array['query_fiftyone'], past)->>'query_fiftyone') <> '1' then
        raise exception 'parameters_need did not read the parameter as of an hour ago';
    end if;
    -- a deleted name comes back from now, beside its history
    insert into aiq.parameters (name, part, value, controls, read_by, why)
    values ('walk.query_fiftyone', 'walk', '4', 'query/51', 'query/51', 'query/51');
    if aiq.parameter('walk.query_fiftyone') <> '4' or aiq.parameter('walk.query_fiftyone', past) <> '1' then
        raise exception 'a name added again did not start from now';
    end if;
end $$;

-- 2. A memoryless replay walk, on query/48's graph.
create temp table fx(n int, sitting text, pos int, terms text[], near int[]);
insert into fx values
 (1,'a',0,'{hallway,ceiling}','{2}'), (2,'a',1,'{ladder,ceiling}','{1}'), (3,'a',2,'{budget,hallway}','{4}'),
 (4,'a',3,'{moving,vanity}','{3}'), (5,'a',4,'{ladder,rental}','{2}'), (6,'a',5,'{paint}','{1}'),
 (7,'a',6,'{ladder,rental}','{5}'), (8,'a',7,'{paint}','{6}');

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
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/51 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/51 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/51 fixture')
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
    -- a replay judged under the source wording as it stands now
    insert into content.channels (name, kind, org_id, visibility) values ('walk-fixture-51', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture-51:replay', 'replay', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task('source'), 'verdicts',
        jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.8, 'term:hallway', 0.2))::text);
end $$;

select aiq.install_walk_workflow('walk_fixture_51', 'jev', 4);

do $$
declare
    -- the run names no describe: it runs under the default, set to source for it below
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture-51:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'order', 'p', 'wave', 3, 'seeds', 1, 'per_wave', 1));
    r       uuid;
    before  text;
    w0      text := aiq.walk_task('source');
    span0   jsonb := aiq.parameter('walk.span');
begin
    -- 2. A walk run before a wording change reads as it did. It runs under the wording as it stands (w0), and is then
    -- placed an hour back; the wording changes now.
    r := workflow.start_workflow('walk_fixture_51', inp || jsonb_build_object('settings', inp->'settings' || '{"describe": "source"}'));
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish in-database: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    update workflow.runs set created_at = now() - interval '1 hour' where id = r;
    before := aiq.walk_structure(r)::text;
    update aiq.parameters set value = to_jsonb(text 'query/51: a later source wording') where name = 'decider.task';
    if aiq.walk_task('source') = w0 or aiq.walk_task('source', now() - interval '1 hour') <> w0 then
        raise exception 'the wording history is not w0 then the later wording';
    end if;
    -- before history, this raised 'the replay was judged under another task wording'
    if aiq.walk_structure(r)::text is distinct from before then
        raise exception 'a wording changed after the walk changed how it reads';
    end if;

    -- 3. A run with no recorded settings (one from before the record) resolves the defaults as of its start.
    update workflow.tasks set output = output #- '{result,0,state,settings}' where run_id = r and step_key = 'start';
    update aiq.parameters set value = to_jsonb((span0 #>> '{}')::int + 1) where name = 'walk.span';
    if aiq.walk_run_settings(r)->'span' is distinct from span0 then
        raise exception 'an unrecorded run read span % where it started under %', aiq.walk_run_settings(r)->'span', span0;
    end if;
end $$;

-- 4. cory's case, 01a187a8 on 5801: a replay walk that names no describe, run while the default was source, before
-- settings were recorded and before history, so its start's defaults read today's describe. The replay's wording
-- says what it ran under.
do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture-51:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'order', 'p', 'wave', 3, 'seeds', 1, 'per_wave', 1));
    r uuid;
begin
    -- the wording back as the replay has it, and source the default while the walk runs
    update aiq.parameters set value = to_jsonb((select (string_agg(c.content, '' order by c.ordinal))::jsonb->>'task'
                                                  from content.resource_chunks c join content.resources res on res.id = c.resource_id
                                                 where res.uri = 'walk-fixture-51:replay'))
     where name = 'decider.task';
    update aiq.parameters set value = '"source"' where name = 'walk.describe';
    r := workflow.start_workflow('walk_fixture_51', inp);
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish in-database';
    end if;
    -- now the default is lines again, the run recorded nothing, and it started before history knew describe was source
    update aiq.parameters set value = '"lines"' where name = 'walk.describe';
    update workflow.tasks set output = output #- '{result,0,state,settings}' where run_id = r and step_key = 'start';
    if aiq.walk_settings((select input from workflow.runs where id = r), (select created_at from workflow.runs where id = r))->>'describe'
       <> 'lines' then
        raise exception 'this case needs lines as the default at the run''s start';
    end if;
    if aiq.walk_run_settings(r)->>'describe' is distinct from 'source' then
        raise exception 'a run from before history did not take describe from its replay''s wording: %', aiq.walk_run_settings(r);
    end if;
    perform aiq.walk_structure(r);
end $$;

\echo 'query/51: a walk reads its defaults and wordings as of its start'
rollback;
