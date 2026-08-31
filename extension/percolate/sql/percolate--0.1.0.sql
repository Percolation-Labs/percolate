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

create or replace function workflow.check_spec_before_insert() returns trigger as $$
begin
    perform workflow.validate_spec(new.spec);
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
-- 7. Payload-ref enforcement
-- ------------------------------------------------------------
-- The limit is a SETTING, not a literal, and the default was raised from 8KB
-- to 64KB after a real workflow hit it: a 768-dimension embedding is ~10KB as
-- JSON, and passing one from an embed step to a search step is a legitimate
-- intermediate, not a blob someone forgot to offload.
--
-- The guard's purpose is keeping multi-megabyte payloads out of the task
-- table, and 8KB was tight enough to reject ordinary structured values --
-- which pushes authors toward the $ref escape hatch for things that do not
-- warrant object storage, or (worse) toward not using the engine.
--
-- Still a hard limit rather than a warning: an unbounded payload column is how
-- a task table becomes unqueryable, and $ref remains the right answer for
-- anything genuinely large.
create or replace function workflow.enforce_payload_ref_size() returns trigger as $$
declare
    v_max int := coalesce(
        nullif(current_setting('workflow.max_payload_bytes', true), '')::int,
        65536);
begin
    if new.input is not null and pg_column_size(new.input) > v_max and not (new.input ? '$ref') then
        raise exception
            'task %: input payload is % bytes, over the % byte limit, and is not an S3 ref ($ref). '
            'Raise workflow.max_payload_bytes, or pass a $ref to object storage.',
            new.id, pg_column_size(new.input), v_max;
    end if;
    if new.output is not null and pg_column_size(new.output) > v_max and not (new.output ? '$ref') then
        raise exception
            'task %: output payload is % bytes, over the % byte limit, and is not an S3 ref ($ref). '
            'Raise workflow.max_payload_bytes, or return a $ref to object storage.',
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
create or replace function workflow.cascade_task_status() returns trigger as $$
begin
    if new.status is not distinct from old.status then
        return new;
    end if;

    if new.status = 'done' then
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
        -- cascade to direct dependents; their own transition to 'cancelled'
        -- fires this trigger again on their row, cascading to any depth
        update workflow.tasks t2
        set status = 'cancelled'
        where t2.status in ('pending', 'ready', 'waiting_external')
          and t2.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);
    end if;

    return new;
end;
$$ language plpgsql;

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

create or replace function workflow.check_run_completion(p_run_id uuid) returns void as $$
    update workflow.runs r
    set status = 'completed', completed_at = now()
    where r.id = p_run_id
      and r.status = 'running'
      and not exists (select 1 from workflow.tasks t where t.run_id = p_run_id and t.status <> 'done');
$$ language sql;

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
create or replace function workflow.start_workflow(p_name text, p_input jsonb, p_external_id text default null, p_trace_id text default null)
returns uuid as $$
declare
    v_def       workflow.definitions;
    v_run_id    uuid;
    v_step      jsonb;
    v_step_ids  jsonb := '{}'::jsonb;   -- step_key -> task id (as text)
    v_new_id    uuid;
    v_dep_key   text;
    v_dep_id    uuid;
    v_count     int;
