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
                         check (kind in ('work','decision','timer','signal','sub_workflow','http_call')),
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
create or replace function workflow.enforce_payload_ref_size() returns trigger as $$
begin
    if new.input is not null and pg_column_size(new.input) > 8192 and not (new.input ? '$ref') then
        raise exception 'task %: input payload exceeds 8KB and is not an S3 ref ($ref)', new.id;
    end if;
    if new.output is not null and pg_column_size(new.output) > 8192 and not (new.output ? '$ref') then
        raise exception 'task %: output payload exceeds 8KB and is not an S3 ref ($ref)', new.id;
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
create or replace function workflow.check_compensation_completion(p_run_id uuid) returns void as $$
    update workflow.runs
    set compensation_state = 'compensated'
    where id = p_run_id and compensation_state = 'compensating'
      and not exists (
          select 1 from workflow.tasks
          where run_id = p_run_id and compensation_task_key is not null
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
        insert into workflow.tasks (run_id, step_key, queue, kind, pending_deps, status)
        values (
            v_run_id, v_step->>'key', coalesce(v_step->>'queue', 'default'),
            coalesce(v_step->>'kind', 'work'), 0, 'pending'
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
    update workflow.tasks set status = 'done', output = p_output, completed_at = now()
    where id = p_task_id
    returning run_id into v_run_id;

    update workflow.runs r
    set context = context || jsonb_build_object((select step_key from workflow.tasks where id = p_task_id), p_output),
        updated_at = now()
    where r.id = v_run_id;

    perform workflow.check_run_completion(v_run_id);
    perform workflow.check_compensation_completion(v_run_id);
end;
$$ language plpgsql;

create or replace function workflow.fail_task(p_task_id uuid, p_error jsonb)
returns void as $$
declare t workflow.tasks;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if t.attempts < t.max_attempts and not t.cancel_requested then
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

create view workflow.v_compensation_status as
    select run_id, saga_group,
           count(*) filter (where compensated_at is not null) as compensated,
           count(*) as total_compensatable
    from workflow.tasks
    where saga_group is not null and compensation_task_key is not null
    group by run_id, saga_group;

create view workflow.v_decision_history as
    select te.run_id, te.task_id, t.step_key, te.input_snapshot, t.output as decision_output, te.at
    from workflow.task_events te
    join workflow.tasks t on t.id = te.task_id
    where t.kind = 'decision' and te.to_status = 'running'
    order by te.run_id, te.at;
