-- A STEP NOBODY HAS RUN IS ESTIMATED FROM ITS SHAPE, AND A MODEL STEP BY A DRY RUN (REM-1125, part 2).
--
--   1. a step that spends no model tokens is estimated from the plan: one task, no tokens;
--   2. a matrix fans out to its declared bound (dry_run_bound), never to what a stand-in returned;
--      the engine refuses a matrix with no bound, so a plan cannot fan out without one;
--   3. the model steps go to a shadow run of a generated definition: only those steps, each
--      call flagged dry_run with tools off, upstream results replaced by a placeholder, the
--      shadow run itself unestimated;
--   3b. a shadow task is claimed only by a worker that declares the dry_run capability;
--   4. when the shadow run ends, its spend lands in the original run's estimate, times each
--      step's fan-out.
--
-- One transaction, rolled back. The shadow run's tasks are completed by hand, as the runtime
-- would complete them on its stand-in model.

\set ON_ERROR_STOP on

begin;

insert into workflow.definitions (name, spec) values ('t_dry_1125', $j${"steps":[
  {"key":"fetch","kind":"work","queue":"t-dry-1125"},
  {"key":"ask","kind":"http_call","queue":"t-dry-http","depends_on":["fetch"],
   "input":{"url":"{{env.P8_AGENT_URL}}/v1/chat/completions","method":"POST",
            "body":{"model":"reader","messages":[{"role":"user","content":"Read {{steps.fetch.result}}"}]}}},
  {"key":"fan","kind":"matrix","queue":"t-dry-1125","depends_on":["fetch"],
   "input":{"items":"{{steps.fetch.result}}","max_fanout":5,
            "template":{"kind":"http_call","queue":"t-dry-http",
                        "input":{"url":"{{env.P8_AGENT_URL}}/v1/chat/completions","method":"POST",
                                 "body":{"model":"reader","messages":[{"role":"user","content":"one"}]}}}}},
  {"key":"wide","kind":"matrix","queue":"t-dry-1125","depends_on":["fetch"],
   "input":{"items":"{{steps.fetch.result}}","max_fanout":100,"template":{"kind":"work","queue":"t-dry-1125"}}}
]}$j$);

create temp table dry_ids (k text primary key, v uuid);

-- A dry run starts only for a run a policy holds until it is estimated. REM-1126 owns that hold; this file
-- stands one in, for this transaction: every run is created held.
alter table workflow.runs add column if not exists hold text;
create function pg_temp.hold_new_runs() returns trigger language plpgsql as $$
begin
    if nullif(current_setting('workflow.starting_dry_run', true), '') is null then
        new.hold := 'awaiting_estimate';
    end if;
    return new;
end $$;
create trigger trg_zz_test_hold before insert on workflow.runs for each row execute function pg_temp.hold_new_runs();

do $$
declare
    v_run uuid := workflow.start_workflow('t_dry_1125', '{}'::jsonb);
    v_shadow uuid;
    e jsonb;
    spec jsonb;
begin
    insert into dry_ids values ('run', v_run);
    select jsonb_object_agg(step_key, to_jsonb(r) - 'run_id') into e from workflow.run_estimates r
     where run_id = v_run and step_key is not null;

    -- 1. Shape, with no tokens.
    if (e->'fetch'->>'basis', (e->'fetch'->>'est_tasks')::int, (e->'fetch'->>'est_input_tokens')::int)
       is distinct from ('dry_run'::text, 1, 0) then
        raise exception 'a step with no model is estimated from the plan: %', e->'fetch';
    end if;
    -- 2. A bound is the fan-out; no bound is a floor.
    if (e->'wide'->>'basis', (e->'wide'->>'est_tasks')::int) is distinct from ('dry_run_bound'::text, 100) then
        raise exception 'a matrix with no model fans out to its declared bound: %', e->'wide';
    end if;
    if (e->'fan'->>'basis', (e->'fan'->>'est_tasks')::int) is distinct from ('none'::text, 5) then
        raise exception 'a bounded model matrix waits for the dry run at its bound: %', e->'fan';
    end if;

    -- 3. The shadow run: only the model steps, flagged, with placeholders, and not estimated itself.
    select shadow_run_id into v_shadow from workflow.dry_runs where of_run_id = v_run;
    if v_shadow is null then raise exception 'no shadow run was started for the model steps'; end if;
    insert into dry_ids values ('shadow', v_shadow);
    select d.spec into spec from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
     where r.id = v_shadow;
    if (select array_agg(s->>'key' order by s->>'key') from jsonb_array_elements(spec->'steps') s)
       is distinct from array['ask', 'fan'] then
        raise exception 'the shadow run should hold only the model steps: %', spec;
    end if;
    if exists (select 1 from jsonb_array_elements(spec->'steps') s
                where not coalesce((s->'input'->'body'->>'dry_run')::boolean, false)
                   or s->'input'->'body'->>'tool_choice' is distinct from 'none'
                   or s ? 'depends_on' or s::text like '%{{steps.%') then
        raise exception 'every shadow step is flagged dry_run, tools off, independent, with no live template: %', spec;
    end if;
    if exists (select 1 from workflow.run_estimates where run_id = v_shadow) then
        raise exception 'a shadow run must not be estimated itself';
    end if;
