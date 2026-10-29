-- A CLUE CAN BE DESCRIBED BY WHAT ITS TARGETS SAY (REM-1240). walk.describe = lines shows the decider what the user
-- said in up to three of a clue's targets, read from what is stored, and a term's count of messages. One function
-- makes every description, and aiq.walk_clue_text hands a re-judge the walk's own words. What is held:
--   1. under lines, every clue still to be judged quotes its targets' own lines and never its source's;
--   2. aiq.walk_clue_text gives exactly the text the walk showed, under source, targets and lines;
--   3. a source walk's clue, re-described as lines, reads as a lines walk showed it;
--   4. a term says how many messages hold it;
--   5. lines asks in its own wording, so a replay given under another is refused, and a clue the run never raised
--      is an error, not null;
--   6. a channel's documents are described by their stored terms_text, and one in another sitting by days apart.
-- One transaction, rolled back.

\set ON_ERROR_STOP on

begin;

create temp table fx(n int, sitting text, pos int, said text, terms text[], near int[]);
insert into fx values
 (1,'a',0,'I need a ladder for the hallway ceiling','{room,ladder}','{2}'),
 (2,'a',1,'Which paint suits a damp room?','{room,paint}','{1}'),
 (3,'a',2,'Should I prime the room before painting?','{room,paint,primer}','{4}'),
 (4,'a',3,'I rented a ladder from the hire shop on Friday','{ladder,rental}','{3}'),
 (11,'b',0,'How long does risotto take?','{risotto}','{12}'),
 (12,'b',1,'Can I use stock cubes?','{stock}','{11}');

do $$
declare
    org uuid := (select id from rbac.orgs order by id limit 1);
    ch  uuid;
    res uuid;
    w   text;
begin
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select 'walk_lines', gen_random_uuid(), org, 'public', said from fx;
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select n.id, 'walk_lines', 'wl/' || fx.n, 'canonical', org
      from fx join aiq.nodes n on n.entity_type = 'walk_lines' and n.summary = fx.said;
    insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
    select distinct 'walk_lines_tag', gen_random_uuid(), org, 'public', t from fx, unnest(terms) t;
    insert into aiq.relation_types (src_type, relation, dst_type, description) values
        ('walk_lines', 'walk_tagged', 'walk_lines_tag', 'query/47 fixture'),
        ('walk_lines', 'walk_next', 'walk_lines', 'query/47 fixture'),
        ('walk_lines', 'walk_nearest', 'walk_lines', 'query/47 fixture')
    on conflict do nothing;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select i.id, tg.id, 'walk_tagged', org, '{}'
      from fx join aiq.nodes i on i.entity_type = 'walk_lines' and i.summary = fx.said
      cross join unnest(fx.terms) t
      join aiq.nodes tg on tg.entity_type = 'walk_lines_tag' and tg.summary = t;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_next', org, jsonb_build_object('sitting', x.sitting, 'pos', x.pos)
      from fx x join fx y on y.sitting = x.sitting and y.pos = x.pos + 1
      join aiq.nodes a on a.entity_type = 'walk_lines' and a.summary = x.said
      join aiq.nodes b on b.entity_type = 'walk_lines' and b.summary = y.said;
    insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
    select a.id, b.id, 'walk_nearest', org, jsonb_build_object('rank', 0)
      from fx cross join unnest(fx.near) m
      join aiq.nodes a on a.entity_type = 'walk_lines' and a.summary = fx.said
      join aiq.nodes b on b.entity_type = 'walk_lines' and b.summary = (select said from fx f where f.n = m);
    insert into content.channels (name, kind, org_id, visibility) values ('walk-lines', 'manual', org, 'public')
    returning id into ch;
    -- One replay per wording, each liking ladder, so every walk reads the same messages.
    foreach w in array array['source', 'targets', 'lines'] loop
        insert into content.resources (channel_id, uri, title, org_id, visibility)
        values (ch, 'walk-lines:' || w, 'replay', org, 'public') returning id into res;
        insert into content.resource_chunks (resource_id, ordinal, content)
        values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(w),
                                           'verdicts', jsonb_build_object('term:ladder', 0.9))::text);
    end loop;
end $$;

-- One wave, so the clues its reads raise are still waiting, with their descriptions, when the walk stops.
select aiq.install_walk_workflow('walk_lines_1', 'jev', 1);

do $$
declare
    base jsonb := jsonb_build_object(
        'nodes', 'walk_lines', 'prefix', 'wl/',
        'question', jsonb_build_object('node_id', (select n.id from aiq.nodes n join aiq.node_keys k on k.node_id = n.id
                                                    where k.key = 'wl/1'),
                                       'text', 'Did I rent a ladder?'),
        'search', to_jsonb(array['wl/1','wl/11','wl/12','wl/2','wl/3','wl/4']), 'offline', true,
        'settings', jsonb_build_object('wave', 2, 'seeds', 1, 'per_wave', 1));
    runs jsonb := '{}'::jsonb;
    w    text;
    r    uuid;
    st   jsonb;
    bad  text;
