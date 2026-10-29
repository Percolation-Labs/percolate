-- A NEAR MISS IS TRAVELLED ON ITS TURN (REM-1207).
--
-- settings.near_miss = {band, every} makes every `every`-th travel of a walk take the best rejected clue whose P is
-- in [band, gate), when one still leads somewhere unread. It is the walkthrough's step 4: a decider's no just under
-- the gate is often a yes it was not sure of. A fixed rotation, not the study's coin, so a replay reads the same
-- documents in the same order on any engine.
--
-- query/33's sixteen-node graph, with one change to the replay: 'ladder' is a near miss at 0.4, where query/33 has it
-- accepted at 0.9. Worked by hand, with {band: 0.35, every: 2}: wave 0 reads 1; wave 1 judges 1's clues and travel 0
-- takes 'ceiling' to 2, then search fills 11 and 12; wave 2 reads 13 from search, and travel 1 is the near miss's
-- turn: 'ladder' takes the walk to 5 and 7. The same seven reads query/33 makes with ladder accepted. With the setting
-- off, ladder is rejected and never travelled, so 5 and 7 are not among those reads.

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

select aiq.install_walk_workflow('walk_fixture_run', 'jev', 3);

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', false, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r     uuid;
    reads text[];
    got   text;
begin
    -- On: the second travel is the near miss's turn.
    r := workflow.start_workflow('walk_fixture_run',
             jsonb_set(inp, '{settings,near_miss}', '{"band": 0.35, "every": 2}'));
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the walk did not finish: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    select array_agg(doc order by wave, ord) into reads from aiq.walk_reads(r);
    if reads[1:7] is distinct from array['wt/1','wt/2','wt/11','wt/12','wt/13','wt/5','wt/7'] then
        raise exception 'with near misses the reads are % where the hand-worked walk reads 1; 2, 11, 12; 13, 5, 7', reads;
    end if;
    select string_agg(key || '=' || decision || '/' || state, ',' order by key) into got
      from aiq.walk_clues(r) where key in ('term:ceiling', 'term:ladder', 'term:hallway');
    if got is distinct from 'term:ceiling=accepted/travelled,term:hallway=rejected/rejected,term:ladder=rejected/travelled' then
        raise exception 'the clues'' fate with near misses is %', got;
    end if;
    -- the travel says it was a near miss; hallway, at 0.2, is under the band and never one
    if not exists (select 1 from jsonb_array_elements(aiq.walk_state(r)->'waves') w,
                                 jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) t
                    where t->>'key' = 'term:ladder' and (t->>'near_miss')::boolean) then
        raise exception 'the travel by ladder is not marked as a near miss';
    end if;

    -- Off: ladder is a plain rejection, and no travel carries the mark.
    r := workflow.start_workflow('walk_fixture_run', inp);
    select array_agg(doc order by wave, ord) into reads from aiq.walk_reads(r);
    if reads[1:7] && array['wt/5','wt/7'] then
        raise exception 'with the setting off a rejected clue was travelled: %', reads;
    end if;
    if (select state from aiq.walk_clues(r) where key = 'term:ladder') is distinct from 'rejected' then
        raise exception 'with the setting off ladder is %', (select state from aiq.walk_clues(r) where key = 'term:ladder');
    end if;
    if exists (select 1 from jsonb_array_elements(aiq.walk_state(r)->'waves') w,
                             jsonb_array_elements(coalesce(w->'travels', '[]'::jsonb)) t where t ? 'near_miss') then
        raise exception 'with the setting off a travel carries a near_miss mark';
    end if;
    raise notice 'query/36: a near miss is travelled on its turn, and never with the setting off';
end $$;

rollback;
