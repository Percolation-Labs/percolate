-- MATRIX FAN-OUT -- the work to do is a query result, and the parent cannot
-- be done while its children are missing.
--
-- `schema.sql` §20. Two things here are worth more than the rest, because
-- both are failures that report success:
--
--   1. THE FAN-IN. The design note this section was built from claimed the
--      AND-join was free -- "pending_deps already does it". It does not: a
--      successor's one edge points at the MATRIX task, which completes at
--      expansion time, so an aggregate over the fan-out would fire instantly
--      over nothing and the run would report `completed`. §3 below is the
--      assertion that would have caught that.
--   2. THE CONTEXT WRITE. A fan-out child that wrote into runs.context would
--      work perfectly on three children and quietly turn the hottest column
--      in the schema quadratic on five thousand. §2 asserts the absence.
--
-- Everything is driven in-database. No worker runs; `work` children are
-- completed by calling complete_task directly, which is exactly what a worker
-- would do.

\set ON_ERROR_STOP on

begin;

set local role app_owner;

-- ---------------------------------------------------------------------
-- Fixture: a watchlist, and the registered function that turns it into a
-- row set. Matrix rows come from the allow-list, never from inline SQL --
-- expansion is SECURITY DEFINER, so a step that could supply a statement
-- would be a privilege-escalation primitive with a YAML front end.
-- ---------------------------------------------------------------------
create table t_mx_watchlist (cik text, concept text, tier int);
insert into t_mx_watchlist values
    ('0000320193', 'Revenues', 1),
    ('0000789019', 'Revenues', 1),
    ('0001018724', 'Revenues', 1),
    ('0000051143', 'Revenues', 2);

create function t_mx_rows(p_tier text) returns jsonb as $fn$
    select coalesce(jsonb_agg(jsonb_build_object('cik', cik, 'concept', concept)
                              order by cik), '[]'::jsonb)
    from t_mx_watchlist where tier = p_tier::int;
$fn$ language sql stable;

create function t_mx_none() returns jsonb as $fn$ select '[]'::jsonb $fn$ language sql stable;

create function t_mx_echo(p_cik text) returns jsonb as $fn$
    select jsonb_build_object('saw', p_cik);
$fn$ language sql stable;

select workflow.register_step_function('t_mx_rows', 't_mx_rows', '{text}');
select workflow.register_step_function('t_mx_none', 't_mx_none', '{}');
select workflow.register_step_function('t_mx_echo', 't_mx_echo', '{text}');

-- ---------------------------------------------------------------------
-- 1. Expansion. Three tier-1 rows become three tasks, from one SELECT, with
--    nothing deployed -- start_workflow returns with the fan-out already
--    materialised.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_mx_fan', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"t", "input":{
        "rows":       {"function":"t_mx_rows", "args":["1"]},
        "max_fanout": 100,
        "template":   {"queue":"t-fetch", "kind":"work",
                       "input":{"url":"https://data.sec.gov/CIK{{item.cik}}/{{item.concept}}"}}}},
    {"key":"rollup", "kind":"work", "queue":"t", "depends_on":["fan"]}
 ]}');

do $$
declare
    v_run   uuid;
    v_fan   workflow.tasks;
    v_kids  int;
    v_first workflow.tasks;