begin
    if p_external_id is not null then
        select id into v_run_id from workflow.runs where external_id = p_external_id;
        if v_run_id is not null then
            return v_run_id;   -- idempotent: already started
        end if;
    end if;

    select * into v_def from workflow.definitions where name = p_name order by version desc limit 1;
    if v_def.id is null then
        raise exception 'no workflow_def found for name %', p_name;
    end if;

    insert into workflow.runs (workflow_def_id, input, external_id, trace_id)
    values (v_def.id, p_input, p_external_id, coalesce(p_trace_id, encode(gen_random_bytes(16), 'hex')))
    returning id into v_run_id;

    -- pass 1: create every step row, deps wired in pass 2
    for v_step in select * from jsonb_array_elements(v_def.spec->'steps')
    loop
        insert into workflow.tasks (run_id, step_key, queue, kind, pending_deps, status,
                                    wait_signal, input, rate_key,
                                    saga_group, compensation_task_key)
        values (
            v_run_id, v_step->>'key', coalesce(v_step->>'queue', 'default'),
            coalesce(v_step->>'kind', 'work'), 0, 'pending',
            -- wait_signal was NEVER populated here, which made the entire
            -- signal mechanism inert: signal_task() matches on
            -- (run_id, wait_signal, status), and with wait_signal null it can
            -- never match, so a `kind: signal` step waits forever. Confirmed
            -- by running it -- the task sat in waiting_external and no signal
            -- could ever resolve it. Defaults to the step's own key, so
            -- {"key":"approval","kind":"signal"} is signalled as 'approval'
            -- without needing a redundant "signal" field.
            case when coalesce(v_step->>'kind','work') = 'signal'
                 then coalesce(v_step->>'signal', v_step->>'key') end,
            -- Same class of omission: a step spec could declare input,
            -- rate_key, saga_group and compensation_task_key and they were all
            -- silently dropped, so saga/compensation and per-step rate limiting
            -- were unreachable through start_workflow() -- only through
            -- add_task(). Carried through now.
            v_step->'input',
            v_step->>'rate_key',
            v_step->>'saga_group',
            v_step->>'compensation_task_key'
        )
        returning id into v_new_id;
        v_step_ids := v_step_ids || jsonb_build_object(v_step->>'key', v_new_id::text);
    end loop;

    -- pass 2: wire deps now that all ids exist; set real pending_deps
    -- and flip roots ready/waiting_external directly (bypassing the
    -- insert-time trigger, which saw pending_deps=0 for everyone in pass 1)
    for v_step in select * from jsonb_array_elements(v_def.spec->'steps')
    loop
        v_new_id := (v_step_ids ->> (v_step->>'key'))::uuid;
        v_count := 0;

        for v_dep_key in select jsonb_array_elements_text(coalesce(v_step->'depends_on', '[]'::jsonb))
        loop
            v_dep_id := (v_step_ids ->> v_dep_key)::uuid;
            insert into workflow.task_dependencies (task_id, depends_on_task_id)
            values (v_new_id, v_dep_id)
            on conflict do nothing;
            v_count := v_count + 1;
        end loop;

        update workflow.tasks
        set pending_deps = v_count,
            status = case
                when v_count > 0 then 'pending'
                when kind = 'signal' then 'waiting_external'
                else 'ready'
            end
        where id = v_new_id;
    end loop;

    -- Kick any `sql` steps that are ready. THIS is the right place and the
    -- only one: the dependency graph is not valid until pass 2 finishes, and
    -- a root step is already 'ready' from mark_roots_ready, so the
    -- ready-transition trigger never sees an edge to fire on. Everything
    -- downstream is reached by that trigger via ordinary cascade; this call
    -- only starts the ones that begin the run. Safe when there are none --
    -- drain_sql_steps returns 0 without touching anything.
    perform workflow.drain_sql_steps(v_run_id);

    return v_run_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 10. Client API
-- ------------------------------------------------------------

create or replace function workflow.claim_task(p_queue text, p_worker_id text)
returns workflow.tasks as $$
declare t workflow.tasks;
begin
    update workflow.tasks
    set status = 'running', claimed_by = p_worker_id,
        claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
    where id = (
        select id from workflow.tasks
        where queue = p_queue and status = 'ready' and run_after <= now()
        order by priority desc, created_at
        for update skip locked
        limit 1
    )
    returning * into t;
    return t;
end;
$$ language plpgsql;

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

create or replace function workflow.claim_task_rate_limited(p_queue text, p_worker_id text)
returns workflow.tasks as $$
declare
    t workflow.tasks;
    v_lookahead int;
begin
    select coalesce(rate_lookahead, 20) into v_lookahead from workflow.queue_config where queue = p_queue;
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
$$ language plpgsql;

create or replace function workflow.heartbeat_task(p_task_id uuid)
returns boolean as $$
    update workflow.tasks set heartbeat_at = now()
    where id = p_task_id and status = 'running'
    returning not cancel_requested;
$$ language sql;

create or replace function workflow.complete_task(p_task_id uuid, p_output jsonb)
returns void as $$
declare v_run_id uuid;
begin
    -- CONTEXT FIRST, THEN STATUS. The order matters and is not stylistic:
    -- flipping the task to 'done' fires the cascade, which can mark a `sql`
    -- step ready, which auto-executes it IN THE SAME STATEMENT (§17). If the
    -- run's context has not been written yet, that step resolves
    -- {{steps.<this>.result}} against a context that does not contain this
    -- step's output and fails with 'template resolved to nothing'.
    -- Reproduced exactly that way: an embed step completed, and the P8QL step
    -- consuming its vector failed on the very output that had just been
    -- produced.
    select run_id into v_run_id from workflow.tasks where id = p_task_id;

    update workflow.runs r
    set context = context || jsonb_build_object(
            (select step_key from workflow.tasks where id = p_task_id), p_output),
        updated_at = now()
    where r.id = v_run_id;

    update workflow.tasks set status = 'done', output = p_output, completed_at = now()
    where id = p_task_id;

    perform workflow.check_run_completion(v_run_id);
    perform workflow.check_compensation_completion(v_run_id);
end;
$$ language plpgsql;

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
create or replace function workflow.fail_task(
    p_task_id uuid, p_error jsonb, p_terminal boolean default false)
returns void as $$
declare t workflow.tasks;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not p_terminal and t.attempts < t.max_attempts and not t.cancel_requested then
        update workflow.tasks set status = 'ready', error = p_error,
            run_after = now() + (power(2, t.attempts) * interval '1 second')
        where id = p_task_id;
    else
        update workflow.tasks set status = 'failed', error = p_error where id = p_task_id;
        update workflow.runs set status = 'failed' where id = t.run_id;
        -- dependent cascade now handled entirely by trg_cascade_task_status
        perform workflow.check_compensation_completion(t.run_id);
    end if;
