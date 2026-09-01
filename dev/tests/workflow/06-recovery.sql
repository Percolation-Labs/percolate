-- CRASH RECOVERY -- the story the spec tells loudest and had never once run.
--
-- `spec.md` §3/§4 name heartbeat_task, reap_stale_tasks and
-- complete_decision_task as the crash-recovery and replay primitives. A
-- coverage pass with `track_functions='all'` found all three had **zero
-- executions, ever** -- not by the suite, not by any live run -- while the
-- spec described them in the present tense and a surface audit reported them
-- present. This file is what executing them found.
--
-- Every assertion below corresponds to a defect that was reproduced against a
-- live PG19 instance before it was fixed, in the house style: the failure came
-- first, the test second. Two of them were the same class -- a worker that is
-- slow rather than dead -- and that class is why §22 exists.
--
-- Deterministic and offline. The wall-clock half (a worker actually dying, a
-- pod actually evicted) is what `faultsrv`'s /slow route is for; this file
-- ages heartbeat_at instead, because a test that waits two minutes is a test
-- nobody runs.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- One definition per section, each on its OWN queue. Not fussiness: these
-- sections deliberately leave tasks behind in `ready` (that is the point of a
-- reaped task), so a shared queue means claim_task hands section N a leftover
-- from section N-1 and the assertion tests nothing it claims to.
do $$
declare i int;
begin
    for i in 1..8 loop
        insert into workflow.definitions (name, spec) values (
            't_r_crash_' || i,
            format('{"steps":[{"key":"a","kind":"work","queue":"tr%s"},
                              {"key":"b","kind":"work","queue":"tr%s","depends_on":["a"]}]}',
                   i, i)::jsonb);
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 1. A DEAD WORKER'S TASK COMES BACK -- WITH BACKOFF, NOT AT CLAIM SPEED.
--
-- The reaper used to return a stale task straight to `ready` with no backoff
-- and no attempt accounting. It now delegates to fail_task(.., false), which
-- IS the retry policy, so a dead worker is a failure like any other rather
-- than a second, parallel retry mechanism that agrees with the first by
-- coincidence.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_t workflow.tasks; v_after timestamptz; v_claimed text;
begin
    v_run := workflow.start_workflow('t_r_crash_1', '{}'::jsonb);
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    v_t := workflow.claim_task('tr1', 'worker-A');
    if v_t.id <> v_a then raise exception 'claimed the wrong task'; end if;

    -- The pod is evicted. Nothing calls heartbeat_task again.
    update workflow.tasks set heartbeat_at = now() - interval '10 minutes' where id = v_a;

    if workflow.reap_stale_tasks() <> 1 then
        raise exception 'the reaper did not notice a worker that stopped heartbeating';
    end if;

    select status, claimed_by, run_after into v_t.status, v_claimed, v_after
    from workflow.tasks where id = v_a;

    if v_t.status <> 'ready' then
        raise exception 'a reaped task was left %, so nothing will ever pick it up', v_t.status;
    end if;
    -- claimed_by must be cleared: §22's fence reads it, and a `ready` task
    -- still naming its dead worker would let that worker act on it again.
    if v_claimed is not null then
        raise exception 'a requeued task still names % as its holder', v_claimed;
    end if;
    if v_after <= now() then
        raise exception 'a reaped task was requeued with no backoff -- a worker that '
                        'dies on this task will now crash-loop at claim speed';
    end if;
    raise notice 'workflow/06: a dead worker''s task is requeued, unclaimed, behind a backoff';
end $$;

-- ---------------------------------------------------------------------
-- 2. max_attempts IS A REAL BUDGET FOR CRASHES, NOT ONLY FOR ERRORS.
--
-- THE FAILURE: measured at attempts=10 against max_attempts=5, still
-- claimable, run still `running`. And invisible -- every claim refreshes
-- heartbeat_at, so v_stuck_tasks never saw it. A task can consume a worker
-- slot forever while every dashboard reads green, which is this collection's
-- defining failure shape (`dev/tests/README.md`).
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid; v_a uuid; v_t workflow.tasks; i int;
    v_att int; v_max int; v_st text; v_err text;
