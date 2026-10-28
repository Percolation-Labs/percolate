-- A WALK THAT LOST JEV VERDICTS ENDS FAILED (REM-1225).
--
-- A walk asks Jev about every clue a wave raises, one request per 60 clues. A request can fail for good: on 28 Oct
-- the provider account ran out of credit and every request after 14:34Z came back 402. The judge step tolerates a
-- failed request so the others land, but the walk must not then read on as if those clues had been judged: 244
-- walks lost 4,579 of their 10,112 requests that afternoon and all 244 ended succeeded. Here the same sixteen-node
-- graph as query/33 is walked with no replay, so its first wave sends real requests; this test fails them as the
-- provider did, and the walk has to stop failed, saying how many requests it lost and why.

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
end $$;

select aiq.install_walk_workflow('walk_fixture_lost', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('id', 'q1', 'text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'settings', jsonb_build_object('wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r uuid := workflow.start_workflow('walk_fixture_lost', inp);
    t record;
    asked int := 0;
    err text;
begin
    -- The first wave's requests wait for a worker; fail each one as the provider did.
    for t in select id from workflow.tasks
              where run_id = r and step_key like 'judge\_%' and matrix_parent_id is not null and status = 'ready' loop
        perform workflow.fail_task(t.id, jsonb_build_object('error',
            'http_call returned HTTP 402: the provider account has no credit left; retrying will not help'), true);
        asked := asked + 1;
    end loop;
    if asked = 0 then
        raise exception 'the walk sent no Jev request to fail, so this test proves nothing';
    end if;
    perform workflow.drain_sql_steps(r);
    if (select status from workflow.runs where id = r) is distinct from 'failed' then
        raise exception 'a walk that lost all % of its Jev requests ended %, not failed', asked,
            (select status from workflow.runs where id = r);
    end if;
    select error->>'error' into err from workflow.tasks where run_id = r and step_key like 'read%' and status = 'failed';
    if err is null or err not like format('%s of the %s Jev requests in this walk failed%%', asked, asked) then
        raise exception 'the failed read says % where it should count the % lost requests', err, asked;
    end if;
end $$;

rollback;
