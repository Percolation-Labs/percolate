-- A REPLAY IS HELD TO WHAT ITS RECORDING JUDGED (REM-1246).
--
-- faithful counted every lead a replay met without a verdict, including leads the recorded walk itself never judged:
-- the stack's stale stop ends a wave before judging what it raised, so an exact replay of such a walk read 'partial'
-- (1M:20's two stack walks, 29 Oct: every clue line identical, 949/949 and 1,489/1,489). The replay document now lists
-- the recording's own unjudged leads, and a replay is faithful when it holds a verdict for every lead the recording
-- judged.
--
-- query/45's graph. Walk A replays the fixture's three verdicts, so it leaves leads unjudged, as a stale stop does.
-- An exact replay of A is faithful; the same replay missing one verdict A did give is partial, one unjudged.

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

select aiq.install_walk_workflow('walk_fixture_held', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    a    uuid;
    b    uuid;
    ch   uuid := (select id from content.channels where name = 'walk-fixture');
    org  uuid := (select id from rbac.orgs order by id limit 1);
    rep  uuid;
    rdoc jsonb;
    d    jsonb;
    one  text;
begin
    perform aiq.walk_index(inp);
    a := workflow.start_workflow('walk_fixture_held', inp || jsonb_build_object('offline', true,
            'replay', (select id from content.resources where uri = 'walk-fixture:replay')));
    perform workflow.drain_sql_steps(a);
    rdoc := aiq.walk_verdicts(a);
    if jsonb_array_length(coalesce(rdoc->'unjudged', '[]'::jsonb)) = 0 then
        raise exception 'the recording left no lead unjudged, so the fixture cannot show the case: %', rdoc - 'verdicts' - 'order';
    end if;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture:replay-held', 'replay', org, 'public') returning id into rep;
    insert into content.resource_chunks (resource_id, ordinal, content) values (rep, 0, rdoc::text);
    b := workflow.start_workflow('walk_fixture_held', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if (d->>'faithful')::boolean is distinct from true or (d->>'unjudged')::int is distinct from 0 then
        raise exception 'an exact replay of a walk that left % leads unjudged is not faithful: %',
            jsonb_array_length(rdoc->'unjudged'), d;
    end if;
    -- a verdict the recording gave, gone: that lead is unjudged in the replay and the recording judged it
    one := (select min(k) from jsonb_object_keys(rdoc->'verdicts') k);
    update content.resource_chunks set content = (rdoc #- array['verdicts', one])::text where resource_id = rep;
    b := workflow.start_workflow('walk_fixture_held', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if (d->>'faithful')::boolean is distinct from false or (d->>'unjudged')::int is distinct from 1 then
        raise exception 'a replay missing the recorded verdict on % is not partial with 1 unjudged: %', one, d;
    end if;
    raise notice 'query/57: a replay is held to what its recording judged (% left unjudged by the recording, not counted)',
        jsonb_array_length(rdoc->'unjudged');
end $$;

rollback;
