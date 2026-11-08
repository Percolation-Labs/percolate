-- THE CONFIGURED DECIDER JUDGES THROUGH THE JUDGE'S OWN CALLS (P8_DECIDER).
--
-- percolate.decider names the claims.deciders row a deployment decides with, and when it is set, dream hands each
-- person's open bind cases to it: one run per subject owner, started by the platform for them, whose requests the
-- worker posts and whose answers land through claim_judgement and complete_judgement at tier decision_model. Here
-- the worker is stood in for by completing the requests by hand, as query/43 does. The checks:
--   1. the setting picks the default decider, and unset it is jev; the stand-in row ships;
--   2. judge_with_decider starts one run for the owner, as the platform, with one request per open case, each a
--      Jev request (a state and one choice) addressed to the decider's endpoint;
--   3. an answer at or above the bar binds, recorded decision_model:<owner> with the model's probabilities as the
--      reason; its twin goes moot and is passed over; one below the bar goes to the person; a request that failed
--      (Jev's 402) leaves its case open with nothing written;
--   4. the landing is nobody's to call, and a workflow step acting for a person (api_viewer) meets the guard, so
--      it cannot write a verdict onto a judgement it does not hold.
-- One transaction, rolled back.

\set ON_ERROR_STOP on
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
    if p_ok is not true then
        raise exception 'decider: %', p_what;
    end if;
end $$;

-- 1. The setting, and the rows.
select pg_temp.check(claims.default_decider() = coalesce(nullif(current_setting('percolate.decider', true), ''), 'jev'),
    '1. default_decider does not read percolate.decider');
set local percolate.decider = '';
select pg_temp.check(claims.default_decider() = 'jev', '1. unset, the default decider is not jev');
set local percolate.decider = 'standin';
select pg_temp.check(claims.default_decider() = 'standin', '1. the setting does not pick the decider');
select pg_temp.check(exists (select 1 from claims.deciders where name = 'standin' and endpoint like 'http://host.docker.internal:%'),
    '1. the stand-in row does not ship');

-- Ana Lima and A. Lima at Tagus Q72, as the Zep tour has them: four cases, two twins each.
select aiq.upsert_graph('{"nodes":[{"k":"person","n":"Ana Lima Q72"},{"k":"company","n":"Tagus Q72"},
  {"k":"person","n":"A. Lima Q72"},{"k":"organization","n":"Tagus Q72"}],
  "edges":[{"s":0,"t":1,"r":"affiliated_with"},{"s":2,"t":3,"r":"affiliated_with"}]}', '{"agent":"knit","run_id":"q72"}');
-- Hers: the cases are seen through their subjects, and a run is its subject's owner's.
update aiq.nodes n set owner_id = '11111111-1111-1111-1111-111111111111', visibility = 'private'
  from aiq.soft_nodes s where n.entity_type = 'soft' and n.entity_id = s.id and s.key like '%q72';
set local percolate.decider = '';
select aiq.dream() as dreamt \gset
select pg_temp.check((select count(*) from aiq.judgements where evidence->>'key' like '%q72' and status = 'open') = 4,
    '2. dream did not queue the four cases: ' || :'dreamt');

-- 2. One run, as the platform for her.
select aiq.judge_with_decider('standin') as started \gset
select (:'started'::jsonb->'runs'->0->>'run') as run \gset
select pg_temp.check((select owner_id = '11111111-1111-1111-1111-111111111111' and started_actor = 'platform'
                        from workflow.runs where id = :'run'::uuid),
    '2. the run is not the owner''s, started by the platform: ' || :'started');
select pg_temp.check((select count(*) from workflow.tasks where run_id = :'run'::uuid and matrix_parent_id is not null
                        and input->>'url' = (select endpoint from claims.deciders where name = 'standin')
                        and input->'item'->'body'->'questions'->'same'->>'type' = 'choice'
                        and input->'item'->'body'->'state'->>'name' like '%Q72') = 4,
    '2. there is not one Jev request per case, addressed to the stand-in');
