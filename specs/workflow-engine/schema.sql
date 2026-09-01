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

create extension if not exists pgcrypto;

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
-- exists to express. Found by running a pipeline whose SEARCH step needed the
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
--       - id: find
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
create or replace function workflow.resolve_args(p_args jsonb, p_run_id uuid, p_item jsonb)
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
        if v_txt is not null and v_txt ~ '^\s*\{\{\s*[a-zA-Z0-9_.]+\s*\}\}\s*$' then
            v_ref  := trim(both from replace(replace(v_txt, '{{', ''), '}}', ''));
            v_head := split_part(v_ref, '.', 1);
            v_rest := substr(v_ref, length(v_head) + 2);
            if v_head = 'steps' then
                v_val := r.context #> string_to_array(v_rest, '.');
            elsif v_head = 'run' then
                v_val := r.input #> string_to_array(v_rest, '.');
            elsif v_head = 'item' then
                -- Naming {{item.x}} in a step that is not a fan-out child is
                -- an authoring error, and it must not read as "the row had no
                -- such column" -- those need different fixes.
                if p_item is null then
                    raise exception
                        'template ''%'' names the item namespace, but this task is not a '
                        'matrix fan-out child -- {{item.*}} is only bound on tasks '
                        'expanded from a matrix step', v_ref;
                end if;
                v_val := p_item #> string_to_array(v_rest, '.');
            else
                raise exception
                    'unknown template namespace ''%'' in a sql step argument '
                    '-- expected steps, run or item', v_head;
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
                saga_group, compensation_task_key)
            values (
                t.run_id,
                t.step_key || '[' || v_i || ']',
                coalesce(v_tmpl->>'queue', t.queue),
                coalesce(v_tmpl->>'kind', 'work'),
                coalesce(v_tmpl->'input', '{}'::jsonb) || jsonb_build_object('item', v_row),
                v_tmpl->>'rate_key',
                0, 'ready', p_task_id, t.span_id,
                v_tmpl->>'saga_group',
                v_tmpl->>'compensation_task_key')
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
        perform workflow.complete_task(p_task_id, jsonb_build_object(
            'fanout',    coalesce(array_length(v_children, 1), 0),
            'rows_hash', v_hash,
            'source',    coalesce(v_spec#>>'{rows,function}', 'items')));
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
create or replace function workflow.complete_task(p_task_id uuid, p_output jsonb)
returns void as $$
declare
    v_run_id uuid;
    v_matrix uuid;
begin
    -- CONTEXT FIRST, THEN STATUS. The order matters and is not stylistic:
    -- flipping the task to 'done' fires the cascade, which can mark a `sql`
    -- step ready, which auto-executes it IN THE SAME STATEMENT (§17). If the
    -- run's context has not been written yet, that step resolves
    -- {{steps.<this>.result}} against a context that does not contain this
    -- step's output and fails with 'template resolved to nothing'.
    select run_id, matrix_parent_id into v_run_id, v_matrix
    from workflow.tasks where id = p_task_id;

    if v_matrix is null then
        update workflow.runs r
        set context = context || jsonb_build_object(
                (select step_key from workflow.tasks where id = p_task_id), p_output),
            updated_at = now()
        where r.id = v_run_id;
    else
        update workflow.runs set updated_at = now() where id = v_run_id;
    end if;

    update workflow.tasks set status = 'done', output = p_output, completed_at = now()
    where id = p_task_id;

    perform workflow.check_run_completion(v_run_id);
    perform workflow.check_compensation_completion(v_run_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

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
        -- what it just claimed.
        'kind',        v_task.kind,
        -- -> {{item.*}}. Null on every task that is not a matrix child.
        'item',        v_task.input->'item',
        'matrix_parent_step', (select m.step_key from workflow.tasks m
                               where m.id = v_task.matrix_parent_id),
        'attempt',     v_task.attempts,
        'trace_id',    v_run.trace_id,
        'span_id',     v_task.span_id
    );
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

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

create or replace function workflow.check_spec_before_insert() returns trigger as $$
begin
    perform workflow.validate_spec(new.spec);
    perform workflow.validate_matrix_steps(new.spec);
    return new;
end;
$$ language plpgsql;

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
create or replace function workflow.autorun_sql_steps() returns trigger as $$
begin
    if new.status = 'ready' and old.status is distinct from 'ready' then
        if new.kind = 'sql' then
            perform workflow.execute_sql_step(new.id);
        elsif new.kind = 'matrix' then
            perform workflow.expand_matrix(new.id);
        end if;
    end if;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.drain_sql_steps(p_run_id uuid, p_max int default 50)
returns int as $$
declare v_id uuid; v_kind text; v_done int := 0;
begin
    loop
        select id, kind into v_id, v_kind from workflow.tasks
        where run_id = p_run_id and kind in ('sql','matrix') and status = 'ready'
          and run_after <= now()
        order by kind, created_at
        limit 1;
        exit when v_id is null or v_done >= p_max;
        if v_kind = 'sql' then
            perform workflow.execute_sql_step(v_id);
        else
            perform workflow.expand_matrix(v_id);
        end if;
        v_done := v_done + 1;
    end loop;
    return v_done;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

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
create or replace function workflow.cascade_task_status() returns trigger as $$
begin
    if new.status is not distinct from old.status then
        return new;
    end if;

    if new.status = 'done' then
        if old.completed_at is not null then
            return new;   -- already cascaded on the first completion
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
        -- cascade to direct dependents; their own transition to 'cancelled'
        -- fires this trigger again on their row, cascading to any depth
        update workflow.tasks t2
        set status = 'cancelled'
        where t2.status in ('pending', 'ready', 'waiting_external')
          and t2.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);
    end if;

    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

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
grant execute on function workflow.resolve_args(jsonb, uuid, jsonb) to worker, authenticated;
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