end;
$$ language plpgsql;

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
create or replace function workflow.begin_compensation(p_run_id uuid, p_saga_group text)
returns void as $$
declare
    v_task          workflow.tasks;
    v_prev_comp_id  uuid := null;
    v_new_id        uuid;
begin
    update workflow.runs set compensation_state = 'compensating' where id = p_run_id;

    for v_task in
        select * from workflow.tasks
        where run_id = p_run_id and saga_group = p_saga_group
          and status = 'done' and compensation_task_key is not null and compensated_at is null
        order by completed_at desc
    loop
        v_new_id := workflow.add_task(
            p_run_id,
            v_task.compensation_task_key || ':' || v_task.id,   -- unique per compensated instance
            v_task.queue,
            case when v_prev_comp_id is not null then array[v_prev_comp_id] else '{}'::uuid[] end,
            'work',
            v_task.output    -- the compensation sees what the forward step produced
        );
        -- Tag the new task as a compensation and record WHICH forward task it
        -- undoes. check_compensation_completion() keys off this; without it,
        -- that function cannot distinguish a compensation task from a forward
        -- one and completes the saga before any compensation has run.
        update workflow.tasks set compensates_task_id = v_task.id where id = v_new_id;
        update workflow.tasks set compensated_at = now() where id = v_task.id;
        v_prev_comp_id := v_new_id;
    end loop;

    perform workflow.check_compensation_completion(p_run_id);
end;
$$ language plpgsql;

create or replace function workflow.signal_task(p_run_id uuid, p_signal text, p_payload jsonb)
returns void as $$
    update workflow.tasks
    set status = 'done', output = p_payload
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

create or replace function workflow.start_child_workflow(p_task_id uuid, p_workflow_name text, p_input jsonb)
returns uuid as $$
declare
    v_def_id uuid;
    v_child_run_id uuid;
begin
    select id into v_def_id from workflow.definitions where name = p_workflow_name order by version desc limit 1;
    insert into workflow.runs (workflow_def_id, parent_task_id, input)
    values (v_def_id, p_task_id, p_input)
    returning id into v_child_run_id;

    update workflow.tasks set child_run_id = v_child_run_id, status = 'waiting_external'
    where id = p_task_id;

    return v_child_run_id;
end;
$$ language plpgsql;

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
create or replace function workflow.complete_decision_task(
    p_task_id uuid,
    p_output jsonb,
    p_new_tasks jsonb default '[]'::jsonb
    -- [{step_key, queue, depends_on: [uuid,...], kind, input, rate_key}]
) returns void as $$
declare
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

    update workflow.tasks set status = 'done', output = p_output, completed_at = now(),
        decision_output_hash = v_new_hash
    where id = p_task_id;
    perform workflow.check_run_completion(v_run_id);
    perform workflow.check_compensation_completion(v_run_id);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 13. Timers
-- ------------------------------------------------------------
create or replace function workflow.promote_due_timers() returns int as $$
    with due as (
        update workflow.tasks set status = 'done', output = '{"fired": true}'::jsonb
        where kind = 'timer' and status = 'ready' and run_after <= now()
        returning id
    )
    select count(*)::int from due;
$$ language sql;
-- select cron.schedule('promote-timers', '*/10 seconds', $$select workflow.promote_due_timers()$$);

-- ------------------------------------------------------------
-- 14. Reaper
-- ------------------------------------------------------------
create or replace function workflow.reap_stale_tasks() returns int as $$
    with cfg as (
        select distinct t.queue, coalesce(qc.stale_timeout, interval '2 minutes') as timeout
        from workflow.tasks t
        left join workflow.queue_config qc on qc.queue = t.queue
        where t.status = 'running'
    ),
    dead as (
        update workflow.tasks t
        set status = 'ready', claimed_by = null, claimed_at = null
        from cfg
        where t.queue = cfg.queue
          and t.status = 'running'
          and t.heartbeat_at < now() - cfg.timeout
        returning t.id
    )
    select count(*)::int from dead;
$$ language sql;
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
alter function workflow.heartbeat_task(uuid)
    security definer set search_path = pg_catalog, public;
alter function workflow.complete_task(uuid, jsonb)
    security definer set search_path = pg_catalog, public;
alter function workflow.fail_task(uuid, jsonb, boolean)
    security definer set search_path = pg_catalog, public;
