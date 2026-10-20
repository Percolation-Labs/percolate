-- FAULTS -- the twelve things five real runs broke, asserted.
--
-- `schema.sql` §21. Every assertion here corresponds to a failure produced by
-- running a workflow against a live public API, not by reading source. They
-- share the shape this repo cares most about: the run reported a status that
-- was not true, or a feature read as configured and was not.
--
-- Deterministic and offline. The HTTP half of the same matrix -- retry on a
-- 5xx, a tolerated 404, a shape violation that recovers -- is exercised by
-- `../../faultsrv/example.yaml` against the fault-injection service, because
-- those need a worker and a network and this file needs neither.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- 1. The output contract (21a). The worker stored its http_call output as a
--    JSON STRING containing JSON, so {{steps.<id>.result}} -- the one idiom
--    every step kind teaches -- resolved to nothing against every REST step.
--    Chaining anything to a fetch was impossible as documented.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_f_encode', '{"steps":[{"key":"a","kind":"work","queue":"t"},
                          {"key":"b","kind":"work","queue":"t","depends_on":["a"]}]}');

do $$
declare v_run uuid; v_a uuid; v_ctx jsonb; v_before bigint;
begin
    v_run := workflow.start_workflow('t_f_encode', '{}'::jsonb);
    select id into v_a from workflow.tasks where run_id = v_run and step_key = 'a';

    select count(*) into v_before from workflow.task_events
    where detail->>'event' = 'output_normalized';

    -- Exactly what the shipped worker does.
    perform workflow.complete_task(v_a, to_jsonb('{"status":200,"result":{"rates":{"GBP":0.79}}}'::text));

    select context into v_ctx from workflow.runs where id = v_run;
    if jsonb_typeof(v_ctx->'a') <> 'object' then
        raise exception
            'a double-encoded output was stored as-is (%). Every {{steps.a.result}} '
            'against it resolves to nothing, in a run that reports success.',
            jsonb_typeof(v_ctx->'a');
    end if;
    if v_ctx#>>'{a,result,rates,GBP}' <> '0.79' then
        raise exception 'the repaired output is not navigable: %', v_ctx->'a';
    end if;

    -- Repaired, but RECORDED. Silent leniency is how a contract rots.
    if (select count(*) from workflow.task_events
        where detail->>'event' = 'output_normalized') <= v_before then
        raise exception
            'the repair was silent. A producer violating the output contract has to be '
            'a number someone can watch, or it never gets fixed.';
    end if;
    if not exists (select 1 from workflow.encoding_drift()) then
        raise exception 'encoding_drift() does not report the repair';
    end if;

    -- A genuine scalar output is NOT touched: only a string whose content is
    -- itself an object or array is unambiguously double-encoded.
    if workflow.normalize_output(v_a, '"ok"'::jsonb) <> '"ok"'::jsonb then
        raise exception 'normalization rewrote an ordinary string output';
    end if;
    if workflow.normalize_output(v_a, '"not json at all"'::jsonb) <> '"not json at all"'::jsonb then
        raise exception 'normalization mangled a non-JSON string';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Declared output shapes (21f/21h), and why a violation is RETRYABLE.
--
-- This is the only failure in the engine classified retryable on purpose:
-- asking a model again is a real remedy, where re-fetching a 404 is not.
-- ---------------------------------------------------------------------
do $$
declare
    v_case record;
    v_got  text;
begin
    for v_case in
        select * from (values
            ('{"verdict":"SAFETY","confidence":0.9}',
             '{"type":"object","required":["verdict","confidence"],
               "properties":{"verdict":{"enum":["SAFETY","FINANCE"]},
                             "confidence":{"type":"number"}}}',
             null, 'a conforming answer'),
            ('{"verdict":"SAFETY"}',
             '{"type":"object","required":["verdict","confidence"]}',
             'missing required key', 'a missing field'),
            ('{"verdict":"MAYBE"}',
             '{"type":"object","properties":{"verdict":{"enum":["SAFETY","FINANCE"]}}}',
             'not one of', 'a value outside the enum'),
            ('{"confidence":"high"}',
             '{"type":"object","properties":{"confidence":{"type":"number"}}}',
             'expected type number', 'the wrong type'),
            ('{"a":1,"b":2}',
             '{"type":"object","properties":{"a":{}},"additionalProperties":false}',
             'unexpected key', 'a closed object with an extra key'),
            ('[{"v":"X"}]',
             '{"type":"array","items":{"properties":{"v":{"enum":["A"]}}}}',
             'array element', 'a bad element in an array')
        ) as t(val, schema, expect, why)
    loop
        v_got := workflow.validate_shape(v_case.val::jsonb, v_case.schema::jsonb);
        if v_case.expect is null then
            if v_got is not null then
                raise exception 'rejected %: %', v_case.why, v_got;
            end if;
        elsif v_got is null or v_got not like '%' || v_case.expect || '%' then
            raise exception 'accepted % (or said the wrong thing): %',
                v_case.why, coalesce(v_got, '<conformed>');
        end if;
    end loop;
end $$;

insert into workflow.definitions (name, spec) values
('t_f_shape', '{"steps":[{"key":"ask","kind":"work","queue":"t","input":{
    "output_schema":{"type":"object","required":["verdict"],
                     "properties":{"verdict":{"enum":["SAFETY","FINANCE"]}}}}}]}');

