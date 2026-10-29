-- A REPLAY WALKS THE GRAPH IT WAS RECORDED ON, OR SAYS IT DID NOT (REM-1246).
--
-- A replay's verdicts are keyed by the leads of the graph they were given on. Links indexed again can differ -- a tag
-- renamed renames its leads -- and a replay read against them met leads it held no verdict for and showed them as
-- rejected, passing as the walk it replays (the article's step 70, 29 Oct). Now a replay document names its kept
-- graph (aiq.walk_verdicts), a replay walks that document when the database holds it, and walk_summary's decider says
-- faithful only when it did and every lead it met had a verdict; otherwise it says how far it is partial.
--
-- query/45's graph, indexed. Walk A records the leads; a replay document holds a verdict for every one of them, on A's
-- graph. Then the seed wt/1 gains a tag and the scope is indexed again, which keeps a second graph document.

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
begin
    perform aiq.walk_index(inp);
    -- A: offline on the fixture's replay, so it raises its leads; then every lead it raised gets a verdict
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

    -- the links change after the recording: wt/1, the seed, is tagged 'risotto' too, and the scope indexed again,
    -- which keeps a second graph document in which wt/1 raises a lead the replay never judged (term:risotto)
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', i.org_id, '{}'
      from aiq.nodes i, aiq.nodes tg
     where i.entity_type = 'walk_fixture' and i.summary = 'wt/1'
       and tg.entity_type = 'walk_fixture_tag' and tg.summary = 'risotto';
    perform aiq.walk_index(inp);
    if (select count(distinct uri) from content.resources where uri like 'walk-graph:%' and metadata ? 'walk_graph') < 2 then
        raise exception 'indexing again kept no second graph document';
    end if;

    -- B replays on the recorded graph, which this database holds: faithful
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if (d->>'faithful')::boolean is distinct from true or (d->>'unjudged')::int <> 0 then
        raise exception 'a replay on its recorded graph is not faithful: %', d;
    end if;
    if (select output->'result'->0->'state'->>'graph' from workflow.tasks where run_id = b and step_key = 'start')
       is distinct from doc->>'graph' then
        raise exception 'the replay did not walk its recorded graph';
    end if;

    -- C names a graph this database does not hold: it walks today's links and says partial
    update content.resource_chunks set content = jsonb_set(doc, '{graph}', to_jsonb(text 'walk-graph:not-here'))::text
     where resource_id = rep;
    b := workflow.start_workflow('walk_fixture_rg', inp || jsonb_build_object('offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    d := aiq.walk_summary(b)->'decider';
    if (d->>'faithful')::boolean is distinct from false or d->>'partial' not like '%walked today''s links%'
       or (d->>'unjudged')::int < 1 then
        raise exception 'a replay off its recorded graph did not say it was partial: %', d;
    end if;
    raise notice 'query/55: a replay walks its recorded graph, or says it is partial (%)', d->>'partial';
end $$;

rollback;