alter function workflow.complete_decision_task(uuid, jsonb, jsonb)
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
create or replace function workflow.get_task_context(p_task_id uuid, p_worker_id text)
returns jsonb as $$
declare
    v_task workflow.tasks;
    v_run  workflow.runs;
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

    return jsonb_build_object(
        'run_id',      v_run.id,
        'run_input',   coalesce(v_run.input, '{}'::jsonb),
        'context',     coalesce(v_run.context, '{}'::jsonb),
        'task_input',  coalesce(v_task.input, '{}'::jsonb),
        'step_key',    v_task.step_key,
        -- The worker dispatches to a handler by KIND, so it has to be told
        -- what it just claimed. Omitted at first, which forced the worker to
        -- guess from the shape of the input -- exactly the kind of inference
        -- that silently does the wrong thing when a task is malformed.
        'kind',        v_task.kind,
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
grant execute on function workflow.claim_task(text, text) to worker;
grant execute on function workflow.claim_tasks(text, text, int) to worker;
grant execute on function workflow.claim_task_rate_limited(text, text) to worker;
grant execute on function workflow.heartbeat_task(uuid) to worker;
grant execute on function workflow.complete_task(uuid, jsonb) to worker;
grant execute on function workflow.fail_task(uuid, jsonb, boolean) to worker;
grant execute on function workflow.complete_decision_task(uuid, jsonb, jsonb) to worker;
grant execute on function workflow.start_child_workflow(uuid, text, jsonb) to worker;
grant execute on function workflow.add_task(uuid, text, text, uuid[], text, jsonb, text) to worker;
grant execute on function workflow.get_task_context(uuid, text) to worker;

-- Scheduled maintenance (pg_cron, or an operator). Not the worker's job.
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
create or replace function workflow.register_step_function(
    p_name text, p_fn text, p_arg_types text[] default '{}',
    p_timeout_ms int default 30000, p_description text default null
) returns void as $$
begin
    if to_regprocedure(p_fn || '(' || array_to_string(p_arg_types, ',') || ')') is null then
        raise exception 'function %(%) does not exist', p_fn, array_to_string(p_arg_types, ',');
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
-- exists to express. Found by running a pipeline whose HYBRID step needed the
-- embedding produced by a preceding model call.
--
-- Deliberately narrower than the worker's resolver: no {{env.*}}, because the
-- database has no business reading the deployment's environment, and that is
-- precisely the sort of ambient authority this collection keeps removing.
create or replace function workflow.resolve_args(p_args jsonb, p_run_id uuid)
returns jsonb as $$
declare
    r        workflow.runs;
    v_out    jsonb := '[]'::jsonb;
    v_arg    jsonb;
    v_txt    text;
    v_ref    text;
    v_head   text;
    v_rest   text;
    v_val    jsonb;
begin
    select * into r from workflow.runs where id = p_run_id;

    for v_arg in select * from jsonb_array_elements(coalesce(p_args, '[]'::jsonb))
    loop
        v_txt := v_arg #>> '{}';
        -- Only a WHOLE-string reference is substituted, and it keeps its
        -- native type. Partial interpolation inside a larger string is the
        -- worker's job; here an argument is a value, not a template.
        if v_txt is not null and v_txt ~ '^\s*\{\{\s*[a-zA-Z0-9_.]+\s*\}\}\s*$' then
            v_ref  := trim(both from replace(replace(v_txt, '{{', ''), '}}', ''));
            v_head := split_part(v_ref, '.', 1);
            v_rest := substr(v_ref, length(v_head) + 2);
            if v_head = 'steps' then
                v_val := r.context #> string_to_array(v_rest, '.');
            elsif v_head = 'run' then
                v_val := r.input #> string_to_array(v_rest, '.');
            else
                raise exception
                    'unknown template namespace ''%'' in a sql step argument '
                    '-- expected steps or run', v_head;
            end if;
            if v_val is null then
                raise exception 'template ''%'' resolved to nothing', v_ref;
            end if;
            v_out := v_out || jsonb_build_array(v_val);
        else
            v_out := v_out || jsonb_build_array(v_arg);
        end if;
    end loop;
    return v_out;
end;
$$ language plpgsql stable;

create or replace function workflow.execute_sql_step(p_task_id uuid)
returns boolean as $$
declare
    t        workflow.tasks;
    r        workflow.runs;
    f        workflow.step_functions;
    v_spec   jsonb;
    v_args   jsonb;
    v_sql    text;
    v_out    jsonb;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found or t.status <> 'ready' or t.kind <> 'sql' then
        return false;
    end if;

    update workflow.tasks set status = 'running', claimed_by = 'in-database',
           claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
    where id = p_task_id;

    select * into r from workflow.runs where id = t.run_id;
    v_spec := coalesce(t.input, '{}'::jsonb);

    begin      -- subtransaction: a failure here must not abort the caller
        select * into f from workflow.step_functions where name = v_spec->>'function';
        if not found then
            raise exception
                'sql step names function ''%'', which is not registered. Register it with '
                'workflow.register_step_function() -- steps may not supply arbitrary SQL.',
                v_spec->>'function';
        end if;

        perform set_config('statement_timeout', f.timeout_ms::text, true);

        -- Arguments are passed as parameters, never interpolated: a step's
        -- args are data from the run, and building SQL text out of them would
        -- be injection with extra steps.
        v_args := workflow.resolve_args(coalesce(v_spec->'args', '[]'::jsonb), t.run_id);
        -- Each argument is extracted according to its REGISTERED type, not
        -- uniformly as text. Getting this wrong surfaces as
        -- "function f(text, text) does not exist" -- which reads as a missing
        -- function rather than a coercion problem, and cost real time.
        --   text   -> $1->>i      (JSON string to text)
        --   jsonb  -> $1->i       (the JSON value itself, structure intact)
        --   other  -> ($1->>i)::type
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
create or replace function workflow.drain_sql_steps(p_run_id uuid, p_max int default 50)
returns int as $$
declare v_id uuid; v_done int := 0;
begin
    loop
        select id into v_id from workflow.tasks
        where run_id = p_run_id and kind = 'sql' and status = 'ready'
          and run_after <= now()
        limit 1;
        exit when v_id is null or v_done >= p_max;
        perform workflow.execute_sql_step(v_id);
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
create or replace function workflow.autorun_sql_steps() returns trigger as $$
begin
    if new.kind = 'sql' and new.status = 'ready'
       and old.status is distinct from 'ready' then
        perform workflow.execute_sql_step(new.id);
    end if;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create trigger trg_autorun_sql_steps
    after update of status on workflow.tasks
    for each row execute function workflow.autorun_sql_steps();

grant execute on function workflow.execute_sql_step(uuid) to worker, authenticated;
grant execute on function workflow.drain_sql_steps(uuid, int) to worker, authenticated;
grant select on workflow.step_functions to worker, authenticated;

-- ============================================================
-- 18. YAML authoring: workflow.define_yaml()
--
-- The payoff of §17 plus the http_call handler: a workflow whose steps are
-- only P8QL and REST needs NO USER CODE ANYWHERE. The worker stops being
-- something a user writes and becomes something purely generic that ships.
--
--     name: classify_recent
--     steps:
--       - id: find
--         p8ql: 'HYBRID "safety recall" FROM chunks LIMIT 5'
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

create or replace function workflow.define_yaml(p_yaml text)
returns uuid as $$
declare
    c      jsonb;
    v_id   uuid;
    v_name text;
    v_ver  int;
begin
    if to_regprocedure('p8_compile_workflow(text)') is null then
        raise exception
            'workflow.define_yaml needs the percolate extension (p8_compile_workflow). '
            'This should be impossible -- the function is part of the same extension '
            'as this one.';
    end if;

    c := p8_compile_workflow(p_yaml);
    if not (c->>'ok')::boolean then
        -- The compiler's message names the offending step, so surface it as-is
        -- rather than wrapping it in something vaguer.
        raise exception 'workflow YAML did not compile: %', c->>'error';
    end if;

    v_name := c->'workflow'->>'name';
    v_ver  := coalesce((c->'workflow'->>'version')::int, 1);

    -- validate_spec() still runs via the insert trigger: the compiler checks
    -- that every `needs` names a real step, the engine checks reachability and
    -- cycles. Two different questions, both worth asking.
    insert into workflow.definitions (name, version, spec)
    values (v_name, v_ver, c->'workflow'->'spec')
    on conflict (name, version) do update set spec = excluded.spec
    returning id into v_id;

    return v_id;
end;
$$ language plpgsql;

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
create or replace function rbac.has_permission(p_user_id uuid, p_resource text, p_action text)
returns boolean as $$
    select exists (
        select 1 from rbac.user_roles ur
        join rbac.role_permissions rp on rp.role = ur.role
        where ur.user_id = p_user_id
          and rp.resource = p_resource
          and rp.action = p_action
    );
$$ language sql stable;

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
                        'cascade_task_status')
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

    update workflow.tasks
    set status = 'done', output = p_payload
    where run_id = p_run_id and wait_signal = p_signal and status = 'waiting_external';
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function workflow.cancel_run_unchecked(uuid) from public;
revoke execute on function workflow.assert_run_access(uuid, text) from public;
grant execute on function workflow.cancel_run(uuid) to authenticated;
grant execute on function workflow.signal_task(uuid, text, jsonb) to authenticated;


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
--   LOOKUP ... FUZZY -> pg_trgm over node_keys ONLY, never the data plane
--   SEMANTIC         -> pgvector over the embedding table for one entity type
--   GRAPH depth 1    -> GRAPH_TABLE over the property graph below
--   GRAPH depth n>1  -> WITH RECURSIVE over edges (PG19 has no quantified
--                       path patterns; confirmed empirically, brief.md §3)
--   SQL              -> read-only passthrough, SECURITY INVOKER (brief.md §3)
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
create unique index idx_node_keys_canonical
    on aiq.node_keys (org_id, key, entity_type) where kind = 'canonical';
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
        raise exception
            'relation (%s, %s, %s) is not in the catalogue -- add it to aiq.relation_types first',
            v_src_type, new.relation, v_dst_type;
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
    v_tbl_short text := split_part(p_source_table, '.', 2);
