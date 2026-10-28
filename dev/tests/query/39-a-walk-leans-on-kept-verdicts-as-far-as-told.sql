-- A WALK LEANS ON KEPT VERDICTS AS FAR AS IT IS TOLD (REM-1199; Sirsh, M-20261027-115632-55e8).
--
-- Every verdict a decider gives is kept, append-only and dated: aiq.walk_keep writes a run's verdicts as one
-- document that is never changed. settings.memory (0 to 1, default 0) is how far a later run leans on them: at 0 it
-- does not read them, which is the walk as it was; above, a clue judged before and now takes
-- (1 - memory) * now + memory * before, and one judged only before takes it whole and is not asked again. Only
-- verdicts given before the run started, under the run's wording, are read.
--
-- query/36's graph and replay ('ladder' at 0.4, a rejection), with one kept document from an earlier run: ladder
-- 0.9, risotto 0.7, and hallway 0.95 dated after the run starts; and one under another wording, ladder 0.0. At
-- memory 0 ladder is rejected and 5 and 7 are not read; at memory 1 it is 0.9, accepted and travelled, and the walk
-- reads query/33's seven; at 0.5 it is 0.65. Risotto is taken whole, hallway keeps the replay's 0.2, and the other
-- wording is never read. An offline run asked nobody, so it keeps nothing.


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
    -- in the shared org, where register_text looks for a channel a caller with no org names
    insert into content.channels (name, kind, org_id, visibility)
    values ('walk-fixture-kept', 'manual', rbac.shared_org_id(), 'public');
    perform content.register_text('walk-fixture-kept', u1, '[{"content": "-"}]'::jsonb, 'an earlier run', u1, null, jsonb_build_object('question', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1')::text, 'task', aiq.walk_task(), 'verdicts',
            jsonb_build_object('term:ladder', jsonb_build_object('p', 0.9, 'at', now() - interval '1 day'),
                               'term:risotto', jsonb_build_object('p', 0.7, 'at', now() - interval '1 day'),
                               'term:hallway', jsonb_build_object('p', 0.95, 'at', now() + interval '1 hour'))));
    perform content.register_text('walk-fixture-kept', u2, '[{"content": "-"}]'::jsonb, 'a run under another wording', u2, null, jsonb_build_object('question', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1')::text, 'task', 'another wording',
            'verdicts', jsonb_build_object('term:ladder', jsonb_build_object('p', 0.0, 'at', now() - interval '1 day'))));
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('node_id', (select id from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/1'), 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r     uuid;
    reads text[];
    st    jsonb;
begin
    -- Memory 0, the default: the kept verdicts are not read.
    r := workflow.start_workflow('walk_fixture_run', inp);
    st := aiq.walk_state(r);
    if (st->'p'->>'term:ladder')::real is distinct from 0.4::real or st->'p' ? 'term:risotto' then
        raise exception 'at memory 0 the kept verdicts were read: %', st->'p';
    end if;
    select array_agg(doc order by wave, ord) into reads from aiq.walk_reads(r);
    if reads[1:7] && array['wt/5','wt/7'] then
        raise exception 'at memory 0 a rejected clue was travelled: %', reads;
    end if;
    -- An offline run asked nobody: its keep step ran and kept no document.
    if (select status from workflow.tasks where run_id = r and step_key = 'keep') is distinct from 'succeeded'
       or exists (select 1 from content.resources where uri = 'verdicts:q1:' || r) then
        raise exception 'the keep step of an offline run: %',
            (select status || ' ' || coalesce(error::text, '') from workflow.tasks where run_id = r and step_key = 'keep');
    end if;

    -- Memory 1: ladder is the kept 0.9, accepted and travelled.
    r := workflow.start_workflow('walk_fixture_run', jsonb_set(inp, '{settings,memory}', '1'));
    st := aiq.walk_state(r);
    if (st->'p'->>'term:ladder')::real is distinct from 0.9::real then
        raise exception 'at memory 1 ladder is %', st->'p'->>'term:ladder';
    end if;
    select array_agg(doc order by wave, ord) into reads from aiq.walk_reads(r);
    if reads[1:7] is distinct from array['wt/1','wt/2','wt/11','wt/12','wt/13','wt/5','wt/7'] then
        raise exception 'at memory 1 the reads are % where accepting ladder reads 1; 2, 11, 12; 13, 5, 7', reads;
    end if;
    -- a verdict given after the run started is not read, so hallway keeps the replay's 0.2
    if (st->'p'->>'term:hallway')::real is distinct from 0.2::real then
        raise exception 'a verdict dated after the run started was read: hallway %', st->'p'->>'term:hallway';
    end if;

    -- Memory 0.5: ladder is halfway; risotto, judged only before, is taken whole.
    r := workflow.start_workflow('walk_fixture_run', jsonb_set(inp, '{settings,memory}', '0.5'));
    st := aiq.walk_state(r);
    if abs((st->'p'->>'term:ladder')::real - 0.65) > 0.0001 or (st->'p'->>'term:risotto')::real is distinct from 0.7::real then
        raise exception 'at memory 0.5 ladder is % and risotto %', st->'p'->>'term:ladder', st->'p'->>'term:risotto';
    end if;
    raise notice 'query/39: a walk leans on kept verdicts as far as its memory setting says, and not at all by default';
end $$;

rollback;