begin
    v_run := workflow.start_workflow('t_r_crash_2', '{}'::jsonb, 'crashloop');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';
    select max_attempts into v_max from workflow.tasks where id = v_a;

    -- Ten crash cycles. run_after is wound back each time so the loop reaches
    -- the attempt budget rather than the backoff clock -- §1 already proved
    -- the backoff is there.
    for i in 1..10 loop
        update workflow.tasks set run_after = now() - interval '1 second' where id = v_a;
        v_t := workflow.claim_task('tr2', 'doomed-' || i);
        exit when v_t.id is null;
        update workflow.tasks set heartbeat_at = now() - interval '10 minutes' where id = v_a;
        perform workflow.reap_stale_tasks();
        select status into v_st from workflow.tasks where id = v_a;
        exit when v_st = 'failed';
    end loop;

    select attempts, status, error->>'error' into v_att, v_st, v_err
    from workflow.tasks where id = v_a;

    if v_st <> 'failed' then
        raise exception 'a task whose worker dies every time is still %, on attempt % of % '
                        '-- the crash budget is not enforced', v_st, v_att, v_max;
    end if;
    if v_att <> v_max then
        raise exception 'the crash loop stopped at % attempts, not the declared %', v_att, v_max;
    end if;
    -- The error has to name the worker and the attempt, or the operator learns
    -- only that something failed.
    if v_err not like '%stopped heartbeating%' or v_err not like '%doomed-%' then
        raise exception 'the reaped failure does not say who died: %', v_err;
    end if;
    if (select status from workflow.runs where id = v_run) is distinct from 'failed' then
        raise exception 'the run survived a task that exhausted its crash budget';
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'b') is distinct from 'cancelled' then
        raise exception 'the successor of a terminally-crashed task was not cancelled';
    end if;
    raise notice 'workflow/06: a crash loop is bounded by max_attempts, fails the run, '
                 'and names the worker that died';
end $$;

-- ---------------------------------------------------------------------
-- 3. THE ZOMBIE. A worker that was slow, not dead, must not win.
--
-- THE FAILURE, reproduced end to end: worker A is partitioned, the reaper
-- revokes its lease, worker B takes the task -- and A's completion was
-- accepted anyway. It wrote A's stale output into runs.context, released the
-- successor with it, and then B's real completion OVERWROTE that context
-- after the successor had already read it. Two workers did the same work, the
-- loser's answer was published, and `{{steps.a.result}}` meant different
-- things depending on when a step dispatched.
--
-- Note the fence is tested through the REAPED-INTO-BACKOFF window, which is
-- the harder case: the task is `ready` and unclaimed there, so a check that
-- only compared worker ids would pass vacuously.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_t workflow.tasks; v_ctx jsonb; v_v bigint;
begin
    v_run := workflow.start_workflow('t_r_crash_3', '{}'::jsonb, 'zombie');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    v_t := workflow.claim_task('tr3', 'worker-A');
    update workflow.tasks set heartbeat_at = now() - interval '10 minutes' where id = v_a;
    perform workflow.reap_stale_tasks();

    select count(*) into v_v from workflow.task_events where detail->>'event' = 'lease_violation';

    -- A wakes up and reports the work it finished before it was declared dead.
    perform workflow.complete_task(v_a, '{"result":"STALE-from-A"}'::jsonb);

    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx ? 'a' then
        raise exception 'a worker whose lease was revoked published its result anyway: %', v_ctx;
    end if;
    if (select status from workflow.tasks where id = v_a) = 'done' then
        raise exception 'a revoked worker completed the task it no longer held';
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'b') is distinct from 'pending' then
        raise exception 'the successor was released by a worker that had been reaped';
    end if;

    -- Refused, but RECORDED. A completion that vanishes silently is
    -- indistinguishable from a worker that never ran -- the same argument
    -- normalize_output's event makes (§21a).
    if (select count(*) from workflow.task_events
        where detail->>'event' = 'lease_violation') <= v_v then
        raise exception 'the refusal was silent -- nothing can tell this deployment '
                        'that its workers are being reaped mid-flight';
    end if;
    if (select count(*) from workflow.v_lease_violations) = 0 then
        raise exception 'v_lease_violations does not report a refusal that happened';
    end if;
    raise notice 'workflow/06: a reaped worker cannot publish its result, and the '
                 'refusal is visible rather than silent';
end $$;

