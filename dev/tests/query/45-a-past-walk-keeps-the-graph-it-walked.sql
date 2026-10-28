-- A PAST WALK KEEPS THE GRAPH IT WALKED, AND AN EDGE IS CLOSED, NEVER DELETED (Sirsh, M-20261028-200720-890b).
--
-- A walk's leads are read back from its graph (aiq.walk_clues, walk_why), so a link that changes after the walk would
-- change what the walk is said to have seen. Two things keep a past walk as it was. A walk whose scope is indexed
-- (aiq.walk_index, a kept graph document per version of the links) records that document at its start, and every
-- later reading takes the graph from it. And aiq.edges refuses DELETE and TRUNCATE: a fact that stops holding is
-- closed (valid_to), and only a node's own removal takes its edges, by cascade.
--
-- query/39's graph and replay, indexed, then one offline walk; then the graph is rewritten in place (the tag 'ladder'
-- renamed, and a backdated walk_tagged edge added from wt/1 to 'risotto'), and the walk's leads and reads must not
-- move. On main the rename moves the run's leads (term:ladder becomes term:stepladder).


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
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
        'q1', jsonb_build_object('term:ceiling', 0.9, 'term:ladder', 0.4, 'term:hallway', 0.2)))::text);
end $$;

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('id', 'q1', 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', 'walk-fixture:replay', 'offline', true,
        'settings', jsonb_build_object('wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r      uuid;
    v_uri  text;
    clues0 jsonb;
    reads0 jsonb;
    e      uuid;
    n      int;
begin
    perform aiq.walk_index(inp);  -- what percolate walk index leaves after writing the links
    r := workflow.start_workflow('walk_fixture_run', inp);
    perform workflow.drain_sql_steps(r);
    v_uri := (select output->'result'->0->'state'->>'graph' from workflow.tasks where run_id = r and step_key = 'start');
    if v_uri is null or not exists (select 1 from content.resources where content.resources.uri = v_uri) then
        raise exception 'the start step recorded no kept graph document: %', v_uri;
    end if;
    select jsonb_agg(c order by c.key) into clues0 from aiq.walk_clues(r) c;
    select jsonb_agg(w order by w.wave, w.ord) into reads0 from aiq.walk_reads(r) w;
    if clues0 is null or not clues0 @> '[{"key": "term:ladder"}]' then
        raise exception 'the fixture walk raised no term:ladder lead: %', clues0;
    end if;

    -- The graph changes after the walk: a tag renamed in place, and a link added with a valid time before the walk.
    update aiq.nodes set summary = 'stepladder' where entity_type = 'walk_fixture_tag' and summary = 'ladder';
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance, valid_from)
    select i.id, tg.id, 'walk_tagged', i.org_id, '{}', now() - interval '1 day'
      from aiq.nodes i, aiq.nodes tg
     where i.entity_type = 'walk_fixture' and i.summary = 'wt/1'
       and tg.entity_type = 'walk_fixture_tag' and tg.summary = 'risotto';
    if (select jsonb_agg(c order by c.key) from aiq.walk_clues(r) c) is distinct from clues0 then
        raise exception 'the past walk''s leads moved with the graph: %',
            (select jsonb_agg(c.key order by c.key) from aiq.walk_clues(r) c);
    end if;
    if (select jsonb_agg(w order by w.wave, w.ord) from aiq.walk_reads(r) w) is distinct from reads0 then
        raise exception 'the past walk''s reads moved with the graph';
    end if;

    -- An edge cannot be deleted or truncated away.
    select id into e from aiq.edges where relation = 'walk_next' limit 1;
    begin
        delete from aiq.edges where id = e;
        raise exception 'a DELETE on aiq.edges was not refused';
    exception when raise_exception then
        if sqlerrm not like 'aiq.edges are closed, never deleted%' then raise; end if;
    end;
    begin
        truncate aiq.edges cascade;
        raise exception 'a TRUNCATE on aiq.edges was not refused';
    exception when raise_exception then
        if sqlerrm not like 'aiq.edges are closed, never deleted%' then raise; end if;
    end;

    -- A node's own removal still takes its edges with it.
    select count(*) into n from aiq.edges ed join aiq.nodes nd on nd.id in (ed.src_id, ed.dst_id)
     where nd.entity_type = 'walk_fixture' and nd.summary = 'wt/18';
    delete from aiq.nodes where entity_type = 'walk_fixture' and summary = 'wt/18';
    if n = 0 or exists (select 1 from aiq.edges ed join aiq.nodes nd on nd.id in (ed.src_id, ed.dst_id)
                         where nd.entity_type = 'walk_fixture' and nd.summary = 'wt/18') then
        raise exception 'removing a node did not take its % edges', n;
    end if;
    raise notice 'query/45: a past walk keeps the graph it walked, and an edge is closed, never deleted';
end $$;

rollback;
