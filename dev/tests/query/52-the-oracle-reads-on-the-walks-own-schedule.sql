-- THE ORACLE READS ON THE WALK'S OWN SCHEDULE (walk.md §11 at cdd1c68f; mike, M-20261029-143357-85f1).
--
-- The oracle is the ceiling a walk is scored against: same graph, seeds and budget, and the labelled set to choose by.
-- It reads as the walk reads: cumulative reads reach wave x walk.wave (wave 0's seeds count toward wave 1); from wave
-- 2, walk.per_wave of search's next unread documents come first; and a lead a read raises is live only from the next
-- wave, because the walk judges a wave's leads before it reads on. A ceiling that skipped the search fill fell below
-- search on 1M contradiction walks.
--
-- query/45's graph, indexed, so the walk keeps a graph document. One offline walk: seeds 1 (wt/1), wave 6, per_wave
-- 1. The labelled piece is wt/16, in the other sitting: no lead out of sitting a reaches it, only leads out of
-- sitting b, and the walk enters sitting b only through search's next unread document, wt/11, which it reads first
-- in wave 2 (read 7). wt/11's leads are live from wave 3; wave 2 runs out of live leads at read 10 and fills from
-- search (wt/12-14), and wave 3 opens with search's next, wt/15 (read 13). So the oracle reads wt/16 after read 13. Making a lead live at once reads it in wave 2; skipping the search fill never
-- enters sitting b until sitting a runs dry.

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

select aiq.install_walk_workflow('walk_fixture_oracle', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 6, 'seeds', 1,
                                       'per_wave', 1, 'expand_all', false));
    r    uuid;
    got  text;
    k5   int;
begin
    perform aiq.walk_index(inp);
    r := workflow.start_workflow('walk_fixture_oracle', inp);
    perform workflow.drain_sql_steps(r);
    select string_agg(format('%s:%s<%s', o.k, o.doc, o.via), ' ' order by o.k) into got
      from aiq.walk_oracle(r, array['wt/16'], 18) o;
    raise notice 'query/52: oracle %', got;
    select o.k into k5 from aiq.walk_oracle(r, array['wt/16'], 18) o where o.doc = 'wt/16';
    if k5 is null or k5 <= 13 then
        raise exception 'the oracle read wt/16 at % (%); its leads are raised by wt/11 in wave 2 and live from wave 3', k5, got;
    end if;
    -- each later wave opens with search's next unread document, before any lead
    if (select string_agg(o.k || ':' || o.doc, ' ' order by o.k) from aiq.walk_oracle(r, array['wt/16'], 18) o
         where o.k in (7, 13) and o.via = 'search') is distinct from '7:wt/11 13:wt/15' then
        raise exception 'waves 2 and 3 did not open with search''s per_wave reads (wt/11, wt/15): %', got;
    end if;
    raise notice 'query/52: the oracle reads on the walk''s own schedule';
end $$;

rollback;