-- ---------------------------------------------------------------------
-- 4. AND THE SAME FENCE WITH TWO LIVE WORKERS, WHICH IS THE OTHER HALF.
--
-- §3 covers the window where nobody holds the task. This is the window where
-- somebody else does -- the case that needs the caller to say who it is.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_t workflow.tasks; v_ctx jsonb;
begin
    v_run := workflow.start_workflow('t_r_crash_4', '{}'::jsonb, 'twolive');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    v_t := workflow.claim_task('tr4', 'worker-A');
    update workflow.tasks set heartbeat_at = now() - interval '10 minutes' where id = v_a;
    perform workflow.reap_stale_tasks();
    update workflow.tasks set run_after = now() - interval '1 second' where id = v_a;
    v_t := workflow.claim_task('tr4', 'worker-B');
    if v_t.claimed_by <> 'worker-B' then raise exception 'B did not take the lease'; end if;

    -- A reports, identifying itself honestly. It must be refused.
    perform workflow.complete_task(v_a, '{"result":"STALE"}'::jsonb, 'worker-A');
    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx ? 'a' then
        raise exception 'the previous lease holder completed a task another worker holds';
    end if;

    -- ...and a heartbeat from A is told to stop, which is how a partitioned
    -- worker learns it lost. B's heartbeat still says keep going.
    if workflow.heartbeat_task(v_a, 'worker-A') then
        raise exception 'a worker that lost its lease was told to keep working';
    end if;
    if not workflow.heartbeat_task(v_a, 'worker-B') then
        raise exception 'the live lease holder was told to stop';
    end if;

    -- B, the real holder, completes normally.
    perform workflow.complete_task(v_a, '{"result":"FRESH-from-B"}'::jsonb, 'worker-B');
    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx#>>'{a,result}' <> 'FRESH-from-B' then
        raise exception 'the live holder''s result did not land: %', v_ctx;
    end if;
    raise notice 'workflow/06: between two workers the live lease holder wins, and the '
                 'loser is told to stop';
end $$;

-- ---------------------------------------------------------------------
-- 5. A DONE STEP'S RESULT IS IMMUTABLE.
--
-- The torn read, isolated. Once `a` is done, {{steps.a.result}} must mean one
-- thing forever -- otherwise a step that dispatched early and a step that
-- dispatched late read different values for the same expression, and neither
-- is wrong from where it stands.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_ctx jsonb;
begin
    v_run := workflow.start_workflow('t_r_crash_5', '{}'::jsonb, 'immutable');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    perform workflow.complete_task(v_a, '{"result":"FIRST"}'::jsonb);
    perform workflow.complete_task(v_a, '{"result":"SECOND"}'::jsonb);

    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx#>>'{a,result}' <> 'FIRST' then
        raise exception 'a completed step''s result was rewritten to %, so {{steps.a.result}} '
                        'means different things at different times', v_ctx#>>'{a,result}';
    end if;
    raise notice 'workflow/06: a completed step''s result cannot be rewritten';
end $$;

-- ---------------------------------------------------------------------
-- 6. THE REAPER DOES NOT KILL HEALTHY LONG WORK.
--
-- The other direction, and the one that would make the reaper worse than
-- useless: a task that is slow but alive must survive. This is what
-- heartbeat_task is FOR, and it had never been called.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_t workflow.tasks;
begin
    v_run := workflow.start_workflow('t_r_crash_6', '{}'::jsonb, 'longwork');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';
    v_t := workflow.claim_task('tr6', 'worker-slow');
    if v_t.id <> v_a then raise exception 'claimed the wrong task'; end if;

    -- Nearly stale...
    update workflow.tasks set heartbeat_at = now() - interval '10 minutes' where id = v_a;
    -- ...and then it checks in, as a live worker on a long job does.
    if not workflow.heartbeat_task(v_a, 'worker-slow') then
        raise exception 'a live worker was told to stop for no reason';
    end if;

    if workflow.reap_stale_tasks() <> 0 then
        raise exception 'the reaper killed a task whose worker had just checked in -- '
                        'long work is now impossible';
    end if;
    if (select status from workflow.tasks where id = v_a) is distinct from 'running' then
        raise exception 'a heartbeating task did not stay running';
    end if;
    raise notice 'workflow/06: a heartbeat protects long work from the reaper';
end $$;

