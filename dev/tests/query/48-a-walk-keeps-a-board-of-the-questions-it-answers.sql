-- A WALK KEEPS A BOARD OF THE QUESTIONS IT ANSWERS (REM-1245, specs/ai-query-layer/walk.md §6-§9).
--
-- Under walk.stack the decider links reads to the questions they answer, opens a part when the root's linked reads
-- share a term, closes a question its linked reads answer, and judges each lead against the questions still open.
-- query/33's sixteen-node graph, with a replay document standing in for Jev, so the run completes inside
-- start_workflow. Worked by hand:
--   wave 0 reads 1 (search's first). Iteration 1 links 1 to the root (A|root|wt/1 0.9); one linked read shares
--     nothing, so no part is offered. The leads out of 1 are judged against the root: term:ceiling accepted.
--   wave 1 travels ceiling to 2 and fills from search (11, 12). Iteration 2 links 2 to the root; 1 and 2 share
--     'ceiling', the one term two root-linked reads hold, so S|root|ceiling is asked and opens part:ceiling. The
--     root's two lines are each judged (T|root|wt/1, T|root|wt/2): the root is a leaf until it has a part, and neither line
--     answers it. The leads out of 2 are judged against both open questions:
--     term:ladder is low for the root and high for the part, so it is accepted and serves part:ceiling.
--   wave 2 reads search's next (13), travels ladder to 5 and 7, and fills its fourth read from search (14, which the
--     replay never assessed, so it is linked to nothing). Iteration 3 links 5 and 7 to the part; 5 answers
--     the part (T|part:ceiling|wt/5), so the part closes on that one line; the root, now a parent whose only part is
--     answered, closes by structure, with no Jev call.
--   wave 3 reads nothing: the root is answered, and the walk stops `answered`.
-- What is held: the board is the fold of each wave's recorded moves; walk_stack, walk_clues' serves and
-- walk_structure read it; a verdict the replay lacks decides nothing; walk_keep makes it graph rows.

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
        ('walk_fixture', 'walk_tagged', 'walk_fixture_tag', 'query/48 fixture'),
        ('walk_fixture', 'walk_next', 'walk_fixture', 'query/48 fixture'),
        ('walk_fixture', 'walk_nearest', 'walk_fixture', 'query/48 fixture')
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
    -- The replay: every judgement the hand-worked walk needs, in the stack's keys; everything else absent.
    insert into content.channels (name, kind, org_id, visibility) values ('walk-fixture-48', 'manual', org, 'public')
    returning id into ch;
    insert into content.resources (channel_id, uri, title, org_id, visibility)
    values (ch, 'walk-fixture-48:replay', 'replay', org, 'public')
    returning id into res;
    insert into content.resource_chunks (resource_id, ordinal, content)
    values (res, 0, jsonb_build_object('model', 'stand-in', 'task', aiq.walk_task(), 'verdicts', jsonb_build_object(
        'A|root|wt/1', 0.9, 'A|root|wt/2', 0.9, 'A|root|wt/11', 0.1, 'A|root|wt/12', 0.1,
        'L|root|term:ceiling', 0.9, 'L|root|term:hallway', 0.2,
        'S|root|ceiling', 0.8, 'T|root|wt/1', 0.3, 'T|root|wt/2', 0.3,
        'L|root|term:ladder', 0.2, 'L|part:ceiling|term:ladder', 0.9,
        'A|root|wt/13', 0.1, 'A|part:ceiling|wt/13', 0.1,
        'A|root|wt/5', 0.3, 'A|part:ceiling|wt/5', 0.9, 'A|root|wt/7', 0.3, 'A|part:ceiling|wt/7', 0.9,
        'T|part:ceiling|wt/5', 0.9, 'T|part:ceiling|wt/7', 0.2))::text);
end $$;

select aiq.install_walk_workflow('walk_fixture_stack', 'jev', 6);
-- the state gate is calibrated in a deployment (F12); this walk is hand-worked against 0.7
update aiq.parameters set value = '0.7' where name = 'stack.state_gate';