do $$
declare v_run uuid; v_t uuid; t workflow.tasks;
begin
    v_run := workflow.start_workflow('t_f_shape', '{}'::jsonb);
    select id into v_t from workflow.tasks where run_id = v_run and step_key = 'ask';

    -- A model answering in the wrong shape.
    perform workflow.complete_task(v_t, '{"result":{"verdict":"MAYBE"}}'::jsonb);
    select * into t from workflow.tasks where id = v_t;

    if t.status <> 'ready' then
        raise exception
            'a shape violation was not retryable (status %). Asking a model again is a '
            'real remedy -- this is the one place retry is obviously right.', t.status;
    end if;
    if not (t.error ? 'shape_violation') or t.error->>'error' not like '%not one of%' then
        raise exception 'the violation does not say what was wrong: %', t.error;
    end if;

    -- The same step, answering correctly on the next attempt.
    update workflow.tasks set status = 'running' where id = v_t;
    perform workflow.complete_task(v_t, '{"result":{"verdict":"SAFETY"}}'::jsonb);
    if (select status from workflow.tasks where id = v_t) is distinct from 'succeeded' then
        raise exception 'a conforming retry did not complete';
    end if;

    -- A model returns its answer as message CONTENT, i.e. a string. It must be
    -- parsed before the shape is checked, or every structured agent step fails.
    update workflow.tasks set status = 'running', output = null where id = v_t;
    perform workflow.complete_task(v_t, jsonb_build_object('result', '{"verdict":"FINANCE"}'));
    if (select output#>>'{result,verdict}' from workflow.tasks where id = v_t) is distinct from 'FINANCE' then
        raise exception 'a JSON-in-a-string model answer was not parsed before validation';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. A fan-out that survives a failed child (21e).
--
-- The failure this exists for is ordinary, not exotic: a filer that does not
-- tag a concept returns 404, and under pure AND-join that one 404 cancelled
-- the aggregate. It happened on the FIRST six-wide run, twice.
-- ---------------------------------------------------------------------
create function t_f_echo(p text) returns jsonb as $fn$ select jsonb_build_object('saw', p) $fn$ language sql;
select workflow.register_step_function('t_f_echo','t_f_echo','{text}');

insert into workflow.definitions (name, spec) values
('t_f_tolerant', '{"steps":[
  {"key":"fan","kind":"matrix","queue":"t","input":{
     "items":[{"n":1},{"n":2},{"n":3},{"n":4}], "max_fanout":10,
     "continue_on":"failed", "min_success":0.5,
     "template":{"queue":"t","kind":"work"}}},
  {"key":"agg","kind":"work","queue":"t","depends_on":["fan"]}]}');

do $$
declare v_run uuid; v_agg uuid; v_kid uuid;
begin
    v_run := workflow.start_workflow('t_f_tolerant', '{}'::jsonb);
    select id into v_agg from workflow.tasks where run_id = v_run and step_key = 'agg';

    if not (select tolerate_failure from workflow.tasks
            where run_id = v_run and step_key = 'fan[0]') then
        raise exception 'continue_on did not reach the children';
    end if;

    -- Two fail, two succeed: exactly the 0.5 floor.
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[0]';
    perform workflow.fail_task(v_kid, '{"error":"404"}'::jsonb, true);

    -- A TOLERATED failure must SATISFY its dependent, not merely stop
    -- cancelling it. Skipping the cancel without decrementing leaves the
    -- aggregate blocked forever -- a stall instead of a cancellation, which is
    -- worse because nothing reports it.
    if (select status from workflow.tasks where id = v_agg) is distinct from 'pending' then
        raise exception 'the aggregate was released after one of four children';
    end if;
    if (select pending_deps from workflow.tasks where id = v_agg) is distinct from 3 then
        raise exception
            'a tolerated failure did not decrement its dependent: pending_deps=%',
            (select pending_deps from workflow.tasks where id = v_agg);
    end if;
    -- ...and it must not fail the run.
    if (select status from workflow.runs where id = v_run) is distinct from 'running' then
        raise exception 'a tolerated child failure failed the whole run';
    end if;

    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[1]';
    perform workflow.fail_task(v_kid, '{"error":"401"}'::jsonb, true);
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[2]';
    perform workflow.complete_task(v_kid, '{"result":"ok"}'::jsonb);
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[3]';
    perform workflow.complete_task(v_kid, '{"result":"ok"}'::jsonb);

    if (select status from workflow.tasks where id = v_agg) is distinct from 'ready' then
        raise exception 'the aggregate was not released at exactly the min_success floor: %',
            (select status from workflow.tasks where id = v_agg);
    end if;
end $$;

-- Below the floor, the aggregate is cancelled rather than run over a
-- half-empty fan-out -- and the check happens BEFORE release, because a `sql`
-- successor auto-runs inside the statement that marks it ready.
insert into workflow.definitions (name, spec) values
('t_f_floor', '{"steps":[
  {"key":"fan","kind":"matrix","queue":"t","input":{
     "items":[{"n":1},{"n":2}], "max_fanout":10,
     "continue_on":"failed", "min_success":0.9,
     "template":{"queue":"t","kind":"work"}}},
  {"key":"agg","kind":"sql","queue":"none","depends_on":["fan"],
   "input":{"function":"t_f_echo","args":["SHOULD-NOT-RUN"]}}]}');

do $$
declare v_run uuid; v_kid uuid;
begin
    v_run := workflow.start_workflow('t_f_floor', '{}'::jsonb);
    -- one of two fails -> 50%, below the 90% floor. `agg` is a `sql` step
    -- precisely so that releasing it would RUN it inside the same statement:
    -- if the gate were checked after release rather than before, its output
    -- would already exist by the time it was cancelled.
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[1]';
    perform workflow.complete_task(v_kid, '{"result":"ok"}'::jsonb);
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[0]';
    perform workflow.fail_task(v_kid, '{"error":"boom"}'::jsonb, true);

    if (select status from workflow.tasks where run_id = v_run and step_key='agg') is distinct from 'cancelled' then
        raise exception 'the aggregate ran below its min_success floor: %',
            (select status from workflow.tasks where run_id = v_run and step_key='agg');
    end if;
    if (select output from workflow.tasks where run_id = v_run and step_key='agg') is not null then
        raise exception
            'the aggregate produced output before being cancelled -- the gate is being '
            'checked after release, and a sql successor runs in the same statement';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Saga (21d), which did not work in five ways.