end $$;

-- 3b. A shadow task goes only to a worker that declares it can run one: a worker that does not
-- would make the real call. Claimed with the capability, it is a shadow task (so the refusal below
-- is not an empty queue); handed back, so step 4 runs it.
do $$
declare
    v_shadow uuid := (select v from dry_ids where k = 'shadow');
    t workflow.tasks;
begin
    if exists (select 1 from workflow.claim_task('t-dry-http', 'w-old'))
       or exists (select 1 from workflow.claim_tasks('t-dry-http', 'w-old', 10))
       or exists (select 1 from workflow.claim_task('t-dry-http', 'w-other', array['gpu'])) then
        raise exception 'a worker that did not declare dry_run was handed a dry run''s task';
    end if;
    select * into t from workflow.claim_task('t-dry-http', 'w-new', array['dry_run']);
    if t.run_id is distinct from v_shadow then
        raise exception 'a worker that declares dry_run should claim the shadow task, claimed %', to_jsonb(t);
    end if;
    if (select count(*) from workflow.claim_tasks('t-dry-http', 'w-new', 10, array['dry_run'])) is distinct from 1::bigint then
        raise exception 'the batch claim should hand the other shadow task to a dry_run worker';
    end if;
    update workflow.tasks set status = 'ready', claimed_by = null, claimed_at = null, heartbeat_at = null,
                              attempts = attempts - 1
     where run_id = v_shadow and status = 'running';
end $$;

-- 4. The runtime answers both on the stand-in; the shadow run ends.
do $$
declare
    v_shadow uuid := (select v from dry_ids where k = 'shadow');
    t workflow.tasks;
begin
    for t in select * from workflow.tasks where run_id = v_shadow and status = 'ready' order by step_key loop
        update workflow.tasks set status = 'running', claimed_by = 'stand-in', claimed_at = now() - interval '2 seconds',
                                  attempts = attempts + 1 where id = t.id;
        perform workflow.record_task_usage(t.id, t.attempts + 1,
            case t.step_key when 'ask' then '{"requests": 1, "input_tokens": 120, "output_tokens": 30}'
                            else '{"requests": 1, "input_tokens": 50, "output_tokens": 10}' end::jsonb, 'stand-in');
        perform workflow.complete_task(t.id, '{"result": "stand-in"}'::jsonb, 'stand-in');
    end loop;
    if (select status from workflow.runs where id = v_shadow) is distinct from 'succeeded' then
        raise exception 'the shadow run did not finish: %', (select status from workflow.runs where id = v_shadow);
    end if;
end $$;

do $$
declare
    v_run uuid := (select v from dry_ids where k = 'run');
    e jsonb;
    r workflow.run_estimates;
begin
    select jsonb_object_agg(step_key, to_jsonb(x) - 'run_id') into e from workflow.run_estimates x
     where run_id = v_run and step_key is not null;
    if (e->'ask'->>'basis', (e->'ask'->>'est_input_tokens')::int, (e->'ask'->>'est_output_tokens')::int)
       is distinct from ('dry_run'::text, 120, 30) then
        raise exception 'the dry run''s spend did not reach the step it estimated: %', e->'ask';
    end if;
    if (e->'fan'->>'basis', (e->'fan'->>'est_input_tokens')::int, (e->'fan'->>'est_requests')::int)
       is distinct from ('dry_run_bound'::text, 250, 5) then
        raise exception 'a bounded matrix''s spend is one item''s times the bound: %', e->'fan';
    end if;
    select * into r from workflow.run_estimates where run_id = v_run and step_key is null;
    if (r.basis, r.est_input_tokens, r.est_tasks) is distinct from ('dry_run'::text, 370::bigint, 107) then
        raise exception 'the run totals its steps, every one known by a dry run: %', to_jsonb(r);
    end if;
end $$;

-- 5. A run that only SAYS it is a dry run is an ordinary run: estimated, and its end writes
--    nothing into the run it names.
do $$
declare
    v_run uuid := (select v from dry_ids where k = 'run');
    v_forged uuid := workflow.start_workflow('t_dry_1125', jsonb_build_object('dry_run_of', v_run));
    before jsonb := (select jsonb_agg(to_jsonb(x) order by step_key) from workflow.run_estimates x where run_id = v_run);
begin
    if not exists (select 1 from workflow.run_estimates where run_id = v_forged and step_key is null) then
        raise exception 'a run whose input claims dry_run_of skipped its own estimate';
    end if;
    if exists (select 1 from workflow.dry_runs where shadow_run_id = v_forged) then
        raise exception 'a forged dry_run_of was recorded as a shadow run';
    end if;
    perform workflow.record_dry_run(v_forged);
    if (select jsonb_agg(to_jsonb(x) order by step_key) from workflow.run_estimates x where run_id = v_run) is distinct from before then
        raise exception 'a forged dry_run_of wrote into another run''s estimate';
    end if;
end $$;

rollback;
