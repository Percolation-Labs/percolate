-- A WALK SAYS WHY ITS ANSWER IS INCOMPLETE, FROM ITS OWN ROWS (REM-1211).
--
-- aiq.walk_why(run, nodes) gives each labelled node the walk did not read
-- one reason: (a) never offered, (b) rejected with its P, (c) open with its
-- rank, or queued, or unjudged when a lead held no P. aiq.walk_audit(run) needs
-- no answer key. Three walks over query/33's sixteen-node graph, each with a
-- replay standing in for Jev, worked by hand from their clue rows:
--
--   eager     the replay accepts more leads than two-read waves can follow, so
--             wt/4, wt/5 and wt/7 sit behind open leads ranked 1 to 3 of 3
--   no-ladder the replay rejects 'ladder' at 0.4, so wt/5 and wt/7 are (b)
--             and 'ladder' is a near miss
--   offline   query/33's replay judges three clues; the rest are unjudged, so
--             wt/4 is unjudged and the walk earns no certificate
--
-- wt/99 is in no graph: never offered. The rules are percolate-core's
-- percolate_core/walk/why.py; the two agree on these walks.

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
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/34 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/34 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/34 fixture')
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

do $$
declare
    chunk text := jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
        'q1', jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.6, 'term:hallway', 0.2, 'next:wt/1', 0.8,
                                 'near:wt/1', 0.75, 'next:wt/2', 0.7, 'near:wt/2', 0.65)))::text;
    res uuid;
begin
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    select channel_id, u, 'replay', org_id, visibility from content.resources,
           unnest(array['walk-fixture:eager', 'walk-fixture:no-ladder']) u
     where uri = 'walk-fixture:replay';
    insert into content.resource_chunks (resource_id, ordinal, content)
    select id, 0, chunk from content.resources where uri = 'walk-fixture:eager';
    insert into content.resource_chunks (resource_id, ordinal, content)
    select id, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
               'q1', jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.4, 'term:hallway', 0.2)))::text
      from content.resources where uri = 'walk-fixture:no-ladder';
end $$;

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/',
        'question', jsonb_build_object('id', 'q1', 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', 'walk-fixture:replay', 'offline', true,
        'settings', jsonb_build_object('wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false,
                                       'span', 2));  -- the fixture's walk was laid out for next reaching 2
    gold text[] := array['wt/2', 'wt/4', 'wt/5', 'wt/7', 'wt/99'];
    eager uuid := workflow.start_workflow('walk_fixture_run', inp || jsonb_build_object('replay', 'walk-fixture:eager',
                      'settings', inp->'settings' || '{"wave": 2}'));
    noladder uuid := workflow.start_workflow('walk_fixture_run', inp || '{"replay": "walk-fixture:no-ladder"}');
    offline uuid := workflow.start_workflow('walk_fixture_run', inp);
    carrier uuid;
    got text;
    a jsonb;