begin
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
    execute format($f$
        create or replace function aiq.project_%1$s_ins() returns trigger as $b$
        begin
            insert into aiq.nodes (entity_type, entity_id, org_id, summary)
            select %2$L, n.id, %3$s, %4$s from new_rows n where %5$s
            on conflict (entity_type, entity_id) do update
                set summary = excluded.summary, org_id = excluded.org_id,
                    updated_at = now();

            insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
            select nd.id, %2$L, lower(trim(%6$s)), 'canonical', %3$s
            from new_rows n
            join aiq.nodes nd on nd.entity_type = %2$L and nd.entity_id = n.id
            where %5$s
            -- DO UPDATE, not DO NOTHING: org_id scopes the canonical-key
            -- unique index, so leaving a stale copy on an existing key row
            -- silently corrupts that scoping after a tenancy change.
            on conflict (node_id, key, kind) do update set org_id = excluded.org_id;
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_tbl_short, p_entity_type, p_org_expr, p_summary_expr, p_include_where, p_key_expr);

    execute format($f$
        create or replace function aiq.project_%1$s_del() returns trigger as $b$
        begin
            delete from aiq.nodes
            where entity_type = %2$L and entity_id in (select id from old_rows);
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_tbl_short, p_entity_type);

    execute format('drop trigger if exists trg_aiq_project_ins on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_ins
            after insert on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.project_%2$s_ins();
    $f$, p_source_table, v_tbl_short);

    execute format('drop trigger if exists trg_aiq_project_upd on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_upd
            after update on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.project_%2$s_ins();
    $f$, p_source_table, v_tbl_short);

    execute format('drop trigger if exists trg_aiq_project_del on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_del
            after delete on %1$s
            referencing old table as old_rows
            for each statement execute function aiq.project_%2$s_del();
    $f$, p_source_table, v_tbl_short);