-- ---------------------------------------------------------------------
create table t_f_ledger (seq serial primary key, action text);
create function t_f_note(p text) returns jsonb as $fn$
    insert into t_f_ledger(action) values (p) returning jsonb_build_object('did', action);
$fn$ language sql volatile;
create function t_f_boom(p text) returns jsonb as $fn$
begin raise exception 'declined: %', p; end $fn$ language plpgsql volatile;
select workflow.register_step_function('t_f_note','t_f_note','{text}');
select workflow.register_step_function('t_f_boom','t_f_boom','{text}');

insert into workflow.definitions (name, spec) values
('t_f_saga', '{"steps":[
  {"key":"charge","kind":"sql","queue":"none","saga_group":"b","compensation_task_key":"refund",
   "input":{"function":"t_f_note","args":["charge"]}},
  {"key":"reserve","kind":"sql","queue":"none","depends_on":["charge"],"saga_group":"b",
   "compensation_task_key":"release","input":{"function":"t_f_note","args":["reserve"]}},
  {"key":"ticket","kind":"sql","queue":"none","depends_on":["reserve"],"saga_group":"b",
   "input":{"function":"t_f_boom","args":["ticket"]}},
  {"key":"refund","kind":"sql","queue":"none","input":{"function":"t_f_note","args":["REFUND"]}},
  {"key":"release","kind":"sql","queue":"none","input":{"function":"t_f_note","args":["RELEASE"]}}]}');

do $$
declare v_run uuid; v_ledger text;
begin
    v_run := workflow.start_workflow('t_f_saga', '{}'::jsonb);

    -- (1) Compensation steps are not part of the forward graph. They used to
    -- be created as roots and run immediately -- refunding the customer during
    -- a SUCCESSFUL booking.
    if exists (select 1 from workflow.tasks
               where run_id = v_run and step_key in ('refund','release')) then
        raise exception 'a compensation step was instantiated as a forward task';
    end if;

    -- (2) Terminal failure inside the group starts the rollback by itself.
    if (select compensation_state from workflow.runs where id = v_run) is distinct from 'compensated' then
        raise exception
            'compensation did not trigger (state %). spec.md 6 describes it as automatic '
            'on terminal failure; it was wired to nothing.',
            (select compensation_state from workflow.runs where id = v_run);
    end if;

    -- (3) A compensation runs as the step the author actually wrote. They were
    -- created kind=work on the forward queue, so a sql compensation became an
    -- unrunnable work task on queue 'none' and sat ready forever.
    if exists (select 1 from workflow.tasks
               where run_id = v_run and compensates_task_id is not null
                 and (kind <> 'sql' or status <> 'succeeded')) then
        raise exception 'a compensation did not run as its declared kind: %',
            (select jsonb_agg(jsonb_build_object('k',kind,'s',status))
             from workflow.tasks where run_id = v_run and compensates_task_id is not null);
    end if;

    -- (4) Reverse order. completed_at used now() -- the TRANSACTION timestamp
    -- -- so every step finishing in one transaction shared it and LIFO
    -- degraded to arbitrary. It compensated charge before reserve.
    select string_agg(action, ',' order by seq) into v_ledger from t_f_ledger;
    if v_ledger is distinct from 'charge,reserve,RELEASE,REFUND' then
        raise exception
            'compensation did not run in reverse order: %  (expected charge,reserve,RELEASE,REFUND)',
            v_ledger;
    end if;
    if (select count(distinct completed_at) from workflow.tasks
        where run_id = v_run and saga_group = 'b' and status = 'succeeded') < 2 then
        raise exception
            'saga members share a completed_at, so LIFO ordering is a coin flip -- '
            'now() is the transaction timestamp; clock_timestamp() advances within one';
    end if;
end $$;

-- (5) A compensation that fails must not start another rollback -- that is an
-- infinite loop, and it is why the trigger keys off compensates_task_id.
do $$
declare v_run uuid; v_comp uuid;
begin
    select r.id into v_run from workflow.runs r join workflow.definitions d on d.id=r.workflow_def_id
    where d.name = 't_f_saga' order by r.created_at desc limit 1;
    select id into v_comp from workflow.tasks
    where run_id = v_run and compensates_task_id is not null limit 1;

    update workflow.tasks set status = 'running', compensated_at = null where id = v_comp;
    perform workflow.fail_task(v_comp, '{"error":"rollback failed"}'::jsonb, true);
    -- If this returned, no infinite recursion occurred.
    if (select status from workflow.tasks where id = v_comp) is distinct from 'failed' then
        raise exception 'a failed compensation did not settle';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. A dead run is not an idempotent hit (21k).
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_again uuid; v_err text;
begin
    v_run := workflow.start_workflow('t_f_encode', '{}'::jsonb, 't_f_key');

    -- A repeat while it is live is the idempotent case, and must be silent.
    v_again := workflow.start_workflow('t_f_encode', '{}'::jsonb, 't_f_key');
    if v_again is distinct from v_run then
        raise exception 'idempotency stopped working for a live run';
    end if;

    perform workflow.cancel_run_unchecked(v_run);
    begin
        perform workflow.start_workflow('t_f_encode', '{}'::jsonb, 't_f_key');
        raise exception 'a cancelled run was handed back as "already started"';
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err not like '%cancelled%' or v_err not like '%new external_id%' then
        raise exception 'the refusal does not say what happened or what to do: %', v_err;
    end if;

    -- And no work lands under a cancelled run: a worker finishing in-flight
    -- work used to resurrect a cancelled graph one step at a time.
    perform workflow.complete_task(
        (select id from workflow.tasks where run_id = v_run and step_key = 'a'),
        '{"result":"late"}'::jsonb);
    if coalesce((select status from workflow.tasks where run_id = v_run and step_key = 'a'),
                '<no such task>') <> 'cancelled' then
        raise exception 'a task completed under a cancelled run: it is %',
            (select status from workflow.tasks where run_id = v_run and step_key = 'a');
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Rate limiting is consumed by claim_task itself (21b).
--
-- Every piece existed -- the bucket, try_consume_rate_limit,
-- claim_task_rate_limited -- and nothing called them, because the worker calls
-- claim_task. Measured 12.94 req/s against a published 10/s ceiling with the
-- bucket untouched at capacity.
-- ---------------------------------------------------------------------
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('t_f_limit', 2, 2, 0);