begin
    if exists (select 1 from workflow.runs where id in (eager, noladder, offline) and status is distinct from 'succeeded') then
        raise exception 'a fixture walk did not finish in-database';
    end if;

    -- (c) open, ranked by P among the leads still open; (a) for a document no lead pointed at.
    select string_agg(format('%s %s %s %s %s', doc, letter, reason, coalesce(key, '-'), coalesce(detail, '-')), '; ' order by doc)
      into got from aiq.walk_why(eager, gold);
    if got is distinct from 'wt/4 c open next:wt/2 rank 1 of 3 open by P; '
                         || 'wt/5 c open near:wt/2 rank 2 of 3 open by P; '
                         || 'wt/7 c open term:ladder rank 3 of 3 open by P; '
                         || 'wt/99 a never offered - no clue raised in the walk pointed at it' then
        raise exception 'eager: why is %', got;
    end if;
    a := aiq.walk_audit(eager);
    if a->>'state' is distinct from 'cold, accepted leads open'
       or a->'open' is distinct from '[["next:wt/2", 0.7, 1], ["near:wt/2", 0.65, 1], ["term:ladder", 0.6, 2]]' then
        raise exception 'eager: the audit is %', a;
    end if;

    -- (b) rejected with its P; the rejected lead just under the gate is a near miss.
    select string_agg(format('%s %s %s %s', doc, letter, coalesce(key, '-'), coalesce(p::text, '-')), '; ' order by doc)
      into got from aiq.walk_why(noladder, gold) where doc in ('wt/5', 'wt/7');
    if got is distinct from 'wt/5 b term:ladder 0.4; wt/7 b term:ladder 0.4' then
        raise exception 'no-ladder: why is %', got;
    end if;
    if aiq.walk_audit(noladder)->'near misses' is distinct from '[["term:ladder", 0.4, 2]]' then
        raise exception 'no-ladder: the near misses are %', aiq.walk_audit(noladder)->'near misses';
    end if;

    -- A lead with no P is unjudged, never rejected; and while one points at unread documents there is no certificate.
    select string_agg(format('%s %s %s', doc, reason, key), '; ') into got from aiq.walk_why(offline, array['wt/4']);
    if got is distinct from 'wt/4 unjudged next:wt/2' then
        raise exception 'offline: why is %', got;
    end if;
    if aiq.walk_audit(offline)->>'state' not like '%unjudged leads still point at unread documents (no certificate)' then
        raise exception 'offline: a walk with unjudged leads open claimed the certificate: %', aiq.walk_audit(offline)->>'state';
    end if;

    -- The labels come from the caller and nowhere else: the same set gives the same answer, and none is refused.
    if exists (select 1 from aiq.walk_why(offline, array['wt/2', 'wt/5', 'wt/7'])) then
        raise exception 'the offline walk read all of wt/2, wt/5 and wt/7, yet why lists %',
            (select string_agg(doc, ', ') from aiq.walk_why(offline, array['wt/2', 'wt/5', 'wt/7']));
    end if;
    begin
        perform aiq.walk_why(offline, null);
        raise exception 'a walk was explained with no labelled nodes';
    exception when invalid_parameter_value then
        null;
    end;

    -- Coverage takes its labels from the caller too: of wt/2, wt/5 and wt/7 (one named twice, counted once), the
    -- walk's first read holds none, search's top 15 holds two (ranks 14 and 15) and every read the walk made holds all.
    select string_agg(format('%s %s %s %s', k, walk, search, labelled), '; ') into got
      from aiq.walk_coverage(offline, array['wt/2', 'wt/5', 'wt/7', 'wt/2'], array[1, 15, 1000]);
    if got is distinct from '1 0 0 3; 15 ' || (select count(*) from (select doc from aiq.walk_reads(offline)
                                                  order by wave, ord limit 15) x where doc in ('wt/2', 'wt/5', 'wt/7'))
                            || ' 2 3; 1000 3 3 3' then
        raise exception 'coverage of the offline walk is %', got;
    end if;

    -- A walk never carries its answer key: a question holding anything beside {id, text} fails at the start step.
    carrier := workflow.start_workflow('walk_fixture_run',
                   inp || jsonb_build_object('question', inp->'question' || '{"gold": ["wt/2"]}'));
    if (select status from workflow.runs where id = carrier) is distinct from 'failed'
       or not exists (select 1 from workflow.tasks where run_id = carrier and step_key = 'start'
                         and error::text like '%this one also carries gold%') then
        raise exception 'a walk whose question carried its answer key ended %, not failed at the start',
            (select status from workflow.runs where id = carrier);
    end if;

    -- A run the caller may not read is refused by the walk's own functions, not explained as empty.
    begin
        perform aiq.walk_audit(gen_random_uuid());
        raise exception 'a run that does not exist was audited';
    exception when no_data_found then
        null;
    end;

    raise notice 'query/34: an unread document is never offered, rejected with its P, open with its rank, or unjudged';
end $$;

rollback;