end;
$$ language plpgsql;

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
    if not found then raise exception 'entity type % not registered', p_entity_type; end if;

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

    get diagnostics v_count = row_count;
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
    if not found then raise exception 'entity type % not registered', p_entity_type; end if;

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

-- GRAPH depth 1: native SQL/PGQ. Confirmed working on PG19 beta3.
create or replace function aiq.graph_neighbors(
    p_node_id uuid, p_relation text default null, p_limit int default 100
) returns table(neighbor_id uuid, entity_type text, summary text,
                relation text, weight real, direction text) as $$
    select * from (
        select b.id, b.entity_type, b.summary, e.relation, e.weight, 'out'::text
        from graph_table (aiq.knowledge_graph
            match (a is node) -[e is related]-> (b is node)
            columns (a.id as a_id, b.id as b_id, e.relation as relation, e.weight as weight)
        ) g
        join aiq.nodes b on b.id = g.b_id
        join aiq.edges e on e.src_id = g.a_id and e.dst_id = g.b_id and e.relation = g.relation
        where g.a_id = p_node_id and (p_relation is null or g.relation = p_relation)
        union all
        -- The reverse question is first-class: no inverse edge is stored, so
        -- it is answered by walking dst_id, and the label comes from the
        -- catalogue at read time (graph-identity.md "Edge table").
        select a.id, a.entity_type, a.summary,
               coalesce(rt.inverse_label, e.relation || '_by'), e.weight, 'in'::text
        from aiq.edges e
        join aiq.nodes a on a.id = e.src_id
        join aiq.nodes b2 on b2.id = e.dst_id
        left join aiq.relation_types rt
               on rt.src_type = a.entity_type and rt.relation = e.relation
              and rt.dst_type = b2.entity_type
        where e.dst_id = p_node_id and (p_relation is null or e.relation = p_relation)
    ) x
    limit p_limit;
$$ language sql stable;