do $$
declare
    inp jsonb := jsonb_build_object(
        'nodes', 'walk_fixture', 'prefix', 'wt/', 'question', jsonb_build_object('text', 'the ladder'),
        'search', to_jsonb(array['wt/1','wt/11','wt/12','wt/13','wt/14','wt/15','wt/16','wt/17','wt/18',
                                 'wt/3','wt/4','wt/6','wt/8','wt/2','wt/5','wt/7']),
        'replay', (select id from content.resources where uri = 'walk-fixture-48:replay'), 'offline', true,
        'settings', jsonb_build_object('stack', true, 'describe', 'source', 'order', 'p', 'wave', 4, 'seeds', 1, 'per_wave', 1, 'expand_all', false));
    r   uuid := workflow.start_workflow('walk_fixture_stack', inp);
    m   uuid;
    got text;
    st  jsonb;
begin
    if (select status from workflow.runs where id = r) is distinct from 'succeeded' then
        raise exception 'the stack walk did not finish in-database: %', (select string_agg(step_key || ' ' || status || ' '
            || coalesce(error::text, ''), '; ') from workflow.tasks where run_id = r and status not in ('succeeded', 'skipped'));
    end if;
    select string_agg(doc, ',' order by wave, ord) into got from aiq.walk_reads(r);
    if got is distinct from 'wt/1,wt/2,wt/11,wt/12,wt/13,wt/5,wt/7,wt/14' then
        raise exception 'the reads are % where the hand-worked walk reads 1; 2, 11, 12; 13, 5, 7, 14', got;
    end if;
    if aiq.walk_summary(r)->'stop'->>'reason' is distinct from 'answered' then
        raise exception 'the walk stopped %, where the root closes at iteration 3 and the walk stops answered',
            aiq.walk_summary(r)->'stop';
    end if;
    -- the board as each wave left it
    select string_agg(format('%s:%s=%s[%s]', wave, question, state, array_to_string(evidence, ' ')), '; '
                      order by wave, question) into got
      from aiq.walk_stack(r);
    if got is distinct from
       '0:root=open[wt/1]; 1:part:ceiling=open[]; 1:root=open[wt/1 wt/2]; '
       '2:part:ceiling=answered[wt/5 wt/7]; 2:root=answered[wt/1 wt/2]' then
        raise exception 'the board went %', got;
    end if;
    -- what closed each question: a line for the leaf, the structure for the parent
    if (select (st0->'board'->'questions'->'root'->>'closed_by') || ' ' || (st0->'board'->'questions'->'root'->'answered_by')::text
              || ' ' || (st0->'board'->'questions'->'part:ceiling'->>'closed_by') || ' ' || (st0->'board'->'questions'->'part:ceiling'->>'answer')
          from (select aiq.walk_state(r) as st0) z) is distinct from 'structure ["part:ceiling"] line wt/5' then
        raise exception 'the answers recorded are %', (select aiq.walk_state(r)->'board'->'questions');
    end if;
    if (select parent || '/' || by || '/' || opened_wave from aiq.walk_stack(r) where wave = 2 and question = 'part:ceiling')
       is distinct from 'root/decider/1' then
        raise exception 'part:ceiling was not opened by the decider under the root at wave 1';
    end if;
    -- a lead's P is its highest against an open question, and the travel records the question it served
    if (select (t->>'p')::numeric(3,1) || ' ' || (t->>'serves')
          from jsonb_array_elements(aiq.walk_state(r)->'waves') w, jsonb_array_elements(w->'travels') t
         where t->>'key' = 'term:ladder') is distinct from '0.9 part:ceiling' then
        raise exception 'term:ladder travelled as % where its P against the part (0.9) beats the root (0.2)',
            (select t from jsonb_array_elements(aiq.walk_state(r)->'waves') w, jsonb_array_elements(w->'travels') t
              where t->>'key' = 'term:ladder');
    end if;
    -- with every question answered, every lead falls away: none has an open question to take a P from
    if exists (select 1 from aiq.walk_clues(r) where p is not null) then
        raise exception 'a lead kept a P after every question it served was answered';
    end if;
    -- a verdict the replay lacks decides nothing: hallway's leads out of 1 other than term:ceiling stay unjudged
    if (select decision from aiq.walk_clues(r) where key = 'next:wt/1') is distinct from 'unjudged' then
        raise exception 'a lead the replay never judged was decided';
    end if;
    -- the structure a UI reads says the same
    st := aiq.walk_structure(r);
    if (st->'counts'->>'questions_answered')::int <> 2 or (st->'counts'->>'evidence_edges')::int <> 4
       or st->'oracle' is not null then
        raise exception 'walk_structure counts %', st->'counts';
    end if;
    if (aiq.walk_structure(r, array['wt/2', 'wt/5', 'wt/7'])->'oracle'->>'oracle')::boolean is not true then
        raise exception 'oracle mode is not marked oracle';
    end if;
    -- kept, the board is graph rows: two walk_question nodes, a part_of edge and four answers edges
    if (select count(*) from aiq.edges where provenance->>'run' = r::text and relation = 'walk_answers') <> 4
       or (select count(*) from aiq.edges where provenance->>'run' = r::text and relation = 'walk_part_of') <> 1 then
        raise exception 'the kept board is % answers edges and % part_of edges',
            (select count(*) from aiq.edges where provenance->>'run' = r::text and relation = 'walk_answers'),
            (select count(*) from aiq.edges where provenance->>'run' = r::text and relation = 'walk_part_of');
    end if;
    -- with the stack off the same input is a memoryless walk: no board moves, and no lead serves a question
    m := workflow.start_workflow('walk_fixture_stack', jsonb_set(inp, '{settings,stack}', 'false'));
    if (select status from workflow.runs where id = m) is distinct from 'succeeded'
       or exists (select 1 from aiq.walk_clues(m) where serves is not null)
       or (select count(*) from aiq.walk_stack(m)) <> 1 then
        raise exception 'a walk with the stack off kept a board';
    end if;
    -- a run is read back under the settings it started with: a default changed afterwards rewrites nothing
    got := (select string_agg(format('%s:%s=%s', wave, question, state), ';' order by wave, question) from aiq.walk_stack(r));
    update aiq.parameters set value = '"targets"' where name = 'walk.describe';
    update aiq.parameters set value = '"p"' where name = 'walk.order';
    if aiq.walk_state(r)->'settings'->>'describe' is distinct from 'source'
       or (select string_agg(format('%s:%s=%s', wave, question, state), ';' order by wave, question) from aiq.walk_stack(r))
          is distinct from got then
        raise exception 'changing a default rewrote a past run: it now reads describe %',
            aiq.walk_state(r)->'settings'->>'describe';
    end if;
    -- a parameter row the stack reads is missing: the walk fails, naming it, rather than silently linking nothing (bill)
    delete from aiq.parameters where name = 'stack.link_floor';
    m := workflow.start_workflow('walk_fixture_stack', inp);
    if (select status from workflow.runs where id = m) is distinct from 'failed'
       or not exists (select 1 from workflow.tasks where run_id = m and status = 'failed'
                                                    and error::text like '%stack.link_floor%') then
        raise exception 'a stack walk with no stack.link_floor row did not fail naming it: %',
            (select string_agg(step_key || ' ' || status || ' ' || coalesce(error::text, ''), '; ')
               from workflow.tasks where run_id = m and status not in ('succeeded', 'skipped'));
    end if;
    raise notice 'query/48: a stack walk links, opens, closes and stops answered, and its board is rows a reader queries';
end $$;

-- A walk's readers run as the signed-in caller: one whom the run's policy admits reads it, a stranger is refused.
update workflow.runs set owner_id = (select id from rbac.users order by id limit 1), visibility = 'private'
 where workflow_def_id in (select id from workflow.definitions where name = 'walk_fixture_stack');
select set_config('request.jwt.claims', json_build_object('sub', (select id from rbac.users order by id limit 1), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
begin
    if (select count(*) from aiq.walk_stack((select run from aiq.walk_runs where question_text = 'the ladder' order by created_at limit 1))) = 0 then
        raise exception 'the run''s owner, signed in, cannot read its board';
    end if;
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub": "00000000-0000-4000-8000-000000000001", "role": "authenticated"}', true);
set local role authenticated;
do $$
begin
    if exists (select 1 from aiq.walk_runs where question_text = 'the ladder') then
        raise exception 'a stranger, signed in, lists a walk that is not theirs';
    end if;
    raise notice 'query/48: a walk''s owner reads it signed in, and a stranger sees none of it';
end $$;
reset role;

rollback;