-- ---------------------------------------------------------------------
-- 7. COOPERATIVE CANCEL. heartbeat_task returning false is the documented
--    way a worker is asked to stop, and nothing had ever read it.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_a uuid; v_t workflow.tasks; v_alice uuid;
begin
    v_run := workflow.start_workflow('t_r_crash_7', '{}'::jsonb, 'coopcancel');
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';
    v_t := workflow.claim_task('tr7', 'worker-C');
    if v_t.id <> v_a then raise exception 'claimed the wrong task'; end if;

    if not workflow.heartbeat_task(v_a, 'worker-C') then
        raise exception 'a worker on a live run was told to stop before anything cancelled it';
    end if;

    -- cancel_run is authorised, so drive it the way a caller does -- through a
    -- JWT -- rather than reading its source for the string 'assert_run_access'.
    -- A source check catches the guard being deleted and not the guard being
    -- wrong, which is the failure assert_run_access actually had twice.
    v_alice := gen_random_uuid();
    insert into rbac.users (id, email) values (v_alice, 'recovery-alice@test.com');
    update workflow.runs set owner_id = v_alice where id = v_run;
    perform set_config('request.jwt.claims', json_build_object('sub', v_alice::text)::text, true);
    perform workflow.cancel_run(v_run);
    perform set_config('request.jwt.claims', '', true);

    if workflow.heartbeat_task(v_a, 'worker-C') then
        raise exception 'a worker on a CANCELLED run was told to keep working -- '
                        'cooperative cancel does not work';
    end if;
    raise notice 'workflow/06: cancelling a run tells its running workers to stop, '
                 'through the authorised entry point';
end $$;

-- ---------------------------------------------------------------------
-- 8. AND AN UNAUTHORISED CALLER CANNOT CANCEL. The behavioural half of the
--    same assertion 01-quiet-failures.sql makes by reading source text.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_alice uuid; v_mallory uuid;
begin
    v_alice   := gen_random_uuid();
    v_mallory := gen_random_uuid();
    insert into rbac.users (id, email) values
        (v_alice, 'recovery-owner@test.com'), (v_mallory, 'recovery-mallory@test.com');

    v_run := workflow.start_workflow('t_r_crash_8', '{}'::jsonb, 'authz');
    update workflow.runs set owner_id = v_alice where id = v_run;

    perform set_config('request.jwt.claims', json_build_object('sub', v_mallory::text)::text, true);
    begin
        perform workflow.cancel_run(v_run);
        perform set_config('request.jwt.claims', '', true);
        raise exception 'PRIVILEGE ESCALATION: a stranger cancelled somebody else''s run';
    exception when others then
        perform set_config('request.jwt.claims', '', true);
        if sqlerrm like 'PRIVILEGE ESCALATION%' then raise; end if;
    end;

    if (select status from workflow.runs where id = v_run) is distinct from 'running' then
        raise exception 'the run was cancelled despite the authorisation failure';
    end if;
    raise notice 'workflow/06: cancel_run refuses a caller who owns neither the run '
                 'nor the permission -- asserted by calling it, not by reading it';
end $$;

-- ---------------------------------------------------------------------
-- 9. THE REPLAY PRIMITIVE. complete_decision_task is what spec.md §3 offers
--    INSTEAD of full event sourcing, and it had never been executed.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_r_dec', '{"steps":[{"key":"d","kind":"decision","queue":"td"},
                       {"key":"after","kind":"work","queue":"td","depends_on":["d"]}]}');