-- GRAPH depth n>1: WITH RECURSIVE. PG19's GRAPH_TABLE rejects quantified path
-- patterns outright ("element pattern quantifier is not supported") -- not a
-- beta gap to wait out, deliberately scoped out of the initial implementation
-- (brief.md §3). Depth- AND degree-capped, per graph-identity.md "Non-goals".
create or replace function aiq.graph_walk(
    p_node_id uuid, p_depth int default 2, p_relation text default null,
    p_max_nodes int default 500
) returns table(node_id uuid, entity_type text, summary text,
                depth int, path_relations text[]) as $$
    with recursive walk as (
        select n.id, n.entity_type, n.summary, 0 as depth,
               array[]::text[] as rels, array[n.id] as seen
        from aiq.nodes n where n.id = p_node_id
        union all
        select nx.id, nx.entity_type, nx.summary, w.depth + 1,
               w.rels || e.relation, w.seen || nx.id
        from walk w
        join aiq.edges e on (e.src_id = w.id or e.dst_id = w.id)
        join aiq.nodes nx on nx.id = case when e.src_id = w.id then e.dst_id else e.src_id end
        where w.depth < p_depth
          and not nx.id = any(w.seen)          -- cycle guard
          and (p_relation is null or e.relation = p_relation)
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
    select distinct on (id) id, entity_type, summary, depth, rels
    from walk where depth > 0
    order by id, depth
    limit p_max_nodes;
$$ language sql stable;

-- SEMANTIC: pgvector over one entity type's chunk table. Registered per type
-- rather than hardcoded, because the embedding table belongs to the consumer
-- (world-model-ingestion owns resource_chunks), not to this layer.
create table aiq.semantic_sources (
    name          text primary key,
    source_table  text not null,       -- schema-qualified, has (id, content, embedding)
    content_col   text not null default 'content',
    embedding_col text not null default 'embedding',
    link_expr     text                 -- optional SQL expr -> owning node's entity_id
);

create or replace function aiq.semantic(
    p_source text, p_query vector, p_limit int default 10
) returns table(chunk_id uuid, content text, distance float8) as $$
declare s aiq.semantic_sources;
begin
    select * into s from aiq.semantic_sources where name = p_source;
    if not found then raise exception 'semantic source % not registered', p_source; end if;
    return query execute format(
        'select c.id, c.%I::text, (c.%I <=> $1)::float8 as distance
         from %s c order by c.%I <=> $1 limit $2',
        s.content_col, s.embedding_col, s.source_table, s.embedding_col
    ) using p_query, p_limit;
end;
$$ language plpgsql stable;

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
    v_out    jsonb;
begin
    if to_regprocedure('aiq_parse(text)') is null then
        raise exception
            'aiq_parse is missing. It ships in the same extension as this '
            'function, so this should be impossible -- if you are seeing it, the '
            'extension is partially installed. The per-mode functions '
            '(aiq.lookup, aiq.graph_neighbors, aiq.graph_walk, aiq.semantic_in, '
            'aiq.lexical, aiq.hybrid) still work directly.';
    end if;
    p := aiq_parse(p_query);

    if not (p->>'ok')::boolean then
        raise exception 'query parse error: %', p->>'error';
    end if;

    case p->>'mode'
    when 'LOOKUP' then
        select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_out
        from aiq.lookup(p->>'arg', (p->>'fuzzy')::boolean, (p->>'limit')::int) l;

    when 'GRAPH' then
        -- Resolve the key ONCE, here, then traverse by id: the dialect names
        -- nodes by key, but traversal never parses names
        -- (graph-identity.md "Edges -- canonical, written directly").
        select node_id into v_node from aiq.lookup(p->>'arg', true, 1) limit 1;
        if v_node is null then
            return jsonb_build_object('mode','GRAPH','rows','[]'::jsonb,
                'error', format('no node matches key %L', p->>'arg'));
        end if;

        if (p->>'depth')::int <= 1 then
            select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) into v_out
            from aiq.graph_neighbors(v_node, p->>'relation', (p->>'limit')::int) g;
        else
            select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) into v_out
            from aiq.graph_walk(v_node, (p->>'depth')::int, p->>'relation',
                                (p->>'limit')::int) w;
        end if;

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
        select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_out
        from aiq.semantic_in(p_embedding, p->>'model', (p->>'limit')::int) s;

    when 'TEXT' then
        -- Lexical only. Needs no embedding at all, which is exactly why it
        -- answers the rare-exact-token case (§11) that SEMANTIC misses.
        select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_out
        from aiq.lexical(p->>'source', p->>'arg', (p->>'limit')::int) l;

    when 'HYBRID' then
        if p_embedding is null then
            raise exception
                'HYBRID fuses lexical and semantic ranks, so it needs p_embedding. '
                'Use TEXT ''%'' for the lexical half alone.', p->>'arg';
        end if;
        select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) into v_out
        from aiq.hybrid(p->>'source', p->>'arg', p_embedding, p->>'model',
                        (p->>'limit')::int) h;

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

    return jsonb_build_object('mode', p->>'mode', 'plan', p, 'rows', v_out);
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
-- ============================================================