insert into workflow.definitions (name, spec) values
('t_f_rate', '{"steps":[
  {"key":"a","kind":"work","queue":"t_rate","rate_key":"t_f_limit"},
  {"key":"b","kind":"work","queue":"t_rate","rate_key":"t_f_limit"},
  {"key":"c","kind":"work","queue":"t_rate","rate_key":"t_f_limit"}]}');

do $$
declare v_run uuid; v_claimed int := 0; t workflow.tasks;
begin
    v_run := workflow.start_workflow('t_f_rate', '{}'::jsonb);
    for i in 1..3 loop
        t := workflow.claim_task('t_rate', 'tester');
        if t.id is not null then v_claimed := v_claimed + 1; end if;
    end loop;

    if v_claimed <> 2 then
        raise exception
            'claim_task handed out % tasks against a bucket of 2. A throttle that reads '
            'as configured and is not is worse than no throttle -- it is why a fan-out '
            'gets pointed at a regulator''s API believing it is polite.', v_claimed;
    end if;
    -- `is distinct from` / a null guard rather than `>= 2`: a scalar subquery
    -- over a row that is not there is NULL, `NULL >= 2` is NULL, and the IF
    -- does not fire -- so this assertion used to pass on a bucket that was
    -- never created at all, which is the one state it exists to refuse.
    -- (failure-modes.md, "An assertion that cannot fail".)
    if coalesce((select tokens from workflow.rate_limits where key = 't_f_limit'), 99) >= 2 then
        raise exception 'the bucket was never consumed (tokens = %)',
            coalesce((select tokens::text from workflow.rate_limits where key = 't_f_limit'), 'no bucket row');
    end if;
    -- Unthrottled tasks are unaffected: identical behaviour where no rate_key.
    if (select count(*) from workflow.tasks
        where run_id = v_run and status = 'ready' and rate_key is not null) <> 1 then
        raise exception 'the throttled task was consumed rather than left ready';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6a2. THE BUCKET'S OWN ARITHMETIC, WHICH NO CALLER COULD REACH.
--
-- try_consume_rate_limit tested admission against an UNCAPPED refill and then
-- wrote a CAPPED one, so the two disagreed for any amount larger than the
-- bucket: capacity 1, idle 100 seconds, consume 5 was ADMITTED and left the row
-- holding -4. A negative amount went the other way and minted 1000 tokens into
-- a bucket of 1.
--
-- Neither was reachable from a shipped caller -- claim_task and
-- rbac.attempt_login both consume exactly 1 against a capacity of 2 or more --
-- and that is the reason it is asserted here rather than assumed: a defect no
-- existing call site can express is one the NEXT call site finds. The
-- constraints on workflow.rate_limits are the half that cannot be bypassed by
-- a caller at all.
-- ---------------------------------------------------------------------
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('t_bucket', 1, 0, 1);

do $$
declare v_ok boolean;
begin
    -- Idle long enough to refill far past the ceiling, then ask for more than
    -- the ceiling. The refill is capped, so the answer is no.
    update workflow.rate_limits set updated_at = now() - interval '100 seconds'
     where key = 't_bucket';
    if workflow.try_consume_rate_limit('t_bucket', 5) then
        raise exception
            'a bucket of capacity 1 admitted 5 tokens after sitting idle -- the '
            'admission test and the write were reading different refills';
    end if;
    -- coalesced to -1 rather than compared bare: a missing bucket row makes the
    -- subquery NULL, `NULL < 0` is NULL, and `if NULL then` does not fire -- so
    -- the check passed in exactly the state that once made rbac.attempt_login
    -- refuse every user in the collection. Absence is a failure here, not a pass.
    if coalesce((select tokens from workflow.rate_limits where key = 't_bucket'), -1) < 0 then
        raise exception 'a refused consume still debited the bucket, to % '
                        '(null means the bucket row is gone entirely)',
            (select tokens from workflow.rate_limits where key = 't_bucket');
    end if;

    -- One token, which the same idle period does cover.
    update workflow.rate_limits set updated_at = now() - interval '100 seconds'
     where key = 't_bucket';
    if not workflow.try_consume_rate_limit('t_bucket', 1) then
        raise exception 'a full bucket refused a single token';
    end if;

    -- A bucket is not filled by asking it for a negative amount.
    begin
        v_ok := workflow.try_consume_rate_limit('t_bucket', -1000);
        raise exception 'a negative amount was accepted and minted tokens';
    exception when others then
        if sqlerrm like 'a negative amount%' then raise; end if;
    end;

    -- And the invariants are the table's, not the function's: every writer is
    -- refused, including one that never calls try_consume_rate_limit.
    begin
        insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
        values ('t_bucket_over', 1, 5, 1);
        raise exception 'a bucket holding more than its capacity was accepted';
    exception when check_violation then null;
    end;
    begin
        insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
        values ('t_bucket_neg', 1, -1, 1);
        raise exception 'a bucket holding a negative balance was accepted';
    exception when check_violation then null;
    end;
    begin
        insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
        values ('t_bucket_zero', 0, 0, 1);
        raise exception 'a bucket with no capacity was accepted -- it admits one '
                        'request per refill period while reading as "blocked"';
    exception when check_violation then null;
    end;