begin
    foreach w in array array['source', 'targets', 'lines'] loop
        r := workflow.start_workflow('walk_lines_1',
                 jsonb_set(jsonb_set(base, '{settings,describe}', to_jsonb(w)), '{replay}',
                           to_jsonb((select id from content.resources where uri = 'walk-lines:' || w))));
        if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
            raise exception 'the % walk did not finish: %', w, (select string_agg(step_key || ' ' || status || ' '
                || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
        end if;
        runs := runs || jsonb_build_object(w, r);
    end loop;

    -- 1. Under lines, every clue quotes what its targets say, and none quotes its source.
    st := aiq.walk_state((runs->>'lines')::uuid);
    if (select count(*) from jsonb_object_keys(st->'next')) = 0 then
        raise exception 'the lines walk raised no clue to describe';
    end if;
    select string_agg(key || ' = ' || coalesce(value->>'text', 'null'), '; ') into bad
      from jsonb_each(st->'next')
     where value->>'text' is null or value->>'text' not like '%What the user said in them: "%'
        or value->>'text' like '%this read one%' or value->>'text' like '%key terms%';
    if bad is not null then
        raise exception 'under lines a clue was not described by what its targets say: %', bad;
    end if;
    -- The walk read the hire-shop message (place 3); its next clue leads back to the paint question, two exchanges
    -- earlier in the same sitting.
    if not exists (select 1 from jsonb_each(st->'next')
                    where value->>'text' like '%"Which paint suits a damp room?" (same sitting, 2 exchange(s) earlier)%') then
        raise exception 'a lines clue did not say what its target said and where it sits: %', st->'next';
    end if;

    -- 2. The clue text function gives the walk's own words, under every description.
    foreach w in array array['source', 'targets', 'lines'] loop
        st := aiq.walk_state((runs->>w)::uuid);
        select string_agg(key, ', ') into bad
          from jsonb_each(st->'next')
         where aiq.walk_clue_text((runs->>w)::uuid, key) is distinct from value->>'text';
        if bad is not null then
            raise exception 'under % aiq.walk_clue_text differed from what the walk showed for: %', w, bad;
        end if;
    end loop;

    -- 3. A source walk's clue, re-described as lines, reads as the lines walk showed it.
    select string_agg(key, ', ') into bad
      from jsonb_each(aiq.walk_state((runs->>'lines')::uuid)->'next')
     where aiq.walk_clue_text((runs->>'source')::uuid, key, 'lines') is distinct from value->>'text';
    if bad is not null then
        raise exception 'a source clue re-described as lines read differently from the lines walk: %', bad;
    end if;

    -- 4. A term says how many messages hold it: room is held by three, two of them unread from the ladder message.
    bad := aiq.walk_describe_clue(base, aiq.walk_graph(base), 'lines', 'term:room', 'term', 'room', 'wl/1', '["wl/2","wl/3"]');
    if bad not like 'the term ''room'', held by 3 message(s) in all, 2 of them unread. What the user said in them: %'
       or bad not like '%"Which paint suits a damp room?" (same sitting, 1 exchange(s) later)%' then
        raise exception 'a term did not say how many messages hold it, or where its targets sit: %', bad;
    end if;

    -- 5. Its own wording: a targets-worded replay cannot answer a lines walk; an unknown clue is an error.
    if aiq.walk_task('lines') in (aiq.walk_task('source'), aiq.walk_task('targets')) then
        raise exception 'lines shares a wording with another description';
    end if;
    begin
        r := workflow.start_workflow('walk_lines_1',
                 jsonb_set(jsonb_set(base, '{settings,describe}', '"lines"'), '{replay}',
                           to_jsonb((select id from content.resources where uri = 'walk-lines:targets'))));
        perform aiq.walk_state(r);
        raise exception 'a targets-worded replay answered a lines walk';
    exception when invalid_parameter_value then
        null;
    end;
    begin
        perform aiq.walk_clue_text((runs->>'lines')::uuid, 'term:nothing-raised-this');
        raise exception 'a clue the run never raised was described';
    exception when no_data_found then
        null;
    end;
    -- 6. A channel's documents: the user's stored line, and days apart across sittings (said_at).
    declare
        org uuid := (select id from rbac.orgs order by id limit 1);
        ch  uuid;
        txt text;
    begin
        insert into content.channels (name, kind, org_id, visibility) values ('walk-lines-ch', 'manual', org, 'public')
        returning id into ch;
        insert into content.resources (channel_id, uri, title, org_id, visibility, metadata)
        select ch, 'wlc/' || x.i, 'wlc', org, 'public',
               jsonb_build_object('terms_text', x.said, 'said_at', x.at, 'sitting', x.sit, 'position', x.pos)
          from (values (1, 'I booked the van for Saturday', '2024-03-01T10:00:00Z', 's1', 0),
                       (2, 'The van holds six boxes', '2024-03-01T10:05:00Z', 's1', 1),
                       (3, 'The van was late by an hour', '2024-03-04T09:00:00Z', 's2', 0)) x(i, said, at, sit, pos);
        insert into aiq.nodes (entity_type, entity_id, org_id, visibility, summary)
        select 'document', r.id, org, 'public', r.uri from content.resources r where r.channel_id = ch;
        insert into aiq.relation_types (src_type, relation, dst_type, description)
        values ('document', 'walk_next', 'document', 'query/47 fixture') on conflict do nothing;
        insert into aiq.edges (src_id, dst_id, relation, org_id, provenance)
        select a.id, b.id, 'walk_next', org, '{"sitting": "s1", "pos": 0}'
          from aiq.nodes a, aiq.nodes b, content.resources ra, content.resources rb
         where a.entity_id = ra.id and b.entity_id = rb.id and ra.uri = 'wlc/1' and rb.uri = 'wlc/2';
        txt := aiq.walk_describe_clue(jsonb_build_object('channel', 'walk-lines-ch'), '{}'::jsonb, 'lines', 'next:wlc/1',
                                      'near', 'wlc/1', 'wlc/1', '["wlc/2","wlc/3"]');
        if txt not like '%"The van holds six boxes" (same sitting, 1 exchange(s) later)%'
           or txt not like '%"The van was late by an hour" (another sitting, 3 day(s) later)%' then
            raise exception 'a channel''s documents were not described by their stored lines and distance: %', txt;
        end if;
    end;
    raise notice 'query/47: a clue can be described by what its targets say, in the walk''s own words';
end $$;

rollback;