begin
    v_run := workflow.start_workflow('t_mx_fan', '{}'::jsonb);

    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';
    if v_fan.status <> 'done' then
        raise exception 'matrix step did not expand on start: status %', v_fan.status;
    end if;

    select count(*) into v_kids from workflow.tasks where matrix_parent_id = v_fan.id;
    if v_kids <> 3 then
        raise exception 'expected 3 children from 3 tier-1 rows, got %', v_kids;
    end if;

    -- The parent cannot be done while its children are missing: they are
    -- inserted by the statement that completes it. There is no window.
    if v_fan.completed_at is null then
        raise exception 'matrix task is done with no completed_at';
    end if;

    -- Children are keyed by index, take the template's queue and kind, and
    -- carry their row verbatim.
    select * into v_first from workflow.tasks
    where matrix_parent_id = v_fan.id and step_key = 'fan[0]';
    if v_first.id is null then
        raise exception 'children are not keyed <step>[<i>]';
    end if;
    if v_first.queue <> 't-fetch' or v_first.kind <> 'work' then
        raise exception 'child did not take the template queue/kind: %/%',
            v_first.queue, v_first.kind;
    end if;
    if v_first.input->'item'->>'cik' <> '0000320193' then
        raise exception 'child does not carry its row: %', v_first.input->'item';
    end if;

    -- THE TEMPLATE IS SUBSTITUTED HERE, AND THIS ASSERTION USED TO SAY THE
    -- OPPOSITE. It required {{item.cik}} to survive to dispatch, on the
    -- argument that pre-substituting makes the recorded input a lie. Then a
    -- real fan-out of `rest:` steps against SEC EDGAR failed on all six
    -- children with the WORKER's error -- `unknown template namespace 'item'
    -- ... expected steps, run or env` -- because deferring had quietly put
    -- `item` into the contract of a shipped worker image that knows three
    -- namespaces. The headline case for the whole feature did not work, and
    -- only `sql` children had ever been exercised.
    --
    -- The reversal is also right on the merits: the "recorded input is a lie"
    -- objection is about a stored DEFINITION shared across runs. A fan-out
    -- child exists for exactly one row, so substituting that row makes its
    -- recorded input say precisely what will be sent.
    if v_first.input->>'url' <> 'https://data.sec.gov/CIK0000320193/Revenues' then
        raise exception
            'the row was not substituted into the template: %. A worker must never need '
            'to know a task came from a fan-out.', v_first.input->>'url';
    end if;
    -- ...and the row is STILL recorded verbatim, because it is the snapshot
    -- §20's determinism guard turns on and a sql child wants it typed.
    if v_first.input->'item'->>'concept' <> 'Revenues' then
        raise exception 'substitution dropped the recorded row';
    end if;

    -- Every child is ready with no worker involved.
    if exists (select 1 from workflow.tasks
               where matrix_parent_id = v_fan.id and status <> 'ready') then
        raise exception 'a fan-out child was not left ready';
    end if;

    -- The recorded row set reads back in expansion order. Queried directly
    -- rather than through workflow.matrix_rows(), which is authorized against
    -- the caller's identity (see below) and this test has none.
    if (select jsonb_agg(t.input->'item' order by t.created_at, t.step_key)
        from workflow.tasks t where t.matrix_parent_id = v_fan.id)
       is distinct from '[{"cik":"0000320193","concept":"Revenues"},
            {"cik":"0000789019","concept":"Revenues"},
            {"cik":"0001018724","concept":"Revenues"}]'::jsonb then
        raise exception 'the children do not hold the recorded snapshot in order';
    end if;
end $$;

-- matrix_rows() returns a run's input data and is granted to `authenticated`,
-- so by integration-rbac.sql's own rule -- every SECURITY DEFINER function
-- reachable by an end user does its own authorization check -- it must not
-- trust the task id it is handed. Asserted the same way 01-quiet-failures
-- asserts it for cancel_run: the check is a property of the shipped
-- definition, not of one call.
--
-- Skipped when the engine is installed standalone, where rbac does not exist
-- and schema.sql's unchecked definition is the right one.
do $$
begin
    if to_regprocedure('workflow.assert_run_access(uuid,text)') is null then
        raise notice 'workflow/04: rbac not installed -- matrix_rows authz check not applicable';
        return;
    end if;
    -- Asserted by CALLING it, not by reading its source for the string
    -- 'assert_run_access'. A source check catches the guard being deleted and
    -- not the guard being wrong, which is the failure assert_run_access
    -- actually had twice (the engine acting with no identity; unowned
    -- scheduled runs). Same conversion as 06-recovery §7/§8.
    declare
        v_run uuid; v_matrix uuid; v_owner uuid; v_stranger uuid; v_rows jsonb;
    begin
        -- Its own definition, not t_mx_fan: the sections below count children
        -- and pending_deps across runs of the same definition, so borrowing
        -- one would make this check quietly break those.
        insert into workflow.definitions (name, spec) values
        ('t_mx_authz', '{"steps":[
            {"key":"fan", "kind":"matrix", "queue":"tz", "input":{
                "rows":{"function":"t_mx_rows", "args":["1"]}, "max_fanout":10,
                "template":{"queue":"tz-fetch", "kind":"work"}}}
         ]}');
        v_owner    := gen_random_uuid();
        v_stranger := gen_random_uuid();
        insert into rbac.users (id, email) values
            (v_owner,    'matrix-owner@test.com'),
            (v_stranger, 'matrix-stranger@test.com');

        v_run := workflow.start_workflow('t_mx_authz', '{}'::jsonb, 'authz-rows');
        update workflow.runs set owner_id = v_owner where id = v_run;
        select id into v_matrix from workflow.tasks
        where run_id = v_run and step_key = 'fan';

        -- The owner reads their own fan-out.
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_owner::text)::text, true);
        v_rows := workflow.matrix_rows(v_matrix);
        if jsonb_array_length(v_rows) = 0 then
            raise exception 'the owner cannot read their own recorded row set';
        end if;

        -- A stranger holding the same task id must not.
        perform set_config('request.jwt.claims',
            json_build_object('sub', v_stranger::text)::text, true);
        begin
            perform workflow.matrix_rows(v_matrix);
            perform set_config('request.jwt.claims', '', true);
            raise exception 'TENANT LEAK: a stranger holding a task id read another '
                            'run''s recorded row set';
        exception when others then
            perform set_config('request.jwt.claims', '', true);
            if sqlerrm like 'TENANT LEAK%' then raise; end if;
        end;
        raise notice 'workflow/04: matrix_rows is authorized by calling it -- the owner '
                     'reads the row set and a stranger with the same task id cannot';
    end;
end $$;

-- ---------------------------------------------------------------------
-- 2. The digest is in context; the rows and the children's outputs are not.
-- ---------------------------------------------------------------------
do $$
declare
    v_run uuid;
    v_ctx jsonb;
begin
    select r.id, r.context into v_run, v_ctx from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 't_mx_fan' order by r.created_at desc limit 1;

    -- Under `result`, like every other kind. A bare object here broke
    -- {{steps.<id>.result}} on exactly one step kind, and the first fan-in
    -- written against this feature failed with 'resolved to nothing'.
    if (v_ctx#>>'{fan,result,fanout}')::int <> 3 then
        raise exception '{{steps.fan.result.fanout}} is not readable downstream: %', v_ctx;
    end if;
    if v_ctx#>>'{fan,result,rows_hash}' is null then
        raise exception 'the matrix task recorded no row-set digest';
    end if;
    -- And the handle, without which a successor cannot reach its siblings.
    if (v_ctx#>>'{fan,result,task_id}') is null then
        raise exception
            'the matrix output carries no task_id -- a successor would know how many '
            'children there were and have no way to find them';
    end if;

    -- Complete one child the way a worker would, then check context again.
    perform workflow.complete_task(
        (select id from workflow.tasks where run_id = v_run and step_key = 'fan[0]'),
        '{"result": "ok"}'::jsonb);

    select context into v_ctx from workflow.runs where id = v_run;
    if v_ctx ? 'fan[0]' then
        raise exception
            'a fan-out child wrote into runs.context. That column is rewritten in full '
            'on every completion, so N children make it N rewrites of a value that grows '
            'to N outputs -- quadratic write amplification on the hottest path here.';
    end if;

    -- ...but the output is on the child's own row, where a `sql` successor
    -- can aggregate over it in one statement.
    if (select output->>'result' from workflow.tasks
        where run_id = v_run and step_key = 'fan[0]') is distinct from 'ok' then
        raise exception 'the child output was not recorded on the child';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. THE FAN-IN. This is the assertion the whole section exists for.
--
-- `rollup` declares depends_on: [fan]. If expansion only inserted children
-- and completed the parent, rollup's single edge would be satisfied and it
-- would already be ready -- an aggregate running over one of three results,
-- in a run that reports success. Expansion rewires it onto the children, so
-- it waits for all of them and not one moment less.
-- ---------------------------------------------------------------------
do $$
declare
    v_run    uuid;
    v_rollup workflow.tasks;
    v_kid    uuid;
begin
    select r.id into v_run from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 't_mx_fan' order by r.created_at desc limit 1;

    select * into v_rollup from workflow.tasks where run_id = v_run and step_key = 'rollup';

    -- One child (fan[0]) was completed in §2, so two remain.
    if v_rollup.status <> 'pending' or v_rollup.pending_deps <> 2 then
        raise exception
            'rollup is %/pending_deps=% after 1 of 3 children -- expected pending/2. '
            'The AND-join over a fan-out is NOT free: a successor edge points at the '
            'matrix task, which completes at expansion time.',
            v_rollup.status, v_rollup.pending_deps;
    end if;

    -- It has an edge to the matrix task AND to each of the three children.
    if (select count(*) from workflow.task_dependencies where task_id = v_rollup.id) <> 4 then
        raise exception 'rollup should depend on the matrix task plus all 3 children';
    end if;

    -- Second child: still not enough.
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[1]';
    perform workflow.complete_task(v_kid, '{"result":"ok"}'::jsonb);
    if (select status from workflow.tasks where id = v_rollup.id) is distinct from 'pending' then
        raise exception 'rollup released before every child finished';
    end if;

    -- Third: now.
    select id into v_kid from workflow.tasks where run_id = v_run and step_key = 'fan[2]';
    perform workflow.complete_task(v_kid, '{"result":"ok"}'::jsonb);
    if (select status from workflow.tasks where id = v_rollup.id) is distinct from 'ready' then
        raise exception 'rollup did not become ready once the fan-out drained: %',
            (select status from workflow.tasks where id = v_rollup.id);
    end if;

    -- And the run is not complete while rollup is outstanding.
    if (select status from workflow.runs where id = v_run) is distinct from 'running' then
        raise exception 'the run reported completion with rollup still to do';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. An empty row set is an answer, not an incident.
--
-- "Nothing has changed since last time" is the normal state of a polling
-- pipeline. A matrix that failed on zero rows would make it an outage.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_mx_empty', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"t", "input":{
        "rows":{"function":"t_mx_none"}, "max_fanout":10,
        "template":{"queue":"t-fetch", "kind":"work"}}},
    {"key":"rollup", "kind":"work", "queue":"t", "depends_on":["fan"]}
 ]}');

do $$
declare v_run uuid; v_st text;
begin
    v_run := workflow.start_workflow('t_mx_empty', '{}'::jsonb);
    if (select count(*) from workflow.tasks t
        join workflow.tasks m on m.id = t.matrix_parent_id
        where m.run_id = v_run) <> 0 then
        raise exception 'an empty matrix created children';
    end if;
    select status into v_st from workflow.tasks where run_id = v_run and step_key = 'rollup';
    if v_st <> 'ready' then
        raise exception 'an empty matrix must release its successor immediately, got %', v_st;
    end if;
    if (select (context#>>'{fan,result,fanout}')::int from workflow.runs where id = v_run) is distinct from 0 then
        raise exception 'an empty matrix did not record fanout 0';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. max_fanout refuses, and refuses BEFORE any child exists.
--
-- The obvious way to hurt yourself with this feature is a cross join with a
-- forgotten WHERE, which inserts the cartesian product as task rows. The
-- ceiling has to fail the task rather than the database.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_mx_cap', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"t", "input":{
        "rows":{"function":"t_mx_rows", "args":["1"]}, "max_fanout":2,
        "template":{"queue":"t-fetch", "kind":"work"}}},
    {"key":"rollup", "kind":"work", "queue":"t", "depends_on":["fan"]}
 ]}');

do $$
declare v_run uuid; v_fan workflow.tasks;
begin
    v_run := workflow.start_workflow('t_mx_cap', '{}'::jsonb);
    select * into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    if v_fan.status <> 'failed' then
        raise exception 'a matrix over its ceiling did not fail: %', v_fan.status;
    end if;
    if v_fan.error->>'error' not like '%max_fanout%' then
        raise exception 'the failure does not name max_fanout: %', v_fan.error;
    end if;
    if exists (select 1 from workflow.tasks where matrix_parent_id = v_fan.id) then
        raise exception 'children were inserted before the ceiling was checked';
    end if;
    -- Terminal, not retried: it will fail identically on every attempt, and
    -- retrying it five times with backoff turns a fast failure into a slow one.
    if v_fan.attempts <> 1 then
        raise exception 'a blown ceiling was retried (% attempts)', v_fan.attempts;
    end if;
    if (select status from workflow.tasks where run_id = v_run and step_key = 'rollup')
       is distinct from 'cancelled' then
        raise exception 'the successor of a failed matrix was not cancelled';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. {{item.*}} resolves at dispatch, in a `sql` child -- so a whole fan-out
--    can run with no process anywhere.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_mx_sql', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"t", "input":{
        "items":[{"cik":"AAA"},{"cik":"BBB"}], "max_fanout":10,
        "template":{"queue":"t-sql", "kind":"sql",
                    "input":{"function":"t_mx_echo", "args":["{{item.cik}}"]}}}}
 ]}');

do $$
declare v_run uuid; v_outs text;
begin
    v_run := workflow.start_workflow('t_mx_sql', '{}'::jsonb);

    -- A `sql` child is INSERTED ready, and the autorun trigger only fires on
    -- a transition INTO ready -- so expansion has to kick them itself. It
    -- does, and the entire fan-out has already run by the time
    -- start_workflow returns.
    select string_agg(output#>>'{result,saw}', ',' order by step_key) into v_outs
    from workflow.tasks where run_id = v_run and kind = 'sql';

    if v_outs is distinct from 'AAA,BBB' then
        raise exception '{{item.*}} did not resolve in a sql child -- got %, tasks: %',
            coalesce(v_outs, '<null>'),
            (select jsonb_agg(jsonb_build_object('k',step_key,'s',status,'e',error))
             from workflow.tasks where run_id = v_run);
    end if;
    if (select status from workflow.runs where id = v_run) is distinct from 'completed' then
        raise exception 'a fan-out of sql steps did not complete with nothing deployed';
    end if;
end $$;

-- Naming {{item.*}} where there is no row is an authoring error with its own
-- message -- not "the row had no such column", which needs a different fix.
do $$
declare v_run uuid; v_err text;
begin
    select r.id into v_run from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    where d.name = 't_mx_sql' order by r.created_at desc limit 1;
    begin
        perform workflow.resolve_args('["{{item.cik}}"]'::jsonb, v_run);
        raise exception '{{item.*}} resolved on a task with no row';
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err not like '%not a matrix fan-out child%' then
        raise exception 'wrong error for {{item.*}} outside a fan-out: %', v_err;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 7. Re-expansion against a changed world is refused by name.
--
-- A matrix is a decision task in §12's sense: its recorded row set is the
-- snapshot. The rows live on the children rather than in the parent's output
-- (5,000 of them do not fit in §7's payload cap), so the parent records a
-- digest -- which is all a determinism check needs.
-- ---------------------------------------------------------------------
do $$
declare v_run uuid; v_fan uuid; v_st text; v_err jsonb;
begin
    v_run := workflow.start_workflow('t_mx_fan', '{}'::jsonb, 't_mx_replay');
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    -- The watchlist changes, as watchlists do.
    insert into t_mx_watchlist values ('0000000001', 'Revenues', 1);

    -- Force a re-expansion the way a reaper would.
    update workflow.tasks set status = 'ready', run_after = now() where id = v_fan;

    select status, error into v_st, v_err from workflow.tasks where id = v_fan;
    if v_st <> 'failed' then
        raise exception 'a re-expansion over a changed row set was allowed: %', v_st;
    end if;
    if v_err->>'error' not like '%DIFFERENT row set%' then
        raise exception 'the refusal does not say what happened: %', v_err;
    end if;
    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan) <> 3 then
        raise exception 'the refused re-expansion still inserted children';
    end if;
end $$;

-- An IDENTICAL re-expansion is a no-op, not a failure -- that is what makes
-- the guard a determinism check rather than a one-shot latch.
do $$
declare v_run uuid; v_fan uuid;
begin
    delete from t_mx_watchlist where cik = '0000000001';
    v_run := workflow.start_workflow('t_mx_fan', '{}'::jsonb, 't_mx_replay2');
    select id into v_fan from workflow.tasks where run_id = v_run and step_key = 'fan';

    update workflow.tasks set status = 'ready', run_after = now() where id = v_fan;

    if (select status from workflow.tasks where id = v_fan) is distinct from 'done' then
        raise exception 'an identical re-expansion did not resolve as done: %',
            (select status from workflow.tasks where id = v_fan);
    end if;
    if (select count(*) from workflow.tasks where matrix_parent_id = v_fan) <> 3 then
        raise exception 'an identical re-expansion double-inserted children: %',
            (select count(*) from workflow.tasks where matrix_parent_id = v_fan);
    end if;
    -- And it did not double-count the successor's dependencies either.
    if (select pending_deps from workflow.tasks where run_id = v_run and step_key='rollup') is distinct from 3 then
        raise exception 'a re-expansion double-counted the fan-in: pending_deps=%',
            (select pending_deps from workflow.tasks where run_id = v_run and step_key='rollup');
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 8. What is refused at REGISTRATION, so it is never discovered as a stalled
--    run. Each of these is a spec that would otherwise look fine.
-- ---------------------------------------------------------------------
do $$
declare
    v_case record;
    v_err  text;
begin
    for v_case in
        select * from (values
            -- No ceiling: the cartesian-product footgun, caught at authoring
            -- time rather than at expansion time.
            ('{"steps":[{"key":"f","kind":"matrix","input":{
                "items":[], "template":{"queue":"q"}}}]}', 'max_fanout',
             'a matrix with no declared ceiling'),
            -- Two sources is a silent choice; one named error is better.
            ('{"steps":[{"key":"f","kind":"matrix","input":{
                "items":[], "rows":{"function":"t_mx_none"}, "max_fanout":5,
                "template":{"queue":"q"}}}]}', 'exactly one',
             'a matrix declaring both rows and items'),
            -- Nested fan-out: a child has no static successors to rewire, so
            -- the grandchildren would never be joined to anything and the run
            -- would report completion before they finished.
            ('{"steps":[{"key":"f","kind":"matrix","input":{
                "items":[], "max_fanout":5,
                "template":{"queue":"q","kind":"matrix"}}}]}', 'Nested fan-out',
             'a matrix templating another matrix'),
            -- The child key namespace must not be shadowable.
            ('{"steps":[{"key":"f","kind":"matrix","input":{
                "items":[], "max_fanout":5, "template":{"queue":"q"}}},
               {"key":"f[0]","kind":"work","depends_on":["f"]}]}', 'reserved',
             'a declared step key that shadows a child key')
        ) as t(spec, expect, why)
    loop
        v_err := null;
        begin
            insert into workflow.definitions (name, spec)
            values ('t_mx_bad_' || md5(v_case.spec), v_case.spec::jsonb);
        exception when others then
            v_err := sqlerrm;
        end;
        if v_err is null then
            raise exception 'REGISTERED a bad spec: %', v_case.why;
        end if;
        if v_err not like '%' || v_case.expect || '%' then
            raise exception 'wrong rejection for %: %', v_case.why, v_err;
        end if;
    end loop;
end $$;

-- ---------------------------------------------------------------------
-- 8b. Substitution: types, interpolation, and a typo that must not become a
--     404. Every case here comes from the EDGAR run that reversed the
--     dispatch-time decision.
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_err text;
begin
    v := workflow.substitute_item(
        '{"url":"https://x/CIK{{item.cik}}/{{item.concept}}.json",
          "n":"{{item.n}}", "obj":"{{item.nested}}", "lit":"untouched",
          "keep":"{{run.tier}}", "arr":["{{item.cik}}"]}'::jsonb,
        '{"cik":"0000320193","concept":"Revenues","n":42,"nested":{"a":1}}'::jsonb,
        '[{"cik":"0000320193"}]'::jsonb, 'fan');

    -- Interpolated into a larger string.
    if v->>'url' <> 'https://x/CIK0000320193/Revenues.json' then
        raise exception 'two references in one string did not both substitute: %', v->>'url';
    end if;
    -- A WHOLE-string reference keeps its native type -- otherwise a numeric
    -- column arrives as "42" and an embedding arrives as a string.
    if jsonb_typeof(v->'n') <> 'number' or (v->>'n')::int <> 42 then
        raise exception 'a whole-string reference was stringified: %', v->'n';
    end if;
    if jsonb_typeof(v->'obj') <> 'object' then
        raise exception 'a nested row value was flattened: %', v->'obj';
    end if;
    -- Only `item` is bound here. The others still resolve at dispatch.
    if v->>'keep' <> '{{run.tier}}' then
        raise exception 'expansion consumed a namespace that is not its own: %', v->>'keep';
    end if;
    if v->'arr'->>0 <> '0000320193' then
        raise exception 'substitution did not descend into arrays';
    end if;
    if v->>'lit' <> 'untouched' then
        raise exception 'a literal was rewritten';
    end if;

    -- A column that does not exist is an authoring error, and it must fail
    -- BEFORE any child exists -- not become a URL with a literal {{item.typo}}
    -- in it and a 404 nobody can explain.
    begin
        perform workflow.substitute_item('{"u":"{{item.typo}}"}'::jsonb,
                                         '{"cik":"1"}'::jsonb,
                                         '[{"cik":"1"}]'::jsonb, 'fan');
        raise exception 'a template naming a missing column was accepted';
    exception when others then
        v_err := sqlerrm;
    end;
    if v_err not like '%not a column of the row set%' or v_err not like '%cik%' then
        raise exception 'the missing-column error does not say what the row has: %', v_err;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 8c. The fan-in, which the first version of §20 shipped without and
--     described wrongly. It claimed children could write to a domain table
--     and a `sql` successor could read it -- true for `work` children, false
--     for `rest` ones, which are the whole worked example: a generic worker
--     records a response and knows no domain.
-- ---------------------------------------------------------------------
insert into workflow.definitions (name, spec) values
('t_mx_gather', '{"steps":[
    {"key":"fan", "kind":"matrix", "queue":"t", "input":{
        "items":[{"n":1},{"n":2},{"n":3}], "max_fanout":10,
        "template":{"queue":"none", "kind":"sql",
                    "input":{"function":"t_mx_echo", "args":["{{item.n}}"]}}}},
    {"key":"gather", "kind":"sql", "queue":"none", "depends_on":["fan"],
     "input":{"function":"matrix_outputs", "args":["{{steps.fan.result.task_id}}"]}}
 ]}');

do $$
declare v_run uuid; v jsonb;
begin
    v_run := workflow.start_workflow('t_mx_gather', '{}'::jsonb);

    if (select status from workflow.runs where id = v_run) is distinct from 'completed' then
        raise exception 'the gather run did not complete: %',
            (select jsonb_agg(jsonb_build_object('k',step_key,'s',status,'e',error))
             from workflow.tasks where run_id = v_run);
    end if;

    select output->'result' into v from workflow.tasks
    where run_id = v_run and step_key = 'gather';

    if jsonb_array_length(v) <> 3 then
        raise exception 'the fan-in saw % children, not 3: %', jsonb_array_length(v), v;
    end if;
    -- Each child comes back with its ROW alongside its output, because an
    -- aggregate almost always needs to know which input produced which result.
    if v->0->'item'->>'n' is null or v->0->'output' is null then
        raise exception 'matrix_outputs does not pair the row with its output: %', v->0;
    end if;
    -- And its status, unfiltered -- so that when continue-on-failure exists,
    -- an aggregate can see which rows are missing rather than silently
    -- averaging over the survivors.
    if v->0->>'status' <> 'done' then
        raise exception 'matrix_outputs does not report per-child status';
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 8d. An output that cannot be stored fails TERMINALLY.
--
-- Found by the same run: an ordinary single-company XBRL response came back
-- at 69,248 bytes against the 65,536 cap, and was retried four times with
-- exponential backoff -- re-fetching a public API each time -- on a failure
-- that is byte-for-byte identical on every attempt. The worker cannot
-- classify it (the HTTP call succeeded), so the engine has to.
-- ---------------------------------------------------------------------
-- The cap is set locally rather than assumed: it is deployment tuning
-- (this database has it raised), and a test that depends on the operator's
-- number tests the operator, not the engine.
set local workflow.max_payload_bytes = '4096';

do $$
declare v_run uuid; v_task uuid; t workflow.tasks;
begin
    insert into workflow.definitions (name, spec) values
    ('t_mx_big', '{"steps":[{"key":"one","kind":"work","queue":"t"}]}');
    v_run := workflow.start_workflow('t_mx_big', '{}'::jsonb);
    select id into v_task from workflow.tasks where run_id = v_run and step_key = 'one';

    perform workflow.complete_task(v_task,
        jsonb_build_object('result', repeat('x', 9000)));

    select * into t from workflow.tasks where id = v_task;
    if t.status <> 'failed' then
        raise exception 'an unstorable output did not fail the task: %', t.status;
    end if;
    if t.attempts > 1 then
        raise exception 'an unstorable output was retried (% attempts) -- it is the same '
            'size on every attempt', t.attempts;
    end if;
    -- The remedy used to be spelled `$ref` and pointed at an s3:// URI. It
    -- never worked -- see 08-artifacts.sql section 1 for the probe -- so this
    -- asserts the spelling that does. The size still has to be in the error:
    -- "too big" without the number is not actionable.
    if t.error->>'error' not like '%$artifact%' or (t.error->>'bytes')::int < 9000 then
        raise exception 'the failure does not name the size or the remedy: %', t.error;
    end if;
    -- Nothing partial was written: the check runs before context is touched.
    if (select context ? 'one' from workflow.runs where id = v_run) then
        raise exception 'a rejected output still reached runs.context';
    end if;
end $$;

reset workflow.max_payload_bytes;

-- ---------------------------------------------------------------------
-- 9. ROUND TRIP. The spec below is the VERBATIM output of
--    p8_compile_workflow() for this YAML:
--
--        name: literal_items
--        steps:
--          - id: fan
--            matrix:
--              items: [{cik: AAA}, {cik: BBB}]
--              max_fanout: 10
--              template:
--                sql: {function: echo, args: ['{{item.cik}}']}
--
--    Pinned as JSON rather than called through workflow.define_yaml() because
--    the compiler lives in the percolate extension's .so, which has not been
--    rebuilt in this environment (the local rustc is older than pgrx 0.19
--    requires). So this asserts the half that can be asserted here: that what
--    the compiler emits is a spec THIS ENGINE runs. If the two ever disagree,
--    this is the row that says so.
-- ---------------------------------------------------------------------
create function t_mx_rt(p text) returns jsonb as $fn$
    select jsonb_build_object('saw', p);
$fn$ language sql stable;
select workflow.register_step_function('echo', 't_mx_rt', '{text}');

insert into workflow.definitions (name, spec) values ('t_mx_rt',
'{"steps": [{"input": {"items": [{"cik": "AAA"}, {"cik": "BBB"}], "max_fanout": 10,
  "template": {"input": {"args": ["{{item.cik}}"], "function": "echo"},
               "kind": "sql", "queue": "none"}},
  "key": "fan", "kind": "matrix", "queue": "none"}]}');

do $$
declare v_run uuid; v_o text;
begin
    v_run := workflow.start_workflow('t_mx_rt', '{}'::jsonb);
    select string_agg(output#>>'{result,saw}', ',' order by step_key) into v_o
    from workflow.tasks where run_id = v_run and kind = 'sql';
    if v_o is distinct from 'AAA,BBB' then
        raise exception 'the compiler''s own output does not run on this engine: %',
            coalesce(v_o, '<null>');
    end if;
    if (select status from workflow.runs where id = v_run) is distinct from 'completed' then
        raise exception 'a compiled matrix workflow did not complete';
    end if;
end $$;

rollback;

do $$ begin
    raise notice 'workflow/04: a matrix expands from a registered query, in-transaction, with nothing deployed';
    raise notice 'workflow/04: the fan-in is rewired onto the children -- a successor waits for all N';
    raise notice 'workflow/04: children carry their row recorded AND substituted, and stay out of runs.context';
    raise notice 'workflow/04: an empty matrix releases its successor; a blown ceiling fails terminally';
    raise notice 'workflow/04: a whole fan-out of sql steps runs with nothing deployed';
    raise notice 'workflow/04: re-expansion over a changed row set is refused, an identical one is a no-op';
    raise notice 'workflow/04: the spec p8_compile_workflow emits for a matrix step runs on this engine';
    raise notice 'workflow/04: matrix_rows is authorized against the run, not the task id it is handed';
    raise notice 'workflow/04: {{item.*}} is substituted at expansion -- a worker never learns a task was fanned out';
    raise notice 'workflow/04: a successor reaches its siblings via {{steps.<id>.result.task_id}} + matrix_outputs';
    raise notice 'workflow/04: an output that cannot be stored fails terminally, not five times';
end $$;