end $$;

-- ---------------------------------------------------------------------
-- 6b. AND BY claim_tasks, WHICH IS THE ONE THAT DID NOT.
--
-- §21b moved the bucket INTO claim_task so throttling stopped being something
-- a worker opts into. It left the BATCH claim as a bare UPDATE, so the same
-- defect survived one function along -- and claim_tasks is not a corner: it is
-- what spec.md §7 names as the throughput path, it is granted to `worker`, and
-- §11's first test recipe puts the token bucket and batching in one pipeline.
-- A worker that batched got every throttled task handed to it at once, which
-- is precisely the fan-out-at-a-regulator's-API failure §6 above is written
-- about, reached by the faster route.
--
-- The old notice on this file claimed "a throttle works with any worker". It
-- was true of the singular claim only, and the batch test in 06-recovery uses
-- a queue with no rate_key, so nothing contradicted it.
-- ---------------------------------------------------------------------
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('t_fb_limit', 2, 2, 0);

insert into workflow.definitions (name, spec) values
('t_fb_rate', '{"steps":[
  {"key":"a","kind":"work","queue":"t_brate","rate_key":"t_fb_limit"},
  {"key":"b","kind":"work","queue":"t_brate","rate_key":"t_fb_limit"},
  {"key":"c","kind":"work","queue":"t_brate","rate_key":"t_fb_limit"},
  {"key":"d","kind":"work","queue":"t_brate","rate_key":"t_fb_limit"}]}');

do $$
declare v_run uuid; v_n int; v_left int;
begin
    v_run := workflow.start_workflow('t_fb_rate', '{}'::jsonb);

    -- One call, asking for more than the bucket holds. The whole point of the
    -- batch API is that it is ONE round trip, so the throttle has to hold
    -- within a single call or it does not hold at all.
    select count(*) into v_n from workflow.claim_tasks('t_brate', 'batch-tester', 10);
    if v_n <> 2 then
        raise exception
            'claim_tasks handed out % of 4 tasks against a bucket of 2. The batch claim '
            'is the throughput path and ignored rate_key entirely -- a throttle that is '
            'bypassed by the API written for volume is bypassed exactly when it matters.',
            v_n;
    end if;

    if coalesce((select tokens from workflow.rate_limits where key = 't_fb_limit'), 99) >= 2 then
        raise exception 'the batch claim did not consume the bucket (tokens = %)',
            coalesce((select tokens::text from workflow.rate_limits where key = 't_fb_limit'), 'no bucket row');
    end if;

    -- The rest are LEFT READY, not consumed and not failed: a throttled task
    -- is one whose turn has not come, and the next claim after a refill takes
    -- it. Same contract claim_task has.
    select count(*) into v_left from workflow.tasks
     where run_id = v_run and status = 'ready';
    if v_left <> 2 then
        raise exception 'expected 2 tasks left ready after a throttled batch, found %', v_left;
    end if;

    -- And an empty bucket yields an empty batch rather than a partial one that
    -- looks like an empty queue.
    if (select count(*) from workflow.claim_tasks('t_brate', 'batch-tester-2', 10)) <> 0 then
        raise exception 'a spent bucket still handed out a batch';
    end if;
end $$;

-- The lookahead survives batching, which is the other half of §11's recipe: a
-- throttled source must not head-of-line-block an unrelated one, and a
-- lookahead the batch itself consumes is no lookahead at all -- which is why
-- claim_tasks adds it to the batch size rather than sharing it.
insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
values ('t_fb_spent', 1, 0, 0);

insert into workflow.definitions (name, spec) values
('t_fb_mixed', '{"steps":[
  {"key":"blocked","kind":"work","queue":"t_bmix","rate_key":"t_fb_spent"},
  {"key":"free","kind":"work","queue":"t_bmix"}]}');

do $$
declare v_rows text[];
begin
    perform workflow.start_workflow('t_fb_mixed', '{}'::jsonb);
    select array_agg(step_key order by step_key) into v_rows
      from workflow.claim_tasks('t_bmix', 'batch-tester', 10);
    if v_rows is distinct from array['free'] then
        raise exception
            'a batch behind a throttled task returned % -- one spent bucket must not '
            'stall an unrelated task sharing the queue', coalesce(v_rows::text, 'nothing');
    end if;
    raise notice 'workflow/05: claim_task AND claim_tasks consume the rate key, so a '
                 'throttle works with any worker, batched or not';
    raise notice 'workflow/05: the bucket never admits over its capacity and never holds '
                 'more than it -- enforced by a constraint, not by the callers that exist';
end $$;

-- ---------------------------------------------------------------------
-- 7. Timers and sub-workflows (21g/21i), neither of which had ever executed.
--
-- start_child_workflow inserted a run row and NEVER EXPANDED THE CHILD'S TASK
-- GRAPH, so a child had zero tasks, nothing called check_run_completion for
-- it, and the parent waited forever on a run that would never finish.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_f_child', '{"steps":[{"key":"inner","kind":"sql","queue":"none",
  "input":{"function":"t_f_note","args":["CHILD"]}}]}');
insert into workflow.definitions (name, spec) values
('t_f_parent', '{"steps":[
  {"key":"call","kind":"sub_workflow","queue":"none","input":{"workflow":"t_f_child"}},
  {"key":"after","kind":"sql","queue":"none","depends_on":["call"],
   "input":{"function":"t_f_note","args":["AFTER"]}}]}');