do $$
declare v_run uuid; v_d uuid; v_t workflow.tasks; v_n int; v_raised boolean := false;
begin
    v_run := workflow.start_workflow('t_r_dec', '{}'::jsonb);
    select id into v_d from workflow.tasks where run_id = v_run and step_key = 'd';
    v_t := workflow.claim_task('td', 'w-dec');

    perform workflow.complete_decision_task(v_d, '{"branch":"left"}'::jsonb,
        '[{"step_key":"left_a","queue":"td","kind":"work","input":{"x":1}}]'::jsonb);

    if (select status from workflow.tasks where run_id = v_run and step_key = 'left_a') is distinct from 'ready' then
        raise exception 'the branch the decision chose was not created ready';
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'after') is distinct from 'ready' then
        raise exception 'the decision did not release its declared successor';
    end if;

    -- Replay with the SAME output: idempotent, not a second branch. This is
    -- the whole point -- re-running a decision against its recorded input has
    -- to be free.
    select count(*) into v_n from workflow.tasks where run_id = v_run;
    perform workflow.complete_decision_task(v_d, '{"branch":"left"}'::jsonb,
        '[{"step_key":"left_a","queue":"td","kind":"work","input":{"x":1}}]'::jsonb);
    if (select count(*) from workflow.tasks where run_id = v_run) <> v_n then
        raise exception 'replaying a decision duplicated its branch';
    end if;

    -- Replay with a DIFFERENT output: loud, not silent. A decision that
    -- branches differently on replay is a decision that read the wall clock.
    begin
        perform workflow.complete_decision_task(v_d, '{"branch":"RIGHT"}'::jsonb, '[]'::jsonb);
    exception when others then
        v_raised := true;
    end;
    if not v_raised then
        raise exception 'a non-deterministic decision replayed silently -- the purity '
                        'guard spec.md §3 trades event sourcing for does not work';
    end if;
    raise notice 'workflow/06: a decision branches once, replays free, and refuses to '
                 'branch differently the second time';
end $$;

-- ---------------------------------------------------------------------
-- 10. A DECISION TASK ORDERS ITS SAGA CORRECTLY (§21c, one function over).
--
-- complete_task was fixed to use clock_timestamp() because now() -- the
-- TRANSACTION timestamp -- is shared by every step finishing in one
-- transaction, and completed_at is the column begin_compensation orders by.
-- complete_decision_task kept now(), which is the same bug surviving in the
-- copy nobody executed. promote_due_timers set no completed_at at all.
-- ---------------------------------------------------------------------
do $$
declare v_a timestamptz; v_b timestamptz;
begin
    if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'workflow' and p.proname = 'complete_decision_task')
       like '%completed_at = now()%' then
        raise exception 'complete_decision_task still stamps completed_at with the '
                        'transaction timestamp, so a decision inside a saga group '
                        'compensates in forward order (§21c)';
    end if;
    if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'workflow' and p.proname = 'promote_due_timers')
       not like '%completed_at%' then
        raise exception 'a fired timer records no completed_at, so it sorts first under '
                        'order by completed_at desc and compensates before everything '
                        'that ran after it';
    end if;
    if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'workflow' and p.proname = 'signal_task')
       not like '%completed_at%' then
        raise exception 'a signalled task records no completed_at -- the third path to '
                        'mark a task done without the column a saga orders by';
    end if;
    raise notice 'workflow/06: all three paths that complete a task outside '
                 'complete_task stamp the ordering column the saga reads';
end $$;

-- ---------------------------------------------------------------------
-- 11. BATCHED CLAIMING. spec.md §7 names claim_tasks as the throughput
--     answer; it had never been called.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_r_batch', '{"steps":[{"key":"p","kind":"work","queue":"tb"},
                         {"key":"q","kind":"work","queue":"tb"},
                         {"key":"r","kind":"work","queue":"tb"}]}');

do $$
declare v_run uuid; v_n int; v_running int;
begin
    v_run := workflow.start_workflow('t_r_batch', '{}'::jsonb);
    select count(*) into v_n from workflow.claim_tasks('tb', 'batch-worker', 10);
    if v_n <> 3 then
        raise exception 'claim_tasks returned % of 3 ready tasks', v_n;
    end if;
    select count(*) into v_running from workflow.tasks
    where run_id = v_run and status = 'running' and claimed_by = 'batch-worker';
    if v_running <> 3 then
        raise exception 'claim_tasks returned rows it did not actually claim: % running', v_running;
    end if;
    if (select count(*) from workflow.claim_tasks('tb', 'batch-worker-2', 10)) <> 0 then
        raise exception 'a second batch re-claimed tasks already held';
    end if;
    raise notice 'workflow/06: batched claiming takes the whole queue once and leaves '
                 'nothing for a second claimer';
end $$;

