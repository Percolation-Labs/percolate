-- A REPLAY READS SEARCH'S ORDER AS THE RECORDING HAD IT (REM-1246).
--
-- A walk's seeds and every wave's search fill come from search's order, which for a channel walk is an approximate
-- vector index whose near ties need not order the same way on another install. A replay that re-queried search read
-- different messages from its first differing search read on (the tour's smoke 3, 29 Oct: all 20 of a replay's
-- unjudged leads came out of messages the recording never read). A replay document now carries the order the walk
-- read, and a replay reads that order, whatever search would answer now.
--
-- query/45's graph. Walk A reads search order X. Its replay document carries X. B replays it while handed another
-- order Y, and reads exactly A's documents in A's order.

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

select aiq.install_walk_workflow('walk_fixture_order', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    x   jsonb := to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']);
    y   jsonb := to_jsonb(array['wt/11','wt/12','wt/1','wt/18','wt/17','wt/16','wt/15','wt/14','wt/13',
                                'wt/7','wt/5','wt/2','wt/8','wt/6','wt/4','wt/3']);
    a   uuid;
    b   uuid;
    ch  uuid := (select id from content.channels where name = 'walk-fixture');
    org uuid := (select id from rbac.orgs order by id limit 1);
    rep uuid;
    rdoc jsonb;
    ra  text;
    rb  text;
begin
    perform aiq.walk_index(inp);
    a := workflow.start_workflow('walk_fixture_order', inp || jsonb_build_object('search', x, 'offline', true,
            'replay', (select id from content.resources where uri = 'walk-fixture:replay')));
    perform workflow.drain_sql_steps(a);
    rdoc := aiq.walk_verdicts(a);
    if rdoc->'order' is distinct from x then
        raise exception 'the replay document does not carry the order the walk read: %', rdoc->'order';
    end if;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture:replay-order', 'replay', org, 'public') returning id into rep;
    insert into content.resource_chunks (resource_id, ordinal, content) values (rep, 0, rdoc::text);
    b := workflow.start_workflow('walk_fixture_order', inp || jsonb_build_object('search', y, 'offline', true, 'replay', rep));
    perform workflow.drain_sql_steps(b);
    select string_agg(doc || '@' || wave, ' ' order by wave, ord) into ra from aiq.walk_reads(a);
    select string_agg(doc || '@' || wave, ' ' order by wave, ord) into rb from aiq.walk_reads(b);
    if rb is distinct from ra then
        raise exception 'the replay read % where the recording read %', rb, ra;
    end if;
    raise notice 'query/56: a replay reads search''s recorded order (%)', ra;
end $$;

rollback;