select pg_temp.check((select count(*) from jsonb_array_elements(:'started'::jsonb->'runs')) = 1
                     and (aiq.judge_with_decider('standin')->'runs') = '[]'::jsonb,
    '2. a second call started another run while the first was asking');

-- 3. Answer as the stand-in would: Tagus (company) sure, its twin sure too, A. Lima unsure; Ana Lima's request
--    fails as Jev's did with no credit.
select set_config('q72.run', :'run', true);
do $$
declare
    t record;
    ans jsonb;
begin
    for t in select id, input->'item'->>'label' as label
               from workflow.tasks
              where run_id = current_setting('q72.run')::uuid and matrix_parent_id is not null and status = 'ready'
    loop
        if t.label = 'Ana Lima Q72' then
            perform workflow.fail_task(t.id, jsonb_build_object('error',
                'http_call returned HTTP 402: the provider account has no credit left; retrying will not help'), true);
            continue;
        end if;
        ans := case when t.label = 'Tagus Q72'
                    then '{"c1": 0.95, "none_of_these": 0.03, "cannot_tell": 0.02}'
                    else '{"c1": 0.6, "none_of_these": 0.1, "cannot_tell": 0.3}' end;
        perform workflow.complete_task(t.id, jsonb_build_object('status', 200, 'result', jsonb_build_object(
            'model', 'standin/test', 'answers', jsonb_build_object('same', jsonb_build_object(
                'type', 'choice', 'choice', 'c1', 'probabilities', ans)))));
    end loop;
    perform workflow.drain_sql_steps(current_setting('q72.run')::uuid);
end $$;

select output->'result' as landed from workflow.tasks where run_id = :'run'::uuid and step_key = 'land' \gset
select pg_temp.check((:'landed'::jsonb->>'decided')::int = 1 and (:'landed'::jsonb->>'to_human')::int = 1
                     and (:'landed'::jsonb->>'left_open')::int = 1 and (:'landed'::jsonb->>'passed_over')::int = 1,
    '3. the landing did not decide one, pass one to her, leave one open and pass over the moot twin: ' || :'landed');
select pg_temp.check(exists (select 1 from aiq.judgements
                              where evidence->>'key' = 'tagus q72' and status = 'decided' and verdict->>'decision' = 'bind'
                                and tier = 'decision_model'
                                and decided_by = 'decision_model:11111111-1111-1111-1111-111111111111'
                                and reason like 'standin/test chose Tagus Q72 with P 0.95%'),
    '3. the sure answer did not bind as the model, for her, with its probabilities as the reason');
select pg_temp.check(exists (select 1 from aiq.judgements
                              where evidence->>'key' = 'a. lima q72' and status = 'to_human' and verdict is null),
    '3. the unsure answer did not go to the person with nothing decided');
select pg_temp.check(exists (select 1 from aiq.judgements
                              where evidence->>'key' = 'ana lima q72' and status = 'open' and verdict is null
                                and claimed_by is null),
    '3. the failed request did not leave its case open with nothing written');

-- 4. Nobody calls the landing, and a step acting for a person meets the guard.
select pg_temp.check(not has_function_privilege('authenticated', 'aiq.land_decider_judgements(uuid,text,real)', 'execute')
                     and not has_function_privilege('authenticated', 'aiq.judge_with_decider(text)', 'execute'),
    '4. a signed-in caller may call the landing or start the decider''s runs');
select id as open_j from aiq.judgements where evidence->>'key' = 'ana lima q72' \gset
select set_config('q72.open', :'open_j', true);
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111","role":"authenticated"}';
set local role api_viewer;
do $$
declare v_failed boolean := false;
begin
    begin
        update aiq.judgements set status = 'decided', verdict = '{"decision":"none"}', reason = 'forged',
               tier = 'decision_model' where id = current_setting('q72.open')::uuid;
    exception when others then
        v_failed := true;
    end;
    perform pg_temp.check(v_failed, '4. a workflow step''s role wrote a verdict onto a judgement it did not hold');
end $$;
reset role;

rollback;