-- ---------------------------------------------------------------------
-- 12. THE TWO WAYS A RUN STALLS WITHOUT FAILING.
--
-- 05-faults asserts a timer's delay is measured from readiness. It does not
-- assert that anything ever FIRES it, and promote_due_timers had never been
-- executed -- a timer that is correctly scheduled and never promoted is a run
-- that waits forever while reporting `running`. The signal half is the same
-- shape from the other end: a `signal` step parks in waiting_external, and if
-- signal_task cannot deliver, nothing says so.
--
-- Both belong in this file rather than 05: they are liveness, and a stall that
-- never fails is the failure this suite exists to catch.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_r_timer', '{"steps":[{"key":"first","kind":"work","queue":"trt"},
                         {"key":"wait","kind":"timer","queue":"none","depends_on":["first"],
                          "input":{"delay_seconds":1}},
                         {"key":"last","kind":"work","queue":"trt","depends_on":["wait"]}]}');

do $$
declare v_run uuid; v_first uuid; v_wait uuid; v_fired int;
begin
    v_run := workflow.start_workflow('t_r_timer', '{}'::jsonb);
    select id into v_first from workflow.tasks where run_id = v_run and step_key = 'first';
    perform workflow.complete_task(v_first, '{"result":"ok"}'::jsonb);

    select id into v_wait from workflow.tasks where run_id = v_run and step_key = 'wait';
    if (select status from workflow.tasks where id = v_wait) is distinct from 'ready' then
        raise exception 'the timer did not become ready when its dependency completed';
    end if;

    -- Not yet due: promoting now would make every delay a lie.
    if workflow.promote_due_timers() <> 0 then
        raise exception 'a timer fired before its delay elapsed';
    end if;

    -- Due. The clock is driven rather than waited on, same as 02-schedules.
    update workflow.tasks set run_after = now() - interval '1 second' where id = v_wait;
    v_fired := workflow.promote_due_timers();
    if v_fired <> 1 then
        raise exception 'a due timer was not promoted -- the run waits forever '
                        'while reporting running (% fired)', v_fired;
    end if;
    if (select status from workflow.tasks where id = v_wait) is distinct from 'done' then
        raise exception 'a promoted timer is not done';
    end if;
    if (select completed_at from workflow.tasks where id = v_wait) is null then
        raise exception 'a fired timer recorded no completed_at, so it sorts first '
                        'in a saga compensation (§21c)';
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'last') is distinct from 'ready' then
        raise exception 'a fired timer did not release the step waiting on it';
    end if;
    raise notice 'workflow/06: a timer fires only when due, and firing releases what '
                 'was waiting on it';
end $$;

insert into workflow.definitions (name, spec) values
('t_r_signal', '{"steps":[{"key":"await","kind":"signal","queue":"none",
                           "input":{"signal":"approved"}},
                          {"key":"then","kind":"work","queue":"trs","depends_on":["await"]}]}');

do $$
declare v_run uuid; v_await uuid; v_owner uuid;
begin
    v_run := workflow.start_workflow('t_r_signal', '{}'::jsonb);
    select id into v_await from workflow.tasks where run_id = v_run and step_key = 'await';

    -- signal_task is authorised, like cancel_run. An unowned run is
    -- system-owned and takes an explicit permission rather than bare
    -- ownership (§21j), so drive this as a real caller with a real identity --
    -- which also asserts that the delivery path an approval button uses is the
    -- authorised one.
    v_owner := gen_random_uuid();
    insert into rbac.users (id, email) values (v_owner, 'recovery-signaller@test.com');
    update workflow.runs set owner_id = v_owner where id = v_run;
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

    if (select status from workflow.tasks where id = v_await) is distinct from 'waiting_external' then
        raise exception 'a signal step did not park in waiting_external, it is %',
            (select status from workflow.tasks where id = v_await);
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'then') is distinct from 'pending' then
        raise exception 'the step after an unsignalled wait was released early';
    end if;

    perform workflow.signal_task(v_run, 'approved', '{"by":"a human"}'::jsonb);

    if (select status from workflow.tasks where id = v_await) is distinct from 'done' then
        raise exception 'signal_task did not resolve the waiting task';
    end if;
    if (select completed_at from workflow.tasks where id = v_await) is null then
        raise exception 'a signalled task recorded no completed_at -- the third path '
                        'to mark a task done without the column a saga orders by (§21c)';
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'then') is distinct from 'ready' then
        raise exception 'the signalled step did not release its successor';
    end if;
    perform set_config('request.jwt.claims', '', true);
    raise notice 'workflow/06: a signal step waits for the outside world and is '
                 'released by it, through the authorised path -- the '
                 'human-in-the-loop primitive, executed';
end $$;

rollback;