do $$
declare v_run uuid; v_child uuid;
begin
    delete from t_f_ledger;
    v_run := workflow.start_workflow('t_f_parent', '{}'::jsonb);

    select child_run_id into v_child from workflow.tasks
    where run_id = v_run and step_key = 'call';
    if v_child is null then
        raise exception 'the sub_workflow step never started a child run';
    end if;
    if (select count(*) from workflow.tasks where run_id = v_child) = 0 then
        raise exception
            'the child run has no tasks -- start_child_workflow inserted a run row without '
            'expanding its graph, so composition could never have worked';
    end if;
    if (select status from workflow.runs where id = v_child) is distinct from 'succeeded' then
        raise exception 'the child run did not complete: %',
            (select status from workflow.runs where id = v_child);
    end if;
    -- The child of only in-database steps finishes INSIDE start_workflow,
    -- before the parent link exists -- so the parent has to be resolved
    -- explicitly or it waits forever on a run that is already over.
    if (select status from workflow.tasks where run_id = v_run and step_key = 'call') is distinct from 'succeeded' then
        raise exception 'the parent was not resolved by its already-finished child';
    end if;
    if (select string_agg(action, ',' order by seq) from t_f_ledger) is distinct from 'CHILD,AFTER' then
        raise exception 'the sub-workflow did not run before its dependant: %',
            (select string_agg(action, ',' order by seq) from t_f_ledger);
    end if;
end $$;

-- A timer's delay is measured from READINESS, not from the start of the run.
-- "Wait 30s after the fetch" is not "start 30s after the run began".
insert into workflow.definitions (name, spec) values
('t_f_timer', '{"steps":[
  {"key":"first","kind":"sql","queue":"none","input":{"function":"t_f_note","args":["FIRST"]}},
  {"key":"wait","kind":"timer","queue":"none","depends_on":["first"],
   "input":{"delay_seconds":30}}]}');

do $$
declare v_run uuid; v_after timestamptz; v_created timestamptz;
begin
    v_run := workflow.start_workflow('t_f_timer', '{}'::jsonb);
    select run_after, created_at into v_after, v_created from workflow.tasks
    where run_id = v_run and step_key = 'wait';

    -- Before either comparison, because both are two-valued: with no `wait` task
    -- at all v_after is NULL, neither `<=` nor `<` fires, and the pair reads
    -- green for a timer that was never created.
    if v_after is null then
        raise exception 'there is no wait task, so its delay cannot be checked';
    end if;
    if v_after <= clock_timestamp() then
        raise exception 'the timer is already due -- its delay was never applied';
    end if;
    if v_after < v_created + interval '25 seconds' then
        raise exception 'the timer delay is short: run_after is only % after creation',
            v_after - v_created;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. Reported by someone building an 18-task pipeline (22a-22d).
-- ---------------------------------------------------------------------

-- The run could not see itself. {{run.*}} read only the run INPUT, so runs.id
-- was unreachable -- and could not be passed in either, because the caller does
-- not know it until start_workflow returns.
do $$
declare v_run uuid; v_err text;
begin
    v_run := workflow.start_workflow('t_f_encode', '{"id":"CALLER-SUPPLIED"}'::jsonb);

    if (workflow.resolve_args('["{{run.$id}}"]'::jsonb, v_run)->>0) <> v_run::text then
        raise exception '{{run.$id}} does not resolve to the run''s own id';
    end if;
    -- ...and a caller's own input key named `id` is NOT shadowed, which is the
    -- whole reason the prefix is reserved.
    if (workflow.resolve_args('["{{run.id}}"]'::jsonb, v_run)->>0) <> 'CALLER-SUPPLIED' then
        raise exception 'the reserved prefix shadowed an ordinary input key';
    end if;

    -- The natural thing to type teaches, rather than resolving to nothing and
    -- failing eight tasks later.
    begin
        perform workflow.resolve_args('["{{run.trace_id}}"]'::jsonb, v_run);
        raise exception '{{run.trace_id}} resolved against an absent input key';
    exception when others then v_err := sqlerrm;
    end;
    if v_err not like '%{{run.$trace_id}}%' then
        raise exception 'the error does not say what to write instead: %', v_err;
    end if;
end $$;

