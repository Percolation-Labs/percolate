-- Walkthrough step 3 without a model (REM-1206): an answer behind an open lead ranked too low, with a near miss
-- beside it, explained by aiq.walk_why from the run's own rows.
--
-- The article walks BEAM's ladder question (dev/examples/muddling-through/blocks/30). BEAM's text stays out of the
-- tests, so this is a hand-made conversation with the same shape: the seed raises 'ladder' beside two leads the
-- replay likes a little more, each of those raises another, and the two messages that answer the question are
-- reachable only through 'ladder', or through 'moving', which the third message raises and the replay rejects just
-- under the gate. Worked by
-- hand, with three reads a wave and one seed: wave 0 reads 1; wave 1 travels budget (2) and drill (3) and fills
-- from search; wave 2 travels checklist (4) and safety (5) and fills; ladder (0.57) is still open at the stop.

\set ON_ERROR_STOP on

begin;

create temp table fx(n int, sitting text, pos int, terms text[], near int[]);
insert into fx values
 (1,'a',0,'{ladder,budget,drill}','{2}'), (2,'a',1,'{budget,checklist}','{1}'), (3,'a',2,'{drill,safety,moving}','{2}'),
 (4,'a',3,'{checklist,spent}','{3}'), (5,'a',4,'{safety,precautions}','{4}'), (6,'a',5,'{spent,precautions}','{5}'),
 (7,'a',6,'{ladder,moving}','{6}'), (8,'a',7,'{ladder,moving}','{7}'),
 (11,'b',0,'{risotto}','{12}'), (12,'b',1,'{stock}','{11}'), (13,'b',2,'{parmesan}','{12}'), (14,'b',3,'{bowls}','{13}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_miss', gen_random_uuid(), org, 'public', 'wm/' || n from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_miss', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_miss';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_miss_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_miss', 'walk_tagged', 'walk_miss_tag', 'query/35 fixture'),
        ('walk_miss', 'walk_next', 'walk_miss', 'query/35 fixture'),
        ('walk_miss', 'walk_nearest', 'walk_miss', 'query/35 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_miss' and i.summary = 'wm/' || fx.n
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_miss_tag' and tg.summary = t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org, jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
      from fx x join fx y on y.sitting = x.sitting and y.pos = x.pos + 1
      join aiq.nodes a on a.entity_type = 'walk_miss' and a.summary = 'wm/' || x.n
      join aiq.nodes b on b.entity_type = 'walk_miss' and b.summary = 'wm/' || y.n;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', 0)
      from fx cross join unnest(fx.near) m
      join aiq.nodes a on a.entity_type = 'walk_miss' and a.summary = 'wm/' || fx.n
      join aiq.nodes b on b.entity_type = 'walk_miss' and b.summary = 'wm/' || m;
    -- The replay: the project's terms accepted, ladder a little below the rest, moving just under the gate; every
    -- other lead rejected.
    insert into content.channels (name, kind, org_id, visibility) values ('walk-miss', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-miss:replay', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    select res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object('term:budget', 0.6, 'term:drill', 0.6, 'term:checklist', 0.59, 'term:safety', 0.59,
                                'term:spent', 0.58, 'term:precautions', 0.58, 'term:ladder', 0.57, 'term:moving', 0.42)
             || (select jsonb_object_agg(k, 0.2) from fx, lateral (values ('next:wm/' || n), ('near:wm/' || n)) v(k))
             || (select jsonb_object_agg('term:' || t, 0.2) from fx, unnest(terms) t
                  where t in ('risotto', 'stock', 'parmesan', 'bowls', 'vanity')))::text;
end $$;

select aiq.install_walk_workflow('walk_miss_2', 'jev', 2), aiq.install_walk_workflow('walk_miss_3', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_miss', 'prefix', 'wm/',
        'question', jsonb_build_object('text', 'How should I sequence my budget, tools and ladder?'),
        'search', to_jsonb(array['wm/1','wm/11','wm/12','wm/13','wm/14','wm/2','wm/3','wm/4','wm/5','wm/6','wm/7','wm/8']),
        'replay', (select id from content.resources where uri = 'walk-miss:replay'), 'offline', true,
        'settings', jsonb_build_object('wave', 3, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r uuid;
    got text;
begin
    -- Two waves: ladder is accepted and still open at the stop, behind leads Jev liked more.
    r := workflow.start_workflow('walk_miss_2', inp);
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish in-database: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    if exists (select 1 from aiq.walk_reads(r) where doc in ('wm/7', 'wm/8')) then
        raise exception 'the evidence was read, so there is no miss to explain: %',
            (select array_agg(doc order by wave, ord) from aiq.walk_reads(r));
    end if;
    select string_agg(doc || ' ' || letter || ' ' || reason || ' ' || key || ' ' || p, '; ' order by doc) into got
      from aiq.walk_why(r, array['wm/7', 'wm/8']);
    if got is distinct from 'wm/7 c open term:ladder 0.57; wm/8 c open term:ladder 0.57' then
        raise exception 'walk_why says % where the answer sits behind the open lead ladder', got;
    end if;
    if (select state from aiq.walk_clues(r) where key = 'term:moving') is distinct from 'rejected' then
        raise exception 'the near miss moving is %', (select state from aiq.walk_clues(r) where key = 'term:moving');
    end if;
    -- Ranked too low, not wrong: with one more wave the same lead is travelled and the answer is read.
    r := workflow.start_workflow('walk_miss_3', inp);
    if (select state from aiq.walk_clues(r) where key = 'term:ladder') is distinct from 'travelled'
       or not exists (select 1 from aiq.walk_reads(r) where doc in ('wm/7', 'wm/8')) then
        raise exception 'a third wave did not travel ladder: %', (select array_agg(doc order by wave, ord) from aiq.walk_reads(r));
    end if;
    raise notice 'query/35: the answer behind an open lead ranked too low, with a near miss beside it';
end $$;

rollback;
