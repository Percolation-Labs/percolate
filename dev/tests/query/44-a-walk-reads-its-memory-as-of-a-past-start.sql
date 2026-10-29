-- A WALK WITH MEMORY CAN READ THE STORE AS OF A PAST WALK'S START (REM-1219; Sirsh, M-20261028-134903-f73c).
--
-- A walk with memory reads the verdicts kept before it started, so a rerun reads verdicts its original never saw:
-- on BEAM 1M:10 a rerun after 86 new verdicts differed in 451 of 500 reads. settings.memory_as_of moves the cutoff
-- back, to a past run's start (its id) or to a time, and never past the run's own start.
--
-- query/39's graph and replay, with two kept documents for q1: ladder 0.9 two days ago, and ladder 0.0 an hour ago.
-- At memory 1 with no memory_as_of both are read, ladder is their mean 0.45 and is rejected. As of a day ago, or as
-- of a run that started a day ago, only the first is read and ladder is 0.9. As of a time after the run started, the
-- run's own start still holds, so a verdict dated after it (hallway 0.95) is not read. A run id that names no run is
-- refused.


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
declare
    u1 text := 'verdicts:' || gen_random_uuid();
    u2 text := 'verdicts:' || gen_random_uuid();
begin
    insert into content.channels (name, kind, org_id, visibility)
    values ('walk-fixture-kept', 'manual', rbac.shared_org_id(), 'public');
    perform content.register_text('walk-fixture-kept', u1, '[{"content": "-"}]'::jsonb, 'a run two days ago', u1, null,
        jsonb_build_object('question', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1')::text, 'task', aiq.walk_task(), 'verdicts',
            jsonb_build_object('term:ladder', jsonb_build_object('p', 0.9, 'at', now() - interval '2 days'))));
    perform content.register_text('walk-fixture-kept', u2, '[{"content": "-"}]'::jsonb, 'a run an hour ago', u2, null,
        jsonb_build_object('question', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1')::text, 'task', aiq.walk_task(), 'verdicts',
            jsonb_build_object('term:ladder', jsonb_build_object('p', 0.0, 'at', now() - interval '1 hour'),
                               'term:hallway', jsonb_build_object('p', 0.95, 'at', now() + interval '1 hour'))));
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('node_id', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1'), 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false, 'memory', 1));
    r     uuid;
    old   uuid;
    st    jsonb;
begin
    -- No memory_as_of: both kept documents are read, and ladder is their mean.
    r := workflow.start_workflow('walk_fixture_run', inp);
    st := aiq.walk_state(r);
    if abs((st->'p'->>'term:ladder')::real - 0.45) > 0.0001 then
        raise exception 'with no memory_as_of ladder is %, not the mean 0.45 of both kept verdicts', st->'p'->>'term:ladder';
    end if;

    -- As of a day ago: only the verdict from two days ago is read.
    r := workflow.start_workflow('walk_fixture_run',
                                 jsonb_set(inp, '{settings,memory_as_of}', to_jsonb(now() - interval '1 day')));
    st := aiq.walk_state(r);
    if (st->'p'->>'term:ladder')::real is distinct from 0.9::real then
        raise exception 'as of a day ago ladder is %, not 0.9', st->'p'->>'term:ladder';
    end if;

    -- As of a run that started a day ago: the same.
    old := workflow.start_workflow('walk_fixture_run', inp);
    update workflow.runs set created_at = now() - interval '1 day' where id = old;
    r := workflow.start_workflow('walk_fixture_run', jsonb_set(inp, '{settings,memory_as_of}', to_jsonb(old::text)));
    st := aiq.walk_state(r);
    if (st->'p'->>'term:ladder')::real is distinct from 0.9::real then
        raise exception 'as of a run started a day ago ladder is %, not 0.9', st->'p'->>'term:ladder';
    end if;

    -- As of a time after the run started: the run's own start holds, so hallway keeps the replay's 0.2.
    r := workflow.start_workflow('walk_fixture_run',
                                 jsonb_set(inp, '{settings,memory_as_of}', to_jsonb(now() + interval '2 hours')));
    st := aiq.walk_state(r);
    if (st->'p'->>'term:hallway')::real is distinct from 0.2::real then
        raise exception 'memory_as_of moved the cutoff past the run''s start: hallway %', st->'p'->>'term:hallway';
    end if;

    -- A run id that names no run is refused.
    r := workflow.start_workflow('walk_fixture_run',
                                 jsonb_set(inp, '{settings,memory_as_of}', to_jsonb(gen_random_uuid()::text)));
    begin
        perform aiq.walk_state(r);
        raise exception 'a memory_as_of naming no run was not refused';
    exception when no_data_found then null;
    end;
    raise notice 'query/44: a walk with memory reads the store as of a past walk''s start when told to';
end $$;

rollback;
