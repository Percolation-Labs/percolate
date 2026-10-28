-- A WALK IS A WORKFLOW WHOSE ROWS ARE ITS RECORD (REM-1210).
--
-- The clue walk reads in waves and lets a decider judge, before reading, which leads to follow. Here it runs as the
-- `walk` workflow over a sixteen-node graph with a replay document standing in for Jev, so every step is in-database
-- and the run completes inside start_workflow. Sitting a is a ladder thread; sitting b is cooking. Search finds the
-- ceiling first; the replay accepts the terms 'ceiling' and 'ladder' and nothing else; the evidence is 2, 5 and 7.
-- Worked by hand: wave 0 reads 1; wave 1 judges 1's clues, travels 'ceiling' to 2 and fills from search; wave 2
-- judges 2's clues, travels 'ladder' to 5 and 7. What is held: the reads, the clues and their fate are rows a reader
-- queries, a clue the replay lacks is unjudged and never accepted, and a replay made under another wording is refused.

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
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/33 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/33 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/33 fixture')
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
    -- The replay: 'ceiling' and 'ladder' yes, 'hallway' no, everything else absent.
    insert into content.channels (name, kind, org_id, visibility) values ('walk-fixture', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility) values (ch, 'walk-fixture:replay', 'replay', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
        'q1', jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.9, 'term:hallway', 0.2)))::text);
    insert into content.resources (channel_id, uri, title, org_id, visibility) values (ch, 'walk-fixture:other-wording', 'x', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, '{"model": "stand-in", "task": "another wording", "verdicts": {}}');
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);
select aiq.install_walk_workflow('walk_fixture_long', 'jev', 10);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('id', 'q1', 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', 'walk-fixture:replay', 'offline', true,
        'settings', jsonb_build_object('wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r uuid := workflow.start_workflow('walk_fixture_run', inp);
    reads text[];
    got text;
    stop_wave int;
    last_read int;
begin
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish in-database: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    -- a database whose default model has no provider installs no q step at all, which is as good
    if exists (select 1 from workflow.tasks where run_id = r and step_key = 'q' and status <> 'skipped') then
        raise exception 'a graph walk given its order embedded the question anyway';
    end if;
    select array_agg(doc order by wave, ord) into reads from aiq.walk_reads(r);
    if reads[1:7] is distinct from array['wt/1','wt/2','wt/11','wt/12','wt/13','wt/5','wt/7'] then
        raise exception 'the reads are % where the hand-worked walk reads 1; 2, 11, 12; 13, 5, 7', reads;
    end if;
    if not array['wt/2','wt/5','wt/7'] <@ reads then
        raise exception 'the evidence was not all read: %', reads;
    end if;
    select string_agg(key || '=' || state, ',' order by key) into got
      from aiq.walk_clues(r) where key in ('term:ceiling', 'term:ladder', 'term:hallway');
    if got is distinct from 'term:ceiling=travelled,term:hallway=rejected,term:ladder=travelled' then
        raise exception 'the clues'' fate is % ', got;
    end if;
    if exists (select 1 from aiq.walk_clues(r) where p is null and decision <> 'unjudged')
       or not exists (select 1 from aiq.walk_clues(r) where decision = 'unjudged') then
        raise exception 'a clue the replay lacks is not unjudged, or none was';
    end if;
    if (select travelled_wave from aiq.walk_clues(r) where key = 'term:ladder') is distinct from 2 then
        raise exception 'ladder was not travelled in wave 2';
    end if;
    if (aiq.walk_verdicts(r)->'verdicts'->'q1'->>'term:ladder')::real is distinct from 0.9::real then
        raise exception 'the verdicts a later run replays lack ladder: %', aiq.walk_verdicts(r);
    end if;
    if (select open_leads from aiq.walk_waves(r) order by wave desc limit 1)
       is distinct from (select count(*)::int from aiq.walk_clues(r) where state = 'open') then
        raise exception 'walk_waves and walk_clues disagree on the leads open at the stop';
    end if;
    if aiq.walk_summary(r)->'stop'->>'reason' is null then
        raise exception 'the stop is missing from the summary: %', aiq.walk_summary(r)->'stop';
    end if;
    if (select count(*) from aiq.walk_waves(r)) < 2 then
        raise exception 'walk_waves has % rows', (select count(*) from aiq.walk_waves(r));
    end if;
    -- The views over a state already built read the same rows as the views over the run.
    if (select array_agg(w order by w.wave) from aiq.walk_state_waves(aiq.walk_state(r)) w)
       is distinct from (select array_agg(w order by w.wave) from aiq.walk_waves(r) w)
       or (select array_agg(c order by c.key) from aiq.walk_state_clues(aiq.walk_state(r)) c)
       is distinct from (select array_agg(c order by c.key) from aiq.walk_clues(r) c) then
        raise exception 'the views over a built state disagree with the views over the run';
    end if;
    -- A step's error fails the step and the run, with the reason on the task.
    r := workflow.start_workflow('walk_fixture_run', inp || '{"replay": "walk-fixture:other-wording"}');
    if (select status from workflow.runs where id = r) is distinct from 'failed'
       or not exists (select 1 from workflow.tasks where run_id = r and status = 'failed'
                                                    and error::text like '%another task wording%') then
        raise exception 'a replay judged under another wording was accepted';
    end if;
    -- A dry stop is a certificate only once every read's clues were judged: the walk that reads the whole graph
    -- stops in a wave after its last reads, never in the wave that read them (james, REM-1205).
    r := workflow.start_workflow('walk_fixture_long', jsonb_set(inp, '{settings,wave}', '6'));
    stop_wave := (aiq.walk_summary(r)->'stop'->>'wave')::int;
    last_read := (select max(wave) from aiq.walk_reads(r));
    if aiq.walk_summary(r)->'stop'->>'reason' is distinct from 'dry'
       or stop_wave is null or last_read is null or stop_wave <= last_read then
        raise exception 'a walk stopped dry before its last reads were judged: stop %, last read wave %',
            aiq.walk_summary(r)->'stop', (select max(wave) from aiq.walk_reads(r));
    end if;
    -- The audit names the stop as the run records it, so a reader sees one wave for one stop.
    if aiq.walk_audit(r)->>'state' not like format('ran dry at wave %s: nothing left to read; %%', stop_wave) then
        raise exception 'the audit names the dry stop differently from the run (wave %): %',
            stop_wave, aiq.walk_audit(r)->>'state';
    end if;
    raise notice 'query/33: a walk runs as a workflow, its reads and clues are rows, and a replay replays';
end $$;

rollback;
