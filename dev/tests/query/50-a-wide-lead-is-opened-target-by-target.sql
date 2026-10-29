-- A WIDE LEAD IS OPENED TARGET BY TARGET (REM-1245, F8, walk spec 54619796).
--
-- With walk.open_whole = n, an accepted lead with more than n unread targets is not opened whole: each of its unread
-- targets is judged once on its own line (X|<question>|<message>), and only those clearing walk.gate are read, as
-- single-target leads. query/33's sixteen-node graph, a replay standing in for Jev, open_whole 1. Worked by hand:
--   wave 0 reads 1. Wave 1: term:ceiling (one target, 2) is opened whole and reads 2; search fills 11 and 12.
--   Wave 2: term:ladder, raised by 2, leads to 5 and 7, two unread, so it is wide. Its targets are judged: 5 at 0.9,
--   7 at 0.2. Search's next (13) is read, then one:wt/5, then search fills the wave's four (14, 15). 7 is never read.
-- Off (the default), the same walk opens ladder whole and reads 5 and 7 together.

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
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/50 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/50 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/50 fixture')
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
    insert into content.channels (name, kind, org_id, visibility) values ('walk-fixture-50', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility) values (ch, 'walk-fixture-50:replay', 'replay', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
        'term:ceiling', 0.9, 'term:hallway', 0.2, 'term:ladder', 0.9,
        'X|root|wt/5', 0.9, 'X|root|wt/7', 0.2))::text);
end $$;


select aiq.install_walk_workflow('walk_fixture_wide', 'jev', 2);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture-50:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'open_whole', 1,
                                       'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r   uuid := workflow.start_workflow('walk_fixture_wide', inp);
    got text;
begin
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish: %', (select string_agg(step_key || ' ' || status || ' ' || coalesce(error::text, ''), '; ')
                                                        from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    select string_agg(doc || '<' || via, ',' order by wave, ord) into got from aiq.walk_reads(r);
    if got is distinct from 'wt/1<search,wt/2<term:ceiling,wt/11<search,wt/12<search,wt/13<search,wt/5<one:wt/5,wt/14<search,wt/15<search' then
        raise exception 'the reads are %', got;
    end if;
    -- the single-target travel records the wide lead it came from
    if (select t->>'via' from jsonb_array_elements(aiq.walk_state(r)->'waves') w, jsonb_array_elements(w->'travels') t
         where t->>'key' = 'one:wt/5') is distinct from 'term:ladder' then
        raise exception 'one:wt/5 does not record term:ladder as the lead it came from';
    end if;
    -- off, the same walk opens ladder whole
    r := workflow.start_workflow('walk_fixture_wide', jsonb_set(inp, '{settings,open_whole}', 'null'));
    select string_agg(doc, ',' order by wave, ord) into got from aiq.walk_reads(r);
    if got not like '%wt/5,wt/7%' then
        raise exception 'with open_whole off, ladder was not opened whole: %', got;
    end if;
    raise notice 'query/50: a wide lead is opened target by target, and off it opens whole';
end $$;

rollback;