create table aiq.embedding_models (
    name        text primary key,          -- 'nomic-embed-text', 'text-embedding-3-small'
    dim         int  not null check (dim > 0),
    provider    text not null,             -- 'ollama' | 'openai' | ...
    endpoint    text,                      -- resolved by the worker, not called from SQL
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

-- Each registered model gets its own storage table + HNSW index, generated
-- from the registry so the dimension and operator class can never drift from
-- what the model actually produces.
create or replace function aiq.register_embedding_space(p_model text)
returns void as $$
declare m aiq.embedding_models;
begin
    select * into m from aiq.embedding_models where name = p_model;
    if not found then raise exception 'embedding model % not registered', p_model; end if;

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

-- SEMANTIC against a named model (or the default when null). The caller still
-- supplies the vector -- embedding generation is an external model call (§4),
-- and which model produced that vector is now explicit rather than implied.
create or replace function aiq.semantic_in(
    p_query vector, p_model text default null, p_limit int default 10
) returns table(chunk_id uuid, distance float8, model text) as $$
declare
    m aiq.embedding_models;
    v_tbl text;
begin
    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then raise exception
            'no default embedding model -- set one, or name a model explicitly'; end if;
    else
        select * into m from aiq.embedding_models where name = p_model;
        if not found then raise exception 'embedding model % not registered', p_model; end if;
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

    v_tbl := 'emb_' || replace(m.name, '-', '_');
    return query execute format(
        'select e.chunk_id, (e.embedding <=> $1)::float8, %L
         from aiq.%I e order by e.embedding <=> $1 limit $2', m.name, v_tbl)
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
    if not found then raise exception 'lexical source % not registered', p_source; end if;
    return query execute format(
        'select c.id, c.%I::text, ts_rank(c.search_tsv, plainto_tsquery(%L, $1))::real
         from %s c where c.search_tsv @@ plainto_tsquery(%L, $1)
         order by ts_rank(c.search_tsv, plainto_tsquery(%L, $1)) desc limit $2',
        s.content_col, s.regconfig, s.source_table, s.regconfig, s.regconfig)
        using p_query, p_limit;
end;
$$ language plpgsql stable;

-- HYBRID: reciprocal rank fusion of lexical + semantic.
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
create or replace function aiq.hybrid(
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
        raise exception 'lexical source % not registered', p_lexical_source;
    end if;

    return query execute format($q$
    with lex as (
        select l.chunk_id, row_number() over (order by l.score desc)::int as rnk
        from aiq.lexical($1, $2, $4 * 4) l
    ),
    sem as (
        select s.chunk_id, row_number() over (order by s.distance asc)::int as rnk
        from aiq.semantic_in($3, $6, $4 * 4) s
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
            'SQL mode is read-only: statement starts with a write/DDL keyword';
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

-- user-rbac has no org model yet (specs/README.md scope decisions defer
-- tenant/org management deliberately). Rather than invent one here, the
-- predicate is expressed against a single function that a real deployment
-- replaces. Shipping a permissive default silently would be the worst option;
-- this one is explicit about being a seam, and errs closed for org-scoped rows
-- when no membership source exists.
-- Returns SETOF rather than an array, deliberately: `org_id = any (select ...)`
-- against an array-returning function compares uuid to uuid[] and fails, while
-- the array form `= any (f())` gives up the InitPlan hoisting that
-- user-rbac/schema.sql §9 measured as the difference between evaluating a
-- predicate once per query and once per row scanned. SETOF gives both --
-- `in (select ...)` type-checks and plans as a hashed SubPlan.
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
-- inherits no grants, making every SEMANTIC/HYBRID call against a newly
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
grant execute on function aiq.graph_neighbors(uuid, text, int) to authenticated;
grant execute on function aiq.graph_walk(uuid, int, text, int) to authenticated;
grant execute on function aiq.semantic_in(vector, text, int) to authenticated;
grant execute on function aiq.lexical(text, text, int) to authenticated;
grant execute on function aiq.hybrid(text, text, vector, text, int, int) to authenticated;
grant execute on function aiq.sql_passthrough(text) to authenticated;

-- Registry reads: an agent needs to know which models and sources exist to
-- form a valid query at all. Read-only, no row-level sensitivity.
grant select on aiq.embedding_models, aiq.lexical_sources,
                aiq.semantic_sources, aiq.relation_types to authenticated;

-- ------------------------------------------------------------
-- 3b. Consumer-owned content tables.
--
-- TEXT, SEMANTIC and HYBRID read the CONSUMER's tables (world-model
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

-- Two arities. SEMANTIC and HYBRID need a vector, which the database cannot
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
-- SEMANTIC and HYBRID are documented as working over "chunks", so the corpus
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
    status       text not null default 'pending'
                     check (status in ('pending','ready','failed','superseded')),
    metadata     jsonb not null default '{}'::jsonb,
    org_id       uuid,
    ingested_at  timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (channel_id, external_id)
);
create index idx_resources_channel on content.resources (channel_id, ingested_at desc);
create index idx_resources_org on content.resources (org_id);
create index idx_resources_status on content.resources (status) where status <> 'ready';

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
-- SECURITY INVOKER on purpose: this is a READ on behalf of a user, so it must
-- be subject to that user's RLS. Making it DEFINER would hand any caller any
-- tenant's storage keys -- the same distinction ai-query-layer's read path
-- draws for the same reason.
create or replace function content.resolve_file(p_resource_id uuid)
returns table(bucket text, object_key text, content_type text, size_bytes bigint) as $$
    select f.bucket, f.object_key, f.content_type, f.size_bytes
    from content.resources r
    join content.files f on f.id = r.file_id
    where r.id = p_resource_id;
$$ language sql stable security invoker;

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
-- world-model-ingestion <-> ai-query-layer + user-rbac integration.
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
        raise exception 'the "chunks" source is not registered -- TEXT/SEMANTIC/HYBRID have no corpus';
    end if;

    raise notice 'world-model-ingestion self-check passed: files unexposed; chunks corpus registered';
end $$;