-- The same fix, in the half the worker resolves. The shipped worker's template
-- pattern does not admit `$`, so {{run.$id}} worked in a sql step and was sent
-- as a LITERAL in a rest step -- a session threaded that way looks exactly like
-- success. The engine binds it before dispatch, as it does {{item.*}}.
do $$
declare v_run uuid; v_task uuid; v_ctx jsonb;
begin
    insert into workflow.definitions (name, spec) values
    ('t_f_meta', '{"steps":[{"key":"call","kind":"http_call","queue":"t",
      "input":{"url":"http://x/{{run.$id}}","body":{"session":"{{run.$session}}"}}}]}');
    v_run := workflow.start_workflow('t_f_meta', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'call';

    update workflow.tasks set status='running', claimed_by='tester' where id = v_task;
    v_ctx := workflow.get_task_context(v_task, 'tester');

    if v_ctx#>>'{task_input,url}' <> 'http://x/' || v_run::text then
        raise exception
            'run metadata was not bound before dispatch: % -- a worker that cannot parse '
            'the namespace would send this literally', v_ctx#>>'{task_input,url}';
    end if;
    if v_ctx#>>'{task_input,body,session}' !~ '^[0-9a-f-]{36}$' then
        raise exception 'the engine-minted session was not bound: %',
            v_ctx#>>'{task_input,body,session}';
    end if;
end $$;

-- One session per (run, group): steps naming the same group share a
-- conversation, two groups are two threads, and both are stable for the run.
do $$
declare v_run uuid;
begin
    v_run := workflow.start_workflow('t_f_encode', '{}'::jsonb);
    if workflow.run_session(v_run,'a') = workflow.run_session(v_run,'b') then
        raise exception 'two session groups in one run collided';
    end if;
    if workflow.run_session(v_run,'a') <> workflow.run_session(v_run,'a') then
        raise exception 'a session id is not stable within a run';
    end if;
end $$;

-- Registration checked the CALLER's privileges while the function runs as the
-- DEFINER's, so registering as a superuser always succeeded and every
-- invocation failed with "permission denied for schema ..." -- naming the
-- schema rather than the registration.
--
-- This file runs AS the definer, so an unreachable schema trips
-- to_regprocedure before the definer check is reached -- both paths refuse, and
-- only the caller-is-not-definer path (registering as a superuser, which sees
-- everything) produces the definer-specific message. What is asserted here is
-- the property that matters either way: registration REFUSES rather than
-- succeeding and failing per-task at runtime. The message itself is asserted by
-- the source check below, which does not depend on who is running.
do $$
declare v_err text; v_def text;
begin
    create schema t_f_unreachable;
    create function t_f_unreachable.f() returns jsonb as $x$ select '{}'::jsonb $x$ language sql;
    revoke all on schema t_f_unreachable from public;
    execute format('revoke all on schema t_f_unreachable from %I',
        (select pg_get_userbyid(proowner) from pg_proc
         where oid = to_regprocedure('workflow.execute_sql_step(uuid)')));

    begin
        perform workflow.register_step_function('t_f_unreach','t_f_unreachable.f','{}');
        raise exception
            'an unreachable function REGISTERED. It would fail on every invocation with '
            '"permission denied for schema ...", naming the schema rather than the '
            'registration, with nothing pointing back here.';
    exception when others then v_err := sqlerrm;
    end;
    if v_err not like '%t_f_unreachable%' then
        raise exception 'the refusal does not name the schema: %', v_err;
    end if;

    -- The check keys off the role that will EXECUTE, not the caller --
    -- to_regprocedure resolves with the caller's privileges, which is why
    -- registering as a superuser used to succeed and tell you nothing.
    --
    -- Read from the TRIGGER function, which is where these checks live. They
    -- used to be in register_step_function's body and this assertion used to
    -- read them there; both moved together when the rule was pushed down onto
    -- the table. If they ever move back, §a below fails first and louder.
    v_def := pg_get_functiondef(
        to_regprocedure('workflow.step_function_is_runnable()')::oid);
    if v_def not like '%has_schema_privilege%' or v_def not like '%execute_sql_step%' then
        raise exception
            'the step_functions trigger no longer checks the definer''s reach -- it is back '
            'to verifying only that the function exists, for whoever happens to be calling';
    end if;
    if v_def not like '%grant usage on schema%' then
        raise exception 'the refusal no longer says what to grant';
    end if;
end $$;

-- ...and a function the definer CAN reach still registers.
do $$
begin
    perform workflow.register_step_function('t_f_ok','t_f_echo','{text}');
end $$;

-- §a. THE TABLE REFUSES, not just the function that writes it.
--
-- Everything above calls register_step_function(). That was the whole gap:
-- the validation was the rule for CALLING THAT FUNCTION, and step_functions is
-- the table that decides what a workflow may cause to run, so a plain insert
-- put an unrunnable row into it and said INSERT 0 1. Found by walking
-- journey J2 -- reading the table before the documentation produced two
-- broken registry rows inside a minute, by accident, on the first try.
--
-- Asserted BEHAVIOURALLY rather than by reading source: the property is "this
-- table cannot hold a row naming something that will not run", and a trigger
-- that exists but is disabled, or attached for the wrong events, satisfies
-- every source check and none of this.
-- A NOTE ON THE SHAPE BELOW, because the first version of it was wrong and the
-- mutation test is what said so. Each case used to raise its own failure
-- message from INSIDE the `begin ... exception` block, and two of those
-- messages contained the phrase "does not exist" -- which is the phrase the
-- following `if v_err not like ...` greps for. So when the guard was removed
-- and the write SUCCEEDED, the failure raise was caught by the same handler,
-- its text satisfied the grep, and the case passed. Two of the three cases
-- could not fail. Found by deleting the trigger and watching only case 5 go
-- red; the repo's own gate for this is "no assertion passes because its
-- subject is missing", and this was the same defect one level in.
--
-- So the write's SUCCESS is recorded in a flag and judged outside the handler,
-- where no message can be mistaken for a refusal.
do $$
declare v_err text; v_n int; v_allowed boolean;
begin
    -- 1. a function that does not exist, straight into the table
    v_allowed := false;
    begin
        insert into workflow.step_functions (name, fn, arg_types)
        values ('t_f_ghost', 'journey.no_such_function', '{}');
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'a bare INSERT put an unrunnable row into step_functions. The registry is '
            'the answer to "what can a workflow cause to run" and it just accepted a '
            'function with no such name.';
    end if;
    if v_err not like '%does not exist%' then
        raise exception 'the refusal does not say the function is missing: %', v_err;
    end if;

    -- 2. the unreachable schema from above, by the same door
    v_allowed := false;
    begin
        insert into workflow.step_functions (name, fn, arg_types)
        values ('t_f_ghost2', 't_f_unreachable.f', '{}');
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'a bare INSERT registered a function the executor cannot reach -- it would '
            'fail on every invocation with "permission denied for schema ..."';
    end if;
    if v_err not like '%t_f_unreachable%' then
        raise exception 'the refusal does not name the schema: %', v_err;
    end if;

    -- 3. UPDATE too, which is the half a before-insert-only trigger misses:
    --    point a good row at a function that does not exist.
    v_allowed := false;
    begin
        update workflow.step_functions set fn = 'journey.no_such_function'
        where name = 't_f_ok';
        v_allowed := true;
    exception when others then v_err := sqlerrm;
    end;
    if v_allowed then
        raise exception
            'an UPDATE re-pointed a registered name at a function with no such name. '
            'The row was checked when it was written and never again.';
    end if;
    if v_err not like '%does not exist%' then
        raise exception 'the update refusal does not say the function is missing: %', v_err;
    end if;

    -- 4. and nothing above left a row behind
    select count(*) into v_n from workflow.step_functions
    where name in ('t_f_ghost','t_f_ghost2');
    if v_n <> 0 then
        raise exception '% refused row(s) are in the registry anyway', v_n;
    end if;

    -- 5. the trigger is ENABLED and fires for both events. A disabled trigger
    --    (tgenabled = 'D') passes every check above only because the raises
    --    above happen to be doing the work; assert the catalog directly so a
    --    later ALTER ... DISABLE TRIGGER cannot pass quietly.
    if not exists (
        select 1 from pg_trigger
        where tgrelid = 'workflow.step_functions'::regclass
          and tgname  = 'step_function_is_runnable'
          and tgenabled <> 'D'
          and (tgtype & 4) <> 0    -- INSERT
          and (tgtype & 16) <> 0   -- UPDATE
          and (tgtype & 2) <> 0    -- BEFORE
    ) then
        raise exception
            'the step_functions guard is not a live BEFORE INSERT OR UPDATE trigger';
    end if;
end $$;

-- The two halves can ship out of step, and the error describes the wrong
-- problem when they do. The probe reports what the installed compiler ACCEPTS,
-- not what it is supposed to.
do $$
declare v_caps jsonb;
begin
    v_caps := workflow.compiler_capabilities();
    if not (v_caps ? 'available') then
        raise exception 'compiler_capabilities returned nothing usable';
    end if;
    if (v_caps->>'available')::boolean then
        if not (v_caps->'accepts' ? 'matrix') or not (v_caps->'accepts' ? 'signal') then
            raise exception 'the probe does not cover the features that skewed';
        end if;
        -- "it compiled" is not evidence a feature exists: a deserialiser drops
        -- unknown keys silently. output_schema is therefore probed by checking
        -- the EMITTED SPEC, and this asserts the probe still does that.
        if not (v_caps->'accepts' ? 'output_schema') then
            raise exception 'output_schema is not probed at all';
        end if;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 9. A feature the compiler cannot emit must not compile CLEAN (22c).
--
-- The first version of the skew check ran only when compilation FAILED, which
-- caught every missing step KIND -- those fail loudly -- and missed the one
-- that matters most. `output_schema` is not a step kind, so a compiler that has
-- never heard of it drops the key, the document compiles clean, and the
-- declared contract simply is not there at runtime. An author who writes a
-- contract and gets a green run reasonably concludes it is enforced.
-- ---------------------------------------------------------------------
do $$
declare v_caps jsonb; v_missing text; v_yaml text; v_err text; v_ok boolean;
begin
    v_caps := workflow.compiler_capabilities();
    if not (v_caps->>'available')::boolean then
        raise notice 'workflow/05: no compiler installed -- skew check not applicable';
        return;
    end if;

    -- Pick something this build genuinely cannot emit. On a current build there
    -- is nothing missing and the assertion is vacuous, which is correct: the
    -- check exists for the skewed case.
    select f into v_missing from jsonb_array_elements_text(v_caps->'missing') f limit 1;
    if v_missing is null then
        raise notice 'workflow/05: compiler is current -- nothing to skew against';
        return;
    end if;

    v_yaml := E'name: t_skew\nsteps:\n  - id: a\n    rest: {url: http://x}\n    '
              || v_missing || E': {}';
    execute 'select coalesce((p8_compile_workflow($1)->>''ok'')::boolean,false)'
        into v_ok using v_yaml;

    begin
        perform workflow.define_yaml(v_yaml);
        raise exception
            'define_yaml accepted a document declaring %, which this build cannot emit. '
            'compiled_clean=% -- a silently dropped contract is worse than an unsupported '
            'feature, because nothing anywhere says so.', v_missing, v_ok;
    exception when others then
        v_err := sqlerrm;
    end;

    if v_err not like '%version skew%' then
        raise exception 'the refusal does not name it as skew: %', v_err;
    end if;
    -- And when it compiled clean, the message has to say THAT -- otherwise it
    -- reads as a syntax complaint about a document whose syntax is fine.
    if v_ok and v_err not like '%COMPILED CLEAN%' then
        raise exception
            'a silently-dropped feature was reported as if the compiler had rejected it: %',
            v_err;
    end if;
end $$;

-- The reporter's other note, generalised: the run-namespace logic must live in
-- exactly ONE place, or a fix to it lands in one arity and not the other.
do $$
begin
    if pg_get_functiondef(to_regprocedure('workflow.resolve_args(jsonb,uuid)')::oid)
       not like '%resolve_args(p_args, p_run_id, null::jsonb)%' then
        raise exception
            'resolve_args(jsonb,uuid) has its own copy of the namespace logic again. Two '
            'copies means a fix lands in one arity and not the other -- which is exactly '
            'how {{run.id}} stayed broken in half the engine.';
    end if;
end $$;

rollback;

do $$ begin
    raise notice 'workflow/05: a double-encoded output is repaired AND recorded, so the contract can be enforced';
    raise notice 'workflow/05: a declared output shape is checked, and a violation retries -- the one place retry is right';
    raise notice 'workflow/05: a tolerated child failure satisfies its dependent; below min_success the aggregate is cancelled, not run';
    raise notice 'workflow/05: saga compensations stay out of the forward graph, trigger themselves, run as their declared kind, in reverse';
    raise notice 'workflow/05: a cancelled run is not an idempotent hit, and no work lands under one';
    raise notice 'workflow/05: sub-workflows expand and resolve their parent; a timer counts from readiness';
    raise notice 'workflow/05: a run can see itself via {{run.$*}}, in both resolvers, without shadowing caller input';
    raise notice 'workflow/05: registration checks the role that will EXECUTE, and says what to grant';
    raise notice 'workflow/05: the installed compiler is probed, so version skew reads as skew and not as bad syntax';
    raise notice 'workflow/05: a feature the compiler cannot emit is refused even when it compiles CLEAN';
    raise notice 'workflow/05: the run-namespace logic lives in exactly one place';
end $$;
