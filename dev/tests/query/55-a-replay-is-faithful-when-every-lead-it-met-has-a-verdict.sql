-- A REPLAY SAYS WHICH GRAPH IT WALKED, AND IS FAITHFUL ONLY WHEN IT HELD A VERDICT FOR EVERY LEAD IT MET (REM-1246).
--
-- A replay's verdicts are keyed by leads. Over links that differ from the recording's -- text changed under the index, as
-- the plan-marker strip did to the article's step 70 -- a replay meets leads it never judged and showed them as rejected,
-- passing as the walk it replays. A replay document names its kept graph; a replay walks that document when the
-- database holds it ('recorded') and otherwise rebuilds from today's links ('rebuilt'), which on another install are the
-- same edges under another uri. walk_summary's decider judges faithfulness by content: faithful when every lead met has
-- a recorded verdict, else 'partial: N leads unjudged'.
--
-- query/45's graph, indexed. Walk A records its leads; a replay holds a verdict for every one, on A's graph.

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

select aiq.install_walk_workflow('walk_fixture_rg', 'jev', 3);

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
    doc  jsonb;
    d    jsonb;
    gone text;
begin
    perform aiq.walk_index(inp);
    a := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true,
            'replay', (select id from content.resources where uri = 'walk-fixture:replay')));
    perform workflow.drain_sql_steps(a);
    doc := aiq.walk_verdicts(a);
    if doc->>'graph' is null then
        raise exception 'the replay document names no graph: %', doc - 'verdicts';
    end if;
    doc := jsonb_set(doc, '{verdicts}', (select jsonb_object_agg(c.key, 0.1) from aiq.walk_clues(a) c));
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture:replay-rg', 'replay', org, 'public') returning id into rep;
    insert into content.resource_chunks (resource_id, ordinal, content) values (rep, 0, doc::text);

    -- 1. on the recorded graph, every verdict held: recorded, faithful
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if d->>'graph' is distinct from 'recorded' or (d->>'faithful')::boolean is distinct from true then
        raise exception '1: a replay on its recorded graph with every verdict is not recorded and faithful: %', d;
    end if;

    -- 2. naming a graph this database does not hold, on the same links (a reader's install): rebuilt, and still
    -- faithful, since every lead it met has a verdict
    update content.resource_chunks set content = jsonb_set(doc, '{graph}', to_jsonb(text 'walk-graph:another-install'))::text
     where resource_id = rep;
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if d->>'graph' is distinct from 'rebuilt' or (d->>'faithful')::boolean is distinct from true
       or (d->>'unjudged')::int is distinct from 0 then
        raise exception '2: a rebuilt replay meeting no unjudged lead is not faithful: %', d;
    end if;

    -- 3. the links change after the recording (wt/1, the seed, tagged 'risotto' too, indexed again): the replay naming
    -- the recorded graph walks it, and is faithful
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', i.org_id, '{}'
      from aiq.nodes i, aiq.nodes tg
     where i.entity_type = 'walk_fixture' and i.summary = 'wt/1'
       and tg.entity_type = 'walk_fixture_tag' and tg.summary = 'risotto';
    perform aiq.walk_index(inp);
    update content.resource_chunks set content = doc::text where resource_id = rep;
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if d->>'graph' is distinct from 'recorded' or (d->>'faithful')::boolean is distinct from true then
        raise exception '3: after the links changed, the replay did not walk its recorded graph faithfully: %', d;
    end if;

    -- 4. rebuilt over the changed links: the seed's new lead was never judged, so it says partial
    update content.resource_chunks set content = jsonb_set(doc, '{graph}', to_jsonb(text 'walk-graph:another-install'))::text
     where resource_id = rep;
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if d->>'graph' is distinct from 'rebuilt' or (d->>'faithful')::boolean is distinct from false
       or (d->>'unjudged')::int < 1 or d->>'partial' not like 'partial: % leads unjudged' then
        raise exception '4: a rebuilt replay meeting an unjudged lead did not say partial: %', d;
    end if;
    raise notice 'query/55: recorded or rebuilt, a replay is faithful only when every lead it met has a verdict (4: %)', d->>'partial';
end $$;

rollback;
