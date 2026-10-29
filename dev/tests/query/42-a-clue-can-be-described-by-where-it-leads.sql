-- A CLUE CAN BE DESCRIBED BY WHERE IT LEADS (REM-1204). walk.describe = source shows the decider the read message a
-- clue comes out of; targets shows its kind, how many unread messages it reaches and the rarest stored terms of up to
-- three of them, and reads no target. What is held:
--   1. under targets, every clue the walk raises is described by its targets' terms, never by its source's text,
--      and a term's sign lists the target's rarest term first;
--   2. each description asks in its own wording, so a replay given under the other one is refused, not mixed;
--   3. the sign is the same every time for the same clue;
--   4. a description that is neither source nor targets is refused.
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fx(n int, sitting text, pos int, terms text[], near int[]);
insert into fx values
 (1,'a',0,'{room,ladder}','{2}'), (2,'a',1,'{room,paint}','{1}'), (3,'a',2,'{room,paint,primer}','{4}'),
 (4,'a',3,'{ladder,rental}','{3}'), (11,'b',0,'{risotto}','{12}'), (12,'b',1,'{stock}','{11}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_desc', gen_random_uuid(), org, 'public', 'wd/' || n from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select id, 'walk_desc', summary, 'canonical', org from aiq.nodes where entity_type = 'walk_desc';
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_desc_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_desc', 'walk_tagged', 'walk_desc_tag', 'query/42 fixture'),
        ('walk_desc', 'walk_next', 'walk_desc', 'query/42 fixture'),
        ('walk_desc', 'walk_nearest', 'walk_desc', 'query/42 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_desc' and i.summary = 'wd/' || fx.n
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_desc_tag' and tg.summary = t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org, jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
      from fx x join fx y on y.sitting = x.sitting and y.pos = x.pos + 1
      join aiq.nodes a on a.entity_type = 'walk_desc' and a.summary = 'wd/' || x.n
      join aiq.nodes b on b.entity_type = 'walk_desc' and b.summary = 'wd/' || y.n;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', 0)
      from fx cross join unnest(fx.near) m
      join aiq.nodes a on a.entity_type = 'walk_desc' and a.summary = 'wd/' || fx.n
      join aiq.nodes b on b.entity_type = 'walk_desc' and b.summary = 'wd/' || m;
    insert into content.channels (name, kind, org_id, visibility) values ('walk-desc', 'manual', org, 'public')
    returning id into ch;
    -- Two replays, one per wording, both liking ladder.
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-desc:source', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task('source'),
                                       'verdicts', jsonb_build_object('term:ladder', 0.9))::text);
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-desc:targets', 'replay', org, 'public') returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task('targets'),
                                       'verdicts', jsonb_build_object('term:ladder', 0.9))::text);
end $$;

-- One wave, so the clues its reads raise are still waiting, with their descriptions, when the walk stops.
select aiq.install_walk_workflow('walk_desc_1', 'jev', 1);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_desc', 'prefix', 'wd/',
        'question', jsonb_build_object('node_id', (select id from aiq.nodes where entity_type = 'walk_desc' and summary = 'wd/1'),
                                       'text', 'Did I rent a ladder?'),
        'search', to_jsonb(array['wd/1','wd/11','wd/12','wd/2','wd/3','wd/4']),
        'replay', (select id from content.resources where uri = 'walk-desc:targets'), 'offline', true,
        'settings', jsonb_build_object('wave', 2, 'seeds', 1, 'per_wave', 1, 'describe', 'targets'));
    src uuid := (select id from content.resources where uri = 'walk-desc:source');
    r uuid;
    st jsonb;
    bad text;
    sign1 text;
begin
    -- 1. Under targets, every clue still to be judged is described by its targets, and none quotes its source.
    r := workflow.start_workflow('walk_desc_1', inp);
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the targets walk did not finish: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    st := aiq.walk_state(r);
    select string_agg(key || ' = ' || coalesce(value->>'text', 'null'), '; ') into bad
      from jsonb_each(st->'next')
     where value->>'text' is null or value->>'text' not like '%Their own key terms: %' or value->>'text' like '%this read one%';
    if bad is not null or (select count(*) from jsonb_object_keys(st->'next')) = 0 then
        raise exception 'under targets a clue was not described by its targets: %', coalesce(bad, 'no clue raised');
    end if;
    -- A sign lists the rarest term first: wd/4 holds ladder (2 documents) and rental (1), so rental leads.
    if aiq.walk_signs(aiq.walk_graph(inp), 'term:ladder', '["wd/4"]') <> 'rental, ladder' then
        raise exception 'a sign did not list its target''s rarest terms first: %',
            aiq.walk_signs(aiq.walk_graph(inp), 'term:ladder', '["wd/4"]');
    end if;
    -- 3. The same clue shows the same sign every time.
    sign1 := aiq.walk_signs(aiq.walk_graph(inp), 'term:room', '["wd/1","wd/2","wd/3","wd/4"]');
    if sign1 is distinct from aiq.walk_signs(aiq.walk_graph(inp), 'term:room', '["wd/4","wd/3","wd/2","wd/1"]') then
        raise exception 'the same clue showed two signs: %', sign1;
    end if;
    -- 2. A replay given under the source wording cannot answer a targets walk.
    begin
        r := workflow.start_workflow('walk_desc_1', jsonb_set(inp, '{replay}', to_jsonb(src)));
        perform aiq.walk_state(r);
        raise exception 'a source-worded replay answered a targets walk';
    exception when invalid_parameter_value then
        null;
    end;
    -- and the source walk still quotes its source.
    r := workflow.start_workflow('walk_desc_1', jsonb_set(jsonb_set(inp, '{replay}', to_jsonb(src)),
                                                          '{settings,describe}', '"source"'));
    if not exists (select 1 from jsonb_each(aiq.walk_state(r)->'next') where value->>'text' like '%this read one%') then
        raise exception 'under source no clue quoted its source: %', aiq.walk_state(r)->'next';
    end if;
    -- 4. Neither source nor targets is refused.
    begin
        perform aiq.walk_task('summaries');
        raise exception 'walk.describe = summaries was accepted';
    exception when invalid_parameter_value then
        null;
    end;
    raise notice 'query/42: a clue can be described by where it leads, in its own wording, the same way every time';
end $$;

rollback;
