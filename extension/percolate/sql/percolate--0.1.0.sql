-- ============================================================
-- percolate 0.1.0 -- the whole schema, as one extension script.
--
-- GENERATED from specs/ by extension/percolate/build-sql.py. Do not edit.
--
-- Install:
--     CREATE EXTENSION vector;            -- superuser, not trusted
--     CREATE EXTENSION percolate_parser;  -- superuser, carries C functions
--     SET ROLE app_owner;
--     CREATE EXTENSION percolate;         -- non-superuser: owns what it makes
--
-- That last line is the load-bearing one. Extension objects are owned by
-- whoever runs the script, and superusers bypass RLS unconditionally -- so
-- installing this as a superuser would leave every policy below inert.
-- user-rbac's own guard refuses that case rather than allowing it silently.
--
-- Roles are NOT created here: they are cluster-level, and a non-superuser
-- cannot CREATE ROLE. See specs/user-rbac/roles.sql, applied once by a DBA.
-- ============================================================


-- ============================================================
-- workflow-engine/schema.sql
--   the engine: definitions, runs, tasks, saga, sql steps, YAML
-- ============================================================

-- ============================================================
-- HOW TO READ THIS FILE
--
-- One definition per function, placed where it is first needed. A later
-- section that discusses a function explains WHY it has the shape it does and
-- points at the body rather than repeating it.
--
-- That convention was bought the hard way. This file grew by appending: each
-- fix was written next to the failure that produced it, as `create or
-- replace`, and the file accumulated superseded bodies that never executed --
-- 1,013 dead lines across seventeen functions, one of them defined five times.
-- Behaviour stayed correct, because the last definition wins. That is exactly
-- what made it dangerous: nothing told a maintainer which copy was live, and a
-- fix applied to a superseded one is silently a no-op.
--
-- `extension/percolate/build-sql.py` now refuses to assemble a spec file that
-- defines the same signature twice, so this cannot come back quietly.
--
-- Sections are chronological: §1-19 are the engine as designed, §20-22 are what
-- running it against live sources and real pipelines changed. Reading them in
-- order is reading the argument.
-- ============================================================

-- ============================================================
-- DB-native workflow engine — final canonical schema
--
-- History folded into this single file:
--   v1.0 fixed four concurrency/correctness bugs found in review:
--     1. Dependency-completion race (FOR UPDATE serialization)
--     2. Cascading cancellation stopping after one hop (unified trigger)
--     3. Missing workflow.start_workflow() bootstrap function
--     4. No guard against adding tasks to an already-cancelled run
--   This version adds the three Stage-1 recommendations from the
--   workflow-theory research pass:
--     5. Static spec soundness check at registration time
--        (reachability + cycle-entry check; van der Aalst WF-net
--        soundness, restricted to what's cheap to check without a
--        full state-space exploration)
--     6. Saga/compensation as a first-class primitive — the single
--        largest gap found versus DBOS/River/Temporal
--     7. Determinism guard on decision tasks (hash comparison),
--        since "pure decision function" was previously a convention,
--        not an enforced contract
-- ============================================================



-- Schema namespacing (specs/README.md ground rule, executed here): every
-- table/function this subsystem owns lives in the workflow schema, not
-- public. touch_updated_at() is the one exception -- a generic, subsystem-
-- agnostic trigger utility, defined here (workflow-engine is its first
-- consumer) but placed in public since any future schema's own tables may
-- want the same trigger.
create schema if not exists workflow;

-- System-fields envelope (specs/README.md ground rule): mutable entity
-- tables get created_at/updated_at maintained by this shared trigger, never
-- hand-set in every UPDATE statement -- confirmed error-prone the hard way
-- (workflow.runs.updated_at was hand-set in some UPDATE statements and not
-- verified against all of them; workflow.tasks had no updated_at at all despite
-- being the most heavily mutated table in this schema).
create or replace function public.touch_updated_at() returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 1. Workflow defs
-- ------------------------------------------------------------
create table workflow.definitions (
    id          uuid primary key default gen_random_uuid(),
    name        text not null,
    version     int not null default 1,
    spec        jsonb not null,   -- {"steps": [{"key","queue","kind","depends_on":[keys]}]}
    created_at  timestamptz not null default now(),
    -- Deprecation, not deletion: existing runs still reference a specific
    -- (name, version), so a def is retired by marking it, never removed.
    -- Was a genuine gap -- this table had no way to say "don't start new
    -- runs against this version" before this column existed.
    deleted_at  timestamptz,
    unique (name, version)
);

-- ------------------------------------------------------------
-- 1b. Static spec validation (research finding: WF-net soundness is
--     decidable and cheap to check for free-choice/acyclic graphs;
--     this is a lightweight version of that, not full soundness --
--     it catches the errors that actually matter before a run starts:
--     duplicate/unknown step keys, unreachable ("dead") steps, and
--     cycles with no entry point. Rejects the spec at registration
--     time rather than letting a broken graph run and stall silently.
-- ------------------------------------------------------------
create or replace function workflow.validate_spec(p_spec jsonb) returns void as $$
declare
    v_all_keys   text[];
    v_step       jsonb;
    v_dep        text;
    v_reachable  text[];
    v_frontier   text[];
    v_prev_count int;
begin
    select array_agg(s->>'key') into v_all_keys
    from jsonb_array_elements(p_spec->'steps') s;

    if v_all_keys is null or array_length(v_all_keys, 1) = 0 then
        raise exception 'spec has no steps';
    end if;

    if array_length(v_all_keys, 1) <> (select count(distinct k) from unnest(v_all_keys) k) then
        raise exception 'spec has duplicate step keys';
    end if;

    -- every depends_on must reference a real step
    for v_step in select * from jsonb_array_elements(p_spec->'steps') loop
        for v_dep in select jsonb_array_elements_text(coalesce(v_step->'depends_on', '[]'::jsonb)) loop
            if not (v_dep = any(v_all_keys)) then
                raise exception 'step % depends on unknown step %', v_step->>'key', v_dep;
            end if;
        end loop;
    end loop;

    -- forward reachability closure from root steps (no depends_on)
    select array_agg(s->>'key') into v_frontier
    from jsonb_array_elements(p_spec->'steps') s
    where coalesce(jsonb_array_length(s->'depends_on'), 0) = 0;

    if v_frontier is null then
        raise exception 'spec has no root steps -- every step depends on something, meaning a cycle with no entry point';
    end if;

    v_reachable := v_frontier;
    loop
        v_prev_count := array_length(v_reachable, 1);

        select array_agg(distinct s->>'key') into v_frontier
        from jsonb_array_elements(p_spec->'steps') s
        where s->>'key' <> all(v_reachable)
          and (
              select bool_and(dep = any(v_reachable))
              from jsonb_array_elements_text(coalesce(s->'depends_on', '[]'::jsonb)) dep
          );

        if v_frontier is not null then
            v_reachable := v_reachable || v_frontier;
        end if;

        exit when v_frontier is null or array_length(v_reachable, 1) = v_prev_count;
    end loop;

    if array_length(v_reachable, 1) < array_length(v_all_keys, 1) then
        raise exception 'spec has unreachable step(s), likely a cycle with no valid entry: %',
            (select array_agg(k) from unnest(v_all_keys) k where k <> all(v_reachable));
    end if;
end;
$$ language plpgsql;

-- Current form. It reached this shape in section 20f (Validation -- refuse at registration, not at 3am.), which explains
-- the failure that produced it. Defined here, where it is first needed.
--
-- The lint (§25) runs here too, and this is the one place it can run: a
-- definition arrives by INSERT whether it came from define_yaml, a migration,
-- or a hand-written JSON spec, so the trigger is the only gate all three pass.
create or replace function workflow.check_spec_before_insert() returns trigger as $$
declare v_bad text;
begin
    perform workflow.validate_spec(new.spec);
    perform workflow.validate_matrix_steps(new.spec);

    select string_agg(format('  %s: %s', l.step_key, l.detail), E'\n' order by l.step_key)
      into v_bad
      from workflow.lint_spec(new.spec) l where l.severity = 'error';
    if v_bad is not null then
        raise exception E'this workflow cannot run as written:\n%', v_bad;
    end if;

    for v_bad in select format('%s: %s', l.step_key, l.detail)
                   from workflow.lint_spec(new.spec) l where l.severity = 'warning'
    loop
        raise warning 'workflow lint: %', v_bad;
    end loop;
    return new;
end;
$$ language plpgsql;

create trigger trg_check_spec_before_insert
    before insert or update of spec on workflow.definitions
    for each row execute function workflow.check_spec_before_insert();

-- ------------------------------------------------------------
-- 2. Workflow runs
-- ------------------------------------------------------------
create table workflow.runs (
    id               uuid primary key default gen_random_uuid(),
    workflow_def_id  uuid not null references workflow.definitions(id),
    parent_task_id   uuid,
    external_id      text unique,     -- caller-supplied idempotency key for workflow.start_workflow
    status           text not null default 'running'
                         check (status in ('running','completed','failed','cancelled')),
    compensation_state text not null default 'none'
                         check (compensation_state in ('none','compensating','compensated')),
    cancel_requested boolean not null default false,
    input            jsonb,
    context          jsonb not null default '{}'::jsonb,
    -- W3C Trace Context trace_id (32 hex chars / 128 bit) -- specs/README.md's
    -- OTel ground rule. Defaulted so a run always has one even if the caller
    -- doesn't propagate one, but see workflow.start_workflow()'s p_trace_id param for
    -- the propagation path -- a run started from an already-traced FastAPI
    -- request should continue that trace, not start a disconnected one.
    trace_id         text not null default encode(gen_random_bytes(16), 'hex'),
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now(),
    completed_at     timestamptz
);

-- ------------------------------------------------------------
-- 3. Tasks
-- ------------------------------------------------------------
create table workflow.tasks (
    id               uuid primary key default gen_random_uuid(),
    run_id           uuid not null references workflow.runs(id) on delete cascade,
    step_key         text not null,
    -- http_call: a durable outbound HTTP dispatch, claimed and executed by a
    -- GENERIC worker (no per-consumer code) -- spec.md §14. Needs no new
    -- columns: `input` carries the call spec
    -- ({"url","method","headers"?,"credential_ref"?,"body"?,"timeout_ms"?,
    -- "mode":"sync"|"async"}), `output` carries the response, existing
    -- max_attempts/run_after drive retry/backoff exactly like any other kind.
    kind             text not null default 'work'
                         check (kind in ('work','decision','timer','signal','sub_workflow','http_call','sql')),
    queue            text not null default 'default',
    status           text not null default 'pending'
                         check (status in
                             ('pending','ready','running','waiting_external',
                              'done','failed','cancelled')),
    priority         int not null default 100,
    attempts         int not null default 0,
    max_attempts     int not null default 5,
    pending_deps     int not null default 0,
    run_after        timestamptz not null default now(),
    claimed_by       text,
    claimed_at       timestamptz,
    heartbeat_at     timestamptz,
    cancel_requested boolean not null default false,
    idempotency_key  text generated always as (run_id::text || ':' || step_key) stored,
    rate_key         text,
    input            jsonb,
    output           jsonb,
    error            jsonb,
    wait_signal      text,
    child_run_id     uuid references workflow.runs(id),
    -- W3C Trace Context span_id (16 hex chars / 64 bit) for this task's own
    -- span, and the parent span it was created under -- specs/README.md's
    -- OTel ground rule. trace_id itself lives on workflow.runs (one trace per
    -- run, shared by every task in it); span_id/parent_span_id build the span
    -- tree within that trace.
    span_id          text not null default encode(gen_random_bytes(8), 'hex'),
    parent_span_id   text,
    completed_at     timestamptz,          -- set on 'done'; drives saga reverse-order compensation
    saga_group       text,                 -- groups tasks that must be compensated together on failure
    compensation_task_key text,            -- step_key to run (in reverse order) if this task must be undone
    compensated_at   timestamptz,          -- set once this task's compensation has run
    -- Set only on a COMPENSATION task, pointing at the forward task it undoes.
    -- Added after a live saga run reported compensation_state='compensated'
    -- while both of its compensation tasks were still unrun: the completion
    -- check had no way to tell a compensation task from a forward one, so it
    -- was inspecting the wrong set of rows entirely (see
    -- check_compensation_completion below). Also gives the compensation trail
    -- real lineage instead of encoding it in a step_key string.
    compensates_task_id uuid references workflow.tasks(id),
    decision_output_hash text,             -- determinism guard: hash of a decision's recorded output
    created_at       timestamptz not null default now(),
    -- Was missing entirely despite being the most heavily mutated table in
    -- this schema (claim/heartbeat/complete/fail/cancel all touch a row) --
    -- system-fields ground rule, maintained by public.touch_updated_at() below, not
    -- hand-set at each call site.
    updated_at       timestamptz not null default now(),
    unique (run_id, step_key)
);

create trigger trg_workflow_runs_touch before update on workflow.runs
    for each row execute function public.touch_updated_at();
create trigger trg_tasks_touch before update on workflow.tasks
    for each row execute function public.touch_updated_at();

create index idx_tasks_claimable on workflow.tasks (queue, priority, run_after) where status = 'ready';
create index idx_tasks_run on workflow.tasks (run_id);
create index idx_tasks_heartbeat on workflow.tasks (status, heartbeat_at) where status = 'running';
create index idx_tasks_signal on workflow.tasks (wait_signal) where status = 'waiting_external';

create table workflow.task_dependencies (
    task_id             uuid not null references workflow.tasks(id) on delete cascade,
    depends_on_task_id  uuid not null references workflow.tasks(id) on delete cascade,
    primary key (task_id, depends_on_task_id)
);
create index idx_task_deps_reverse on workflow.task_dependencies (depends_on_task_id);

-- ------------------------------------------------------------
-- 4. Per-queue config
-- ------------------------------------------------------------
create table workflow.queue_config (
    queue          text primary key,
    stale_timeout  interval not null default interval '2 minutes',
    rate_lookahead int not null default 20
);

-- ------------------------------------------------------------
-- 5. Rate limiting
-- ------------------------------------------------------------
create table workflow.rate_limits (
    key         text primary key,
    capacity    numeric not null,
    tokens      numeric not null,
    refill_rate numeric not null,
    updated_at  timestamptz not null default now()
);

create or replace function workflow.try_consume_rate_limit(p_key text, p_amount numeric default 1)
returns boolean as $$
declare v_ok boolean;
begin
    update workflow.rate_limits
    set tokens = least(capacity, tokens + refill_rate * extract(epoch from now() - updated_at)) - p_amount,
        updated_at = now()
    where key = p_key
      and (tokens + refill_rate * extract(epoch from now() - updated_at)) >= p_amount
    returning true into v_ok;
    return coalesce(v_ok, false);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 6. Audit log
-- ------------------------------------------------------------
create table workflow.task_events (
    id             bigint generated always as identity primary key,
    task_id        uuid not null,
    run_id         uuid not null,
    from_status    text,
    to_status      text not null,
    input_snapshot jsonb,
    detail         jsonb,
    at             timestamptz not null default now()
);
create index idx_task_events_run on workflow.task_events (run_id, at);

create or replace function workflow.log_task_transition() returns trigger as $$
begin
    if old.status is distinct from new.status then
        insert into workflow.task_events (task_id, run_id, from_status, to_status, input_snapshot, detail)
        values (
            new.id, new.run_id, old.status, new.status,
            case when new.status = 'running' then new.input else null end,
            jsonb_build_object('attempts', new.attempts, 'error', new.error)
        );
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_log_task_transition
    after update of status on workflow.tasks
    for each row execute function workflow.log_task_transition();

-- ------------------------------------------------------------
-- 7. Payload size, and the artifact ref that makes it survivable
-- ------------------------------------------------------------
-- The limit is a SETTING, not a literal, and the default was raised from 8KB
-- to 64KB after a real workflow hit it: a 768-dimension embedding is ~10KB as
-- JSON, and passing one from an embed step to a search step is a legitimate
-- intermediate, not a blob someone forgot to offload.
--
-- The guard's purpose is keeping multi-megabyte payloads out of the task
-- table, and 8KB was tight enough to reject ordinary structured values --
-- which pushes authors toward object storage for things that do not warrant
-- it, or (worse) toward not using the engine.
--
-- Still a hard limit rather than a warning: an unbounded payload column is how
-- a task table becomes unqueryable, and an artifact ref is the right answer
-- for anything genuinely large. See outputs.md for the four output classes;
-- this section owns the fourth.
--
-- THE REF IS A SIBLING OF `result`, NOT A VALUE INSIDE IT:
--
--     {"status": 200, "result": {...small...}, "$artifact": "<resource uuid>"}
--
-- Three things fall out of that placement, and the first one is why the
-- previous spelling never worked. It said "return {"$ref": "s3://..."}", and
-- the checks below use the jsonb `?` operator, which is TOP-LEVEL ONLY --
-- while YAML.md says every step nests its payload under `result`. Probed at a
-- 64KB cap: {"$ref": ...} at the top passed the check and broke every
-- {{steps.<id>.result}} reading it; {"result": {"$ref": ...}} kept the
-- templates working and was refused as oversized. No shape satisfied both,
-- which is a better account of "the worker never implemented $ref" than
-- "nobody got to it". As a sibling there is nothing to reconcile: `?` already
-- looks exactly where the ref now is.
--
--   1. {{steps.<id>.result}} is untouched, and {{steps.<id>.$artifact}}
--      resolves the ref -- resolve_args' template character class already
--      admits `$`, so this needed no resolver change.
--   2. `output_schema` validates `result` and never sees the engine's key, so
--      a contract with additionalProperties:false stays writable.
--   3. A step that produced ONLY bytes writes no `result` at all, and
--      {{steps.<id>.result}} then fails loudly -- which is correct, because
--      there is no value.
--
-- The old size BYPASS is gone rather than re-spelled. `not (output ? '$ref')`
-- exempted a payload that was over the limit AND carried a ref -- that is, one
-- that offloaded its bytes and then inlined them anyway. A genuine ref is
-- about thirty bytes and was never going to trip a 64KB cap, so the exemption
-- had no legitimate caller and admitted precisely the case the rule exists to
-- reject. The limit is now unconditional.
--
-- Registering the bytes lives in world-model-ingestion/integration-workflow.sql,
-- because `content` loads after this file and a workflow engine that cannot be
-- installed without a content plane is not the engine this collection specs.
create or replace function workflow.artifact_ref(p_payload jsonb) returns uuid as $$
    -- The extractor the engine itself uses, so "is this an artifact ref" has
    -- one definition rather than a `?` test repeated at four call sites.
    -- Returns null for a payload that carries no ref OR carries something that
    -- is not a uuid: a malformed ref is not a ref, and the size check that
    -- calls this must not be satisfiable by writing {"$artifact": "yes"}.
    select case
        when jsonb_typeof(p_payload -> '$artifact') = 'string'
         and (p_payload ->> '$artifact') ~
             '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        then (p_payload ->> '$artifact')::uuid
    end;
$$ language sql immutable;

create or replace function workflow.enforce_payload_ref_size() returns trigger as $$
declare
    v_max int := coalesce(
        nullif(current_setting('workflow.max_payload_bytes', true), '')::int,
        65536);
begin
    if new.input is not null and pg_column_size(new.input) > v_max then
        raise exception
            'task %: input payload is % bytes, over the % byte limit. '
            'Put the bytes in object storage and pass a "$artifact" ref beside '
            'the payload, or raise workflow.max_payload_bytes deliberately.',
            new.id, pg_column_size(new.input), v_max;
    end if;
    if new.output is not null and pg_column_size(new.output) > v_max then
        raise exception
            'task %: output payload is % bytes, over the % byte limit. '
            'Put the bytes in object storage (workflow.register_artifact) and '
            'return {"result": ..., "$artifact": "<resource id>"}, or raise '
            'workflow.max_payload_bytes deliberately.',
            new.id, pg_column_size(new.output), v_max;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_enforce_payload_ref_size
    before insert or update on workflow.tasks
    for each row execute function workflow.enforce_payload_ref_size();

-- ------------------------------------------------------------
-- 8. FIX #2: unified cascade trigger — handles done (decrement +
--    ready) AND cancelled/failed (cascade-cancel dependents, which
--    recurses for free since cancelling a row fires this same
--    trigger again for that row).
-- ------------------------------------------------------------
-- Current form. It reached this shape in section 21e (A fan-out that survives a failed child.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.cascade_task_status() returns trigger as $$
declare
    v_satisfies boolean;
    v_remaining int;
begin
    if new.status is not distinct from old.status then
        return new;
    end if;

    -- A terminal state SATISFIES a dependent if it succeeded, or if it failed
    -- and this task was expanded under continue_on.
    v_satisfies := new.status = 'done'
                   or (new.status in ('failed', 'cancelled') and new.tolerate_failure);

    if v_satisfies then
        -- Already cascaded once (§20i): pending_deps is decremented on the
        -- transition into a terminal state and never re-incremented, so a
        -- second decrement is always wrong.
        if old.completed_at is not null then
            return new;
        end if;

        -- THE GATE. Evaluated when the last child of a matrix resolves, and
        -- BEFORE anything downstream is released.
        if new.matrix_parent_id is not null then
            select count(*) into v_remaining from workflow.tasks
            where matrix_parent_id = new.matrix_parent_id
              and status not in ('done', 'failed', 'cancelled');

            if v_remaining = 0 and not workflow.matrix_gate_passes(new.matrix_parent_id) then
                update workflow.tasks t2 set status = 'cancelled'
                where t2.status in ('pending', 'ready', 'waiting_external')
                  and t2.id in (select task_id from workflow.task_dependencies
                                where depends_on_task_id = new.matrix_parent_id);
                update workflow.runs set status = 'failed' where id = new.run_id;
                return new;
            end if;
        end if;

        update workflow.tasks t
        set pending_deps = pending_deps - 1
        where t.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);

        update workflow.tasks t
        set status = case when t.kind = 'signal' then 'waiting_external' else 'ready' end
        where t.pending_deps = 0 and t.status = 'pending'
          and t.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);

        perform pg_notify('task_ready', t.queue)
        from workflow.tasks t
        where t.status = 'ready'
          and t.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);

    elsif new.status in ('cancelled', 'failed') then
        update workflow.tasks t2
        set status = 'cancelled'
        where t2.status in ('pending', 'ready', 'waiting_external')
          and t2.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);
    end if;

    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create trigger trg_cascade_task_status
    after update of status on workflow.tasks
    for each row execute function workflow.cascade_task_status();

create or replace function workflow.mark_roots_ready() returns trigger as $$
begin
    if new.pending_deps = 0 and new.status = 'pending' then
        new.status := case when new.kind = 'signal' then 'waiting_external' else 'ready' end;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_mark_roots_ready
    before insert on workflow.tasks
    for each row execute function workflow.mark_roots_ready();

create or replace function workflow.notify_new_ready() returns trigger as $$
begin
    if new.status = 'ready' then
        perform pg_notify('task_ready', new.queue);
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_notify_new_ready
    after insert on workflow.tasks
    for each row execute function workflow.notify_new_ready();

-- workflow.check_run_completion(uuid) is defined in section 21e.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- Saga: flips compensation_state once every compensation task for a
-- run's saga groups has resolved. Cheap no-op call from workflow.complete_task/
-- workflow.fail_task; only does anything while compensation_state='compensating'.
--
-- BUG FIXED HERE, found by running a real saga (charge -> hotel -> flight,
-- flight fails): this predicate used to filter on `compensation_task_key is
-- not null`, which selects the FORWARD tasks -- the ones that *declare* a
-- compensation -- not the compensation tasks themselves. By the time
-- compensation begins those forward tasks are all terminal
-- (done/failed/cancelled), so `not exists` was immediately true and the run
-- flipped straight to 'compensated' while every compensation task was still
-- ready/pending. Measured: cancel_hotel 'ready', refund 'pending',
-- compensation_state 'compensated'. In the worked example that means the
-- system reports a completed rollback while the customer's card has not been
-- refunded -- a correctness failure that reports success, the worst kind.
-- The fix keys off compensates_task_id, which is set only on compensation
-- tasks, so this now waits on the rows it was always meant to wait on.
create or replace function workflow.check_compensation_completion(p_run_id uuid) returns void as $$
    update workflow.runs
    set compensation_state = 'compensated'
    where id = p_run_id and compensation_state = 'compensating'
      and exists (
          -- there is at least one compensation task (otherwise 'compensated'
          -- would be claimed for a run whose compensations were never created)
          select 1 from workflow.tasks
          where run_id = p_run_id and compensates_task_id is not null
      )
      and not exists (
          select 1 from workflow.tasks
          where run_id = p_run_id and compensates_task_id is not null
            and status not in ('done', 'failed', 'cancelled')
      );
$$ language sql;

-- ------------------------------------------------------------
-- 9. FIX #3: workflow bootstrap — the piece that was missing entirely.
--    Two-pass: insert all step rows first (so every step_key has an
--    id), then wire workflow.task_dependencies + compute real pending_deps once all
--    ids are known. Idempotent via external_id.
-- ------------------------------------------------------------
-- p_trace_id: propagate an existing W3C trace_id from an already-traced
-- caller (e.g. a FastAPI request already inside a trace) instead of always
-- starting a disconnected new one -- specs/README.md's OTel ground rule.
-- Omit it and the run gets a fresh trace_id via the column default.
-- Current form. It reached this shape in section 21k (A dead run is not an idempotent hit.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.start_workflow(p_name text, p_input jsonb, p_external_id text default null, p_trace_id text default null)
returns uuid as $$
declare
    v_def       workflow.definitions;
    v_run_id    uuid;
    v_status    text;
    v_step      jsonb;
    v_step_ids  jsonb := '{}'::jsonb;
    v_new_id    uuid;
    v_dep_key   text;
    v_dep_id    uuid;
    v_count     int;
    v_comp      text[];
begin
    if p_external_id is not null then
        select id, status into v_run_id, v_status
        from workflow.runs where external_id = p_external_id;

        if v_run_id is not null then
            if v_status in ('running', 'completed') then
                return v_run_id;      -- the work happened; do not repeat it
            end if;
            raise exception
                'external_id % already belongs to run %, which is %. That run did not '
                'complete, so returning it would report work that never happened -- and '
                'external_id is unique, so this key cannot start a second run. Use a new '
                'external_id to retry.', p_external_id, v_run_id, v_status;
        end if;
    end if;

    select * into v_def from workflow.definitions where name = p_name order by version desc limit 1;
    if v_def.id is null then
        raise exception 'no workflow_def found for name %', p_name;
    end if;

    v_comp := workflow.compensation_keys(v_def.spec);

    insert into workflow.runs (workflow_def_id, input, external_id, trace_id)
    values (v_def.id, p_input, p_external_id, coalesce(p_trace_id, encode(gen_random_bytes(16), 'hex')))
    returning id into v_run_id;

    for v_step in select * from jsonb_array_elements(v_def.spec->'steps')
    loop
        continue when (v_step->>'key') = any(v_comp);
        insert into workflow.tasks (run_id, step_key, queue, kind, pending_deps, status,
                                    wait_signal, input, rate_key, saga_group, compensation_task_key)
        values (
            v_run_id, v_step->>'key', coalesce(v_step->>'queue', 'default'),
            coalesce(v_step->>'kind', 'work'), 0, 'pending',
            case when coalesce(v_step->>'kind','work') = 'signal'
                 then coalesce(v_step->'input'->>'signal', v_step->>'signal', v_step->>'key') end,
            v_step->'input', v_step->>'rate_key',
            v_step->>'saga_group', v_step->>'compensation_task_key')
        returning id into v_new_id;
        v_step_ids := v_step_ids || jsonb_build_object(v_step->>'key', v_new_id::text);
    end loop;

    for v_step in select * from jsonb_array_elements(v_def.spec->'steps')
    loop
        continue when (v_step->>'key') = any(v_comp);
        v_new_id := (v_step_ids ->> (v_step->>'key'))::uuid;
        v_count := 0;
        for v_dep_key in select jsonb_array_elements_text(coalesce(v_step->'depends_on', '[]'::jsonb))
        loop
            if v_dep_key = any(v_comp) then
                raise exception
                    'step % depends on %, which is a compensation step. A compensation '
                    'runs only when its saga rolls back, so nothing in the forward graph '
                    'can wait for it.', v_step->>'key', v_dep_key;
            end if;
            v_dep_id := (v_step_ids ->> v_dep_key)::uuid;
            insert into workflow.task_dependencies (task_id, depends_on_task_id)
            values (v_new_id, v_dep_id) on conflict do nothing;
            v_count := v_count + 1;
        end loop;
        update workflow.tasks
        set pending_deps = v_count,
            status = case when v_count > 0 then 'pending'
                          when kind = 'signal' then 'waiting_external'
                          else 'ready' end
        where id = v_new_id;
    end loop;

    perform workflow.drain_sql_steps(v_run_id);
    return v_run_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 10. Client API
-- ------------------------------------------------------------

-- Current form. It reached this shape in section 21b (Rate limiting stops being decoration.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.claim_task(p_queue text, p_worker_id text)
returns workflow.tasks as $$
declare
    t           workflow.tasks;
    v_lookahead int;
begin
    -- Look past a throttled task rather than stalling behind it: one
    -- rate-limited source must not block an unrelated one sharing a queue.
    select coalesce(rate_lookahead, 20) into v_lookahead
    from workflow.queue_config where queue = p_queue;
    v_lookahead := coalesce(v_lookahead, 20);

    for t in
        select * from workflow.tasks
        where queue = p_queue and status = 'ready' and run_after <= now()
        order by priority desc, created_at
        for update skip locked
        limit v_lookahead
    loop
        if t.rate_key is null or workflow.try_consume_rate_limit(t.rate_key) then
            update workflow.tasks
            set status = 'running', claimed_by = p_worker_id,
                claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
            where id = t.id
            returning * into t;
            return t;
        end if;
    end loop;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.claim_tasks(p_queue text, p_worker_id text, p_batch_size int default 10)
returns setof workflow.tasks as $$
    update workflow.tasks
    set status = 'running', claimed_by = p_worker_id,
        claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
    where id in (
        select id from workflow.tasks
        where queue = p_queue and status = 'ready' and run_after <= now()
        order by priority desc, created_at
        for update skip locked
        limit p_batch_size
    )
    returning *;
$$ language sql;

-- SUPERSEDED, kept as an alias rather than a second body.
--
-- This was the rate-limited claim, opted into by a worker that knew to call it.
-- That was the defect: the shipped worker called plain claim_task, so the token
-- bucket and this function both existed and neither ever ran -- rate limiting
-- was inert while looking present (§21, and `05-faults.sql` now asserts the
-- throttle works "with any worker"). The fix was to move the lookahead-skip
-- INTO claim_task, so the throttle is not opt-in.
--
-- Which left the two functions with byte-identical bodies. That is the exact
-- defect the consolidation pass removed everywhere else in this file --
-- superseded copies that behave correctly right up until somebody fixes one of
-- them -- so it is delegated rather than duplicated. It stays for callers
-- written against the old name; new callers use claim_task.
create or replace function workflow.claim_task_rate_limited(p_queue text, p_worker_id text)
returns workflow.tasks as $$
    select workflow.claim_task(p_queue, p_worker_id);
$$ language sql;

-- THE LEASE FENCE (§23). Returns null when the caller may act on the task, or
-- the reason it may not -- and records the refusal, because a worker whose
-- completion is silently dropped looks exactly like a worker that never ran.
--
-- Two distinct callers get refused here and they are not the same problem:
--
--   * A task in a terminal state. Completing a done task cannot change its
--     outcome but CAN still rewrite runs.context, which is what makes it
--     dangerous rather than merely redundant -- see §23.
--   * A caller that is not the current lease holder. This is the crash-recovery
--     case: the reaper handed the task to somebody else, and the original
--     worker was slow rather than dead.
--
-- p_worker_id is optional because the in-database paths (execute_sql_step,
-- expand_matrix) have no worker identity and cannot lie about one. A worker
-- that passes its id gets the full fence; one that does not still gets the
-- terminal-state half. get_task_context already hands every worker the
-- `claimed_by` it should send back, so passing it is not new information.
create or replace function workflow.lease_violation(
    p_task_id uuid, p_worker_id text, p_op text)
returns text as $$
declare t workflow.tasks; v_why text;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found then
        return format('no task %s', p_task_id);
    end if;

    if t.status in ('done', 'failed', 'cancelled') then
        v_why := format('task is already %s', t.status);

    -- The revoked lease, and the reason this test is on `attempts` rather than
    -- on claimed_by. A reaped task is requeued with claimed_by cleared and a
    -- backoff, so for the length of that backoff it is `ready` and unclaimed --
    -- and a check that only compared worker ids would pass vacuously, letting
    -- the worker whose lease was just revoked complete it after all. Whether the
    -- zombie won would then depend on whether a replacement had claimed yet,
    -- which is a race deciding whose answer is authoritative.
    --
    -- attempts > 0 means "somebody has held this lease", and a task that is not
    -- `running` is a task nobody holds. Together: the lease was revoked, and the
    -- caller is talking about a lease that no longer exists. attempts = 0 is
    -- left open deliberately -- that is a task nobody ever claimed, which is how
    -- every in-database path and every test drives the engine directly.
    elsif t.status <> 'running' and t.attempts > 0 then
        v_why := format('the lease was revoked -- task is %s after %s attempt(s)',
                        t.status, t.attempts);

    elsif p_worker_id is not null and t.claimed_by is not null
          and p_worker_id is distinct from t.claimed_by then
        v_why := format('the lease is held by %s, not %s', t.claimed_by, p_worker_id);
    else
        return null;
    end if;

    insert into workflow.task_events (task_id, run_id, from_status, to_status, detail)
    values (p_task_id, t.run_id, t.status, t.status, jsonb_build_object(
        'event', 'lease_violation',
        'op', p_op,
        'why', v_why,
        'caller', p_worker_id,
        'holder', t.claimed_by,
        'queue', t.queue,
        'attempts', t.attempts));
    return v_why;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Returns false to mean "stop working" -- which is now true for three reasons,
-- not one: the run was cancelled, the task reached a terminal state, or this
-- worker's lease was reaped and given to somebody else. A partitioned worker
-- asking "should I keep going?" is exactly the caller that must be told no.
create or replace function workflow.heartbeat_task(
    p_task_id uuid, p_worker_id text default null)
returns boolean as $$
declare v_ok boolean;
begin
    if workflow.lease_violation(p_task_id, p_worker_id, 'heartbeat') is not null then
        return false;
    end if;
    update workflow.tasks set heartbeat_at = now()
    where id = p_task_id and status = 'running'
    returning not cancel_requested into v_ok;
    return coalesce(v_ok, false);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Current form. It reached this shape in section 21h (Completion, final form: repair, validate, then store.), which explains
-- the failure that produced it. Defined here, where it is first needed.
drop function if exists workflow.complete_task(uuid, jsonb);
create or replace function workflow.complete_task(
    p_task_id uuid, p_output jsonb, p_worker_id text default null)
returns void as $$
declare
    t        workflow.tasks;
    v_lease  text;
    v_out    jsonb;
    v_res    jsonb;
    v_schema jsonb;
    v_why    text;
    v_max    int := coalesce(
        nullif(current_setting('workflow.max_payload_bytes', true), '')::int, 65536);
begin
    select * into t from workflow.tasks where id = p_task_id;

    -- 21k: no work lands under a cancelled run. complete_decision_task and
    -- add_task have always refused; this path never did, so a worker finishing
    -- in-flight work resurrected a cancelled graph one step at a time.
    if exists (select 1 from workflow.runs where id = t.run_id and status = 'cancelled') then
        update workflow.tasks set status = 'cancelled'
        where id = p_task_id and status in ('running', 'ready');
        return;
    end if;

    -- §23: the lease fence. Placed after the cancelled-run branch, which is
    -- idempotent and correct for any caller, and before anything that writes.
    v_lease := workflow.lease_violation(p_task_id, p_worker_id, 'complete');
    if v_lease is not null then
        return;
    end if;

    v_out := workflow.normalize_output(p_task_id, p_output);          -- 21a

    v_schema := t.input->'output_schema';
    if v_schema is not null then
        v_res := coalesce(v_out->'result', v_out);
        -- A model returns its structured answer as message CONTENT, i.e. a
        -- string. Parse it before checking the shape, and treat unparseable
        -- output as a shape failure rather than a crash -- it is the same
        -- class of problem and the same remedy.
        if jsonb_typeof(v_res) = 'string' then
            begin
                v_res := (v_res #>> '{}')::jsonb;
                v_out := jsonb_set(coalesce(v_out, '{}'::jsonb), '{result}', v_res);
            exception when others then
                perform workflow.fail_task(p_task_id, jsonb_build_object(
                    'error', 'output_schema was declared, but the result is not JSON',
                    'shape_violation', true, 'got', left(v_res #>> '{}', 400)), false);
                return;
            end;
        end if;

        v_why := workflow.validate_shape(v_res, v_schema);
        if v_why is not null then
            perform workflow.fail_task(p_task_id, jsonb_build_object(
                'error', format('output does not match the declared shape: %s', v_why),
                'shape_violation', true,
                'schema', v_schema, 'got', v_res), false);   -- retryable, on purpose
            return;
        end if;
    end if;

    -- An artifact ref that is not one. Both of these are terminal and both
    -- say what to write instead, because the alternative is storing a string
    -- nothing can dereference and finding out three steps later.
    --
    -- Deliberately NOT checked here: whether the resource exists. That would
    -- make complete_task depend on `content`, and the engine has to stay
    -- installable without a content plane (see section 7). Registration
    -- returns a real id; a fabricated one fails at deref, where the reader has
    -- the context to say what it was looking for.
    if v_out ? '$ref' then
        perform workflow.fail_task(p_task_id, jsonb_build_object(
            'error', '"$ref" is the old spelling and never worked: it collided with '
                     'the {"result": ...} nesting every step uses, and with $ref in '
                     'output_schema. Register the bytes (workflow.register_artifact) '
                     'and return {"result": ..., "$artifact": "<resource id>"} -- the '
                     'ref is a SIBLING of result, not a value inside it.',
            'got', v_out -> '$ref'), true);
        return;
    end if;
    if v_out ? '$artifact' and workflow.artifact_ref(v_out) is null then
        perform workflow.fail_task(p_task_id, jsonb_build_object(
            'error', '"$artifact" must be a resource uuid returned by '
                     'workflow.register_artifact, not an s3:// URI or a name. A bucket '
                     'path in a payload is unscoped, undeduped and unservable, and '
                     'carries a bucket name into a row that is supposed to stay '
                     'inspectable.',
            'got', v_out -> '$artifact'), true);
        return;
    end if;

    -- Unconditional: the old `and not (v_out ? '$ref')` exempted the one case
    -- worth rejecting (see the trigger in section 7). A step that offloaded
    -- its bytes returns a ~30-byte ref beside a small result and is nowhere
    -- near the cap; a step that inlined a megabyte is over it whether or not
    -- it also names an artifact.
    if v_out is not null and pg_column_size(v_out) > v_max then
        perform workflow.fail_task(p_task_id, jsonb_build_object(
            'error', format(
                'output is %s bytes, over the %s byte limit. This is terminal: the '
                'same response will be the same size on every attempt. Register the '
                'bytes (workflow.register_artifact) and return '
                '{"result": ..., "$artifact": "<resource id>"}, or raise '
                'workflow.max_payload_bytes deliberately.',
                pg_column_size(v_out), v_max),
            'bytes', pg_column_size(v_out), 'limit', v_max), true);
        return;
    end if;

    if t.matrix_parent_id is null then
        update workflow.runs r
        set context = context || jsonb_build_object(t.step_key, v_out), updated_at = now()
        where r.id = t.run_id;
    else
        update workflow.runs set updated_at = now() where id = t.run_id;
    end if;

    update workflow.tasks set status = 'done', output = v_out,
        completed_at = clock_timestamp()
    where id = p_task_id;

    perform workflow.check_run_completion(t.run_id);
    perform workflow.check_compensation_completion(t.run_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- p_terminal: "do not retry this, no matter how many attempts remain."
--
-- Retry is the right default -- most failures are transient -- but some are
-- provably not: a 400 or a 404 from an http_call will fail identically on
-- every attempt, and retrying it five times with exponential backoff just
-- turns a fast failure into a slow one while burning the caller's rate limit.
-- The DISPATCHER decides which is which (it is the only thing that knows an
-- HTTP status code means); the engine just honours the verdict.
--
-- Defaulted to false so every existing call site keeps its previous behaviour.
drop function if exists workflow.fail_task(uuid, jsonb);
drop function if exists workflow.fail_task(uuid, jsonb, boolean);
-- Current form. It reached this shape in section 21e (A fan-out that survives a failed child.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.fail_task(
    p_task_id uuid, p_error jsonb, p_terminal boolean default false,
    p_worker_id text default null)
returns void as $$
declare t workflow.tasks; v_lease text;
begin
    select * into t from workflow.tasks where id = p_task_id;

    -- §23, same fence as complete_task: a worker that lost its lease must not
    -- be able to fail a task somebody else is currently running, which would
    -- burn an attempt belonging to the live holder.
    v_lease := workflow.lease_violation(p_task_id, p_worker_id, 'fail');
    if v_lease is not null then
        return;
    end if;

    -- The SAME repair complete_task applies to output, applied to error --
    -- which it was not, for as long as both existed. `error` is jsonb and the
    -- worker hands it a JSON document serialised into a string, so the column
    -- held `"{\"error\": \"connection failed\"}"` and the documented way to
    -- read a failure, `error->>'error'`, returned NULL. A run that failed for a
    -- reason the engine had recorded reported no reason at all: the text was
    -- there, one indirection away, and every accessor in every dashboard
    -- reading it the obvious way got nothing.
    --
    -- Found by asking the engine why a run failed and being told nothing.
    -- Same producer as the output bug, same encoding mistake, same fix already
    -- written -- and never wired to this path, which is §23c's failure shape
    -- exactly: a repair that lands where somebody was looking and not where
    -- the same problem also lives.
    p_error := workflow.normalize_output(p_task_id, p_error);

    if not p_terminal and t.attempts < t.max_attempts and not t.cancel_requested then
        -- claimed_by is cleared on requeue (§23). A ready task that still names
        -- a worker is not merely untidy: the lease fence reads claimed_by, so a
        -- stale one would let the previous holder act on a task it no longer
        -- owns -- the exact hole the fence exists to close.
        update workflow.tasks set status = 'ready', error = p_error,
            claimed_by = null, claimed_at = null,
            run_after = now() + (power(2, t.attempts) * interval '1 second')
        where id = p_task_id;
        return;
    end if;

    update workflow.tasks
    set status = 'failed', error = p_error,
        completed_at = case when t.tolerate_failure then clock_timestamp() else completed_at end
    where id = p_task_id;

    if not t.tolerate_failure then
        update workflow.runs set status = 'failed' where id = t.run_id;
    end if;

    if t.saga_group is not null and t.compensates_task_id is null
       and (select compensation_state from workflow.runs where id = t.run_id)
           is distinct from 'compensating' then
        perform workflow.begin_compensation(t.run_id, t.saga_group);
    end if;

    perform workflow.check_compensation_completion(t.run_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- Saga / compensation: the largest gap found by the theory
-- research pass. Compensations are ordinary work tasks -- they
-- inherit the existing queue, retry/backoff, and audit machinery
-- for free. Call this after a saga member fails terminally.
-- Reverse (LIFO) order via `ORDER BY completed_at DESC`, with each
-- compensation task depending on the previous one so they run
-- strictly in sequence even though the queue itself is concurrent.
-- Compensation task functions must be idempotent -- they may be
-- retried, and (by saga theory) may run even when there's nothing
-- to undo, so they must no-op safely in that case.
-- ------------------------------------------------------------
-- Current form. It reached this shape in section 21d (Saga compensation, which did not work in four ways.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.begin_compensation(p_run_id uuid, p_saga_group text)
returns void as $$
declare
    v_task         workflow.tasks;
    v_spec         jsonb;
    v_step         jsonb;
    v_prev_comp_id uuid := null;
    v_new_id       uuid;
begin
    update workflow.runs set compensation_state = 'compensating' where id = p_run_id;

    select d.spec into v_spec
    from workflow.runs r join workflow.definitions d on d.id = r.workflow_def_id
    where r.id = p_run_id;

    for v_task in
        select * from workflow.tasks
        where run_id = p_run_id and saga_group = p_saga_group
          and status = 'done' and compensation_task_key is not null and compensated_at is null
        order by completed_at desc, id desc          -- 21c: clock_timestamp, stable tie-break
    loop
        select s into v_step from jsonb_array_elements(v_spec->'steps') s
        where s->>'key' = v_task.compensation_task_key;

        if v_step is null then
            raise exception
                'step % declares compensation %, which is not a step in this workflow',
                v_task.step_key, v_task.compensation_task_key;
        end if;

        v_new_id := workflow.add_task(
            p_run_id,
            v_task.compensation_task_key || ':' || v_task.id,
            coalesce(v_step->>'queue', v_task.queue),
            case when v_prev_comp_id is not null then array[v_prev_comp_id] else '{}'::uuid[] end,
            coalesce(v_step->>'kind', 'work'),
            -- The step's own input, with what the forward step produced
            -- attached: a refund needs the charge id, and the declared input
            -- is where a `sql` compensation's function and args live.
            coalesce(v_step->'input', '{}'::jsonb)
                || jsonb_build_object('compensates', jsonb_build_object(
                       'step_key', v_task.step_key, 'output', v_task.output)),
            v_step->>'rate_key'
        );

        update workflow.tasks set compensates_task_id = v_task.id where id = v_new_id;
        update workflow.tasks set compensated_at = now() where id = v_task.id;
        v_prev_comp_id := v_new_id;
    end loop;

    -- A `sql` compensation is INSERTED ready, and the autorun trigger fires
    -- only on a transition INTO ready -- the same hazard §20 hit with matrix
    -- children. Without this an in-database rollback never starts.
    perform workflow.drain_sql_steps(p_run_id);
    perform workflow.check_compensation_completion(p_run_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- completed_at is stamped here for the same §21c reason as complete_task and
-- promote_due_timers: it is the column begin_compensation orders by, and this
-- was the third path that marked a task `done` without it. A signalled task in
-- a saga group sorted first under `order by completed_at desc` -- compensated
-- before everything that ran after it -- because a NULL sorts first.
create or replace function workflow.signal_task(p_run_id uuid, p_signal text, p_payload jsonb)
returns void as $$
    update workflow.tasks
    set status = 'done', output = p_payload, completed_at = clock_timestamp()
    where run_id = p_run_id and wait_signal = p_signal and status = 'waiting_external';
$$ language sql;

create or replace function workflow.cancel_run(p_run_id uuid) returns void as $$
declare v_child uuid;
begin
    update workflow.runs set status = 'cancelled', cancel_requested = true
    where id = p_run_id and status = 'running';

    update workflow.tasks set cancel_requested = true
    where run_id = p_run_id and status = 'running';

    update workflow.tasks set status = 'cancelled'
    where run_id = p_run_id and status in ('pending', 'ready', 'waiting_external');

    for v_child in select child_run_id from workflow.tasks
                   where run_id = p_run_id and child_run_id is not null
    loop
        perform workflow.cancel_run(v_child);
    end loop;
end;
$$ language plpgsql;

-- Current form. It reached this shape in section 21g (Sub-workflows had never executed.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.start_child_workflow(p_task_id uuid, p_workflow_name text, p_input jsonb)
returns uuid as $$
declare
    v_child  uuid;
    v_status text;
    v_ctx    jsonb;
begin
    if not exists (select 1 from workflow.definitions where name = p_workflow_name) then
        raise exception
            'sub_workflow step names workflow %, which is not registered', p_workflow_name;
    end if;

    update workflow.tasks set status = 'waiting_external' where id = p_task_id;

    -- The child inherits the parent's trace. Omitting the argument -- which is
    -- what this line did -- gives the child run a FRESH trace_id from the
    -- column default, so a sub-workflow was a broken trace: parent_task_id
    -- recorded the causal link in the database while the two halves sat in
    -- different traces in any collector reading them. The one place in this
    -- engine where a run is provably caused by another run is the one place
    -- the trace was not carried across.
    v_child := workflow.start_workflow(
        p_workflow_name, p_input, null,
        (select r.trace_id from workflow.runs r
           join workflow.tasks t on t.run_id = r.id
          where t.id = p_task_id));

    update workflow.runs set parent_task_id = p_task_id where id = v_child;
    update workflow.tasks set child_run_id = v_child where id = p_task_id;

    -- A child of only sql/p8ql/matrix steps is already finished. Its
    -- completion trigger fired before the link above existed, so resolve the
    -- parent here rather than leaving it blocked on a run that is over.
    select status, context into v_status, v_ctx from workflow.runs where id = v_child;
    if v_status = 'completed' then
        perform workflow.complete_task(p_task_id, jsonb_build_object('result', v_ctx));
    elsif v_status in ('failed', 'cancelled') then
        perform workflow.fail_task(p_task_id,
            jsonb_build_object('child_run_status', v_status, 'child_run_id', v_child), true);
    end if;

    return v_child;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.resolve_parent_on_child_completion() returns trigger as $$
begin
    if new.status in ('completed', 'failed', 'cancelled') and old.status = 'running' then
        if new.parent_task_id is not null then
            if new.status = 'completed' then
                perform workflow.complete_task(new.parent_task_id, new.context);
            else
                perform workflow.fail_task(new.parent_task_id, jsonb_build_object('child_run_status', new.status));
            end if;
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_resolve_parent_on_child_completion
    after update of status on workflow.runs
    for each row execute function workflow.resolve_parent_on_child_completion();

-- ------------------------------------------------------------
-- 11. FIX #1 + #4: workflow.add_task now (a) locks dependency rows before
--     deciding pending_deps, closing the completion race, and
--     (b) refuses to insert under an already-cancelled run.
-- ------------------------------------------------------------
create or replace function workflow.add_task(
    p_run_id uuid, p_step_key text, p_queue text,
    p_depends_on uuid[] default '{}', p_kind text default 'work',
    p_input jsonb default null, p_rate_key text default null
) returns uuid as $$
declare
    v_id uuid;
    v_dep uuid;
    v_dep_status text;
    v_count int := 0;
begin
    if exists (select 1 from workflow.runs where id = p_run_id and status = 'cancelled') then
        return null;   -- fix #4: no new work under a cancelled run
    end if;

    -- fix #1: lock every dependency row BEFORE deciding pending_deps.
    -- This serializes against any concurrent workflow.complete_task on the same
    -- dependency: whichever transaction wins the lock, the other sees
    -- (or produces) a consistent outcome -- no stuck task is possible.
    foreach v_dep in array coalesce(p_depends_on, '{}')
    loop
        select status into v_dep_status from workflow.tasks where id = v_dep for update;
        if v_dep_status is distinct from 'done' then
            v_count := v_count + 1;
        end if;
    end loop;

    insert into workflow.tasks (run_id, step_key, queue, kind, input, rate_key, pending_deps, status)
    values (
        p_run_id, p_step_key, coalesce(p_queue, 'default'), p_kind, p_input, p_rate_key,
        v_count,
        case when v_count > 0 then 'pending'
             when p_kind = 'signal' then 'waiting_external'
             else 'ready' end
    )
    on conflict (run_id, step_key) do nothing
    returning id into v_id;

    if v_id is not null then
        foreach v_dep in array coalesce(p_depends_on, '{}') loop
            insert into workflow.task_dependencies (task_id, depends_on_task_id) values (v_id, v_dep)
            on conflict do nothing;
        end loop;
        if v_count = 0 and p_kind not in ('signal') then
            perform pg_notify('task_ready', coalesce(p_queue, 'default'));
        end if;
    end if;

    return v_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 12. Decision tasks — same fixes applied: dependency locking +
--     cancelled-run guard, still atomic (branch + complete in one call).
-- ------------------------------------------------------------
drop function if exists workflow.complete_decision_task(uuid, jsonb, jsonb);
create or replace function workflow.complete_decision_task(
    p_task_id uuid,
    p_output jsonb,
    p_new_tasks jsonb default '[]'::jsonb,
    -- [{step_key, queue, depends_on: [uuid,...], kind, input, rate_key}]
    p_worker_id text default null
) returns void as $$
declare
    v_holder text;
    v_run_id uuid;
    v_item jsonb;
    v_new_id uuid;
    v_dep_text text;
    v_dep uuid;
    v_dep_status text;
    v_count int;
    v_new_hash text;
    v_prior_hash text;
begin
    select run_id into v_run_id from workflow.tasks where id = p_task_id;

    if exists (select 1 from workflow.runs where id = v_run_id and status = 'cancelled') then
        update workflow.tasks set status = 'cancelled' where id = p_task_id and status = 'running';
        return;   -- fix #4: run was cancelled while this decision was executing
    end if;

    -- §23's lease fence, minus the terminal-state half. A decision task is the
    -- one completion path where re-calling on a `done` task is legitimate --
    -- that is what replay IS, and the determinism guard below is the check that
    -- matters there. What must still be refused is a worker acting on a lease
    -- that was reaped and handed to somebody else, since two live workers
    -- branching a run independently is the one thing this function must never
    -- allow.
    if p_worker_id is not null then
        select claimed_by into v_holder from workflow.tasks where id = p_task_id;
        if v_holder is not null and v_holder is distinct from p_worker_id then
            perform workflow.lease_violation(p_task_id, p_worker_id, 'decide');
            return;
        end if;
    end if;

    -- Determinism guard (research finding: "pure decision" was a
    -- convention, not enforced). If this decision task has been
    -- executed before (retry, or offline replay against the recorded
    -- input_snapshot), its output must hash identically. A mismatch
    -- means something non-deterministic leaked into the decision
    -- function (wall clock, random id, external state read) -- fail
    -- loudly rather than silently branching differently.
    v_new_hash := md5(p_output::text || p_new_tasks::text);
    select decision_output_hash into v_prior_hash from workflow.tasks where id = p_task_id;
    if v_prior_hash is not null and v_prior_hash <> v_new_hash then
        raise exception 'non-deterministic decision output for task %: expected hash %, got %. '
            'A decision task must be a pure function of its recorded input -- check for '
            'now()/random()/external reads inside it.', p_task_id, v_prior_hash, v_new_hash;
    end if;

    for v_item in select * from jsonb_array_elements(coalesce(p_new_tasks, '[]'::jsonb))
    loop
        v_count := 0;
        -- fix #1: lock dependencies before inserting, same as workflow.add_task
        for v_dep_text in select jsonb_array_elements_text(coalesce(v_item->'depends_on', '[]'::jsonb))
        loop
            v_dep := v_dep_text::uuid;
            select status into v_dep_status from workflow.tasks where id = v_dep for update;
            if v_dep_status is distinct from 'done' then
                v_count := v_count + 1;
            end if;
        end loop;

        insert into workflow.tasks (run_id, step_key, queue, kind, input, rate_key, pending_deps, status)
        values (
            v_run_id,
            v_item->>'step_key',
            coalesce(v_item->>'queue', 'default'),
            coalesce(v_item->>'kind', 'work'),
            v_item->'input',
            v_item->>'rate_key',
            v_count,
            case when v_count > 0 then 'pending'
                 when coalesce(v_item->>'kind','work') = 'signal' then 'waiting_external'
                 else 'ready' end
        )
        on conflict (run_id, step_key) do nothing
        returning id into v_new_id;

        if v_new_id is not null then
            for v_dep_text in select jsonb_array_elements_text(coalesce(v_item->'depends_on', '[]'::jsonb))
            loop
                v_dep := v_dep_text::uuid;
                insert into workflow.task_dependencies (task_id, depends_on_task_id)
                values (v_new_id, v_dep)
                on conflict do nothing;
            end loop;
        end if;
    end loop;

    -- clock_timestamp(), not now() -- §21c. This function kept the transaction
    -- timestamp after complete_task was fixed, which is the "a fix lands in one
    -- of two copies" failure the consolidation pass exists to stop, one function
    -- over. completed_at is the saga's ORDERING column: every task finishing in
    -- one transaction shares now(), so a decision task inside a saga group
    -- compensated in forward order.
    update workflow.tasks set status = 'done', output = p_output,
        completed_at = clock_timestamp(),
        decision_output_hash = v_new_hash
    where id = p_task_id;
    perform workflow.check_run_completion(v_run_id);
    perform workflow.check_compensation_completion(v_run_id);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 13. Timers
-- ------------------------------------------------------------
-- completed_at is set here for the same §21c reason: it is the saga ordering
-- column, and a timer that fired was previously left with it NULL. A NULL sorts
-- first under `order by completed_at desc`, so a timer inside a saga group was
-- compensated before everything that ran after it.
create or replace function workflow.promote_due_timers() returns int as $$
    with due as (
        update workflow.tasks set status = 'done', output = '{"fired": true}'::jsonb,
            completed_at = clock_timestamp()
        where kind = 'timer' and status = 'ready' and run_after <= now()
        returning id
    )
    select count(*)::int from due;
$$ language sql;
-- select cron.schedule('promote-timers', '*/10 seconds', $$select workflow.promote_due_timers()$$);

-- ------------------------------------------------------------
-- 14. Reaper
-- ------------------------------------------------------------
-- Current form (§23). The previous version returned every stale task straight
-- to `ready` and touched nothing else, which had two consequences neither the
-- spec nor a test had ever observed, because nothing had ever called it.
--
--   * `max_attempts` was not a budget. A task whose worker dies every time was
--     reaped and re-claimed without limit -- measured at attempts=10 against
--     max_attempts=5, still claimable, run still `running`. Worse, it was
--     INVISIBLE: each claim refreshes heartbeat_at, so v_stuck_tasks never saw
--     it. A task consuming a worker slot forever while every dashboard reads
--     green is this collection's defining failure shape.
--   * There was no backoff, so a crash loop ran at claim speed.
--
-- Both are fixed by not having a second retry policy. `fail_task(.., false)`
-- IS the retry policy -- attempt budget, exponential backoff, terminal
-- transition, run failure and saga compensation -- so a dead worker is now
-- just a failure like any other, and the only thing this function decides is
-- which tasks are dead.
-- ---------------------------------------------------------------------------
-- Queue depth, for an autoscaler.
--
-- One function rather than a table grant, and that is the whole point. An
-- autoscaler runs OUTSIDE the database and outside the namespace it scales:
-- KEDA's operator holds this credential and reads it across every namespace
-- it serves. Handing that position `select on workflow.tasks` widens further
-- than it looks -- the RLS policy on tasks reads workflow.runs, so the grant
-- cascades to a second table, and the role that was defined by holding NO
-- table privileges now holds two. Measured, on a live cluster: granting
-- select on tasks alone produces `permission denied for table runs`.
--
-- EXECUTE on one STABLE SECURITY DEFINER function has none of that. It is
-- also the seam where the count can be made correct once, for everyone.
--
-- IT COUNTS `running` AS WELL AS CLAIMABLE-`ready`, and the obvious version
-- that counts only `ready` is wrong in a way that appears solely under long
-- tasks: a pool of ten pods each three minutes into a task reports depth 0,
-- the autoscaler reads that as idle, and it scales the pods out from under
-- work in flight. The arithmetic stays right because an autoscaler's target
-- is PER REPLICA -- N pods each holding one task report depth N against a
-- target of 1, which resolves to N. Work drains, both counts reach zero, and
-- the pool scales to zero with no special case anywhere.
--
-- `run_after <= now()` is equally deliberate: a task backing off between
-- retries is not work anyone can do yet, and holding a pod for it burns money
-- until the backoff expires.
--
-- The residual inaccuracy is a task `running` on a pod that died, which
-- inflates depth until reap_stale_tasks() returns it to `ready`. Bounded by
-- that reaper RUNNING -- with no clock there is no bound, and a pool never
-- scales to zero. Also measured.
-- ---------------------------------------------------------------------------
create or replace function workflow.queue_depth(p_queue text)
returns bigint as $$
    select count(*) from workflow.tasks
    where queue = p_queue
      and (status = 'running'
           or (status = 'ready' and run_after <= now()));
$$ language sql stable;

create or replace function workflow.reap_stale_tasks() returns int as $$
declare v_rec record; v_n int := 0;
begin
    for v_rec in
        select t.id, t.claimed_by, t.attempts, t.max_attempts,
               coalesce(qc.stale_timeout, interval '2 minutes') as timeout
        from workflow.tasks t
        left join workflow.queue_config qc on qc.queue = t.queue
        where t.status = 'running'
          and t.heartbeat_at < now() - coalesce(qc.stale_timeout, interval '2 minutes')
    loop
        perform workflow.fail_task(v_rec.id, jsonb_build_object(
            'error', format(
                'worker %s stopped heartbeating for longer than %s; the lease was '
                'reaped on attempt %s of %s',
                coalesce(v_rec.claimed_by, '(unclaimed)'), v_rec.timeout,
                v_rec.attempts, v_rec.max_attempts),
            'reaped', true,
            'reaped_from', v_rec.claimed_by), false);
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;
-- select cron.schedule('reap-stale-tasks', '*/1 * * * *', $$select workflow.reap_stale_tasks()$$);

-- ------------------------------------------------------------
-- 15. Observability views
-- ------------------------------------------------------------
create view workflow.v_queue_depth as
    select queue, status, count(*) as value from workflow.tasks group by queue, status;

create view workflow.v_run_progress as
    select r.id as run_id, d.name as workflow_name, r.status as run_status,
           count(*) filter (where t.status = 'done') as done,
           count(*) as total, r.created_at, r.updated_at
    from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    join workflow.tasks t on t.run_id = r.id
    group by r.id, d.name, r.status, r.created_at, r.updated_at;

create view workflow.v_stuck_tasks as
    select t.id, t.run_id, t.queue, t.step_key, t.status,
           extract(epoch from now() - t.created_at) as age_seconds
    from workflow.tasks t
    left join workflow.queue_config qc on qc.queue = t.queue
    where (t.status = 'ready' and t.run_after < now() - interval '5 minutes')
       or (t.status = 'running' and t.heartbeat_at < now() - coalesce(qc.stale_timeout, interval '2 minutes'))
       or (t.status = 'waiting_external' and t.created_at < now() - interval '1 hour');

-- Reports on the COMPENSATION tasks (the work that undoes), not merely on
-- forward tasks that have been marked as having had a compensation created --
-- the same distinction the check_compensation_completion bug turned on.
-- §23. A refused call is a fact about the deployment, not a nuisance: repeated
-- lease violations from one queue mean workers are dying, or a stale_timeout is
-- shorter than the work. Silently dropping them is what made the reaper's own
-- defects invisible for as long as they were.
create view workflow.v_lease_violations as
    select e.detail->>'queue'  as queue,
           e.detail->>'op'     as op,
           e.detail->>'why'    as why,
           e.detail->>'caller' as caller,
           e.detail->>'holder' as holder,
           count(*)            as refusals,
           max(e.at)           as last_seen
    from workflow.task_events e
    where e.detail->>'event' = 'lease_violation'
    group by 1,2,3,4,5 order by 6 desc;

create view workflow.v_compensation_status as
    select f.run_id, f.saga_group,
           count(*) as total_compensatable,
           count(c.id) as compensations_created,
           count(*) filter (where c.status = 'done') as compensations_done,
           count(*) filter (where c.status = 'failed') as compensations_failed
    from workflow.tasks f
    left join workflow.tasks c on c.compensates_task_id = f.id
    where f.saga_group is not null and f.compensation_task_key is not null
    group by f.run_id, f.saga_group;

create view workflow.v_decision_history as
    select te.run_id, te.task_id, t.step_key, te.input_snapshot, t.output as decision_output, te.at
    from workflow.task_events te
    join workflow.tasks t on t.id = te.task_id
    where t.kind = 'decision' and te.to_status = 'running'
    order by te.run_id, te.at;

-- ============================================================
-- 16. Role model, ownership, and RLS.
--
-- This section did not exist until the schema was prototyped against real
-- cross-subsystem cases. Before it, this file had NO grants, NO RLS, and no
-- SECURITY DEFINER anywhere -- it implicitly assumed every caller was the
-- table owner. That assumption is wrong for both real callers (a KEDA-scaled
-- worker, and an end user reading their own runs through PostgREST), and the
-- gap was not academic: three other spec sections already described
-- `workflow.runs.owner_id` + RLS as though it existed
-- (user-rbac/spec.md §6, its schema.sql §8 sketch, and this system's own
-- spec.md §13 usage metering).
--
-- THE FAILURE THIS PREVENTS, reproduced end to end against PG19 beta3:
-- adding the RLS that those sections describe, without also making the
-- engine's mutation functions SECURITY DEFINER, causes SILENT DATA LOSS.
-- complete_task() updates workflow.runs to merge a step's output into
-- run.context. Under RLS, a worker (which has no JWT, so current_user_id()
-- is null) matches no rows -- and an UPDATE matching zero rows is not an
-- error. Measured, same procedure, only the function's security mode varying:
--
--     SECURITY INVOKER -> task status 'done', run.context {}          <-- lost
--     SECURITY DEFINER -> task status 'done', run.context {"gather":...}
--
-- Every step output silently discarded while the run reports success. The
-- lesson generalizes past this schema: whenever an RLS-protected table is
-- written by a trusted background process, the write path must be a
-- SECURITY DEFINER function, or RLS turns a write into a no-op instead of a
-- refusal.
-- ============================================================

-- (a) The TRUSTED path: the engine's own state machine. These run as the
-- table owner (which bypasses RLS -- ENABLE, never FORCE, same rule as
-- user-rbac/schema.sql §9), because a worker is not a user and cannot
-- satisfy a user-scoped policy. search_path pinned, same CVE-2018-1058
-- hardening as every other SECURITY DEFINER function in this collection.
alter function workflow.claim_task(text, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.claim_tasks(text, text, int)
    security definer set search_path = pg_catalog, public;
alter function workflow.claim_task_rate_limited(text, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.heartbeat_task(uuid, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.complete_task(uuid, jsonb, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.fail_task(uuid, jsonb, boolean, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.complete_decision_task(uuid, jsonb, jsonb, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.signal_task(uuid, text, jsonb)
    security definer set search_path = pg_catalog, public;
alter function workflow.start_workflow(text, jsonb, text, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.start_child_workflow(uuid, text, jsonb)
    security definer set search_path = pg_catalog, public;
alter function workflow.add_task(uuid, text, text, uuid[], text, jsonb, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.cancel_run(uuid)
    security definer set search_path = pg_catalog, public;
alter function workflow.begin_compensation(uuid, text)
    security definer set search_path = pg_catalog, public;
alter function workflow.promote_due_timers()
    security definer set search_path = pg_catalog, public;
alter function workflow.queue_depth(text)
    security definer set search_path = workflow, pg_catalog;
alter function workflow.reap_stale_tasks()
    security definer set search_path = pg_catalog, public;

-- The audit trigger, likewise. Without this a worker needs INSERT on
-- task_events just to change a task's status -- i.e. write access to the log
-- that audits it, which it could then forge entries in. An audit trigger must
-- write with the owner's privileges, never the caller's.
alter function workflow.log_task_transition()
    security definer set search_path = pg_catalog, public;
alter function workflow.cascade_task_status()
    security definer set search_path = pg_catalog, public;

-- A worker holds no table grants, so it cannot read the run its task belongs
-- to -- and start_workflow() puts the CALLER's input on the RUN, while a task
-- only carries whatever its step spec declared. Without this function a worker
-- literally cannot see what it is supposed to work on: confirmed by running a
-- real embedding pipeline, where the worker got `input = NULL` and
-- `permission denied for table runs` when it tried to join for the
-- resource_id. That made the engine unusable for any workflow whose steps
-- share run-level data, which is nearly all of them.
--
-- Returns the run's input, its accumulated context (so a later step can read
-- an earlier step's output -- the whole point of complete_task() merging into
-- context), and the task's own input, in one call.
--
-- Scoped to a task the CALLER HAS CLAIMED. Without that check this is a
-- cross-tenant read primitive: any worker could pass any task_id and get that
-- run's input. The claim is the authorization, exactly as the grant is the
-- authorization for claim_task itself.
-- Current form. It reached this shape in section 22d (`{{run.$*}}` is bound before the worker ever sees it.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.get_task_context(p_task_id uuid, p_worker_id text)
returns jsonb as $$
declare
    v_task workflow.tasks;
    v_run  workflow.runs;
    v_meta jsonb;
begin
    select * into v_task from workflow.tasks where id = p_task_id;
    if not found then
        raise exception 'task % not found', p_task_id;
    end if;
    if v_task.claimed_by is distinct from p_worker_id or v_task.status <> 'running' then
        raise exception
            'task % is not currently claimed by % -- a worker may only read the context of a task it holds',
            p_task_id, p_worker_id;
    end if;

    select * into v_run from workflow.runs where id = v_task.run_id;

    -- {{run.$session}} binds to THIS step's thread: the group is a property of
    -- the step, so the template reads the same everywhere and two groups in one
    -- run are two independent conversations.
    v_meta := workflow.run_meta(v_task.run_id)
              || case when v_task.input ? 'session_group'
                      then jsonb_build_object('$session',
                             workflow.run_session(v_task.run_id,
                               v_task.input->>'session_group')::text)
                      else '{}'::jsonb end;

    return jsonb_build_object(
        'run_id',      v_run.id,
        -- Still merged, so a worker that DOES admit `$` sees them as ordinary
        -- run input. The substitution below is what makes it work on one that
        -- does not.
        'run_input',   coalesce(v_run.input, '{}'::jsonb) || v_meta,
        'context',     coalesce(v_run.context, '{}'::jsonb),
        'task_input',  workflow.substitute_meta(
                           coalesce(v_task.input, '{}'::jsonb), v_meta),
        'run_meta',    v_meta,
        'step_key',    v_task.step_key,
        'kind',        v_task.kind,
        'item',        v_task.input->'item',
        'matrix_parent_step', (select m.step_key from workflow.tasks m
                               where m.id = v_task.matrix_parent_id),
        'attempt',     v_task.attempts,
        'trace_id',    v_run.trace_id,
        'span_id',     v_task.span_id
    );
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- (b) Deny by default, then grant only the entry points -- same rule and same
-- reasoning as user-rbac/schema.sql §9(a).
revoke execute on all functions in schema workflow from public;

grant usage on schema workflow to worker, scheduler, authenticated;

-- The worker role: executes the state machine, and that is ALL it can do. It
-- gets NO table grants whatsoever -- every one of its interactions is a
-- function call. Enumerated the hard way: granting a worker direct table
-- access meant it needed SELECT/UPDATE on tasks, INSERT on task_events,
-- SELECT on task_dependencies, SELECT/UPDATE on runs, and EXECUTE on
-- rbac.current_user_id() -- five tables and a cross-schema function, just to
-- finish one task. Routing everything through SECURITY DEFINER functions
-- reduces that to this list, and removes the forge-the-audit-log problem.
-- Read-only, and the only thing an autoscaler needs.
grant execute on function workflow.queue_depth(text) to worker;
grant execute on function workflow.claim_task(text, text) to worker;
grant execute on function workflow.claim_tasks(text, text, int) to worker;
grant execute on function workflow.claim_task_rate_limited(text, text) to worker;
grant execute on function workflow.heartbeat_task(uuid, text) to worker;
grant execute on function workflow.complete_task(uuid, jsonb, text) to worker;
grant execute on function workflow.fail_task(uuid, jsonb, boolean, text) to worker;
grant execute on function workflow.complete_decision_task(uuid, jsonb, jsonb, text) to worker;
grant execute on function workflow.start_child_workflow(uuid, text, jsonb) to worker;
grant execute on function workflow.add_task(uuid, text, text, uuid[], text, jsonb, text) to worker;
grant execute on function workflow.get_task_context(uuid, text) to worker;

-- Scheduled maintenance (pg_cron, or an operator). Not the worker's job.
-- artifact_ref is the one definition of "is this an artifact ref"; a worker
-- deciding whether a prior step offloaded its bytes asks this rather than
-- re-implementing the key test.
grant execute on function workflow.artifact_ref(jsonb) to worker, authenticated;

grant execute on function workflow.promote_due_timers() to scheduler;
grant execute on function workflow.reap_stale_tasks() to scheduler;

-- End users, via PostgREST: start a run, signal it, cancel their own.
grant execute on function workflow.start_workflow(text, jsonb, text, text) to authenticated;
grant execute on function workflow.signal_task(uuid, text, jsonb) to authenticated;
grant execute on function workflow.cancel_run(uuid) to authenticated;

-- (c) Self-check for THIS file's invariant. The view-ownership check lives in
-- integration-rbac.sql, alongside the views it validates.
do $$
declare
    v_bad text;
begin
    -- Every function that writes state must be SECURITY DEFINER, or a worker's
    -- write becomes a silent no-op once integration-rbac.sql adds RLS (see this
    -- section's header). This is the check that would have caught the data-loss
    -- bug that motivated this whole section.
    select string_agg(p.proname, ', ')
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'workflow'
      and p.proname in ('claim_task','claim_tasks','claim_task_rate_limited',
                        'heartbeat_task','complete_task','fail_task',
                        'complete_decision_task','signal_task','start_workflow',
                        'start_child_workflow','add_task','cancel_run',
                        'begin_compensation','promote_due_timers',
                        'reap_stale_tasks','log_task_transition',
                        'cascade_task_status')
      and not p.prosecdef;
    if v_bad is not null then
        raise exception
            'STATE-MUTATING FUNCTIONS ARE NOT SECURITY DEFINER: %. Once RLS is on '
            'workflow.runs, a worker (no JWT) matches no rows, and an UPDATE '
            'matching zero rows is NOT an error -- step outputs would be silently '
            'discarded while runs report success.', v_bad;
    end if;

    raise notice 'workflow-engine self-check passed: all state mutators are SECURITY DEFINER';
end $$;

-- ============================================================
-- 17. `sql` steps -- declarative, and executed by NOBODY.
--
-- The question this answers: which step kinds actually need a process outside
-- Postgres? Only two. `http_call` does, because it performs network I/O.
-- `work` does, because it runs arbitrary user code. Everything else --
-- indexing, projection, a query, a rollup -- is just SQL, and making a worker
-- claim a task in order to send SQL back to the same database is machinery
-- with no purpose.
--
-- So a `sql` step runs IN the database, the moment it becomes ready, with no
-- poller, no queue consumer and no deployment. A workflow of only `sql` steps
-- completes with nothing running anywhere.
--
-- This does NOT weaken the "database never blocks on HTTP" invariant, and it
-- is worth being precise about why: that invariant is about waiting on
-- someone ELSE's latency, which is unbounded and belongs in a worker where it
-- costs worker capacity rather than a connection slot. A `sql` step waits only
-- on Postgres, which is work the database was going to do anyway.
--
-- THREE GUARDS, because "execute SQL from a table" is otherwise a
-- privilege-escalation primitive and a long-transaction generator:
--
--   1. ALLOW-LIST, not arbitrary SQL. A step names a registered function; it
--      cannot supply a statement. Registration is an admin act (owner-only),
--      so authoring a workflow never widens what can be executed.
--   2. A SUBTRANSACTION per step. A failing step fails ITSELF -- it must not
--      abort the transaction of whichever worker happened to complete the
--      preceding task. Without this, one bad SQL step would roll back an
--      unrelated worker's completed work.
--   3. A statement timeout, so a pathological query cannot hold the caller's
--      transaction open indefinitely.
-- ============================================================

-- The kind is added by ALTER as well as in the CREATE TABLE above, so an
-- existing installation picks it up. `create table` is skipped when the table
-- exists, which silently leaves the old constraint in place -- caught by a
-- `sql` step being rejected on a database that had already been installed.
alter table workflow.tasks drop constraint if exists tasks_kind_check;
alter table workflow.tasks add constraint tasks_kind_check
    check (kind in ('work','decision','timer','signal','sub_workflow','http_call','sql'));

create table workflow.step_functions (
    name          text primary key,        -- what a step spec names
    fn            text not null,            -- schema-qualified function
    arg_types     text[] not null default '{}',
    timeout_ms    int not null default 30000,
    description   text,
    registered_at timestamptz not null default now()
);

-- Registering is deliberately owner-only (no grant below): it decides what a
-- workflow author is allowed to cause to run.
-- Current form. It reached this shape in section 22b (BUG 2 -- registration checked the wrong role's privileges.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.register_step_function(
    p_name text, p_fn text, p_arg_types text[] default '{}',
    p_timeout_ms int default 30000, p_description text default null
) returns void as $$
declare
    v_sig     text := p_fn || '(' || array_to_string(p_arg_types, ',') || ')';
    v_oid     oid;
    v_definer name;
    v_nsp     text;
begin
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
        raise exception 'function % does not exist', v_sig;
    end if;

    -- Whoever owns execute_sql_step is who will run this at dispatch.
    select pg_get_userbyid(proowner) into v_definer
    from pg_proc where oid = to_regprocedure('workflow.execute_sql_step(uuid)');

    select n.nspname into v_nsp
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = v_oid;

    if not has_schema_privilege(v_definer, v_nsp, 'USAGE') then
        raise exception
            'function % is not reachable by %, which is the role that will execute it '
            '(execute_sql_step is SECURITY DEFINER). Registration would succeed and every '
            'invocation would fail with "permission denied for schema %". Run: '
            'grant usage on schema % to %;',
            v_sig, v_definer, v_nsp, quote_ident(v_nsp), quote_ident(v_definer::text);
    end if;
    if not has_function_privilege(v_definer, v_oid, 'EXECUTE') then
        raise exception
            'function % exists and its schema is reachable, but % cannot execute it. Run: '
            'grant execute on function % to %;', v_sig, v_definer, v_sig, quote_ident(v_definer::text);
    end if;

    insert into workflow.step_functions (name, fn, arg_types, timeout_ms, description)
    values (p_name, p_fn, p_arg_types, p_timeout_ms, p_description)
    on conflict (name) do update set fn = excluded.fn, arg_types = excluded.arg_types,
        timeout_ms = excluded.timeout_ms, description = excluded.description;
end;
$$ language plpgsql;

-- Executes one ready `sql` task. Returns true if it did something.
-- Resolve {{steps.x.y}} / {{run.x}} in a sql step's arguments.
--
-- The worker does this for http_call steps; sql steps need it for the same
-- reason and it was missing -- so a P8QL step could not consume the output of
-- the REST step before it, which is exactly the composition the YAML syntax
-- exists to express. Found by running a pipeline whose SEARCH step needed the
-- embedding produced by a preceding model call.
--
-- Deliberately narrower than the worker's resolver: no {{env.*}}, because the
-- database has no business reading the deployment's environment, and that is
-- precisely the sort of ambient authority this collection keeps removing.
-- workflow.resolve_args(jsonb,uuid) is defined in section 20a.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- Current form. It reached this shape in section 20b (One place that calls an allow-listed function.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.execute_sql_step(p_task_id uuid)
returns boolean as $$
declare
    t      workflow.tasks;
    v_spec jsonb;
    v_out  jsonb;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found or t.status <> 'ready' or t.kind <> 'sql' then
        return false;
    end if;

    update workflow.tasks set status = 'running', claimed_by = 'in-database',
           claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
    where id = p_task_id;

    v_spec := coalesce(t.input, '{}'::jsonb);

    -- The run this step belongs to, published transaction-locally so an
    -- allow-listed function can tell "my own run" from "a run id somebody
    -- typed into a step spec". Needed the moment a step function takes a task
    -- id -- matrix_outputs does -- because a workflow author could otherwise
    -- name another tenant's matrix task and read its results. Transaction-local
    -- (set_config's third argument), so it cannot leak into a pooled
    -- connection's next transaction; the same hazard rbac.current_user_id()
    -- was hardened against.
    perform set_config('workflow.current_run_id', t.run_id::text, true);

    begin      -- subtransaction: a failure here must not abort the caller
        v_out := workflow.call_step_function(
            v_spec->>'function', v_spec->'args', t.run_id, t.input->'item');
        perform workflow.complete_task(p_task_id, jsonb_build_object('result', v_out));
        return true;
    exception when others then
        perform workflow.fail_task(p_task_id,
            jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate),
            -- A missing registration or a bad signature will fail identically
            -- on every retry; a deadlock or timeout will not.
            sqlstate in ('42883','42P01','P0001'));
        return true;
    end;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Run every ready `sql` task for one run, until none remain. Chained sql steps
-- therefore complete in one call: index -> rollup -> notify needs no round trip.
-- Bounded, because a definition cycle would otherwise spin here.
-- Current form. It reached this shape in section 21i (Timers and sub-workflows start themselves.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.drain_sql_steps(p_run_id uuid, p_max int default 50)
returns int as $$
declare v_id uuid; v_kind text; v_done int := 0;
begin
    loop
        select id, kind into v_id, v_kind from workflow.tasks
        where run_id = p_run_id and kind in ('sql','matrix','sub_workflow') and status = 'ready'
          and run_after <= now()
        order by kind, created_at
        limit 1;
        exit when v_id is null or v_done >= p_max;
        if v_kind = 'sql' then
            perform workflow.execute_sql_step(v_id);
        elsif v_kind = 'matrix' then
            perform workflow.expand_matrix(v_id);
        else
            perform workflow.start_child_workflow(v_id,
                (select input->>'workflow' from workflow.tasks where id = v_id),
                coalesce((select input->'input' from workflow.tasks where id = v_id), '{}'::jsonb));
        end if;
        v_done := v_done + 1;
    end loop;
    return v_done;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The hook that makes it automatic. Fires after a task's status changes, so a
-- `sql` step becomes ready and runs within the same statement that unblocked
-- it -- no poller, no latency, nothing deployed.
-- Fires when a `sql` step is UPDATED into 'ready'. Both entry points are
-- updates, so this catches everything: start_workflow's second pass flips
-- roots ready, and cascade_task_status flips dependents ready.
--
-- ON UPDATE ONLY, and that is not an oversight -- an AFTER INSERT trigger was
-- tried first and was actively wrong. start_workflow builds in two passes:
-- pass 1 inserts every step with pending_deps = 0 (dependencies are not wired
-- until pass 2), so mark_roots_ready marks EVERY step ready on insert. An
-- insert-time autorun therefore executed the whole workflow immediately, in
-- arbitrary order, ignoring the dependency graph -- and pass 2 then reset the
-- statuses underneath it, re-running the first step and reverting the second
-- to 'pending' while the run reported 'completed'. The task_events trail
-- showed all of it. During construction the graph is not yet valid, so the
-- only safe signal is a deliberate transition INTO ready.
--
-- Re-entry is safe: execute_sql_step() moves the row to 'running' before doing
-- any work, so the recursive fire sees a non-ready row and stops. A chain of
-- sql steps runs to completion through ordinary cascade.
-- Current form. It reached this shape in section 21i (Timers and sub-workflows start themselves.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.autorun_sql_steps() returns trigger as $$
begin
    if new.status = 'ready' and old.status is distinct from 'ready' then
        if new.kind = 'sql' then
            perform workflow.execute_sql_step(new.id);
        elsif new.kind = 'matrix' then
            perform workflow.expand_matrix(new.id);
        elsif new.kind = 'sub_workflow' then
            perform workflow.start_child_workflow(
                new.id, new.input->>'workflow',
                coalesce(new.input->'input', '{}'::jsonb));
        elsif new.kind = 'timer' and (new.input ? 'delay_seconds') then
            -- Measured from readiness, not from the run's start.
            update workflow.tasks
            set run_after = clock_timestamp()
                          + ((new.input->>'delay_seconds')::numeric * interval '1 second')
            where id = new.id and run_after <= clock_timestamp();
        end if;
    end if;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create trigger trg_autorun_sql_steps
    after update of status on workflow.tasks
    for each row execute function workflow.autorun_sql_steps();

grant execute on function workflow.execute_sql_step(uuid) to worker, authenticated;
grant execute on function workflow.drain_sql_steps(uuid, int) to worker, authenticated;
-- The allow-list is readable by `authenticated` for discoverability: a user
-- authoring a `sql` step should be able to see which functions are callable
-- without guessing. It is NOT granted to `worker`, and that omission is the
-- point: execute_sql_step is SECURITY DEFINER, so nothing needs this grant to
-- run, and a service role holding a table grant it never uses is exactly the
-- privilege that survives long enough to be useful to an attacker. The claim
-- "no service role holds a table grant" is only true if it stays true.
grant select on workflow.step_functions to authenticated;

-- ============================================================
-- 18. YAML authoring: workflow.define_yaml()
--
-- The payoff of §17 plus the http_call handler: a workflow whose steps are
-- only P8QL and REST needs NO USER CODE ANYWHERE. The worker stops being
-- something a user writes and becomes something purely generic that ships.
--
--     name: classify_recent
--     steps:
--       - id: find                        -- two tasks: SEARCH needs a vector
--         p8ql: 'SEARCH "safety recall" FROM chunks LIMIT 5'
--       - id: judge
--         needs: [find]
--         agent: classifier          # a row in agentic.agents, by NAME
--         input: 'Classify: {{steps.find.result}}'
--       - id: reindex
--         needs: [judge]
--         sql: {function: rebuild_graph_index, args: [company]}
--
-- compiles to ordinary workflow.tasks rows, so retry, backoff, the reaper,
-- saga, cancellation and OTel tracing all apply unchanged -- this is sugar
-- over start_workflow, never a second execution engine.
--
-- The YAML parse itself is in the p8_query extension (serde_yaml); doing it in
-- PL/pgSQL is not a reasonable thing to attempt. Keeping it there rather than
-- in the Content Server means authoring is SQL-native: no service has to be
-- running to define a workflow.
-- ============================================================

-- Current form. It reached this shape in section 22c (BUG 3 -- the two halves can ship out of step, silently.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.define_yaml(p_yaml text)
returns uuid as $$
declare
    c        jsonb;
    v_id     uuid;
    v_name   text;
    v_ver    int;
    v_caps   jsonb;
    v_stale  text[];
    v_spec   jsonb;
begin
    if to_regprocedure('p8_compile_workflow(text)') is null then
        raise exception
            'workflow.define_yaml needs the percolate extension (p8_compile_workflow). '
            'Install it, or insert the spec into workflow.definitions as JSON.';
    end if;

    execute 'select p8_compile_workflow($1)' into c using p_yaml;

    -- THE SKEW CHECK RUNS ON SUCCESS TOO, and the first version of it did not.
    -- That was the whole bug: a missing STEP KIND fails loudly, so checking only
    -- the failure branch caught those -- but `output_schema` is not a step kind.
    -- serde drops the unknown key, the document compiles CLEAN, and the declared
    -- contract is simply absent. An author who writes a contract and gets a
    -- green run reasonably concludes it is enforced.
    --
    -- A silently dropped contract is worse than an unsupported feature, so this
    -- refuses rather than warns. The engine's own comment on the probe said
    -- "compiling is not evidence -- the emitted SPEC is", and then the code
    -- went on to treat compiling as evidence.
    v_caps := workflow.compiler_capabilities();
    if (v_caps->>'available')::boolean then
        select array_agg(f) into v_stale
        from jsonb_array_elements_text(v_caps->'missing') f
        where p_yaml ~ ('(^|\n)[[:space:]]*' || f || '[[:space:]]*:');
    end if;

    if v_stale is not null then
        raise exception
            'this document declares %, which the INSTALLED compiler cannot emit. The SQL '
            'schema supports it and the compiled extension predates it -- a version skew, '
            'not a syntax error.%  Rebuild the percolate extension, or write the spec as '
            'JSON. (workflow.compiler_capabilities() lists everything missing.)',
            array_to_string(v_stale, ', '),
            case when coalesce((c->>'ok')::boolean, false)
                 then ' It COMPILED CLEAN: the key was dropped and the contract would not '
                      'have existed at runtime, with nothing to tell you.'
                 else ' The compiler said: ' || coalesce(c->>'error', '?') || '.' end;
    end if;

    if not coalesce((c->>'ok')::boolean, false) then
        raise exception 'workflow YAML did not compile: %', c->>'error';
    end if;

    v_name := c#>>'{workflow,name}';
    v_ver  := coalesce((c#>>'{workflow,version}')::int, 1);
    v_spec := c#>'{workflow,spec}';

    -- An `embed:` step -- and the embed half of a SEMANTIC/SEARCH `p8ql:` step
    -- -- compiles to a MARKER, not a call: the compiler knows the text and at
    -- most a model name, and the url, request shape and response path are rows
    -- in the model registry. Filling them in HERE rather than at dispatch is
    -- what makes the stored definition say which model it meant; a run does not
    -- re-decide because someone moved is_default in between.
    --
    -- Conditional because ai-query-layer may not be installed -- the engine is
    -- deployable on its own, and this file may not reference aiq. A marker that
    -- survives is refused by the lint below, with the missing integration named.
    if to_regprocedure('aiq.expand_embed_steps(jsonb)') is not null then
        execute 'select aiq.expand_embed_steps($1)' into v_spec using v_spec;
    end if;

    insert into workflow.definitions (name, version, spec)
    values (v_name, coalesce((select max(version) + 1 from workflow.definitions where name = v_name), v_ver),
            v_spec)
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- P8QL as a step. This is what makes a query a first-class workflow node with
-- no process behind it -- it is an ordinary §17 sql step whose registered
-- function happens to be the query dialect.
-- workflow.p8ql() -- the P8QL step function -- deliberately does NOT live here.
-- It calls aiq.query(), which would make this file depend on ai-query-layer
-- and break the property that workflow-engine is deployable on its own with
-- no other subsystem present. Caught by verifying a clean install: this schema
-- loads at step 2 and aiq does not exist until step 5.
--
-- It lives in ai-query-layer/integration-workflow.sql, applied after both --
-- the same boundary discipline as workflow-engine/integration-rbac.sql.
grant execute on function workflow.define_yaml(text) to authenticated;

-- ------------------------------------------------------------
-- 19. Schedules -- a scheduled workflow is a ROW, not a cron entry.
--
-- spec.md §10 said "register scheduled workflows with pg_cron" and left the
-- shape open. Registering one cron job per schedule was tried first and is
-- the wrong answer for this collection, for three reasons that only show up
-- once you try it:
--
--   * cron.job is a catalog table in another extension's schema. It has no
--     org_id and no owner, so a scheduled workflow could not be RLS-scoped,
--     and "list my schedules" would have to read a table every tenant shares.
--   * Creating one needs rights on the cron schema, so adding a schedule
--     could never be an ordinary authenticated REST call.
--   * It would be a second copy of state -- cron.job plus whatever row we
--     kept alongside it -- and this collection has already paid for that kind
--     of drift more than once.
--
-- So pg_cron drives exactly ONE job:
--
--     select cron.schedule('workflow-tick', '* * * * *',
--                          $$select workflow.tick()$$);
--
-- and every schedule is a row in the table below. That keeps the whole
-- feature inside the ownership and RLS model the rest of the collection
-- already has, and it makes pg_cron a *driver* rather than a dependency:
-- anything that calls workflow.tick() once a minute works identically -- an
-- operator, a KEDA-scaled pod, a `while sleep 60` -- which matters because
-- pg_cron's PG19 support is a patch we carry (dev/patches/), not a given.
--
-- The unit of scheduling is deliberately the RUN, not the task: a schedule
-- starts a workflow through start_workflow() like any other caller, so
-- retry, backoff, the reaper, saga compensation, cancellation and tracing all
-- apply unchanged. Nothing here is a second execution engine.
-- ------------------------------------------------------------
create table workflow.schedules (
    id             uuid primary key default gen_random_uuid(),
    name           text not null unique,
    -- The definition NAME, not its id: start_workflow() resolves the latest
    -- version at fire time, so publishing v2 of a workflow changes what the
    -- schedule runs without touching the schedule.
    workflow_name  text not null,
    cron_expr      text not null,
    -- IANA zone. Stored per schedule rather than assumed UTC because "every
    -- weekday at 09:00" is a statement about somebody's morning, and the whole
    -- point of a cron expression is lost if it silently means 09:00 UTC.
    timezone       text not null default 'UTC',
    input          jsonb not null default '{}'::jsonb,
    enabled        boolean not null default true,
    -- 'skip': do not start a new run while this schedule's previous run is
    -- still running. This is world-model-ingestion/brief.md §5's
    -- overlapping-poll problem, solved once here rather than per pipeline: a
    -- channel polled every minute whose fetch takes ninety seconds must not
    -- accumulate runs. 'allow' is the escape hatch for genuinely independent
    -- ticks.
    overlap_policy text not null default 'skip'
                       check (overlap_policy in ('skip','allow')),
    -- last_tick_at is the minute this schedule was last EVALUATED;
    -- last_fired_at is the minute it last STARTED a run. Two columns because
    -- they answer different questions -- "is the ticker alive?" and "is this
    -- schedule producing work?" -- and collapsing them makes a schedule that
    -- is being skipped every minute look identical to one that is firing.
    last_tick_at   timestamptz,
    last_fired_at  timestamptz,
    last_run_id    uuid references workflow.runs(id),
    fire_count     bigint not null default 0,
    skip_count     bigint not null default 0,
    -- A schedule whose workflow was deleted, or whose input no longer
    -- validates, must say so out loud rather than failing invisibly once a
    -- minute forever (RELEASE-0.1.md §5, "honest failure modes").
    last_error     text,
    last_error_at  timestamptz,
    org_id         uuid,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);
create index idx_schedules_due on workflow.schedules (last_tick_at) where enabled;
create index idx_schedules_org on workflow.schedules (org_id);

create trigger trg_schedules_touch before update on workflow.schedules
    for each row execute function public.touch_updated_at();

-- One field of a 5-field cron expression, against one integer.
-- Supports `*`, `n`, `a-b`, `*/s`, `a-b/s` and `n/s`, comma-separated.
-- Deliberately NOT supported: `@daily` and friends (sugar that would need its
-- own expansion table), `L`/`W`/`#` (Quartz extensions, not Vixie cron).
-- An unsupported field raises at authoring time via schedule_workflow().
create or replace function workflow.cron_field_matches(
    p_field text, p_value int, p_min int, p_max int)
returns boolean as $$
declare
    v_part  text;
    v_range text;
    v_step  int;
    v_lo    int;
    v_hi    int;
begin
    foreach v_part in array string_to_array(btrim(p_field), ',')
    loop
        v_part := btrim(v_part);
        if v_part = '' then
            raise exception 'cron: empty element in field "%"', p_field;
        end if;

        v_step  := 1;
        v_range := v_part;
        if position('/' in v_part) > 0 then
            v_range := split_part(v_part, '/', 1);
            if split_part(v_part, '/', 2) !~ '^\d+$' then
                raise exception 'cron: bad step in "%"', v_part;
            end if;
            v_step := split_part(v_part, '/', 2)::int;
            if v_step < 1 then
                raise exception 'cron: step must be >= 1 in "%"', v_part;
            end if;
        end if;

        if v_range = '*' then
            v_lo := p_min;
            v_hi := p_max;
        elsif v_range ~ '^\d+-\d+$' then
            v_lo := split_part(v_range, '-', 1)::int;
            v_hi := split_part(v_range, '-', 2)::int;
        elsif v_range ~ '^\d+$' then
            v_lo := v_range::int;
            -- `n/s` means "from n to the end of the range, every s" (the
            -- common extension); a bare `n` is just itself.
            v_hi := case when v_step > 1 then p_max else v_lo end;
        else
            raise exception 'cron: unsupported element "%" in field "%"', v_part, p_field;
        end if;

        if v_lo < p_min or v_hi > p_max or v_lo > v_hi then
            raise exception 'cron: "%" out of range %-% in field "%"',
                v_part, p_min, p_max, p_field;
        end if;

        if p_value between v_lo and v_hi and (p_value - v_lo) % v_step = 0 then
            return true;
        end if;
    end loop;
    return false;
end;
$$ language plpgsql immutable;

-- Does a 5-field cron expression match this instant, in this zone?
--
-- Matching rather than "compute the next run time" is deliberate, and it is
-- what cron itself does: the ticker wakes once a minute and asks whether now
-- matches. A next_run_at column would be a cached derivation that goes stale
-- the moment a DST boundary, a timezone edit or a clock change disagrees
-- with it -- and it would have to be recomputed correctly in every path that
-- edits a schedule. There is nothing to keep in sync here.
create or replace function workflow.cron_matches(
    p_expr text, p_ts timestamptz, p_timezone text default 'UTC')
returns boolean as $$
declare
    f               text[];
    v_local         timestamp;
    v_dow           int;
    v_min_ok        boolean;
    v_hour_ok       boolean;
    v_month_ok      boolean;
    v_dom_ok        boolean;
    v_dow_ok        boolean;
begin
    f := regexp_split_to_array(btrim(p_expr), '\s+');
    if coalesce(array_length(f, 1), 0) <> 5 then
        raise exception
            'cron: expected 5 fields (minute hour day-of-month month day-of-week), got % in "%"',
            coalesce(array_length(f, 1), 0), p_expr;
    end if;

    -- Raises for an unknown zone, which is the point: a typo'd timezone is
    -- caught when the schedule is created rather than never firing.
    v_local := p_ts at time zone p_timezone;

    -- All five fields are evaluated before any of them is allowed to decide
    -- the answer. Short-circuiting on the first non-match is the obvious
    -- implementation and it makes validation depend on the CLOCK: with
    -- `5 9 * * MON`, a check run at 09:04 returns false from the minute field
    -- and never parses the unsupported day-of-week at all -- so
    -- schedule_workflow() accepts it, and it fails once a minute forever
    -- instead of in the caller's hand. Found by testing exactly that.
    v_min_ok   := workflow.cron_field_matches(f[1], extract(minute from v_local)::int, 0, 59);
    v_hour_ok  := workflow.cron_field_matches(f[2], extract(hour   from v_local)::int, 0, 23);
    v_month_ok := workflow.cron_field_matches(f[4], extract(month  from v_local)::int, 1, 12);

    v_dow    := extract(dow from v_local)::int;    -- 0 = Sunday, matching cron
    v_dom_ok := workflow.cron_field_matches(f[3], extract(day from v_local)::int, 1, 31);
    -- Both 0 and 7 mean Sunday in cron, so Sunday is tested twice.
    v_dow_ok := workflow.cron_field_matches(f[5], v_dow, 0, 7)
                or (v_dow = 0 and workflow.cron_field_matches(f[5], 7, 0, 7));

    if not (v_min_ok and v_hour_ok and v_month_ok) then
        return false;
    end if;

    -- Vixie cron's genuinely surprising rule, reproduced rather than "fixed":
    -- when BOTH day-of-month and day-of-week are restricted, a match on
    -- either one fires. `0 0 13 * 5` is the 13th *or* any Friday, not
    -- Friday the 13th. Implementing the intuitive AND here would make every
    -- expression copied from a crontab mean something different.
    if f[3] <> '*' and f[5] <> '*' then
        return v_dom_ok or v_dow_ok;
    end if;
    return v_dom_ok and v_dow_ok;
end;
$$ language plpgsql stable;

-- The ticker. Call once a minute, from pg_cron or from anything else.
--
-- Returns the number of runs STARTED, so a caller (or a monitoring query) can
-- tell "the ticker ran and nothing was due" from "the ticker is not running",
-- which last_tick_at also answers per schedule.
-- Current form. It reached this shape in section 21j (A scheduled run belongs to whoever scheduled it.), which explains
-- the failure that produced it. Defined here, where it is first needed.
create or replace function workflow.tick(p_now timestamptz default now())
returns int as $$
declare
    v_minute  timestamptz := date_trunc('minute', p_now);
    s         workflow.schedules;
    v_run_id  uuid;
    v_started int := 0;
    v_active  boolean;
begin
    for s in
        select * from workflow.schedules
         where enabled
           -- Dedupe by minute: two overlapping ticks, or a ticker that fires
           -- twice in the same minute, cannot double-start anything.
           and (last_tick_at is null or last_tick_at < v_minute)
         order by name
         for update skip locked
    loop
        begin
            if not workflow.cron_matches(s.cron_expr, v_minute, s.timezone) then
                update workflow.schedules set last_tick_at = v_minute where id = s.id;
                continue;
            end if;

            if s.overlap_policy = 'skip' and s.last_run_id is not null then
                select exists (
                    select 1 from workflow.runs r
                     where r.id = s.last_run_id and r.status = 'running'
                ) into v_active;
                if v_active then
                    update workflow.schedules
                       set last_tick_at = v_minute, skip_count = skip_count + 1
                     where id = s.id;
                    continue;
                end if;
            end if;

            -- The external_id is the schedule and the minute, which makes a
            -- fire idempotent through the engine's OWN idempotency rather
            -- than a second mechanism here: if this transaction is retried,
            -- start_workflow() returns the existing run instead of a second
            -- one.
            v_run_id := workflow.start_workflow(
                s.workflow_name,
                s.input,
                'schedule:' || s.name || ':' ||
                    to_char(v_minute at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'),
                null);

            -- 21j: authority follows provenance. A schedule already has an
            -- owner, set from the verified JWT of whoever created it, and the
            -- runs it starts are that person's. Without this every scheduled
            -- run is unowned -- and assert_run_access correctly treats unowned
            -- as owned by nobody -- so a scheduled workflow that waits for
            -- approval could never be approved, by anyone.
            update workflow.runs
               set owner_id = s.owner_id
             where id = v_run_id and owner_id is null and s.owner_id is not null;

            update workflow.schedules
               set last_tick_at  = v_minute,
                   last_fired_at = v_minute,
                   last_run_id   = v_run_id,
                   fire_count    = fire_count + 1,
                   last_error    = null,
                   last_error_at = null
             where id = s.id;
            v_started := v_started + 1;

        exception when others then
            -- One broken schedule must not stop the other schedules from
            -- firing. The subtransaction rolls back, the record of WHY does
            -- not: this update runs after the rollback.
            update workflow.schedules
               set last_tick_at  = v_minute,
                   last_error    = sqlerrm,
                   last_error_at = now()
             where id = s.id;
        end;
    end loop;

    return v_started;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ---------- the REST surface -------------------------------------------
-- Three functions, reached over PostgREST as POST /rpc/<name> with
-- `Content-Profile: workflow`. Functions rather than table grants for the
-- same reason as everywhere else in this schema: the write path is a
-- SECURITY DEFINER call, and no PostgREST-facing role holds INSERT on a base
-- table.

-- Every SECURITY DEFINER function an end user can reach must do its own
-- authorization -- integration-rbac.sql (e) states the rule and records the
-- confirmed exploit that produced it. These three take a caller-supplied
-- schedule NAME, so without a check any authenticated caller could repoint or
-- delete any tenant's schedule.
--
-- The core engine has no identity system to consult, so this is the seam:
-- integration-rbac.sql replaces this function with the real owner/permission
-- check. The default DENIES rather than permits -- anyone who is not a member
-- of the role owning the table is refused -- so a deployment that grants
-- schedule management to users without applying integration-rbac.sql fails
-- loudly instead of silently authorizing everyone. An identity-free
-- deployment (the engine standing alone) still works, because there the
-- operator IS the schema owner.
create or replace function workflow.assert_schedule_access(p_name text, p_action text)
returns void as $$
declare
    v_owner name;
begin
    select pg_get_userbyid(c.relowner) into v_owner
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'workflow' and c.relname = 'schedules';

    if pg_has_role(session_user, v_owner, 'member') then
        return;
    end if;

    raise exception 'not authorized to % schedule "%"', p_action, p_name
        using hint = 'workflow-engine/integration-rbac.sql installs the '
                     'owner-and-permission check this default stands in for';
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- Create or update a schedule, by name. Idempotent: calling it again with a
-- different expression edits the schedule rather than creating a second one,
-- so a deployment can re-run its own seed without accumulating duplicates.
create or replace function workflow.schedule_workflow(
    p_name          text,
    p_workflow      text,
    p_cron          text,
    p_input         jsonb default '{}'::jsonb,
    p_timezone      text  default 'UTC',
    p_overlap       text  default 'skip')
returns uuid as $$
declare
    v_id uuid;
begin
    -- Validate everything that can be validated NOW. A schedule that cannot
    -- possibly fire should fail in the caller's hand, not once a minute into
    -- last_error where nobody is looking.
    perform workflow.assert_schedule_access(p_name, 'create');

    if not exists (select 1 from workflow.definitions where name = p_workflow) then
        raise exception 'no workflow definition named "%"', p_workflow
            using hint = 'register it with workflow.define_yaml() first';
    end if;
    -- Raises on a malformed expression or an unknown timezone.
    perform workflow.cron_matches(p_cron, now(), p_timezone);

    insert into workflow.schedules (name, workflow_name, cron_expr, input,
                                    timezone, overlap_policy)
    values (p_name, p_workflow, p_cron, coalesce(p_input, '{}'::jsonb),
            p_timezone, p_overlap)
    on conflict (name) do update
        set workflow_name  = excluded.workflow_name,
            cron_expr      = excluded.cron_expr,
            input          = excluded.input,
            timezone       = excluded.timezone,
            overlap_policy = excluded.overlap_policy,
            last_error     = null,
            last_error_at  = null
    returning id into v_id;

    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Enable or disable without losing the definition or its history. Disabling
-- is the reversible operation and is what a UI's toggle should call;
-- unschedule_workflow() is the destructive one.
create or replace function workflow.set_schedule_enabled(
    p_name text, p_enabled boolean)
returns boolean as $$
declare
    v_found boolean;
begin
    perform workflow.assert_schedule_access(p_name, 'enable');

    update workflow.schedules set enabled = p_enabled
     where name = p_name
    returning true into v_found;
    return coalesce(v_found, false);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Returns false rather than raising when the name is unknown, so that
-- deleting something already deleted is not an error a caller has to catch.
create or replace function workflow.unschedule_workflow(p_name text)
returns boolean as $$
declare
    v_found boolean;
begin
    perform workflow.assert_schedule_access(p_name, 'delete');

    delete from workflow.schedules where name = p_name
    returning true into v_found;
    return coalesce(v_found, false);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The ticker runs as `scheduler`, the role user-rbac/roles.sql §3 defines for
-- exactly this and which holds no table grants. tick() is SECURITY DEFINER,
-- so EXECUTE is the whole grant it needs.
grant execute on function workflow.tick(timestamptz) to scheduler;

grant execute on function workflow.schedule_workflow(text, text, text, jsonb, text, text)
    to authenticated;
grant execute on function workflow.set_schedule_enabled(text, boolean) to authenticated;
grant execute on function workflow.unschedule_workflow(text) to authenticated;
grant execute on function workflow.cron_matches(text, timestamptz, text) to authenticated;

revoke execute on function workflow.assert_schedule_access(text, text) from public;

-- ============================================================
-- 20. `matrix` steps -- fan-out is a SELECT, and it commits with its parent.
--
-- The problem this solves is Argo Workflows' `withParam`. Argo expands a
-- matrix by having a controller pod read a JSON array out of a previous
-- step's output and template one pod per element. It works, and it costs
-- three processes and a serialisation round trip before any real work starts:
-- the step that emits the array, the controller that reads it, and the pods it
-- creates. It also leaves a window open -- the emitting step is `done` and its
-- children do not exist yet -- in which a controller crash strands the
-- fan-out with nothing to resume from.
--
-- Percolate already had both halves of the alternative and had not put them
-- together. `kind='sql'` (§17) runs a query with no process; §12's
-- complete_decision_task atomically completes a task AND inserts the tasks it
-- decided on. A matrix step is those two facts in one function: the work to do
-- IS a query result, and the row set, the children, and the parent's
-- completion all land in one transaction.
--
-- Zero processes expand the matrix. The parent cannot be `done` while its
-- children are missing, because they are inserted by the statement that
-- completes it.
--
-- ------------------------------------------------------------------
-- THE FAN-IN IS NOT FREE, AND THE DESIGN NOTE THAT SAID IT WAS WAS WRONG.
--
-- The claim this section was written against was: "the fan-in is already
-- handled -- pending_deps is an AND-join, so an aggregate step depending on
-- the matrix simply waits." That is false against this engine, and running it
-- says so immediately. A static successor declares `depends_on: [fan]`, so its
-- one edge points at the MATRIX task -- which completes at expansion time,
-- before a single child has run. The aggregate would fire instantly, over
-- nothing.
--
-- So expansion does three things, not two: it inserts the children, it
-- REWIRES every successor of the matrix step to depend on the children
-- instead of only on the matrix task (edge inserted, pending_deps
-- incremented), and only then completes the parent. The cascade then
-- decrements the successor's original edge to the matrix task by one, leaving
-- exactly N outstanding. The AND-join is real, but it had to be built.
--
-- ------------------------------------------------------------------
-- WHERE THE ROW SET IS RECORDED, AND WHY NOT WHERE IT WAS SUPPOSED TO BE.
--
-- A decision task in this engine is contractually a pure function of a
-- recorded input snapshot (§12). A query over live tables is not pure --
-- a watchlist changes between runs. The intended resolution was "the matrix's
-- row set IS the snapshot: record it as the task's output at expansion time,
-- and replay reads the recorded set rather than re-running the query."
--
-- That resolution does not survive §7's payload cap. Five thousand rows do
-- not fit in a 64KB output, and making the matrix step the one kind of task
-- that writes a multi-megabyte payload -- or a $ref to object storage, for a
-- set the database already holds -- is a worse answer than the one the
-- schema hands you for free:
--
--   THE CHILDREN ARE THE SNAPSHOT. Each row is recorded, durably and
--   individually, as `input->'item'` on the child task it produced. The set is
--   `select input->'item' from workflow.tasks where matrix_parent_id = ...`,
--   in insertion order, and each row is inside the payload cap by
--   construction because it is one row.
--
-- The matrix task's own output therefore records the DIGEST -- the count and a
-- hash over the ordered row set -- which is all a determinism check needs, and
-- reuses `decision_output_hash` unchanged. A re-expansion that produces a
-- different row set is refused by name rather than silently fanning out over a
-- changed world; a re-expansion that produces the same one is a no-op.
--
-- ------------------------------------------------------------------
-- MATRIX ROWS COME FROM A REGISTERED FUNCTION, NOT AN INLINE SELECT.
--
-- The obvious spelling is an inline `sql: | select ...` in the step. It is
-- refused here for exactly the reason §17 refuses it for `sql` steps: this
-- executes SECURITY DEFINER, so a step that could supply a statement would be
-- a privilege-escalation primitive with a YAML front end. A matrix names a
-- function in the SAME allow-list (`workflow.step_functions`) that `sql` steps
-- use, and the function returns a JSON array of objects. Registration stays an
-- owner-only act, so authoring a matrix never widens what can be executed.
--
-- The cost is real -- a new fan-out shape needs a migration, not just a YAML
-- edit -- and it is the correct cost. A literal `items: [...]` list covers the
-- small static case without a registration.
--
-- ------------------------------------------------------------------
-- DELIBERATELY NOT HERE (each has a reason, not an omission):
--
--   * AGGREGATION OVER CHILDREN. There is no `{{items.<step>}}` namespace and
--     no gather step. Children do NOT write into `runs.context` -- see
--     complete_task below -- because 5,000 outputs in one JSONB column is a
--     row that is rewritten in full on every child completion, which is
--     quadratic write amplification on the hottest path in the schema. The
--     pattern that works today is the one the worked pipelines actually want:
--     children write to a domain table, and the successor is a `sql` step over
--     that table. Promote a real aggregation namespace on the second consumer
--     that cannot be expressed that way, per
--     meta/skills/spec-driven-development §5.
--   * PARTIAL-FAILURE TOLERANCE (`continue_on: failed`, `min_success`). One
--     failed child currently cascade-cancels the successors, which for an
--     11,200-fetch matrix against a public API means one 404 kills the run.
--     This is the first thing to build next and it is a known sharp edge, not
--     a solved one.
--   * A PER-MATRIX PARALLELISM CAP. `rate_key` plus queue_config already
--     throttle the children; a second concurrency mechanism needs a case the
--     first one cannot express.
--   * NESTED MATRIX. A matrix inside a matrix template is REJECTED at
--     validation rather than silently mis-wired: a child has no static
--     successors to rewire, so its grandchildren would never be joined to the
--     rollup. Refusing by name beats a run that completes early and looks fine.
-- ============================================================

alter table workflow.tasks drop constraint if exists tasks_kind_check;
alter table workflow.tasks add constraint tasks_kind_check
    check (kind in ('work','decision','timer','signal','sub_workflow','http_call','sql','matrix'));

-- Set on a CHILD, pointing at the matrix task that produced it. Three jobs:
-- it is how expansion finds what it already created (the re-expansion guard),
-- it is how the recorded row set is read back, and it is what complete_task
-- keys off to keep fan-out children out of runs.context.
alter table workflow.tasks
    add column if not exists matrix_parent_id uuid references workflow.tasks(id);

create index if not exists idx_tasks_matrix_parent
    on workflow.tasks (matrix_parent_id, created_at)
    where matrix_parent_id is not null;

-- ------------------------------------------------------------
-- 20a. `{{item.*}}` -- a third namespace, and where it lives.
--
-- A fan-out child's whole reason to exist is one row, so it needs a way to
-- name it. The row is NOT substituted into the child's input at expansion
-- time: §"Templates" in YAML.md is explicit that resolving at author time
-- makes the recorded task input a lie about what was sent, and pre-baking
-- 5,000 URLs would make it a lie 5,000 times over. Instead the row is stored
-- verbatim as `input->'item'` and resolved at dispatch, exactly like
-- {{run.*}} and {{steps.*}}.
--
-- The 3-argument form carries the item; the 2-argument form is kept and
-- delegates, so every existing caller and the surface-audit row for
-- resolve_args(jsonb,uuid) stay valid.
-- ------------------------------------------------------------
-- Current form. It reached this shape in section 22a (BUG 1 -- the run cannot see itself.), which explains
-- the failure that produced it. Defined here, where it is first needed.
-- ONE reference, resolved. Split out of resolve_args when an argument stopped
-- being either a whole reference or a literal: a query string carries text
-- AROUND its references ('SEARCH "{{run.question}}" FROM chunks'), so the same
-- resolution now has two callers -- one that wants the jsonb value and one
-- that wants it rendered into a longer string.
create or replace function workflow.resolve_template_ref(
    p_ref text, p_run_id uuid, p_item jsonb)
returns jsonb as $$
declare
    r      workflow.runs;
    v_meta jsonb;
    v_head text;
    v_rest text;
    v_val  jsonb;
begin
    select * into r from workflow.runs where id = p_run_id;
    v_head := split_part(p_ref, '.', 1);
    v_rest := substr(p_ref, length(v_head) + 2);

    if v_head = 'steps' then
        v_val := r.context #> string_to_array(v_rest, '.');
    elsif v_head = 'run' then
        if left(v_rest, 1) = '$' then
            v_meta := workflow.run_meta(p_run_id);
            v_val := v_meta -> v_rest;
            if v_val is null then
                raise exception
                    'unknown engine field ''run.%''. Available: %',
                    v_rest, (select string_agg(k, ', ' order by k)
                             from jsonb_object_keys(v_meta) k);
            end if;
        else
            v_val := r.input #> string_to_array(v_rest, '.');
            -- The natural thing to type for a run's own id is {{run.id}}. Say
            -- what to write instead of resolving to nothing and failing eight
            -- tasks later.
            if v_val is null and workflow.run_meta(p_run_id) ? ('$' || v_rest) then
                raise exception
                    'template ''run.%'' resolved to nothing. {{run.*}} reads the '
                    'run INPUT; the run''s own % is {{run.$%}} -- the $ prefix is '
                    'reserved for engine fields so an input key named ''%'' cannot '
                    'shadow it.', v_rest, v_rest, v_rest, v_rest;
            end if;
        end if;
    elsif v_head = 'item' then
        if p_item is null then
            raise exception
                'template ''%'' names the item namespace, but this task is not a '
                'matrix fan-out child -- {{item.*}} is only bound on tasks '
                'expanded from a matrix step', p_ref;
        end if;
        v_val := p_item #> string_to_array(v_rest, '.');
    else
        raise exception
            'unknown template namespace ''%'' in a sql step argument '
            '-- expected steps, run or item', v_head;
    end if;

    if v_val is null then
        raise exception 'template ''%'' resolved to nothing', p_ref;
    end if;
    return v_val;
end;
$$ language plpgsql stable;

-- Two shapes, and the difference is not a preference.
--
-- A WHOLE-STRING reference is a value: '{{steps.embed.result}}' is a vector,
-- and it must arrive as an array rather than as a string that looks like one.
-- That rule was the whole of this function, and it was written as "here an
-- argument is a value, not a template".
--
-- An EMBEDDED reference is text, and leaving it alone was a defect this
-- collection's own headline example demonstrated. `p8ql_vec` takes the query
-- as its first argument, and the documented hybrid pipeline passes
-- 'SEARCH "{{run.question}}" FROM chunks LIMIT 3'. Not a whole-string
-- reference, so it was substituted nowhere and reached aiq.query verbatim --
-- and SEARCH feeds that text to the LEXICAL half. Full-text search for the
-- literal string {{run.question}} matches nothing, every lexical rank comes
-- back null, and the fusion quietly degrades to semantic-only. It returns
-- rows. It looks like it worked. That is the failure mode this repository
-- exists to catch, sitting in the example that opens YAML.md.
--
-- So: whole-string keeps its native type, embedded interpolates as text. That
-- is not a new rule -- it is the rule the WORKER already applies to a url and
-- the one YAML.md states for {{item.*}} ("a whole-string reference keeps its
-- native type; one embedded in a URL is interpolated as text"). The database
-- half was the odd one out, and silently.
create or replace function workflow.resolve_args(p_args jsonb, p_run_id uuid, p_item jsonb)
returns jsonb as $$
declare
    v_out    jsonb := '[]'::jsonb;
    v_arg    jsonb;
    v_txt    text;
    v_new    text;
    v_ref    text;
    v_val    jsonb;
    v_m      text[];
begin
    for v_arg in select * from jsonb_array_elements(coalesce(p_args, '[]'::jsonb))
    loop
        v_txt := v_arg #>> '{}';
        -- `$` joins the character class so {{run.$id}} is a whole-string
        -- reference like any other.
        if v_txt is not null and v_txt ~ '^\s*\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}\s*$' then
            v_ref := trim(both from replace(replace(v_txt, '{{', ''), '}}', ''));
            v_out := v_out || jsonb_build_array(
                workflow.resolve_template_ref(v_ref, p_run_id, p_item));

        elsif v_txt is not null and v_txt ~ '\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}' then
            v_new := v_txt;
            for v_m in
                select regexp_matches(v_txt, '(\{\{\s*([a-zA-Z0-9_.$]+)\s*\}\})', 'g')
            loop
                v_val := workflow.resolve_template_ref(v_m[2], p_run_id, p_item);
                -- `#>> '{}'` renders a string without its quotes and anything
                -- else as its JSON text. replace() on the matched text rather
                -- than regexp_replace on a rebuilt pattern, because a resolved
                -- value containing & or \ is data, not a substitution rule.
                v_new := replace(v_new, v_m[1], v_val #>> '{}');
            end loop;
            v_out := v_out || jsonb_build_array(to_jsonb(v_new));

        else
            v_out := v_out || jsonb_build_array(v_arg);
        end if;
    end loop;
    return v_out;
end;
$$ language plpgsql stable;

create or replace function workflow.resolve_args(p_args jsonb, p_run_id uuid)
returns jsonb as $$
    select workflow.resolve_args(p_args, p_run_id, null::jsonb);
$$ language sql stable;

-- ------------------------------------------------------------
-- 20b. One place that calls an allow-listed function.
--
-- execute_sql_step (§17) built the call by hand: look the name up in
-- workflow.step_functions, set the statement timeout, extract each argument
-- according to its REGISTERED type rather than uniformly as text, and
-- to_jsonb the result. A matrix step needs precisely the same four things to
-- get its row set, and a second hand-rolled copy of that argument-coercion
-- logic is the kind of duplication that drifts silently -- the text/jsonb
-- distinction below already cost real debugging time once.
--
-- So it moves here and both callers use it. The subtransaction and the
-- fail_task decision stay with the callers, because what a failure MEANS
-- differs: a bad `sql` step fails its own task, a bad matrix query must fail
-- before any child exists.
-- ------------------------------------------------------------
create or replace function workflow.call_step_function(
    p_name text, p_args jsonb, p_run_id uuid, p_item jsonb default null
) returns jsonb as $$
declare
    f      workflow.step_functions;
    v_args jsonb;
    v_sql  text;
    v_out  jsonb;
begin
    select * into f from workflow.step_functions where name = p_name;
    if not found then
        raise exception
            'step names function ''%'', which is not registered. Register it with '
            'workflow.register_step_function() -- steps may not supply arbitrary SQL.',
            p_name;
    end if;

    perform set_config('statement_timeout', f.timeout_ms::text, true);

    -- Arguments are passed as parameters, never interpolated: a step's args
    -- are data from the run, and building SQL text out of them would be
    -- injection with extra steps.
    v_args := workflow.resolve_args(coalesce(p_args, '[]'::jsonb), p_run_id, p_item);

    -- Each argument is extracted according to its REGISTERED type, not
    -- uniformly as text. Getting this wrong surfaces as "function f(text,
    -- text) does not exist" -- which reads as a missing function rather than
    -- a coercion problem.
    if jsonb_array_length(v_args) = 0 then
        execute format('select to_jsonb(%s())', f.fn) into v_out;
    else
        v_sql := format('select to_jsonb(%s(%s))', f.fn, (
            select string_agg(
                case lower(coalesce(f.arg_types[i], 'text'))
                    when 'text'  then format('$1->>%s', i - 1)
                    when 'jsonb' then format('$1->%s', i - 1)
                    when 'json'  then format('($1->%s)::json', i - 1)
                    else format('($1->>%s)::%s', i - 1, f.arg_types[i])
                end, ',' order by i)
            from generate_series(1, jsonb_array_length(v_args)) i));
        execute v_sql into v_out using v_args;
    end if;

    return v_out;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- execute_sql_step, re-expressed over the shared caller. Behaviour is
-- unchanged except that a `sql` step which is itself a matrix child can now
-- name {{item.*}} in its args.
-- workflow.execute_sql_step(uuid) is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20a-bis. `{{item.*}}` is substituted AT EXPANSION, and the first version of
-- this section said the opposite. Reversed by running it.
--
-- The original decision was that the row should be stored on the child and
-- `{{item.cik}}` resolved at dispatch, like {{run.*}} and {{steps.*}}, on the
-- grounds that YAML.md's Templates section says author-time substitution makes
-- the recorded task input a lie about what was sent.
--
-- Then the worked case ran -- a matrix of `rest:` steps against SEC EDGAR --
-- and all six children failed terminally with:
--
--     unknown template namespace 'item' in {{item.cik}}
--     -- expected steps, run or env
--
-- That message is the WORKER's, not this database's. Deferring to dispatch put
-- `item` into the worker's contract, and the worker is a shipped image that
-- knows three namespaces. So the headline use case for this entire feature --
-- fan out over a query, fetch one URL per row -- did not work, on a design
-- that had been written up as if it did. Only `sql` children had been
-- exercised, because those resolve in-database where the namespace had been
-- added.
--
-- The decision was also wrong on its own terms, which is the part worth
-- keeping. The "recorded input is a lie" objection is about a stored
-- DEFINITION, which is shared across every run and cannot be resolved in
-- advance. A fan-out child is not that: it exists for exactly one row, and
-- substituting that row makes its recorded input say EXACTLY what will be
-- sent. Deferring made the recorded input say `{{item.cik}}` and forced a
-- reader to join to `input->'item'` to learn what was actually requested.
-- Substitution is the more honest record, not the less.
--
-- So: `item` is substituted here, the other namespaces are untouched and still
-- resolve at dispatch, and the row is ALSO kept verbatim on the child --
-- because it is the recorded snapshot §20 turns on, and because a `sql` child
-- can then read it with its type intact.
--
-- The payoff beyond correctness: a worker never learns that a task came from a
-- fan-out. Expansion is the engine's business, and it now stays there.
-- ------------------------------------------------------------
create or replace function workflow.substitute_item(p_value jsonb, p_item jsonb, p_step text)
returns jsonb as $$
declare
    v_txt   text;
    v_path  text;
    v_val   jsonb;
    v_out   jsonb;
    v_key   text;
    m       text[];
begin
    if p_value is null then
        return null;
    end if;

    case jsonb_typeof(p_value)
    when 'object' then
        v_out := '{}'::jsonb;
        for v_key in select jsonb_object_keys(p_value) loop
            v_out := v_out || jsonb_build_object(
                v_key, workflow.substitute_item(p_value->v_key, p_item, p_step));
        end loop;
        return v_out;

    when 'array' then
        return coalesce((
            select jsonb_agg(workflow.substitute_item(e, p_item, p_step) order by ord)
            from jsonb_array_elements(p_value) with ordinality as x(e, ord)), '[]'::jsonb);

    when 'string' then
        v_txt := p_value #>> '{}';

        -- A WHOLE-STRING reference keeps its native type, so a numeric column
        -- arrives as a number and a nested object arrives as an object. Same
        -- rule resolve_args applies, for the same reason: an argument that is
        -- only a reference is a value, not a template.
        m := regexp_match(v_txt, '^\s*\{\{\s*item\.([a-zA-Z0-9_.]+)\s*\}\}\s*$');
        if m is not null then
            v_val := p_item #> string_to_array(m[1], '.');
            if v_val is null then
                raise exception
                    'matrix step ''%'': template names {{item.%}}, which is not a column of '
                    'the row set. The row has: %',
                    p_step, m[1], (select string_agg(k, ', ' order by k)
                                   from jsonb_object_keys(p_item) k);
            end if;
            return v_val;
        end if;

        -- Embedded in a larger string -- a URL, a prompt -- so the value is
        -- interpolated as text. A string is inserted bare; anything else is
        -- inserted as its JSON form, which is what a caller building a URL out
        -- of a number means.
        for m in select regexp_matches(v_txt, '\{\{\s*item\.([a-zA-Z0-9_.]+)\s*\}\}', 'g') loop
            v_val := p_item #> string_to_array(m[1], '.');
            if v_val is null then
                raise exception
                    'matrix step ''%'': template names {{item.%}}, which is not a column of '
                    'the row set. The row has: %',
                    p_step, m[1], (select string_agg(k, ', ' order by k)
                                   from jsonb_object_keys(p_item) k);
            end if;
            v_txt := replace(v_txt,
                (regexp_match(v_txt, '\{\{\s*item\.' || m[1] || '\s*\}\}'))[1],
                case when jsonb_typeof(v_val) = 'string' then v_val #>> '{}'
                     else v_val::text end);
        end loop;
        return to_jsonb(v_txt);

    else
        return p_value;
    end case;
end;
$$ language plpgsql immutable;

-- ------------------------------------------------------------
-- 20c. Expansion -- the whole mechanism, in one transaction.
--
-- Step spec (the `input` of a `kind: matrix` step):
--
--   {
--     "rows":  {"function": "<registered>", "args": [...]},   -- OR
--     "items": [ {...}, {...} ],                              -- a literal set
--     "max_fanout": 5000,
--     "template": {
--        "queue":  "edgar-xbrl",
--        "kind":   "http_call",
--        "input":  {"url": ".../CIK{{item.cik}}/...", "jsonpath": "units.USD"},
--        "rate_key": "sec-edgar"
--     }
--   }
--
-- Children are keyed `<matrix_key>[<i>]`, which is why validate_spec below
-- refuses a declared step key containing '[' -- the two namespaces must not
-- be able to collide.
--
-- Returns the number of children created. Zero is a legitimate answer, not an
-- error: an empty row set means there was nothing to do, the matrix task
-- completes, and its successors run with no children to wait for. A matrix
-- that fails on an empty result would make "nothing changed since last time"
-- an incident.
-- ------------------------------------------------------------
create or replace function workflow.expand_matrix(p_task_id uuid)
returns int as $$
declare
    t           workflow.tasks;
    v_spec      jsonb;
    v_rows      jsonb;
    v_max       int;
    v_tmpl      jsonb;
    v_row       jsonb;
    v_i         int := 0;
    v_child     uuid;
    v_children  uuid[] := '{}';
    v_succ      uuid;
    v_added     int;
    v_hash      text;
    v_prior     text;
begin
    select * into t from workflow.tasks where id = p_task_id;
    -- run_after is checked here and not in execute_sql_step's equivalent, and
    -- that asymmetry is load-bearing. fail_task's retry path sets a task back
    -- to 'ready' with a future run_after -- which is an UPDATE into ready, so
    -- the autorun trigger fires again immediately. Without this guard a matrix
    -- whose expansion failed re-expands on the spot, burning every attempt in
    -- one transaction while backoff does nothing.
    if not found or t.status <> 'ready' or t.kind <> 'matrix' or t.run_after > now() then
        return 0;
    end if;

    -- Same guard as add_task: no new work under a cancelled run, and a matrix
    -- is the largest possible way to violate that.
    if exists (select 1 from workflow.runs where id = t.run_id and status = 'cancelled') then
        update workflow.tasks set status = 'cancelled' where id = p_task_id;
        return 0;
    end if;

    update workflow.tasks set status = 'running', claimed_by = 'in-database',
           claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
    where id = p_task_id;

    v_spec := coalesce(t.input, '{}'::jsonb);
    v_tmpl := v_spec->'template';
    v_max  := (v_spec->>'max_fanout')::int;

    begin      -- subtransaction: a bad matrix must not abort the transaction
               -- of whichever worker happened to complete the step before it
        if v_tmpl is null or jsonb_typeof(v_tmpl) <> 'object' then
            raise exception 'matrix step ''%'' has no template object', t.step_key;
        end if;
        if v_max is null or v_max < 1 then
            raise exception
                'matrix step ''%'' declares no max_fanout. A matrix needs a ceiling: a '
                'cross join with a forgotten WHERE inserts the cartesian product as task '
                'rows, and the failure should be this task, not the database.', t.step_key;
        end if;

        -- The row set. Exactly one source, checked rather than preferred, so
        -- a spec carrying both is a named error instead of a silent choice.
        if (v_spec ? 'rows') = (v_spec ? 'items') then
            raise exception
                'matrix step ''%'' must declare exactly one of `rows` (a registered '
                'function) or `items` (a literal list)', t.step_key;
        end if;

        if v_spec ? 'items' then
            v_rows := v_spec->'items';
        else
            v_rows := workflow.call_step_function(
                v_spec#>>'{rows,function}', v_spec#>'{rows,args}', t.run_id, t.input->'item');
        end if;

        if v_rows is null or jsonb_typeof(v_rows) <> 'array' then
            raise exception
                'matrix step ''%'' produced % where a JSON array of row objects was '
                'expected -- a matrix function must return jsonb shaped like '
                '[{"col": ...}, ...]', t.step_key, coalesce(jsonb_typeof(v_rows), 'null');
        end if;

        if jsonb_array_length(v_rows) > v_max then
            raise exception
                'matrix step ''%'' would expand to % tasks, over its declared max_fanout '
                'of %. Narrow the query or raise the ceiling deliberately.',
                t.step_key, jsonb_array_length(v_rows), v_max;
        end if;

        -- The digest, over the ORDERED row set. This is what makes a matrix a
        -- decision task in the §12 sense without storing the set twice: the
        -- rows themselves are recorded on the children, and this is the thing
        -- a re-expansion is checked against.
        v_hash := md5(v_rows::text);
        select decision_output_hash into v_prior from workflow.tasks where id = p_task_id;

        -- Re-expansion. Children existing means a previous expansion COMMITTED
        -- (insert, rewire and completion are one transaction, so a crash
        -- mid-expansion leaves nothing behind). Re-running it must not
        -- double-insert, and must not quietly fan out over a world that has
        -- changed underneath the run.
        if exists (select 1 from workflow.tasks where matrix_parent_id = p_task_id) then
            if v_prior is distinct from v_hash then
                raise exception
                    'matrix step ''%'' re-expanded to a DIFFERENT row set (recorded hash '
                    '%, now %). The row set is this task''s recorded snapshot; a fan-out '
                    're-expanded against changed source tables is not a replay of this '
                    'run, it is a different run wearing the same id.',
                    t.step_key, v_prior, v_hash;
            end if;
            -- completed_at is deliberately NOT touched: it is the marker
            -- 20i uses to know this task has already cascaded, and rewriting
            -- it here would re-decrement every successor's pending_deps.
            update workflow.tasks set status = 'done' where id = p_task_id;
            return (select count(*)::int from workflow.tasks where matrix_parent_id = p_task_id);
        end if;

        -- 1. The children. Each carries its row verbatim as input->'item';
        --    the template's own {{...}} references are left untouched and
        --    resolve at dispatch, like every other step's.
        for v_row in select * from jsonb_array_elements(v_rows)
        loop
            insert into workflow.tasks (
                run_id, step_key, queue, kind, input, rate_key,
                pending_deps, status, matrix_parent_id, parent_span_id,
                saga_group, compensation_task_key, tolerate_failure)
            values (
                t.run_id,
                t.step_key || '[' || v_i || ']',
                coalesce(v_tmpl->>'queue', t.queue),
                coalesce(v_tmpl->>'kind', 'work'),
                -- Substituted, then the row appended verbatim. The child's
                -- input therefore says exactly what will be sent AND still
                -- carries the snapshot §20 records.
                workflow.substitute_item(coalesce(v_tmpl->'input', '{}'::jsonb), v_row, t.step_key)
                    || jsonb_build_object('item', v_row),
                v_tmpl->>'rate_key',
                0, 'ready', p_task_id, t.span_id,
                v_tmpl->>'saga_group',
                v_tmpl->>'compensation_task_key',
                -- 21e: a child expanded under continue_on satisfies its
                -- dependents even when it fails.
                coalesce(v_spec->>'continue_on', '') = 'failed')
            on conflict (run_id, step_key) do nothing
            returning id into v_child;

            if v_child is null then
                raise exception
                    'matrix step ''%'' collided on child key %[%] -- a declared step key '
                    'must not shadow a fan-out child key', t.step_key, t.step_key, v_i;
            end if;
            v_children := v_children || v_child;
            v_i := v_i + 1;
        end loop;

        -- 2. THE REWIRE. Every successor of the matrix step gains an edge to
        --    every child. This is what turns pending_deps into a real AND-join
        --    over the fan-out; without it the successor's single edge to the
        --    matrix task is satisfied the instant the matrix completes, and
        --    the aggregate runs over nothing.
        --
        --    The successor row is locked first, for the same reason add_task
        --    locks its dependencies (fix #1): a concurrent completion racing
        --    this increment would otherwise leave the successor permanently
        --    stuck at a pending_deps that never reaches zero.
        if array_length(v_children, 1) > 0 then
            for v_succ in
                select task_id from workflow.task_dependencies
                where depends_on_task_id = p_task_id
                order by task_id
            loop
                perform 1 from workflow.tasks where id = v_succ for update;

                insert into workflow.task_dependencies (task_id, depends_on_task_id)
                select v_succ, c from unnest(v_children) c
                on conflict do nothing;
                get diagnostics v_added = row_count;

                update workflow.tasks set pending_deps = pending_deps + v_added
                where id = v_succ;
            end loop;
        end if;

        -- 3. Complete the parent. The cascade then decrements each successor's
        --    ORIGINAL edge to this task by one, leaving exactly N outstanding
        --    -- or zero, for an empty matrix, which correctly releases the
        --    successor immediately.
        --
        --    The digest goes into runs.context under the step key, so
        --    {{steps.<key>.fanout}} is available downstream. The rows do not:
        --    they are on the children.
        -- WRAPPED IN `result`, and the first version was not. Every other kind
        -- puts its payload there -- execute_sql_step returns {'result': ...},
        -- the worker's http_call returns {'status':..., 'result':...} -- so
        -- {{steps.<id>.result}} is the one idiom an author learns. A matrix
        -- step returning a bare object broke it on exactly one kind, and the
        -- first fan-in written against this feature failed with
        -- `template 'steps.fan.result' resolved to nothing`. One idiom beats
        -- two, so the shape moved rather than the idiom.
        --
        -- `task_id` is in there because without it a successor cannot REACH
        -- its siblings. The digest said how many children there were and
        -- nothing about how to find them; matrix_outputs() below needs the
        -- handle, and this is the only place a downstream step can get one.
        perform workflow.complete_task(p_task_id, jsonb_build_object('result',
            jsonb_build_object(
                'task_id',   p_task_id,
                'fanout',    coalesce(array_length(v_children, 1), 0),
                'rows_hash', v_hash,
                'source',    coalesce(v_spec#>>'{rows,function}', 'items'))));
        update workflow.tasks set decision_output_hash = v_hash where id = p_task_id;

        -- 4. `sql` children need a kick. The autorun trigger (§17) fires ON
        --    UPDATE INTO ready only, and these were INSERTED ready -- so
        --    without this a matrix of sql steps would sit there forever. Found
        --    exactly that way.
        for v_child in
            select id from workflow.tasks
            where matrix_parent_id = p_task_id and kind = 'sql' and status = 'ready'
            order by created_at, step_key
        loop
            perform workflow.execute_sql_step(v_child);
        end loop;

        return coalesce(array_length(v_children, 1), 0);
    exception when others then
        perform workflow.fail_task(p_task_id,
            jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate),
            -- A malformed spec, an unregistered function or a blown ceiling
            -- fails identically on every retry. A deadlock or timeout does not.
            sqlstate in ('42883','42P01','P0001'));
        return 0;
    end;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The fan-in, made possible. THE FIRST VERSION OF §20 SHIPPED WITHOUT THIS
-- AND SAID SO WRONGLY.
--
-- It claimed no aggregation was needed yet because "the pattern that works
-- today is that children write to a domain table and the successor is a `sql`
-- step over it". Running it showed that is false for the commonest child kind:
-- a `rest` child's output goes to workflow.tasks.output and nowhere else --
-- the generic worker records a response, it does not know a domain. So for a
-- fan-out of HTTP calls, which is the entire worked example, there was no way
-- for a successor to see a single result. Fan-out without a reachable fan-in
-- is not fan-out.
--
-- This is deliberately NOT the {{items.<step>}} namespace §20 defers. It is
-- the handle plus a reader: a successor takes {{steps.<id>.result.task_id}}
-- and calls this, either as a step in its own right or from inside its own
-- registered aggregate. That keeps the reduction in the author's function,
-- where it belongs -- 5,000 outputs are for aggregating, not for passing
-- around as a step argument, which would hit §7's payload cap immediately.
--
-- `status` is returned per child and not filtered, because with no
-- continue-on-failure yet a successor only runs when every child succeeded --
-- but the moment that changes, an aggregate needs to see which rows are
-- missing rather than silently averaging over the survivors.
-- SCOPED TO THE EXECUTING RUN, and that requirement was found by running it.
--
-- The first version had no check at all; adding the ordinary one
-- (assert_run_access, as matrix_rows has) then broke the fan-in immediately --
-- `not authorized to read run ...` -- because execute_sql_step runs as the
-- owner with no JWT, so the engine calling its own registered function has no
-- user identity to be authorized as. That is the same collision cancel_run
-- hit, and the same answer applies: the caller's authority is not the only
-- authority.
--
-- But an unchecked variant is not the answer here, because this one takes a
-- TASK ID from a step spec. A workflow author could name another tenant's
-- matrix task and read its outputs -- an exfiltration path with a YAML front
-- end. The authority that actually matters is "this task belongs to the run I
-- am executing", which execute_sql_step publishes above.
--
-- integration-rbac.sql widens this to "or a run the caller may read", for a
-- human or an API client calling it directly with an identity.
create or replace function workflow.matrix_outputs(p_task_id uuid)
returns jsonb as $$
declare v_run uuid; v_cur text;
begin
    select run_id into v_run from workflow.tasks where id = p_task_id;
    if not found then
        raise exception 'task % not found', p_task_id;
    end if;

    v_cur := nullif(current_setting('workflow.current_run_id', true), '');
    if v_cur is null or v_cur::uuid <> v_run then
        raise exception
            'task % belongs to run %, which is not the run being executed. A step may '
            'read the fan-out of its OWN run; pass {{steps.<id>.result.task_id}} rather '
            'than a task id from elsewhere.', p_task_id, v_run;
    end if;

    return (select coalesce(jsonb_agg(jsonb_build_object(
                'step_key', t.step_key, 'item', t.input->'item',
                'status', t.status, 'output', t.output)
            order by t.created_at, t.step_key), '[]'::jsonb)
            from workflow.tasks t where t.matrix_parent_id = p_task_id);
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- Read the recorded row set back, in expansion order. This is the "snapshot"
-- that §12's purity contract is about -- it is a query, not a column, because
-- the rows live where they are individually useful.
create or replace function workflow.matrix_rows(p_task_id uuid)
returns jsonb as $$
    select coalesce(jsonb_agg(t.input->'item' order by t.created_at, t.step_key), '[]'::jsonb)
    from workflow.tasks t
    where t.matrix_parent_id = p_task_id;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 20d. Children stay out of runs.context.
--
-- complete_task writes every output into runs.context under its step key, so
-- that {{steps.<key>.result}} works. For a fan-out that is the wrong shape at
-- both ends. runs.context is ONE jsonb column, rewritten in full on every
-- completion -- so N children make it N sequential rewrites of a value that
-- grows to N outputs, which is quadratic write amplification on the hottest
-- path in the schema, and blows §7's payload thinking to boot. And nothing
-- can read it usefully anyway: `fan[0]`, `fan[1]` ... are not names an author
-- writes.
--
-- So a matrix child completes without touching context. Its output is on its
-- own row, where a `sql` successor can aggregate over it in one statement --
-- and where the eventual {{items.<step>}} namespace will read it from, when a
-- second consumer justifies building one.
-- ------------------------------------------------------------
-- workflow.complete_task(uuid,jsonb,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20e. A worker has to be able to see its row.
--
-- get_task_context returns task_input, and the item is inside it -- but a
-- worker resolving {{item.cik}} should not have to know that {{run.*}} comes
-- from one key and {{item.*}} from a nested field of another. The three
-- namespaces are peers in the template language, so they are peers here.
-- `null` when the task is not a fan-out child, which is what makes the
-- worker's "you named item on a non-child" error possible at all.
-- ------------------------------------------------------------
-- workflow.get_task_context(uuid,text) is defined in section 16.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20f. Validation -- refuse at registration, not at 3am.
--
-- validate_spec (§1b) asks one question: is this GRAPH sound. Whether a
-- matrix step is well FORMED is a different question, and answering it inside
-- validate_spec's body would mean re-pasting eighty lines of reachability
-- closure to add a type check. Two functions, one trigger, and the trigger is
-- the enforcement point -- which is where it has always actually been.
-- ------------------------------------------------------------
create or replace function workflow.validate_matrix_steps(p_spec jsonb) returns void as $$
declare
    v_step jsonb;
    v_in   jsonb;
    v_tk   text;
    v_key  text;
begin
    if not exists (
        select 1 from jsonb_array_elements(p_spec->'steps') s
        where s->>'kind' = 'matrix')
    then
        return;
    end if;

    -- Children are keyed `<matrix_key>[<i>]`, so a declared key containing a
    -- bracket could shadow one. Cheap to forbid, and the alternative failure
    -- is a duplicate-key collision mid-expansion, after some children exist.
    for v_key in select s->>'key' from jsonb_array_elements(p_spec->'steps') s loop
        if v_key like '%[%' then
            raise exception
                'step key ''%'' contains ''['', which is reserved for matrix fan-out '
                'child keys (<step>[<i>])', v_key;
        end if;
    end loop;

    for v_step in
        select * from jsonb_array_elements(p_spec->'steps') s where s->>'kind' = 'matrix'
    loop
        v_in := coalesce(v_step->'input', '{}'::jsonb);
        v_tk := coalesce(v_in#>>'{template,kind}', 'work');

        if (v_in ? 'rows') = (v_in ? 'items') then
            raise exception
                'matrix step ''%'' must declare exactly one of `rows` or `items`',
                v_step->>'key';
        end if;
        if jsonb_typeof(v_in->'template') is distinct from 'object' then
            raise exception 'matrix step ''%'' has no template object', v_step->>'key';
        end if;
        if (v_in->>'max_fanout') is null or (v_in->>'max_fanout')::int < 1 then
            raise exception
                'matrix step ''%'' declares no max_fanout. Declaring the ceiling is the '
                'point: a cross join with a forgotten WHERE is the obvious way to hurt '
                'yourself here, and it should fail the task rather than the database.',
                v_step->>'key';
        end if;

        -- A child has no static successors to rewire, so a matrix inside a
        -- matrix would produce grandchildren that no aggregate ever waits on
        -- -- a run that completes early and looks fine. Refused by name.
        if v_tk = 'matrix' then
            raise exception
                'matrix step ''%'' templates another matrix. Nested fan-out is not '
                'supported: the grandchildren would never be joined to this step''s '
                'successors, so the run would complete before they finished.',
                v_step->>'key';
        end if;
        if v_tk in ('signal', 'decision') then
            raise exception
                'matrix step ''%'' templates kind ''%'', which has no meaning per-row '
                '-- a signal is addressed by name and a decision must be uniquely keyed',
                v_step->>'key', v_tk;
        end if;
    end loop;
end;
$$ language plpgsql;

-- workflow.check_spec_before_insert() is defined in section 1b.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20g. Making it automatic -- the same two hooks `sql` steps use.
--
-- A matrix step deploys nothing, so like a `sql` step it must run the moment
-- it becomes ready. Both entry points are the same two: the ON UPDATE trigger
-- for anything unblocked by a cascade, and the drain call in start_workflow
-- for a matrix that is itself a root (where no transition into ready ever
-- happens, because mark_roots_ready sets it on insert).
--
-- drain_sql_steps keeps its name and its surface-audit row; what it drains is
-- now "the kinds that run in-database", which is what it always meant.
-- ------------------------------------------------------------
-- workflow.autorun_sql_steps() is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- workflow.drain_sql_steps(uuid,int) is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20h-bis. An output that cannot be stored is a TERMINAL failure.
--
-- Found by the same EDGAR run. One child fetched Amazon's NetIncomeLoss
-- concept -- an ordinary single-company XBRL response -- and came back with
-- 69,248 bytes against the 65,536-byte cap. The payload trigger did what it
-- exists to do and raised. What happened next was wrong:
--
--     attempts | status | error
--     -------- + ------ + -------------------------------------------
--            4 | ready  | output payload is 69248 bytes, over the ...
--
-- It was RETRIED. Four times, with exponential backoff, on a failure that is
-- byte-for-byte identical on every attempt -- and it would have burned all
-- five attempts, re-fetching a public API each time, before failing anyway.
--
-- The worker cannot be blamed for that and cannot fix it: it classifies
-- terminal-vs-retryable from the HTTP status (4xx terminal, 5xx not), and the
-- HTTP call SUCCEEDED. The size limit is this engine's constraint, so this
-- engine has to be the one that knows retrying cannot help. Leaving it to the
-- worker would mean every third-party worker independently learning to string
-- match an error message this schema produced.
--
-- So complete_task checks the size ITSELF and fails the task terminally with
-- the remedy in the message, rather than raising and making the caller guess.
-- The task did not complete -- its output cannot be stored -- and `failed` is
-- the honest word for that.
--
-- WHAT THIS DOES NOT FIX, stated because the cap has now been hit twice by
-- real traffic: §7's `$ref` offload is the designed answer and the worker does
-- not implement it. The default was already raised once (8KB -> 64KB) after a
-- pipeline hit it; raising it again would move the wall rather than remove it,
-- and 69KB of JSON in a task row is exactly the TOAST and replication weight
-- the cap exists to keep out. The gap is the offload, not the number.
-- ------------------------------------------------------------
-- workflow.complete_task(uuid,jsonb,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20i. A task that completes twice must not decrement twice.
--
-- NOT a matrix bug, found by a matrix test. §7 of dev/tests/workflow/04
-- forces a re-expansion the way a reaper would (done -> ready -> done). The
-- second completion fired trg_cascade_task_status again, decrementing every
-- successor's pending_deps a second time -- so the rollup went from 3
-- outstanding children to 2, and would have fired one child early. The run
-- would have reported `completed` with a result computed over an incomplete
-- fan-out, which is this repo's worst failure shape.
--
-- The general statement: pending_deps is decremented on the TRANSITION into
-- done, and the done -> ready transition never re-increments it, so a second
-- decrement is always wrong. completed_at is the marker -- it is null on a
-- first completion and set on any subsequent one.
--
-- This was reachable before matrix steps existed (any double
-- complete_task on the same task), just not by any path anything took. The
-- fan-out re-expansion path takes it deliberately.
--
-- The SECURITY DEFINER clause is restated here and is not optional: CREATE OR
-- REPLACE resets the security attribute, and §16's self-check would (rightly)
-- refuse the install if this silently became SECURITY INVOKER.
-- ------------------------------------------------------------
-- workflow.cascade_task_status() is defined in section 8.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 20h. Grants. Same shape as §17: nothing here needs a table grant, because
-- every one of these is SECURITY DEFINER and the worker's whole interaction
-- is function calls.
-- ------------------------------------------------------------
-- expand_matrix is granted to NOBODY, and that is the interesting one.
-- Expansion is trigger-driven and reached from drain_sql_steps, both of which
-- are SECURITY DEFINER and therefore need no grant. Handing it to a user
-- identity would be a SECURITY DEFINER function that inserts up to max_fanout
-- task rows into a run chosen by the caller -- the exact shape
-- integration-rbac.sql's header calls out as confirmed exploitable elsewhere
-- in this schema. `worker` does not get it either: a worker never claims a
-- matrix task (they run in-database on queue 'none'), so the grant would be a
-- privilege it holds and never uses, which is precisely the kind that survives
-- long enough to be useful to an attacker.
revoke execute on function workflow.expand_matrix(uuid) from public;
-- matrix_rows reads a run's recorded snapshot, so it is user-facing and gets
-- the authorization check every user-facing SECURITY DEFINER function in this
-- collection gets. The check lives in integration-rbac.sql (f), next to
-- assert_run_access; this grant is what that file re-authorizes.
grant execute on function workflow.matrix_rows(uuid) to worker, authenticated;
grant execute on function workflow.matrix_outputs(uuid) to worker, authenticated;
grant execute on function workflow.resolve_args(jsonb, uuid, jsonb) to worker, authenticated;
grant execute on function workflow.resolve_template_ref(text, uuid, jsonb) to worker, authenticated;

-- Registered in the allow-list, so a fan-in needs no user code at all:
--   - id: gather
--     needs: [fan]
--     sql: {function: matrix_outputs, args: ['{{steps.fan.result.task_id}}']}
-- An author's own aggregate can equally call it directly and reduce inside.
select workflow.register_step_function('matrix_outputs', 'workflow.matrix_outputs',
    '{uuid}', 30000, 'Every child of a matrix step: its row, status and output');
-- call_step_function is DELIBERATELY not granted. It is the allow-list
-- dispatcher, reachable only through execute_sql_step and expand_matrix,
-- which decide WHICH task's arguments get passed to it. Granting it directly
-- would let any caller invoke any registered function with arguments of its
-- own choosing -- the allow-list without the workflow around it.
revoke execute on function workflow.call_step_function(text, jsonb, uuid, jsonb) from public;

do $$
declare v_bad text;
begin
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'workflow'
      and p.proname in ('expand_matrix','call_step_function','complete_task',
                        'get_task_context','execute_sql_step','drain_sql_steps')
      and not p.prosecdef;
    if v_bad is not null then
        raise exception 'MATRIX-PATH FUNCTIONS ARE NOT SECURITY DEFINER: %', v_bad;
    end if;
    raise notice 'workflow-engine 20: matrix path self-check passed';
end $$;

-- ============================================================
-- 21. What five real runs broke, and what was done about it.
--
-- §20 was designed, then exercised against live SEC EDGAR and Frankfurter
-- endpoints in five pipelines an agent authored from `SCHEMA "workflow"`.
-- Twelve faults came back. This section fixes them, and each fix carries the
-- run that found it -- because the value of a fault found by execution is the
-- specific thing it proved, and that is lost the moment it is summarised as
-- "hardening".
--
-- The through-line: every one of the twelve sat OUTSIDE the transaction. The
-- task graph itself never misbehaved under 256 tasks of real traffic. What
-- failed was the authoring surface, the worker contract, saga, and the
-- authorization model -- the parts furthest from the one place this system is
-- actually strong.
-- ============================================================

-- ------------------------------------------------------------
-- 21a. The output contract, and why the answer is NOT async.
--
-- FOUND BY: run 1, a three-stage pipeline that fetches USD rates and fans out
-- over the currencies in that response. The matrix never expanded:
--
--     template 'steps.latest.result' resolved to nothing
--
-- The worker had stored its http_call output as a JSON STRING containing
-- JSON, so runs.context->'latest' was a jsonb string and the one idiom every
-- step kind teaches -- {{steps.<id>.result}} -- resolved to nothing against
-- any REST step. Chaining anything to a fetch was impossible as documented.
--
-- THE QUESTION THIS RAISED: should http_call become fire-and-forget async
-- instead? No, and the reasoning is worth recording because the `mode`
-- field in the http_call spec makes it look like an open question.
--
-- Synchronous-in-the-worker is right for three reasons. (1) The invariant
-- that matters -- the DATABASE never blocks on someone else's latency -- is
-- already satisfied: the worker blocks, which costs worker capacity, and
-- worker capacity is the correct thing to spend on an outbound call. (2) A
-- fire-and-forget call needs a callback endpoint, a correlation key, and a
-- policy for the callback that never arrives; that is a second execution path
-- with its own failure modes, which is exactly what this engine refuses
-- everywhere else. (3) Retry, backoff, the reaper, saga and cancellation all
-- apply to http_call today ONLY because it is an ordinary task; an async
-- dispatch would have to re-earn each of them.
--
-- The real defect was never sync-vs-async. It was that the output contract
-- was written in prose and enforced nowhere. A long-running call is a
-- capacity problem, answered with more workers or a timer-and-poll composed
-- from existing kinds -- not with a second dispatch model.
--
-- SO THE CONTRACT IS ENFORCED HERE. A double-encoded output is repaired,
-- because rejecting it would brick every shipped worker and turn one bug into
-- an outage -- but the repair is RECORDED, so a defect that was invisible
-- becomes a row anyone can count. Silent leniency is how a contract rots;
-- leniency plus a ledger is how it gets fixed.
-- ------------------------------------------------------------
create or replace function workflow.normalize_output(p_task_id uuid, p_output jsonb)
returns jsonb as $$
declare v_inner jsonb;
begin
    -- Only the unambiguous case: a jsonb STRING whose text is itself a JSON
    -- object or array. No legitimate producer serialises a document into a
    -- string to hand to a jsonb parameter. A genuine scalar output -- "ok", a
    -- number -- is left exactly as it is.
    if p_output is null or jsonb_typeof(p_output) <> 'string' then
        return p_output;
    end if;

    begin
        v_inner := (p_output #>> '{}')::jsonb;
    exception when others then
        return p_output;          -- an ordinary string that is not JSON
    end;

    if jsonb_typeof(v_inner) not in ('object', 'array') then
        return p_output;
    end if;

    insert into workflow.task_events (task_id, run_id, from_status, to_status, detail)
    select p_task_id, t.run_id, t.status, t.status,
           jsonb_build_object(
             'event', 'output_normalized',
             -- Reached from complete_task's output AND fail_task's error, so
             -- the sentence names both rather than the first one it was
             -- written for. One event name for both on purpose: it is one
             -- producer defect, and encoding_drift() should count it once.
             'why', 'a result arrived double-encoded: a JSON document serialised into '
                    'a string. Repaired so {{steps.<id>.result}} resolves and so '
                    'error->>''error'' is readable; the producer should pass the object '
                    'to complete_task/fail_task(uuid, jsonb), not its text.',
             'queue', t.queue, 'kind', t.kind, 'claimed_by', t.claimed_by)
    from workflow.tasks t where t.id = p_task_id;

    return v_inner;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The ledger. A producer violating the output contract is now a number, not a
-- rumour -- so it can be watched, put in a dashboard, and closed.
create or replace function workflow.encoding_drift()
returns table (queue text, kind text, claimed_by text, repairs bigint, last_seen timestamptz) as $$
    select e.detail->>'queue', e.detail->>'kind', e.detail->>'claimed_by',
           count(*), max(e.at)
    from workflow.task_events e
    where e.detail->>'event' = 'output_normalized'
    group by 1,2,3 order by 4 desc;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 21b. Rate limiting stops being decoration.
--
-- FOUND BY: run 4. Thirty children against SEC EDGAR with `rate_key:
-- sec-edgar` declared and a token bucket configured at capacity 10:
--
--     rate_key stored on children: 30
--     rate limit tokens: 10.00   (capacity 10 -- untouched)
--     measured throughput: 12.94 req/s   (SEC publishes a 10/s ceiling)
--
-- Every piece existed -- the bucket, try_consume_rate_limit,
-- claim_task_rate_limited -- and nothing called them, because the worker
-- calls claim_task. A throttle that reads as configured and is not is worse
-- than no throttle: it is the reason someone points a fan-out at a
-- regulator's API believing they are polite.
--
-- Fixed in claim_task rather than in the worker, deliberately. Rate limiting
-- is a property of the QUEUE, not of whoever happens to be polling it, and a
-- limit that every third-party worker has to opt into is a limit that some
-- worker will not. This also means it works today, with the shipped image,
-- with no client change.
--
-- Behaviour is identical for a task with no rate_key, so nothing that worked
-- before changes.
-- ------------------------------------------------------------
-- workflow.claim_task(text,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21c. Saga LIFO ordering was a no-op.
--
-- FOUND BY: run 3. begin_compensation orders by `completed_at DESC` to undo
-- in reverse, and complete_task set completed_at with now() -- the
-- TRANSACTION timestamp. Every step finishing inside one transaction shares
-- it, which is the normal case for the in-database steps this engine is
-- proudest of:
--
--     charge   completed_at = 2026-09-01 13:29:23.659428+00
--     reserve  completed_at = 2026-09-01 13:29:23.659428+00
--     distinct completed_at values among saga members: 1
--
-- It compensated `charge` before `reserve` -- forward order. clock_timestamp()
-- advances within a transaction and is what an ordering column needs; now()
-- is right for "when this unit of work happened" and wrong for "in what order
-- did these happen".
--
-- The tie-break on id is not decoration either: two steps CAN still share a
-- microsecond, and a stable order beats an arbitrary one.
-- ------------------------------------------------------------
-- workflow.complete_task(uuid,jsonb,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21d. Saga compensation, which did not work in four ways.
--
-- FOUND BY: run 3, a booking saga -- charge, reserve, issue ticket -- where
-- the ticket fails. This is the capability spec.md §6 calls the single largest
-- gap closed against DBOS, River and Temporal. It had been exercised from SQL
-- and never once through the compiler. What came back:
--
--     RUN failed / compensation_state none
--     charge  | done      ledger: 1 charge_card
--     reserve | done              2 reserve_room
--     refund  | DONE              4 REFUND      <-- ran forward
--     release | DONE              5 RELEASE     <-- ran forward
--     ticket  | failed
--
-- (1) THE COMPENSATIONS RAN FORWARD. `refund` and `release` are declared as
--     steps, they have no `needs`, so start_workflow created them as ROOTS and
--     they executed immediately. The customer was refunded during a successful
--     booking, before anything had failed.
--
--     Fixed by DERIVING it rather than declaring it: a step named as another
--     step's compensation_task_key is a compensation, and compensations are
--     not part of the forward graph. The definition already carried that fact;
--     nothing read it. No compiler change and no new syntax -- and existing
--     stored definitions are fixed by this without being rewritten.
--
-- (2) COMPENSATION NEVER TRIGGERED. compensation_state stayed 'none'.
--     fail_task never called begin_compensation, and nothing else did. §6
--     describes it as automatic on terminal failure. It was wired to nothing.
--
-- (3) THE COMPENSATION TASKS WERE UNRUNNABLE. begin_compensation created them
--     as kind='work' on the FORWARD task's queue, so a `sql` compensation
--     became a `work` task on queue 'none' -- which nothing polls and no
--     handler serves. Both sat 'ready' forever. Now the compensation step's
--     own kind, queue and input are read from the definition, so a `sql`
--     compensation runs in-database and a `rest` one goes to the worker,
--     exactly as written.
--
-- (4) The reverse ordering was a no-op -- fixed in 21c.
--
-- What this does NOT change: compensations are still ordinary tasks, so they
-- still inherit retry, backoff, the reaper and the audit trail, which was the
-- whole argument for the design.
-- ------------------------------------------------------------

-- Which step keys in a spec are compensations rather than forward steps.
-- Derived from the spec itself: nothing has to declare it twice.
create or replace function workflow.compensation_keys(p_spec jsonb)
returns text[] as $$
    select coalesce(array_agg(distinct s->>'compensation_task_key'), '{}')
    from jsonb_array_elements(p_spec->'steps') s
    where s->>'compensation_task_key' is not null;
$$ language sql immutable;

-- workflow.start_workflow(text,jsonb,text,text) is defined in section 9.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- 21d(3): the compensation runs as the step the author actually wrote.
-- workflow.begin_compensation(uuid,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- 21d(2): terminal failure inside a saga group starts the rollback. This is
-- what §6 always said happened.
-- workflow.fail_task(uuid,jsonb,boolean) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21e. A fan-out that survives a failed child.
--
-- FOUND BY: runs 4 and, before them, the first realistic EDGAR pipeline. Both
-- died the same way and for the most ordinary reason there is:
--
--     fan[5]  Amazon / Revenues  ->  HTTP 404
--     report  cancelled
--
-- Amazon does not tag us-gaap:Revenues. That is not an outage, it is what a
-- registry looks like. §20 shipped with pure AND-join semantics and called
-- this a sharp edge for the fourth thousand; the FIRST six-wide run hit it.
-- A matrix over real sources meets an absent concept, a rate limit or an
-- oversized response on essentially every run, so this is not a refinement of
-- fan-out -- it is the difference between having it and not.
--
--     matrix:
--       continue_on: failed        # a failed child satisfies its dependents
--       min_success: 0.9           # ...but at least 90% must succeed
--
-- min_success takes a FRACTION (<= 1) or an absolute COUNT (> 1). Both, because
-- "at least 8 of them" and "at least 90% of them" are different intentions and
-- a fan-out whose width is decided by a query cannot always express one as the
-- other.
--
-- THE PART THAT IS EASY TO GET WRONG: a tolerated failure must still SATISFY
-- its dependents, not merely stop cancelling them. Skipping the cancel without
-- decrementing pending_deps leaves the aggregate blocked forever on a child
-- that will never finish -- a stall instead of a cancellation, which is worse
-- because nothing reports it.
--
-- And the threshold has to be checked BEFORE the successor is released, not
-- after. A `sql` successor auto-runs inside the same statement that marks it
-- ready (§17), so releasing first and cancelling second would run the
-- aggregate over an under-strength fan-out and then cancel a task that had
-- already written its output.
-- ------------------------------------------------------------
alter table workflow.tasks
    add column if not exists tolerate_failure boolean not null default false;

-- Did enough of this matrix's children succeed? Null min_success means the
-- old behaviour -- every child must succeed -- so nothing that worked before
-- changes.
create or replace function workflow.matrix_gate_passes(p_matrix_id uuid)
returns boolean as $$
declare
    v_spec  jsonb;
    v_min   numeric;
    v_total int;
    v_ok    int;
    v_need  int;
begin
    select input into v_spec from workflow.tasks where id = p_matrix_id;
    v_min := nullif(v_spec->>'min_success', '')::numeric;
    if v_min is null then
        return true;
    end if;

    select count(*), count(*) filter (where status = 'done')
    into v_total, v_ok
    from workflow.tasks where matrix_parent_id = p_matrix_id;

    if v_total = 0 then
        return true;      -- an empty matrix had nothing to fail
    end if;

    -- <= 1 reads as a fraction, > 1 as a count. ceil() because "90% of 6" is
    -- 5.4 and accepting 5 would be rounding a guarantee down.
    v_need := case when v_min <= 1 then ceil(v_min * v_total)::int else v_min::int end;
    return v_ok >= v_need;
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- workflow.cascade_task_status() is defined in section 8.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- A tolerated failure is terminal for THIS task and neutral for the run: it
-- must not mark the run failed, and it needs completed_at so the
-- double-decrement guard above sees it.
-- workflow.fail_task(uuid,jsonb,boolean) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- A run whose only unfinished tasks are tolerated failures IS finished.
-- Without this a fan-out with continue_on could never reach 'completed' --
-- it would sit in 'running' forever, which is the stall this whole section
-- exists to avoid.
create or replace function workflow.check_run_completion(p_run_id uuid) returns void as $$
    update workflow.runs r
    set status = 'completed', completed_at = now()
    where r.id = p_run_id
      and r.status = 'running'
      and not exists (
          select 1 from workflow.tasks t
          where t.run_id = p_run_id
            and t.status <> 'done'
            and not (t.status = 'failed' and t.tolerate_failure));
$$ language sql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 21f. Agent steps with a declared output shape.
--
-- An `agent:` step returns whatever a language model felt like returning, and
-- the moment you fan out over N documents and try to combine the verdicts you
-- need to know the shape without inspecting each one. Declaring it turns a
-- pile of prose into a column.
--
--     - id: classify
--       agent: triage
--       input: 'Classify: {{item.text}}'
--       output_schema:
--         type: object
--         required: [verdict, confidence]
--         properties:
--           verdict:    {type: string, enum: [SAFETY, FINANCE, OTHER]}
--           confidence: {type: number}
--
-- Two decisions worth stating.
--
-- A SHAPE CHECK, NOT JSON SCHEMA. Types, required keys, enums, and closing the
-- object -- that is what "combine N agent results safely" actually needs, and
-- it is checkable in a few lines of SQL. Implementing $ref, allOf and pattern
-- in PL/pgSQL to be able to say "JSON Schema" would be a validator nobody
-- audited, wrong in ways only a corpus would reveal. What is unsupported is
-- named below rather than silently ignored, which is the difference between a
-- subset and a lie.
--
-- A SHAPE VIOLATION IS RETRYABLE, and this is the one place where retry is
-- obviously right rather than merely defensible: the same prompt genuinely can
-- produce conforming output on the next attempt. Every other terminal
-- classification in this engine exists because retrying cannot help. Here it
-- can, so max_attempts becomes a real budget for "ask again".
-- ------------------------------------------------------------
create or replace function workflow.validate_shape(p_value jsonb, p_schema jsonb)
returns text as $$
declare
    v_key   text;
    v_prop  jsonb;
    v_want  text;
    v_got   text;
    v_extra text[];
begin
    if p_schema is null or p_schema = '{}'::jsonb then
        return null;
    end if;
    if p_value is null then
        return 'output is null, but a shape was declared';
    end if;

    v_want := p_schema->>'type';
    if v_want is not null then
        v_got := jsonb_typeof(p_value);
        -- JSON has one number type; `integer` is a number that is whole.
        if v_want = 'integer' then
            if v_got <> 'number' or (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric) then
                return format('expected an integer, got %s', coalesce(v_got, 'null'));
            end if;
        elsif v_want <> v_got then
            return format('expected type %s, got %s', v_want, coalesce(v_got, 'null'));
        end if;
    end if;

    if p_schema ? 'enum' and not (p_schema->'enum' @> jsonb_build_array(p_value)) then
        return format('value %s is not one of %s', p_value::text, (p_schema->'enum')::text);
    end if;

    if jsonb_typeof(p_value) = 'object' then
        for v_key in select jsonb_array_elements_text(coalesce(p_schema->'required', '[]'::jsonb))
        loop
            if not (p_value ? v_key) then
                return format('missing required key %L', v_key);
            end if;
        end loop;

        if p_schema ? 'properties' then
            for v_key in select jsonb_object_keys(p_schema->'properties') loop
                if p_value ? v_key then
                    v_got := workflow.validate_shape(p_value->v_key, p_schema#>array['properties', v_key]);
                    if v_got is not null then
                        return format('%s: %s', v_key, v_got);
                    end if;
                end if;
            end loop;

            -- Closing the object is opt-in, and off by default, because an
            -- agent adding a field it was not asked for is not usually a
            -- reason to throw the answer away.
            if (p_schema->>'additionalProperties') = 'false' then
                select array_agg(k) into v_extra
                from jsonb_object_keys(p_value) k
                where not (p_schema->'properties' ? k);
                if v_extra is not null then
                    return format('unexpected key(s) %s', array_to_string(v_extra, ', '));
                end if;
            end if;
        end if;
    end if;

    if jsonb_typeof(p_value) = 'array' and p_schema ? 'items' then
        for v_prop in select * from jsonb_array_elements(p_value) loop
            v_got := workflow.validate_shape(v_prop, p_schema->'items');
            if v_got is not null then
                return format('array element: %s', v_got);
            end if;
        end loop;
    end if;

    return null;   -- conforms
end;
$$ language plpgsql immutable;

comment on function workflow.validate_shape(jsonb, jsonb) is
  'Structural subset of JSON Schema: type (incl. integer), required, properties, '
  'enum, items, additionalProperties:false. NOT supported and rejected loudly if '
  'relied on: $ref, allOf/anyOf/oneOf, pattern, format, numeric bounds, '
  'minItems/maxItems. Named so a caller knows what the check does and does not buy.';

-- ------------------------------------------------------------
-- 21g. Sub-workflows had never executed.
--
-- FOUND BY: adding `workflow:` to the YAML vocabulary and then trying it.
-- start_child_workflow inserted a row into workflow.runs and NEVER EXPANDED
-- THE CHILD'S TASK GRAPH -- it did not call start_workflow. So a child run had
-- zero tasks, nothing ever called check_run_completion for it, and it sat in
-- 'running' forever with the parent blocked behind it in waiting_external.
-- Composition, one of the five kinds this engine advertises, had never once
-- run.
--
-- The ordering below is the subtle part. A child made only of in-database
-- steps COMPLETES INSIDE start_workflow, before this function could have
-- recorded who its parent is -- so resolve_parent_on_child_completion would
-- fire with parent_task_id still null and the parent would wait forever on a
-- child that had already finished. The parent link is therefore established
-- first where it can be, and an already-finished child is resolved explicitly.
-- ------------------------------------------------------------
-- workflow.start_child_workflow(uuid,text,jsonb) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21h. Completion, final form: repair, validate, then store.
--
-- The order is the contract. Repair first (21a) so a double-encoded document
-- is a document before anything looks at it. Then, if the step declared an
-- output_schema, parse a JSON-in-a-string payload -- which is what a model
-- returns, since an agent step's result is message content -- and check the
-- shape. Only then does anything get written.
--
-- A shape violation fails the task RETRYABLY, which is the opposite of every
-- other classification here and deliberately so: asking a model again is a
-- real remedy, where re-fetching an oversized response or re-requesting a 404
-- is not.
-- ------------------------------------------------------------
-- workflow.complete_task(uuid,jsonb,text) is defined in section 10.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21i. Timers and sub-workflows start themselves.
--
-- Both were reachable only from a worker, which meant neither could appear in
-- a pipeline that otherwise deploys nothing -- and a `timer` whose delay is
-- measured from the START of the run rather than from the moment its
-- dependencies finish is not a timer, it is a coincidence. The delay begins
-- when the step becomes ready, which is what "wait 30s after the fetch" means.
-- ------------------------------------------------------------
-- workflow.autorun_sql_steps() is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- workflow.drain_sql_steps(uuid,int) is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21j. A scheduled run belongs to whoever scheduled it.
--
-- FOUND BY: run 5. A human-in-the-loop workflow could not be signalled:
--
--     ERROR: not authorized to signal run 40fa2d57-...
--     run owner_id: (null = system-owned)
--
-- tick() runs as `scheduler` with no JWT, so every scheduled run came out
-- owner-less, and assert_run_access deliberately treats a null owner as owned
-- by nobody -- correctly, since "unowned" must not mean "everyone's". But
-- nothing granted the fallback permission either, so the door was welded shut
-- rather than locked: a scheduled workflow that waits for approval could never
-- be approved, by anyone.
--
-- The fix is not to weaken the check. A schedule already HAS an owner, set
-- from the verified JWT of whoever created it, and a run that schedule starts
-- is that person's run. Carrying the identity across is what was missing --
-- authority should follow provenance, not be granted around it.
-- ------------------------------------------------------------
-- workflow.tick(timestamptz) is defined in section 19.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 21k. A dead run is not an idempotent hit.
--
-- FOUND BY: driving the scheduled approval flow. A run for that minute had
-- been cancelled; tick() called start_workflow with the same external_id and
-- got the CANCELLED run back, reported `fired: 1`, and recorded a successful
-- fire. Nothing was started and nothing said so.
--
--     external_id: schedule:approval_nightly:2026-09-01T14:04Z
--     status:      cancelled
--     -> returned as "already started"
--
-- The idempotency guard matched on external_id alone. That is right for a run
-- that is running or completed -- the work happened, do not repeat it -- and
-- wrong for one that was cancelled or failed, where the work did NOT happen
-- and the caller is being told it did.
--
-- external_id is UNIQUE, so a retry cannot silently mint a second run under
-- the same key; the honest move is to say so by name and let the caller decide
-- (a scheduler records it in last_error, which is exactly the column for it).
-- Guessing -- reusing the corpse, or inventing a suffixed key -- would make
-- "idempotent" mean two different things depending on how the last attempt
-- died.
--
-- AND: a cancelled run's tasks could still be driven to completion.
-- complete_decision_task and add_task both refuse to act under a cancelled
-- run; complete_task never checked, so a worker finishing in-flight work
-- resurrected a cancelled run's graph one step at a time. The signal path had
-- the same hole.
-- ------------------------------------------------------------
-- workflow.start_workflow(text,jsonb,text,text) is defined in section 9.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ============================================================
-- 22. Reported by building a real pipeline against this engine.
--
-- An 18-task brief-generator -- 8 REST ingestions, 8 SQL landings, a model leg
-- and a render -- ran end to end and needed three workarounds to get there.
-- The workarounds are the report. Each fix below carries the symptom it was
-- filed under, because a bug found by someone building something is worth more
-- than one found by reading, and the thing that makes it worth more is the
-- specific shape of what they were trying to do.
-- ============================================================

-- ------------------------------------------------------------
-- 22a. BUG 1 -- the run cannot see itself.
--
--     template 'run.id' resolved to nothing   (sqlstate P0001)
--
-- 8 of 18 tasks. {{run.*}} resolved only into the run's INPUT jsonb, so
-- runs.id, trace_id and external_id -- the run's own columns -- were
-- unreachable from a template.
--
-- WHAT MAKES THIS MORE THAN AN OMISSION, and the reporter is exactly right:
-- it cannot be worked around by passing the id in as run input, because THE
-- CALLER DOES NOT KNOW THE RUN ID UNTIL start_workflow RETURNS. The value
-- would have to be an argument to the call that creates it. So run-scoped
-- state -- land rows keyed by run, aggregate them, render -- which is the
-- normal shape of a pipeline, forced every author to mint a correlation id the
-- engine already owned and would not hand over.
--
-- RESERVED `$` PREFIX rather than plain {{run.id}}. An input key literally
-- named `id` is not unusual, and silently shadowing it would make the same
-- template mean different things depending on the caller's payload. `$` cannot
-- collide with an ordinary key, and it reads as "this comes from the engine".
--
-- {{run.id}} with no such input key now says what to write instead, because
-- the natural thing to type is the thing the reporter typed.
-- ------------------------------------------------------------
create or replace function workflow.run_meta(p_run_id uuid)
returns jsonb as $$
    select jsonb_build_object(
        '$id',          r.id::text,
        '$trace_id',    r.trace_id,
        '$external_id', r.external_id,
        '$definition',  d.name,
        '$version',     d.version,
        '$started_at',  to_char(r.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ'),
        -- FEATURE 1a: an engine-minted session, stable for the life of the run,
        -- so several agent steps share one conversation by naming it and stay
        -- stateless by omitting it. Derived rather than stored: the same run
        -- yields the same id on every resolution, including a replay, without a
        -- column that could drift from the run it belongs to.
        '$session',     md5(r.id::text || ':')::uuid::text)
    from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    where r.id = p_run_id;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- One id per (run, group), so one run can hold two independent conversations.
create or replace function workflow.run_session(p_run_id uuid, p_group text default '')
returns uuid as $$
    select md5(p_run_id::text || ':' || coalesce(p_group, ''))::uuid;
$$ language sql immutable;

-- workflow.resolve_args(jsonb,uuid,jsonb) is defined in section 20a.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- The worker resolves {{run.*}} out of the `run_input` it is handed, and it is
-- a shipped image that will not learn a new namespace. Merging the $-prefixed
-- fields INTO run_input makes {{run.$id}} work in a `rest` step with no client
-- change at all -- and it cannot shadow anything, because that is what the
-- reserved prefix is for.
-- workflow.get_task_context(uuid,text) is defined in section 16.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 22b. BUG 2 -- registration checked the wrong role's privileges.
--
--     permission denied for schema brief
--
-- Raised per task, at runtime, after registration succeeded. A function in a
-- newly created schema registered cleanly and failed on every invocation, and
-- the message named the SCHEMA rather than the registration -- so it read as a
-- database misconfiguration rather than "you skipped a grant", with nothing
-- pointing back at register_step_function.
--
-- register_step_function verified only that the function EXISTS, via
-- to_regprocedure -- which resolves with the CALLER's privileges. But
-- execute_sql_step is SECURITY DEFINER, so the role that will actually call it
-- is the function's owner. Registering as a superuser therefore always
-- succeeded, because a superuser can see everything, and told you nothing
-- about whether the definer could.
--
-- The definer is looked up rather than hardcoded: this file must not assume it
-- is installed as any particular role.
-- ------------------------------------------------------------
-- workflow.register_step_function(text,text,text[],int,text) is defined in section 17.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 22c. BUG 3 -- the two halves can ship out of step, silently.
--
--     workflow YAML did not compile: step 'fan' must have exactly one of
--     p8ql/sql/rest/agent/work, found none
--
-- ...for a `matrix:` step that YAML.md documents in full. The SQL half had
-- shipped (`kind='matrix'` is in the CHECK constraint, matrix_parent_id and
-- tolerate_failure exist) and the compiled parser had not, so the error
-- described a syntax problem in a document whose syntax was correct.
--
-- The reporter's cost is the argument: the matrix version of their workflow is
-- 3 steps and the hand-expanded version is 18.
--
-- Rebuilding is the fix for the instance. The fix for the CLASS is to stop
-- guessing: probe the installed compiler with a canary per kind and let it say
-- what it actually accepts. Derived, not declared -- the same discipline the
-- schema facet's example corpus uses, for the same reason.
-- ------------------------------------------------------------
create or replace function workflow.compiler_capabilities()
returns jsonb as $$
declare
    v_out   jsonb := '{}'::jsonb;
    v_case  record;
    v_res   jsonb;
begin
    if to_regprocedure('p8_compile_workflow(text)') is null then
        return jsonb_build_object('available', false,
            'why', 'p8_compile_workflow is not installed -- the percolate extension is missing');
    end if;

    for v_case in
        select * from (values
            ('sql',          E'name: c\nsteps:\n  - id: s\n    sql: {function: f}'),
            ('p8ql',         E'name: c\nsteps:\n  - id: s\n    p8ql: ''LOOKUP "x"'''),
            ('rest',         E'name: c\nsteps:\n  - id: s\n    rest: {url: http://x}'),
            ('embed',        E'name: c\nsteps:\n  - id: s\n    embed: hello'),
            ('agent',        E'name: c\nsteps:\n  - id: s\n    agent: a'),
            ('work',         E'name: c\nsteps:\n  - id: s\n    work: true'),
            ('matrix',       E'name: c\nsteps:\n  - id: s\n    matrix:\n      items: []\n      max_fanout: 1\n      template: {work: true}'),
            ('signal',       E'name: c\nsteps:\n  - id: s\n    signal: true'),
            ('timer',        E'name: c\nsteps:\n  - id: s\n    timer: 1'),
            ('sub_workflow', E'name: c\nsteps:\n  - id: s\n    workflow: other'),

            ('continue_on',  E'name: c\nsteps:\n  - id: s\n    matrix:\n      items: []\n      max_fanout: 1\n      continue_on: failed\n      min_success: 0.5\n      template: {work: true}')
        ) as t(feature, yaml)
    loop
        execute 'select p8_compile_workflow($1)' into v_res using v_case.yaml;
        v_out := v_out || jsonb_build_object(v_case.feature, coalesce((v_res->>'ok')::boolean, false));
    end loop;

    -- output_schema cannot be probed by compile-success and it is worth saying
    -- why: serde drops unknown keys silently, so a compiler that has never
    -- heard of it accepts the document and emits nothing. Compiling is
    -- therefore not evidence -- the emitted SPEC is. This is the general trap
    -- with capability probes: "it did not error" and "it did the thing" are
    -- different questions, and only the second one is useful.
    execute 'select p8_compile_workflow($1)' into v_res using
        E'name: c\nsteps:\n  - id: s\n    rest: {url: http://x}\n    output_schema: {type: object}';
    v_out := v_out || jsonb_build_object('output_schema',
        coalesce(v_res#>'{workflow,spec,steps,0,input}' ? 'output_schema', false));

    -- The vector desugar is the other feature compile-success cannot probe,
    -- and for the opposite reason to output_schema: a compiler that has never
    -- heard of it accepts the document AND emits a step -- just one, calling
    -- the one-argument p8ql, which fails at dispatch on a query that is
    -- correct as written. So the probe counts the ROWS, which is the only
    -- place the difference exists.
    execute 'select p8_compile_workflow($1)' into v_res using
        E'name: c\nsteps:\n  - id: s\n    p8ql: ''SEARCH "x" FROM chunks''';
    v_out := v_out || jsonb_build_object('p8ql_vector_desugar',
        coalesce(jsonb_array_length(v_res#>'{workflow,spec,steps}') = 2, false));

    return jsonb_build_object('available', true, 'accepts', v_out,
        'missing', coalesce((select jsonb_agg(k order by k)
                             from jsonb_each(v_out) e(k, v) where v = 'false'::jsonb), '[]'::jsonb));
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- define_yaml, with the halves' disagreement made legible. A compile error
-- that mentions the one-of rule on a document using a feature the installed
-- compiler does not have is not a syntax error, and saying so is the whole
-- difference between "my YAML is wrong" and "my extension is old".
-- workflow.define_yaml(text) is defined in section 18.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 22d. `{{run.$*}}` is bound before the worker ever sees it.
--
-- FOUND BY: probing the fix for BUG 1 rather than assuming it. A `rest` step
-- whose body carried both spellings:
--
--     {{run.plain}}  ->  PLAIN-OK      resolved
--     {{run.$id}}    ->  {{run.$id}}   sent literally
--
-- The reserved `$` prefix is exactly what stops an input key shadowing an
-- engine field -- and the shipped worker's template pattern does not admit `$`.
-- So the fix worked in `sql` steps, where this database resolves, and failed
-- SILENTLY in `rest` and `agent` steps, where the worker does. A session id
-- would have been threaded as the literal string "{{run.$session}}" on every
-- call: two steps sharing a conversation named by a template that was never
-- resolved, which looks exactly like success.
--
-- The answer is the one §20a-bis already established for {{item.*}}: if the
-- worker cannot know a namespace, the engine binds it before dispatch. A
-- worker should not have to learn a namespace to stay correct, and the engine
-- is the only party that can be relied on to know one.
--
-- Bound in get_task_context rather than stored, because unlike a fan-out
-- child's row -- which exists for exactly one task and is its record -- run
-- metadata is derivable at any time and baking it into the stored input would
-- freeze a value that should be read fresh on a retry.
-- ------------------------------------------------------------
create or replace function workflow.substitute_meta(p_value jsonb, p_meta jsonb)
returns jsonb as $$
declare
    v_txt text; v_out jsonb; v_key text; m text[]; v_val jsonb;
begin
    if p_value is null then return null; end if;

    case jsonb_typeof(p_value)
    when 'object' then
        v_out := '{}'::jsonb;
        for v_key in select jsonb_object_keys(p_value) loop
            v_out := v_out || jsonb_build_object(
                v_key, workflow.substitute_meta(p_value->v_key, p_meta));
        end loop;
        return v_out;
    when 'array' then
        return coalesce((select jsonb_agg(workflow.substitute_meta(e, p_meta) order by ord)
                         from jsonb_array_elements(p_value) with ordinality x(e, ord)), '[]'::jsonb);
    when 'string' then
        v_txt := p_value #>> '{}';
        if v_txt !~ '\{\{\s*run\.\$' then
            return p_value;             -- nothing of ours in it
        end if;
        -- Whole-string reference keeps its native type; embedded is text.
        m := regexp_match(v_txt, '^\s*\{\{\s*run\.(\$[a-zA-Z0-9_]+)\s*\}\}\s*$');
        if m is not null then
            v_val := p_meta -> m[1];
            if v_val is null then
                raise exception 'unknown engine field ''run.%''. Available: %',
                    m[1], (select string_agg(k, ', ' order by k) from jsonb_object_keys(p_meta) k);
            end if;
            return v_val;
        end if;
        for m in select regexp_matches(v_txt, '\{\{\s*run\.(\$[a-zA-Z0-9_]+)\s*\}\}', 'g') loop
            v_val := p_meta -> m[1];
            if v_val is null then
                raise exception 'unknown engine field ''run.%''. Available: %',
                    m[1], (select string_agg(k, ', ' order by k) from jsonb_object_keys(p_meta) k);
            end if;
            v_txt := regexp_replace(v_txt, '\{\{\s*run\.\' || m[1] || '\s*\}\}',
                case when jsonb_typeof(v_val) = 'string' then v_val #>> '{}' else v_val::text end,
                'g');
        end loop;
        return to_jsonb(v_txt);
    else
        return p_value;
    end case;
end;
$$ language plpgsql immutable;

-- workflow.get_task_context(uuid,text) is defined in section 16.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

-- ------------------------------------------------------------
-- 23. Crash recovery, the first time anything ran it.
--
-- FOUND BY: a coverage pass with `track_functions='all'` over a clean install
-- plus the whole suite. 47 of 62 workflow functions had been invoked; 15 had
-- not, and three of the fifteen were `heartbeat_task`, `reap_stale_tasks` and
-- `complete_decision_task` -- between them the entire crash-recovery and
-- replay story, described in spec.md §3 and §4 in the present tense, reported
-- present by the surface audit, and never once executed by anything.
--
-- Executing them found two defects and confirmed a third by reading. The
-- shape they share is worth naming before the details: **the engine had no
-- concept of a lease**. It knew a task was `running` and which worker string
-- had claimed it, and nothing anywhere checked that the worker asking to
-- finish a task was the worker still entitled to.
--
-- 23a. THE ZOMBIE. A worker that is slow is indistinguishable from a worker
-- that is dead, and the difference only appears afterwards.
--
--     worker A claims task a                     -> running, claimed_by=A
--     A is partitioned; heartbeats stop
--     reap_stale_tasks()                         -> ready, claimed_by=null
--     worker B claims task a                     -> running, claimed_by=B
--     A comes back and calls complete_task(a, …)
--
-- Reproduced against a live PG19 beta3 instance, and every step of what
-- followed was wrong:
--
--     after zombie A completes: status=done claimed_by=worker-B
--                               context={"a": {"result": "STALE-from-A"}}
--     successor b status: ready
--     after real owner B completes:
--                               context={"a": {"result": "FRESH-from-B"}}
--
-- A's stale answer was published and the successor was released with it; then
-- B's real answer silently overwrote the same key AFTER a downstream step had
-- already read the other one. So `{{steps.a.result}}` resolved to two
-- different values over the life of one run, both workers did the work, and
-- nothing was logged. `complete_task` ended in an unqualified
-- `update workflow.tasks set status = 'done' where id = p_task_id` -- no
-- status guard, no ownership guard -- so this was not an edge case, it was the
-- only behaviour there was.
--
-- The fix is `workflow.lease_violation()`, applied by complete_task, fail_task
-- and heartbeat_task. Three things about its shape are deliberate:
--
--   * It tests `attempts > 0 and status <> 'running'`, not just worker ids.
--     A reaped task spends its backoff `ready` and unclaimed, and an id
--     comparison passes vacuously against a null holder -- so whether the
--     zombie won would have depended on whether a replacement had claimed
--     yet. That is a race deciding whose answer is authoritative.
--   * `attempts = 0` is left open. That is a task nobody ever claimed, which
--     is how every in-database path (execute_sql_step, expand_matrix) and
--     every test drives the engine, and none of them can lie about an
--     identity they do not have.
--   * A refusal is RECORDED, as a `lease_violation` task_event behind
--     `v_lease_violations`. A completion that vanishes silently looks exactly
--     like a worker that never ran -- the same argument §21a makes for
--     recording output repairs rather than quietly performing them.
--
-- `heartbeat_task` returning false now means "stop" for three reasons rather
-- than one: the run was cancelled, the task is terminal, or your lease was
-- reaped. A partitioned worker asking whether to keep going is precisely the
-- caller that has to be told no.
--
-- 23b. THE REAPER HAD ITS OWN RETRY POLICY, AND IT DISAGREED WITH THE REAL ONE.
--
-- `reap_stale_tasks` returned stale tasks straight to `ready` and touched
-- nothing else. Measured:
--
--     after 10 crash cycles: attempts=10 status=ready (max_attempts=5)
--     still claimable? t     run status: running
--     visible in v_stuck_tasks? 0
--
-- `max_attempts` was a budget for errors and not for crashes, so a task whose
-- worker dies every time was reaped and re-claimed without limit, with no
-- backoff, at claim speed. And it was INVISIBLE: every claim refreshes
-- heartbeat_at, so the one view whose job is to notice never saw it. A task
-- consuming a worker slot forever while every dashboard reads green is this
-- collection's defining failure shape, arriving through the function that
-- exists to prevent it.
--
-- The fix is to delete the second policy rather than repair it: the reaper now
-- calls `fail_task(id, …, false)`, which already owns the attempt budget, the
-- exponential backoff, the terminal transition, the run failure and saga
-- compensation. A dead worker is a failure like any other, and the only thing
-- the reaper decides is which tasks are dead. `fail_task` additionally clears
-- `claimed_by` on requeue, which it never did -- a `ready` task still naming a
-- worker is what 23a's fence would otherwise have read.
--
-- 23c. AND §21c HAD SURVIVED IN THE COPY NOBODY RAN.
--
-- `complete_task` was fixed to stamp `completed_at` with `clock_timestamp()`
-- because `now()` is the transaction timestamp, shared by every step finishing
-- in one transaction, and `completed_at` is the column `begin_compensation`
-- orders by. `complete_decision_task` still used `now()`, and
-- `promote_due_timers` set no `completed_at` at all -- a NULL, which sorts
-- first under `order by completed_at desc`. So a decision or a timer inside a
-- saga group compensated in forward order, which is the exact bug §21c
-- reports as fixed. Both now stamp `clock_timestamp()`.
--
-- This is the failure mode the consolidation pass was about, one function over
-- instead of one copy over: a fix that lands where somebody was looking and
-- not where the same code also lives. The defence is the same -- one
-- definition per function -- and it does not help across two functions that
-- merely ought to agree. `06-recovery.sql` asserts the agreement directly.
--
-- WHAT THIS DOES NOT CLOSE. The fence is strongest when a worker names itself,
-- and the shipped worker does not yet pass `p_worker_id` -- `get_task_context`
-- already hands it the `claimed_by` it should send back, so this is a
-- percolate-core change, not new information. Without it the revoked-lease and
-- terminal-state halves still hold (they need no identity), and only the
-- two-live-workers case in 23a degrades to first-writer-wins. The parameter
-- defaults to null for exactly that reason: this had to be deployable ahead of
-- the worker that uses it.
-- ------------------------------------------------------------
-- workflow.complete_task(uuid,jsonb,text), workflow.fail_task(uuid,jsonb,boolean,text),
-- workflow.heartbeat_task(uuid,text), workflow.lease_violation(uuid,text,text) and
-- workflow.reap_stale_tasks() are defined in sections 10, 13 and 14.
-- This section explains why they have the shape they do; the bodies are not
-- repeated, because two copies of a function is how a fix lands in only one of them.

-- ============================================================
-- 24. The descriptions a bound tool actually carries.
--
-- These COMMENTs are not documentation for humans reading psql. They are the
-- text a language model reads before deciding whether to call the function,
-- and they got written the moment this engine was first bound as a tool
-- server (`specs/agentic/reference/`).
--
-- The mechanism, confirmed against PostgREST 12.2 rather than assumed: a
-- COMMENT ON becomes the operation's OpenAPI documentation -- FIRST LINE into
-- `summary`, the remaining lines into `description`. `agentic`'s OpenAPI
-- adapter is required to carry no per-service knowledge (brief.md §5.2), so it
-- copies whatever is there and adds nothing. PostgREST emits no `operationId`
-- either, so a bound tool's name is mechanical (`post_rpc_start_workflow`) and
-- the comment is the ONLY thing distinguishing it from any other RPC.
--
-- Which makes the absence of a comment a real defect rather than an untidiness:
-- an uncommented function binds as a tool with a generated name, an argument
-- list, and no statement anywhere of what it does or when to use it. That is
-- what these functions did before this section existed. The first line is
-- therefore written as a summary -- one sentence, imperative, no leading
-- "This function" -- and the rest as the caller-facing contract, because that
-- is exactly how the two halves are split downstream.
--
-- Scope: the entry points an outside caller reaches, not the internals. A
-- comment on `resolve_args` would be documentation; a comment on
-- `start_workflow` is a tool description.
--
-- One of these -- `cancel_run` -- is redefined later, by
-- integration-rbac.sql, which loads after this file. The comment survives:
-- pg_description is keyed on the function's oid and CREATE OR REPLACE does
-- not change it (checked, rather than assumed). So the comments stay together
-- here, where they can be read as one set, instead of being scattered to
-- wherever each function's final definition happens to live.
-- ============================================================

comment on function workflow.start_workflow(text, jsonb, text, text) is
$c$Start a run of a workflow that has already been defined.
Takes the workflow NAME (not an id) and a JSON input object, and returns the
new run's id immediately -- it does not wait for the run to finish. Steps whose
kind is p8ql or sql execute inside Postgres as soon as they are ready; rest,
agent and work steps become queued tasks a worker picks up. Poll runs_api by
that id for status, or tasks_api by run_id for per-step detail.
p_external_id is an idempotency key: starting twice with the same one returns
the existing run rather than a second one.$c$;

comment on function workflow.define_yaml(text) is
$c$Define or re-version a workflow from a YAML document.
The document is a name plus a list of steps, each with an id, an optional
needs: list naming the steps it waits for, and exactly one action --
p8ql, sql, rest, agent, work, or a control form. Returns the new definition's
id. Defining a name that already exists creates a NEW VERSION rather than
overwriting: runs already in flight keep the version they started on.
This only defines; use start_workflow to run it.$c$;

comment on function workflow.schedule_workflow(text, text, text, jsonb, text, text) is
$c$Run a defined workflow repeatedly on a cron schedule.
p_name names the schedule, p_workflow names the workflow it starts. p_cron is
standard five-field cron, interpreted in p_timezone. p_overlap decides what
happens when a run is still going when the next tick arrives: skip (default),
queue, or allow. Creating a schedule does not start a run immediately.$c$;

comment on function workflow.cancel_run(uuid) is
$c$Cancel a run that is still in flight.
Stops any step that has not started and triggers saga compensation for the ones
that completed, in reverse order. A run that has already finished is left
alone -- cancelling it is a no-op, not an error.$c$;

-- The two *_api VIEWS are commented in integration-rbac.sql instead, beside
-- where they are created, and the asymmetry is the point. The paragraph above
-- holds for FUNCTIONS: cancel_run is redefined by that file and keeps its
-- comment, because pg_description is keyed on an oid CREATE OR REPLACE does
-- not change. A view that does not exist yet has no oid to key on, so the same
-- move fails outright -- `relation "workflow.runs_api" does not exist`, at
-- CREATE EXTENSION, on an empty database. Found by installing into one.

-- ============================================================
-- 25. workflow.lint_spec() -- refuse at authoring time what cannot work.
--
-- validate_spec (§1b) checks the GRAPH: steps exist, keys are unique,
-- dependencies resolve, nothing is unreachable. That is everything about the
-- shape of a workflow and nothing about its CONTENT, and the gap was measured
-- rather than guessed: every one of these was accepted by define_yaml --
--
--     p8ql: 'THIS IS NOT A QUERY AT ALL'          accepted, failed at run time
--     sql:  {function: no_such_function}          accepted, failed at run time
--     agent: there_is_no_such_agent               accepted, then queued FOREVER
--     '{{steps.NOSUCHSTEP.result}}'               accepted, resolves to null
--
-- The first two at least fail loudly on first execution. The third does not
-- fail at all: the task sits `ready` waiting for a runtime that will never
-- recognise it. The fourth is the worst -- an unresolvable reference becomes a
-- null argument, and a step that runs with null where it expected a value
-- reports success.
--
-- All four are decidable from the document plus the catalog, with no process
-- running and nothing executed. So they are decided here.
--
-- Severity, and why it is not all-or-nothing. A p8ql string is static text: it
-- can never become valid, so it is an `error`. An unregistered function or a
-- missing agent is a REFERENCE TO DATA that may legitimately arrive after the
-- workflow that names it -- authoring order is not deployment order -- so
-- those are `warning`s. Refusing them would make "define the workflow, then
-- register the function" impossible, which is a real and reasonable order.
-- ============================================================

create or replace function workflow.lint_spec(p_spec jsonb)
returns table(step_key text, severity text, detail text) as $$
declare
    v_step  jsonb;
    v_keys  text[];
    v_deps  text[];
    v_ref   text;
    v_head  text;
begin
    select array_agg(s->>'key') into v_keys
    from jsonb_array_elements(p_spec->'steps') s;

    for v_step in select * from jsonb_array_elements(p_spec->'steps') loop
        step_key := v_step->>'key';
        select coalesce(array_agg(d), '{}') into v_deps
        from jsonb_array_elements_text(coalesce(v_step->'depends_on','[]'::jsonb)) d;

        -- (a) p8ql that cannot parse.
        --
        -- Note the shape this reads, which is not the shape the AUTHOR wrote:
        -- a `p8ql:` step compiles to kind `sql` calling the allow-listed
        -- `p8ql` function with the query as its first argument. There is no
        -- `kind: p8ql` in a stored spec, and a lint written against the YAML's
        -- vocabulary silently matches nothing.
        if v_step->>'kind' = 'sql'
           and v_step->'input'->>'function' in ('p8ql', 'p8ql_vec')
           and to_regprocedure('aiq_parse(text)') is not null then
            declare v_p jsonb; v_q text;
            begin
                v_q := v_step->'input'->'args'->>0;
                -- A query that is itself a template resolves at dispatch and
                -- cannot be parsed now; skipped rather than guessed at.
                if v_q is not null and v_q !~ '\{\{' then
                    execute 'select aiq_parse($1)' into v_p using v_q;
                    if not coalesce((v_p->>'ok')::boolean, false) then
                        severity := 'error';
                        detail := 'p8ql does not parse: ' || coalesce(v_p->>'error','?');
                        return next;
                    end if;
                end if;
            exception when others then
                severity := 'warning';
                detail := 'p8ql could not be checked: ' || sqlerrm;
                return next;
            end;
        end if;

        -- (b) and (c) template references. Unknown step is an error; a known
        -- step that is not a DECLARED DEPENDENCY is also an error, and the
        -- sharper of the two: the reference resolves against run context, so
        -- reading a step you did not wait for returns null exactly when the
        -- race goes the wrong way -- intermittently, and as success.
        --
        -- Scanned over the step's whole JSON text rather than per field,
        -- because a reference can appear in an arg, a url, a header or three
        -- levels down a request body, and enumerating those places is a list
        -- that goes stale the next time a step kind is added.
        --
        -- KNOWN OVER-STRICT, and the note is here rather than in an issue
        -- because this is where someone will read the rule. The condition that
        -- makes a reference safe is that the step is a REACHABLE ANCESTOR --
        -- runs.context accumulates every completed step's output, so in
        -- a -> b -> c, `c` reading {{steps.a.result}} cannot race anything.
        -- This checks the DIRECT edge, which is merely the easiest case of it,
        -- so it refuses a correct diamond. Nobody has reported it because the
        -- workaround under explicit `needs:` is to name both (`needs: [a, b]`)
        -- and that reads fine. It stops being invisible the moment dependencies
        -- can come from document order: see YAML.md § Not built: `sequence:`.
        for v_ref in
            select m[1] from regexp_matches(v_step::text,
                '\{\{\s*steps\.([a-zA-Z0-9_-]+)', 'g') m
        loop
            if not (v_ref = any(v_keys)) then
                severity := 'error';
                detail := format('references {{steps.%s...}}, which is not a step '
                                 'in this workflow', v_ref);
                return next;
            elsif not (v_ref = any(v_deps)) then
                severity := 'error';
                detail := format('reads {{steps.%s...}} without depending on %L -- '
                                 'it resolves to null whenever this step runs first',
                                 v_ref, v_ref);
                return next;
            end if;
        end loop;

        -- (d) a sql step naming a function nobody registered. Warning, not
        -- error: authoring order is not deployment order, and defining a
        -- workflow before registering its function is a reasonable sequence.
        if v_step->>'kind' = 'sql'
           and not exists (select 1 from workflow.step_functions f
                            where f.name = v_step->'input'->>'function') then
            severity := 'warning';
            detail := format('sql step calls %L, which is not registered '
                             '(workflow.register_step_function)',
                             v_step->'input'->>'function');
            return next;
        end if;

        -- (e) an agent step naming an agent that is not a row -- the one whose
        -- run-time failure mode is SILENCE: the task queues `ready` and waits
        -- for a runtime that will never recognise the name.
        --
        -- Recognised by the url template, because that is all there is to
        -- recognise it by: `agent:` compiles to an ordinary http_call whose
        -- only remaining trace of having been an agent step is that it points
        -- at {{env.P8_AGENT_URL}}. Worth saying plainly -- the compiled form
        -- discards the authored intent, so anything downstream that wants to
        -- reason about agent steps is reading a convention, not a field.
        if v_step->>'kind' = 'http_call'
           and v_step->'input'->>'url' like '%P8_AGENT_URL%'
           and to_regclass('agentic.agents') is not null
           and not exists (select 1 from agentic.agents a
                            where a.name = v_step->'input'->'body'->>'model') then
            severity := 'warning';
            detail := format('agent step names %L, which is not in agentic.agents -- '
                             'this task will queue and wait rather than fail',
                             v_step->'input'->'body'->>'model');
            return next;
        end if;

        -- (f) an embed marker nothing expanded.
        --
        -- `embed:` compiles to an http_call with NO URL on purpose, and
        -- workflow.define_yaml fills it in from the model registry
        -- (aiq.expand_embed_steps). A spec can reach this table three ways --
        -- define_yaml, a migration, hand-written JSON -- and the other two skip
        -- the expander entirely, so without this the marker would be stored,
        -- dispatched, and handed to a worker as a request to POST nothing to
        -- nowhere. The message names the missing INTEGRATION rather than the
        -- missing key, because that is the actual condition on a database
        -- carrying the engine and not the query layer.
        -- Both places a marker can be. The template was missed at first, and
        -- the miss is instructive: the check was written against the step KIND
        -- it expected rather than against where the shape can occur, so a
        -- matrix fanning out an embed passed the lint, stored clean, and
        -- failed N times at dispatch.
        if (v_step->>'kind' = 'http_call'
            and v_step->'input' ? 'embed' and not (v_step->'input' ? 'url'))
        or (v_step->>'kind' = 'matrix'
            and v_step#>'{input,template,input}' ? 'embed'
            and not (v_step#>'{input,template,input}' ? 'url')) then
            severity := 'error';
            detail := 'this embed step was never expanded -- it has no url. '
                      'workflow.define_yaml fills one in from aiq.embedding_models; '
                      'a spec inserted as JSON, or one defined on a database without '
                      'ai-query-layer''s integration installed, does not get that.';
            return next;
        end if;

        -- (g) a vector query with no vector.
        --
        -- This rule has a prior instance in THIS FILE, which is the argument
        -- for it. §18's define_yaml comment has always illustrated authoring
        -- with `p8ql: 'SEARCH "safety recall" FROM chunks LIMIT 5'` -- a
        -- workflow that, until the compiler learned to emit the embed step,
        -- compiled clean and died at dispatch on `SEARCH ... needs
        -- p_embedding`. The function's own doc comment documented a workflow
        -- that could not run, and nothing in the collection could see it.
        --
        -- SEMANTIC and SEARCH rank against an embedding, so the one-argument
        -- p8ql registration cannot serve them: aiq.query raises at dispatch.
        -- Catching it here matters most when the two halves are out of step --
        -- a compiler predating the desugar emits exactly this shape from a
        -- document that is correct as written -- and the error then arrives at
        -- authoring time with the step key on it rather than mid-run.
        if v_step->>'kind' = 'sql'
           and v_step->'input'->>'function' = 'p8ql'
           and to_regprocedure('aiq_parse(text)') is not null then
            declare v_pv jsonb; v_qv text;
            begin
                v_qv := v_step->'input'->'args'->>0;
                if v_qv is not null then
                    execute 'select aiq_parse($1)' into v_pv using v_qv;
                    if coalesce((v_pv->>'ok')::boolean, false)
                       and v_pv->>'mode' in ('SEMANTIC','SEARCH') then
                        severity := 'error';
                        detail := format(
                            '%s ranks against an embedding and this step passes none. '
                            'Written as `p8ql:` it compiles to an embed step and this one; '
                            'a compiler that predates that emits what is here. Rebuild the '
                            'percolate extension, or write the embed step by hand and call '
                            'p8ql_vec.', v_pv->>'mode');
                        return next;
                    end if;
                end if;
            exception when others then
                null;   -- (a) already reports a query that cannot be checked
            end;
        end if;
    end loop;
end;
$$ language plpgsql stable;

comment on function workflow.lint_spec(jsonb) is
$c$Check a workflow spec's CONTENT, not just its graph shape.
Returns one row per problem: step_key, severity (error or warning) and detail.
validate_spec already refuses a bad graph; this catches a p8ql string that
cannot parse, a template reading a step it does not depend on, a sql step
naming an unregistered function, and an agent step naming an agent that does
not exist. Errors are refused by define_yaml; warnings are raised and the
definition stands, because a function or an agent may legitimately be
registered after the workflow that names it.$c$;


-- ============================================================
-- user-rbac/schema.sql
--   identity: users, roles, API keys, sessions, the role model
-- ============================================================

-- ============================================================
-- User management + RBAC — maximal Postgres pushdown v1.0
-- Philosophy: same as the workflow engine. Postgres is the
-- source of truth for identity, permissions, and sessions.
-- FastAPI is a thin proxy that mints/forwards JWTs and handles
-- the handful of things that structurally cannot live in SQL
-- (OAuth token exchange, email sending, TOTP).
-- ============================================================
--
-- Every SECURITY DEFINER function below sets `search_path = pg_catalog,
-- public` explicitly. This is standard PostgreSQL hardening (CVE-2018-1058
-- and the advisory it produced: https://wiki.postgresql.org/wiki/
-- A_Guide_to_CVE-2018-1058:_Protect_Your_Search_Path) for any SECURITY
-- DEFINER function that calls other objects by unqualified name -- without
-- it, a caller who can create an object earlier in their own session's
-- search_path (a schema they own, or in some configurations pg_temp) could
-- have a DEFINER function resolve to their malicious same-named function
-- instead of the real one, executing it with the DEFINER's privileges. One
-- specific reproduction attempt (a pg_temp function shadow against
-- grant_role's internal has_permission() call) did NOT succeed against this
-- schema's current grants (authenticated has neither CREATE on the database
-- nor on public). That's exactly the point: today's grants happening to block one
-- attempt is not a reason to skip a fix the authoritative guidance states
-- unconditionally, especially given this schema's own history of "safe by
-- accident of which grants don't exist yet" bugs (§9).
--
-- Schema namespacing (specs/README.md ground rule, executed here): every
-- table/function/view this module owns lives in the rbac schema, qualified
-- explicitly at every reference -- not just at each CREATE, and not via a
-- widened search_path either. `set search_path = pg_catalog, public` below
-- is deliberately left unchanged, not extended to include rbac: the whole
-- point of this file's existing hardening posture is never trusting implicit
-- resolution for a SECURITY DEFINER function, and adding a second schema to
-- the trusted list is exactly the kind of shortcut that posture argues
-- against, even when (as here) rbac isn't writable by an untrusted role.
-- Fully qualifying every internal reference costs nothing at runtime and
-- means this file's search_path story never needs re-reasoning about later.
-- The one cross-schema reference in this file (attempt_login()'s call into
-- workflow-engine's rate limiter) is explicitly `workflow.`-qualified for
-- the same reason. Permission-resource string literals like 'users' passed
-- to has_permission() (e.g. has_permission(uid, 'users', 'select')) are a
-- separate, deliberately un-namespaced vocabulary -- role_permissions.resource
-- tags, not object references -- and are untouched by this schema move.
-- ============================================================


-- create extension if not exists pgjwt;   -- optional: mint JWTs in SQL (see §7 callout)

create schema if not exists rbac;

-- ------------------------------------------------------------
-- 1. Users
-- ------------------------------------------------------------
create table rbac.users (
    id            uuid primary key default gen_random_uuid(),
    email         text not null unique,
    password_hash text,                 -- null for API-key-only / SSO-only accounts
    status        text not null default 'active'
                      check (status in ('active','disabled','pending_verification')),
    mfa_secret    text,                 -- TOTP secret, set only after MFA enrollment
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

-- Password verification pushed to pgcrypto -- no password ever leaves
-- Postgres in plaintext, and hashing cost (bcrypt work factor) is
-- tunable independent of the app layer.
--
-- SECURITY (fixed after empirical testing against a live PostgREST role
-- model): this and verify_password() are now internal-only -- EXECUTE is revoked from
-- PUBLIC in §9, so they're callable only from within another
-- SECURITY DEFINER function owned by the same role (create_user_with_password,
-- change_password, attempt_login below), never directly via PostgREST RPC.
-- Confirmed empirically: with no restriction, web_anon could call
-- set_password(any_user_id, ...) with zero auth check and silently succeeded
-- purely because table-level UPDATE happened not to be granted yet -- an
-- accident of grant ordering, not a real control. Never trust that again.
create or replace function rbac.set_password(p_user_id uuid, p_plain text)
returns void as $$
    update rbac.users
    set password_hash = crypt(p_plain, gen_salt('bf', 12)), updated_at = now()
    where id = p_user_id;
$$ language sql security definer set search_path = pg_catalog, public;

create or replace function rbac.verify_password(p_email text, p_plain text)
returns uuid as $$
    select id from rbac.users
    where email = p_email
      and status = 'active'
      and password_hash = crypt(p_plain, password_hash);
$$ language sql security definer set search_path = pg_catalog, public;
-- security definer: callable by an unprivileged 'api_user' role via
-- PostgREST RPC without granting that role SELECT on users.password_hash.
-- Confirmed empirically: with EXECUTE left at its Postgres default (granted
-- to PUBLIC), this is an unrate-limited password-guessing oracle for anyone
-- who calls it directly, bypassing attempt_login()'s rate limiter entirely --
-- EXECUTE must be revoked from PUBLIC (§9); only attempt_login() (also
-- security definer, same owner) may call it internally.

-- The only safe way to change a password: proves identity via the OLD
-- password (self-service) rather than trusting a caller-supplied user id.
-- Public entry point -- EXECUTE granted to `authenticated` in §9.
create or replace function rbac.change_password(p_old_plain text, p_new_plain text)
returns void as $$
declare
    v_email text;
begin
    select email into v_email from rbac.users where id = rbac.current_user_id();
    if v_email is null or rbac.verify_password(v_email, p_old_plain) is null then
        raise exception 'current password incorrect';
    end if;
    perform rbac.set_password(rbac.current_user_id(), p_new_plain);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Signup. The function spec.md's FastAPI example always assumed existed --
-- it didn't (empirically confirmed missing here); added to close that gap.
-- Public entry point -- EXECUTE granted to `web_anon` in §9 (signup is
-- inherently unauthenticated).
create or replace function rbac.create_user_with_password(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    insert into rbac.users (email, status) values (p_email, 'pending_verification')
    returning id into v_user_id;
    perform rbac.set_password(v_user_id, p_plain);
    return v_user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 2. RBAC — roles and permissions as data, uniform across every
--    module (users, workflow, resource search, agentic tools).
--    This is the same table any future module's RLS policies join to.
-- ------------------------------------------------------------
create table rbac.roles (
    name        text primary key,
    description text
);

create table rbac.user_roles (
    user_id uuid not null references rbac.users(id) on delete cascade,
    role    text not null references rbac.roles(name),
    primary key (user_id, role)
);

create table rbac.role_permissions (
    role     text not null references rbac.roles(name),
    resource text not null,     -- e.g. 'workflow_runs', 'tasks', 'users'
    action   text not null,     -- e.g. 'select', 'insert', 'cancel', 'admin'
    primary key (role, resource, action)
);

-- One function every module's RLS policy calls. Add a new module
-- (resource search, agentic tools) by inserting rows here, not by
-- writing new authz code.
--
-- SECURITY DEFINER, and this is load-bearing rather than incidental: without
-- it the function recurses until the backend blows its stack. The cycle is
-- two hops and neither hop looks wrong on its own --
--
--   any table's policy  ->  has_permission(uid, 'x', 'select')
--                       ->  select from rbac.user_roles      (as the CALLER)
--                       ->  user_roles_self_or_admin policy  (§9b, below)
--                       ->  has_permission(uid, 'user_roles', 'select')
--                       ->  select from rbac.user_roles  ->  ...
--
-- Postgres cannot see this as a policy cycle -- its own "infinite recursion
-- detected in policy for relation" check only catches a policy that names its
-- own table directly, and here the self-reference is laundered through a
-- function -- so the failure is `stack depth limit exceeded` from inside
-- has_permission, with nothing naming RLS at all.
--
-- Reproduced against the live PG19 beta3 stack via dev/tests/rbac/01: it needs
-- a caller who does NOT own the row being scanned AND does not hold the
-- permission, which is why the happy path hid it. A user reading their own
-- rows short-circuits on the first disjunct and never evaluates the second.
-- That is exactly the population RLS exists to constrain, so every consumer
-- table adopting the documented policy shape (§2's comment) was broken for
-- precisely the callers it was protecting against, and passing for everyone
-- else. It fails closed -- an error, not extra rows -- but it fails.
--
-- app_owner owns this function and owns user_roles/role_permissions, and a
-- table owner bypasses RLS by default (§9b's three facts, fact 1), so running
-- as the definer breaks the cycle at the first hop. `set search_path` is the
-- collection's unconditional rule for any SECURITY DEFINER function
-- (specs/README.md ground rules, CVE-2018-1058).
--
-- The tradeoff this accepts, stated rather than discovered: as a definer the
-- function answers for ANY p_user_id, so a caller holding a user's uuid can
-- learn whether that user has a given permission. It returns a boolean about
-- role grants and never a row, and the parameter is deliberately kept because
-- spec.md §11's per-resource-sharing work needs to ask the question about
-- somebody else. Narrowing it to self-or-admin belongs with that work, not
-- here, where it would be a second authorization rule invented in passing.
create or replace function rbac.has_permission(p_user_id uuid, p_resource text, p_action text)
returns boolean as $$
    select exists (
        select 1 from rbac.user_roles ur
        join rbac.role_permissions rp on rp.role = ur.role
        where ur.user_id = p_user_id
          and rp.resource = p_resource
          and rp.action = p_action
    );
$$ language sql stable security definer set search_path = pg_catalog, public;

-- Convenience: current user id from the JWT claims PostgREST already
-- exposes via current_setting -- use this directly inside RLS policies.
--
-- The nullif() guards the RAW SETTING, not the extracted 'sub' field: once a
-- pooled connection (PgBouncer/pgcat) has had request.jwt.claims SET LOCAL in
-- any prior transaction, an unregistered custom GUC resets to '' (not NULL)
-- after that transaction commits -- confirmed empirically against PG19 beta3.
-- Casting '' straight to
-- ::json throws before a nullif() applied only to ->>'sub' ever runs; guarding
-- the raw string first avoids that, and is what makes the very next anonymous
-- request on a reused pooled connection return zero rows instead of a 500.
create or replace function rbac.current_user_id() returns uuid as $$
    select (nullif(current_setting('request.jwt.claims', true), '')::json->>'sub')::uuid;
$$ language sql stable;

-- OTel ground rule (specs/README.md): the W3C trace_id for the request this
-- function call is happening inside, not a fresh disconnected one, whenever
-- the caller already has one. Reads request.trace_id, the same "GUC PostgREST
-- sets per-request" mechanism as current_user_id() above -- bridged from the
-- standard `traceparent` HTTP header via PostgREST's db-pre-request hook (a
-- function that runs before every request and can set session GUCs from
-- request.headers), not a new mechanism. Falls back to a fresh trace_id only
-- when the caller genuinely didn't propagate one -- an auth_events row should
-- never have a null trace_id, even for a client that doesn't participate in
-- tracing. Same empty-string-after-pooled-connection-commit guard as
-- current_user_id() -- see its comment above -- applies here too.
create or replace function rbac.current_trace_id() returns text as $$
    select coalesce(
        nullif(current_setting('request.trace_id', true), ''),
        encode(gen_random_bytes(16), 'hex')
    );
$$ language sql stable;

-- Example RLS policy shape any module adopts. current_user_id()/
-- has_permission() are called from OUTSIDE rbac here (any other schema's
-- own RLS policy) -- explicitly qualified, per this file's header note,
-- not left to a search_path that would have to include rbac to work:
-- create policy select_own_or_permitted on <table> for select
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), '<resource>', 'select'));

-- ------------------------------------------------------------
-- 3. Refresh tokens — JWTs are stateless and can't be revoked, so
--    the revocable long-lived credential lives here. Access JWTs
--    stay short-lived (minutes) and are minted per-request from a
--    valid refresh token.
-- ------------------------------------------------------------
create table rbac.refresh_tokens (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references rbac.users(id) on delete cascade,
    token_hash   text not null unique,     -- sha256 of the raw token; raw never stored
    device_label text,                     -- "Chrome on Mac", shown in session list
    issued_at    timestamptz not null default now(),
    expires_at   timestamptz not null,
    revoked_at   timestamptz,
    replaced_by  uuid references rbac.refresh_tokens(id)  -- rotation chain, for reuse detection
);
create index idx_refresh_tokens_user on rbac.refresh_tokens (user_id) where revoked_at is null;

-- Rotate: issue a new refresh token, revoke the old one, link the chain.
-- If a caller ever presents an already-revoked token whose replaced_by
-- chain is populated, that's a stolen/replayed token -- revoke the
-- entire chain (see refresh_session below).
-- SECURITY: internal only (EXECUTE revoked from PUBLIC in §9), never a
-- direct PostgREST RPC target. Confirmed empirically: if exposed, any
-- unauthenticated caller could mint a valid refresh token for an arbitrary
-- p_user_id with zero proof of identity -- a full account-takeover primitive,
-- not a theoretical one. Only login() below (security definer, same owner)
-- may call it, and only with the user_id ITS OWN password check just proved,
-- never a caller-supplied one.
create or replace function rbac.issue_refresh_token(p_user_id uuid, p_device_label text, p_raw_token text, p_ttl interval default interval '30 days')
returns uuid as $$
declare v_id uuid;
begin
    insert into rbac.refresh_tokens (user_id, token_hash, device_label, expires_at)
    values (p_user_id, encode(digest(p_raw_token, 'sha256'), 'hex'), p_device_label, now() + p_ttl)
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- security definer: self-authenticating via token possession, so safe as a
-- public entry point, but needs to INSERT/UPDATE refresh_tokens without
-- granting broad write access on that table to web_anon.
create or replace function rbac.refresh_session(p_raw_token text, p_new_raw_token text)
returns table(user_id uuid, new_refresh_token_id uuid) as $$
declare
    v_row rbac.refresh_tokens;
begin
    select * into v_row from rbac.refresh_tokens
    where token_hash = encode(digest(p_raw_token, 'sha256'), 'hex');

    if v_row.id is null then
        raise exception 'invalid refresh token';
    end if;

    if v_row.revoked_at is not null then
        -- reuse of a rotated-away token: possible theft. Revoke the
        -- whole chain forward from here as a precaution.
        update rbac.refresh_tokens set revoked_at = now()
        where user_id = v_row.user_id and revoked_at is null;
        raise exception 'refresh token reuse detected; all sessions revoked';
    end if;

    if v_row.expires_at < now() then
        raise exception 'refresh token expired';
    end if;

    return query
    with new_token as (
        insert into rbac.refresh_tokens (user_id, token_hash, device_label, expires_at)
        values (v_row.user_id, encode(digest(p_new_raw_token, 'sha256'), 'hex'),
                v_row.device_label, now() + interval '30 days')
        returning id
    ),
    revoke_old as (
        update rbac.refresh_tokens
        set revoked_at = now(), replaced_by = (select id from new_token)
        where id = v_row.id
    )
    select v_row.user_id, (select id from new_token);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- SECURITY: p_user_id used to be a caller-supplied parameter -- dropped.
-- Confirmed empirically (same class of bug as grant_role below): a
-- caller-supplied "whose session is this" argument is always spoofable via
-- PostgREST RPC, so any authenticated user could have revoked anyone else's
-- sessions by just passing their target's id. current_user_id() is the only
-- trustworthy source, since it's derived server-side from the verified JWT,
-- not client input. A user can only revoke their own sessions via these
-- public entry points; an admin-driven "revoke someone else's sessions"
-- would need its own has_permission()-gated function, not this one.
create or replace function rbac.revoke_session(p_refresh_token_id uuid)
returns void as $$
    update rbac.refresh_tokens set revoked_at = now()
    where id = p_refresh_token_id and user_id = rbac.current_user_id();
$$ language sql security definer set search_path = pg_catalog, public;

create or replace function rbac.revoke_all_sessions() returns void as $$
    update rbac.refresh_tokens set revoked_at = now()
    where user_id = rbac.current_user_id() and revoked_at is null;
$$ language sql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 4. API keys — for agents/service accounts that shouldn't hold a
--    user password/session. Scoped, revocable, no expiry by default
--    (agents are long-running), but revocation is immediate since
--    it's a DB row, not a stateless token.
-- ------------------------------------------------------------
create table rbac.api_keys (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid references rbac.users(id) on delete cascade,  -- null = service account
    label       text not null,
    key_hash    text not null unique,      -- sha256 of raw key; raw shown once at creation
    scopes      text[] not null default '{}',  -- e.g. {'workflow:trigger','workflow:read'}
    created_at  timestamptz not null default now(),
    last_used_at timestamptz,
    revoked_at  timestamptz
);

-- security definer: self-authenticating via key possession, so safe as a
-- public entry point, but needs to UPDATE last_used_at without granting
-- broad UPDATE on api_keys to web_anon.
create or replace function rbac.verify_api_key(p_raw_key text)
returns table(key_id uuid, user_id uuid, scopes text[]) as $$
    update rbac.api_keys
    set last_used_at = now()
    where key_hash = encode(digest(p_raw_key, 'sha256'), 'hex')
      and revoked_at is null
    returning id, user_id, scopes;
$$ language sql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 5. Login throttling — reuses the WORKFLOW ENGINE's rate limiter
--    (try_consume_rate_limit / rate_limits) rather than building a
--    second one. Same token-bucket, keyed by email or IP. Cross-schema
--    call, explicitly qualified (workflow.*, per this file's header note) --
--    requires workflow-engine's schema.sql to already be applied; this
--    module is not standalone-deployable without it (confirmed:
--    attempt_login() below fails outright with no fallback if
--    workflow.try_consume_rate_limit() is undefined). The bucket row
--    itself is seeded lazily inside attempt_login() on first use, not here.
-- ------------------------------------------------------------

-- security definer: needs to call verify_password() (now internal-only, §9)
-- and write auth_events without granting either directly to web_anon.
create or replace function rbac.attempt_login(p_email text, p_plain text)
returns uuid as $$
declare v_user_id uuid;
begin
    -- FIX (empirically confirmed broken): try_consume_rate_limit() does an
    -- UPDATE against an existing
    -- rate_limits row -- with none pre-seeded, the UPDATE matches zero rows,
    -- and it fails closed (returns false). With no bucket ever created for a
    -- new email, this meant NOBODY could ever log in, for any account --
    -- confirmed directly, not a hypothetical. Seed the bucket lazily on
    -- first use rather than requiring a bucket to already exist.
    insert into workflow.rate_limits (key, capacity, tokens, refill_rate)
    values ('login:' || lower(p_email), 5, 5, 0.0167)
    on conflict (key) do nothing;

    if not workflow.try_consume_rate_limit('login:' || lower(p_email)) then
        raise exception 'too many login attempts, try again shortly';
    end if;

    v_user_id := rbac.verify_password(p_email, p_plain);

    insert into rbac.auth_events (user_id, event_type, detail)
    values (v_user_id, case when v_user_id is null then 'login_failed' else 'login_success' end,
            jsonb_build_object('email', p_email));

    if v_user_id is null then
        raise exception 'invalid credentials';
    end if;
    return v_user_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The actual public login entry point: attempt_login() and
-- issue_refresh_token() combined atomically, so the token is always issued
-- for the SAME user_id attempt_login() just verified -- there is no code
-- path where a caller can supply a different one. Replaces the two separate
-- RPC calls spec.md's FastAPI example used to make (attempt_login then
-- issue_refresh_token), which only worked because issue_refresh_token() used
-- to accept a caller-supplied user_id directly -- exactly the bug this
-- section fixes.
create or replace function rbac.login(p_email text, p_plain text, p_device_label text, p_raw_token text)
returns table(user_id uuid, refresh_token_id uuid) as $$
declare
    v_user_id uuid;
    v_token_id uuid;
begin
    v_user_id := rbac.attempt_login(p_email, p_plain);
    v_token_id := rbac.issue_refresh_token(v_user_id, p_device_label, p_raw_token);
    return query select v_user_id, v_token_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6. Audit log — append-only, same shape as the workflow engine's
--    task_events. Every auth-relevant event, queryable, no separate
--    logging infra needed for this.
-- ------------------------------------------------------------
create table rbac.auth_events (
    id         bigint generated always as identity primary key,
    user_id    uuid,
    event_type text not null,   -- login_success, login_failed, password_changed,
                                 -- session_revoked, role_granted, role_revoked, api_key_created
    detail     jsonb,
    -- W3C Trace Context fields, specs/README.md's OTel ground rule -- current_trace_id()
    -- propagates the caller's own trace via request.trace_id when set, so a
    -- signup that triggers a send_verification_email workflow task shares one
    -- trace_id across auth_events and workflow-engine's task_events. span_id is
    -- this event's own span, generated fresh every row.
    trace_id   text not null default rbac.current_trace_id(),
    span_id    text not null default encode(gen_random_bytes(8), 'hex'),
    at         timestamptz not null default now()
);
create index idx_auth_events_user on rbac.auth_events (user_id, at);

-- SECURITY: this is the vulnerability that motivated this whole section --
-- confirmed empirically as a full, working privilege escalation, not a
-- theoretical one. p_actor_id
-- used to be a caller-supplied parameter: any authenticated non-admin user
-- could call grant_role(<a real admin's id>, <their own id>, 'admin') and the
-- has_permission() check would pass, because it was checking the ADMIN's
-- permissions, not the CALLER's -- there was nothing tying p_actor_id to who
-- was actually making the request. Once this function is security definer
-- (needed so it can write to user_roles without granting broad INSERT to
-- `authenticated`), that escalation fully succeeds end to end, confirmed by
-- reproducing it directly. current_user_id() is the only trustworthy actor.
create or replace function rbac.grant_role(p_target_user_id uuid, p_role text)
returns void as $$
begin
    if not rbac.has_permission(rbac.current_user_id(), 'users', 'admin') then
        raise exception 'not authorized to grant roles';
    end if;
    insert into rbac.user_roles (user_id, role) values (p_target_user_id, p_role)
    on conflict do nothing;
    insert into rbac.auth_events (user_id, event_type, detail)
    values (p_target_user_id, 'role_granted', jsonb_build_object('role', p_role, 'by', rbac.current_user_id()));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 7. OPTIONAL maximal-pushdown callout: mint JWTs in SQL via pgjwt,
--    so login() returns a ready-to-use access token directly.
--    Tradeoff: the signing secret lives in the DB (in a Postgres
--    setting or a small config table), which is one more place a
--    leak matters. Most teams should mint in FastAPI instead (see
--    spec) -- this is here because "maximal pushdown" was the ask.
-- ------------------------------------------------------------
-- create or replace function rbac.login_and_mint_jwt(p_email text, p_plain text)
-- returns text as $$
-- declare
--     v_user_id uuid;
--     v_role text;
-- begin
--     v_user_id := rbac.attempt_login(p_email, p_plain);
--     select role into v_role from rbac.user_roles where user_id = v_user_id limit 1;
--     return sign(
--         json_build_object(
--             'sub', v_user_id, 'role', coalesce(v_role, 'api_user'),
--             'exp', extract(epoch from now() + interval '5 minutes')::int
--         ),
--         current_setting('app.jwt_secret')
--     );
-- end;
-- $$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 8. Tie into the workflow engine: row-level ownership so a user
--    can only see/cancel their own runs unless permitted otherwise.
--    (Requires workflow-engine/schema.sql's workflow.runs table.)
-- ------------------------------------------------------------
-- alter table workflow.runs add column owner_id uuid references rbac.users(id);
--
-- alter table workflow.runs enable row level security;
-- create policy runs_owner_or_permitted on workflow.runs for select
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), 'workflow_runs', 'select'));
-- create policy runs_cancel on workflow.runs for update
--   using (owner_id = rbac.current_user_id() or rbac.has_permission(rbac.current_user_id(), 'workflow_runs', 'cancel'));

-- ------------------------------------------------------------
-- 9. PostgREST role model, grants, and RLS -- not previously written
--    down anywhere; added after empirically confirming its absence was
--    exploitable, not just incomplete. Two structural rules this section
--    enforces:
--      a) EVERY function meant to be a PostgREST RPC entry point is
--         SECURITY DEFINER (fixed above) AND has EXECUTE explicitly
--         granted -- Postgres's default (EXECUTE granted to PUBLIC on
--         every new function) is revoked wholesale first, so a new
--         function added later is unreachable via REST until someone
--         deliberately grants it. Deny-by-default, not allow-by-omission.
--      b) NO base table gets direct INSERT/UPDATE/DELETE from web_anon or
--         authenticated. All writes to auth-sensitive tables go through
--         the checked functions above; PostgREST's auto-CRUD only ever
--         needs to expose reads (via RLS + column grants) for this module.
-- ------------------------------------------------------------
-- ROLES ARE NOT CREATED HERE -- see roles.sql, applied once by a DBA/superuser
-- before this file. Roles are CLUSTER-level objects (shared by every database),
-- while everything else in this file is schema-level and owned by a
-- non-superuser schema owner. Those are two different privilege levels and two
-- different lifecycles, so they're two different files: a non-superuser schema
-- owner cannot CREATE ROLE (lacks CREATEROLE), which is not a limitation to
-- work around -- it's the correct boundary. Confirmed empirically: with role
-- creation inlined here, this file could only ever be loaded by a superuser,
-- which is exactly the thing the assertion below refuses to allow.
--
-- ASSERTION, not a comment: the "never let the schema owner be a cluster
-- superuser" rule stated in (b) below is CHECKED here, because a rule that
-- lives only in prose is a rule that gets violated silently. Confirmed the
-- hard way against a live PG19 beta3 stack: with a superuser schema/view
-- owner, a non-admin user reading through users_api saw EVERY row in the
-- table -- correct policies in place, and those same policies provably
-- working on a direct base-table read by the same role in the same session.
-- Superusers bypass RLS unconditionally, so an owner-privileged view owned by
-- one silently disables RLS for every caller of that view. The test harness
-- had been running as a superuser owner for this schema's entire history and
-- never caught it, because no test read through the views as a non-owner
-- until one was written specifically to.
--
-- This fails loudly at load time rather than deploying a schema whose central
-- security guarantee is silently inert.
do $$
begin
    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception
            'REFUSING TO LOAD: current_user (%) is a cluster superuser. '
            'Superusers bypass RLS unconditionally, so the owner-privileged '
            'views below (users_api, refresh_tokens_api, api_keys_api) would '
            'silently return ALL rows to every caller. Apply roles.sql first, '
            'then load this file as app_owner (psql -c ''set role app_owner;'' '
            '-f schema.sql).', current_user;
    end if;
end $$;

-- PostgREST needs USAGE on every schema it exposes -- rbac for this
-- module's own objects, public for anything not yet namespaced (and for
-- objects, like public.touch_updated_at, that are deliberately shared
-- rather than owned by one schema).
grant usage on schema rbac, public to web_anon, authenticated;

-- (a) Deny all function execution by default, then allow only the
-- functions actually meant to be public entry points. Scoped to rbac,
-- where this module's functions actually live now.
revoke execute on all functions in schema rbac from public;

grant execute on function rbac.create_user_with_password(text, text) to web_anon;
grant execute on function rbac.login(text, text, text, text) to web_anon;
grant execute on function rbac.refresh_session(text, text) to web_anon, authenticated;
grant execute on function rbac.verify_api_key(text) to web_anon, authenticated;
grant execute on function rbac.change_password(text, text) to authenticated;
grant execute on function rbac.grant_role(uuid, text) to authenticated;
grant execute on function rbac.revoke_session(uuid) to authenticated;
grant execute on function rbac.revoke_all_sessions() to authenticated;
-- has_permission()/current_user_id() are called FROM RLS policies, which
-- always run as the querying role -- both need direct EXECUTE too, not just
-- "called internally by a security definer function" (there is no
-- security-definer indirection when Postgres evaluates a USING clause).
-- Every OTHER schema's RLS policy calls these explicitly qualified
-- (rbac.current_user_id(), rbac.has_permission(...)) per this file's header
-- note, so this grant is what makes those cross-schema calls work, not a
-- widened search_path anywhere.
grant execute on function rbac.has_permission(uuid, text, text) to web_anon, authenticated;
grant execute on function rbac.current_user_id() to web_anon, authenticated;
-- set_password, verify_password, issue_refresh_token, attempt_login: stay
-- internal-only (owner-only EXECUTE), reachable only from within the
-- security-definer functions above that call them, never directly via RPC.

-- (b) RLS on every table this module owns -- deny-by-default the moment RLS
-- is enabled with no matching policy, which is exactly what anon/no-session
-- callers should get on tables this sensitive.
--
-- The three facts this section is built around, each confirmed empirically
-- against a live PG19 beta3 instance rather than reasoned about:
--   1. Table owners bypass their own RLS policies BY DEFAULT, independent of
--      superuser status.
--   2. Superusers bypass RLS unconditionally -- no flag changes that. Hence
--      the load-time assertion above: never let any of these roles be one.
--   3. users_api/refresh_tokens_api/api_keys_api are plain (owner-privileged)
--      views -- required, not incidental: a security_invoker view was tried
--      first and re-requires base-table grants, defeating the point. So every
--      read through them evaluates RLS as the VIEW OWNER, not the caller.
-- Together those mean the view owner's identity, not a policy flag, is what
-- decides whether the read path is safe. See the ENABLE-not-FORCE note below.
-- ENABLE, deliberately NOT FORCE. Getting this exactly right took three
-- rounds of live failure; the reasoning is worth keeping because both
-- obvious alternatives are wrong in ways that only show up in a correctly
-- configured deployment (a superuser-owned schema hides all of it):
--
--   * WITHOUT the split-owner design below, ENABLE alone is not enough: the
--     *_api views are owner-privileged, so a read through them evaluates RLS
--     as the VIEW's owner. If that owner also owns the tables, it bypasses
--     RLS and every caller sees every row. Reproduced directly.
--   * FORCE ROW LEVEL SECURITY is the tempting fix for that, and it IS
--     wrong here: FORCE also subjects the SECURITY DEFINER functions to RLS
--     (they run as the table owner), and with only SELECT policies in place
--     and no JWT during signup/login, every write is denied -- signup,
--     login's own auth_events insert, password changes, token issuance and
--     rotation, role grants. Also reproduced directly: `insert ...
--     returning id` failed even for the table owner, because RETURNING must
--     read the new row back through the SELECT policy.
--
-- The resolution is ownership separation, not a policy flag (roles.sql §1/§2):
--   - app_owner owns the TABLES + FUNCTIONS -> bypasses RLS (no FORCE) ->
--     the SECURITY DEFINER trusted path works, including reads during login
--     before a JWT exists.
--   - api_viewer owns ONLY THE VIEWS and is NOT the table owner -> RLS
--     applies to it normally -> the untrusted read path is filtered
--     per-request by current_user_id(), exactly as intended.
-- Both are non-superusers; §10's self-check verifies all of this at load time.
alter table rbac.users enable row level security;
alter table rbac.refresh_tokens enable row level security;
alter table rbac.api_keys enable row level security;
alter table rbac.auth_events enable row level security;
alter table rbac.user_roles enable row level security;

-- Every predicate below wraps current_user_id()/has_permission() in a scalar
-- subquery -- (select ...) -- rather than calling them bare. Both are STABLE
-- and none of their arguments depend on row data, so this looks purely
-- cosmetic, but it isn't: confirmed directly via EXPLAIN that the wrapped
-- form produces a separate InitPlan the row filter just references (evaluated
-- once), while the bare form inlines the full expression into the per-row
-- Filter with no InitPlan at all -- STABLE alone does not make the planner
-- hoist it. At the tiny scale tested this doesn't show up in the numbers,
-- but has_permission() itself runs a join against user_roles/role_permissions
-- -- at real table sizes the difference is a join-per-row-scanned versus a
-- join-once. This is a documented general Postgres RLS performance pattern,
-- not specific to this schema -- worth applying to every RLS policy written
-- for any future module, not just these five.
create policy users_self_or_admin on rbac.users for select
  using (id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'users', 'select')));
create policy refresh_tokens_self_or_admin on rbac.refresh_tokens for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'refresh_tokens', 'select')));
create policy api_keys_self_or_admin on rbac.api_keys for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'api_keys', 'select')));
create policy auth_events_self_or_admin on rbac.auth_events for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'auth_events', 'select')));
create policy user_roles_self_or_admin on rbac.user_roles for select
  using (user_id = (select rbac.current_user_id()) or (select rbac.has_permission(rbac.current_user_id(), 'user_roles', 'select')));

-- Read paths for users/refresh_tokens/api_keys are VIEWS, not column-level
-- grants on the base table -- confirmed empirically that a partial
-- column-level GRANT does NOT do what it looks like it does here: PostgREST's `GET
-- /users` issues the equivalent of `SELECT *`, and Postgres fails that
-- *entire* query with "permission denied for table users" the moment it
-- references even one ungranted column -- it does not silently drop
-- password_hash/mfa_secret and return the rest. A view whose SELECT list
-- simply never mentions the secret columns has no such failure mode: there
-- is no ungranted column for `SELECT *` (against the view) to reference.
-- RLS on the base table still applies through the view -- confirmed
-- directly -- since current_user_id() reads session state, not anything
-- owner/view-dependent. Deliberately the Postgres DEFAULT view behavior
-- (security_invoker = false / omitted), not the PG15+ security_invoker
-- option -- confirmed empirically that security_invoker actively breaks
-- this pattern: it makes the QUERYING role's own privileges on the base
-- table get re-checked, which defeats the entire point (the view exists so
-- `authenticated` never needs a base-table grant at all). The default,
-- owner-privileged view is what makes "grant SELECT on the view only" work:
-- object-level column access is checked against the view's OWNER, while
-- RLS row-filtering still uses the querying role, because current_user_id()
-- reads session state regardless of whose privileges are active for the
-- column check.
create view rbac.users_api as
  select id, email, status, created_at, updated_at from rbac.users;
create view rbac.refresh_tokens_api as
  select id, user_id, device_label, issued_at, expires_at, revoked_at from rbac.refresh_tokens;
create view rbac.api_keys_api as
  select id, user_id, label, scopes, created_at, last_used_at, revoked_at from rbac.api_keys;

-- Hand the views to api_viewer -- the step that makes RLS actually enforce on
-- the read path (roles.sql §2, and the ENABLE-not-FORCE reasoning above).
-- A view owned by the TABLE owner would bypass RLS and leak every row; owned
-- by this separate non-owner role, the same view is filtered per-request.
-- api_viewer needs its own SELECT on the base tables (it is not the owner) and
-- EXECUTE on the two functions the policies call -- policies are evaluated as
-- the view owner, so the view owner is who must be able to run them.
-- Grants BEFORE the ownership transfer, not after: Postgres re-validates the
-- view against its new owner's privileges at ALTER time, so a view handed to
-- a role that cannot yet read the underlying tables fails with "permission
-- denied for schema rbac".
grant usage on schema rbac to api_viewer;
grant select on rbac.users, rbac.refresh_tokens, rbac.api_keys to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;
grant execute on function rbac.has_permission(uuid, text, text) to api_viewer;
-- has_permission() joins these two, so the view owner must be able to read
-- them for the policy predicate to evaluate at all.
grant select on rbac.user_roles, rbac.role_permissions to api_viewer;

-- Postgres additionally requires the INCOMING owner to hold CREATE on the
-- schema at the moment of an ownership transfer. Granted narrowly for the
-- transfer and revoked immediately after: api_viewer's whole purpose is to be
-- a low-privilege identity that RLS applies to, so leaving it able to create
-- objects in this schema would undercut the point of splitting it out.
grant create on schema rbac to api_viewer;

alter view rbac.users_api owner to api_viewer;
alter view rbac.refresh_tokens_api owner to api_viewer;
alter view rbac.api_keys_api owner to api_viewer;

revoke create on schema rbac from api_viewer;

grant select on rbac.users_api to authenticated;
grant select on rbac.refresh_tokens_api to authenticated;
grant select on rbac.api_keys_api to authenticated;
-- No grant on the base tables themselves to web_anon or authenticated --
-- PostgREST should be pointed at users_api/refresh_tokens_api/api_keys_api,
-- never at users/refresh_tokens/api_keys directly, for reads. Writes to all
-- three go exclusively through the functions in (a), not REST table writes,
-- so no base-table INSERT/UPDATE/DELETE grant exists at all.

grant select on rbac.auth_events to authenticated;
grant select on rbac.user_roles to authenticated;
-- roles, role_permissions: reference/catalog data, not per-row sensitive --
-- plain table grants, no RLS needed.
grant select on rbac.roles, rbac.role_permissions to authenticated;

-- web_anon gets no table access at all -- every unauthenticated interaction
-- this module supports (signup, login, refresh, API-key auth) is a function
-- call, not a table read, so it never needed one.

-- ------------------------------------------------------------
-- 10. Self-check. Rule (b) and the write-policy scoping above are only
--     defense-in-depth if BOTH layers actually hold, so verify rather than
--     assert in prose -- this file's whole history is gaps that looked fine
--     until something read the catalog instead of the comments.
-- ------------------------------------------------------------
do $$
declare
    v_bad text;
begin
    -- (b): no write grant on any base table for the PostgREST-facing roles.
    select string_agg(format('%s.%s -> %s on %s',
                             table_schema, table_name, privilege_type, grantee), ', ')
    into v_bad
    from information_schema.role_table_grants
    where table_schema = 'rbac'
      and grantee in ('web_anon', 'authenticated')
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
      and table_name in ('users','refresh_tokens','api_keys','auth_events',
                         'user_roles','roles','role_permissions');
    if v_bad is not null then
        raise exception
            'RULE (b) VIOLATED: base-table write grants exist for PostgREST roles: %. '
            'All writes must go through the SECURITY DEFINER functions in (a).', v_bad;
    end if;

    -- The owner must still be non-superuser at this point (a superuser owner
    -- silently disables RLS everywhere). Belt and braces with the assertion at
    -- the top of §9 -- cheap, and catches a SET ROLE mid-file.
    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception 'schema owner (%) is a superuser -- every RLS guarantee here is inert', current_user;
    end if;

    -- THE central invariant of this module's read path: each *_api view must
    -- be owned by a NON-SUPERUSER role that is NOT the base table's owner.
    -- Same owner -> the view bypasses RLS and returns every row to every
    -- caller (reproduced directly). Superuser -> same outcome, unconditionally.
    -- Checked from the catalog rather than trusted from the ALTER VIEW
    -- statements above, so a later edit that adds a view and forgets to
    -- reassign it fails at load time instead of leaking silently in production.
    select string_agg(format('%s (view owner %s, table owner %s)',
                             v.relname,
                             pg_get_userbyid(v.relowner),
                             pg_get_userbyid(t.relowner)), ', ')
    into v_bad
    from pg_class v
    join pg_namespace n on n.oid = v.relnamespace
    join pg_class t on t.relname = replace(v.relname, '_api', '')
                   and t.relnamespace = v.relnamespace and t.relkind = 'r'
    where n.nspname = 'rbac' and v.relkind = 'v' and v.relname like '%\_api'
      and (v.relowner = t.relowner
           or (select rolsuper from pg_roles where oid = v.relowner));
    if v_bad is not null then
        raise exception
            'VIEW OWNERSHIP INVARIANT VIOLATED: %. Each *_api view must be owned '
            'by a non-superuser role distinct from the base table owner, or RLS '
            'is bypassed on every read through it (roles.sql §2).', v_bad;
    end if;

    raise notice 'user-rbac self-check passed: no base-table write grants; non-superuser owner (%); api views owned by a separate non-superuser role', current_user;
end $$;


-- ============================================================
-- workflow-engine/integration-rbac.sql
--   ownership and authorization on run-scoped entry points
-- ============================================================

-- ============================================================
-- workflow-engine <-> user-rbac integration.
--
-- Applied AFTER both schema.sql files, as app_owner. Split out for a reason
-- that only became visible when the two were prototyped together: the two
-- schemas are MUTUALLY dependent, so neither can fully load second.
--
--   rbac.attempt_login()  ->  workflow.rate_limits, workflow.try_consume_rate_limit()
--   workflow.runs.owner_id -> rbac.users
--   workflow.runs RLS      -> rbac.current_user_id(), rbac.has_permission()
--
-- That is a genuine cycle, not an ordering mistake, and it is resolved the
-- way cycles usually should be: the acyclic cores load in either order, and
-- everything that crosses the boundary lives here, in one file, applied last.
-- Keeping it separate also keeps workflow-engine/schema.sql honest -- that
-- file alone is a complete, deployable engine with no identity system at all,
-- which is what lets it be reused by a deployment that has its own.
--
-- Load order:
--   1. user-rbac/roles.sql              (superuser)
--   2. workflow-engine/schema.sql       (app_owner)
--   3. user-rbac/schema.sql             (app_owner)
--   4. THIS FILE                        (app_owner)
-- ============================================================

-- (c) Ownership + RLS on the READ path, which is what user-rbac §6 and
-- spec.md §13 actually meant. owner_id is nullable on purpose: a run started
-- by the system (a scheduled poll, a consolidation run) has no human owner,
-- and must not be forced to invent one.
alter table workflow.runs add column if not exists owner_id uuid references rbac.users(id);
create index if not exists idx_runs_owner on workflow.runs (owner_id);

alter table workflow.runs enable row level security;
alter table workflow.tasks enable row level security;

-- Same (select ...) InitPlan wrapping as user-rbac/schema.sql's policies --
-- has_permission() runs a join, so bare calls re-evaluate it per row scanned.
create policy runs_owner_or_permitted on workflow.runs for select
  using (owner_id = (select rbac.current_user_id())
         or (select rbac.has_permission(rbac.current_user_id(), 'workflow_runs', 'select')));

-- Tasks inherit their run's visibility rather than restating the rule -- one
-- place to change it, and a task has no owner of its own.
create policy tasks_via_run on workflow.tasks for select
  using (exists (select 1 from workflow.runs r where r.id = workflow.tasks.run_id));

-- Reads go through views owned by api_viewer, NOT the table owner -- the
-- ownership split user-rbac/roles.sql §2 exists for. A view owned by the
-- table owner bypasses RLS and returns every row to every caller.
create view workflow.runs_api as
  select id, workflow_def_id, owner_id, status, compensation_state,
         external_id, input, context, trace_id, created_at, updated_at, completed_at
  from workflow.runs;
create view workflow.tasks_api as
  select id, run_id, step_key, kind, queue, status, attempts, max_attempts,
         priority, run_after, output, error, span_id, parent_span_id,
         created_at, updated_at, completed_at
  from workflow.tasks;

grant usage on schema workflow to api_viewer;
grant select on workflow.runs, workflow.tasks to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;
grant execute on function rbac.has_permission(uuid, text, text) to api_viewer;

grant create on schema workflow to api_viewer;
alter view workflow.runs_api owner to api_viewer;
alter view workflow.tasks_api owner to api_viewer;
revoke create on schema workflow from api_viewer;

grant select on workflow.runs_api, workflow.tasks_api to authenticated;

-- No base-table grant to authenticated at all: reads are the views, writes
-- are the functions in (b). Same shape as user-rbac.

-- Tool descriptions for the two read views, here rather than with the rest of
-- the set in schema.sql §24: this is the first point at which these views
-- exist. See that section for why the function comments do not have to move.
comment on view workflow.runs_api is
$c$One row per workflow run, filtered to the runs you may see.
status is pending, running, completed, failed or cancelled. Filter it the
PostgREST way -- ?status=eq.running, ?id=eq.<uuid>, ?order=created_at.desc --
and use ?select= to narrow the columns. This is the read side of
start_workflow: check a run here by the id that returned.$c$;

comment on view workflow.tasks_api is
$c$One row per step of a workflow run -- the per-step detail behind a run's status.
Filter by ?run_id=eq.<uuid> to see how a single run is progressing. status
distinguishes ready, running, completed and failed; attempts against
max_attempts shows what has been retried, and error carries why the last
attempt failed.$c$;

-- (d) Self-check, mirroring user-rbac/schema.sql §10 -- the invariants that
-- silently degrade rather than fail loudly are the ones worth verifying.
do $$
declare
    v_bad text;
begin
    -- Every function that writes state must be SECURITY DEFINER, or a worker's
    -- write becomes a silent no-op under the RLS above (see this section's
    -- header). This is the check that would have caught the data-loss bug.
    select string_agg(p.proname, ', ')
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'workflow'
      and p.proname in ('claim_task','claim_tasks','claim_task_rate_limited',
                        'heartbeat_task','complete_task','fail_task',
                        'complete_decision_task','signal_task','start_workflow',
                        'start_child_workflow','add_task','cancel_run',
                        'begin_compensation','promote_due_timers',
                        'reap_stale_tasks','log_task_transition',
                        'cascade_task_status',
                        -- §19: the ticker and the schedule REST surface
                        'tick','schedule_workflow','set_schedule_enabled',
                        'unschedule_workflow')
      and not p.prosecdef;
    if v_bad is not null then
        raise exception
            'STATE-MUTATING FUNCTIONS ARE NOT SECURITY DEFINER: %. Under the RLS '
            'policies in this section, a worker (no JWT) matches no rows, and an '
            'UPDATE matching zero rows is NOT an error -- step outputs would be '
            'silently discarded while runs report success.', v_bad;
    end if;

    -- Same view-ownership invariant as user-rbac/schema.sql §10.
    select string_agg(v.relname, ', ')
    into v_bad
    from pg_class v
    join pg_namespace n on n.oid = v.relnamespace
    join pg_class t on t.relnamespace = v.relnamespace and t.relkind = 'r'
                   and t.relname = replace(v.relname, '_api', '')
    where n.nspname = 'workflow' and v.relkind = 'v' and v.relname like '%\_api'
      and (v.relowner = t.relowner
           or (select rolsuper from pg_roles where oid = v.relowner));
    if v_bad is not null then
        raise exception
            'VIEW OWNERSHIP INVARIANT VIOLATED: %. Each *_api view must be owned by '
            'a non-superuser role distinct from the base table owner, or RLS is '
            'bypassed on every read through it.', v_bad;
    end if;

    raise notice 'workflow-engine self-check passed: state mutators are SECURITY DEFINER; api views separately owned';
end $$;

-- ============================================================
-- (e) Ownership assignment, and authorization on the user-facing entry
--     points. Both belong here rather than in schema.sql because both need
--     rbac.current_user_id(), and the core engine is deliberately identity-free.
-- ============================================================

-- Runs get their owner from the verified JWT, never from a caller-supplied
-- argument (the lesson rbac.grant_role() and rbac.issue_refresh_token() both
-- taught: a caller-supplied "whose is this" parameter is always spoofable
-- through PostgREST). A trigger rather than a modified start_workflow(), so
-- start_child_workflow() and any future insert path get it for free, and so
-- the core function keeps no rbac dependency.
--
-- Found by running it: start_workflow() set no owner at all, so every run
-- created through the RPC was ownerless -- and therefore invisible to the
-- person who started it, since the RLS policy above matches on owner_id. The
-- ownership model three spec sections describe was unusable end to end.
-- Null stays null for system-initiated runs (a scheduled poll, a
-- consolidation run) -- those have no human owner and must not invent one.
create or replace function workflow.set_run_owner() returns trigger as $$
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create trigger trg_set_run_owner
    before insert on workflow.runs
    for each row execute function workflow.set_run_owner();

-- Authorization on the two run-scoped user entry points.
--
-- CONFIRMED EXPLOITABLE before this was added, and worth being precise about
-- why: making these SECURITY DEFINER in schema.sql §16 (necessary, so workers
-- and owners can act on runs without base-table grants) means they no longer
-- get RLS as an accidental backstop. A non-owner with no permissions
-- cancelled another user's running workflow end to end -- reproduced
-- directly. This is the same shape as the grant_role privilege escalation
-- found in user-rbac: a SECURITY DEFINER function that acts on a
-- caller-supplied id without checking the caller's authority over it.
--
-- The rule this makes explicit, for any future function in this collection:
-- SECURITY DEFINER deliberately bypasses RLS, so every SECURITY DEFINER
-- function reachable by an end user MUST do its own authorization check.
-- Worker-facing functions (claim/complete/fail/heartbeat) are exempt because
-- EXECUTE on them is granted only to `worker`, which is infrastructure, not
-- a user identity -- their authorization IS the grant.
create or replace function workflow.assert_run_access(p_run_id uuid, p_action text)
returns void as $$
declare v_owner uuid;
begin
    select owner_id into v_owner from workflow.runs where id = p_run_id;
    if not found then
        raise exception 'run % not found', p_run_id;
    end if;
    -- A system-owned run (owner_id null) is not "owned by everyone": it takes
    -- an explicit permission, never bare ownership, to act on.
    if v_owner is not null and v_owner = rbac.current_user_id() then
        return;
    end if;
    if rbac.has_permission(rbac.current_user_id(), 'workflow_runs', p_action) then
        return;
    end if;
    raise exception 'not authorized to % run %', p_action, p_run_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.cancel_run(p_run_id uuid) returns void as $$
declare v_child uuid;
begin
    perform workflow.assert_run_access(p_run_id, 'cancel');

    update workflow.runs set status = 'cancelled', cancel_requested = true
    where id = p_run_id and status = 'running';

    update workflow.tasks set cancel_requested = true
    where run_id = p_run_id and status = 'running';

    update workflow.tasks set status = 'cancelled'
    where run_id = p_run_id and status in ('pending', 'ready', 'waiting_external');

    -- Child runs are cancelled by the same authority as their parent, not
    -- re-checked against the caller: a child run is frequently system-owned
    -- (no owner_id), and re-running the check would fail on exactly the runs
    -- a legitimate parent cancellation most needs to reach. The parent check
    -- above is the authorization boundary for the whole tree.
    for v_child in select child_run_id from workflow.tasks
                   where run_id = p_run_id and child_run_id is not null
    loop
        perform workflow.cancel_run_unchecked(v_child);
    end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The recursive/internal form: no authorization, never granted to any user
-- role, reachable only from cancel_run() above (same owner) and from the
-- engine itself. Split out rather than adding a "skip the check" boolean
-- parameter, because a caller-supplied flag that disables authorization is
-- precisely the pattern this collection keeps finding to be exploitable.
create or replace function workflow.cancel_run_unchecked(p_run_id uuid) returns void as $$
declare v_child uuid;
begin
    update workflow.runs set status = 'cancelled', cancel_requested = true
    where id = p_run_id and status = 'running';
    update workflow.tasks set cancel_requested = true
    where run_id = p_run_id and status = 'running';
    update workflow.tasks set status = 'cancelled'
    where run_id = p_run_id and status in ('pending', 'ready', 'waiting_external');
    for v_child in select child_run_id from workflow.tasks
                   where run_id = p_run_id and child_run_id is not null
    loop
        perform workflow.cancel_run_unchecked(v_child);
    end loop;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.signal_task(p_run_id uuid, p_signal text, p_payload jsonb)
returns void as $$
begin
    -- Was equally open, and only *appeared* safe when tested because
    -- wait_signal was never populated (schema.sql's start_workflow bug, fixed
    -- there) -- so the UPDATE matched nothing regardless of who called it. A
    -- security property that holds only because a different feature is broken
    -- is not a security property.
    perform workflow.assert_run_access(p_run_id, 'signal');

    -- completed_at is stamped for the §21c reason, and this is the definition
    -- that actually runs: schema.sql defines signal_task too and this file
    -- REPLACES it to add the authorization check, so the base body is dead in
    -- any deployment that loads both -- which is every deployment, since both
    -- files are in build-sql.py's ORDER. The fix was first applied to the
    -- superseded copy and had no effect; dev/currency.sh is what noticed.
    update workflow.tasks
    set status = 'done', output = p_payload, completed_at = clock_timestamp()
    where run_id = p_run_id and wait_signal = p_signal and status = 'waiting_external';
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- schema.sql §20's matrix_rows() reads the recorded row set of a fan-out --
-- a run's input data, one row per child. It is SECURITY DEFINER (it reads
-- workflow.tasks, which no user role can touch directly) and it is granted to
-- `authenticated`, which by this section's own rule means it MUST check the
-- caller's authority over the run rather than trusting the task id it was
-- handed. Without this, any authenticated user who could guess or observe a
-- task id would read another tenant's watchlist, AOI grid or sponsor set.
--
-- Redefined here rather than checked in schema.sql for the same reason
-- cancel_run is: rbac.current_user_id() does not exist until user-rbac loads,
-- and the engine must install standalone.
create or replace function workflow.matrix_rows(p_task_id uuid)
returns jsonb as $$
declare v_run uuid;
begin
    select run_id into v_run from workflow.tasks where id = p_task_id;
    if not found then
        raise exception 'task % not found', p_task_id;
    end if;
    perform workflow.assert_run_access(v_run, 'read');

    return (select coalesce(jsonb_agg(t.input->'item' order by t.created_at, t.step_key),
                            '[]'::jsonb)
            from workflow.tasks t where t.matrix_parent_id = p_task_id);
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

grant execute on function workflow.matrix_rows(uuid) to worker, authenticated;

-- matrix_outputs returns the children's OUTPUTS -- the fetched documents, the
-- model verdicts, whatever the fan-out produced -- so it needs the same check.
-- It has TWO legitimate callers with different authorities, which is why this
-- override reads the way it does:
--
--   * The ENGINE, running a fan-in step. No JWT, no user identity, and the
--     authority is "this task belongs to the run I am executing" --
--     schema.sql §20 checks that against a transaction-local run id, and it is
--     what stops a workflow author naming another tenant's matrix task.
--   * A USER or API client calling it directly. Real identity, and the
--     ordinary ownership check applies.
--
-- Either is sufficient; neither alone covers both callers. Getting this wrong
-- in the obvious direction -- only the user check -- was reproduced: the
-- fan-in failed with `not authorized to read run ...` on a run it had itself
-- created.
create or replace function workflow.matrix_outputs(p_task_id uuid)
returns jsonb as $$
declare v_run uuid; v_cur text;
begin
    select run_id into v_run from workflow.tasks where id = p_task_id;
    if not found then
        raise exception 'task % not found', p_task_id;
    end if;

    v_cur := nullif(current_setting('workflow.current_run_id', true), '');
    if v_cur is null or v_cur::uuid <> v_run then
        perform workflow.assert_run_access(v_run, 'read');
    end if;

    return (select coalesce(jsonb_agg(jsonb_build_object(
                'step_key', t.step_key, 'item', t.input->'item',
                'status', t.status, 'output', t.output)
            order by t.created_at, t.step_key), '[]'::jsonb)
            from workflow.tasks t where t.matrix_parent_id = p_task_id);
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

grant execute on function workflow.matrix_outputs(uuid) to worker, authenticated;

revoke execute on function workflow.cancel_run_unchecked(uuid) from public;
revoke execute on function workflow.assert_run_access(uuid, text) from public;
grant execute on function workflow.cancel_run(uuid) to authenticated;
grant execute on function workflow.signal_task(uuid, text, jsonb) to authenticated;

-- ============================================================
-- (f) Schedules (schema.sql §19) under the identity model.
--
-- Same three pieces every user-facing table in this collection gets, for the
-- same reasons: an owner assigned from the verified JWT by a trigger, an RLS
-- policy on the read path, and a real authorization check replacing the
-- deny-by-default stand-in the core engine ships.
-- ============================================================

alter table workflow.schedules add column if not exists owner_id uuid references rbac.users(id);
create index if not exists idx_schedules_owner on workflow.schedules (owner_id);

-- Ownership from the JWT, never from an argument -- the same rule, and the
-- same trigger shape, as runs above. schedule_workflow() therefore has no
-- owner parameter to spoof.
create or replace function workflow.set_schedule_owner() returns trigger as $$
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create trigger trg_set_schedule_owner
    before insert on workflow.schedules
    for each row execute function workflow.set_schedule_owner();

alter table workflow.schedules enable row level security;

-- (select ...) wrapping, as everywhere: has_permission() runs a join.
create policy schedules_owner_or_permitted on workflow.schedules for select
  using (owner_id = (select rbac.current_user_id())
         or (select rbac.has_permission(rbac.current_user_id(), 'workflow_schedules', 'select')));

-- The real check, replacing schema.sql §19's deny-by-default stand-in.
-- Mirrors assert_run_access() exactly, including its rule about system-owned
-- rows: a schedule with no owner (seeded by the deployment itself) takes an
-- explicit permission to touch, never bare ownership.
--
-- Creating a NEW schedule is the one action with no existing row to own, so
-- it is allowed to any authenticated caller -- the trigger above then makes
-- them its owner. An anonymous caller has no identity to own it and is
-- refused, which is what keeps `web_anon` out.
create or replace function workflow.assert_schedule_access(p_name text, p_action text)
returns void as $$
declare
    v_owner  uuid;
    v_exists boolean;
    v_caller uuid := rbac.current_user_id();
    v_tbl_owner name;
begin
    -- The deployment itself, seeding or repairing its own schedules, has no
    -- JWT and no rbac.users row -- and must not need one. A caller connected
    -- as (or able to become) the role that owns the table is that case, and
    -- is the same escape the core engine's stand-in uses. PostgREST connects
    -- as `authenticator`, which is deliberately NOT a member of it, so this
    -- never widens the REST path.
    select pg_get_userbyid(c.relowner) into v_tbl_owner
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'workflow' and c.relname = 'schedules';
    if pg_has_role(session_user, v_tbl_owner, 'member') then
        return;
    end if;

    select owner_id, true into v_owner, v_exists
      from workflow.schedules where name = p_name;

    if not coalesce(v_exists, false) then
        if p_action = 'create' and v_caller is not null then
            return;
        end if;
        if p_action <> 'create' then
            -- Nothing to authorize against; the caller's own function decides
            -- what a missing name means (unschedule_workflow returns false).
            return;
        end if;
        raise exception 'not authorized to create schedule "%"', p_name
            using hint = 'authenticate first: a schedule needs an owner';
    end if;

    if v_owner is not null and v_owner = v_caller then
        return;
    end if;
    if rbac.has_permission(v_caller, 'workflow_schedules', p_action) then
        return;
    end if;
    raise exception 'not authorized to % schedule "%"', p_action, p_name;
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- The read path: a view owned by api_viewer, never the table owner.
create view workflow.schedules_api as
  select id, name, workflow_name, cron_expr, timezone, input, enabled,
         overlap_policy, owner_id, org_id, last_tick_at, last_fired_at,
         last_run_id, fire_count, skip_count, last_error, last_error_at,
         created_at, updated_at
  from workflow.schedules;

grant select on workflow.schedules to api_viewer;
grant create on schema workflow to api_viewer;
alter view workflow.schedules_api owner to api_viewer;
revoke create on schema workflow from api_viewer;
grant select on workflow.schedules_api to authenticated;


-- ============================================================
-- ai-query-layer/schema.sql
--   nodes, keys, edges, the seven query modes, embedding spaces
-- ============================================================

-- ============================================================
-- AI Query Layer — schema v0.1
--
-- Implements graph-identity.md: a write-time node registry (identity), a
-- key index (lookup, exact/short/fuzzy), and an authored edge table (soft
-- links), kept strictly separate from each consumer's own typed tables
-- (attributes) and from hard FK relationships (which stay relational and are
-- never copied into edges).
--
-- Applied as app_owner, after workflow-engine and user-rbac. Depends on rbac
-- only for RLS predicates (org scoping), same boundary discipline as
-- workflow-engine/integration-rbac.sql.
--
-- The five REM-derived query modes (brief.md §2, §3) compile to:
--   LOOKUP           -> node_keys btree probe -> nodes -> typed-table PK fetch
--                       (takes a LIST of keys; each resolves independently)
--   FUZZY LOOKUP     -> pg_trgm over node_keys ONLY, never the data plane
--   SEMANTIC         -> pgvector over the embedding table for one entity type
--   GRAPH depth 1    -> GRAPH_TABLE over the property graph below
--   GRAPH depth n>1  -> WITH RECURSIVE over edges (PG19 has no quantified
--                       path patterns; confirmed empirically, brief.md §3)
--   SEARCH           -> RRF fusion of the lexical and semantic ranks
--   <ordinary SQL>   -> read-only passthrough, SECURITY INVOKER (brief.md §3);
--                       no keyword, recognised by how the statement starts
-- ============================================================




create schema if not exists aiq;

-- ------------------------------------------------------------
-- 1. Node registry — graph identity for one included typed row.
--    Does NOT store the payload; payload stays on the typed table.
-- ------------------------------------------------------------
create table aiq.nodes (
    id           uuid primary key default gen_random_uuid(),
    entity_type  text not null,          -- owning table, e.g. 'company'
    entity_id    uuid not null,          -- PK in that table
    org_id       uuid,                   -- tenant; null = shared reference data
    summary      text,                   -- cheap human/agent-readable label
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (entity_type, entity_id)
);
create index idx_nodes_org on aiq.nodes (org_id);

create trigger trg_nodes_touch before update on aiq.nodes
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Keys — how humans, agents and the query dialect NAME a node.
--    Not the edge foreign key (that is nodes.id, graph-identity.md D3).
--    entity_type is copied here so the unique index needs no join.
-- ------------------------------------------------------------
create table aiq.node_keys (
    node_id      uuid not null references aiq.nodes(id) on delete cascade,
    entity_type  text not null,
    key          text not null,          -- normalized (lowercased, trimmed)
    kind         text not null check (kind in ('canonical','short','alias')),
    org_id       uuid,
    primary key (node_id, key, kind)
);
-- Canonical keys are unique per (org, type). Short keys and aliases are
-- deliberately NOT unique -- 'bakhmut' may be canonical for a place and an
-- event, and short-key lookup may legitimately return several nodes.
--
-- NULLS NOT DISTINCT, and it is the whole guarantee rather than a detail.
-- org_id IS NULL means shared reference data, which integration-rbac.sql §1
-- calls "a real category here, not a loophole" and which every public company
-- in a deployment will be. Under the default NULLS DISTINCT, two NULLs never
-- conflict -- so this index enforced canonical-key uniqueness for exactly the
-- tenants that have one and not at all for the shared tier. Measured: two
-- companies both took the canonical key 'acme', and LOOKUP "ACME" -- the
-- dialect's most common call, documented as an exact match -- returned two
-- different nodes with no way to tell which was meant.
create unique index idx_node_keys_canonical
    on aiq.node_keys (org_id, key, entity_type) nulls not distinct
    where kind = 'canonical';
create index idx_node_keys_lookup on aiq.node_keys (key);
-- FUZZY lives here and ONLY here: a trigram index on this thin key table,
-- never on the data plane (graph-identity.md "Scale").
create index idx_node_keys_trgm on aiq.node_keys using gin (key gin_trgm_ops);

-- ------------------------------------------------------------
-- 3. Relation catalogue — every allowed (src_type, relation, dst_type).
--    Out-of-catalogue relations are rejected at write, so the graph cannot
--    accumulate typos-as-relations (graph-identity.md "Catalogue").
-- ------------------------------------------------------------
create table aiq.relation_types (
    src_type   text not null,
    relation   text not null,
    dst_type   text not null,
    inverse_label text,                  -- read-time inverse; NOT a stored edge
    description   text,
    primary key (src_type, relation, dst_type)
);

-- ------------------------------------------------------------
-- 4. Edges — canonical store for SOFT (authored) links only.
--    Hard FK/junction relationships are NEVER copied here (D4).
-- ------------------------------------------------------------
create table aiq.edges (
    id          uuid primary key default gen_random_uuid(),
    src_id      uuid not null references aiq.nodes(id) on delete cascade,
    dst_id      uuid not null references aiq.nodes(id) on delete cascade,
    relation    text not null,
    weight      real not null default 1.0,
    valid_from  timestamptz,
    valid_to    timestamptz,
    provenance  jsonb not null default '{}'::jsonb,
    org_id      uuid,
    created_at  timestamptz not null default now(),
    unique (src_id, dst_id, relation)
);
-- Forward and REVERSE both indexed: "what points at this?" is first-class,
-- and the inverse edge is never stored (graph-identity.md "Edge table").
create index idx_edges_src on aiq.edges (src_id);
create index idx_edges_dst on aiq.edges (dst_id);
create index idx_edges_relation on aiq.edges (relation);

-- Enforce the catalogue, and enforce that both endpoints are real nodes
-- (the FKs already do the latter; this makes the type-pair check real).
create or replace function aiq.check_edge_catalogue() returns trigger as $$
declare
    v_src_type text;
    v_dst_type text;
begin
    select entity_type into v_src_type from aiq.nodes where id = new.src_id;
    select entity_type into v_dst_type from aiq.nodes where id = new.dst_id;
    if not exists (
        select 1 from aiq.relation_types
        where src_type = v_src_type and relation = new.relation and dst_type = v_dst_type
    ) then
        -- `%s` here, not `%`: RAISE takes % as the placeholder, so the
        -- original spelling appended a literal 's' to every value and the
        -- message read `relation (companys, competes_withs, persons)`. An
        -- error that misnames the types it is complaining about sends the
        -- reader looking for an entity type that does not exist.
        raise exception
            'relation (%, %, %) is not in the catalogue -- add it to aiq.relation_types first',
            coalesce(v_src_type, '<no node>'), new.relation,
            coalesce(v_dst_type, '<no node>');
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_check_edge_catalogue
    before insert or update on aiq.edges
    for each row execute function aiq.check_edge_catalogue();

-- ------------------------------------------------------------
-- 5. The property graph (SQL/PGQ). Read-only catalog metadata over the
--    tables above -- no second copy of the graph, no writers (D8, invariant 7).
--    Hard-link junctions get added here as EDGE TABLES by each consumer that
--    wants them walkable; nothing about that is stored twice either.
-- ------------------------------------------------------------
-- Two PG19 syntax constraints, both found by the parser rejecting the
-- obvious form, and both worth stating because neither is guessable:
--   * KEY must precede SOURCE/DESTINATION in an edge table definition.
--   * SOURCE/DESTINATION ... REFERENCES takes the vertex table's ALIAS
--     (its unqualified name as declared above), never a schema-qualified
--     name -- `references aiq.nodes (id)` is a syntax error.
--   * The KEY column is NOT implicitly a property. Selecting a.id in a
--     GRAPH_TABLE COLUMNS clause fails with `property "id" does not exist`
--     unless id is also listed in PROPERTIES. Since every useful query needs
--     the node id to join back to the typed tables, id is declared twice
--     here by necessity, not redundancy.
create property graph aiq.knowledge_graph
    vertex tables (
        aiq.nodes key (id) label node properties (id, entity_type, org_id, summary)
    )
    edge tables (
        aiq.edges key (id)
            source key (src_id) references nodes (id)
            destination key (dst_id) references nodes (id)
            label related properties (relation, weight, org_id)
    );

-- ------------------------------------------------------------
-- 6. Projection: keeping nodes/node_keys in sync with typed tables.
--
--    D6: STATEMENT-level triggers with transition tables, not row-level.
--    The difference is the whole scalability argument -- a 10k-row COPY pays
--    ONE set-based INSERT here, not 10k trigger firings. Row-level triggers
--    are permitted only on tiny interactive tables, and are not the default.
--
--    Registration is generic: a consumer calls aiq.register_entity_table()
--    and gets projection for free, rather than hand-writing three triggers
--    per table. The inclusion policy (which rows become nodes) is expressed
--    as a WHERE predicate on the source table -- rebuild and live projection
--    MUST use the same predicate, or a rebuild resurrects evicted nodes
--    (graph-identity.md "Inclusion policy").
-- ------------------------------------------------------------
create table aiq.entity_registry (
    entity_type   text primary key,
    source_table  text not null,          -- schema-qualified
    key_expr      text not null,          -- SQL expr -> canonical key
    summary_expr  text not null default 'null',
    org_expr      text not null default 'null',
    include_where text not null default 'true',
    registered_at timestamptz not null default now()
);

create or replace function aiq.register_entity_table(
    p_entity_type   text,
    p_source_table  text,
    p_key_expr      text,
    p_summary_expr  text default 'null',
    p_org_expr      text default 'null',
    p_include_where text default 'true'
) returns void as $$
declare
    -- Named after the ENTITY TYPE, not after the source table's short name.
    --
    -- The short name was `split_part(p_source_table, '.', 2)`, which is not
    -- unique: registering `s1.thing` as `t_one` and `s2.thing` as `t_two`
    -- generated `aiq.project_thing_ins` twice, and the second CREATE OR
    -- REPLACE silently rewrote the first with the other type's entity_type
    -- baked in. Rows inserted into s1.thing were then projected as `t_two`.
    -- Confirmed by running it: identity for a whole table came back wrong,
    -- with nothing raised anywhere. entity_type is the registry's primary
    -- key, so it is the only name that cannot collide.
    v_ins   text := quote_ident('project_' || p_entity_type || '_ins');
    v_del   text := quote_ident('project_' || p_entity_type || '_del');
    v_other text;
begin
    -- One table, one entity type. Two types over one table cannot both work
    -- anyway -- the trigger names are fixed, so the second registration's
    -- triggers replace the first's and only one type ever projects -- and the
    -- failure is silent. Refusing is the honest form of the same limit.
    select entity_type into v_other from aiq.entity_registry
     where source_table = p_source_table and entity_type <> p_entity_type;
    if v_other is not null then
        raise exception
            '% is already registered as entity type % -- one table projects into '
            'one entity type. Drop the other registration first, or project the '
            'second view of this table from its own view or table.',
            p_source_table, v_other;
    end if;

    insert into aiq.entity_registry
        (entity_type, source_table, key_expr, summary_expr, org_expr, include_where)
    values (p_entity_type, p_source_table, p_key_expr, p_summary_expr, p_org_expr, p_include_where)
    on conflict (entity_type) do update
        set source_table = excluded.source_table, key_expr = excluded.key_expr,
            summary_expr = excluded.summary_expr, org_expr = excluded.org_expr,
            include_where = excluded.include_where;

    -- One projection function per registered type, generated from the
    -- registry row. Generated rather than generic-at-runtime because a
    -- statement trigger's transition table cannot be addressed dynamically
    -- by name from a shared function -- the trigger body has to know its own
    -- table. This is the concrete cost of D6's statement-level requirement,
    -- and it is worth paying: the alternative is a row-level trigger and a
    -- projection per row.
    --
    -- The function has FOUR statements, not two, and the two added ones are
    -- both evictions. A projection that only ever inserts keeps a registry
    -- that only ever grows, and both halves of that were real: an UPDATE that
    -- made a row fail the inclusion predicate left its node and key in place
    -- (invariant 3 broken by the projection itself, and the drift check duly
    -- reported the node it had just created), and a rename left the old
    -- canonical key behind, so the previous name went on resolving forever
    -- and the node ended up with two keys each claiming to be the derived one.
    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            -- 1. Rows that belong: upsert identity.
            insert into aiq.nodes (entity_type, entity_id, org_id, summary)
            select %2$L, n.id, %3$s, %4$s from new_rows n where %5$s
            on conflict (entity_type, entity_id) do update
                set summary = excluded.summary, org_id = excluded.org_id,
                    updated_at = now();

            -- 2. Rows that no longer belong: evict. coalesce(..., false)
            --    rather than `not (...)` because a predicate that evaluates to
            --    NULL is not satisfied, and three-valued logic here would put
            --    the stale node back exactly where it was.
            delete from aiq.nodes nd
            where nd.entity_type = %2$L
              and nd.entity_id in (select n.id from new_rows n
                                    where not coalesce((%5$s), false));

            -- 3. The canonical key.
            insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
            select nd.id, %2$L, lower(trim(%6$s)), 'canonical', %3$s
            from new_rows n
            join aiq.nodes nd on nd.entity_type = %2$L and nd.entity_id = n.id
            where %5$s
            -- DO UPDATE, not DO NOTHING: org_id scopes the canonical-key
            -- unique index, so leaving a stale copy on an existing key row
            -- silently corrupts that scoping after a tenancy change.
            on conflict (node_id, key, kind) do update set org_id = excluded.org_id;

            -- 4. Superseded canonical keys. Runs AFTER the insert, so a
            --    key_expr that evaluates to NULL aborts on the not-null
            --    constraint above rather than deleting the name the node had.
            --    Short keys and aliases are editorial and are not touched:
            --    a rename is not a reason to forget that somebody taught the
            --    graph a synonym.
            delete from aiq.node_keys k
            using aiq.nodes nd, new_rows n
            where k.node_id = nd.id
              and nd.entity_type = %2$L and nd.entity_id = n.id
              and k.kind = 'canonical'
              and k.key is distinct from lower(trim(%6$s));
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_ins, p_entity_type, p_org_expr, p_summary_expr, p_include_where, p_key_expr);

    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            delete from aiq.nodes
            where entity_type = %2$L and entity_id in (select id from old_rows);
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_del, p_entity_type);

    execute format('drop trigger if exists trg_aiq_project_ins on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_ins
            after insert on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_ins);

    execute format('drop trigger if exists trg_aiq_project_upd on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_upd
            after update on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_ins);

    execute format('drop trigger if exists trg_aiq_project_del on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_del
            after delete on %1$s
            referencing old table as old_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_del);
end;
-- `drop trigger if exists` raises a NOTICE per trigger it did not find, so a
-- first registration emitted three lines of "does not exist, skipping" that
-- say nothing and bury anything that does. WARNING and above still get
-- through, which is everything a caller of this function needs to see.
$$ language plpgsql set client_min_messages = warning;

-- Rebuild + drift detection (D7). The rebuild MUST use the same predicate as
-- the live trigger -- both read it from entity_registry, so they cannot drift
-- apart by editing one and forgetting the other.
--
-- The source row is aliased `n` here, matching the alias the live trigger's
-- transition table uses. That is not cosmetic: registry expressions are stored
-- as SQL text (`n.is_public`, `coalesce(n.ticker, n.name)`), so the alias is
-- part of their contract. An earlier version aliased the source `s` in rebuild
-- and `n` in the trigger, which made every rebuild fail outright with
-- "missing FROM-clause entry for table n" -- caught by running it. Worse than
-- a silent drift, but the same root cause D7 is about: two code paths that
-- must agree, with nothing forcing them to.
create or replace function aiq.rebuild_entity_type(p_entity_type text)
returns bigint as $$
declare
    r aiq.entity_registry;
    v_count bigint;
begin
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    if not found then raise exception 'entity type % not registered -- SCHEMA "graph" lists the registered ones', p_entity_type; end if;

    execute format($q$
        insert into aiq.nodes (entity_type, entity_id, org_id, summary)
        select %1$L, n.id, %2$s, %3$s from %4$s n where %5$s
        on conflict (entity_type, entity_id) do update
            set summary = excluded.summary, org_id = excluded.org_id, updated_at = now()
    $q$, r.entity_type, r.org_expr, r.summary_expr, r.source_table, r.include_where);

    execute format($q$
        insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
        select nd.id, %1$L, lower(trim(%2$s)), 'canonical', %3$s
        from %4$s n
        join aiq.nodes nd on nd.entity_type = %1$L and nd.entity_id = n.id
        where %5$s
        on conflict (node_id, key, kind) do update set org_id = excluded.org_id
    $q$, r.entity_type, r.key_expr, r.org_expr, r.source_table, r.include_where);

    -- Evict nodes whose source row is gone or no longer satisfies inclusion.
    execute format($q$
        delete from aiq.nodes nd
        where nd.entity_type = %1$L
          and not exists (select 1 from %2$s n where n.id = nd.entity_id and %3$s)
    $q$, r.entity_type, r.source_table, r.include_where);

    -- Returns how many nodes this type HAS now, not how many rows the last
    -- statement touched. `get diagnostics row_count` after the eviction
    -- DELETE meant a rebuild that had just projected ten nodes returned 0,
    -- which reads as "did nothing" to the bulk-load caller that asked for it.
    execute format('select count(*) from aiq.nodes where entity_type = %L',
                   p_entity_type) into v_count;
    return v_count;
end;
$$ language plpgsql;

-- Two-way EXCEPT drift check (D7). Non-empty result = a writer bug, not a
-- routine merge to paper over. Run as a scheduled workflow-engine task
-- (D10), not a bespoke cron job.
create or replace function aiq.check_drift(p_entity_type text)
returns table(direction text, entity_id uuid) as $$
declare r aiq.entity_registry;
begin
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    if not found then raise exception 'entity type % not registered -- SCHEMA "graph" lists the registered ones', p_entity_type; end if;

    return query execute format($q$
        select 'missing_node'::text, n.id from %2$s n where %3$s
        except
        select 'missing_node'::text, nd.entity_id from aiq.nodes nd where nd.entity_type = %1$L
        union all
        select 'orphan_node'::text, nd.entity_id from aiq.nodes nd where nd.entity_type = %1$L
        except
        select 'orphan_node'::text, n.id from %2$s n where %3$s
    $q$, r.entity_type, r.source_table, r.include_where);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 5b. The org-membership seam.
--
-- This lives in the CORE schema and not in integration-rbac.sql, where its
-- policies live and where it was first written, for a reason found by building
-- a pristine database from the generated extension script: `aiq.schema_graph`
-- -- a core §13 facet -- scopes the sample keys it shows to the caller's orgs,
-- and a `language sql` function is validated at CREATE time. The integration
-- file is applied AFTER this one, so the facet could not be created at all on a
-- fresh install: SCHEMA "graph" was missing from every new database and present
-- in every database where somebody had loaded the file by hand. Existence is
-- not currency, and this is the shape currency.sh exists to catch.
--
-- The design point it was written with is unchanged and still applies: this
-- layer does not invent a second notion of tenancy. user-rbac has no org model
-- yet (specs/README.md defers tenant management deliberately), so the predicate
-- is expressed against a single function that a real deployment replaces.
-- Shipping a permissive default silently would be the worst option; this errs
-- closed for org-scoped rows when no membership source exists.
--
-- Returns SETOF rather than an array, deliberately: `org_id = any (select ...)`
-- against an array-returning function compares uuid to uuid[] and fails, while
-- the array form `= any (f())` gives up the InitPlan hoisting that
-- user-rbac/schema.sql §9 measured as the difference between evaluating a
-- predicate once per query and once per row scanned. SETOF gives both --
-- `in (select ...)` type-checks and plans as a hashed SubPlan.
-- ------------------------------------------------------------
create or replace function aiq.current_org_ids() returns setof uuid as $$
    -- Reads the same request-scoped GUC mechanism as rbac.current_user_id():
    -- PostgREST sets request.jwt.claims per request, so an org claim rides in
    -- the verified token rather than being supplied as a spoofable argument.
    select (value #>> '{}')::uuid
    from jsonb_array_elements(
        coalesce(
            nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'orgs',
            '[]'::jsonb
        )
    );
$$ language sql stable;

-- ------------------------------------------------------------
-- 6b. Aliases and short keys -- the only supported write path into node_keys.
--
-- Invariant 5 says application code never writes nodes or node_keys except
-- through the projection. The projection writes exactly one row per source
-- row, the CANONICAL key from key_expr, because that is all a source row can
-- derive. The other two kinds are editorial: 'kiev' is an alias for 'kyiv'
-- because somebody decided so, and no expression over the typed table
-- produces it.
--
-- So two thirds of LOOKUP's cascade (graph-identity.md "Keys": exact
-- canonical, then short, then fuzzy over both) had no write path the
-- invariant permitted -- the branches existed, were tested with hand-inserted
-- rows, and no caller could reach them without breaking the rule the schema
-- states. This is that path: the invariant's exception, named and narrow,
-- rather than an unwritten convention that inserting into node_keys is fine
-- if you are careful.
--
-- It refuses to write a canonical key. Canonical belongs to the projection,
-- and a second canonical key on one node is not a synonym -- it is two names
-- each claiming to be the derived one. The (org_id, key, entity_type) unique
-- index does not prevent it, because that index scopes uniqueness ACROSS
-- nodes, not within one.
--
-- Not granted to `authenticated`: naming is an editorial act with the same
-- blast radius as registration (an alias silently re-points every LOOKUP that
-- uses it), so it stays with the role that runs migrations, like
-- register_entity_table above.
-- ------------------------------------------------------------
create or replace function aiq.add_node_key(
    p_node_key text, p_key text, p_kind text default 'alias'
) returns uuid as $$
declare
    v_node_id uuid;
    v_n       int;
    v_norm    text := lower(trim(p_key));
begin
    if p_kind = 'canonical' then
        raise exception
            'canonical keys come from the projection (entity_registry.key_expr), '
            'not from add_node_key -- change key_expr and rebuild, or add this '
            'name as a short key or an alias';
    elsif p_kind not in ('short','alias') then
        raise exception 'kind must be short or alias, not %', p_kind;
    end if;
    if v_norm is null or v_norm = '' then
        raise exception 'an empty key matches nothing and would sit in the '
                        'trigram index forever';
    end if;

    -- Resolved through the ordinary cascade, so an alias can be hung off a
    -- node found by its short name. Ambiguity is refused rather than resolved
    -- by picking one: attaching a name to the wrong node is not recoverable by
    -- reading the row back, since it looks exactly like the right one.
    -- (array_agg(...))[1] rather than min(): there is no min(uuid) in PG19,
    -- and the aggregate is only here to make "how many" and "which one" one
    -- pass over a result that is nearly always a single row.
    select count(*), (array_agg(l.node_id))[1] into v_n, v_node_id
    from aiq.lookup(p_node_key) l;
    if v_n = 0 then
        raise exception 'no node is named % -- add_node_key names an existing '
                        'node, it does not create one', p_node_key;
    elsif v_n > 1 then
        raise exception '% resolves to % nodes -- name the one you mean by its '
                        'canonical key', p_node_key, v_n;
    end if;

    -- entity_type and org_id are COPIED from the node for the same reason the
    -- projection copies them: the canonical-key unique index reads them
    -- without a join, and a hand-supplied value could disagree with the node.
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select v_node_id, n.entity_type, v_norm, p_kind, n.org_id
    from aiq.nodes n where n.id = v_node_id
    on conflict (node_id, key, kind) do update set org_id = excluded.org_id;

    return v_node_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 7. The query modes.
--
-- Each is an ordinary SQL function so PostgREST exposes it as an RPC and the
-- planner can see through it. aiq_query() (§8) is the single dispatch entry
-- point the dialect compiles to; these are the per-mode implementations, also
-- callable directly when a caller already knows the mode it wants.
-- ------------------------------------------------------------

-- LOOKUP: exact canonical -> short -> (caller opts in) fuzzy. Returns
-- identity + summary only; hydrating the typed row is a second, deliberate
-- step (REM's lazy-then-load discipline, brief.md §2).
create or replace function aiq.lookup(
    p_key text, p_fuzzy boolean default false, p_limit int default 20
) returns table(node_id uuid, entity_type text, entity_id uuid, key text,
                match_kind text, score real) as $$
declare v_norm text := lower(trim(p_key));
begin
    -- 1. exact canonical. distinct on (n.id) throughout, see the fuzzy
    -- branch below for why.
    return query
    select distinct on (n.id)
           n.id, n.entity_type, n.entity_id, k.key, 'canonical'::text, 1.0::real
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind = 'canonical'
    limit p_limit;
    if found then return; end if;

    -- 2. short / alias -- may legitimately return several NODES (and several
    -- types: 'bakhmut' as both a place and an event is the canonical example
    -- from graph-identity.md). Several nodes is correct; the same node twice
    -- is not.
    return query
    select distinct on (n.id)
           n.id, n.entity_type, n.entity_id, k.key, k.kind, 1.0::real
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind in ('short','alias')
    limit p_limit;
    if found then return; end if;

    -- 3. fuzzy, opt-in, and ONLY over node_keys -- never the data plane.
    --
    -- DISTINCT ON (n.id): a node with several matching keys (canonical
    -- 'acme', short 'acme', alias 'acme robotics') otherwise comes back once
    -- PER KEY. Confirmed on the fixture: one company returned three times for
    -- a single misspelling. LOOKUP answers "which NODES match this string",
    -- not "which key rows matched" -- the caller is going to hydrate nodes,
    -- and a duplicate is a bug at the call site every time. Best-scoring key
    -- wins and is reported, so the caller can still see WHICH name matched.
    if p_fuzzy then
        return query
        select * from (
            select distinct on (n.id)
                   n.id, n.entity_type, n.entity_id, k.key, 'fuzzy'::text,
                   similarity(k.key, v_norm) as score
            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
            where k.key % v_norm
            order by n.id, similarity(k.key, v_norm) desc
        ) d
        order by d.score desc
        limit p_limit;
    end if;
end;
$$ language plpgsql stable;

-- LOOKUP over a LIST of keys -- what the dialect's `LOOKUP "a", "b"` compiles
-- to, and the shape an agent actually needs: it rarely holds exactly one name.
--
-- Each key runs the full cascade independently. That is the whole subtlety:
-- resolving them as one set would let one key's canonical hit suppress
-- another key's fuzzy match, so a list of five names would answer differently
-- than five separate calls. Independence keeps the list a convenience rather
-- than a change of meaning.
--
-- It returns `input_key` alongside each row, which the scalar form has no need
-- for. Without it a caller cannot tell WHICH of five names produced a row, or
-- which produced none -- and "which of these did you not find" is usually the
-- question worth asking.
--
-- Deliberately NOT an overload of aiq.lookup(text, ...): an untyped literal
-- like aiq.lookup('acme') would then be ambiguous between text and text[],
-- and "function is not unique" is a poor greeting for the dialect's most
-- common call.
create or replace function aiq.lookup_many(
    p_keys text[], p_fuzzy boolean default false, p_limit int default 20
) returns table(input_key text, node_id uuid, entity_type text, entity_id uuid,
                key text, match_kind text, score real) as $$
    -- LEFT join lateral, so a key that matched nothing comes back as a row
    -- with a null node_id rather than not coming back at all. The comment
    -- above has always said "which of these did you not find" is usually the
    -- question worth asking; the inner join meant input_key could only ever
    -- report keys that HAD been found, which is the one case where the caller
    -- can already tell.
    select k.key_in, l.node_id, l.entity_type, l.entity_id, l.key,
           l.match_kind, l.score
    from unnest(p_keys) as k(key_in)
    left join lateral aiq.lookup(k.key_in, p_fuzzy, p_limit) l on true;
$$ language sql stable;

-- GRAPH depth 1: native SQL/PGQ. Confirmed working on PG19 beta3.
-- The `key` column, and why it is not optional.
--
-- This function returned `neighbor_id` and `summary` and no key, and the
-- worked example in USAGE.md reads fine because its summaries happen to BE
-- names ("Acme Robotics", "Dana Whitfield"). Run it against a graph whose
-- summaries are what summaries are for -- a band label, a status, a one-line
-- description -- and the answer is a column of UUIDs. Asked "which pairs moved
-- with sterling", the query layer returned eight ids and nothing that could be
-- said back to a person.
--
-- What made that unrecoverable rather than merely inconvenient: the dialect
-- has no mode that takes an id. LOOKUP resolves a key to a node; nothing
-- resolves a node back to a key. So a GRAPH result could not be turned into
-- names by any further p8ql query, only by dropping to SQL against node_keys
-- -- from a mode whose entire purpose is naming things.
--
-- graph-identity.md's rule is that a node is NAMED by its canonical key and
-- traversal happens by id. Both halves are load-bearing, and the read path was
-- keeping only the second.
create or replace function aiq.graph_neighbors(
    p_node_id uuid, p_relation text default null, p_limit int default 100
) returns table(neighbor_id uuid, key text, entity_type text, summary text,
                relation text, weight real, direction text) as $$
    select * from (
        select b.id, kb.key, b.entity_type, b.summary, e.relation, e.weight, 'out'::text
        from graph_table (aiq.knowledge_graph
            match (a is node) -[e is related]-> (b is node)
            columns (a.id as a_id, b.id as b_id, e.relation as relation, e.weight as weight)
        ) g
        join aiq.nodes b on b.id = g.b_id
        join aiq.edges e on e.src_id = g.a_id and e.dst_id = g.b_id and e.relation = g.relation
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = b.id and nk.kind = 'canonical'
                            limit 1) kb on true
        where g.a_id = p_node_id and (p_relation is null or g.relation = p_relation)
        union all
        -- The reverse question is first-class: no inverse edge is stored, so
        -- it is answered by walking dst_id, and the label comes from the
        -- catalogue at read time (graph-identity.md "Edge table").
        select a.id, ka.key, a.entity_type, a.summary,
               coalesce(rt.inverse_label, e.relation || '_by'), e.weight, 'in'::text
        from aiq.edges e
        join aiq.nodes a on a.id = e.src_id
        join aiq.nodes b2 on b2.id = e.dst_id
        left join aiq.relation_types rt
               on rt.src_type = a.entity_type and rt.relation = e.relation
              and rt.dst_type = b2.entity_type
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = a.id and nk.kind = 'canonical'
                            limit 1) ka on true
        -- The inverse label is matched too, and this is a round-trip fix
        -- rather than a convenience. The row above REPORTS `employs` for an
        -- inbound `works_at`; asking `GRAPH "ACME" TYPE employs` then returned
        -- nothing, so the dialect was displaying a relation name it refused to
        -- accept back. From this node's point of view both names name the same
        -- edge, and a caller that reads one should be able to write it.
        where e.dst_id = p_node_id
          and (p_relation is null or e.relation = p_relation
               or coalesce(rt.inverse_label, e.relation || '_by') = p_relation)
    ) x
    limit p_limit;
$$ language sql stable;

-- GRAPH depth n>1: WITH RECURSIVE. PG19's GRAPH_TABLE rejects quantified path
-- patterns outright ("element pattern quantifier is not supported") -- not a
-- beta gap to wait out, deliberately scoped out of the initial implementation
-- (brief.md §3). Depth- AND degree-capped, per graph-identity.md "Non-goals".
drop function if exists aiq.graph_walk(uuid, int, text, int);
create or replace function aiq.graph_walk(
    p_node_id uuid, p_depth int default 2, p_relation text default null,
    p_max_nodes int default 500
) returns table(node_id uuid, key text, entity_type text, summary text,
                depth int, path_relations text[], path_weight real) as $$
    with recursive walk as (
        select n.id, n.entity_type, n.summary, 0 as depth,
               array[]::text[] as rels, array[n.id] as seen, 1.0::real as score
        from aiq.nodes n where n.id = p_node_id
        union all
        -- path_weight is the PRODUCT of the edge weights along the path, not
        -- their sum or their minimum. brief.md §3.6 puts a coherence score in
        -- edges.weight and says a walk should not treat every edge as equally
        -- believed; a product is what makes a two-hop path through one
        -- barely-promoted 0.35 edge rank below two strong hops, which is the
        -- example that section actually gives. Sum would reward length, and
        -- min would make a long chain of near-certainties indistinguishable
        -- from a single one.
        --
        -- Until this existed §3.6's claim that "graph_walk orders by
        -- accumulated weight along the path" was simply false: the walk
        -- ordered by node id and ignored weight entirely, so the whole
        -- ingestion pipeline's scoring was discarded at the read step -- the
        -- exact failure that section is about.
        select nx.id, nx.entity_type, nx.summary, w.depth + 1,
               w.rels || e.relation, w.seen || nx.id, (w.score * e.weight)::real
        from walk w
        join aiq.edges e on (e.src_id = w.id or e.dst_id = w.id)
        join aiq.nodes nx on nx.id = case when e.src_id = w.id then e.dst_id else e.src_id end
        where w.depth < p_depth
          and not nx.id = any(w.seen)          -- cycle guard
          -- Same round-trip rule as graph_neighbors: a relation may be named
          -- by its catalogue name or by the inverse label the read path shows.
          and (p_relation is null or e.relation = p_relation
               or exists (select 1 from aiq.relation_types rt
                           where rt.relation = e.relation
                             and rt.inverse_label = p_relation))
    )
    -- DISTINCT ON (id) ... ORDER BY depth: a node reachable by several paths
    -- otherwise appears once PER PATH. Confirmed on the fixture: 'Acme
    -- Robotics' came back three times from one walk (depth 1 directly, depth
    -- 2 via two other routes). This mode answers "what is related to this,
    -- and how far away" -- one row per node, at its SHORTEST distance, with
    -- the path that achieved it. That is what REM's lazy-then-load discipline
    -- (brief.md §2) actually needs: a candidate SET to review, then hydrate.
    --
    -- Enumerating every distinct PATH between two nodes is a genuinely
    -- different question (provenance/explanation, not discovery). It is not
    -- this function, and it should not be a boolean flag on this function --
    -- the result shape differs, and callers of the two want different limits.
    -- Left unbuilt until a real consumer needs it.
    -- The same `key` graph_neighbors carries, and for the same reason: a
    -- walk that returns ids is a walk whose result cannot be spoken.
    --
    -- The cap is applied to an ORDERED result, which it previously was not.
    -- `limit p_max_nodes` over a DISTINCT ON's node-id order dropped an
    -- arbitrary subset -- a walk capped at 3 returned three nodes chosen by
    -- uuid. Nearest first, then best-corroborated, so a capped walk keeps the
    -- part of the neighbourhood the caller would have kept.
    select * from (
        select distinct on (w.id) w.id, k.key, w.entity_type, w.summary,
               w.depth, w.rels, w.score
        from walk w
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = w.id and nk.kind = 'canonical'
                            limit 1) k on true
        where w.depth > 0
        order by w.id, w.depth, w.score desc
    ) d
    order by d.depth, d.score desc, d.id
    limit p_max_nodes;
$$ language sql stable;

-- SEMANTIC's corpus registry: which table a `FROM <name>` names, for the
-- vector modes. Registered per corpus rather than hardcoded, because the
-- content belongs to the consumer (world-model-ingestion owns
-- resource_chunks), not to this layer.
create table aiq.semantic_sources (
    name          text primary key,
    source_table  text not null,       -- schema-qualified, has (id, content)
    content_col   text not null default 'content',
    -- Kept, and no longer read by anything. It described the superseded
    -- storage shape below, where the vector was a column on the consumer's own
    -- table. §10 moved embeddings into per-MODEL spaces owned by this schema,
    -- which is what makes two models over one corpus possible at all; a column
    -- on the chunk table can hold exactly one model's output.
    embedding_col text not null default 'embedding',
    link_expr     text                 -- optional SQL expr -> owning node's entity_id
);

-- The superseded implementation, removed rather than left to be found.
--
-- `aiq.semantic(source, vector, limit)` read `<source_table>.<embedding_col>`
-- -- an embedding column on the consumer's own chunk table. §10 replaced that
-- storage model with one table per registered MODEL, and this function was
-- never updated, never called by the dispatch (which routes SEMANTIC to
-- semantic_in), and never declared in surface.sql. It had therefore been
-- broken for as long as the schema has shipped: calling it against the
-- registered `chunks` source raises `column c.embedding does not exist`,
-- because content.resource_chunks has no such column and never did.
--
-- Two implementations of one mode, one of them unreachable and non-working, is
-- worse than one: it is a function an agent can find in the catalog, call, and
-- receive a schema error from. The drop is explicit because `create or replace`
-- cannot remove it from a database that already installed it.
drop function if exists aiq.semantic(text, vector, int);

-- ============================================================
-- 8. Verified properties (measured on PG19 beta3, not asserted).
--
-- graph-identity.md's "Verification" section lists these as the criteria a
-- correct implementation must meet. Results from running them against this
-- schema with a real fixture:
--
--  * LOOKUP is an index probe, NOT an Append of typed-table scans:
--        Nested Loop
--          -> Index Scan using idx_node_keys_canonical on node_keys
--          -> Index Scan using nodes_pkey on nodes
--    This is the whole scale argument (10^9 KEYS stays O(log n)) and it holds.
--
--  * SQL/PGQ is a rewriter onto ordinary joins, exactly as the standard
--    describes. An unfiltered GRAPH_TABLE plans as hash joins over
--    edges + nodes; there is no separate graph engine and no index-free
--    adjacency to hope for.
--
--  * Predicates push down THROUGH GRAPH_TABLE into the base-table indexes,
--    and -- the part worth knowing -- it does not matter whether the
--    predicate is written inside the MATCH pattern
--    (`match (a is node where a.id = $1)`) or applied to the GRAPH_TABLE
--    result (`where g.a_id = $1`). Both produce:
--        Index Only Scan using nodes_pkey  (seed)
--        Bitmap Index Scan on idx_edges_src (expand)
--    So callers need no special construction discipline, and the reverse
--    direction is served by idx_edges_dst the same way. This is a direct
--    consequence of PGQ being a rewriter: the ordinary planner optimises it.
--
--  * Inclusion policy is enforced at projection time: with
--    include_where = 'n.is_public', a private company got no node, no key and
--    therefore could not be an edge endpoint. Data-plane rows
--    (resource_chunks) are never nodes, and the semantic path reaches them
--    through a relational join instead -- the read-path split the design
--    requires, working end to end.
--
--  * A hard FK (events.primary_company_id) is absent from aiq.edges and still
--    answerable by an indexed join -- the "two memories" claim (D4), concrete.
--
-- ------------------------------------------------------------
-- 8b. What a second, exhaustive pass measured -- and what it corrected.
--
-- The results above were measured against a fixture that lived in a psql
-- session and was never committed, so nothing could re-run them. That fixture
-- is now dev/init/04-graph-sample.sql, and the properties above are now
-- assertions in dev/tests/query/04-06 rather than paragraphs. Running the
-- whole surface rather than the happy path changed several of them:
--
--  * "LOOKUP is an index probe, NOT an Append of typed-table scans" is not
--    assertable in that form at any fixture size worth shipping: with 22 keys
--    the planner reads the table sequentially and is correct to. The
--    size-independent statements are that the predicate is index-servable and
--    that the plan touches no registered source table -- which is what
--    invariant 6 actually claims. Recorded because the original phrasing would
--    have had to be neutered to pass, and a neutered assertion is worse than
--    none.
--
--  * The projection was insert-only. An UPDATE that made a row fail the
--    inclusion predicate left its node, its key, and its edges in place --
--    invariant 3 broken by the projection itself -- and a rename ADDED a
--    canonical key rather than replacing one, so the old name resolved
--    forever. Both are fixed above; both were invisible to any assertion that
--    only inserts.
--
--  * The canonical-key unique index was NULLS DISTINCT, so it enforced nothing
--    at all for shared reference data (org_id is null), which is most of a
--    real deployment. Two rows took the key 'acme' and LOOKUP returned both.
--
--  * Generated projection functions were named after the source table's SHORT
--    name, so two registered tables called `thing` in different schemas shared
--    one function and one of them projected under the other's entity_type.
--
--  * GRAPH resolved its seed key with fuzzy matching, always, and took the
--    first row: a typo walked a different node's neighbourhood and the answer
--    said nothing about it. The seed is now exact and reported.
--
--  * The walk ignored edges.weight entirely, contradicting brief.md §3.6's
--    claim to be coherence-ranked, and applied its row cap to a uuid-ordered
--    result.
--
--  * SQL/PGQ is RLS-filtered through the property graph, which was worth
--    checking rather than assuming: a property graph is a separate privilege
--    object compiled to joins, and neither fact settles whether the base
--    tables' policies still apply. They do (dev/tests/query/06 §3).
-- ============================================================

-- ------------------------------------------------------------
-- 9. Single dispatch entry point.
--
-- One PostgREST RPC for the whole dialect, so an agent posts
--     {"p_query": "GRAPH \"acme\" DEPTH 2 TYPE competes_with"}
-- to ONE endpoint rather than choosing between five. This is the
-- "query directly on the API" property the Rust parser exists to enable.
--
-- Parse and execute are deliberately split (see the parser's own comment in
-- the pgrx crate): aiq_parse() is pure computation in Rust, unit-testable
-- off-database, and returns the PLAN; this function executes it in SQL, where
-- the planner, RLS and the indexes already live. A caller can also call
-- aiq_parse() alone to see how its string was understood -- for an
-- agent-facing dialect that matters, because a misparse is otherwise
-- indistinguishable from an empty result.
--
-- Returns jsonb rather than a fixed row type: the modes genuinely return
-- different shapes, and forcing them into one row type would mean a lowest
-- common denominator that loses each mode's useful columns.
-- ------------------------------------------------------------
-- DEPENDENCY: aiq_parse(), from the p8_query extension. REQUIRED, not
-- optional -- the dialect is the primary interface to this layer, and
-- install.sh treats p8_query exactly like pgcrypto or pgvector.
--
-- The per-mode functions (lookup, graph_neighbors, graph_walk, semantic_in,
-- lexical, hybrid) remain plain SQL and callable directly. That is a
-- convenience for SQL clients and a fallback for a broken install, not a
-- supported alternative interface -- new capability lands in the dialect.
--
-- Checked at call time so a missing extension says WHICH extension and how to
-- get it, rather than failing on an unqualified "function does not exist"
-- that reads as a corrupt schema.
create or replace function aiq.query(p_query text, p_embedding vector default null)
returns jsonb as $$
declare
    p        jsonb;
    v_node   uuid;
    v_n      int;
    v_seed   jsonb;
    v_out    jsonb;
    v_unresolved jsonb := '[]'::jsonb;
begin
    if to_regprocedure('aiq_parse(text)') is null then
        raise exception
            'aiq_parse is missing. It ships in the same extension as this '
            'function, so this should be impossible -- if you are seeing it, the '
            'extension is partially installed. The per-mode functions '
            '(aiq.lookup, aiq.graph_neighbors, aiq.graph_walk, aiq.semantic_in, '
            'aiq.lexical, aiq.search) still work directly.';
    end if;
    p := aiq_parse(p_query);

    if not (p->>'ok')::boolean then
        raise exception 'query parse error: %', p->>'error';
    end if;

    case p->>'mode'
    when 'LOOKUP' then
        -- The dialect takes a list, so the dispatch does too. Resolving five
        -- names is one round trip and one plan, not five -- which is the
        -- normal case for an agent holding several entities at once.
        --
        -- A MISS IS NOT A ROW. lookup_many LEFT JOINs deliberately, so a key
        -- that matched nothing comes back as a row of nulls with input_key
        -- echoed -- useful to a SQL caller, who can filter, and actively
        -- misleading here: through this JSON envelope `rows` is non-empty and
        -- a miss is indistinguishable from a hit to anything that does not
        -- inspect the fields. `LOOKUP "sterling"` against a graph holding no
        -- such node returned one row, and a model reading it concluded it had
        -- found something. USAGE.md documented the opposite -- "absent rather
        -- than returned as an empty row" -- so the two halves of this system
        -- disagreed in writing, each with its reasoning stated next to it.
        --
        -- Both intents survive by separating them: matches in `rows`, the
        -- names that resolved to nothing in `unresolved`. The set difference
        -- USAGE.md promises is then handed over directly instead of being left
        -- as an exercise, and an empty result is empty.
        select coalesce(jsonb_agg(to_jsonb(l)) filter (where l.node_id is not null),
                        '[]'::jsonb),
               coalesce(jsonb_agg(distinct l.input_key) filter (where l.node_id is null),
                        '[]'::jsonb)
          into v_out, v_unresolved
        from aiq.lookup_many(
            (select array_agg(value) from jsonb_array_elements_text(p->'args')),
            (p->>'fuzzy')::boolean, (p->>'limit')::int) l;

    when 'GRAPH' then
        -- Four things are checked before anything is walked, and all four are
        -- the same rule the dialect already states for USING: a modifier the
        -- caller wrote and the engine ignored, or a value the engine quietly
        -- reinterpreted, is how a query comes to mean something other than
        -- what it says. Each of these was measured doing exactly that.

        -- (a) FROM names a CORPUS -- which chunk table TEXT/SEMANTIC/SEARCH
        --     read. A walk has no corpus; it starts at a node. The parser
        --     accepts `GRAPH "acme" FROM chunks` and the walk ignored it,
        --     which is the same silent drop USING is refused for. Ideally the
        --     parser would refuse it, next to the USING rule it already
        --     enforces; until the crate is rebuilt this is the backstop, and
        --     it fails in the same direction.
        if p->>'source' is not null then
            raise exception
                'FROM <source> applies only to TEXT, SEMANTIC and SEARCH -- a '
                'walk starts at a node, not in a corpus. Drop `FROM %`.',
                p->>'source';
        end if;

        -- (b) DEPTH below 1 asked for something and got depth 1. `GRAPH "x"
        --     DEPTH 0` returned the full neighbour list, because the dispatch
        --     routed depth <= 1 to graph_neighbors without looking at what
        --     the caller actually wrote.
        if (p->>'depth')::int < 1 then
            raise exception
                'DEPTH must be at least 1 -- DEPTH % asked for no traversal and '
                'would have been served a depth-1 one', p->>'depth';
        end if;

        -- (c) ...and DEPTH above the cap. graph-identity.md's non-goals list
        --     "unbounded traversal" and nothing enforced a bound: DEPTH 1000
        --     was accepted and run. 5 is a working ceiling rather than a
        --     measured one -- the documented discipline is lazy-then-load at
        --     depth 2 (brief.md §2) -- and it is enforced HERE rather than in
        --     graph_walk so a deliberate deep analytic walk can still call the
        --     function directly.
        if (p->>'depth')::int > 5 then
            raise exception
                'DEPTH % exceeds the dialect''s ceiling of 5. The documented '
                'pattern is a shallow walk, then LOOKUP of what looks worth '
                'loading; call aiq.graph_walk() directly if you really want '
                'depth %.', p->>'depth', p->>'depth';
        end if;

        -- (d) A relation nobody ever catalogued is a typo, always -- the write
        --     path refuses one, so the read path should not answer it with an
        --     empty result. `TYPE not_a_relation` returned [], which on this
        --     surface is indistinguishable from "nothing is related".
        if p->>'relation' is not null
           and not exists (select 1 from aiq.relation_types rt
                            where rt.relation = p->>'relation'
                               or rt.inverse_label = p->>'relation') then
            raise exception
                'no relation named % is in the catalogue -- SCHEMA "graph" lists '
                'the registered ones', p->>'relation';
        end if;

        -- Resolve the key ONCE, here, then traverse by id: the dialect names
        -- nodes by key, but traversal never parses names
        -- (graph-identity.md "Edges -- canonical, written directly").
        --
        -- EXACT, and this is a correction. The resolution was
        -- `aiq.lookup(arg, true, 1) limit 1` -- fuzzy, always, take whatever
        -- comes first. So `GRAPH "ACMEE"` walked Acme's neighbourhood and the
        -- answer said nothing about it, and `GRAPH "borealis"` -- a short key
        -- that graph-identity.md's own Bakhmut example says belongs to two
        -- nodes -- picked one of them by coin flip. Neither the typo nor the
        -- ambiguity was visible in the result.
        --
        -- The cascade LOOKUP already runs (canonical, then short, then alias)
        -- is what a seed needs; trigram matching is not, and the dialect has
        -- no FUZZY GRAPH to ask for it with -- `FUZZY` is refused on every
        -- mode but LOOKUP. On a miss the near matches come back as
        -- suggestions, so the affordance survives without the guess.
        select count(*), (array_agg(l.node_id))[1]
          into v_n, v_node
          from aiq.lookup(p->>'arg', false, 50) l;

        if v_n = 0 then
            return jsonb_build_object('mode','GRAPH','plan',p,'rows','[]'::jsonb,
                'error', format('no node matches key %L', p->>'arg'),
                'did_you_mean', coalesce((
                    select jsonb_agg(jsonb_build_object(
                               'key', f.key, 'entity_type', f.entity_type,
                               'score', f.score))
                    from aiq.lookup(p->>'arg', true, 5) f), '[]'::jsonb));
        elsif v_n > 1 then
            return jsonb_build_object('mode','GRAPH','plan',p,'rows','[]'::jsonb,
                'error', format(
                    '%L names %s nodes -- name the one you mean by its canonical key',
                    p->>'arg', v_n),
                'candidates', (
                    select jsonb_agg(jsonb_build_object(
                               'key', c.key, 'entity_type', c.entity_type,
                               'match_kind', c.match_kind))
                    from aiq.lookup(p->>'arg', false, 50) c));
        end if;

        -- Which node was walked, reported alongside the rows. A walk names its
        -- seed by key and answers by id, and the result carried neither -- so
        -- nothing downstream could check that the string it wrote resolved to
        -- the node it meant.
        select jsonb_build_object('node_id', s.node_id, 'key', s.key,
                                  'entity_type', s.entity_type,
                                  'match_kind', s.match_kind)
          into v_seed
          from aiq.lookup(p->>'arg', false, 1) s limit 1;

        if (p->>'depth')::int <= 1 then
            select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) into v_out
            from aiq.graph_neighbors(v_node, p->>'relation', (p->>'limit')::int) g;
        else
            select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) into v_out
            from aiq.graph_walk(v_node, (p->>'depth')::int, p->>'relation',
                                (p->>'limit')::int) w;
        end if;
        return jsonb_build_object('mode','GRAPH','plan',p,'seed',v_seed,'rows',v_out);

    when 'SEMANTIC' then
        -- The embedding is supplied by the caller, not computed here:
        -- embedding generation is an external model call, one of the few
        -- things structurally outside SQL (brief.md §4). The dialect carries
        -- the TEXT so the plan stays legible; the vector arrives alongside it.
        -- USING names the model, so the caller controls WHICH space is
        -- searched -- two 768-dim models are not interchangeable (§10).
        if p_embedding is null then
            raise exception
                'SEMANTIC requires p_embedding -- embed ''%'' with your model and pass the vector',
                p->>'arg';
        end if;
        -- `FROM <source>` is passed through, which it was not: the parser
        -- REQUIRES it on SEMANTIC and the dispatch dropped it, so every
        -- SEMANTIC query searched every registered corpus regardless of the
        -- one the caller was made to name. See semantic_in's own comment for
        -- what that leaked.
        select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_out
        from aiq.semantic_in(p->>'source', p_embedding, p->>'model',
                             (p->>'limit')::int) s;

    when 'TEXT' then
        -- Lexical only. Needs no embedding at all, which is exactly why it
        -- answers the rare-exact-token case (§11) that SEMANTIC misses.
        select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_out
        from aiq.lexical(p->>'source', p->>'arg', (p->>'limit')::int) l;

    when 'SEARCH' then
        if p_embedding is null then
            raise exception
                'SEARCH fuses lexical and semantic ranks, so it needs p_embedding. '
                'Use TEXT ''%'' for the lexical half alone.', p->>'arg';
        end if;
        select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) into v_out
        from aiq.search(p->>'source', p->>'arg', p_embedding, p->>'model',
                        (p->>'limit')::int) h;

    when 'SCHEMA' then
        -- The one mode that returns a document rather than rows, so it says
        -- `schema` rather than pretending to be a one-element result set.
        -- `arg` is '' rather than null when SCHEMA carried no facet -- the
        -- parser emits the first argument of a possibly-empty list -- and the
        -- index is what an empty facet means (§13c).
        return jsonb_build_object('mode','SCHEMA','plan', p,
            'schema', aiq.schema(nullif(p->>'arg', ''), p->>'source'));

    when 'SQL' then
        -- Deliberately NOT executed here. Returning the statement keeps this
        -- function's security mode irrelevant to it; the caller runs it
        -- through the SECURITY INVOKER, read-only-enforced passthrough
        -- (brief.md §3's correction).
        return jsonb_build_object('mode','SQL','statement', p->>'arg',
            'note','execute via the SECURITY INVOKER read-only passthrough, not here');
    else
        raise exception 'unhandled mode %', p->>'mode';
    end case;

    -- `unresolved` only appears where it means something. A key absent from
    -- the envelope is a mode that does not resolve names; a key present and
    -- empty is "every name you gave me resolved". Emitting it always, empty,
    -- for SEMANTIC and TEXT would make the second reading unavailable.
    return jsonb_build_object('mode', p->>'mode', 'plan', p, 'rows', v_out)
        || case when p->>'mode' = 'LOOKUP'
                then jsonb_build_object('unresolved', v_unresolved)
                else '{}'::jsonb end;
end;
$$ language plpgsql stable;

-- ============================================================
-- 10. Embedding spaces: multiple models, multiple dimensions.
--
-- THE CONSTRAINT, measured rather than assumed:
--   * `vector(n)` is fixed-width -- inserting 1536 dims into vector(768)
--     fails with "expected 768 dimensions, not 1536".
--   * An UNTYPED `vector` column DOES accept mixed dimensions, but cannot be
--     indexed at all: `create index ... using hnsw` fails with "column does
--     not have dimensions". So it is unusable for search -- every query
--     becomes a seq scan.
-- Therefore embeddings of different shapes MUST live in different columns
-- with their own indexes. There is no single-table shortcut.
--
-- THE CORRECTION worth stating: the partition key is the MODEL, not the
-- dimension. Two different 768-dimension models do not produce comparable
-- vectors -- cosine distance between them is meaningless, not merely
-- imprecise. Naming storage after the dimension alone (embedding_768) invites
-- exactly that mistake, because it makes two incompatible things look
-- interchangeable. Dimension is an ATTRIBUTE of a model here, never the
-- identity of a space.
--
-- One table per registered model, each with its own typed column and its own
-- HNSW index. A chunk may have rows in several of them simultaneously, which
-- is what makes migrating models (or A/B-ing them) possible without a
-- destructive rewrite: embed into the new space alongside the old, compare,
-- switch the default, drop the old space when nothing references it.
--
-- THE CONSEQUENCE FOR TENANCY, which is not obvious from any of the above and
-- was measured rather than reasoned: a space is keyed by MODEL, so it holds
-- every registered corpus's chunks together, and it has no way to know which
-- consumer table a chunk_id came from -- `chunk_id` deliberately carries no
-- foreign key, because one space serves many corpora. A generated space
-- therefore cannot carry a row policy of its own.
--
-- Two things follow, and only the first is fixed.
--
--  1. THE MODE MUST SCOPE ITSELF. aiq.semantic_in() joins the space to the
--     table registered under the corpus named in `FROM`, which both restricts
--     the search to that corpus and puts the consumer's policies in the path
--     (the mode is SECURITY INVOKER, so the join reads as the caller). Before
--     that join, SEMANTIC returned chunk ids and cosine distances for rows the
--     caller could not read: on the committed fixture, a caller holding org
--     B's claim saw five of six chunks and SEMANTIC returned all six.
--
--  2. THE SPACE ITSELF IS STILL READABLE, and this is a known, open exposure
--     rather than a decision. integration-rbac.sql grants SELECT on this
--     schema's tables -- and sets ALTER DEFAULT PRIVILEGES so spaces
--     registered later are covered -- precisely because the modes are SECURITY
--     INVOKER and must read them as the caller; withholding the grant would
--     break every SEMANTIC call. So `select * from aiq.emb_<model>` still
--     hands any authenticated caller chunk ids and raw vectors for content it
--     cannot read, and raw vectors are not innocuous (embedding inversion is a
--     published attack). Closing it needs per-source row policies generated
--     onto each space from aiq.semantic_sources, refreshed as corpora are
--     registered. That is real machinery and it is not built.
--     dev/tests/query/09 §5 pins the current state so that building it is a
--     deliberate act that updates this paragraph.
-- ============================================================

create table aiq.embedding_models (
    name        text primary key,          -- 'nomic-embed-text', 'text-embedding-3-small'
    dim         int  not null check (dim > 0),
    provider    text not null,             -- 'ollama' | 'openai' | ...
    -- Resolved by the WORKER, not called from SQL -- and it may be written as
    -- a `{{env.X}}` reference ('{{env.LLM_URL}}/api/embeddings'), because the
    -- worker resolves that namespace and the database deliberately cannot.
    -- That is what lets one registry row serve dev, staging and production
    -- without a per-deployment UPDATE.
    endpoint    text,
    -- The env var name the worker reads a bearer token from, for a hosted
    -- provider. Never the token: a secret in a table is a secret in every
    -- backup, every logical replica and every pg_dump.
    credential_ref text,
    distance_op text not null default 'vector_cosine_ops'
                    check (distance_op in ('vector_cosine_ops','vector_l2_ops','vector_ip_ops')),
    is_default  boolean not null default false,
    notes       text,
    created_at  timestamptz not null default now()
);

-- Exactly one default at a time. A partial unique index rather than a trigger:
-- the database enforces it, so a bad deploy fails loudly instead of leaving
-- two defaults and a coin-flip about which one SEMANTIC uses.
create unique index idx_embedding_models_one_default
    on aiq.embedding_models ((true)) where is_default;

-- ------------------------------------------------------------
-- 10a. What an embedding CALL looks like -- one row per provider.
--
-- `provider` above was a label: it recorded which service produced a space and
-- nothing could act on it. Everything needed to actually make the call -- the
-- request body's shape and where the vector sits in the response -- lived in
-- whatever YAML an author happened to write, which is how two workflows in one
-- deployment end up embedding differently against the same model.
--
-- It is a TABLE rather than code in the worker for the reason the rest of this
-- collection is tables: a new provider is then a row, insertable by a
-- deployment that cannot rebuild an image. Both shipped rows were written from
-- the providers' published request formats; a deployment whose gateway differs
-- overrides the row rather than forking anything.
--
-- The template is deliberately ONE LEVEL DEEP, and that is a limit worth
-- naming rather than discovering: `{{model}}` and `{{text}}` are substituted
-- as whole VALUES of top-level keys, never inside a longer string. Substituting
-- into arbitrary nested JSON text would mean escaping author-supplied text into
-- a JSON literal by hand, and hand-rolled JSON escaping is a defect waiting for
-- a quote character. Both providers' bodies are flat objects, so the limit
-- costs nothing today and fails loudly rather than silently if it ever does.
--
-- `{{text}}` may itself arrive holding a workflow template ('{{run.question}}')
-- -- it is left intact, and the worker resolves it at dispatch like any other
-- REST body. Two template layers, resolved in the right order by the two halves
-- that own them.
-- ------------------------------------------------------------
create table aiq.embedding_providers (
    provider         text primary key,
    request_template jsonb not null,
    response_path    text  not null,   -- dotted path, the worker's `jsonpath`
    method           text  not null default 'POST',
    notes            text
);

insert into aiq.embedding_providers (provider, request_template, response_path, notes) values
    ('ollama', '{"model": "{{model}}", "prompt": "{{text}}"}'::jsonb, 'embedding',
     'POST /api/embeddings -- one vector, at the top level under "embedding".'),
    ('openai', '{"model": "{{model}}", "input": "{{text}}"}'::jsonb, 'data.0.embedding',
     'POST /v1/embeddings -- a list, because the API embeds a batch; a single '
     'text still comes back as data[0]. Needs credential_ref on the model row.')
on conflict (provider) do nothing;

-- Each registered model gets its own storage table + HNSW index, generated
-- from the registry so the dimension and operator class can never drift from
-- what the model actually produces.
create or replace function aiq.register_embedding_space(p_model text)
returns void as $$
declare m aiq.embedding_models;
begin
    select * into m from aiq.embedding_models where name = p_model;
    if not found then raise exception 'embedding model % not registered -- SCHEMA "graph" lists the registered ones', p_model; end if;

    execute format($q$
        create table if not exists aiq.%1$I (
            chunk_id   uuid primary key,
            embedding  vector(%2$s) not null,
            embedded_at timestamptz not null default now()
        )$q$, 'emb_' || replace(m.name, '-', '_'), m.dim);

    execute format($q$
        create index if not exists %1$I on aiq.%2$I
        using hnsw (embedding %3$s)$q$,
        'idx_' || replace(m.name,'-','_') || '_hnsw',
        'emb_' || replace(m.name, '-', '_'), m.distance_op);
end;
$$ language plpgsql;

-- SEMANTIC against a named corpus and a named model (or the default model when
-- null). The caller still supplies the vector -- embedding generation is an
-- external model call (§4), and which model produced that vector is now
-- explicit rather than implied.
--
-- THE SOURCE IS FIRST AND IT IS NOT OPTIONAL, and that is a security fix, not
-- a signature preference.
--
-- This function took (vector, model, limit) and searched the whole embedding
-- space. The space is keyed by MODEL, not by corpus, so it holds every
-- registered corpus's chunks together; and `aiq.emb_*` tables carry no
-- row-level policy, because a generated space has no way to know which
-- consumer table a chunk_id came from. So the mode returned chunk ids and
-- cosine distances for rows the caller could not read.
--
-- Measured, on the committed fixture: a caller holding org B's claim can see
-- five of six chunks -- content's own RLS correctly hides org A's memo -- and
-- SEMANTIC returned all six, org A's memo included, at rank three. The text
-- did not come back, but the id, the existence and the similarity did, and a
-- similarity oracle over private content that answers an arbitrary probe
-- vector is the whole attack, not a precursor to it.
--
-- The dialect made this worse rather than causing it: the parser REQUIRES
-- `FROM <source>` on SEMANTIC ("SEMANTIC, TEXT and SEARCH each require FROM
-- <source>"), and the dispatch then dropped it on the floor and searched
-- everything. The caller was compelled to name a corpus that was not used.
--
-- The fix is the join, and it fixes both halves at once: joining the space to
-- the registered source table scopes the search to the corpus the caller
-- named, AND puts the consumer's own RLS in the path, because this function is
-- SECURITY INVOKER and the join reads as the caller.
--
-- The cost is honest to state: an HNSW scan feeding a join that may discard
-- rows means the index can be walked further than `limit` rows to fill the
-- result. That is the price of a filtered vector search and it is the correct
-- price to pay; the alternative is a fast wrong answer.
--
-- What this does NOT fix, and what dev/tests/query/09 pins: `aiq.emb_*` is
-- still directly SELECT-able by `authenticated`, because integration-rbac.sql
-- grants the schema's tables so that SECURITY INVOKER modes can read them. A
-- caller who queries the space directly still sees chunk ids and raw vectors
-- for content they cannot read. Closing that needs per-source policies on
-- generated spaces, which is real machinery and is not built.
drop function if exists aiq.semantic_in(vector, text, int);
create or replace function aiq.semantic_in(
    p_source text, p_query vector, p_model text default null, p_limit int default 10
) returns table(chunk_id uuid, distance float8, model text) as $$
declare
    m aiq.embedding_models;
    src aiq.semantic_sources;
    v_tbl text;
begin
    if p_source is null then
        raise exception
            'SEMANTIC needs the corpus it is searching -- name one with '
            'FROM <source>. Without it a vector search reads every registered '
            'corpus and cannot be filtered by the consumer''s own policies.';
    end if;
    select * into src from aiq.semantic_sources where name = p_source;
    if not found then
        raise exception 'semantic source % not registered -- SCHEMA "graph" lists the registered ones', p_source;
    end if;
    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then raise exception
            'no default embedding model -- set one, or name a model explicitly'; end if;
    else
        select * into m from aiq.embedding_models where name = p_model;
        if not found then raise exception 'embedding model % not registered -- SCHEMA "graph" lists the registered ones', p_model; end if;
    end if;

    -- Dimension mismatch is caught HERE with a message naming both sides,
    -- rather than surfacing as pgvector's bare "expected N dimensions".
    -- Querying the wrong space is the single easiest mistake to make once
    -- more than one model exists.
    if vector_dims(p_query) <> m.dim then
        raise exception
            'query vector has % dimensions but model % expects % -- embedded with the wrong model?',
            vector_dims(p_query), m.name, m.dim;
    end if;

    -- The join is the filter. `c` is the consumer's table, read as the caller,
    -- so the consumer's policies decide which chunks may rank at all -- and
    -- ranks are computed after it, so a chunk the caller cannot see does not
    -- silently occupy a position and shift everyone else's fused score.
    v_tbl := 'emb_' || replace(m.name, '-', '_');
    return query execute format(
        'select e.chunk_id, (e.embedding <=> $1)::float8, %L
         from aiq.%I e
         join %s c on c.id = e.chunk_id
         order by e.embedding <=> $1 limit $2', m.name, v_tbl, src.source_table)
        using p_query, p_limit;
end;
$$ language plpgsql stable;

-- ============================================================
-- 11. Lexical search -- the mode that was missing entirely.
--
-- THE GAP, demonstrated rather than argued: the dialect had LOOKUP (exact
-- keys), FUZZY (trigram over KEYS), SEMANTIC (vectors) and GRAPH -- and
-- nothing that searches document TEXT lexically. Asking for the part number
-- "R7", which appears verbatim in a chunk:
--     LOOKUP 'R7'        -> 0 hits   (node_keys only; chunks are not nodes)
--     LOOKUP 'R7' FUZZY  -> 0 hits   (trigram over keys, not content)
--     native FTS         -> found it immediately
-- Rare exact tokens -- part numbers, tickers, error codes, case IDs, proper
-- nouns -- are precisely where embeddings are weakest and lexical search is
-- strongest, which is why production RAG is near-universally hybrid. We had
-- only half of it.
--
-- Native tsvector/ts_rank, NOT BM25, and the difference is worth being honest
-- about: ts_rank uses its own length-normalisation and has no k1/b term
-- saturation, so a term occurring 20 times keeps accruing score in a way BM25
-- deliberately damps. For short chunks the practical difference is small; for
-- long documents with repeated terms it is not.
--
-- Chosen as the DEFAULT anyway because it is permissive-licensed, already in
-- core Postgres, costs one GIN index and zero new dependencies. pg_search
-- (ParadeDB, real BM25) is the promote-on-evidence upgrade -- see
-- meta/postgres-manifest.md for its AGPLv3 posture, which is the one
-- non-permissive license in the collection and deserves a deliberate decision
-- rather than a default.
-- ============================================================

create table aiq.lexical_sources (
    name         text primary key,
    source_table text not null,
    content_col  text not null default 'content',
    regconfig    text not null default 'english'
);

-- A generated tsvector column + GIN index is the standard shape: the vector
-- is maintained by Postgres on write, never by application code that can
-- forget, and the index is what makes it a search rather than a scan.
create or replace function aiq.register_lexical_source(
    p_name text, p_source_table text,
    p_content_col text default 'content', p_regconfig text default 'english'
) returns void as $$
declare v_short text := split_part(p_source_table, '.', 2);
begin
    insert into aiq.lexical_sources (name, source_table, content_col, regconfig)
    values (p_name, p_source_table, p_content_col, p_regconfig)
    on conflict (name) do update set source_table = excluded.source_table,
        content_col = excluded.content_col, regconfig = excluded.regconfig;

    execute format(
        'alter table %s add column if not exists search_tsv tsvector
         generated always as (to_tsvector(%L, coalesce(%I, ''''))) stored',
        p_source_table, p_regconfig, p_content_col);
    execute format(
        'create index if not exists %I on %s using gin (search_tsv)',
        'idx_' || v_short || '_tsv', p_source_table);
end;
$$ language plpgsql;

-- TEXT mode. Deliberately returns the same (id, score) shape as
-- aiq.semantic_in() so the two can be fused without reshaping either.
create or replace function aiq.lexical(
    p_source text, p_query text, p_limit int default 10
) returns table(chunk_id uuid, content text, score real) as $$
declare s aiq.lexical_sources;
begin
    select * into s from aiq.lexical_sources where name = p_source;
    if not found then raise exception 'lexical source % not registered -- SCHEMA "graph" lists the registered ones', p_source; end if;
    return query execute format(
        'select c.id, c.%I::text, ts_rank(c.search_tsv, plainto_tsquery(%L, $1))::real
         from %s c where c.search_tsv @@ plainto_tsquery(%L, $1)
         order by ts_rank(c.search_tsv, plainto_tsquery(%L, $1)) desc limit $2',
        s.content_col, s.regconfig, s.source_table, s.regconfig, s.regconfig)
        using p_query, p_limit;
end;
$$ language plpgsql stable;

-- SEARCH: reciprocal rank fusion of lexical + semantic.
--
-- RRF rather than score-weighted blending, deliberately: ts_rank and cosine
-- distance are not on the same scale, not even the same direction (higher is
-- better vs lower is better), and no fixed normalisation of the two survives a
-- change of model or corpus. RRF only uses RANK, so it is invariant to both.
-- k=60 is the value from the original RRF paper and the common default; it
-- damps the contribution of low-ranked items without a tunable that needs
-- per-corpus fitting.
--
-- This is the mode that answers the "R7" case AND "is this product
-- dangerous?" with one call -- which is the actual argument for a unified
-- dialect over three separate APIs.
create or replace function aiq.search(
    p_lexical_source text, p_query_text text,
    p_query_vector vector, p_model text default null,
    p_limit int default 10, p_k int default 60
) returns table(chunk_id uuid, content text, rrf_score real,
                lexical_rank int, semantic_rank int) as $$
declare
    src aiq.lexical_sources;
begin
    select * into src from aiq.lexical_sources where name = p_lexical_source;
    if not found then
        raise exception 'lexical source % not registered -- SCHEMA "graph" lists the registered ones', p_lexical_source;
    end if;

    return query execute format($q$
    with lex as (
        select l.chunk_id, row_number() over (order by l.score desc)::int as rnk
        from aiq.lexical($1, $2, $4 * 4) l
    ),
    sem as (
        -- The SAME source name feeds both halves, so `SEARCH "..." FROM x`
        -- means one corpus and not two. It must therefore be registered in
        -- both registries; the semantic branch says so by name if it is not.
        select s.chunk_id, row_number() over (order by s.distance asc)::int as rnk
        from aiq.semantic_in($1, $3, $6, $4 * 4) s
    )
    -- Content is fetched by id AFTER the fusion, not carried through the
    -- lexical branch: a chunk matched only semantically has no row in `lex`,
    -- so taking content from there returns NULL for exactly the results the
    -- semantic side contributed. Found by running it -- the fused output had
    -- blank content for every vector-only hit.
    select f.chunk_id, c.%1$I::text, f.rrf, f.lexical_rank, f.semantic_rank
    from (
        select coalesce(lex.chunk_id, sem.chunk_id) as chunk_id,
               (coalesce(1.0 / ($5 + lex.rnk), 0)
                + coalesce(1.0 / ($5 + sem.rnk), 0))::real as rrf,
               lex.rnk as lexical_rank, sem.rnk as semantic_rank
        from lex full outer join sem on sem.chunk_id = lex.chunk_id
    ) f
    join %2$s c on c.id = f.chunk_id
    order by f.rrf desc
    limit $4
    $q$, src.content_col, src.source_table)
    using p_lexical_source, p_query_text, p_query_vector, p_limit, p_k, p_model;
end;
$$ language plpgsql stable;

-- ------------------------------------------------------------
-- 12. The SQL escape hatch, actually implemented.
--
-- §9 returned the statement and told the caller to run it "via the SECURITY
-- INVOKER read-only passthrough" -- which did not exist. Written now, because
-- a spec that names a component it never defines is exactly the kind of gap
-- these prototype rounds keep finding.
--
-- SECURITY INVOKER, not DEFINER (brief.md §3's correction): this function
-- executes caller-supplied SQL, so DEFINER would make it an RLS-bypass and
-- privilege-escalation primitive -- the same class of bug as workflow's
-- cancel_run and rbac's grant_role, and the reason those were fixed.
--
-- Read-only is enforced by the DATABASE, not by inspecting the string. A
-- parser that tries to decide whether SQL is "read-only" is a filter to be
-- bypassed; a read-only transaction is a guarantee. Any write, DDL, or
-- function with a side effect raises inside the block and the whole thing
-- aborts.
-- ------------------------------------------------------------
create or replace function aiq.sql_passthrough(p_statement text)
returns jsonb as $$
declare
    v_result jsonb;
begin
    -- Rejected up front only for the things that are unambiguous and cheap to
    -- catch, giving a clear error instead of a confusing transaction abort.
    -- This is a courtesy, NOT the security boundary -- the read-only
    -- transaction below is.
    if p_statement ~* '^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy)\M' then
        raise exception
            'the SQL passthrough is read-only: statement starts with a write/DDL keyword';
    end if;

    -- The actual boundary. set_config(..., true) is transaction-local, so it
    -- reverts on commit or rollback and cannot leak into a pooled connection's
    -- next transaction -- the same pooling hazard rbac.current_user_id() was
    -- hardened against.
    perform set_config('transaction_read_only', 'on', true);

    execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement)
    into v_result;

    return v_result;
end;
$$ language plpgsql volatile security invoker;

-- ============================================================
-- 13. `SCHEMA` -- the mode that answers "what IS this database".
--
-- Every other mode requires you to already know something: a key to look up,
-- a source to search, a relation to walk. An agent arriving cold can write
-- none of them. `SCHEMA` is the one query answerable before you know
-- anything, and bare `SCHEMA` returns the index of what you may ask about.
--
-- The reason to build it here rather than hand agents markdown: the registries
-- it reports on ALREADY EXIST and are already the truth --
-- `aiq.entity_registry`, `aiq.relation_types`, `aiq.semantic_sources`,
-- `aiq.lexical_sources`, `aiq.embedding_models`, `workflow.step_functions`,
-- `agentic.agents`. Every one of them is a table a caller could read if it
-- knew to. Nothing joins them into one caller-facing surface, and the failure
-- that costs is visible in this file's own error messages: `semantic source %
-- not registered` tells you the name was wrong and nothing about which names
-- are right.
--
-- THREE COMMITMENTS, each of which is what makes this a capability report
-- rather than documentation:
--
--   1. DERIVED BEATS DECLARED, AND THE SPLIT IS VISIBLE. Anything the catalog
--      can prove is read from the catalog -- the legal `kind` values come off
--      the check constraint, the callable functions off the allow-list, the
--      relation catalogue off the table that enforces it. What a catalog
--      cannot express (what a `matrix` step is FOR, how the YAML is spelled)
--      is emitted by the Rust crate that implements it, so the grammar an
--      agent reads is the grammar that parses its input. Every facet reports
--      both halves under `derived` and `declared`, so a reader knows which
--      half could go stale.
--
--   2. EXAMPLES ARE VERIFIED BY EXECUTION, NOT TRUSTED. The example corpus is
--      a table, and every read feeds each example back through the real parser
--      (`aiq_parse`) or the real compiler (`p8_compile_workflow`) and reports
--      what it did. An example that stops parsing says so on its own row
--      rather than teaching an agent a syntax this deployment no longer
--      accepts. This is the same discipline `../../surface.sql` applies to
--      capabilities, applied to the sentences that describe them.
--
--   3. THE VERSION IS A HASH, NOT A NUMBER SOMEBODY REMEMBERS TO BUMP.
--      `aiq.schema_revisions` records one row per facet per distinct content
--      hash, so "versioned and maintained with updates" is literal: registering
--      a step function, adding a relation type or shipping a new step kind
--      changes the hash, and capture writes a new revision you can diff
--      against the last. A hand-maintained semver would be a second thing to
--      keep true, and this collection's whole method is to not have those.
--
-- A FACET IS A REGISTRATION, NOT A BRANCH. `SCHEMA "tradecraft"` over
-- `tradecraft.likelihood`/`evidence_classes`/`source_reliability`, or a facet
-- over `content.v_required_credentials`, needs an INSERT and a function --
-- never a change to the parser or to this dispatch. That is the extensibility
-- the "soft schema we might add later" case actually requires, and it is the
-- second-consumer evidence that justifies a registry over a CASE statement.
-- ============================================================

create table if not exists aiq.schema_facets (
    name          text primary key,          -- what SCHEMA "<name>" names
    provider_fn   text not null,             -- schema-qualified, (text) -> jsonb
    title         text not null,
    description   text not null,
    -- A GLOBAL facet describes the deployment and reads the same for
    -- everyone, so its provider is SECURITY DEFINER over metadata tables no
    -- user role holds a grant on. A CALLER-SCOPED facet describes what YOU can
    -- reach, so its provider must be SECURITY INVOKER -- a schema document
    -- listing tables the reader cannot select from is both a leak and a lie.
    caller_scoped boolean not null default false,
    registered_at timestamptz not null default now()
);

-- Owner-only, and for the same reason workflow.register_step_function is: it
-- decides what a `SCHEMA` query can cause to run.
create or replace function aiq.register_schema_facet(
    p_name text, p_fn text, p_title text, p_description text,
    p_caller_scoped boolean default false
) returns void as $$
begin
    if to_regprocedure(p_fn || '(text)') is null then
        raise exception
            'schema facet provider %(text) does not exist. A provider takes the optional '
            'FROM argument (null when absent) and returns jsonb.', p_fn;
    end if;
    insert into aiq.schema_facets (name, provider_fn, title, description, caller_scoped)
    values (lower(p_name), p_fn, p_title, p_description, p_caller_scoped)
    on conflict (name) do update set provider_fn = excluded.provider_fn,
        title = excluded.title, description = excluded.description,
        caller_scoped = excluded.caller_scoped;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 13a. The example corpus -- data, and checked by running it.
--
-- Few-shot examples are the single most useful thing a schema document can
-- give an agent, and the single most likely thing to go quietly wrong: an
-- example written against an older dialect keeps being served, keeps looking
-- authoritative, and teaches a syntax that now fails. So examples are rows,
-- and every read executes them.
--
-- `kind` says which executor verifies it. Adding a third (a p8ql fragment, a
-- cron expression, a JSON spec) is a new branch in aiq.verify_example and
-- nothing else.
-- ------------------------------------------------------------
create table if not exists aiq.schema_examples (
    facet     text not null references aiq.schema_facets(name) on delete cascade,
    label     text not null,
    kind      text not null check (kind in ('p8ql', 'workflow_yaml')),
    example   text not null,
    note      text,
    ordinal   int  not null default 100,
    primary key (facet, label)
);

create or replace function aiq.register_schema_example(
    p_facet text, p_label text, p_kind text, p_example text,
    p_note text default null, p_ordinal int default 100
) returns void as $$
    insert into aiq.schema_examples (facet, label, kind, example, note, ordinal)
    values (lower(p_facet), p_label, p_kind, p_example, p_note, p_ordinal)
    on conflict (facet, label) do update set kind = excluded.kind,
        example = excluded.example, note = excluded.note, ordinal = excluded.ordinal;
$$ language sql;

-- Run one example through the thing that actually consumes it.
--
-- `verified` is three-valued on purpose. true/false is a claim about the
-- example; null means "this deployment cannot check" -- which is what you get
-- when the extension is older than the example's kind. Collapsing null into
-- false would report a correct example as broken every time the .so lags the
-- schema, and collapsing it into true would report an unchecked example as
-- proven. Neither is the truth, so neither is what is returned.
create or replace function aiq.verify_example(p_kind text, p_example text)
returns jsonb as $$
declare v jsonb;
begin
    if p_kind = 'p8ql' then
        if to_regprocedure('aiq_parse(text)') is null then
            return jsonb_build_object('verified', null,
                'note', 'aiq_parse is unavailable -- the p8_query extension is not installed');
        end if;
        v := aiq_parse(p_example);
        return jsonb_build_object('verified', coalesce((v->>'ok')::boolean, false),
                                  'plan', v);
    elsif p_kind = 'workflow_yaml' then
        if to_regprocedure('p8_compile_workflow(text)') is null then
            return jsonb_build_object('verified', null,
                'note', 'p8_compile_workflow is unavailable -- the percolate extension is not installed');
        end if;
        v := p8_compile_workflow(p_example);
        return jsonb_build_object('verified', coalesce((v->>'ok')::boolean, false),
                                  'compiles_to', v->'workflow'->'spec',
                                  'error', v->>'error');
    end if;
    raise exception 'unknown example kind %', p_kind;
end;
$$ language plpgsql stable;

create or replace function aiq.facet_examples(p_facet text)
returns jsonb as $$
    select coalesce(jsonb_agg(
        jsonb_build_object('label', e.label, 'kind', e.kind, 'example', e.example,
                           'note', e.note)
        || aiq.verify_example(e.kind, e.example)
        order by e.ordinal, e.label), '[]'::jsonb)
    from aiq.schema_examples e where e.facet = p_facet;
$$ language sql stable;

-- ------------------------------------------------------------
-- 13b. Revisions -- what "versioned and maintained with updates" means here.
--
-- Reads never write. A schema query is on the read path and must stay
-- `stable`; recording a revision from it would also mean a poll loop writes a
-- row every time nothing has changed. So capture is a separate, deliberate
-- act -- `aiq.capture_schema_revisions()` -- run from CI next to
-- ../../surface.sql, or as a scheduled workflow, or by hand after a
-- migration.
--
-- The consequence is the interesting part: a read can find that the live hash
-- differs from the last recorded revision, and it SAYS SO (`captured: false`)
-- rather than silently serving an uncaptured document as if it were versioned.
-- That is the drift signal. An agent that caches by hash still gets a correct
-- answer; an operator watching `aiq.schema_drift()` learns the schema moved
-- and nobody recorded it.
-- ------------------------------------------------------------
create table if not exists aiq.schema_revisions (
    facet       text not null references aiq.schema_facets(name) on delete cascade,
    revision    int  not null,
    hash        text not null,
    doc         jsonb not null,
    captured_at timestamptz not null default now(),
    primary key (facet, revision)
);
create index if not exists idx_schema_revisions_hash on aiq.schema_revisions (facet, hash);

-- The one place a facet is produced, so hashing, scoping and the FROM
-- argument cannot be done three slightly different ways.
--
-- The hash covers the document only -- not the revision, not the timestamp --
-- because it has to be comparable across captures. Timestamps in a hashed
-- payload make every capture a new revision, which is a changelog of nothing.
create or replace function aiq.render_facet(p_facet text, p_name text default null)
returns jsonb as $$
declare
    f    aiq.schema_facets;
    v    jsonb;
begin
    select * into f from aiq.schema_facets where name = lower(p_facet);
    if not found then
        raise exception
            'no schema facet named %. Registered facets: %',
            p_facet,
            coalesce((select string_agg(name, ', ' order by name) from aiq.schema_facets),
                     '(none)');
    end if;
    execute format('select %s($1)', f.provider_fn) into v using p_name;
    return coalesce(v, '{}'::jsonb);
end;
$$ language plpgsql stable;

-- Record a revision for every facet whose content hash has moved. Returns the
-- facets it captured, so a CI step can print what changed rather than only
-- that something did.
--
-- Caller-scoped facets are captured as the OWNER sees them, and that is the
-- honest definition: the revision describes what this DATABASE is, while a
-- caller's read describes what that caller can reach. A read of a
-- caller-scoped facet therefore carries `scoped: true` next to the global
-- revision, so nobody mistakes the hash for a hash of what they received.
create or replace function aiq.capture_schema_revisions()
returns table (facet text, revision int, hash text) as $$
declare
    f      aiq.schema_facets;
    v_doc  jsonb;
    v_hash text;
    v_last text;
    v_rev  int;
begin
    for f in select * from aiq.schema_facets order by name loop
        v_doc  := aiq.render_facet(f.name, null);
        v_hash := md5(v_doc::text);

        select r.hash into v_last from aiq.schema_revisions r
        where r.facet = f.name order by r.revision desc limit 1;

        if v_last is distinct from v_hash then
            select coalesce(max(r.revision), 0) + 1 into v_rev
            from aiq.schema_revisions r where r.facet = f.name;
            insert into aiq.schema_revisions (facet, revision, hash, doc)
            values (f.name, v_rev, v_hash, v_doc);
            facet := f.name; revision := v_rev; hash := v_hash;
            return next;
        end if;
    end loop;
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

-- Which facets have moved since anyone recorded them. The read-only half of
-- capture, so a CI gate can fail on drift without writing anything.
create or replace function aiq.schema_drift()
returns table (facet text, live_hash text, recorded_hash text, recorded_at timestamptz) as $$
    select f.name,
           md5(aiq.render_facet(f.name, null)::text),
           r.hash,
           r.captured_at
    from aiq.schema_facets f
    left join lateral (
        select hash, captured_at from aiq.schema_revisions
        where facet = f.name order by revision desc limit 1) r on true
    where r.hash is distinct from md5(aiq.render_facet(f.name, null)::text)
    order by f.name;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13c. The read. `SCHEMA` with no argument is the index.
--
-- SECURITY INVOKER, deliberately: a caller-scoped provider has to see the
-- caller. Everything it reads directly (the three tables above) is deployment
-- metadata already granted to `authenticated`, the same way
-- aiq.entity_registry and workflow.step_functions already are.
-- ------------------------------------------------------------
create or replace function aiq.schema(p_facet text default null, p_name text default null)
returns jsonb as $$
declare
    f      aiq.schema_facets;
    v_doc  jsonb;
    v_hash text;
    r      record;
begin
    -- The index. Deliberately cheap -- it does NOT render every facet to
    -- report their hashes, because rendering the whole deployment to answer
    -- "what may I ask about" would make the one query an agent writes first
    -- the most expensive one it ever writes.
    if p_facet is null or btrim(p_facet) = '' then
        return jsonb_build_object(
            'facet', null,
            'facets', coalesce((
                select jsonb_agg(jsonb_build_object(
                    'name', f2.name, 'title', f2.title, 'description', f2.description,
                    'caller_scoped', f2.caller_scoped,
                    -- Double quotes: %L would emit the single-quoted form,
                    -- which parses but is not how the dialect is written down
                    -- anywhere else, and an index whose copy-paste spelling
                    -- differs from the documentation teaches a second dialect.
                    'query', format('SCHEMA "%s"', f2.name),
                    'revision', (select max(revision) from aiq.schema_revisions
                                 where facet = f2.name))
                order by f2.name) from aiq.schema_facets f2), '[]'::jsonb),
            'note', 'Ask for one with SCHEMA "<name>". Some facets narrow with FROM, '
                    'e.g. SCHEMA "sql" FROM chunks.');
    end if;

    select * into f from aiq.schema_facets where name = lower(p_facet);
    if not found then
        raise exception
            'no schema facet named %. Write SCHEMA with no argument for the list.', p_facet;
    end if;

    v_doc  := aiq.render_facet(f.name, p_name);
    v_hash := md5(v_doc::text);

    select revision, hash, captured_at into r from aiq.schema_revisions
    where facet = f.name order by revision desc limit 1;

    return jsonb_build_object(
        'facet',       f.name,
        'title',       f.title,
        'description', f.description,
        'narrowed_to', p_name,
        -- For a global facet these agree or the schema has moved since the
        -- last capture. For a caller-scoped one they are not expected to
        -- agree at all, which is exactly what `scoped` says.
        'scoped',      f.caller_scoped,
        'hash',        v_hash,
        'revision',    r.revision,
        'captured_at', r.captured_at,
        'captured',    case when f.caller_scoped then null
                            else (r.hash is not distinct from v_hash) end,
        'doc',         v_doc);
end;
$$ language plpgsql stable security invoker;

-- ------------------------------------------------------------
-- 13d. Facet: p8ql -- the dialect, described by what parses it.
--
-- The declared half comes from `p8_query_grammar()` in the parser crate, so
-- there is exactly one copy of the grammar and it lives next to the code that
-- implements it. When the extension predates that function the facet says so
-- by name and still returns the examples, which are verified against the
-- parser that IS installed -- so the useful half never depends on the
-- packaging step.
-- ------------------------------------------------------------
create or replace function aiq.schema_p8ql(p_name text default null)
returns jsonb as $$
declare v_grammar jsonb;
begin
    if to_regprocedure('p8_query_grammar()') is null then
        v_grammar := jsonb_build_object('unavailable',
            'p8_query_grammar() is not in the installed extension -- the grammar prose '
            'ships with the parser, so this deployment''s .so predates it. The examples '
            'below are still verified against the parser that IS installed.');
    else
        execute 'select p8_query_grammar()' into v_grammar;
    end if;

    return jsonb_build_object(
        'declared', v_grammar,
        'derived', jsonb_build_object(
            'parser_installed', to_regprocedure('aiq_parse(text)') is not null,
            -- Which corpora the content-searching modes may name in FROM.
            -- These are the registries whose "not registered" errors do not
            -- list the alternatives; this is where the alternatives live.
            'text_sources',     coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name, 'regconfig', regconfig) order by name)
                                 from aiq.lexical_sources), '[]'::jsonb),
            'semantic_sources', coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name) order by name)
                                 from aiq.semantic_sources), '[]'::jsonb),
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name, 'dim', dim, 'provider', provider,
                                    'is_default', is_default) order by name)
                                 from aiq.embedding_models), '[]'::jsonb)),
        'examples', aiq.facet_examples('p8ql'));
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13e. Facet: workflow -- enough to author one unaided.
--
-- The derived half is the part that matters and the part that cannot drift.
-- `step_kinds` is read off the CHECK CONSTRAINT rather than listed, so
-- shipping a new kind (as `matrix` was) updates this document with no edit
-- here; `step_functions` is the allow-list itself, with the real registered
-- signatures, so an agent writing a `sql:` step is reading the same row the
-- executor will look the function up in.
--
-- SECURITY DEFINER because workflow.queue_config and agentic.agents hold no
-- grants for user roles. Only names and shapes are returned -- no run, task or
-- session data crosses this boundary. Queue and agent names are deployment
-- topology, and an agent that cannot see them cannot author a step that
-- routes anywhere.
-- ------------------------------------------------------------
create or replace function aiq.schema_workflow(p_name text default null)
returns jsonb as $$
declare
    v_grammar jsonb;
    v_kinds   text[];
    v_def     text;
begin
    if to_regprocedure('p8_workflow_grammar()') is null then
        v_grammar := jsonb_build_object('unavailable',
            'p8_workflow_grammar() is not in the installed extension. The step vocabulary '
            'ships with the compiler that reads it; this deployment''s .so predates it. '
            'The derived half below is complete, and the examples are compiled against '
            'the compiler that IS installed.');
    else
        execute 'select p8_workflow_grammar()' into v_grammar;
    end if;

    -- Off the constraint, not off a list. `kind in ('work','decision',...)`
    -- becomes an array of the quoted literals inside it.
    select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'workflow' and t.relname = 'tasks' and c.conname = 'tasks_kind_check';

    if v_def is not null then
        select array_agg(m[1] order by ord) into v_kinds
        from regexp_matches(v_def, '''([a-z_]+)''', 'g') with ordinality as x(m, ord);
    end if;

    return jsonb_build_object(
        'declared', v_grammar,
        'derived', jsonb_build_object(
            -- SUPPORTED vs AUTHORABLE, and the split was found the hard way.
            -- step_kinds is derived from the engine's check constraint, so it
            -- was true about the ENGINE and false about what a person can
            -- write: an agent read all eight kinds as legal, authored a
            -- `signal` step, and the compiler refused it. Deriving from the
            -- catalog protects against drift; it does not protect against
            -- describing the wrong layer. A capability document has to be
            -- derived from the layer the reader will act THROUGH.
            'step_kinds', coalesce(to_jsonb(v_kinds), '[]'::jsonb),
            -- Not a list of what the compiler is SUPPOSED to accept -- what
            -- the installed one actually does, probed with a canary per
            -- feature. The two halves of this system can ship out of step, and
            -- when they do the compile error describes a syntax problem in a
            -- document whose syntax is correct. Someone lost an afternoon to
            -- that; this is so nobody loses a second.
            'compiler', workflow.compiler_capabilities(),
            'authorable_in_yaml', to_jsonb(array[
                'work','sql','http_call','matrix','signal','timer','sub_workflow']),
            'engine_only', coalesce((
                select jsonb_agg(k) from unnest(v_kinds) k
                where k <> all(array['work','sql','http_call','matrix',
                                     'signal','timer','sub_workflow'])), '[]'::jsonb),
            'kinds_note', 'step_kinds is what the ENGINE accepts; authorable_in_yaml is '
                          'what the compiler accepts. Anything in engine_only is reachable '
                          'only by inserting a spec as JSON.',
            'step_functions', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'arg_types', to_jsonb(arg_types),
                    'timeout_ms', timeout_ms, 'description', description) order by name)
                from workflow.step_functions), '[]'::jsonb),
            -- QUEUES ARE UNIONED FROM THREE PLACES, and the first version read
            -- only queue_config. Running a real fan-out exposed why that was
            -- useless: queue_config holds per-queue TUNING and is empty on a
            -- deployment that has not tuned anything, so the facet reported
            -- `queues: []` on a database with a live worker polling `http`.
            -- An agent authoring a `rest:` step was told the one queue that
            -- works does not exist.
            --
            -- A queue is not a registry entry; it is a string a worker polls
            -- and a step names. So the honest answer is every queue anything
            -- has actually used, with where each was learned from -- and the
            -- explicit caveat that a worker which has never claimed anything
            -- is invisible here, because nothing in the database knows it
            -- exists.
            'queues', coalesce((
                select jsonb_agg(jsonb_build_object('queue', q.queue, 'seen_in', q.src)
                       order by q.queue)
                from (
                    select queue, min(src) as src from (
                        select queue, 'queue_config (tuned)' as src from workflow.queue_config
                        union all
                        select distinct queue, 'in use by tasks' from workflow.tasks
                        where queue <> 'none'
                    ) u group by queue
                ) q), '[]'::jsonb),
            'queues_note', 'Unioned from per-queue tuning config and queues tasks have '
                           'actually used. A worker polling a queue that has never had a '
                           'task is not visible: nothing in the database records it.',
            'agents', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'model', model) order by name)
                from agentic.agents), '[]'::jsonb),
            -- What an `embed:` step -- and therefore a SEMANTIC or SEARCH
            -- `p8ql:` step, which compiles to one -- may name. It belongs in
            -- THIS facet and not only in `graph`, on the rule the queues note
            -- above was written for: an author is told what they may write in
            -- the document they are writing, not sent to a second facet to
            -- find out whether the step they just authored can run.
            --
            -- `callable` is the half a registration can get wrong: a model row
            -- with no endpoint, or a provider with no request shape, is
            -- registered as a SPACE and unusable as a STEP -- and the two
            -- registrations are made in different places by different people.
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', m.name, 'dim', m.dim, 'provider', m.provider,
                    'is_default', m.is_default,
                    'callable', (m.endpoint is not null and p.provider is not null))
                    order by m.name)
                from aiq.embedding_models m
                left join aiq.embedding_providers p on p.provider = m.provider), '[]'::jsonb),
            'embedding_note', 'An `embed:` step names a model, never a url: the endpoint, '
                              'request shape and response path come from aiq.embedding_models '
                              'and aiq.embedding_providers, and define_yaml writes them in. '
                              'A SEMANTIC or SEARCH `p8ql:` step compiles to one of these '
                              'plus the search, and the model is pinned into both halves.',
            -- Everything a template can name. {{run.*}} reads the run INPUT;
            -- the run's own identity is under the reserved $ prefix, because
            -- an input key called `id` is not unusual and shadowing it would
            -- make the same template mean different things per caller. This
            -- block exists because the natural thing to write -- {{run.id}} --
            -- silently resolved to nothing and failed 8 of 18 tasks in a real
            -- pipeline.
            'templates', jsonb_build_object(
                'run',   '{{run.<key>}} -- from the run input passed to start_workflow',
                -- The field NAMES, not a sample from whatever ran last: a
                -- facet that reads from live rows is empty on a fresh install,
                -- which is exactly when someone is reading it.
                'engine', jsonb_build_object(
                    '{{run.$id}}',          'this run''s uuid -- unreachable before this existed, '
                                            'and unpassable as input because the caller does not '
                                            'know it until start_workflow returns',
                    '{{run.$trace_id}}',    'the W3C trace id shared by every task in the run',
                    '{{run.$external_id}}', 'the idempotency key, if one was given',
                    '{{run.$definition}}',  'the workflow name',
                    '{{run.$version}}',     'the definition version this run was expanded from',
                    '{{run.$started_at}}',  'when the run began, ISO-8601 UTC',
                    '{{run.$session}}',     'an engine-minted conversation id, stable for the run '
                                            '-- see `sessions` below'),
                'steps', '{{steps.<id>.result}} -- a completed step''s output. EVERY step '
                         'kind nests its payload under `result`, so this is the one idiom '
                         'to learn.',
                'item',  '{{item.<col>}} -- one matrix row; bound only on fan-out children, '
                         'and substituted at expansion so a worker never sees it',
                'env',   '{{env.<VAR>}} -- resolved by the WORKER only; sql steps have no '
                         'env, because the database has no business reading the '
                         'deployment''s environment',
                'when',  'run/steps/env resolve at DISPATCH; item and run.$* are bound by '
                         'the engine before the worker sees them'),
            'sessions', jsonb_build_object(
                'how', 'An agent step declaring `session_group: <name>` gets an '
                       'engine-minted session id, stable for the life of the run, bound to '
                       '{{run.$session}}. Steps naming the same group share one '
                       'conversation; declaring none stays stateless.',
                'why', 'A workflow could not originate a session: `session:` only resolved '
                       'if the CALLER supplied an id, and the natural key derives from the '
                       'run -- which the run could not see.'),
            'limits', jsonb_build_object(
                'max_payload_bytes', coalesce(
                    nullif(current_setting('workflow.max_payload_bytes', true), '')::int, 65536),
                'max_fanout', 'declared per matrix step; there is no global default, '
                              'because the ceiling is the thing the author must think about'),
            'definitions', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'version', version) order by name, version)
                from workflow.definitions where deleted_at is null), '[]'::jsonb)),
        'examples', aiq.facet_examples('workflow'));
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13f. Facet: sql -- caller-scoped, and that is the whole point.
--
-- SECURITY INVOKER, so `has_table_privilege(current_user, ...)` is the
-- caller's. A schema document that lists tables the reader cannot select from
-- is worse than no document: it is a directory of things to try, and it tells
-- one tenant that another's tables exist.
--
-- `SCHEMA "sql" FROM <relation>` narrows to one table, which is the form worth
-- having -- the unnarrowed document over a real deployment is large, and an
-- agent almost always wants one relation it just learned the name of.
-- ------------------------------------------------------------
create or replace function aiq.schema_sql(p_name text default null)
returns jsonb as $$
    with visible as (
        select c.oid, n.nspname, c.relname, c.relkind, c.relrowsecurity,
               obj_description(c.oid, 'pg_class') as comment
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'v', 'm', 'p', 'f')
          and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
          and n.nspname not like 'pg_temp%'
          and has_table_privilege(c.oid, 'SELECT')
          and (p_name is null
               or c.relname = p_name
               or n.nspname || '.' || c.relname = p_name)
    )
    select jsonb_build_object(
        'declared', jsonb_build_object(
            'note', 'Relations you can SELECT from, as your current role. Another role '
                    'sees a different document; the recorded revision is the owner''s '
                    'view of the whole database, not this.',
            'narrow_with', 'SCHEMA "sql" FROM <relation>'),
        'derived', jsonb_build_object(
            'role', current_user,
            'relation_count', (select count(*) from visible),
            'relations', coalesce((
                select jsonb_agg(jsonb_build_object(
                    'schema', v.nspname, 'name', v.relname,
                    'kind', case v.relkind when 'r' then 'table' when 'p' then 'partitioned table'
                                           when 'v' then 'view'  when 'm' then 'materialized view'
                                           else 'foreign table' end,
                    -- Worth surfacing: on an RLS table, "you may select" and
                    -- "you will see rows" are different statements, and an
                    -- agent that does not know the difference reads an empty
                    -- result as an absent fact.
                    'row_level_security', v.relrowsecurity,
                    'comment', v.comment,
                    'columns', (
                        select jsonb_agg(jsonb_build_object(
                            'name', a.attname,
                            'type', format_type(a.atttypid, a.atttypmod),
                            'not_null', a.attnotnull,
                            'default', pg_get_expr(d.adbin, d.adrelid))
                        order by a.attnum)
                        from pg_attribute a
                        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                        where a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped),
                    'constraints', (
                        select jsonb_agg(jsonb_build_object(
                            'name', co.conname, 'definition', pg_get_constraintdef(co.oid))
                        order by co.conname)
                        from pg_constraint co where co.conrelid = v.oid))
                order by v.nspname, v.relname)
                from visible v), '[]'::jsonb)),
        'examples', aiq.facet_examples('sql'));
$$ language sql stable security invoker;

-- ------------------------------------------------------------
-- 13g. Facet: graph -- the soft schema, which was already written down.
--
-- `aiq.relation_types` is the richest thing in this collection for this
-- purpose: it is the edge catalogue the insert trigger ENFORCES, it carries an
-- inverse label and a human description, and until now nothing served it to
-- the caller who needs it. An agent writing `GRAPH "acme" TYPE competes_with`
-- has no other way to learn that `competes_with` exists, that it runs
-- company -> company, or what it means.
-- ------------------------------------------------------------
create or replace function aiq.schema_graph(p_name text default null)
returns jsonb as $$
    select jsonb_build_object(
        'declared', jsonb_build_object(
            'model', 'Nodes are projections of typed rows registered in aiq.entity_registry; '
                     'keys in aiq.node_keys are how the dialect NAMES them; edges are soft '
                     '(authored) links validated against the relation catalogue below.',
            'traversal', 'GRAPH "<key>" [DEPTH n] [TYPE <relation>] -- the key is resolved '
                         'once and the walk proceeds by id, never by name.'),
        'derived', jsonb_build_object(
            -- How to WRITE one, not just which ones exist. The catalogue told
            -- an author that `competes_with` runs company -> company and
            -- nothing about the table it goes in -- so the first edge written
            -- from this document guessed the column names and failed.
            'edge_write', jsonb_build_object(
                'table', 'aiq.edges',
                'columns', jsonb_build_object(
                    'src_id', 'uuid -> aiq.nodes.id  (NOT src_node_id)',
                    'dst_id', 'uuid -> aiq.nodes.id',
                    'relation', 'text, must exist in the catalogue below',
                    'weight', 'real, default 1.0',
                    'provenance', 'jsonb, default {}'),
                'enforced_by', 'a trigger validates (src_type, relation, dst_type) '
                               'against aiq.relation_types; an unlisted triple is refused',
                'resolve_ids', 'nodes are found by key: select node_id from aiq.lookup(''<key>'')'),
            -- `sample_keys`, and the dead end it closes.
            --
            -- Every mode except SCHEMA requires the caller to ALREADY HOLD a
            -- key (USAGE.md says so outright), and until now nothing anywhere
            -- showed one. So the discovery path terminated: SCHEMA "graph"
            -- said an `fx_pair` entity type exists and a `same_band` relation
            -- runs between them, and left the caller to invent the name of an
            -- instance.
            --
            -- Observed, on the first real question ever put to the sample
            -- agent: it read both schema facets correctly, then guessed
            -- `sterling`, `gbp`, `gbp_usd` and `gbpusd`, got four empty
            -- results, and gave up. The keys were `usd/gbp`. Three example
            -- keys would have ended it at the first call -- the shape of a key
            -- is the one thing a naming convention cannot be reasoned out of.
            --
            -- Scoped explicitly, because this function is SECURITY DEFINER and
            -- therefore does NOT get the RLS that protects aiq.nodes: the
            -- predicate below is the nodes_org_scoped policy written out by
            -- hand. Without it the facet would be a cross-tenant key
            -- disclosure dressed as documentation.
            'entity_types', coalesce((select jsonb_agg(jsonb_build_object(
                    'entity_type', r.entity_type, 'source_table', r.source_table,
                    'key_expr', r.key_expr, 'include_where', r.include_where,
                    'sample_keys', coalesce((
                        select jsonb_agg(k.key order by k.key)
                        from (select nk.key
                                from aiq.node_keys nk
                                join aiq.nodes n on n.id = nk.node_id
                               where n.entity_type = r.entity_type
                                 and nk.kind = 'canonical'
                                 and (n.org_id is null
                                      or n.org_id in (select aiq.current_org_ids()))
                               order by nk.key
                               limit 3) k), '[]'::jsonb))
                    order by r.entity_type)
                from aiq.entity_registry r
                where p_name is null or r.entity_type = p_name), '[]'::jsonb),
            'relations', coalesce((select jsonb_agg(jsonb_build_object(
                    'src_type', src_type, 'relation', relation, 'dst_type', dst_type,
                    'inverse_label', inverse_label, 'description', description)
                    order by src_type, relation, dst_type)
                from aiq.relation_types
                where p_name is null
                   or p_name in (src_type, relation, dst_type)), '[]'::jsonb),
            'semantic_sources', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'source_table', source_table, 'content_col', content_col)
                    order by name) from aiq.semantic_sources), '[]'::jsonb),
            'lexical_sources', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'source_table', source_table, 'regconfig', regconfig)
                    order by name) from aiq.lexical_sources), '[]'::jsonb),
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'dim', dim, 'provider', provider,
                    'distance_op', distance_op, 'is_default', is_default) order by name)
                from aiq.embedding_models), '[]'::jsonb)),
        'examples', aiq.facet_examples('graph'));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13h. Registration, and the starting example corpus.
--
-- Four facets and nothing hardcoded anywhere above them. A fifth --
-- `tradecraft` over the controlled vocabularies in
-- world-model-ingestion/tradecraft.sql, or `connectors` over
-- content.v_required_credentials -- is these two calls and a function.
-- ------------------------------------------------------------
select aiq.register_schema_facet('p8ql', 'aiq.schema_p8ql',
    'The query dialect',
    'Every mode, its syntax, and the sources and models you may name in FROM and USING. '
    'The grammar is emitted by the parser itself; the examples are parsed on every read.');

select aiq.register_schema_facet('workflow', 'aiq.schema_workflow',
    'Authoring a workflow',
    'The step vocabulary, the legal step kinds read off the engine''s own constraint, the '
    'allow-listed functions a sql step may call with their real signatures, the queues and '
    'agents a step may route to, and worked YAML that is compiled on every read.');

select aiq.register_schema_facet('sql', 'aiq.schema_sql',
    'Relations you can read',
    'Tables, views and columns your current role may SELECT, with constraints and whether '
    'row-level security applies. Narrow with FROM <relation>.', true);

select aiq.register_schema_facet('graph', 'aiq.schema_graph',
    'The entity and relation catalogue',
    'Registered entity types, the enforced edge catalogue with descriptions and inverse '
    'labels, and the search sources and embedding spaces behind them.');

select aiq.register_schema_example('p8ql', 'lookup-list', 'p8ql',
    'FUZZY LOOKUP "acme", "globex" LIMIT 5',
    'Resolving several names is one round trip, not N.', 10);
select aiq.register_schema_example('p8ql', 'graph-walk', 'p8ql',
    'GRAPH "acme" DEPTH 2 TYPE competes_with',
    'DEPTH and TYPE apply only to GRAPH; written elsewhere they are refused, not ignored.', 20);
select aiq.register_schema_example('p8ql', 'lexical', 'p8ql',
    'TEXT "R7 recall notice" FROM chunks LIMIT 10',
    'No embedding needed -- this is the rare-exact-token case SEMANTIC misses.', 30);
select aiq.register_schema_example('p8ql', 'fused', 'p8ql',
    'SEARCH "safety recall" FROM chunks USING nomic-embed-text LIMIT 5',
    'Needs an embedding passed alongside; the database makes no model calls.', 40);
select aiq.register_schema_example('p8ql', 'self', 'p8ql',
    'SCHEMA "workflow"',
    'The query that produced this document.', 50);

-- The `graph` facet had a document and no examples, which is the half of it
-- most likely to be read and the half that rots. Registered as kind `p8ql`, so
-- every read runs them through the real parser: an example that stops parsing
-- is served as `verified: false` rather than as authority.
select aiq.register_schema_example('graph', 'neighbours', 'p8ql',
    'GRAPH "ACME"',
    'Depth 1 is native SQL/PGQ. Both directions come back; an inbound edge is '
    'labelled with the catalogue''s inverse label, and that label works as a '
    'TYPE filter too.', 10);
select aiq.register_schema_example('graph', 'typed-walk', 'p8ql',
    'GRAPH "ACME" DEPTH 2 TYPE competes_with',
    'DEPTH above 1 falls back to WITH RECURSIVE -- PG19 has no quantified path '
    'patterns. One row per node at its shortest depth, ordered by depth then by '
    'the product of the edge weights along the path.', 20);
select aiq.register_schema_example('graph', 'seed-then-load', 'p8ql',
    'LOOKUP "acme", "borealis"',
    'The seed of a walk is resolved exactly -- canonical, then short, then '
    'alias, never trigram. LOOKUP first when a name might be ambiguous: it '
    'returns every node that answers to it, and reports the names it did not '
    'find as rows with a null node_id.', 30);

select aiq.register_schema_example('workflow', 'sql-only', 'workflow_yaml',
$y$name: reindex_nightly
steps:
  - id: rebuild
    sql: {function: rebuild_graph_index, args: [company]}
$y$, 'A workflow of only sql steps completes with nothing running anywhere.', 10);

select aiq.register_schema_example('workflow', 'search', 'workflow_yaml',
$y$name: hybrid_research
steps:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 3'
$y$, 'A vector mode still runs as two tasks -- a sql step cannot embed text, because that '
     'is a model call -- but the compiler writes the embed step, and define_yaml pins the '
     'model into both halves. Compile it and look: there are two steps, and the query in '
     'the stored spec carries USING.', 20);

select aiq.register_schema_example('workflow', 'search-spelled-out', 'workflow_yaml',
$y$name: hybrid_research_raw
steps:
  - id: q
    embed: {text: '{{run.question}}', model: nomic-embed-text}
  - id: retrieve
    needs: [q]
    sql:
      function: p8ql_vec
      args: ['SEARCH "{{run.question}}" FROM chunks USING nomic-embed-text LIMIT 3',
             '{{steps.q.result}}']
$y$, 'The same two tasks, written by hand. Worth knowing they are the same rows: the '
     'shorthand is not a second execution path, and reaching for this form costs nothing '
     'when a pipeline embeds once and searches twice.', 25);

select aiq.register_schema_example('workflow', 'matrix-fanout', 'workflow_yaml',
$y$name: edgar_restatements
steps:
  - id: fan
    matrix:
      rows: {function: tier1_concepts, args: ['{{run.tier}}']}
      max_fanout: 5000
      template:
        queue: edgar-xbrl
        rest:
          url: https://data.sec.gov/api/xbrl/companyconcept/CIK{{item.cik}}/us-gaap/{{item.concept}}.json
          jsonpath: units.USD
  - id: checks
    needs: [fan]
    sql: {function: detect_restatements, args: ['{{run.tier}}']}
$y$, 'One task per row, inserted by the statement that completes the parent. `checks` waits '
     'for every child, not for the expansion.', 30);

-- ------------------------------------------------------------
-- 13i. Grants.
--
-- The three registry tables are readable by `authenticated`, exactly as
-- aiq.entity_registry, aiq.relation_types and workflow.step_functions already
-- are: they describe the deployment, not a tenant. Registration is NOT granted
-- -- it decides what a SCHEMA query can cause to run, the same rule
-- workflow.register_step_function follows.
-- ------------------------------------------------------------
grant select on aiq.schema_facets, aiq.schema_examples, aiq.schema_revisions
    to authenticated, api_viewer;

grant execute on function aiq.schema(text, text) to authenticated, web_anon;
grant execute on function aiq.render_facet(text, text) to authenticated;
grant execute on function aiq.verify_example(text, text) to authenticated;
grant execute on function aiq.facet_examples(text) to authenticated;
grant execute on function aiq.schema_p8ql(text)    to authenticated;
grant execute on function aiq.schema_workflow(text) to authenticated;
grant execute on function aiq.schema_sql(text)     to authenticated;
grant execute on function aiq.schema_graph(text)   to authenticated;

-- Capture writes history, so it is the operator's, not the caller's. It is
-- the same shape as workflow.reap_stale_tasks: scheduled maintenance, granted
-- to `scheduler`, callable from CI beside ../../surface.sql.
grant execute on function aiq.capture_schema_revisions() to scheduler;
grant execute on function aiq.schema_drift() to scheduler, authenticated;
revoke execute on function aiq.register_schema_facet(text, text, text, text, boolean) from public;
revoke execute on function aiq.register_schema_example(text, text, text, text, text, int) from public;


-- ============================================================
-- ai-query-layer/integration-rbac.sql
--   org scoping, api views, the SECURITY INVOKER read path
-- ============================================================

-- ============================================================
-- ai-query-layer <-> user-rbac integration.
--
-- Applied AFTER ai-query-layer/schema.sql and user-rbac/schema.sql, as
-- app_owner. Split out for the same reason workflow-engine's equivalent is:
-- the core query layer must stay deployable with no identity system at all,
-- and everything that crosses the boundary belongs in one file applied last.
--
-- Round 3 established what makes this dangerous to get wrong, so it is worth
-- restating rather than assuming the reader remembers:
--   * A view owned by the TABLE owner bypasses RLS entirely -> every caller
--     sees every row.
--   * FORCE ROW LEVEL SECURITY "fixes" that and breaks all writes, because
--     the trusted SECURITY DEFINER path runs as the table owner too.
--   * The resolution is ownership separation (app_owner owns tables and
--     functions; api_viewer owns only the *_api views), never a policy flag.
-- The same shape is applied here.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tenant scoping.
--
-- nodes/node_keys/edges already carry org_id. The rule, stated once:
--   org_id IS NULL  -> shared reference data, visible to everyone
--   org_id = <uuid> -> visible only to members of that org
--
-- "Shared reference data" is a real category here, not a loophole: a public
-- SEC filing or a well-known company is legitimately global, and forcing it
-- to be duplicated per tenant would defeat the whole point of one identity
-- registry (graph-identity.md "Node registry", org_id "null = shared").
--
-- Membership lives in rbac. This layer does not invent a second notion of
-- tenancy -- it asks the one that already exists.
-- ------------------------------------------------------------

-- The org-membership seam, `aiq.current_org_ids()`, is defined in
-- ai-query-layer/schema.sql rather than here, and the reason is a build
-- ordering one rather than a design one -- see the comment at its definition.
-- What belongs here is the POLICIES that use it, below.

alter table aiq.nodes     enable row level security;
alter table aiq.node_keys enable row level security;
alter table aiq.edges     enable row level security;

-- (select ...) wrapping for InitPlan caching, same as every other RLS policy
-- in this collection -- current_org_ids() is STABLE but that alone does not
-- get it hoisted (user-rbac/schema.sql §9's EXPLAIN finding).
create policy nodes_org_scoped on aiq.nodes for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));
-- node_keys INHERITS its node's visibility rather than re-deriving it from
-- its own org_id copy. That copy exists for the canonical-key unique index
-- (two orgs may each have their own 'acme' -- graph-identity.md "Keys"), and
-- it is the wrong thing to gate reads on.
--
-- Found by running LOOKUP over REST after a rebuild: nodes.org_id had been
-- updated while node_keys.org_id had not (the projection's ON CONFLICT DO
-- NOTHING never touches an existing key row), so the key was visible and its
-- node was not. The join returned nothing and LOOKUP reported an empty result
-- -- indistinguishable from "no such key". A duplicated tenancy fact that can
-- drift is a silent-wrong-answer generator, and the same table cannot be both
-- the uniqueness scope and the visibility source without staying in lockstep.
--
-- One source of truth: visibility lives on nodes, keys inherit it. Drift is
-- now impossible rather than merely detected. (Same shape as workflow.tasks
-- inheriting visibility from workflow.runs.)
create policy node_keys_via_node on aiq.node_keys for select
  using (exists (select 1 from aiq.nodes n where n.id = aiq.node_keys.node_id));
-- Edges likewise inherit: an edge is visible only when BOTH endpoints are.
-- Its own org_id stays for authoring/provenance, not for read gating -- same
-- reasoning as node_keys above, and it additionally prevents an edge from
-- revealing that an invisible node exists.
create policy edges_via_endpoints on aiq.edges for select
  using (exists (select 1 from aiq.nodes s where s.id = aiq.edges.src_id)
     and exists (select 1 from aiq.nodes d where d.id = aiq.edges.dst_id));

-- ------------------------------------------------------------
-- 2. Read path: views owned by api_viewer, exactly as user-rbac does.
--    A view owned by app_owner would bypass the policies above.
-- ------------------------------------------------------------
create view aiq.nodes_api as
  select id, entity_type, entity_id, org_id, summary, created_at, updated_at
  from aiq.nodes;
create view aiq.edges_api as
  select id, src_id, dst_id, relation, weight, valid_from, valid_to, org_id, created_at
  from aiq.edges;

grant usage on schema aiq to api_viewer, authenticated;
grant select on aiq.nodes, aiq.node_keys, aiq.edges to api_viewer;
grant execute on function aiq.current_org_ids() to api_viewer, authenticated;

grant create on schema aiq to api_viewer;
alter view aiq.nodes_api owner to api_viewer;
alter view aiq.edges_api owner to api_viewer;
revoke create on schema aiq from api_viewer;

grant select on aiq.nodes_api, aiq.edges_api to authenticated;

-- Base-table SELECT for `authenticated` too -- and this is NOT the same
-- decision user-rbac made, so the difference is worth stating.
--
-- user-rbac grants no base-table access because its sensitivity is
-- COLUMN-level: password_hash and mfa_secret must never be selectable, and
-- RLS cannot hide a column. Only a view whose SELECT list omits them can.
--
-- Here the sensitivity is purely ROW-level (which org owns this node), which
-- is exactly what RLS does. There is no secret column to hide, so a view adds
-- nothing to safety -- and the query functions are SECURITY INVOKER by
-- design (§3), so they read as the CALLER and are filtered by the caller's
-- policies. Withholding the grant would simply make every mode fail with
-- "permission denied for table node_keys", which is what happened the first
-- time this was exercised over REST.
--
-- The rule, generalised: views for COLUMN secrecy, RLS for ROW visibility.
-- Reaching for a view when the problem is row-level buys nothing and costs a
-- layer of indirection.
grant select on aiq.nodes, aiq.node_keys, aiq.edges to authenticated;

-- A PROPERTY GRAPH is its own privilege object in PG19, separate from the
-- tables it is defined over. Granting SELECT on nodes and edges is NOT
-- sufficient: GRAPH mode fails with "permission denied for property graph
-- knowledge_graph" until this is granted too. Not guessable -- found by a
-- REST call failing after every table grant was already in place.
grant select on property graph aiq.knowledge_graph to authenticated, api_viewer;

-- Embedding spaces are created DYNAMICALLY by register_embedding_space(), so
-- they cannot be listed here -- and a table created after this file runs
-- inherits no grants, making every SEMANTIC/SEARCH call against a newly
-- registered model fail with "permission denied for table emb_<model>".
-- Found by registering a model and immediately querying it over REST.
--
-- ALTER DEFAULT PRIVILEGES is the mechanism that actually covers this: it
-- applies to objects app_owner creates in this schema FROM NOW ON, so a model
-- registered next month is readable without anyone remembering to come back
-- here. The existing grant covers spaces created before this line runs.
grant select on all tables in schema aiq to authenticated, api_viewer;
alter default privileges for role app_owner in schema aiq
    grant select on tables to authenticated, api_viewer;

-- ------------------------------------------------------------
-- 3. Query functions: deny by default, then grant the entry points.
--
-- aiq.query() and the per-mode functions are deliberately left SECURITY
-- INVOKER. This is the opposite call from workflow-engine, and the difference
-- is the point: workflow's mutators run on behalf of a WORKER that has no
-- user identity and must bypass RLS to do its job. These are READ paths run
-- on behalf of a USER, so they must be subject to that user's RLS -- making
-- them SECURITY DEFINER would silently return every tenant's rows, which is
-- precisely the bug the ownership split exists to prevent.
-- ------------------------------------------------------------
revoke execute on all functions in schema aiq from public;

grant execute on function aiq.query(text, vector) to authenticated;
grant execute on function aiq.lookup(text, boolean, int) to authenticated;
grant execute on function aiq.lookup_many(text[], boolean, int) to authenticated;
grant execute on function aiq.graph_neighbors(uuid, text, int) to authenticated;
grant execute on function aiq.graph_walk(uuid, int, text, int) to authenticated;
grant execute on function aiq.semantic_in(text, vector, text, int) to authenticated;
grant execute on function aiq.lexical(text, text, int) to authenticated;
grant execute on function aiq.search(text, text, vector, text, int, int) to authenticated;
grant execute on function aiq.sql_passthrough(text) to authenticated;

-- Registry reads: an agent needs to know which models and sources exist to
-- form a valid query at all. Read-only, no row-level sensitivity.
grant select on aiq.embedding_models, aiq.lexical_sources,
                aiq.semantic_sources, aiq.relation_types to authenticated;

-- ------------------------------------------------------------
-- 3b. Consumer-owned content tables.
--
-- TEXT, SEMANTIC and SEARCH read the CONSUMER's tables (world-model
-- ingestion's resource_chunks, say), not aiq's own -- registered by name in
-- lexical_sources / semantic_sources. Because the query functions are
-- SECURITY INVOKER, the caller needs real access to those tables, and
-- without it every content mode fails with "permission denied for schema
-- <consumer>" even though every aiq grant is correct.
--
-- Deliberately NOT granted here: this file must not reach into a consumer
-- schema it does not own and decide who may read it. That is the consumer's
-- policy to set, alongside its own RLS. Stated explicitly because the failure
-- is confusing -- it looks like an ai-query-layer permissions bug and is not.
--
-- A consumer registering a source is signing up for, e.g.:
--     grant usage on schema wm to authenticated;
--     grant select on wm.resource_chunks to authenticated;
--     alter table wm.resource_chunks enable row level security;
--     create policy ... ;   -- the consumer's own visibility rule
-- ------------------------------------------------------------

-- Registration and projection are ADMIN operations, not user operations, and
-- stay owner-only: register_entity_table() and register_embedding_space()
-- execute DDL built from their arguments, so exposing them to `authenticated`
-- would be a SQL-injection surface with DDL privileges attached. Not granted
-- to anyone; a deployment runs them as app_owner during migration.

-- ------------------------------------------------------------
-- 4. Self-check, mirroring the other two schemas.
-- ------------------------------------------------------------
do $$
declare v_bad text;
begin
    -- The read path must NOT be SECURITY DEFINER (see §3's reasoning).
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'aiq'
      and p.proname in ('query','lookup','graph_neighbors','graph_walk',
                        'semantic_in','lexical','hybrid','sql_passthrough')
      and p.prosecdef;
    if v_bad is not null then
        raise exception
            'READ-PATH FUNCTIONS ARE SECURITY DEFINER: %. These run on behalf of a '
            'user and must be subject to that user''s RLS -- SECURITY DEFINER here '
            'returns every tenant''s rows.', v_bad;
    end if;

    -- Same view-ownership invariant as user-rbac §10 and workflow §16.
    select string_agg(v.relname, ', ') into v_bad
    from pg_class v
    join pg_namespace n on n.oid = v.relnamespace
    join pg_class t on t.relnamespace = v.relnamespace and t.relkind = 'r'
                   and t.relname = replace(v.relname, '_api', '')
    where n.nspname = 'aiq' and v.relkind = 'v' and v.relname like '%\_api'
      and (v.relowner = t.relowner
           or (select rolsuper from pg_roles where oid = v.relowner));
    if v_bad is not null then
        raise exception
            'VIEW OWNERSHIP INVARIANT VIOLATED: %. Each *_api view must be owned by a '
            'non-superuser role distinct from the base table owner.', v_bad;
    end if;

    raise notice 'ai-query-layer self-check passed: read path is SECURITY INVOKER; api views separately owned';
end $$;


-- ============================================================
-- ai-query-layer/integration-workflow.sql
--   p8ql as a workflow step
-- ============================================================

-- ============================================================
-- ai-query-layer <-> workflow-engine integration.
--
-- Applied AFTER both schemas, as app_owner. Split out for the same reason
-- workflow-engine/integration-rbac.sql is: each core must stay deployable on
-- its own, and anything crossing a boundary belongs in one file applied last.
--
-- Caught by verifying a clean install rather than by reading: putting
-- workflow.p8ql() in workflow-engine/schema.sql made that file reference
-- aiq.query(), and the install failed at step 2 with `schema "aiq" does not
-- exist` -- because workflow loads before ai-query-layer. A workflow engine
-- that cannot be installed without a query layer is not the workflow engine
-- this collection specs.
-- ============================================================

-- Two arities. SEMANTIC and SEARCH need a vector, which the database cannot
-- produce -- embedding is an external model call. So those modes are composed
-- as: a `rest` step that embeds, then a p8ql step taking
-- {{steps.embed.result}} as its second argument. LOOKUP, GRAPH and TEXT need
-- no vector and use the one-argument form.
create or replace function workflow.p8ql(p_query text)
returns jsonb as $$
    select aiq.query(p_query);
$$ language sql;

create or replace function workflow.p8ql(p_query text, p_embedding jsonb)
returns jsonb as $$
    select aiq.query(p_query,
        case when p_embedding is null or p_embedding = 'null'::jsonb then null
             else (select array_agg((v #>> '{}')::real order by ord)
                   from jsonb_array_elements(p_embedding) with ordinality t(v, ord))::vector
        end);
$$ language sql;

grant execute on function workflow.p8ql(text) to authenticated, worker;
grant execute on function workflow.p8ql(text, jsonb) to authenticated, worker;

-- Register P8QL as a workflow step function, so `p8ql:` in a YAML workflow
-- resolves. Registration is owner-only (§17), so this is the deployment
-- deciding that queries may run as steps -- not something a workflow author
-- can grant themselves.
select workflow.register_step_function(
    'p8ql', 'workflow.p8ql', array['text'], 30000,
    'Run a P8QL query as a workflow step');
select workflow.register_step_function(
    'p8ql_vec', 'workflow.p8ql', array['text','jsonb'], 30000,
    'P8QL with an embedding produced by a prior step');

-- ============================================================
-- Embed steps: the half of a vector search the database cannot do.
--
-- The two arities above are the mechanism, and for a long time they were also
-- the interface: an author wrote the `rest:` call to a model by hand, then
-- passed {{steps.embed.result}} into p8ql_vec. That has two defects, and only
-- the first is ergonomic.
--
--  1. The url, the request body's shape and the path to the vector in the
--     response are deployment facts written into a document that outlives
--     deployments. Two workflows in one database embed differently against the
--     same model because two people wrote two `rest:` blocks.
--
--  2. NOTHING TIED THE TWO HALVES TOGETHER. The embed step names a model, the
--     query names a space with USING (or takes the default), and if those two
--     disagree the run does not fail -- aiq.semantic_in only checks the
--     DIMENSION, so two 768-dim models produce a cosine distance that is a
--     number and not an answer. §10 says this in the strongest terms it has
--     ("meaningless, not merely imprecise") and then left the workflow author
--     to hold both ends of it by hand.
--
-- So the compiler emits a MARKER -- an http_call whose input is
-- {"embed": {"text": ..., "model": ...}} and no url -- and this function turns
-- it into an ordinary REST call at DEFINITION time, from the registry. Three
-- consequences worth stating:
--
--   * The shipped worker needs no new handler. After expansion this is an
--     http_call like any other, on the queue the author named, with retry,
--     backoff, the reaper and tracing already applying. An `embed:` step is
--     not a new deployable and not a new execution path.
--   * The model is resolved ONCE and pinned into BOTH halves -- written into
--     the query as `USING <model>` if it was not already there, and refused if
--     it was there and disagrees. The invariant the two-step form could not
--     hold is now unstatable in a stored definition.
--   * It resolves at definition time rather than dispatch, so the answer is
--     visible in workflow.definitions.spec. A run does not re-decide which
--     model it meant because someone moved is_default in between.
-- ============================================================
-- ONE marker becomes ONE call, and it is a function rather than a block
-- because there are two places a marker can be: a step, and the template a
-- matrix step fans out. The second was missed on the first pass -- the
-- compiler accepted `template: {embed: ...}`, nothing expanded it, and every
-- child was created as an http_call with no url, failing at dispatch N times
-- with a message about a document nobody wrote. Found by asking where else a
-- step can hide, which is the question `matrix` has now answered wrongly
-- three times (nested fan-out, the successors that had to be rewired, this).
create or replace function aiq.embed_call(p_marker jsonb, p_step_key text)
returns jsonb as $$
declare
    v_text  text := p_marker->>'text';
    v_named text := p_marker->>'model';
    v_body  jsonb;
    v_input jsonb;
    m       aiq.embedding_models;
    p       aiq.embedding_providers;
begin
    if v_named is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then
            raise exception
                'step ''%'' embeds text but this deployment has no default embedding '
                'model. Name one with `embed: {text: ..., model: <name>}` (or '
                'USING <model> in the query), or set is_default on a row in '
                'aiq.embedding_models.', p_step_key;
        end if;
    else
        select * into m from aiq.embedding_models where name = v_named;
        if not found then
            raise exception
                'step ''%'' embeds with model ''%'', which is not registered. '
                'SCHEMA "graph" lists the registered ones.', p_step_key, v_named;
        end if;
    end if;

    select * into p from aiq.embedding_providers where provider = m.provider;
    if not found then
        raise exception
            'embedding model ''%'' is served by provider ''%'', which has no row in '
            'aiq.embedding_providers -- so nothing here knows what its request '
            'body looks like or where the vector sits in its response.',
            m.name, m.provider;
    end if;

    -- Refused rather than defaulted: a guessed url is a step that 404s on
    -- every run of every workflow that ever names this model, and the message
    -- would name the endpoint rather than the omission.
    if m.endpoint is null then
        raise exception
            'embedding model ''%'' has no endpoint, so step ''%'' has nowhere to send '
            'its text. Set aiq.embedding_models.endpoint -- it may be written as '
            '''{{env.LLM_URL}}/api/embeddings'', which the worker resolves.',
            m.name, p_step_key;
    end if;

    -- Whole VALUES only (§10a): the author's text becomes a jsonb string via
    -- to_jsonb, so quotes, newlines and braces in it are escaped by the
    -- database rather than by a regex of ours.
    select jsonb_object_agg(k,
               case when v = '"{{text}}"'::jsonb  then to_jsonb(v_text)
                    when v = '"{{model}}"'::jsonb then to_jsonb(m.name)
                    else v end)
      into v_body
      from jsonb_each(p.request_template) e(k, v);

    v_input := jsonb_build_object(
        'url',        m.endpoint,
        'method',     p.method,
        'body',       v_body,
        'jsonpath',   p.response_path,
        'timeout_ms', 30000,
        -- Kept beside the call, not consumed by it. It is what makes a task
        -- row say what it IS -- "the embedding of {{run.question}} in
        -- nomic-embed-text" -- rather than leaving a reader to infer an intent
        -- from a url and a body. It is also what makes expansion idempotent: a
        -- marker is recognised by having NO url, so an expanded step cannot be
        -- expanded twice.
        'embed',      jsonb_build_object('text', v_text, 'model', m.name));

    if m.credential_ref is not null then
        v_input := v_input || jsonb_build_object('credential_ref', m.credential_ref);
    end if;
    return v_input;
end;
$$ language plpgsql stable;

grant execute on function aiq.embed_call(jsonb, text) to authenticated;

create or replace function aiq.expand_embed_steps(p_spec jsonb)
returns jsonb as $$
declare
    v_steps   jsonb := '[]'::jsonb;
    v_out     jsonb;
    v_step    jsonb;
    v_models  jsonb := '{}'::jsonb;   -- embed step key -> the model it resolved to
    v_input   jsonb;
    v_ref     text;
    v_plan    jsonb;
    v_query   text;
    v_model   text;
begin
    if p_spec is null or p_spec->'steps' is null then
        return p_spec;
    end if;

    -- Pass 1: every marker becomes a REST call, wherever the marker is.
    for v_step in select * from jsonb_array_elements(p_spec->'steps') loop

        if v_step->>'kind' = 'http_call'
           and v_step->'input' ? 'embed' and not (v_step->'input' ? 'url') then
            v_input  := aiq.embed_call(v_step->'input'->'embed', v_step->>'key');
            v_step   := jsonb_set(v_step, '{input}', v_input);
            v_models := v_models || jsonb_build_object(
                            v_step->>'key', v_input->'embed'->>'model');

        -- A matrix template is a step in every way except that it has no key
        -- of its own, so it needs the same expansion and borrows the parent's
        -- key for any message. There is no model to PIN here, and that is not
        -- an omission: a template is ONE step, so nothing inside it consumes
        -- the vector. A successor reads the children through matrix_outputs,
        -- and the model each child embedded with is recorded on the child.
        elsif v_step->>'kind' = 'matrix'
           and v_step#>'{input,template,input}' ? 'embed'
           and not (v_step#>'{input,template,input}' ? 'url') then
            v_step := jsonb_set(v_step, '{input,template,input}',
                aiq.embed_call(v_step#>'{input,template,input,embed}',
                               (v_step->>'key') || ' (matrix template)'));
        end if;

        v_steps := v_steps || jsonb_build_array(v_step);
    end loop;

    -- Pass 2: pin the model into the query that consumes each vector.
    --
    -- The pairing is read off the DATA FLOW -- a p8ql step whose arguments
    -- reference {{steps.<an embed step>.result}} -- rather than off a marker
    -- the compiler left behind. That is deliberate: it makes the check apply
    -- to the hand-written two-step form exactly as it applies to the sugar,
    -- so the raw spelling is not the one that quietly keeps the old defect.
    v_out := '[]'::jsonb;
    for v_step in select * from jsonb_array_elements(v_steps) loop
        if v_step->>'kind' = 'sql'
           and coalesce(v_step->'input'->>'function', '') in ('p8ql', 'p8ql_vec') then

            v_query := v_step->'input'->'args'->>0;
            v_model := null;
            for v_ref in
                select m2[1] from regexp_matches(v_step::text,
                    '\{\{\s*steps\.([a-zA-Z0-9_-]+)\.result\s*\}\}', 'g') m2
            loop
                if v_models ? v_ref then
                    -- Refused rather than last-one-wins. A query takes ONE
                    -- vector, so a step reading two embeddings is already
                    -- saying something it cannot mean -- and silently pinning
                    -- whichever reference the scan happened to see last is the
                    -- exact shape of bug this whole pass exists to remove.
                    if v_model is not null and v_model <> v_models->>v_ref then
                        raise exception
                            'step ''%'' reads vectors from two embed steps, produced by '
                            '''%'' and ''%''. A query ranks against one embedding, so '
                            'there is no answer to which space it is searching.',
                            v_step->>'key', v_model, v_models->>v_ref;
                    end if;
                    v_model := v_models->>v_ref;
                end if;
            end loop;

            if v_query is not null and v_model is not null then
                execute 'select aiq_parse($1)' into v_plan using v_query;

                -- A query that does not parse is the lint's to report, with
                -- the step key and the parser's own message. Saying it twice,
                -- here, in a function about embeddings, would put the worst
                -- version of that message in front of the author.
                if coalesce((v_plan->>'ok')::boolean, false)
                   and v_plan->>'mode' in ('SEMANTIC', 'SEARCH') then

                    if v_plan->>'model' is null then
                        -- USING is order-independent in the dialect, so
                        -- appending is legal whatever else the query carries.
                        v_step := jsonb_set(v_step, '{input,args,0}',
                            to_jsonb(v_query || ' USING ' || v_model));

                    elsif v_plan->>'model' <> v_model then
                        raise exception
                            'step ''%'' searches the ''%'' space but is handed a vector produced '
                            'by ''%''. Nothing downstream can catch this: cosine distance '
                            'between two embedding spaces is a number, not an answer, and '
                            'the dimension check passes whenever the two models happen to '
                            'be the same width.',
                            v_step->>'key', v_plan->>'model', v_model;
                    end if;
                end if;
            end if;
        end if;
        v_out := v_out || jsonb_build_array(v_step);
    end loop;

    return jsonb_set(p_spec, '{steps}', v_out);
end;
$$ language plpgsql stable;

grant execute on function aiq.expand_embed_steps(jsonb) to authenticated;

comment on function aiq.expand_embed_steps(jsonb) is
    'Turn every `embed:` marker in a compiled workflow spec into an ordinary REST '
    'call from aiq.embedding_models + aiq.embedding_providers, and pin the model it '
    'resolved to into the query that consumes the vector. Called by '
    'workflow.define_yaml; an unexpanded marker is refused by the lint.';


-- ============================================================
-- world-model-ingestion/schema.sql
--   the content plane: channels, files, resources, chunks
-- ============================================================

-- ============================================================
-- World Model Ingestion — schema v0.1
--
-- The content plane: where bytes come from, where they are registered, and
-- what gets chunked for retrieval. Implements brief.md §2-§3.
--
-- This closes a real coherence hole rather than adding a feature.
-- ai-query-layer/USAGE.md instructs a reader to run
--   select aiq.register_lexical_source('chunks', 'wm.resource_chunks');
-- and no such table shipped -- `wm` was a throwaway test fixture. TEXT,
-- SEMANTIC and SEARCH are documented as working over "chunks", so the corpus
-- they search has to be something the collection actually installs.
--
-- Applied as app_owner, after ai-query-layer. The aiq/rbac wiring lives in
-- integration.sql, same boundary discipline as everywhere else in this
-- collection: this file alone is a content store with no query layer and no
-- identity system.
-- ============================================================

create schema if not exists content;

-- ------------------------------------------------------------
-- 1. Channels — where content comes from.
--
-- Made a first-class table rather than a string column on `resource`
-- (brief.md §2): a Telegram channel is a row exactly as an SEC EDGAR feed is,
-- so adding a source kind is an insert plus a handler, not a schema change.
--
-- `kind` distinguishes who initiates, which is the only thing that actually
-- differs between them -- a push arrives as an upload, a pull is polled.
-- ------------------------------------------------------------
create table content.channels (
    id            uuid primary key default gen_random_uuid(),
    name          text not null,
    kind          text not null check (kind in
                      ('file_upload','http_pull','ftp_pull','feed','telegram','manual')),
    -- Provider-specific: url, auth reference, cursor field, parser hints.
    -- Deliberately jsonb: every provider needs different things, and a column
    -- per provider is how this table becomes unmaintainable.
    config        jsonb not null default '{}'::jsonb,
    -- Poll cadence for pull kinds. Null = not polled (upload/manual).
    poll_interval interval,
    last_polled_at timestamptz,
    org_id        uuid,
    enabled       boolean not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (org_id, name)
);
create index idx_channels_pollable on content.channels (last_polled_at)
    where enabled and poll_interval is not null;

create trigger trg_channels_touch before update on content.channels
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Files — the Postgres-side pointer. NEVER the bytes.
--
-- Keyed by content hash, so the same PDF uploaded twice is one object
-- (brief.md §3). That dedup is exactly why this table has NO org_id: one row
-- can legitimately be referenced by resources belonging to different tenants,
-- so there is no single owner and any owner-scoped RLS policy on it would be
-- meaningless. Tenancy lives on `resources`, which is single-owner.
--
-- Consequently this table is never exposed through PostgREST -- reads go
-- through a resource, which is scoped. See integration.sql.
-- ------------------------------------------------------------
create table content.files (
    id           uuid primary key default gen_random_uuid(),
    checksum     text not null unique,      -- sha256 of the content; the dedup key
    bucket       text not null,
    object_key   text not null,
    size_bytes   bigint not null check (size_bytes >= 0),
    content_type text,
    created_at   timestamptz not null default now(),
    unique (bucket, object_key)
);

-- ------------------------------------------------------------
-- 3. Resources — the unit of ingested content.
--
-- A resource is one thing that entered the system: an uploaded document, a
-- fetched page, a Telegram post. It points at a channel (where it came from)
-- and optionally a file (if it has bytes -- a scraped JSON record may not).
-- ------------------------------------------------------------
create table content.resources (
    id           uuid primary key default gen_random_uuid(),
    channel_id   uuid not null references content.channels(id),
    file_id      uuid references content.files(id),
    -- Provider's own identifier, used to avoid re-ingesting the same item on
    -- the next poll. Unique per channel, not globally: two feeds may both
    -- number their items from 1.
    external_id  text,
    uri          text,
    title        text,
    -- 'pending' until the ingestion workflow has chunked it; 'ready' once
    -- retrievable. A resource that failed to parse stays 'failed' and is
    -- visible rather than silently absent.
    -- 'stored' is the fourth state and it is not a stage on the way to
    -- 'ready': it means "bytes registered, and there is nothing to chunk".
    -- A workflow artifact -- a rendered report, an offloaded response --
    -- is retrievable the moment it lands and is not corpus. Giving it its
    -- own status rather than reusing 'ready' closes two collisions by
    -- construction rather than by adding a predicate to each:
    --   * check_drift() below reports pending-too-long and ready-with-no-
    --     chunks. An artifact is legitimately neither, and under 'ready'
    --     every artifact ever produced would be permanent drift noise.
    --   * integration.sql registers resources as graph 'document' nodes
    --     where status = 'ready'. Machine-generated step output is exactly
    --     the data-plane volume graph-identity.md's inclusion policy keeps
    --     out of the node registry -- the same argument that excludes chunks.
    status       text not null default 'pending'
                     check (status in ('pending','ready','stored','failed','superseded')),
    metadata     jsonb not null default '{}'::jsonb,
    org_id       uuid,
    ingested_at  timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (channel_id, external_id)
);
create index idx_resources_channel on content.resources (channel_id, ingested_at desc);
create index idx_resources_org on content.resources (org_id);
-- Partial on the states worth hunting for. 'stored' joins 'ready' in the
-- exclusion: both are terminal and neither is something an operator goes
-- looking for, so admitting artifacts here would grow the index without
-- making it answer anything.
--
-- Written as drop-then-create (and the check as drop-then-add) so an
-- installation that already exists picks both up: `create table` is skipped
-- when the table is there, which silently leaves the old constraint and the
-- old index in place. The workflow engine learned this the hard way with
-- tasks_kind_check.
alter table content.resources drop constraint if exists resources_status_check;
alter table content.resources add constraint resources_status_check
    check (status in ('pending','ready','stored','failed','superseded'));
drop index if exists content.idx_resources_status;
create index idx_resources_status on content.resources (status)
    where status not in ('ready','stored');

create trigger trg_resources_touch before update on content.resources
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 4. Chunks — the data plane, and what retrieval actually searches.
--
-- High volume by design. Per graph-identity.md's inclusion policy these are
-- explicitly NOT graph nodes: they are machine-generated rows that join in
-- after identity is known, never entries in the node registry. The semantic
-- path reaches them through a relational join from a resource, which is what
-- keeps the node/key tables small enough for the O(log n) lookup claim to hold.
--
-- Embeddings live in aiq.emb_<model>, keyed by chunk_id -- one table per
-- MODEL, not per dimension (ai-query-layer/schema.sql §10). No FK is possible
-- in that direction because the embedding table is generic and does not know
-- this schema; integration.sql adds the reconciliation instead.
-- ------------------------------------------------------------
create table content.resource_chunks (
    id           uuid primary key default gen_random_uuid(),
    resource_id  uuid not null references content.resources(id) on delete cascade,
    ordinal      int not null,
    content      text not null,
    -- Byte offsets into the source, so a citation can point at a span rather
    -- than just a chunk -- agentic/brief.md §5.3's citations carry chunk_id,
    -- and a reader following one wants to find it in the original.
    start_offset int,
    end_offset   int,
    token_count  int,
    metadata     jsonb not null default '{}'::jsonb,
    created_at   timestamptz not null default now(),
    unique (resource_id, ordinal)
);
create index idx_chunks_resource on content.resource_chunks (resource_id, ordinal);

-- ------------------------------------------------------------
-- 5. Registration — upload and fetch, as functions.
--
-- The Content Server calls these; it holds no table grants of its own, same
-- as any worker. Writing the rows is a transaction, so a half-registered
-- upload (object stored, no resource row) cannot happen through this path.
-- ------------------------------------------------------------

-- Register an uploaded object. Returns the resource id.
--
-- Content-hash dedup is handled here rather than by the caller: the second
-- upload of identical bytes reuses the existing content.files row.
--
-- DEDUP IS AT THE FILE LEVEL ONLY, and the distinction matters. Two tenants
-- uploading the same public PDF get ONE object and TWO resources -- they each
-- uploaded a thing, with their own title, org and lifecycle, that happens to
-- share bytes. An earlier version used the checksum as the resource's
-- external_id, which collapsed them into one resource and quietly gave the
-- second uploader the first one's row; caught by uploading the same file twice
-- and counting. p_external_id is now the caller's own idea of identity, used
-- by pullers to avoid re-ingesting; an upload normally leaves it null and gets
-- a new resource every time.
create or replace function content.register_upload(
    p_channel     text,
    p_checksum    text,
    p_bucket      text,
    p_object_key  text,
    p_size_bytes  bigint,
    p_content_type text default null,
    p_title       text default null,
    p_uri         text default null,
    p_org_id      uuid default null,
    p_metadata    jsonb default '{}'::jsonb,
    p_external_id text default null,
    p_trace_id    text default null
) returns uuid as $$
declare
    v_channel  uuid;
    v_file     uuid;
    v_res      uuid;
    v_workflow text;
    v_run      uuid;
begin
    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null);
    if v_channel is null then
        raise exception 'no channel named % for this org -- create one first', p_channel;
    end if;

    -- The dedup. ON CONFLICT on checksum, so concurrent uploads of the same
    -- bytes converge on one row rather than racing.
    insert into content.files (checksum, bucket, object_key, size_bytes, content_type)
    values (p_checksum, p_bucket, p_object_key, p_size_bytes, p_content_type)
    on conflict (checksum) do update set checksum = excluded.checksum
    returning id into v_file;

    insert into content.resources (channel_id, file_id, uri, title, org_id, metadata, external_id)
    values (v_channel, v_file, p_uri, p_title, p_org_id, p_metadata, p_external_id)
    on conflict (channel_id, external_id) do update set updated_at = now()
    returning id into v_res;

    -- START THE INGESTION WORKFLOW. This is the point of the whole function
    -- (brief.md §3.5 names it the primary use case): upload -> registered ->
    -- queryable is meant to be one flow, not three manually-wired steps. It
    -- fires here, in the same transaction as the rows, so a committed resource
    -- always has a run and a rolled-back upload leaves neither.
    --
    -- The workflow name comes from the CHANNEL, so different sources can chunk
    -- differently without this function knowing how any of them work. A channel
    -- with no ingest_workflow configured registers content and starts nothing,
    -- which is a legitimate choice rather than an error.
    select config->>'ingest_workflow' into v_workflow
    from content.channels where id = v_channel;

    if v_workflow is not null then
        -- p_trace_id propagates the caller's trace when the Content Server has
        -- one (specs/README.md's OTel ground rule), so an upload and everything
        -- it causes share one trace rather than three disconnected ones.
        v_run := workflow.start_workflow(
            v_workflow,
            jsonb_build_object('resource_id', v_res, 'file_id', v_file,
                               'org_id', p_org_id),
            'ingest:' || v_res::text,
            p_trace_id);
    end if;

    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Register a fetched item that has no bytes of its own (a JSON record from a
-- feed, say). Same shape, no file.
create or replace function content.register_fetched(
    p_channel     text,
    p_external_id text,
    p_title       text default null,
    p_uri         text default null,
    p_org_id      uuid default null,
    p_metadata    jsonb default '{}'::jsonb
) returns uuid as $$
declare v_channel uuid; v_res uuid;
begin
    select id into v_channel from content.channels
    where name = p_channel and (org_id is not distinct from p_org_id or org_id is null);
    if v_channel is null then
        raise exception 'no channel named % for this org', p_channel;
    end if;

    insert into content.resources (channel_id, external_id, uri, title, org_id, metadata)
    values (v_channel, p_external_id, p_uri, p_title, p_org_id, p_metadata)
    on conflict (channel_id, external_id) do nothing
    returning id into v_res;

    -- Null means "already ingested on a previous poll" -- not an error. A
    -- puller that treats it as one re-processes its whole backlog every cycle.
    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Fetch: resolve a resource to its storage location. The Content Server
-- proxies the bytes (brief.md §3.5 -- proxied reads, not presigned URLs, for
-- one authorization path), so it needs the location and nothing else.
--
-- SECURITY DEFINER with an EXPLICIT visibility check, and the combination is
-- forced rather than chosen. This has to read content.files, which is granted
-- to nobody -- deduped by content hash, so it has no single owner and any
-- owner-scoped policy on it would be meaningless. A SECURITY INVOKER version
-- therefore cannot succeed for anyone; it failed with "permission denied for
-- table resources" the first time a containerized Content Server called it.
--
-- So authorization is done here instead of by RLS: the caller must be able to
-- see the RESOURCE, checked against exactly the predicate resources' own
-- policy uses. That keeps one rule in two places, which is a cost -- but the
-- alternative is exposing storage keys through a table that cannot be scoped.
--
-- Returns nothing when the caller may not see it, rather than raising:
-- distinguishing "not yours" from "does not exist" tells an unauthorized
-- caller that the resource exists.
create or replace function content.resolve_file(p_resource_id uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint) as $$
    select f.bucket, f.object_key, f.content_type, f.size_bytes
    from content.resources r
    join content.files f on f.id = r.file_id
    where r.id = p_resource_id
      and (r.org_id is null or r.org_id in (select aiq.current_org_ids()));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- Record chunks produced by the ingestion workflow, and flip the resource
-- ready. One call rather than N inserts plus an update, so a resource is never
-- observably half-chunked.
create or replace function content.record_chunks(p_resource_id uuid, p_chunks jsonb)
returns int as $$
declare v_count int;
begin
    delete from content.resource_chunks where resource_id = p_resource_id;

    insert into content.resource_chunks (resource_id, ordinal, content, token_count, metadata)
    select p_resource_id,
           (ord - 1)::int,
           c->>'content',
           (c->>'token_count')::int,
           coalesce(c->'metadata', '{}'::jsonb)
    from jsonb_array_elements(p_chunks) with ordinality t(c, ord);
    get diagnostics v_count = row_count;

    update content.resources set status = 'ready', updated_at = now()
    where id = p_resource_id;
    return v_count;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6. Reconciliation — the invariant brief.md §3 states, made checkable.
--
--   "every files row has exactly one object in storage, and no object in
--    storage lacks a files row"
--
-- The database can only see one side of that. This reports what it CAN check;
-- the storage side is a Content Server job that lists the bucket and compares.
-- Same shape as aiq.check_drift: a non-empty result is a writer bug, not a
-- routine merge.
-- ------------------------------------------------------------
create or replace function content.check_drift()
returns table(kind text, id uuid, detail text) as $$
    -- a file no resource points at: the upload transaction died after storing
    select 'orphan_file'::text, f.id, f.bucket || '/' || f.object_key
    from content.files f
    where not exists (select 1 from content.resources r where r.file_id = f.id)
    union all
    -- a resource stuck pending: the ingestion workflow never finished
    select 'unchunked_resource'::text, r.id, coalesce(r.title, r.uri, '(untitled)')
    from content.resources r
    where r.status = 'pending' and r.ingested_at < now() - interval '1 hour'
    union all
    -- a ready resource with no chunks: record_chunks was never called
    select 'ready_but_empty'::text, r.id, coalesce(r.title, r.uri, '(untitled)')
    from content.resources r
    where r.status = 'ready'
      and not exists (select 1 from content.resource_chunks c where c.resource_id = r.id);
$$ language sql stable;


-- ============================================================
-- world-model-ingestion/integration.sql
--   registers the corpus, projects documents into the graph
-- ============================================================

-- ============================================================
-- world-model-ingestion <-> ai-query-layer + user-rbac + workflow integration.
--
-- Applied last, after every other schema. Same boundary discipline as the
-- other integration files: content/schema.sql alone is a content store with no
-- query layer and no identity system, and everything crossing a boundary lives
-- here.
--
-- This is the file that makes ai-query-layer/USAGE.md true. That document
-- tells a reader to register a lexical source called "chunks"; until this ran,
-- there was nothing to register.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Register the corpus with the query layer.
--
-- register_lexical_source adds a generated tsvector column and a GIN index to
-- resource_chunks, so TEXT mode works over real content rather than a fixture.
-- ------------------------------------------------------------
select aiq.register_lexical_source('chunks', 'content.resource_chunks');

insert into aiq.semantic_sources (name, source_table)
values ('chunks', 'content.resource_chunks')
on conflict (name) do update set source_table = excluded.source_table;

-- ------------------------------------------------------------
-- 2. Resources become graph nodes; chunks deliberately do NOT.
--
-- graph-identity.md's inclusion policy: a row becomes a node if it is
-- LOOKUP-searchable or an edge endpoint. A document is both -- you name it,
-- and events reference it. A chunk is neither: it is machine-generated
-- data-plane volume that joins in after identity is known, and admitting
-- chunks would put the node registry on the wrong side of the scale argument.
--
-- Only 'ready' resources are included: a pending or failed one is not yet a
-- thing you can meaningfully look up, and the inclusion predicate is shared
-- with rebuild so the two cannot drift.
-- ------------------------------------------------------------
select aiq.register_entity_table(
    'document',
    'content.resources',
    'coalesce(n.title, n.uri, n.id::text)',   -- canonical key
    'coalesce(n.title, n.uri)',               -- summary
    'n.org_id',
    $$n.status = 'ready'$$
);

insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
  ('document','derived_from','document','source_of','a document produced from another'),
  ('document','supersedes','document','superseded_by','a newer revision of the same thing')
on conflict do nothing;

-- ------------------------------------------------------------
-- 3. Tenancy.
--
-- resources and chunks are org-scoped; FILES ARE NOT, and that asymmetry is
-- deliberate rather than an omission. Content-hash dedup means one files row
-- can be referenced by resources belonging to different tenants -- there is no
-- single owner, so an owner-scoped policy on it would be meaningless. Files
-- are therefore never exposed directly: a caller asks for a resource, and
-- content.resolve_file() joins through it (SECURITY INVOKER, so the caller's
-- RLS on resources decides).
--
-- Chunks inherit their resource's visibility rather than carrying a second
-- copy of org_id. Duplicating a tenancy fact is what let node_keys.org_id and
-- nodes.org_id drift and made LOOKUP silently return nothing; one source of
-- truth makes that impossible rather than merely detectable.
-- ------------------------------------------------------------
alter table content.channels        enable row level security;
alter table content.resources       enable row level security;
alter table content.resource_chunks enable row level security;

create policy channels_org_scoped on content.channels for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

create policy resources_org_scoped on content.resources for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

create policy chunks_via_resource on content.resource_chunks for select
  using (exists (select 1 from content.resources r
                 where r.id = content.resource_chunks.resource_id));

-- ------------------------------------------------------------
-- 4. Grants.
--
-- Read paths are SECURITY INVOKER, so callers need real SELECT and RLS does
-- the filtering -- views for column secrecy, RLS for row visibility, and here
-- there are no secret columns. files is the exception, granted to nobody.
-- ------------------------------------------------------------
grant usage on schema content to authenticated, worker, api_viewer;
grant select on content.channels, content.resources, content.resource_chunks
    to authenticated, api_viewer;

-- The Content Server registers uploads and the ingestion workflow records
-- chunks; both go through SECURITY DEFINER functions, so neither needs a write
-- grant on any table.
grant execute on function content.register_upload(text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text) to authenticated;
grant execute on function content.register_fetched(text,text,text,text,uuid,jsonb) to authenticated;
grant execute on function content.record_chunks(uuid,jsonb) to worker, authenticated;
grant execute on function content.resolve_file(uuid) to authenticated;
grant execute on function content.check_drift() to authenticated, worker;

-- ------------------------------------------------------------
-- 5. Ingestion as workflow step functions.
--
-- Registered so a YAML workflow can name them, which is what makes the
-- ingestion pipeline declarative rather than code. Registration is owner-only,
-- so this is the deployment deciding these may run as steps.
-- ------------------------------------------------------------
select workflow.register_step_function(
    'record_chunks', 'content.record_chunks', array['uuid','jsonb'], 60000,
    'Store chunks for a resource and mark it ready');
select workflow.register_step_function(
    'content_drift', 'content.check_drift', array[]::text[], 60000,
    'Report orphaned files and unchunked resources');

-- ------------------------------------------------------------
-- 5b. Workflow artifacts -- the fourth output class, given a home.
--
-- workflow-engine/outputs.md: a step produces rows, a validated assistant
-- message, an inline payload, or BYTES. Bytes are the one the engine cannot
-- hold. Its answer is a ref beside the payload --
-- {"result": ..., "$artifact": "<resource id>"} -- and this section is what
-- makes that id mean something.
--
-- A RESOURCE ID, NOT AN s3:// URI, and the difference is the whole point. A
-- bucket path in a JSONB column is a string with no owner: not RLS-scoped, not
-- checksummed, not deduped, not servable, not garbage-collected, and it drags
-- a bucket name into a row that is supposed to stay inspectable and
-- replayable -- the same argument that makes credential_ref a NAME. A resource
-- id is all of those things already, because content/schema.sql built them for
-- uploads and an artifact is an upload the system performed on its own behalf.
--
-- Nothing new is stored to make the link. The task's output holds the resource
-- id (forward) and the resource's metadata holds the task id (back), each on
-- the row that owns it. A join table would be a third copy of a fact two rows
-- already carry.
-- ------------------------------------------------------------
-- WHERE NOT EXISTS rather than ON CONFLICT, and not as a style choice:
-- channels is UNIQUE (org_id, name) with a NULLABLE org_id, so two global
-- channels of the same name do not collide -- NULLs are distinct in a unique
-- index unless it is declared NULLS NOT DISTINCT, and this one is not. An
-- ON CONFLICT here raises "no unique or exclusion constraint matching"
-- (it does; that is how this comment got written), and the version that
-- compiles would silently insert a second row on the next install, leaving
-- register_upload's lookup to pick one of them arbitrarily.
insert into content.channels (name, kind, config)
select 'workflow_artifacts', 'file_upload',
       -- No ingest_workflow: registering an artifact must not start an
       -- ingestion run. That key is what makes an upload chunk itself, and a
       -- rendered PDF that a step just produced is output, not intake. A
       -- channel with none configured registers content and starts nothing,
       -- which content.register_upload documents as a legitimate choice.
       '{"description": "bytes produced by a workflow step, refd from tasks.output"}'::jsonb
where not exists (
    select 1 from content.channels where name = 'workflow_artifacts' and org_id is null);

create or replace function workflow.register_artifact(
    p_task_id      uuid,
    p_checksum     text,
    p_bucket       text,
    p_object_key   text,
    p_size_bytes   bigint,
    p_content_type text default null,
    p_title        text default null,
    p_org_id       uuid default null
) returns uuid as $$
declare
    t      workflow.tasks;
    v_res  uuid;
    v_file uuid;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found then
        raise exception
            'no task % -- an artifact belongs to the task that produced it, and the '
            'task id is what makes the ref traceable back to a step', p_task_id;
    end if;

    -- external_id is the TASK id, so a retry converges on one resource instead
    -- of leaving a trail of orphans -- the same idempotency the engine already
    -- gets from tasks.idempotency_key. Bytes are deduped independently by
    -- checksum, so two tasks writing identical output share one files row and
    -- still get a resource each.
    v_res := content.register_upload(
        p_channel      => 'workflow_artifacts',
        p_checksum     => p_checksum,
        p_bucket       => p_bucket,
        p_object_key   => p_object_key,
        p_size_bytes   => p_size_bytes,
        p_content_type => p_content_type,
        p_title        => coalesce(p_title, t.step_key),
        p_org_id       => p_org_id,
        p_metadata     => jsonb_build_object('workflow', jsonb_build_object(
                              'run_id', t.run_id, 'task_id', t.id,
                              'step_key', t.step_key, 'attempt', t.attempts)),
        p_external_id  => p_task_id::text,
        p_trace_id     => (select trace_id from workflow.runs where id = t.run_id));

    -- register_upload's ON CONFLICT touches updated_at and nothing else, which
    -- is right for a puller re-seeing the same item and WRONG here: attempt 2
    -- of a task can legitimately produce different bytes, and leaving the
    -- resource pointed at attempt 1's file would be a failure that reports
    -- success. Repoint it, and mark it stored -- an artifact is retrievable
    -- the moment it lands and has no chunking stage to wait for.
    select id into v_file from content.files where checksum = p_checksum;
    update content.resources
       set file_id = v_file, status = 'stored', updated_at = now()
     where id = v_res
       and (file_id is distinct from v_file or status <> 'stored');

    return v_res;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The read side. Wraps content.resolve_file so a caller never needs a grant on
-- content.files -- which is granted to nobody, because content-hash dedup
-- leaves it with no single owner. Scoping therefore happens on the RESOURCE,
-- inside resolve_file, exactly as it does for an ordinary upload: an artifact
-- from another tenant's run is not visible here.
--
-- Returns jsonb, not a table, for the same reason workflow.p8ql does:
-- call_step_function wraps a step function's result as to_jsonb(fn(...)), and
-- a set-returning function under that produces "one row if there was one and
-- nothing at all otherwise" -- which a step would store as {"result": null}
-- and call success. RAISING instead makes an unreadable artifact a terminal
-- step failure (sqlstate P0001 is on execute_sql_step's do-not-retry list),
-- which is right: a ref that does not resolve resolves no better next time.
create or replace function workflow.artifact(p_resource_id uuid) returns jsonb as $$
declare v_out jsonb;
begin
    select to_jsonb(f) into v_out from content.resolve_file(p_resource_id) f;
    if v_out is null then
        raise exception
            'artifact % is not resolvable -- either no such resource, or it belongs '
            'to an org this caller cannot see. An artifact is scoped by its resource, '
            'not by the bucket it happens to sit in.', p_resource_id;
    end if;
    return v_out;
end;
$$ language plpgsql stable;

-- Both directions of the link, as one join, so "what did this run produce" and
-- "which step produced this file" are the same query read from either end.
create or replace view workflow.v_artifacts as
select t.run_id,
       t.id             as task_id,
       t.step_key,
       r.id             as resource_id,
       r.title,
       r.status,
       f.checksum,
       f.bucket,
       f.object_key,
       f.content_type,
       f.size_bytes,
       r.ingested_at
from workflow.tasks t
join content.resources r
  on r.id = workflow.artifact_ref(t.output)
left join content.files f on f.id = r.file_id;

grant execute on function workflow.register_artifact(uuid,text,text,text,bigint,text,text,uuid)
    to worker, authenticated;
grant execute on function workflow.artifact(uuid) to worker, authenticated;
grant select on workflow.v_artifacts to authenticated;

-- Registered so a downstream step can be handed an artifact by id and resolve
-- it in-database, which is what keeps class 4 from needing a worker just to
-- look something up: {{steps.render.$artifact}} is an ordinary argument.
select workflow.register_step_function(
    'artifact', 'workflow.artifact', array['uuid'], 30000,
    'Resolve a workflow artifact ref to its bucket, key, type and size');

-- ------------------------------------------------------------
-- 6. Self-check.
-- ------------------------------------------------------------
do $$
declare v_bad text;
begin
    -- files must not be readable by an API role: dedup means it has no single
    -- owner, so any row-level policy on it is meaningless and a grant would
    -- leak one tenant's storage keys to another.
    select string_agg(grantee, ', ') into v_bad
    from information_schema.role_table_grants
    where table_schema = 'content' and table_name = 'files'
      and grantee in ('web_anon','authenticated','api_viewer','worker');
    if v_bad is not null then
        raise exception
            'content.files is granted to %, but it is deduped by content hash and '
            'therefore has no single owner -- reads must go through '
            'content.resolve_file(), which is scoped by the resource.', v_bad;
    end if;

    -- The corpus the query layer documents must actually be registered.
    if not exists (select 1 from aiq.lexical_sources where name = 'chunks')
       or not exists (select 1 from aiq.semantic_sources where name = 'chunks') then
        raise exception 'the "chunks" source is not registered -- TEXT/SEMANTIC/SEARCH have no corpus';
    end if;

    -- An artifact channel with an ingest_workflow would start an ingestion run
    -- every time a step offloaded its output -- an infinite-ish source of runs
    -- nobody asked for, and the kind of thing that is only ever noticed by the
    -- bill. Cheap to assert, impossible to spot by reading.
    if exists (select 1 from content.channels
               where name = 'workflow_artifacts' and config ? 'ingest_workflow') then
        raise exception
            'the workflow_artifacts channel has an ingest_workflow configured -- '
            'every artifact a step produces would start an ingestion run. Artifacts '
            'are step OUTPUT, not intake.';
    end if;

    raise notice 'world-model-ingestion self-check passed: files unexposed; chunks corpus registered; artifact channel inert';
end $$;


-- ============================================================
-- agentic/schema.sql
--   agents, sessions, runs, messages -- the conversation plane
-- ============================================================

-- ============================================================
-- Agentic — sessions, runs, messages, agents, tool servers
--
-- The territory for `brief.md`'s §7 map. Loads after workflow-engine and
-- user-rbac (it references `workflow.tasks` and `rbac.current_user_id()`),
-- as app_owner, never as a superuser.
--
-- Three conventions inherited from this collection rather than re-decided,
-- because each was learned the hard way in `user-rbac/schema.sql`:
--
--   1. app_owner owns tables and SECURITY DEFINER functions; RLS is ENABLEd
--      but NOT FORCEd, so the trusted function path can still write.
--   2. The untrusted read path is `*_api` views owned by api_viewer -- a
--      DIFFERENT role from the table owner, which is what makes RLS actually
--      enforce through a view. PostgREST is pointed at the views.
--   3. Every SECURITY DEFINER function sets `search_path` explicitly and
--      qualifies every reference.
--
-- What is deliberately NOT here: anything the agent runtime could do itself.
-- The LLM call, the tool calls, and the SSE fan-out are outside SQL's reach
-- (brief.md §8); everything else in an agent turn is a row this file owns.
-- ============================================================

do $$
begin
    if (select usesuper from pg_user where usename = current_user) then
        raise exception
            'agentic/schema.sql must NOT be loaded as a superuser: superusers '
            'bypass RLS unconditionally, which would make every policy below '
            'silently inert (see user-rbac/schema.sql for the reproduction). '
            'Run: psql -c ''set role app_owner;'' -f schema.sql';
    end if;
end $$;


create schema if not exists agentic;

-- ------------------------------------------------------------
-- 1. Tool servers -- registered once, referenced by every agent (brief §5.2)
--
-- One row per MCP server or OpenAPI service. The runtime's entire tool
-- surface is this table plus agents.tools; there is no built-in tool, ever.
-- ------------------------------------------------------------
create table agentic.tool_servers (
    id              uuid primary key default gen_random_uuid(),
    name            text not null unique,
    kind            text not null check (kind in ('mcp', 'openapi')),
    url             text not null,
    -- An indirection, never a literal secret -- the same boundary
    -- workflow-engine's http_call draws. brief.md §9: this collection has no
    -- secrets mechanism yet, and this column is the seam one plugs into.
    credential_ref  text,
    -- brief.md §5.2/§5.3: which servers return citable retrieval results.
    -- A flag, not a tool-name convention -- ai-query-layer's server sets it,
    -- a ticketing API does not.
    emits_citations boolean not null default false,
    -- Which server is the runtime's own agent gateway (brief.md §5.1 item 3),
    -- i.e. whose tools ARE agents. Also a flag rather than a name prefix, and
    -- for a sharper reason than citations: delegation decides the persistence
    -- granularity (§2's slow path) and hands the callee a delegated-by header.
    -- Detecting it by an `agent__` prefix meant any registered MCP server could
    -- claim that namespace, and a server merely *named* `agent` produced it by
    -- accident through collision-prefixing.
    serves_agents   boolean not null default false,
    -- Non-secret headers sent on BOTH the registration fetch and every
    -- subsequent call. Not a general escape hatch and explicitly not where a
    -- secret goes -- that is `credential_ref`, one column up, and the check
    -- constraint below refuses the two header names that would carry one.
    --
    -- It exists because a base url does not always identify an OpenAPI
    -- document. This collection's own REST surface is the case that proved it:
    -- one PostgREST serves five schemas from one url and picks between them
    -- with `Accept-Profile`, so `http://postgrest:3000` resolves to the
    -- `content` document and the workflow operations an agent needs are
    -- invisible -- a bound server that looks correctly registered and is
    -- missing every tool the agent was given. §5.2's adapter is required to
    -- carry no per-service knowledge, so it cannot be taught to send that
    -- header; the row has to.
    default_headers jsonb not null default '{}'::jsonb,
    -- Synced at registration and refreshed by a scheduled workflow-engine
    -- task; NOT re-fetched per agent invocation.
    cached_tools    jsonb not null default '[]'::jsonb,
    synced_at       timestamptz,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

-- The one thing default_headers must never become. A secret in a header is
-- the same secret in a row that credential_ref exists to keep out, and it
-- would arrive there by an entirely reasonable-looking registration, so it is
-- refused by the table rather than by a convention in a reviewer's head.
--
-- Written against the lowercased document rather than with a subquery over
-- jsonb_object_keys, because a CHECK constraint may not contain a subquery at
-- all -- Postgres refuses the natural spelling outright. `?|` tests keys only,
-- so lowercasing the values along with them changes nothing.
alter table agentic.tool_servers add constraint tool_servers_headers_not_secrets
    check (not (lower(default_headers::text)::jsonb
                ?| array['authorization', 'proxy-authorization', 'cookie']));

create trigger trg_tool_servers_updated
    before update on agentic.tool_servers
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Agents -- config rows; adding one is an insert (brief §2, §6)
-- ------------------------------------------------------------
create table agentic.agents (
    id                       uuid primary key default gen_random_uuid(),
    name                     text not null unique,
    system_prompt            text not null default '',
    model                    text,
    -- References into tool_servers, never inline urls/credentials (§5.2):
    --   [{"server": "p8-query", "tools": ["semantic_search"] | null}]
    -- The optional per-server allowlist is also how an agent's delegation
    -- targets are narrowed, since the agent gateway is an ordinary MCP
    -- tool_servers row (§5.1 item 3).
    tools                    jsonb not null default '[]'::jsonb,
    structured_output_schema jsonb,
    -- {"kind": "pg_function"|"webhook", "target": "..."} (§4, §9)
    chained_action           jsonb,
    -- Who summarizes this agent's windowed-out history (§3). Null falls back
    -- to one system-wide default summarizer. Self-referencing on purpose:
    -- "who summarizes" is data, not code.
    summarizer_agent_id      uuid references agentic.agents(id),
    -- {"window_messages": int, "window_tokens": int,
    --  "summarize_after_messages": int} -- §9 leaves the numbers open, so
    -- they are per-agent data with a runtime default, not constants.
    context_policy           jsonb not null default '{}'::jsonb,

    -- ------------------------------------------------------------------
    -- Classification. Not decoration: this table is expected to hold
    -- THOUSANDS of rows, because the extractor pattern (§5.7) puts one
    -- specialist agent behind every (source, document type) pair -- the same
    -- shape as content.connectors holding hundreds of sources.
    --
    -- Once that is true, "list the agents" is useless without a filter, and
    -- an interactive UI that shows a user a thousand machine extractors is
    -- broken. `audience` is the column that fixes it and it is deliberately
    -- NOT derived from tags: whether a human may pick an agent is an access
    -- decision, and inferring it from a free-text tag would make it one a
    -- typo can change.
    -- ------------------------------------------------------------------
    audience                 text not null default 'internal'
                                 check (audience in ('user','internal','system')),
    -- What the agent is FOR. Closed, because an open list becomes a synonym
    -- pile within a month and the whole point is filtering.
    category                 text not null default 'general'
                                 check (category in
                                     ('general','extractor','summariser','classifier',
                                      'router','critic','tool_user','evaluator')),
    -- Free-text, for search rather than for control. Never load-bearing.
    tags                     text[] not null default '{}',
    -- For category='extractor': which (source, doctype) this specialist owns.
    -- Unique when set, so two extractors cannot silently claim one source.
    extracts_source          text,
    extracts_doctype         text,

    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now()
);

-- One specialist per (source, doctype). A second registration is a conflict to
-- resolve, not a fallback to pick between at runtime.
create unique index if not exists idx_agents_extractor
    on agentic.agents (extracts_source, extracts_doctype)
    where category = 'extractor';

create index if not exists idx_agents_audience on agentic.agents (audience)
    where audience = 'user';
create index if not exists idx_agents_category on agentic.agents (category);
create index if not exists idx_agents_tags     on agentic.agents using gin (tags);

-- An extractor without a declared output shape is a model call with extra
-- steps: the shape is what makes N extractions combinable and what makes a
-- bad answer RETRYABLE rather than silently wrong (workflow schema §21).
alter table agentic.agents add constraint agents_extractor_needs_schema
    check (category <> 'extractor' or structured_output_schema is not null);

create trigger trg_agents_updated
    before update on agentic.agents
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 3. Sessions -- one AG-UI thread; the unit a conversation is owned by
-- ------------------------------------------------------------
create table agentic.sessions (
    id             uuid primary key default gen_random_uuid(),
    user_id        uuid not null default rbac.current_user_id(),
    agui_thread_id text,
    title          text,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

create index on agentic.sessions (user_id, created_at desc);

create trigger trg_sessions_updated
    before update on agentic.sessions
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 4. Runs -- one agent invocation, delegated sub-runs included (brief §7)
--
-- The delegation tree IS the span tree: parent_span_id is the parent run's
-- own span_id, never independently maintained, and trace_id is shared across
-- an entire tree -- one trace per top-level session or scheduled trigger.
--
-- owner_id is not redundant with sessions.user_id (brief §3): a scheduled run
-- has no session, so scoping RLS through a session join would put background
-- runs outside tenant isolation entirely.
-- ------------------------------------------------------------
create table agentic.runs (
    id                      uuid primary key default gen_random_uuid(),
    session_id              uuid references agentic.sessions(id) on delete cascade,
    agent_id                uuid not null references agentic.agents(id),
    owner_id                uuid not null default rbac.current_user_id(),
    parent_run_id           uuid references agentic.runs(id) on delete cascade,
    delegated_by_message_id uuid,   -- FK added below, once messages exists
    trigger_kind            text not null default 'interactive'
                                check (trigger_kind in ('interactive','scheduled')),
    -- Set only for scheduled runs: the workflow-engine task that created this
    -- one, so retry/rate-limiting/observability come from that system's
    -- existing machinery rather than a second scheduler here (§3).
    workflow_task_id        uuid references workflow.tasks(id) on delete set null,
    trace_id                text,
    span_id                 text,
    parent_span_id          text,
    depth                   int not null default 0,
    state                   jsonb not null default '{}'::jsonb,
    status                  text not null default 'pending'
                                check (status in ('pending','running','succeeded',
                                                  'failed','cancelled','quota_exceeded')),
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now(),
    finished_at             timestamptz,
    constraint interactive_runs_have_a_session
        check (trigger_kind <> 'interactive' or session_id is not null),
    constraint scheduled_runs_name_their_task
        check (trigger_kind <> 'scheduled' or workflow_task_id is not null),
    constraint child_runs_are_deeper_than_their_parent
        check (parent_run_id is null or depth > 0)
);

create index on agentic.runs (session_id, created_at);
create index on agentic.runs (parent_run_id);
create index on agentic.runs (trace_id);
create index on agentic.runs (owner_id, created_at desc);
create index on agentic.runs (workflow_task_id) where workflow_task_id is not null;

create trigger trg_runs_updated
    before update on agentic.runs
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 5. Messages -- both persistence granularities in one table (brief §2)
--
-- Fast path: a user row and an assistant row, tool calls riding along as
-- JSONB. Slow path: discrete tool_call/tool_response rows -- mandatory when a
-- tool call IS a delegation, so the sub-run stays independently queryable
-- rather than buried in a blob. role='summary' is a third kind entirely: one
-- row per session, superseded rather than appended to (§3).
-- ------------------------------------------------------------
create table agentic.messages (
    id           uuid primary key default gen_random_uuid(),
    run_id       uuid references agentic.runs(id) on delete cascade,
    session_id   uuid references agentic.sessions(id) on delete cascade,
    role         text not null check (role in ('system','user','assistant',
                                               'tool_call','tool_response','summary')),
    content      text,
    tool_calls   jsonb not null default '[]'::jsonb,
    tool_call_id text,
    is_error     boolean not null default false,
    error_kind   text check (error_kind in ('tool_error','dispatch_error')),
    -- Derived by the runtime from this turn's tool_response rows, never
    -- authored by the LLM (§5.3). Tagged union, not one column meaning two
    -- things:  {"kind":"chunk","resource_type","resource_id","chunk_id"}
    --       |  {"kind":"node","node_id"}
    citations    jsonb not null default '[]'::jsonb,
    seq          bigserial,
    created_at   timestamptz not null default now(),
    constraint only_summaries_may_be_runless
        check (role = 'summary' or run_id is not null),
    constraint only_tool_responses_carry_errors
        check (role = 'tool_response' or (is_error = false and error_kind is null)),
    constraint only_assistants_carry_citations
        check (role = 'assistant' or citations = '[]'::jsonb)
);

-- One summary per session, enforced by the database rather than by the
-- application remembering to update instead of insert (§3).
create unique index one_summary_per_session
    on agentic.messages (session_id) where role = 'summary';
create index on agentic.messages (session_id, seq);
create index on agentic.messages (run_id, seq);

alter table agentic.runs
    add constraint runs_delegated_by_message_fk
    foreign key (delegated_by_message_id)
    references agentic.messages(id) on delete set null;

-- ------------------------------------------------------------
-- 6. Streaming -- NOTIFY per session, relayed as AG-UI events (brief §4)
--
-- Per session, not per run, and that is the whole trick: every run in a
-- session -- delegated sub-runs included -- publishes to the same channel
-- tagged with its own run_id, so multiplexing a delegation tree into one
-- client stream is structural rather than something the runtime arranges.
--
-- NOTIFY's payload limit is 8000 bytes, so the payload is a reference (ids +
-- role), never content: the relay reads the row back. Same discipline as
-- workflow-engine's payload_ref.
-- ------------------------------------------------------------
create or replace function agentic.channel_for(p_session_id uuid) returns text
language sql immutable as $$
    select 'agui_' || replace(p_session_id::text, '-', '');
$$;

create or replace function agentic.notify_message() returns trigger as $$
begin
    perform pg_notify(
        agentic.channel_for(new.session_id),
        -- Tagged like every other event on this channel: the relay forwards
        -- AG-UI events from the runtime as-is and treats this one as a
        -- persistence checkpoint (read the row, emit it if the live delta was
        -- missed), so a late-joining or reconnecting client is never left
        -- with a gap the stream alone can't fill.
        json_build_object(
            'type',       'MESSAGE_PERSISTED',
            'message_id', new.id,
            'run_id',     new.run_id,
            'role',       new.role,
            'seq',        new.seq
        )::text
    );
    return new;
end;
$$ language plpgsql
set search_path = pg_catalog, public, agentic;

create trigger trg_notify_message
    after insert on agentic.messages
    for each row when (new.session_id is not null)
    execute function agentic.notify_message();

-- ------------------------------------------------------------
-- 7. RLS -- ENABLE, not FORCE (see header note 1)
-- ------------------------------------------------------------
alter table agentic.sessions enable row level security;
alter table agentic.runs     enable row level security;
alter table agentic.messages enable row level security;

create policy sessions_owner on agentic.sessions
    for select using (user_id = rbac.current_user_id());

-- Scoped on the run's own owner, never through the session join: a scheduled
-- run has no session, and an escape hatch for that case is how a table ends up
-- with rows nobody can see and everybody can read (brief §3).
create policy runs_owner on agentic.runs
    for select using (owner_id = rbac.current_user_id());

create policy messages_via_run on agentic.messages
    for select using (
        exists (select 1 from agentic.runs r
                where r.id = messages.run_id
                  and r.owner_id = rbac.current_user_id())
        or exists (select 1 from agentic.sessions s
                   where s.id = messages.session_id
                     and s.user_id = rbac.current_user_id())
    );

-- Agents and tool_servers are configuration, not tenant data: readable by any
-- authenticated caller, writable only through the functions below. RLS is
-- ENABLEd with an explicitly permissive read policy rather than left off --
-- the two are equivalent to a reader today and completely different to the next
-- person to touch this file: "no policy" reads as an oversight, a policy that
-- says `true` reads as a decision, and it is the seam per-tenant agents would
-- attach to.
--
-- OPEN, and stated because it is a real consequence rather than an accident:
-- every authenticated user can therefore see, and run, every agent -- `/chat`'s
-- `model` field is just a name. A deployment that needs per-tenant agents needs
-- a column that does not exist yet (brief.md §9).
alter table agentic.agents       enable row level security;
alter table agentic.tool_servers enable row level security;

create policy agents_are_shared_config on agentic.agents
    for select using (true);
create policy tool_servers_are_shared_config on agentic.tool_servers
    for select using (true);
-- ------------------------------------------------------------
-- 8. The write path -- SECURITY DEFINER, ownership checked explicitly
--
-- DEFINER bypasses RLS, so each function re-checks what the policy would have:
-- these are the trusted path, and a trusted path that forgets to check is
-- indistinguishable from no policy at all.
-- ------------------------------------------------------------
create or replace function agentic.create_session(p_title text default null)
returns agentic.sessions
language sql security definer
set search_path = pg_catalog, public
as $$
    insert into agentic.sessions (user_id, title)
    values (rbac.current_user_id(), p_title)
    returning *;
$$;

create or replace function agentic.start_run(
    p_agent_name    text,
    p_session_id    uuid default null,
    p_parent_run_id uuid default null,
    p_delegated_by  uuid default null,
    p_trace_id      text default null,
    p_span_id       text default null,
    p_trigger_kind  text default 'interactive',
    p_workflow_task_id uuid default null
) returns agentic.runs
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_agent   agentic.agents;
    v_parent  agentic.runs;
    v_run     agentic.runs;
    v_owner   uuid := rbac.current_user_id();
    v_depth   int  := 0;
    v_pspan   text;
    v_trace   text := p_trace_id;
begin
    select * into v_agent from agentic.agents where name = p_agent_name;
    if not found then
        raise exception 'no agent named %', p_agent_name;
    end if;

    if p_session_id is not null then
        if not exists (select 1 from agentic.sessions
                       where id = p_session_id and user_id = v_owner) then
            raise exception 'session % is not yours', p_session_id;
        end if;

        -- One live turn per conversation. Two concurrent turns both reload the
        -- same window and both append to it, so the history each one saw is not
        -- the history that ends up stored -- a silent corruption, not an error.
        -- Delegated runs (parent_run_id set) are exempt: they happen *inside* a
        -- turn, which is the whole point.
        --
        -- Bounded by age deliberately: a runtime that dies mid-turn would
        -- otherwise leave a session wedged forever, and a stale `running` row
        -- is evidence of a crash, not of a live client.
        if p_parent_run_id is null and p_trigger_kind = 'interactive'
           and exists (
               select 1 from agentic.runs
                where session_id = p_session_id
                  and parent_run_id is null
                  and status = 'running'
                  and created_at > now() - interval '10 minutes'
           )
        then
            raise exception 'session % already has a turn in flight', p_session_id;
        end if;
    end if;

    if p_parent_run_id is not null then
        select * into v_parent from agentic.runs where id = p_parent_run_id;
        if not found or v_parent.owner_id <> v_owner then
            raise exception 'parent run % is not yours', p_parent_run_id;
        end if;
        -- The delegation tree and the trace tree are the same tree: a child's
        -- parent_span_id is simply its parent's span_id (brief §7).
        v_depth := v_parent.depth + 1;
        v_pspan := v_parent.span_id;
        v_trace := coalesce(v_trace, v_parent.trace_id);

        -- A hard ceiling, here and not only in the runtime. brief.md §9 leaves
        -- the *policy* number open and a runtime may set a lower one; this is
        -- the structural backstop, because start_run is granted to every
        -- authenticated caller and an app-side limit protects only callers who
        -- go through the app.
        if v_depth > 8 then
            raise exception 'delegation depth % exceeds the hard limit of 8', v_depth;
        end if;
    end if;

    insert into agentic.runs (session_id, agent_id, owner_id, parent_run_id,
                              delegated_by_message_id, trigger_kind,
                              workflow_task_id, trace_id, span_id,
                              parent_span_id, depth, status)
    values (p_session_id, v_agent.id, v_owner, p_parent_run_id,
            p_delegated_by, p_trigger_kind, p_workflow_task_id,
            coalesce(v_trace, encode(gen_random_bytes(16), 'hex')),
            coalesce(p_span_id, encode(gen_random_bytes(8), 'hex')),
            v_pspan, v_depth, 'running')
    returning * into v_run;
    return v_run;
end;
$$;

create or replace function agentic.finish_run(
    p_run_id uuid,
    p_status text,
    p_state  jsonb default null
) returns agentic.runs
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_run agentic.runs;
begin
    select * into v_run from agentic.runs where id = p_run_id;
    if not found or v_run.owner_id <> rbac.current_user_id() then
        raise exception 'run % is not yours', p_run_id;
    end if;

    update agentic.runs
       set status      = p_status,
           state       = coalesce(p_state, state),
           finished_at = case when p_status in ('pending','running')
                              then null else now() end
     where id = p_run_id
     returning * into v_run;
    return v_run;
end;
$$;

-- One RPC, one transaction: a half-written turn is not a state this database
-- can be left in (sequence.md Gate 2). Takes both granularities -- the caller
-- decides fast or slow path, the function does not care.
create or replace function agentic.persist_turn(p_rows jsonb)
returns setof agentic.messages
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_run_ids uuid[];
begin
    select array_agg(distinct (r->>'run_id')::uuid)
      into v_run_ids
      from jsonb_array_elements(p_rows) as r
     where r->>'run_id' is not null;

    if exists (select 1 from agentic.runs
               where id = any(v_run_ids) and owner_id <> rbac.current_user_id())
    then
        raise exception 'cannot write messages into a run that is not yours';
    end if;

    return query
    insert into agentic.messages (id, run_id, session_id, role, content, tool_calls,
                                  tool_call_id, is_error, error_kind, citations)
    -- The caller may supply the id, and for the assistant row it always does:
    -- the runtime mints that id before the turn runs so its streamed
    -- TEXT_MESSAGE_* deltas and this row are the same message (brief.md §4).
    -- Letting the database assign one instead silently breaks that -- the
    -- stream refers to a message id that never existed.
    select coalesce((r->>'id')::uuid, gen_random_uuid()),
           (r->>'run_id')::uuid,
           (r->>'session_id')::uuid,
           r->>'role',
           r->>'content',
           coalesce(r->'tool_calls', '[]'::jsonb),
           r->>'tool_call_id',
           coalesce((r->>'is_error')::boolean, false),
           r->>'error_kind',
           coalesce(r->'citations', '[]'::jsonb)
      from jsonb_array_elements(p_rows) with ordinality as t(r, ord)
     -- The ORDER BY is what makes `seq` follow conversation order rather than
     -- whatever order the planner felt like emitting rows in. Postgres assigns
     -- serial values in the order the INSERT's SELECT produces them; that is
     -- relied on here deliberately, and named so the reliance is visible.
     order by t.ord
    returning *;
end;
$$;

-- Superseded, never appended to -- the partial unique index makes that a
-- database guarantee, this function makes it a single round trip (§3).
create or replace function agentic.upsert_summary(p_session_id uuid, p_content text)
returns agentic.messages
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.messages;
begin
    if not exists (select 1 from agentic.sessions
                   where id = p_session_id and user_id = rbac.current_user_id()) then
        raise exception 'session % is not yours', p_session_id;
    end if;

    insert into agentic.messages (session_id, role, content)
    values (p_session_id, 'summary', p_content)
    on conflict (session_id) where role = 'summary'
    do update set content = excluded.content, created_at = now()
    returning * into v_row;
    return v_row;
end;
$$;

-- Configuration writes. brief.md §6 calls applying an agent a *migration*, not
-- a deploy -- these are what such a migration calls, and they are gated on the
-- same permission model everything else in this collection uses.
-- Who may author agents and tool servers, and the case the first version of
-- this check got wrong.
--
-- The rule for an ordinary caller is unchanged: a permission row, checked
-- against the identity in the JWT. What it missed is that the FIRST agent in
-- any deployment is registered by a migration -- there is no end user at
-- initdb, `rbac.current_user_id()` is null, and a null holds no permissions,
-- so every seeded agent failed with "not authorized" and the documented write
-- path could not be used to install the sample that documents it.
--
-- The bootstrap branch is deliberately narrow: no end-user identity at all,
-- AND a session that could have written the row with a plain INSERT anyway.
-- The second half is what keeps this from being a hole -- `session_user` is
-- the login role, not the SECURITY DEFINER owner, so it is `authenticator`
-- for anything arriving over REST, and authenticator holds no table grant by
-- design. A caller who can already write the table gains nothing from being
-- refused here except a reason to bypass this function.
-- The table is a separate argument rather than derived from the resource
-- name. They happen to match today, and building one from the other would
-- make a permission-vocabulary string (an untyped tag, per user-rbac's header
-- note) silently load-bearing on a table name.
create or replace function agentic.may_author(p_resource text, p_table regclass)
returns boolean
language sql stable security definer
set search_path = pg_catalog, public
as $$
    select rbac.has_permission(rbac.current_user_id(), p_resource, 'update')
        or (rbac.current_user_id() is null
            -- `session_user` is a reserved SQL expression, not a function
            -- in a schema: qualifying it the way this file qualifies
            -- everything else fails to parse ("missing FROM-clause entry for
            -- table pg_catalog"). Bare is the only spelling, and it is safe
            -- for the same reason -- a keyword cannot be shadowed by a
            -- search_path.
            and pg_catalog.has_table_privilege(session_user, p_table, 'insert'));
$$;

create or replace function agentic.upsert_agent(p_spec jsonb)
returns agentic.agents
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.agents;
begin
    if not agentic.may_author('agents', 'agentic.agents'::regclass) then
        raise exception 'not authorized to author agents';
    end if;

    -- Every column an author can set, including the classification block.
    -- Leaving audience/category out of this list -- which is how it was first
    -- written, because they were added to the table later -- does not fail: it
    -- silently defaults every agent to `internal`/`general`, so an agent
    -- authored as user-facing is accepted, reported as created, and then never
    -- appears in `agents_pickable`. A write path that cannot express a column
    -- the table has is a write path that quietly disagrees with its own schema.
    insert into agentic.agents (name, system_prompt, model, tools,
                                structured_output_schema, chained_action,
                                summarizer_agent_id, context_policy,
                                audience, category, tags,
                                extracts_source, extracts_doctype)
    values (p_spec->>'name',
            coalesce(p_spec->>'system_prompt', ''),
            p_spec->>'model',
            coalesce(p_spec->'tools', '[]'::jsonb),
            p_spec->'structured_output_schema',
            p_spec->'chained_action',
            (p_spec->>'summarizer_agent_id')::uuid,
            coalesce(p_spec->'context_policy', '{}'::jsonb),
            coalesce(p_spec->>'audience', 'internal'),
            coalesce(p_spec->>'category', 'general'),
            coalesce((select array_agg(value)
                        from jsonb_array_elements_text(p_spec->'tags')), '{}'),
            p_spec->>'extracts_source',
            p_spec->>'extracts_doctype')
    -- AN OMITTED KEY MEANS "LEAVE IT ALONE", NOT "SET IT TO THE DEFAULT".
    --
    -- Written the obvious way -- `set x = excluded.x` for every column -- this
    -- is a silent, total data-loss bug, and it fires on the most ordinary edit
    -- there is. `{"name": "percolate", "model": "openai:gpt-4.1-mini"}` is how
    -- anyone changes an agent's model. `excluded` carries the column DEFAULT
    -- for every key the caller did not send, so that call returned 200 and
    -- left the agent with an empty system prompt and no tools at all: the
    -- agent still existed, still resolved by name, and could do nothing.
    --
    -- Found by doing it. It is the same mistake as upsert_tool_server erasing
    -- cached_tools, which was fixed one function away and not here -- twice
    -- now this schema has shipped a partial write that reports success, so the
    -- rule is stated once and applied to every column: the presence of the KEY
    -- decides, never the emptiness of the value.
    on conflict (name) do update
       set system_prompt            = case when p_spec ? 'system_prompt'
                                      then excluded.system_prompt
                                      else agentic.agents.system_prompt end,
           model                    = case when p_spec ? 'model'
                                      then excluded.model
                                      else agentic.agents.model end,
           tools                    = case when p_spec ? 'tools'
                                      then excluded.tools
                                      else agentic.agents.tools end,
           structured_output_schema = case when p_spec ? 'structured_output_schema'
                                      then excluded.structured_output_schema
                                      else agentic.agents.structured_output_schema end,
           chained_action           = case when p_spec ? 'chained_action'
                                      then excluded.chained_action
                                      else agentic.agents.chained_action end,
           summarizer_agent_id      = case when p_spec ? 'summarizer_agent_id'
                                      then excluded.summarizer_agent_id
                                      else agentic.agents.summarizer_agent_id end,
           context_policy           = case when p_spec ? 'context_policy'
                                      then excluded.context_policy
                                      else agentic.agents.context_policy end,
           audience                 = case when p_spec ? 'audience'
                                      then excluded.audience
                                      else agentic.agents.audience end,
           category                 = case when p_spec ? 'category'
                                      then excluded.category
                                      else agentic.agents.category end,
           tags                     = case when p_spec ? 'tags'
                                      then excluded.tags
                                      else agentic.agents.tags end,
           extracts_source          = case when p_spec ? 'extracts_source'
                                      then excluded.extracts_source
                                      else agentic.agents.extracts_source end,
           extracts_doctype         = case when p_spec ? 'extracts_doctype'
                                      then excluded.extracts_doctype
                                      else agentic.agents.extracts_doctype end
    returning * into v_row;
    return v_row;
end;
$$;

create or replace function agentic.upsert_tool_server(p_spec jsonb)
returns agentic.tool_servers
language plpgsql security definer
set search_path = pg_catalog, public
as $$
declare
    v_row agentic.tool_servers;
begin
    if not agentic.may_author('tool_servers', 'agentic.tool_servers'::regclass) then
        raise exception 'not authorized to register tool servers';
    end if;

    insert into agentic.tool_servers (name, kind, url, credential_ref,
                                      emits_citations, serves_agents,
                                      default_headers, cached_tools, synced_at)
    -- kind and url are NOT NULL, so unlike every other column here they
    -- cannot be left to the ON CONFLICT arm: the tuple has to be VALID before
    -- Postgres will even look for the conflict, and a partial registration
    -- naming only the url therefore failed with a null-constraint violation on
    -- `kind` -- from an UPDATE path that would never have touched it. The
    -- existing row supplies them, which makes "omitted means unchanged" true
    -- on both arms rather than only on the one that is easy to write.
    values (p_spec->>'name',
            coalesce(p_spec->>'kind',
                     (select s.kind from agentic.tool_servers s
                       where s.name = p_spec->>'name')),
            coalesce(p_spec->>'url',
                     (select s.url from agentic.tool_servers s
                       where s.name = p_spec->>'name')),
            p_spec->>'credential_ref',
            coalesce((p_spec->>'emits_citations')::boolean, false),
            coalesce((p_spec->>'serves_agents')::boolean, false),
            coalesce(p_spec->'default_headers', '{}'::jsonb),
            coalesce(p_spec->'cached_tools', '[]'::jsonb),
            case when p_spec ? 'cached_tools' then now() end)
    -- Same rule as upsert_agent, and it reached every column here for the
    -- same reason: `cached_tools` was fixed alone because that is the column
    -- whose loss was noticed, while a registration omitting `credential_ref`
    -- or `default_headers` was quietly clearing those too -- and an unset
    -- credential_ref is what makes the NEXT sync anonymous and half-empty.
    on conflict (name) do update
       set kind            = case when p_spec ? 'kind'
                                  then excluded.kind
                                  else agentic.tool_servers.kind end,
           url             = case when p_spec ? 'url'
                                  then excluded.url
                                  else agentic.tool_servers.url end,
           credential_ref  = case when p_spec ? 'credential_ref'
                                  then excluded.credential_ref
                                  else agentic.tool_servers.credential_ref end,
           emits_citations = case when p_spec ? 'emits_citations'
                                  then excluded.emits_citations
                                  else agentic.tool_servers.emits_citations end,
           serves_agents   = case when p_spec ? 'serves_agents'
                                  then excluded.serves_agents
                                  else agentic.tool_servers.serves_agents end,
           default_headers = case when p_spec ? 'default_headers'
                                  then excluded.default_headers
                                  else agentic.tool_servers.default_headers end,
           cached_tools    = case when p_spec ? 'cached_tools'
                                  then excluded.cached_tools
                                  else agentic.tool_servers.cached_tools end,
           synced_at       = coalesce(excluded.synced_at, agentic.tool_servers.synced_at)
    returning * into v_row;
    return v_row;
end;
$$;

-- A chained-action target this system owns, and the reference example of the
-- shape (brief.md §4): the runtime calls <target>(jsonb) with the run's
-- structured output plus the run context that produced it --
--   {"run_id", "session_id", "agent", "trigger_kind", "output": {...}}
-- The context half is not optional: a chained action that only receives the
-- model's output cannot write anything scoped to the conversation it came
-- from, which is what both the summarizer here and §3's consolidation run need.
--
-- And `trigger_kind` is why the context needs to be more than ids. A chained
-- action fires whenever its agent produces structured output -- including when
-- that agent was invoked as somebody's *delegate* mid-conversation. The
-- summarizer delegated to by another agent would then overwrite the live
-- session's rolling summary with a compression of whatever it was asked. Found
-- by running it: an agent that delegated to the summarizer clobbered the
-- window summary of the conversation it was helping with. A session-scoped
-- write must therefore check *why* the run happened, not only where it sat.
-- The signature every chained-action target must have: jsonb in, jsonb out.
-- Not a style preference -- the runtime persists the result as an ordinary
-- tool_response message row, so it has to be JSON; a function returning a
-- composite type cannot even be decoded by the client (confirmed the hard way:
-- "text encoding of composite types is not supported").
create or replace function agentic.apply_summary(p_payload jsonb)
returns jsonb
language sql security definer
set search_path = pg_catalog, public
as $$
    select case
        when p_payload->>'trigger_kind' is distinct from 'scheduled'
            -- Not an error: the summarizer did its job, it simply was not the
            -- scheduled window-summarization run, so its output is a tool
            -- result for whoever delegated to it and nothing else.
            then jsonb_build_object('skipped', 'not a scheduled run')
        else to_jsonb(agentic.upsert_summary(
            (p_payload->>'session_id')::uuid,
            p_payload->'output'->>'summary'
        ))
    end;
$$;

-- ------------------------------------------------------------
-- 9. The read path -- *_api views owned by api_viewer (header note 2)
-- ------------------------------------------------------------
grant usage on schema agentic to web_anon, authenticated, api_viewer;

create view agentic.sessions_api as
    select id, user_id, agui_thread_id, title, created_at from agentic.sessions;
create view agentic.runs_api as
    select id, session_id, agent_id, owner_id, parent_run_id,
           delegated_by_message_id, trigger_kind, workflow_task_id,
           trace_id, span_id, parent_span_id, depth, state, status,
           created_at, finished_at
      from agentic.runs;
create view agentic.messages_api as
    select id, run_id, session_id, role, content, tool_calls, tool_call_id,
           is_error, error_kind, citations, seq, created_at
      from agentic.messages;
-- credential_ref is included, and that is deliberate rather than an oversight:
-- it is a *reference* ("env:X", "vault://path"), never the secret itself --
-- brief.md §5.2 forbids a literal secret in a row, so there is nothing here to
-- hide. Excluding it was tried first and is worse than useless: the runtime
-- reads its tool servers through this view like every other client, so hiding
-- the ref silently produced unauthenticated tool syncs -- a tool list that
-- looks correct and is missing every operation the caller's role would have
-- been allowed to see.
-- `default_headers` is in the view for the same reason and by the same rule:
-- the constraint on the table guarantees it holds no secret, and a caller that
-- cannot see it cannot reach the document it was registered against -- the
-- identical failure, one layer along.
create view agentic.tool_servers_api as
    select id, name, kind, url, credential_ref, emits_citations, serves_agents,
           default_headers, cached_tools, synced_at, created_at
      from agentic.tool_servers;
-- The view an interactive UI reads. `audience = 'user'` is the whole point of
-- the column: a thousand extractors are invisible here without anyone having
-- to remember to filter.
create or replace view agentic.agents_pickable as
select id, name, category, tags, model, structured_output_schema is not null as has_shape
from agentic.agents
where audience = 'user'
order by category, name;

-- The extractor fleet, as an operations surface. Mirrors
-- content.v_connectors: what exists, what it covers, and whether it is
-- contracted.
create or replace view agentic.v_extractors as
select name, extracts_source as source, extracts_doctype as doctype,
       model, tags,
       structured_output_schema is not null as has_shape,
       (select count(*) from jsonb_object_keys(
           coalesce(structured_output_schema->'properties','{}'::jsonb))) as n_slots
from agentic.agents
where category = 'extractor'
order by extracts_source, extracts_doctype;

-- The classification columns are in the view because the runtime reads agents
-- through it, and they are the columns that say what an agent IS FOR. Left out
-- (as they were, having been added to the table later) a client can see every
-- agent and sort them by nothing -- the state the classification block was
-- added to end, undone one layer along.
--
-- extracts_source/extracts_doctype belong here for the same reason and were
-- missed on the first pass anyway, which is the argument for checking this
-- mechanically rather than carefully: they are how a caller answers "which
-- extractor owns this document", and surface.sql's round-trip check found them
-- the first time it ran.
create view agentic.agents_api as
    select id, name, system_prompt, model, tools, structured_output_schema,
           chained_action, summarizer_agent_id, context_policy,
           audience, category, tags, extracts_source, extracts_doctype,
           created_at
      from agentic.agents;

grant select on agentic.sessions, agentic.runs, agentic.messages,
                agentic.agents, agentic.tool_servers to api_viewer;
grant execute on function rbac.current_user_id() to api_viewer;

-- Temporary CREATE, exactly as user-rbac does it: needed only for the
-- ownership transfer, revoked immediately after.
grant create on schema agentic to api_viewer;
alter view agentic.sessions_api     owner to api_viewer;
alter view agentic.runs_api         owner to api_viewer;
alter view agentic.messages_api     owner to api_viewer;
alter view agentic.tool_servers_api owner to api_viewer;
alter view agentic.agents_api       owner to api_viewer;
revoke create on schema agentic from api_viewer;

grant select on agentic.sessions_api, agentic.runs_api, agentic.messages_api,
                agentic.tool_servers_api, agentic.agents_api to authenticated;

grant execute on function agentic.create_session(text) to authenticated;
grant execute on function agentic.start_run(text, uuid, uuid, uuid, text, text, text, uuid)
    to authenticated;
grant execute on function agentic.finish_run(uuid, text, jsonb) to authenticated;
grant execute on function agentic.persist_turn(jsonb) to authenticated;
grant execute on function agentic.upsert_summary(uuid, text) to authenticated;
grant execute on function agentic.apply_summary(jsonb) to authenticated;
grant execute on function agentic.upsert_agent(jsonb) to authenticated;
grant execute on function agentic.upsert_tool_server(jsonb) to authenticated;
grant execute on function agentic.channel_for(uuid) to authenticated, api_viewer;

-- No base-table INSERT/UPDATE/DELETE grant to any PostgREST-facing role: the
-- write path is the functions above, and nothing else.

-- ------------------------------------------------------------
-- 10. Invariant self-checks -- the same two this collection has already been
--     bitten by, asserted at load time rather than trusted.
-- ------------------------------------------------------------
do $$
declare
    v_bad text;
begin
    -- (a) Every *_api view must be owned by api_viewer, NOT by the table
    -- owner: an owner-privileged view owned by the table owner bypasses RLS
    -- for every caller.
    select string_agg(c.relname, ', ')
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'agentic' and c.relkind = 'v'
       and c.relname like '%\_api'
       and pg_get_userbyid(c.relowner) <> 'api_viewer';
    if v_bad is not null then
        raise exception 'VIEW OWNERSHIP INVARIANT VIOLATED: % must be owned by '
                        'api_viewer, not the table owner', v_bad;
    end if;

    -- (b) No write grant on a base table for the PostgREST-facing roles.
    select string_agg(distinct table_name, ', ')
      into v_bad
      from information_schema.role_table_grants
     where table_schema = 'agentic'
       and grantee in ('web_anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE');
    if v_bad is not null then
        raise exception 'WRITE GRANT INVARIANT VIOLATED: % is writable directly; '
                        'the write path is the SECURITY DEFINER functions only', v_bad;
    end if;
end $$;
