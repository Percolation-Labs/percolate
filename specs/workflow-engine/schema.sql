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
-- ------------------------------------------------------------
-- ONE HOME FOR THE LIFECYCLE VOCABULARY.
--
-- Three tables modelled the same idea with three different words for finishing
-- well: workflow.tasks said 'done', workflow.runs said 'completed',
-- agentic.runs said 'succeeded'. Nothing was wrong with any of them
-- individually, which is exactly why it survived -- and both run tables carry a
-- constraint called runs_status_check, so the wrong vocabulary read as the
-- right one. It cost a load-time assertion further down this file, added
-- because a purge written against the wrong word "would have purged NOTHING,
-- silently, forever, and reported a clean zero every time it ran".
--
-- The fix is not three lists that agree. It is one list, referenced. Every
-- status column below carries a foreign key into this table, so a typo or a
-- newly-invented state fails at the write instead of at the read that quietly
-- matches nothing. Which subset of these a given table may use stays a CHECK on
-- that table, because the sets genuinely differ: only a task can be `ready`,
-- only an agent run can be `quota_exceeded`.
--
-- `succeeded` rather than `completed` or `done`, and that is a correctness
-- argument rather than a preference: a failed run also completed, also
-- finished, is also done. Only `succeeded` is the actual opposite of `failed`,
-- so only that pair is mutually exclusive in MEANING and not merely in the
-- constraint. It is also what Kubernetes, Argo and Step Functions call it.
create table if not exists workflow.lifecycle_states (
    state       text primary key,
    is_terminal boolean not null,
    is_success  boolean not null default false,
    note        text not null
);

-- `do update`, NOT `do nothing`, because these rows are the EXTENSION's
-- (REM-68). The schema is replayed on every upgrade, so `do nothing` means a
-- corrected value reaches fresh installs only and every existing database keeps
-- the old one forever -- silently, because dev/upgrade-converges.sh compares
-- OBJECTS and cannot see a row. Whose rows these are is not a judgement call:
-- specs/contract/schema.sql §4's `deployment_tables` is the list, and this
-- table is not on it. Tables that ARE on it -- rbac.role_permissions, roles --
-- keep `do nothing`, because a deployment may edit them and an update would
-- overwrite somebody's change on every upgrade.
insert into workflow.lifecycle_states (state, is_terminal, is_success, note) values
    ('pending',          false, false, 'created, not yet eligible to run'),
    ('ready',            false, false, 'eligible: dependencies satisfied, awaiting a claim'),
    ('running',          false, false, 'claimed and executing'),
    ('waiting_external', false, false, 'suspended on a signal or timer from outside'),
    ('succeeded',        true,  true,  'finished, and did what it was asked'),
    ('failed',           true,  false, 'finished, and did not'),
    ('cancelled',        true,  false, 'stopped deliberately before finishing'),
    ('quota_exceeded',   true,  false, 'stopped because a budget ran out, not because it broke')
on conflict (state) do update
    set is_terminal = excluded.is_terminal,
        is_success  = excluded.is_success,
        note        = excluded.note;

grant select on workflow.lifecycle_states to authenticated, api_viewer;

-- THE TABLE ANSWERS THE QUESTION, rather than being a list beside the answers.
-- `is_terminal` and `is_success` were columns nothing read: every place that
-- needed "has this finished" wrote `status in ('succeeded','failed',
-- 'cancelled')` again -- nine times in this file alone, once in
-- world-model-ingestion, and in the tests, the browser and the eval suite. Each
-- copy is correct today and is a place a ninth state would have to be
-- remembered into, which is the shape `challenge-the-process` §9 names: push
-- the whole fact, not the label (REM-52).
--
-- STABLE, not immutable, because the answer is rows -- so these cannot be used
-- in an index predicate or a CHECK, and are not: which subset of the vocabulary
-- a table admits stays a CHECK on that table, for the reason above.
create or replace function workflow.is_terminal(p_status text)
returns boolean language sql stable parallel safe
set search_path = pg_catalog, public as $$
    select coalesce((select s.is_terminal from workflow.lifecycle_states s
                      where s.state = p_status), false);
$$;

create or replace function workflow.is_success(p_status text)
returns boolean language sql stable parallel safe
set search_path = pg_catalog, public as $$
    select coalesce((select s.is_success from workflow.lifecycle_states s
                      where s.state = p_status), false);
$$;

comment on function workflow.is_terminal(text) is
    'Has a run, task or step in this status finished, by the vocabulary rather '
    'than by a list written down beside it.';
comment on function workflow.is_success(text) is
    'Did it finish AND do what it was asked. A failed run also completed.';

grant execute on function workflow.is_terminal(text), workflow.is_success(text)
    to authenticated, api_viewer, worker, scheduler;

create table if not exists workflow.definitions (
    id          uuid primary key default uuidv7(),
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

-- WHICH VERSION A NAME MEANS, in one place, because three callers were each
-- answering it and two of them answered it differently from the column above.
--
-- `deleted_at` says what it is for in its own comment -- "don't start new runs
-- against this version" -- and nothing enforced that. plan_catalog, plan_graph,
-- plan_document, plan_defects, plan_probe, definitions_api and
-- aiq.schema_workflow all filter `deleted_at is null`; start_workflow resolved
-- `order by version desc limit 1` with no filter, and start_child_workflow and
-- schedule_workflow gated on a bare `exists`. So a retired latest version was
-- hidden from every list and still started, which is the one outcome the column
-- was added to prevent (REM-58).
--
-- Latent rather than live: nothing in core sets `deleted_at` today. That is the
-- reason to fix it now and not the reason to leave it -- the defect is not
-- reachable, so the fix cannot break a caller, and it stops being true the
-- moment anybody retires a definition.
--
-- Returns the ROW, so start_workflow keeps taking `spec` from the same read
-- that chose the version. Two reads could disagree under a concurrent publish.
create or replace function workflow.current_definition(p_name text)
returns workflow.definitions as $$
    select d.* from workflow.definitions d
     where d.name = p_name and d.deleted_at is null
     order by d.version desc
     limit 1;
$$ language sql stable;

comment on function workflow.current_definition(text) is
    'The version of this workflow a new run should use: the highest that has '
    'not been retired. The one answer -- start_workflow, start_child_workflow '
    'and schedule_workflow all read it, so "listed" and "startable" cannot '
    'drift apart.';

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

        -- A `sql` step names a registered function OR carries its own
        -- statement. Exactly one, checked here rather than left to dispatch,
        -- because a spec can arrive as JSON without passing the compiler and
        -- the failure otherwise is `step names function 'null'` several minutes
        -- into a run.
        if v_step->>'kind' = 'sql' then
            if (v_step->'input' ? 'statement') = (v_step->'input' ? 'function') then
                raise exception
                    'sql step ''%'' must carry exactly one of `statement` (its own SQL) or '
                    '`function` (a name workflow.step_functions holds) -- it has %',
                    v_step->>'key',
                    case when v_step->'input' ? 'statement' then 'both' else 'neither' end;
            end if;
            if (v_step->'input' ? 'statement')
               and coalesce(btrim(v_step->'input'->>'statement'), '') = '' then
                raise exception 'sql step ''%'' carries an empty statement', v_step->>'key';
            end if;
        end if;
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

create or replace trigger trg_check_spec_before_insert
    before insert or update of spec on workflow.definitions
    for each row execute function workflow.check_spec_before_insert();

-- ------------------------------------------------------------
-- 2. Workflow runs
-- ------------------------------------------------------------
create table if not exists workflow.runs (
    id               uuid primary key default uuidv7(),
    workflow_def_id  uuid not null references workflow.definitions(id),
    parent_task_id   uuid,
    -- caller-supplied idempotency key for workflow.start_workflow.
    --
    -- NOT `unique` HERE, for the same reason the status CHECK is not: the key
    -- is unique PER OWNER rather than per installation (REM-77), and a unique
    -- constraint written inside `create table if not exists` reaches fresh
    -- installs only. So it is declared once as a drop-then-add index near the
    -- end of this file -- globally, because the engine standalone has no
    -- owners to scope it by -- and integration-rbac.sql §(e) narrows that same
    -- index to (owner, key) once identities exist. Both are convergent, so a
    -- fresh install and an upgraded one end on the same one index.
    external_id      text,
    -- The CHECK is not here. It is one drop-then-add near the end of this
    -- file, with the tasks one beside it, so which subset of the vocabulary a
    -- table admits is stated once and an existing installation picks up a
    -- change to it. Written in both places, a fresh install and an upgraded
    -- one differed by one word and nothing said so (REM-52).
    status           text not null default 'running',
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
create table if not exists workflow.tasks (
    id               uuid primary key default uuidv7(),
    run_id           uuid not null references workflow.runs(id) on delete cascade,
    step_key         text not null,
    -- http_call: a durable outbound HTTP dispatch, claimed and executed by a
    -- GENERIC worker (no per-consumer code) -- spec.md §14. Needs no new
    -- columns: `input` carries the call spec
    -- ({"url","method","headers"?,"credential_ref"?,"body"?,"timeout_ms"?,
    -- "mode":"sync"|"async"}), `output` carries the response, existing
    -- max_attempts/run_after drive retry/backoff exactly like any other kind.
    -- NO INLINE CHECK. The admissible kinds are declared ONCE, by the
    -- `alter table ... add constraint tasks_kind_check` further down this file,
    -- and this column deliberately carries no second copy of them.
    --
    -- Which of the two copies to delete is not a coin toss. `create table if
    -- not exists` is a no-op on a database that already has the table, so an
    -- inline CHECK only ever applies to fresh installs -- and the upgrade
    -- script is this file replayed, which is the path every existing
    -- deployment takes. That is exactly how `matrix` came to be admitted by
    -- one of three declarations: it was added to the ALTER, which runs
    -- everywhere, and the inline copies went on saying something else. The
    -- shipped behaviour was right by luck of ordering, since the last
    -- declaration wins.
    --
    -- So the ALTER is the home that works on both paths, and this is the copy
    -- that goes. Found by `dev/vocab-audit.py`, which pairs vocabularies on
    -- their contents and reported one column declared three times, differently.
    kind             text not null default 'work',
    queue            text not null default 'default',
    status           text not null default 'pending',   -- CHECK: see runs.status
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
    completed_at     timestamptz,          -- set on 'succeeded'; drives saga reverse-order compensation
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

create or replace trigger trg_workflow_runs_touch before update on workflow.runs
    for each row execute function public.touch_updated_at();
create or replace trigger trg_tasks_touch before update on workflow.tasks
    for each row execute function public.touch_updated_at();

-- THE CLAIM INDEX MUST MATCH THE CLAIM'S ORDER BY, AND THIS ONE DID NOT.
--
-- It was (queue, priority, run_after), which looks right and is not: claim_task
-- orders by `priority desc, created_at`, and `created_at` is not in the index
-- at all. That costs nothing while a queue is shallow, because the planner
-- reads a few rows either way -- and it is catastrophic once a queue is deep,
-- because every row matches the predicate, so the index offers no selectivity
-- and the planner correctly abandons it for a sequential scan plus a sort of
-- the ENTIRE ready set, to return twenty rows.
--
-- MEASURED on PG19beta3, 1M ready tasks on one queue, 8 concurrent workers
-- (dev/scale/):
--
--     (queue, priority, run_after)          7.6 claims/s   1050 ms mean
--     (queue, priority desc, created_at)   14243 claims/s   0.56 ms mean
--
-- A single claim went from 40.4 ms to 0.031 ms and stopped spilling 19 MB of
-- external merge sort to disk per claim, per worker. The shape of the failure
-- is what makes it worth this comment: it is invisible on a fixture, it is
-- invisible in every test this repo had, and it appears only under exactly the
-- load the engine exists to absorb.
--
-- `priority desc` is written out rather than left to a reverse scan because
-- the mixed direction (`desc, asc`) cannot be served by scanning one index
-- backwards -- that would reverse both keys.
create index if not exists idx_tasks_claimable on workflow.tasks (queue, priority desc, created_at)
    where status = 'ready';

-- The autoscaler's index. queue_depth() counts ready-and-due plus running, and
-- with only the claim index the planner serves it from a bitmap OR when the
-- live set is small and falls back to a parallel sequential scan when it is
-- large -- which is precisely when the autoscaler is being asked to grow the
-- pool. MEASURED at a 1M-row table with ~300k live: 30,733 buffers and 86 ms
-- inside the function, against 867 buffers and an index-only scan with this.
--
-- Deliberately NOT indexing run_after's predicate: `run_after <= now()` is not
-- immutable and cannot appear in a partial index's WHERE. It rides as an
-- indexed column so the filter is answered without a heap fetch.
create index if not exists idx_tasks_live on workflow.tasks (queue, status, run_after)
    where status in ('ready', 'running');
create index if not exists idx_tasks_run on workflow.tasks (run_id);
create index if not exists idx_tasks_heartbeat on workflow.tasks (status, heartbeat_at) where status = 'running';
create index if not exists idx_tasks_signal on workflow.tasks (wait_signal) where status = 'waiting_external';

create table if not exists workflow.task_dependencies (
    task_id             uuid not null references workflow.tasks(id) on delete cascade,
    depends_on_task_id  uuid not null references workflow.tasks(id) on delete cascade,
    primary key (task_id, depends_on_task_id)
);
create index if not exists idx_task_deps_reverse on workflow.task_dependencies (depends_on_task_id);

-- ------------------------------------------------------------
-- 4. Per-queue config
-- ------------------------------------------------------------
create table if not exists workflow.queue_config (
    queue          text primary key,
    stale_timeout  interval not null default interval '2 minutes',
    rate_lookahead int not null default 20
);

-- ------------------------------------------------------------
-- 5. Rate limiting
-- ------------------------------------------------------------
create table if not exists workflow.rate_limits (
    key         text primary key,
    capacity    numeric not null,
    tokens      numeric not null,
    refill_rate numeric not null,
    updated_at  timestamptz not null default now()
);

-- THE BUCKET'S INVARIANTS, WHERE THEY CAN BE REFUSED RATHER THAN INTENDED.
--
-- `0 <= tokens <= capacity` is the whole definition of a token bucket, and it
-- was enforced by nothing: the admission test below read an UNCAPPED refill
-- while the write applied a capped one, so the two disagreed for any amount
-- larger than the bucket. Measured on a live database, before the WHERE clause
-- was fixed: capacity 1, idle 100 seconds, consume 5 -> admitted, and the row
-- left holding -4 tokens. A negative amount was accepted the same way and
-- minted 1000 tokens into a bucket of 1.
--
-- Neither was reachable from the shipped callers -- claim_tasks and
-- rbac.attempt_login both consume exactly 1 against a capacity of 2 or more --
-- which is precisely why it needed a constraint rather than a fix: the defect
-- was invisible from every call site that existed, and the next call site is
-- the one that would have found it. §9's rule, applied to arithmetic.
--
-- Written drop-then-add, not inside the CREATE TABLE above, so an installation
-- that already has the table picks them up (the discipline runs_status_check
-- is written with). The clamp runs first because a database that ran the old
-- function may be holding a row these constraints refuse; it is idempotent and
-- a no-op on every row written by the corrected function.
--
-- `capacity` is deliberately NOT clamped. A bucket declaring no capacity is a
-- configuration mistake rather than an arithmetic one -- it reads as "blocked"
-- and admits one request per refill period -- and there is no value to silently
-- substitute for it. An upgrade carrying such a row fails on
-- rate_limits_capacity_check by name, which is where that should be found.
update workflow.rate_limits
   set tokens = least(greatest(tokens, 0), capacity)
 where tokens < 0 or tokens > capacity;

alter table workflow.rate_limits drop constraint if exists rate_limits_capacity_check;
alter table workflow.rate_limits add  constraint rate_limits_capacity_check
    check (capacity > 0);
alter table workflow.rate_limits drop constraint if exists rate_limits_refill_check;
alter table workflow.rate_limits add  constraint rate_limits_refill_check
    check (refill_rate >= 0);
alter table workflow.rate_limits drop constraint if exists rate_limits_tokens_check;
alter table workflow.rate_limits add  constraint rate_limits_tokens_check
    check (tokens >= 0 and tokens <= capacity);

-- ONE EXPRESSION FOR THE REFILL, read by both the test and the write.
--
-- The bug was that there were two: `least(capacity, refilled) - p_amount` on
-- the SET and a bare `refilled >= p_amount` on the WHERE. They agree only
-- while p_amount <= capacity, which is a condition no caller states and none
-- of them could see. Naming the capped value once removes the pair.
create or replace function workflow.try_consume_rate_limit(p_key text, p_amount numeric default 1)
returns boolean as $$
declare v_ok boolean;
begin
    -- A refusal, not a top-up: a bucket cannot be filled by asking it for a
    -- negative amount, and a caller that meant to add capacity should say so
    -- by updating the row.
    if p_amount is null or p_amount <= 0 then
        raise exception 'rate limit amount must be positive, got %', p_amount;
    end if;

    update workflow.rate_limits
    set tokens = least(capacity, tokens + refill_rate * extract(epoch from now() - updated_at)) - p_amount,
        updated_at = now()
    where key = p_key
      and least(capacity, tokens + refill_rate * extract(epoch from now() - updated_at)) >= p_amount
    returning true into v_ok;
    return coalesce(v_ok, false);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 6. Audit log
-- ------------------------------------------------------------
create table if not exists workflow.task_events (
    id             bigint generated always as identity primary key,
    task_id        uuid not null,
    run_id         uuid not null,
    from_status    text,
    to_status      text not null,
    input_snapshot jsonb,
    detail         jsonb,
    at             timestamptz not null default now()
);
create index if not exists idx_task_events_run on workflow.task_events (run_id, at);

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

create or replace trigger trg_log_task_transition
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

create or replace trigger trg_enforce_payload_ref_size
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
    v_satisfies := workflow.is_success(new.status)
                   or (workflow.is_terminal(new.status) and new.tolerate_failure);

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
              and not workflow.is_terminal(status);

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

    elsif workflow.is_terminal(new.status) then
        update workflow.tasks t2
        set status = 'cancelled'
        where t2.status in ('pending', 'ready', 'waiting_external')
          and t2.id in (select task_id from workflow.task_dependencies where depends_on_task_id = new.id);
    end if;

    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger trg_cascade_task_status
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

create or replace trigger trg_mark_roots_ready
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

create or replace trigger trg_notify_new_ready
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
            and not workflow.is_terminal(status)
      );
$$ language sql;

-- ------------------------------------------------------------
-- 8b. pending_deps, decided in ONE place.
--
-- `pending_deps` is a cached count of this task's rows in
-- workflow.task_dependencies, and it was maintained by three functions that
-- each counted the caller's list and then inserted the rows `on conflict do
-- nothing`. Those two operations disagree the moment a caller names the same
-- dependency twice -- `needs: [a, a]` in YAML, or `array[t, t]` into add_task
-- -- because the primary key collapses the second row and nothing collapsed
-- the second count. The task is then created with pending_deps = 2 against one
-- dependency row, the cascade decrements once, and the task sits at
-- pending_deps = 1 in `pending` FOR EVER.
--
-- That failure is the worst shape this engine has: no error, no failed task,
-- no reaper interest (the reaper collects `running` leases, and this task
-- never ran), and a run stuck at `running` with nothing claimable. Confirmed
-- by doing it, through both entry points, before this function existed.
--
-- So the count is derived from the same set the insert is: DISTINCT ids. One
-- home for the rule (§8), and the locking that workflow.add_task's "fix #1"
-- comment describes moves in here with it -- every dependency row is locked
-- FOR UPDATE before its status is read, so a concurrent complete_task on that
-- dependency serializes against this count rather than racing it.
--
-- A dependency that has already succeeded is not counted, because the cascade
-- decrements on the transition INTO a terminal state and that transition has
-- already happened. A dependency id that names no task counts as outstanding;
-- the foreign key on task_dependencies refuses the row a moment later, which
-- is where that mistake should be reported.
create or replace function workflow.outstanding_deps(p_deps uuid[])
returns int as $$
declare
    v_dep    uuid;
    v_status text;
    v_n      int := 0;
begin
    for v_dep in
        select distinct d from unnest(coalesce(p_deps, '{}'::uuid[])) d where d is not null
    loop
        select status into v_status from workflow.tasks where id = v_dep for update;
        if v_status is distinct from 'succeeded' then
            v_n := v_n + 1;
        end if;
    end loop;
    return v_n;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 9. FIX #3: workflow bootstrap — the piece that was missing entirely.
--    Two-pass: insert all step rows first (so every step_key has an
--    id), then wire workflow.task_dependencies + compute real pending_deps once all
--    ids are known. Idempotent via external_id.
-- ------------------------------------------------------------

-- WHICH RUN AN IDEMPOTENCY KEY MAY RESOLVE TO, FOR THIS CALLER.
--
-- The engine standalone has no identities, so every run with the key is the
-- caller's and the honest answer here is the run itself -- the same
-- stub-and-shadow shape may_define() carries, and integration-rbac.sql §(e)
-- replaces this with the version that asks whose run it is. That question has
-- to be asked somewhere: start_workflow is idempotent on external_id, and the
-- version of it that matched on the key alone handed a caller who named
-- somebody else's key that run's id -- an existence oracle over another
-- tenant's work, and a run id trusted by whatever the caller did next (REM-77,
-- found while classifying reachable definers for REM-46).
--
-- A FUNCTION RATHER THAN A PREDICATE IN THE QUERY BELOW, because `owner_id`
-- does not exist in this file: the core engine is deliberately identity-free
-- and the column arrives with rbac.add_scope_columns().
create or replace function workflow.reusable_run(p_external_id text)
returns uuid as $$
    select id from workflow.runs where external_id = p_external_id;
$$ language sql stable;

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
    v_dep_ids   uuid[];
    v_count     int;
    v_comp      text[];
begin
    if p_external_id is not null then
        -- AMONG THE RUNS THIS CALLER MAY SEE, never every run with the key.
        -- reusable_run() is the one place that decides which those are.
        v_run_id := workflow.reusable_run(p_external_id);

        if v_run_id is not null then
            select status into v_status from workflow.runs where id = v_run_id;
            if v_status in ('running', 'succeeded') then
                return v_run_id;      -- the work happened; do not repeat it
            end if;
            raise exception
                'external_id % already belongs to run %, which is %. That run did not '
                'complete, so returning it would report work that never happened -- and '
                'external_id is unique per owner, so this key cannot start a second run '
                'for you. Use a new external_id to retry.', p_external_id, v_run_id, v_status;
        end if;
    end if;

    v_def := workflow.current_definition(p_name);
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
        v_dep_ids := '{}'::uuid[];
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
            v_dep_ids := v_dep_ids || v_dep_id;
        end loop;
        -- §8b, and NOT `v_count := v_count + 1` per key: `needs: [a, a]` is one
        -- dependency ROW and used to be a count of two, which is a step that
        -- never becomes ready in a run that never ends.
        v_count := workflow.outstanding_deps(v_dep_ids);
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
-- SETOF, NOT A BARE COMPOSITE, and the difference is the whole contract for an
-- empty queue.
--
-- `returns workflow.tasks` cannot express "nothing to claim": `return null`
-- from a composite-returning function is ONE ROW with every column NULL, and
-- `found` is true. A worker written the obvious way -- claim, and work the row
-- if you got one -- therefore treats an empty queue as a task arriving, on the
-- most-called function in this API, and spec.md §4 documented the signature
-- with no note that emptiness was spelled that way. The reference worker
-- defends against it (`task_id = row[0] if row else None`), which is evidence
-- the trap was known at the call site and never fixed at the source.
--
-- Same shape `ai-query-layer/USAGE.md` records for `lookup_many`'s LEFT JOIN,
-- resolved the same way: "rows is non-empty, and a miss is indistinguishable
-- from a hit to anything that does not inspect the fields." `setof` returning
-- zero rows says it in the type, and matches `claim_tasks` below, which has
-- been setof since it was written.
--
-- The return type changes, so this is a drop rather than a replace. Callers
-- using `select * from claim_task(...)` are unaffected; one using
-- `(claim_task(...)).id` now gets zero rows instead of one NULL, which is the
-- correction.
drop function if exists workflow.claim_task(text, text);
create or replace function workflow.claim_task(p_queue text, p_worker_id text)
returns setof workflow.tasks as $$
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
            return next t;
            return;
        end if;
    end loop;
    -- Nothing claimable: no rows, rather than one row of nulls.
    return;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- THE BATCH CLAIM CONSUMES THE RATE KEY TOO, and it did not.
--
-- §21b's fix moved the token bucket INTO claim_task so that throttling stopped
-- being something a worker had to opt into -- the defect being that every
-- piece existed (the bucket, try_consume_rate_limit, claim_task_rate_limited)
-- and the shipped worker called none of them. This function was left as a bare
-- UPDATE, so the same defect survived one function along: a worker that
-- batches -- which spec.md §7 names as the throughput path, and grants to
-- `worker` below -- got every throttled task handed to it, `rate_key` and all.
-- §11's first test recipe combines the token bucket, lookahead-skip claiming
-- AND batching in one pipeline, so they were always meant to compose.
--
-- The shape is claim_task's, generalised from "the first one that passes" to
-- "the first p_batch_size that pass". The lookahead is ADDED to the batch size
-- rather than shared with it: the point of looking ahead is that a throttled
-- source must not head-of-line-block an unrelated one, and a lookahead that a
-- full batch consumes is no lookahead at all.
--
-- Still one statement's worth of locking: `for update skip locked` over the
-- candidate window, and the rows that are looked at and not claimed stay
-- locked for the transaction exactly as claim_task's do -- concurrent claimers
-- skip them rather than block, which is what SKIP LOCKED is for.
create or replace function workflow.claim_tasks(p_queue text, p_worker_id text, p_batch_size int default 10)
returns setof workflow.tasks as $$
declare
    t           workflow.tasks;
    v_lookahead int;
    v_taken     int := 0;
begin
    select coalesce(rate_lookahead, 20) into v_lookahead
    from workflow.queue_config where queue = p_queue;
    v_lookahead := coalesce(v_lookahead, 20);

    for t in
        select * from workflow.tasks
        where queue = p_queue and status = 'ready' and run_after <= now()
        order by priority desc, created_at
        for update skip locked
        limit p_batch_size + v_lookahead
    loop
        exit when v_taken >= p_batch_size;
        if t.rate_key is null or workflow.try_consume_rate_limit(t.rate_key) then
            update workflow.tasks
            set status = 'running', claimed_by = p_worker_id,
                claimed_at = now(), heartbeat_at = now(), attempts = attempts + 1
            where id = t.id
            returning * into t;
            v_taken := v_taken + 1;
            return next t;
        end if;
    end loop;
    return;
end;
$$ language plpgsql;

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
drop function if exists workflow.claim_task_rate_limited(text, text);
create or replace function workflow.claim_task_rate_limited(p_queue text, p_worker_id text)
returns setof workflow.tasks as $$
    select * from workflow.claim_task(p_queue, p_worker_id);
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

    if workflow.is_terminal(t.status) then
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

-- A task's output reaching runs.context is a property of the TRANSITION INTO
-- `done`, not of complete_task -- and writing it inline in complete_task is how
-- it became a property of complete_task alone. `signal_task` and
-- `promote_due_timers` mark a task done too and merged nothing, so
-- {{steps.<a signal step>.result}} resolved to nothing and the acting step
-- failed with a template its author had written correctly. The whole second
-- half of a human-in-the-loop workflow -- act on what the person said -- was
-- unreachable from the document, and `dev/examples/08-wait.sql` did not notice
-- because it waits, resumes, and never reads the payload.
--
-- failure-modes.md §5 already names this shape ("when a correction applies to a
-- property of a state transition, enumerate every path that performs that
-- transition") and records it reopening three times for `now()` -- at these
-- same two call sites. So the merge is a function with three callers rather
-- than a statement with one, and the enumeration is `grep merge_step_context`.
-- CALL THIS BEFORE THE STATUS TRANSITION, NEVER AFTER. A `sql` successor
-- auto-runs inside the statement that marks it ready (failure-modes.md §1, "an
-- aggregate over a partial set"), so a merge performed after the UPDATE is a
-- merge the successor never sees -- it reads runs.context one statement too
-- early and gets nothing. complete_task has always merged first; the first
-- version of the signal and timer fixes merged after, and the acting step
-- still failed with `template 'steps.officer.result' resolved to nothing`
-- while the context ended up perfectly correct. Order is the whole fix here.
create or replace function workflow.merge_step_context(p_task_id uuid, p_output jsonb)
returns void as $$
declare t workflow.tasks;
begin
    select * into t from workflow.tasks where id = p_task_id;
    if not found then
        return;
    end if;
    -- Matrix children deliberately do NOT write into runs.context: one JSONB
    -- column rewritten in full per completion is quadratic write amplification
    -- at fan-out scale, and matrix_outputs() is the handle-and-reader version
    -- of the same thing. Carried here rather than left at the one call site
    -- that had it, so the three paths cannot disagree about that either.
    if t.matrix_parent_id is null then
        update workflow.runs r
        set context = context || jsonb_build_object(t.step_key, p_output),
            updated_at = now()
        where r.id = t.run_id;
    else
        update workflow.runs set updated_at = now() where id = t.run_id;
    end if;
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

    perform workflow.merge_step_context(p_task_id, v_out);

    update workflow.tasks set status = 'succeeded', output = v_out,
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
          and status = 'succeeded' and compensation_task_key is not null and compensated_at is null
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

-- REPLACED by integration-rbac.sql (e), which adds the authorization check.
-- This body runs only in an engine-only install; in any deployment that loads
-- both -- which is every deployment, since both files are in build-sql.py's
-- ORDER -- the definition below is dead and the one there is live. The note is
-- here rather than only there because here is where the mistake gets made: the
-- completed_at fix described next was first applied to THIS copy and had no
-- effect, and dev/currency.sh is what noticed.
--
-- completed_at is stamped here for the same §21c reason as complete_task and
-- promote_due_timers: it is the column begin_compensation orders by, and this
-- was the third path that marked a task `done` without it. A signalled task in
-- a saga group sorted first under `order by completed_at desc` -- compensated
-- before everything that ran after it -- because a NULL sorts first.
create or replace function workflow.signal_task(p_run_id uuid, p_signal text, p_payload jsonb)
returns void as $$
declare r record;
begin
    -- The rows are selected, merged, and only then transitioned -- see the note
    -- on merge_step_context. Doing it in one UPDATE ... RETURNING loop reads
    -- better and releases the successor before its input exists.
    for r in
        select id from workflow.tasks
        where run_id = p_run_id and wait_signal = p_signal
          and status = 'waiting_external'
        for update
    loop
        -- NESTED UNDER `result`, like every other kind. YAML.md states the rule
        -- generally -- "{{steps.<id>.result}} is the one idiom to learn" -- and
        -- `signal` was the kind that stored the payload bare, so the documented
        -- spelling resolved to nothing on the one step whose entire purpose is
        -- to be read afterwards.
        perform workflow.merge_step_context(
            r.id, jsonb_build_object('result', p_payload));
        update workflow.tasks
        set status = 'succeeded', output = jsonb_build_object('result', p_payload),
            completed_at = clock_timestamp()
        where id = r.id;
    end loop;
end;
$$ language plpgsql;

-- REPLACED by integration-rbac.sql (e), for the same reason and with the same
-- consequence as signal_task above: that version checks the caller's authority
-- over the run first, and splits the cascade into cancel_run_unchecked so the
-- recursive descent into child runs is not a second copy of it. Edit there.
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
    -- STARTABLE, not merely present: the same question start_workflow asks one
    -- call along, so this cannot admit a run that the starter then refuses.
    if (workflow.current_definition(p_workflow_name)).id is null then
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
    if workflow.is_success(v_status) then
        perform workflow.complete_task(p_task_id, jsonb_build_object('result', v_ctx));
    elsif workflow.is_terminal(v_status) then
        perform workflow.fail_task(p_task_id,
            jsonb_build_object('child_run_status', v_status, 'child_run_id', v_child), true);
    end if;

    return v_child;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function workflow.resolve_parent_on_child_completion() returns trigger as $$
begin
    if workflow.is_terminal(new.status) and old.status = 'running' then
        if new.parent_task_id is not null then
            if new.status = 'succeeded' then
                perform workflow.complete_task(new.parent_task_id, new.context);
            else
                perform workflow.fail_task(new.parent_task_id, jsonb_build_object('child_run_status', new.status));
            end if;
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create or replace trigger trg_resolve_parent_on_child_completion
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
    v_count int := 0;
begin
    if exists (select 1 from workflow.runs where id = p_run_id and status = 'cancelled') then
        return null;   -- fix #4: no new work under a cancelled run
    end if;

    -- fix #1 lives in workflow.outstanding_deps (§8b) now, along with the
    -- DISTINCT this loop did not have: it locks every dependency row BEFORE
    -- deciding pending_deps, so a concurrent workflow.complete_task on the same
    -- dependency serializes against the count rather than racing it -- and it
    -- counts the rows the insert below will actually create, so
    -- `array[t, t]` no longer produces a task whose pending_deps cannot reach
    -- zero.
    v_count := workflow.outstanding_deps(p_depends_on);

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
    v_dep_ids uuid[];
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
        -- fix #1 + the DISTINCT, both in workflow.outstanding_deps (§8b), the
        -- third copy of a count that had to agree with an ON CONFLICT DO
        -- NOTHING insert and did not.
        select coalesce(array_agg(e::uuid), '{}'::uuid[]) into v_dep_ids
          from jsonb_array_elements_text(coalesce(v_item->'depends_on', '[]'::jsonb)) e;
        v_count := workflow.outstanding_deps(v_dep_ids);

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
    update workflow.tasks set status = 'succeeded', output = p_output,
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
declare r record; v_n int := 0;
begin
    for r in
        select id from workflow.tasks
        where kind = 'timer' and status = 'ready' and run_after <= now()
        for update skip locked
    loop
        -- `result` again: a timer was the second kind whose output did not
        -- honour the one idiom, so {{steps.<a timer>.result.fired}} was
        -- unreadable on a step that is otherwise trivially readable. Merged
        -- before the transition, for the reason merge_step_context states.
        perform workflow.merge_step_context(
            r.id, '{"result": {"fired": true}}'::jsonb);
        update workflow.tasks set status = 'succeeded',
            output = '{"result": {"fired": true}}'::jsonb,
            completed_at = clock_timestamp()
        where id = r.id;
        v_n := v_n + 1;
    end loop;
    return v_n;
end;
$$ language plpgsql;
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
create or replace view workflow.v_queue_depth as
    select queue, status, count(*) as value from workflow.tasks group by queue, status;

create or replace view workflow.v_run_progress as
    select r.id as run_id, d.name as workflow_name, r.status as run_status,
           count(*) filter (where t.status = 'succeeded') as done,
           count(*) as total, r.created_at, r.updated_at
    from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    join workflow.tasks t on t.run_id = r.id
    group by r.id, d.name, r.status, r.created_at, r.updated_at;

create or replace view workflow.v_stuck_tasks as
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
create or replace view workflow.v_lease_violations as
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

create or replace view workflow.v_compensation_status as
    select f.run_id, f.saga_group,
           count(*) as total_compensatable,
           count(c.id) as compensations_created,
           count(*) filter (where c.status = 'succeeded') as compensations_done,
           count(*) filter (where c.status = 'failed') as compensations_failed
    from workflow.tasks f
    left join workflow.tasks c on c.compensates_task_id = f.id
    where f.saga_group is not null and f.compensation_task_key is not null
    group by f.run_id, f.saga_group;

create or replace view workflow.v_decision_history as
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
--     SECURITY INVOKER -> task status 'succeeded', run.context {}          <-- lost
--     SECURITY DEFINER -> task status 'succeeded', run.context {"gather":...}
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
        -- The batched peer (§20j). Costs the worker nothing to ignore -- the
        -- rows are inside task_input either way -- and spares a handler that
        -- does care from knowing which nested field they live in, which is
        -- the same argument §20e makes for `item`.
        'items',       v_task.input->'items',
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
--
-- THIS IS NOT THE LAST WORD, and reading it as one is how fifty functions
-- below this line kept PUBLIC's EXECUTE. `create or replace function` after a
-- revoke gets the default back, and this file goes on for another five
-- thousand lines. The statement that actually holds the invariant is
-- `identity/closing.sql`, which build-sql.py emits after everything else, with
-- the check that fails the install if it stops holding. This line states the
-- intent where a reader of this file will look for it; that one makes it true.
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
--   1. A POLICY, WHICH DEFAULTS TO OPEN. This guard used to be an allow-list:
--      a step named a registered function and could not supply a statement, so
--      authoring a workflow never widened what could be executed. That is a
--      sound boundary and it made every QUESTION a pipeline wanted to ask into
--      an owner-only registration, which is why `percolate.sql_policy` now
--      chooses -- `open` (a step may carry its own SQL, running with the reach
--      of whoever started the run) or `registered` (the old rule). See "SQL a
--      step wrote itself" above for whose reach that is. Under either policy a
--      READ cannot write: transaction_read_only decides that, not the policy.
--   2. A SUBTRANSACTION per step. A failing step fails ITSELF -- it must not
--      abort the transaction of whichever worker happened to complete the
--      preceding task. Without this, one bad SQL step would roll back an
--      unrelated worker's completed work.
--   3. A statement timeout, so a pathological query cannot hold the caller's
--      transaction open indefinitely.
-- ============================================================

-- The kind vocabulary is re-declared by ALTER at §22c, where `matrix` joins it,
-- so an existing installation picks the change up -- `create table` is skipped
-- when the table exists, which silently leaves the old constraint in place.
-- That was caught by a `sql` step being rejected on a database that had already
-- been installed.
--
-- The ALTER that used to be HERE has been deleted rather than updated. It
-- listed the vocabulary WITHOUT `matrix`, and §22c's later ALTER dropped and
-- re-added the same constraint name with it -- so this one never survived a
-- load, and the file carried three declarations of one column of which only the
-- last was live. That is the same defect `build-sql.py:check_single_definition`
-- refuses for functions ("a maintainer fixing a bug has no way to tell which
-- copy is live"), and it had already produced the state it warns about: two of
-- the three spellings here were wrong and reading either of them told you the
-- wrong thing about what the database admits. Found by `dev/vocab-audit.py`.

create table if not exists workflow.step_functions (
    name          text primary key,        -- what a step spec names
    fn            text not null,            -- schema-qualified function
    arg_types     text[] not null default '{}',
    timeout_ms    int not null default 30000,
    description   text,
    registered_at timestamptz not null default now()
);

-- ON THE TABLE, NOT IN THE FUNCTION THAT WRITES IT, and the move is the point.
-- These three checks used to live in the body of register_step_function() --
-- which meant they were the rules for CALLING THAT FUNCTION rather than the
-- rules for what this table may hold. A bare insert met none of them:
--
--     insert into workflow.step_functions values ('ghost','journey.no_such_fn');
--     INSERT 0 1
--     workflow.register_step_function('ghost2','journey.no_such_fn');
--     ERROR:  function journey.no_such_fn() does not exist
--
-- Found by walking scenarios/evals/J2 as a user: the officer read the table
-- before the documentation and had two unrunnable rows in the registry inside a
-- minute. The docs do say to use the function, so this was never a
-- documentation defect -- it is meta/challenge-the-process's PUSH-DOWN
-- principle unapplied, on the one table that decides what a workflow may cause
-- to run. A foreign key beats a CHECK beats a trigger beats a validator
-- somebody has to call, and a validator somebody has to call is what this was.
--
-- A trigger and not a CHECK constraint because every question here is asked of
-- the catalog -- does this function exist, can the executing role reach it --
-- and a CHECK may not read tables. This is the strongest form available.
--
-- MOVED AND NOT COPIED. register_step_function below now just inserts. Two
-- copies of one rule, checked against each other, is the defect recorded in
-- meta/postmortems/2026-09-04-docs-examples-nobody-ran.md, where a seat defined
-- as two format strings eighty lines apart diverged and a gate spent an hour
-- reporting a defect that was not there.
create or replace function workflow.step_function_is_runnable()
returns trigger as $$
declare
    v_sig     text := new.fn || '(' || array_to_string(new.arg_types, ',') || ')';
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

    -- A NULL definer would make both checks below vanish rather than fail:
    -- has_schema_privilege(null, ...) is null, `not null` is null, and `if null`
    -- does not raise -- so a missing execute_sql_step would turn this trigger
    -- into a row that always passes. That is the same shape as the defect this
    -- trigger exists to fix (a check that cannot fire), so it is refused loudly
    -- instead. Reachable only if the schema is loaded out of order; the
    -- registrations in this tree all follow execute_sql_step's definition.
    if v_definer is null then
        raise exception
            'workflow.execute_sql_step(uuid) does not exist, so there is no role to '
            'check % against. Registering now would validate nothing.', v_sig;
    end if;

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

    return new;
end;
$$ language plpgsql;

-- `or replace` because this file is replayed against an existing database to
-- upgrade it, so every statement in it must survive being applied twice. A
-- plain `create trigger` does not, and `drop ... if exists` followed by
-- `create` leaves a window in which the table has no guard at all.
create or replace trigger step_function_is_runnable
    before insert or update on workflow.step_functions
    for each row execute function workflow.step_function_is_runnable();

-- Registering is deliberately owner-only (no grant below): it decides what a
-- workflow author is allowed to cause to run.
-- Current form. It reached this shape in section 22b (BUG 2 -- registration checked the wrong role's privileges.), which explains
-- the failure that produced it. Defined here, where it is first needed.
--
-- What remains is the insert. The refusals a caller sees are raised by the
-- trigger above, with the same text they have always had -- so this function's
-- contract is unchanged and every existing caller and message assertion still
-- holds. What changed is that they now also fire for a caller who never came
-- through here.
create or replace function workflow.register_step_function(
    p_name text, p_fn text, p_arg_types text[] default '{}',
    p_timeout_ms int default 30000, p_description text default null
) returns void as $$
begin
    insert into workflow.step_functions (name, fn, arg_types, timeout_ms, description)
    values (p_name, p_fn, p_arg_types, p_timeout_ms, p_description)
    on conflict (name) do update set fn = excluded.fn, arg_types = excluded.arg_types,
        timeout_ms = excluded.timeout_ms, description = excluded.description;
end;
$$ language plpgsql;

-- ============================================================================
-- SQL A STEP WROTE ITSELF -- the expressive mode, and the policy that closes it
--
-- `sql:` used to mean one thing: name a function somebody with owner rights had
-- registered. That is a sound boundary and a bad default. Authoring a workflow
-- is granted to `authenticated`; registering a function is not; so every
-- QUESTION a pipeline wants to ask -- "the last eight quarters for this filer"
-- -- required a privileged human to write and bless a one-line SELECT. A real
-- pipeline built against data.sec.gov needed two registrations for five steps,
-- and only one of them was doing anything a review would care about.
--
-- The tax was worst where it bought least. A read is bounded by what the
-- database will show; making somebody promote it into an owner-executed
-- registered function is MORE privilege than the question needed, not less.
--
-- So a step may now carry a statement:
--
--     - id: quarters
--       sql: "select fy, fp, val from sec.facts where cik = '{{run.cik}}'"
--
-- WHOSE REACH A STATEMENT HAS. The person's who started the run. A step
-- executes inside execute_sql_step, which is SECURITY DEFINER and owned by
-- app_owner, the owner of every table -- so a statement run there directly
-- would read every tenant's rows past RLS. It is not run there directly: when
-- the run has an owner, run_sql hands the statement to workflow.execute_for,
-- which runs it with that person's identity and under RLS, as if they had
-- typed it themselves (execute_for below says how). A run nobody started -- a
-- schedule, a system pass -- has no person to act for and keeps the engine's
-- reach; that is the operator's own trade.
--
-- It was not always so, and the history is the argument for it. The first
-- version ran every statement as app_owner and defended it as "anyone who may
-- define a workflow may read anything". Defining was gated; STARTING was not,
-- so a workflow an admin wrote read every tenant for whoever ran it. The tour
-- (scenarios/tour, act 8) had a member of one org start `ask_uploads` and get
-- another org's runbook back from its SEARCH step.
--
-- READS CANNOT WRITE, AND THE DATABASE ENFORCES IT, not a parser. A statement
-- without `write: true` runs with transaction_read_only on, which is the same
-- boundary aiq.sql_passthrough uses and for the reason stated there: a filter
-- that decides whether SQL is read-only is a filter to be bypassed; a read-only
-- transaction is a guarantee. The keyword check beside it is a courtesy that
-- turns a transaction abort into a sentence.
--
-- AND AUTHORING CAN STILL BE NARROWED, one setting away:
--
--     alter database <db> set percolate.sql_policy = 'registered';
--
--   open       (default)  a step may carry a statement, or name a function
--   registered            statements are refused; only the allow-list runs
--
-- That narrows what an author may WRITE. Whose rows a statement sees is the
-- paragraph above, under either policy.
--
-- The registry does not go away and is not deprecated. It keeps the two jobs it
-- was always better at than gatekeeping: a per-function timeout, and a
-- DESCRIPTION -- the same text a bound tool carries into a model's context --
-- so step_functions stays the answer to "what can a workflow cause to run" for
-- the operations a deployment wants blessed.
-- ============================================================================

create or replace function workflow.sql_policy()
returns text
language sql
stable
as $$
    -- A GUC rather than a table: this is a deployment decision, it wants to be
    -- settable per database without a migration, and a policy stored as a row
    -- is a policy somebody can UPDATE from inside the system it constrains.
    select lower(coalesce(nullif(current_setting('percolate.sql_policy', true), ''), 'open'));
$$;

-- THE TWO HOOKS A STEP'S STATEMENT GOES THROUGH, stub-and-shadow like
-- may_define. Standalone the engine has no people, so no run has an owner to
-- act for and every statement keeps the engine's reach. integration-rbac.sql
-- shadows both once the identity plane is installed: run_owner_of reads
-- runs.owner_id, and execute_for runs the statement as that person.
--
-- The run is the one execute_sql_step (or expand_matrix, for a row source)
-- publishes in workflow.current_run_id, never an argument: an argument is text
-- a workflow author wrote, and naming somebody else's run would borrow their
-- reach.
create or replace function workflow.run_owner_of(p_run_id uuid)
returns uuid as $$
    select null::uuid;
$$ language sql stable;

create or replace function workflow.execute_for(
    p_user uuid, p_statement text, p_write boolean, p_params jsonb)
returns jsonb as $$
begin
    raise exception 'no identity plane is installed, so there is nobody to run % for', p_user;
end;
$$ language plpgsql;

revoke execute on function workflow.run_owner_of(uuid) from public;
revoke execute on function workflow.execute_for(uuid, text, boolean, jsonb) from public;

-- ONE HOME FOR "ONE STATEMENT THAT CANNOT BE TWO", and it is here rather than
-- beside either caller because the rule was written once, at the call site
-- where it was needed, and the sibling that needed the same rule did not get
-- it. `execute_as_viewer` wraps a write as the body of a data-modifying CTE --
-- the grammar, not a pattern, deciding that a string is ONE insert, update,
-- delete or merge -- because plpgsql's EXECUTE runs a string of several
-- statements one after another, so `insert ...; set local request.jwt.claims
-- = ...` rewrites whose step it is (REM-64, workflow/15 §4b). `plan_probe`
-- took a workflow author's statement straight into `execute 'explain (format
-- json) ' || v_stmt`, two lines above a read branch that was correctly
-- wrapped, and EXPLAIN of the first statement does not stop the second from
-- running. It is SECURITY INVOKER and granted to `authenticated`.
--
-- That is the seventeenth instance of meta/postmortems/2026-09-11-fixed-at-
-- the-copy-that-failed.md, so the fix is not a second copy of the wrapping:
-- it is this function, which both callers now ask.
--
-- TRAILING SEMICOLONS ARE DROPPED, since an author writes them and a CTE body
-- cannot hold one. A statement carrying its own RETURNING does not parse here
-- and is meant not to; each caller says so in its own words, because "your
-- write step is malformed" and "this probe could not plan it" are different
-- sentences to different people.
create or replace function workflow.one_write_statement(p_statement text)
returns text as $$
    select pg_catalog.format(
        'with p8_write as (%s returning 1) select count(*) from p8_write',
        pg_catalog.regexp_replace(p_statement, '[[:space:];]+$', ''));
$$ language sql immutable;

revoke execute on function workflow.one_write_statement(text) from public;
-- plan_probe is SECURITY INVOKER and reaches this as the caller.
grant execute on function workflow.one_write_statement(text) to authenticated;

-- Dropped rather than left beside the new signature: `create or replace` with
-- an added parameter makes a SECOND function, and the old three-argument one
-- would still be callable and would still interpolate.
drop function if exists workflow.run_sql(text, boolean, int);

create or replace function workflow.run_sql(
    p_statement  text,
    p_write      boolean default false,
    p_timeout_ms int default 30000,
    -- VALUES ARRIVE AS A PARAMETER, NOT AS TEXT. One jsonb, bound as $1, with
    -- the statement referring to it by `$1->>'<ref>'`. See
    -- workflow.resolve_statement_params for why one parameter rather than N:
    -- plpgsql fixes the number of USING expressions at compile time, so a
    -- variable-length parameter list is not expressible, and a single jsonb is.
    p_params     jsonb default null)
returns jsonb as $$
declare
    v_out   jsonb;
    v_count bigint;
    v_pol   text := workflow.sql_policy();
    -- Only bind when there is something to bind: EXECUTE refuses USING against
    -- a statement with no placeholders ("too many parameters specified").
    v_bind  boolean := p_params is not null and p_params <> '{}'::jsonb;
    -- Who this statement runs for: the owner of the run being executed, or
    -- nobody (a system run, or the engine standalone). See "WHOSE REACH".
    v_for   uuid := workflow.run_owner_of(
                        nullif(current_setting('workflow.current_run_id', true), '')::uuid);
begin
    if v_pol = 'registered' then
        raise exception
            'percolate.sql_policy is ''registered'', so a step may not carry its own '
            'statement. Register the query as a step function and name it, or set the '
            'policy to ''open'' for this deployment.';
    elsif v_pol <> 'open' then
        raise exception
            'percolate.sql_policy is ''%'', which this build does not implement. The '
            'modes are ''open'' and ''registered''.', v_pol;
    end if;

    if coalesce(btrim(p_statement), '') = '' then
        raise exception 'this sql step carries an empty statement';
    end if;

    perform set_config('statement_timeout', greatest(p_timeout_ms, 1)::text, true);

    if p_write then
        -- A write says so in the document. That is not the security control --
        -- whose reach the write has is, and for a person's run it is theirs, so
        -- it succeeds only where they could have written the same rows -- but a
        -- plan that cannot tell a question from a mutation is a plan nobody can
        -- review, and every reader of a definition deserves to see which steps
        -- change the database.
        if v_for is not null then
            return workflow.execute_for(v_for, p_statement, true, case when v_bind then p_params end);
        end if;
        if v_bind then execute p_statement using p_params;
        else           execute p_statement;
        end if;
        get diagnostics v_count = row_count;
        return jsonb_build_object('rows_affected', v_count);
    end if;

    -- The courtesy check: unambiguous, cheap, and it turns an abort into a
    -- sentence naming the remedy. NOT the boundary.
    if p_statement ~* '^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy)\M' then
        raise exception
            'this step is a read and its statement starts with %. Declare `write: true` '
            'on the step if it is meant to change the database.',
            upper((regexp_match(p_statement, '^\s*([a-zA-Z]+)'))[1]);
    end if;

    -- THE BOUNDARY, AND THE DOOR BACK OUT OF IT.
    --
    -- transaction_read_only is transaction-local, and this runs inside the
    -- engine's own transaction -- which still has to mark the task done
    -- afterwards. Left on, the first read-only step would make every subsequent
    -- write in that transaction fail, complete_task's included, and the engine
    -- would look broken rather than the step.
    --
    -- Setting it back is not available: Postgres refuses `transaction_read_only
    -- = off` once a transaction is read-only -- `cannot set transaction
    -- read-write mode inside a read-only transaction`, SQLSTATE 25001. It is a
    -- one-way door, and the only way through it is a SUBTRANSACTION, whose
    -- abort rolls the setting back with everything else. So the read runs
    -- inside one and the block is deliberately unwound: the rows are already in
    -- a plpgsql variable, which is not transactional and survives.
    --
    -- Found by running it. The first version set the GUC back by hand, failed
    -- with 25001 on the line after the query, retried five times, and reported
    -- a syntax error's worth of confusion for something that was neither.
    begin
        perform set_config('transaction_read_only', 'on', true);
        if v_for is not null then
            -- Inside the same unwound subtransaction, so the identity
            -- execute_for sets is unwound with the read-only flag.
            v_out := workflow.execute_for(v_for, p_statement, false, case when v_bind then p_params end);
        elsif v_bind then
            execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement)
            into v_out using p_params;
        else
            execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement)
            into v_out;
        end if;
        raise exception using errcode = 'P0001',
                              message = '__percolate_readonly_done__';
    exception when others then
        if sqlerrm <> '__percolate_readonly_done__' then
            raise;
        end if;
    end;

    return coalesce(v_out, '[]'::jsonb);
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

-- A TEMPLATE IN A STATEMENT IS A VALUE, NEVER A FRAGMENT.
--
-- `where cik = '{{run.cik}}'` is the obvious thing to write and the obvious way
-- to introduce injection: the run's input is data a caller supplied, and
-- pasting it into SQL text is exactly the mistake call_step_function avoids by
-- passing arguments as parameters. A statement cannot be parameterised the same
-- way -- the whole point is that the author wrote the SQL -- so every reference
-- is substituted as a QUOTED LITERAL, through quote_nullable, before the
-- statement is ever planned.
--
-- Two consequences, both deliberate. A template resolving to `'; drop table x;
-- --` becomes a string containing that text and nothing else. And a table or
-- column name cannot be templated at all: `from {{run.table}}` produces
-- `from 'sec.facts'`, which is a syntax error rather than a dynamic identifier.
-- Identifiers being un-templatable is the feature -- a workflow that chooses
-- its own tables at runtime is one nobody can review, and matrix templates
-- already cover the case where the ROWS vary.
create or replace function workflow.resolve_statement(
    p_statement text, p_run_id uuid, p_item jsonb default null)
returns text as $$
declare
    v_out  text := p_statement;
    v_ref  text;
    v_lit  text;
    v_pat  text;
begin
    for v_ref in
        select distinct m[1]
          from regexp_matches(p_statement, '\{\{\s*([a-zA-Z0-9_.$-]+)\s*\}\}', 'g') m
    loop
        v_lit := quote_nullable(
            workflow.resolve_template_ref(v_ref, p_run_id, p_item) #>> '{}');
        -- Backslashes are escaped on BOTH sides for different reasons: in the
        -- pattern because a ref carries dots, and in the replacement because
        -- regexp_replace reads \1 as a back-reference and a quoted literal can
        -- legitimately contain a backslash.
        v_pat := '\{\{\s*' || regexp_replace(v_ref, '([.$\\])', '\\\1', 'g') || '\s*\}\}';

        -- QUOTES THE AUTHOR ALREADY WROTE ARE CONSUMED, and this is not
        -- politeness. `where cik = '{{run.cik}}'` is what everyone types --
        -- it is what the equivalent looks like in every templating language
        -- they have used -- and substituting a quoted literal into it produces
        -- `= ''0000320193''`, which is a syntax error pointing at a line the
        -- author did not write. Found immediately, by writing the obvious thing
        -- in the test for this feature.
        --
        -- So a reference wrapped in single quotes is replaced INCLUDING them.
        -- Both spellings then mean the same thing, and neither can produce an
        -- unquoted value -- which is the property that matters.
        v_out := regexp_replace(v_out, '''' || v_pat || '''',
                                replace(v_lit, '\', '\\'), 'g');
        v_out := regexp_replace(v_out, v_pat,
                                replace(v_lit, '\', '\\'), 'g');
    end loop;
    return v_out;
end;
$$ language plpgsql stable;

-- ------------------------------------------------------------
-- THE SAME JOB, DONE WITH A BOUND PARAMETER INSTEAD OF A LITERAL.
--
-- resolve_statement above escapes: it puts the value into the statement text as
-- a quoted literal. That is the accepted fallback and it uses Postgres's own
-- quoting, and it is still the weaker of the two answers, because the value
-- reaches the parser. This one does not put the value in the text at all.
--
-- WHY IT MATTERS HERE RATHER THAN IN GENERAL. Tools that template SQL --
-- Jinja over a warehouse, a DAG's operator arguments -- are safe because their
-- trust model says the TEMPLATE AUTHOR is trusted, which is the same as saying
-- they already have code execution. That model does not hold for a `matrix:`
-- fanning out over rows: the values come from a data table, in a database whose
-- whole premise is that tenants share it. Row data is untrusted input, and the
-- only answer that does not depend on getting escaping right every time is that
-- it never becomes syntax.
--
-- ONE PARAMETER, NOT N, and that is forced rather than chosen: plpgsql fixes
-- the number of `EXECUTE ... USING` expressions at compile time, so a statement
-- with a variable number of references cannot bind one parameter each. A single
-- jsonb keyed by reference name is bindable, and `$1->>'item.site_ref'` is the
-- extraction.
--
-- THE CAST IS TAKEN FROM THE VALUE, because `->>` is text and a quoted literal
-- was not. `where n = '7'` works against an integer column -- an unknown-typed
-- literal is coerced by context -- while `where n = ($1->>'n')` is
-- `integer = text` and fails. So a JSON number binds as ::numeric and a JSON
-- boolean as ::boolean, which is the coercion the literal form got for free.
-- Measured, both directions, before this was written.
--
-- QUOTES THE AUTHOR WROTE ARE CONSUMED, exactly as resolve_statement does and
-- for the reason its comment gives: `= '{{item.ref}}'` is what everybody types.
-- Here it matters more than politeness -- leaving them would produce
-- `'($1->>''item.ref'')'`, a literal string containing the extraction.
create or replace function workflow.resolve_statement_params(
    p_statement text, p_run_id uuid, p_item jsonb default null)
returns jsonb as $$
declare
    v_out    text := p_statement;
    v_ref    text;
    v_val    jsonb;
    v_params jsonb := '{}'::jsonb;
    v_pat    text;
    v_slot   text;
begin
    -- A statement that already uses $1 would collide with the binding. Refused
    -- rather than mangled: the author is writing SQL, and a placeholder that
    -- silently means something else is the failure this whole function is about.
    if p_statement ~ '\$[0-9]' and p_statement ~ '\{\{' then
        raise exception
            'this statement uses both a {{template}} and a $n placeholder. '
            'Templated values are bound as $1, so the two cannot be mixed -- '
            'use {{...}} for values from the run or the row.';
    end if;

    for v_ref in
        select distinct m[1]
          from regexp_matches(p_statement, '\{\{\s*([a-zA-Z0-9_.$-]+)\s*\}\}', 'g') m
    loop
        v_val    := workflow.resolve_template_ref(v_ref, p_run_id, p_item);
        v_params := v_params || jsonb_build_object(v_ref, v_val);
        v_slot   := case jsonb_typeof(v_val)
                        when 'number'  then '(($1->>' || quote_literal(v_ref) || ')::numeric)'
                        when 'boolean' then '(($1->>' || quote_literal(v_ref) || ')::boolean)'
                        else                '($1->>' || quote_literal(v_ref) || ')'
                    end;
        v_pat := '\{\{\s*' || regexp_replace(v_ref, '([.$\\])', '\\\1', 'g') || '\s*\}\}';
        v_out := regexp_replace(v_out, '''' || v_pat || '''',
                                replace(v_slot, '\', '\\'), 'g');
        v_out := regexp_replace(v_out, v_pat,
                                replace(v_slot, '\', '\\'), 'g');
    end loop;
    return jsonb_build_object('sql', v_out, 'params', v_params);
end;
$$ language plpgsql stable;

-- Owner-only, like register_step_function and for the mirror-image reason: a
-- caller reaching this directly would be executing SQL as app_owner with no run
-- to account it to, which is exactly what the step path keeps inside a workflow.
revoke execute on function workflow.run_sql(text, boolean, int, jsonb) from public;

comment on function workflow.run_sql(text, boolean, int, jsonb) is
$c$Execute a workflow step's own SQL statement.
Read-only unless p_write is true, enforced by transaction_read_only rather than
by inspecting the statement, and refused entirely when percolate.sql_policy is
'registered'.$c$;

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
    v_res  jsonb;
    -- SAVED AND RESTORED RATHER THAN JUST SET, because the marker below now
    -- means "the invoker of this call is the engine owner" and something reads
    -- it to decide whether to refuse. set_config(..., true) is
    -- transaction-local, which stops it leaking into a pooled connection's next
    -- transaction and does NOT stop it outliving this step inside the current
    -- one -- so after any step ran, an ordinary direct call later in the same
    -- transaction looked like it was inside a step. Caught by the assertion in
    -- dev/tests/workflow/13 §5b that a direct workflow.p8ql() call is still
    -- allowed under sql_policy = 'registered'; it went red on the first run.
    -- Restoring the previous value rather than blanking it keeps nesting
    -- honest: a sql step whose completion autoruns its successor is this
    -- function inside itself.
    v_prev text := coalesce(nullif(current_setting('workflow.current_run_id', true), ''), '');
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
    -- §20a-ter: resolve_args puts `{` back into row text after its one pass.
    -- Always set, to '' when absent, so the previous task's sentinel in the
    -- same transaction cannot apply to this one.
    perform set_config('workflow.braces', coalesce(t.input->>'braces', ''), true);

    begin      -- subtransaction: a failure here must not abort the caller
        -- TWO SPELLINGS, ONE KIND. A step either names something the deployment
        -- registered or carries its own statement; the engine dispatches on
        -- which, and everything downstream -- retries, the event log, the
        -- payload cap, the plan -- is identical for both. `statement` is
        -- checked first because it is the one an author writes by hand and a
        -- spec carrying both is refused at registration (validate_spec).
        if v_spec ? 'statement' then
            -- Resolved into a STATEMENT PLUS PARAMETERS, not into text. The
            -- item is the child's own row, and on a matrix child that row is
            -- data somebody else wrote -- see resolve_statement_params for why
            -- that is the case escaping is the wrong answer to.
            v_res := workflow.resolve_statement_params(
                         v_spec->>'statement', t.run_id, t.input->'item');
            v_out := workflow.run_sql(
                v_res->>'sql',
                coalesce((v_spec->>'write')::boolean, false),
                coalesce((v_spec->>'timeout_ms')::int, 30000),
                v_res->'params');
        else
            v_out := workflow.call_step_function(
                v_spec->>'function', v_spec->'args', t.run_id, t.input->'item');
        end if;
        perform workflow.complete_task(p_task_id, jsonb_build_object('result', v_out));
        perform set_config('workflow.current_run_id', v_prev, true);
        return true;
    exception when others then
        perform set_config('workflow.current_run_id', v_prev, true);
        perform workflow.fail_task(p_task_id,
            jsonb_build_object('error', sqlerrm, 'sqlstate', sqlstate),
            -- A missing registration, a bad signature, a refused policy or a
            -- statement that does not parse will fail identically on every
            -- retry; a deadlock or timeout will not. 42601 is a syntax error in
            -- SQL the author wrote, which is the new member of that set.
            -- 42501 is the refused policy this comment already claimed and the
            -- list did not have: an authorization refusal -- from RLS, from a
            -- missing grant, or from one of this extension's own `not
            -- authorized` raises -- is the same answer on the fifth attempt.
            sqlstate in ('42501','42883','42P01','42601','P0001'));
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
-- to 'pending' while the run reported 'succeeded'. The task_events trail
-- showed all of it. During construction the graph is not yet valid, so the
-- only safe signal is a deliberate transition INTO ready.
--
-- Re-entry is safe: execute_sql_step() moves the row to 'running' before doing
-- any work, so the recursive fire sees a non-ready row and stops. A chain of
-- sql steps runs to completion through ordinary cascade.
-- A timer's delay is a property of BECOMING READY, and for a root timer that
-- happens at INSERT -- the one transition the autorun trigger below cannot see.
--
-- mark_roots_ready is a BEFORE INSERT trigger that rewrites `status` in the NEW
-- row, so a timer with no `needs:` is inserted already `ready` and no UPDATE
-- ever fires. `delay_seconds` was therefore stored on the task and applied to
-- nothing: run_after stayed at now(), the next promote_due_timers() fired it,
-- and `timer: 3600` as a document's first step waited zero seconds with every
-- task ending `done` and the run `completed`. A cooling-off period that does
-- not cool off, reported as success.
--
-- Same class as the ON UPDATE ONLY note below -- "a trigger that fires only on
-- the transition you did not take" -- failing the quiet way round: not a step
-- that never starts, but a wait that never waits. `dev/examples/08-wait.sql`
-- ages run_after by hand before promoting, which reads as a testing
-- convenience and was in fact a workaround for this, in the file whose job is
-- to demonstrate that timers work.
--
-- A function with two callers rather than a second copy of the arithmetic:
-- two paths that must agree about a policy and agree only by coincidence is
-- how this collection keeps re-finding the same bug.
create or replace function workflow.apply_timer_delay(p_task_id uuid)
returns void as $$
    update workflow.tasks
    set run_after = clock_timestamp()
                  + ((input->>'delay_seconds')::numeric * interval '1 second')
    where id = p_task_id and kind = 'timer' and (input ? 'delay_seconds');
$$ language sql;

-- Unconditional, where the old inline form skipped a row whose run_after was
-- already in the future. That guard is what would let the INSERT stamp below
-- win over the later readiness stamp for a NON-root timer, measuring its delay
-- from the run's start rather than from when it became ready -- the property
-- the old comment claimed and the new insert path would otherwise remove.
create or replace function workflow.apply_timer_delay_on_insert() returns trigger as $$
begin
    perform workflow.apply_timer_delay(new.id);
    return null;
end;
$$ language plpgsql;

-- Only a timer, and only one inserted already ready. Every other kind stays
-- strictly on the update path for the reason the next comment gives: during
-- start_workflow's two-pass construction the graph is not yet valid, so an
-- insert-time autorun would EXECUTE the whole workflow in arbitrary order.
-- Stamping a column is not executing, which is why this one is safe and those
-- are not.
create or replace trigger trg_apply_timer_delay
    after insert on workflow.tasks
    for each row when (new.kind = 'timer' and new.status = 'ready')
    execute function workflow.apply_timer_delay_on_insert();

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
        elsif new.kind = 'timer' then
            perform workflow.apply_timer_delay(new.id);
        end if;
    end if;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger trg_autorun_sql_steps
    after update of status on workflow.tasks
    for each row execute function workflow.autorun_sql_steps();

-- WORKER ONLY, and nobody else needs them: the engine reaches both from inside
-- its own SECURITY DEFINER functions (start_workflow, the autorun trigger,
-- tick), where the grant is not consulted. They used to be granted to
-- `authenticated` as well, and neither asks whose run a task belongs to -- so
-- any signed-in person could make another tenant's ready steps run when THEY
-- chose, a write step included, by naming a task or a run; the output stays in
-- the run, but the act is the owner's. drain_sql_steps also reaches
-- start_child_workflow, which is meant to be the engine's alone (REM-46). The
-- revoke is spelled out because a grant already made survives a replay.
grant execute on function workflow.execute_sql_step(uuid) to worker;
grant execute on function workflow.drain_sql_steps(uuid, int) to worker;
revoke execute on function workflow.execute_sql_step(uuid) from authenticated;
revoke execute on function workflow.drain_sql_steps(uuid, int) from authenticated;
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

-- WHO MAY DEFINE A WORKFLOW -- the gate the open sql_policy assumes exists.
--
-- "SQL a step wrote itself" states the trade plainly: a statement runs as the
-- engine owner, so anyone who may define a workflow may read anything in the
-- database. That sentence is only survivable if defining a workflow is itself
-- a privileged act, and until this hook existed it was not one: define_yaml
-- carried Postgres's PUBLIC default for EXECUTE, so every authenticated user
-- could author a step and read across every tenant. Found by calling it as a
-- user with no permissions at all, who got back every row of rbac.users.
--
-- The engine standalone has no identity model, so the honest default here is
-- `true` and the grant is the boundary -- the same rule this file applies to
-- every worker-facing function. `integration-rbac.sql` shadows this with the
-- rbac-aware version when the identity plane is installed, which is the same
-- stub-and-shadow shape assert_run_access already uses for run access.
create or replace function workflow.may_define()
returns boolean as $$
    select true;
$$ language sql stable;

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
    if not workflow.may_define() then
        raise exception
            'not authorized to define workflows'
            using errcode = 'insufficient_privilege',
                  detail = 'A workflow step may carry its own SQL, which runs as the '
                           'engine owner and is not subject to row-level security, so '
                           'defining one is an authoring privilege rather than a read.',
                  hint   = 'Grant the caller a role holding workflows:update, or set '
                           'percolate.sql_policy = ''registered'' if steps should only '
                           'name functions from the allow-list.';
    end if;

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
create table if not exists workflow.schedules (
    id             uuid primary key default uuidv7(),
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
    -- NOT NULL, defaulted to the shared tier -- but said in
    -- integration-rbac.sql's rbac.add_scope_columns() call rather than here.
    -- Two reasons, and both are structural: rbac.shared_org_id() does not
    -- exist yet at this point in the install (user-rbac is the NEXT file), and
    -- `create table if not exists` alters nothing on a database that already
    -- has this table, so a constraint written here would reach fresh installs
    -- only. identity/spec.md §7's fourth lesson.
    org_id         uuid,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);
create index if not exists idx_schedules_due on workflow.schedules (last_tick_at) where enabled;
create index if not exists idx_schedules_org on workflow.schedules (org_id);

create or replace trigger trg_schedules_touch before update on workflow.schedules
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

-- MATCHING A LOCAL WALL CLOCK, which is the only thing a cron expression has
-- ever described. Split out of cron_matches() so that workflow.tick() can ask
-- the question about a local minute that has no instant -- 02:30 on the
-- morning a clock springs forward is a real entry in somebody's crontab and
-- not a timestamptz at all. cron_matches() below is this function plus a zone
-- conversion, so there is one parser rather than two.
create or replace function workflow.cron_matches_local(
    p_expr text, p_local timestamp)
returns boolean as $$
declare
    f               text[];
    v_local         timestamp := p_local;
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
    -- `at time zone` raises for an unknown zone, which is the point: a typo'd
    -- timezone is caught when the schedule is created rather than never firing.
    select workflow.cron_matches_local(p_expr, p_ts at time zone p_timezone);
$$ language sql stable;

-- IS THIS EXPRESSION AN APPOINTMENT, OR A POLL?
--
-- The distinction only matters twice a year, and it is Vixie cron's own: a job
-- whose HOUR field is a star runs many times a day, so it should ride through
-- a daylight-saving transition unchanged -- an hour repeated means an extra
-- hour of polling, an hour skipped means an hour less. A job that NAMES an
-- hour is somebody's 03:00 report, and it has to happen once: not twice when
-- the clock goes back over it, and not never when the clock jumps over it.
--
-- `*` or `*/n` in the hour field is a poll; anything else is an appointment.
create or replace function workflow.cron_is_wall_clock(p_expr text)
returns boolean as $$
    select (regexp_split_to_array(btrim(p_expr), '\s+'))[2] not like '*%';
$$ language sql immutable;

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
    v_wall    boolean;
    v_local   timestamp;
    v_prev    timestamp;
    v_scan    timestamp;
    v_missed  timestamp;
    v_guard   int;
    v_due     boolean;
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
            -- THE LOCAL CLOCK IS THE ONE THE EXPRESSION TALKS ABOUT, and twice
            -- a year it is not a function of the UTC minute. Both halves below
            -- were found by asking the engine directly, and neither had a test
            -- or a line of documentation:
            --
            --   * Clocks back. 2026-11-01 in America/New_York: 05:30Z and
            --     06:30Z are BOTH 01:30 local, and `30 1 * * *` matched at
            --     each. The external_id is keyed on the UTC minute, so the
            --     engine's own idempotency did not collapse them either -- a
            --     nightly reconcile ran twice, once a year, quietly.
            --   * Clocks forward. 2026-03-08 in the same zone: 01:59 local is
            --     followed by 03:00 local, so `30 2 * * *` matched no minute
            --     at all and the run simply did not happen. Nothing was
            --     recorded, because nothing failed.
            --
            -- Vixie cron's distinction is the one that resolves both, and
            -- workflow.cron_is_wall_clock() carries it: a POLL (`*` in the
            -- hour field) rides the transition unchanged, and an APPOINTMENT
            -- fires exactly once per local wall-clock minute.
            v_wall  := workflow.cron_is_wall_clock(s.cron_expr);
            v_local := v_minute at time zone s.timezone;
            v_due   := workflow.cron_matches_local(s.cron_expr, v_local);

            -- Clocks back: this appointment's local minute has already been
            -- served. Bounded to three hours so that EDITING a schedule's
            -- timezone cannot suppress it -- the longest DST step in the
            -- tz database is an hour, and this is not a general "did it fire
            -- today" memory.
            if v_due and v_wall and s.last_fired_at is not null
               and v_minute - s.last_fired_at < interval '3 hours'
               and v_local <= (s.last_fired_at at time zone s.timezone) then
                update workflow.schedules
                   set last_tick_at = v_minute, skip_count = skip_count + 1
                 where id = s.id;
                continue;
            end if;

            -- Clocks forward: the local clock advanced further than the UTC
            -- clock did, so some local minutes have no instant. A ticker that
            -- was merely DOWN for an hour advances both by the same amount and
            -- is deliberately not caught here -- catching up an outage is a
            -- different decision, and not this one.
            if not v_due and v_wall and s.last_tick_at is not null then
                v_prev := s.last_tick_at at time zone s.timezone;
                if (v_local - v_prev) > (v_minute - s.last_tick_at) then
                    v_scan   := date_trunc('minute', v_prev) + interval '1 minute';
                    v_missed := null;
                    v_guard  := 0;
                    while v_scan < v_local and v_guard < 180 loop
                        if workflow.cron_matches_local(s.cron_expr, v_scan) then
                            v_missed := v_scan;
                            exit;
                        end if;
                        v_scan  := v_scan + interval '1 minute';
                        v_guard := v_guard + 1;
                    end loop;
                    -- Fire it now rather than not at all, which is what cron
                    -- does and what the person who wrote "02:30" meant.
                    v_due := v_missed is not null;
                end if;
            end if;

            if not v_due then
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
        using errcode = 'insufficient_privilege',
              hint = 'workflow-engine/integration-rbac.sql installs the '
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

    -- Startable, for the reason start_child_workflow gives above.
    if (workflow.current_definition(p_workflow)).id is null then
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
-- MATRIX ROWS COME FROM A QUERY, OR FROM A REGISTERED FUNCTION.
--
-- This used to be refused: expansion is SECURITY DEFINER, so a step that could
-- supply a statement was a privilege-escalation primitive with a YAML front
-- end, and `rows:` had to name a function in the same allow-list `sql` steps
-- used. The description of what happens is still accurate; it is simply the
-- trade `percolate.sql_policy = 'open'` now takes everywhere, and a fan-out
-- over "everything nobody has processed yet" is the most natural thing anyone
-- writes here -- making that one case need an owner-only registration was most
-- of what made the allow-list feel like a tax.
--
-- Two differences from an ordinary statement step, both deliberate. A row
-- source is ALWAYS READ-ONLY whatever the step says, because it is re-run by
-- every retry of this expansion and a row function that mutates while deciding
-- how many children to make has no good reading. And `rows: {function, args}`
-- stays -- it is what a deployment running `sql_policy = 'registered'` is
-- restricted to, and a literal `items: [...]` still covers the small static
-- case with neither.
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
        -- {{items}} is deliberately NOT resolvable here. It is bound at
        -- expansion (§20j), inside the matrix template, so reaching this
        -- branch means it was written on an ordinary step -- where there is no
        -- batch and no honest answer.
        raise exception
            'unknown template namespace ''%'' in a sql step argument '
            '-- expected steps, run or item%', v_head,
            case when v_head = 'items'
                 then '. {{items}} is a matrix TEMPLATE namespace: it binds when the '
                      'fan-out expands, so it means nothing on a step outside one.'
                 else '' end;
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
    v_pos    int;
    v_start  int;
    v_end    int;
begin
    for v_arg in select * from jsonb_array_elements(coalesce(p_args, '[]'::jsonb))
    loop
        -- ONLY A STRING IS A TEMPLATE. `#>> '{}'` on an array or object is its
        -- JSON text, so a batch of rows ({{items}}, substituted at expansion)
        -- whose text held `{{...}}` was re-resolved and came back as a STRING
        -- in place of the array. A non-string argument is a value.
        v_txt := case when jsonb_typeof(v_arg) = 'string' then v_arg #>> '{}' end;
        -- `$` joins the character class so {{run.$id}} is a whole-string
        -- reference like any other.
        if v_txt is not null and v_txt ~ '^\s*\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}\s*$' then
            v_ref := trim(both from replace(replace(v_txt, '{{', ''), '}}', ''));
            v_out := v_out || jsonb_build_array(
                workflow.resolve_template_ref(v_ref, p_run_id, p_item));

        elsif v_txt is not null and v_txt ~ '\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}' then
            -- ONE PASS OVER THE ORIGINAL, never over what was substituted.
            --
            -- The first version replaced each reference in turn with
            -- replace(), which re-scans the whole string -- so a VALUE that
            -- happened to look like a template was substituted on a later
            -- iteration. Measured: run input {"a": "{{run.b}}", "b": "SECRET"}
            -- and the argument '{{run.a}} then {{run.b}}' resolved to
            -- "SECRET then SECRET". The caller's DATA became a template, and
            -- the run input is caller-supplied, which is the whole problem.
            -- Values are data. Data is never re-read as instructions.
            v_new := '';
            v_pos := 1;
            loop
                v_start := regexp_instr(v_txt, '\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}', v_pos);
                exit when v_start = 0;
                v_end := regexp_instr(v_txt, '\{\{\s*[a-zA-Z0-9_.$]+\s*\}\}',
                                      v_pos, 1, 1);   -- position AFTER the match
                v_ref := trim(both from replace(replace(
                             substr(v_txt, v_start, v_end - v_start), '{{', ''), '}}', ''));
                v_val := workflow.resolve_template_ref(v_ref, p_run_id, p_item);
                -- A JSON null is a VALUE, so resolve_template_ref lets it
                -- through -- its guard is `is null`, which jsonb 'null' is
                -- not. Rendering it is where that stops being harmless:
                -- `#>> '{}'` on jsonb 'null' returns SQL NULL, and `text ||
                -- NULL` is NULL, so ONE null reference silently annihilated
                -- the entire argument. Measured: run input {"q": null} and
                -- the argument 'SEARCH "{{run.q}}" FROM chunks' resolving to
                -- NULL rather than to a query.
                --
                -- Raised rather than rendered as the four characters "null",
                -- because a search for the literal string null is the same
                -- silent-degradation class this interpolation was added to
                -- close. A whole-string reference still passes jsonb null
                -- through untouched: there it is an argument, and whether a
                -- null argument is legal is the callee's question.
                if jsonb_typeof(v_val) = 'null' then
                    raise exception
                        'template ''%'' is null, and this argument is text around it '
                        '(%). A null cannot be rendered into a string without changing '
                        'what the string says -- pass it as the whole argument if the '
                        'function accepts null.', v_ref, left(v_txt, 60);
                end if;
                -- `#>> '{}'` renders a string without its quotes and anything
                -- else as its JSON text.
                v_new := v_new || substr(v_txt, v_pos, v_start - v_pos)
                                || (v_val #>> '{}');
                v_pos := v_end;
            end loop;
            v_out := v_out || jsonb_build_array(to_jsonb(v_new || substr(v_txt, v_pos)));

        else
            v_out := v_out || jsonb_build_array(v_arg);
        end if;
    end loop;
    -- §20a-ter: row text arrives with `{` escaped; put it back now that the
    -- single pass is done.
    return workflow.brace_restore(v_out, nullif(current_setting('workflow.braces', true), ''));
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
            'workflow.register_step_function(), or write the query directly as '
            '`sql: "select ..."` -- unless this deployment sets '
            'percolate.sql_policy = ''registered'', which is the mode that refuses that.',
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

-- THE THREE-ARGUMENT FORM IS DROPPED, NOT SUPERSEDED.
--
-- `create or replace` with a new parameter list creates an OVERLOAD: the old
-- (jsonb, jsonb, text) body stayed resident in every database that had already
-- applied this file, and any caller still on that arity silently got it --
-- a body that cannot resolve {{items}} and does not error, which is the
-- quietest possible way to be wrong. surface.sql asserts the four-argument
-- form exists and would not have noticed the stale one beside it.
drop function if exists workflow.substitute_item(jsonb, jsonb, text);

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
-- §20j's `{{items}}` -- the whole batch, when the step declares one -- binds
-- here too, and the argument above is why it was never a question the second
-- time: a batched `rest` child POSTing its rows as a body would otherwise need
-- the same worker to learn a namespace it does not have.
--
-- The payoff beyond correctness: a worker never learns that a task came from a
-- fan-out. Expansion is the engine's business, and it now stays there.
-- ------------------------------------------------------------
--
-- p_rows is the whole batch (§20j) and p_item the part of it a child may
-- address as one row: the row itself when the step does not batch, and the
-- columns constant across the batch when it does. Two parameters rather than
-- one because {{item.col}} and {{items}} are different questions -- "the value
-- this task is about" and "every row this task owns" -- and a function that
-- guessed which was meant from the type it was handed would answer the wrong
-- one silently on a batch of exactly one.
--
-- 20a-ter. ROW TEXT IS DATA, AND IS ESCAPED ON THE WAY IN. Substitution puts
-- a row's text into the child input, and the input is then resolved a SECOND
-- time: by the worker at dispatch (`{{run.*}}`, `{{steps.*}}`, `{{env.*}}`) or
-- by resolve_args for a `sql` child. A row whose text contains `{{env.X}}` was
-- therefore resolved as a template. Found backfilling session transcripts
-- through the upload pipeline (2026-09-11): a session that quoted a workflow
-- document failed with `template {{env.LLM_URL}} resolved to nothing`, and
-- `{{env.<secret>}}` in an uploaded document would have put that secret into
-- the prompt sent to the model provider. The same loop below also re-scanned
-- text it had just inserted, so one column's value could name another.
--
-- p_braces is a sentinel, chosen per child by the expansion, that replaces
-- every `{` in text that came from a row. No template can then begin inside
-- row data, and none can be assembled from two adjacent values either. The
-- expansion records the sentinel as `input.braces` when anything was escaped,
-- and each resolver puts `{` back after its single pass: the worker
-- (templates.resolve_task) and resolve_args. A null sentinel is the old
-- behaviour, kept so a caller that passes four arguments is unchanged.
create or replace function workflow.brace_escape(p_value jsonb, p_braces text)
returns jsonb language sql immutable as $$
    select case
        when p_braces is null or p_value is null then p_value
        when jsonb_typeof(p_value) = 'string'
            then to_jsonb(replace(p_value #>> '{}', '{', p_braces))
        when jsonb_typeof(p_value) = 'object' then coalesce((
            select jsonb_object_agg(k, workflow.brace_escape(v, p_braces))
              from jsonb_each(p_value) as e(k, v)), '{}'::jsonb)
        when jsonb_typeof(p_value) = 'array' then coalesce((
            select jsonb_agg(workflow.brace_escape(v, p_braces) order by o)
              from jsonb_array_elements(p_value) with ordinality as e(v, o)), '[]'::jsonb)
        else p_value
    end;
$$;

create or replace function workflow.brace_restore(p_value jsonb, p_braces text)
returns jsonb language sql immutable as $$
    select case
        when p_braces is null or p_braces = '' or p_value is null then p_value
        when jsonb_typeof(p_value) = 'string'
            then to_jsonb(replace(p_value #>> '{}', p_braces, '{'))
        when jsonb_typeof(p_value) = 'object' then coalesce((
            select jsonb_object_agg(k, workflow.brace_restore(v, p_braces))
              from jsonb_each(p_value) as e(k, v)), '{}'::jsonb)
        when jsonb_typeof(p_value) = 'array' then coalesce((
            select jsonb_agg(workflow.brace_restore(v, p_braces) order by o)
              from jsonb_array_elements(p_value) with ordinality as e(v, o)), '[]'::jsonb)
        else p_value
    end;
$$;

-- The sentinel, derived from the rows rather than random so the same rows
-- expand to the same input (a replay can be diffed), and checked absent from
-- both template and rows, since a sentinel the data already contains would be
-- restored into a `{` that was never there.
create or replace function workflow.brace_sentinel(p_tmpl jsonb, p_rows jsonb)
returns text language plpgsql immutable as $$
declare v text; i int := 0; v_all text := coalesce(p_tmpl::text, '') || coalesce(p_rows::text, '');
begin
    loop
        v := '⦃' || left(md5(coalesce(p_rows::text, '') || i::text), 12) || '⦄';
        exit when position(v in v_all) = 0;
        i := i + 1;
        if i > 16 then
            raise exception 'could not choose a brace sentinel absent from the rows';
        end if;
    end loop;
    return v;
end $$;

drop function if exists workflow.substitute_item(jsonb, jsonb, jsonb, text);
create or replace function workflow.substitute_item(
    p_value jsonb, p_item jsonb, p_rows jsonb, p_step text, p_braces text default null)
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
                v_key, workflow.substitute_item(p_value->v_key, p_item, p_rows, p_step, p_braces));
        end loop;
        return v_out;

    when 'array' then
        return coalesce((
            select jsonb_agg(workflow.substitute_item(e, p_item, p_rows, p_step, p_braces) order by ord)
            from jsonb_array_elements(p_value) with ordinality as x(e, ord)), '[]'::jsonb);

    when 'string' then
        v_txt := p_value #>> '{}';

        -- {{items}} -- every row this child owns, as an array. Bound at
        -- EXPANSION like {{item.*}} and for the same reason: a batched `rest`
        -- child POSTing ten records as its body is the headline case for
        -- batching over a network, and resolving this at dispatch instead
        -- would put a fourth namespace into the contract of a shipped worker
        -- image that knows three -- the exact mistake §20a-bis records.
        --
        -- An array of one when the step does not batch, so batch_size stays a
        -- number an author can turn up or down without rewriting the step it
        -- feeds.
        if v_txt ~ '^\s*\{\{\s*items\s*\}\}\s*$' then
            return workflow.brace_escape(p_rows, p_braces);
        end if;
        -- Embedded in a larger string, it is refused rather than rendered.
        -- {{item.cik}} interpolates because a column is a scalar; a batch is
        -- an array, and splicing its JSON text into a URL produces a request
        -- that is wrong in a way no status code reports.
        if v_txt ~ '\{\{\s*items\s*\}\}' then
            raise exception
                'matrix step ''%'': {{items}} is embedded in ''%''. The batch is an '
                'array -- it can be a whole value (a request body, a sql argument), '
                'not part of a string.', p_step, v_txt;
        end if;

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
            return workflow.brace_escape(v_val, p_braces);
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
                replace(case when jsonb_typeof(v_val) = 'string' then v_val #>> '{}'
                             else v_val::text end, '{', coalesce(p_braces, '{')));
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
--     "batch_size": 10,                    -- optional: rows per child
--     "partition_by": ["tenant"],          -- optional: rows that stay together
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
-- BATCHING -- one child owns MANY rows (§20j). A matrix over 100 rows creating
-- 100 tasks is right when a row is an HTTP call and wrong when a row is a
-- database write: 100 claims, 100 heartbeats and 100 completions to do work
-- that one statement could do in ten. `batch_size` caps the rows per child;
-- `partition_by` names columns whose rows must stay in the same child. Either
-- one on its own is enough to make the step batched; both together partition
-- first, then chunk each partition at the cap.
--
-- A batched child carries `input.items` (its rows, in order) and `input.batch`
-- ({index, size, key}) INSTEAD of `input.item` -- the shape says how many rows
-- the task owns, so nothing downstream has to guess. `{{item.<col>}}` still
-- resolves in a batched template, but only for a column that is CONSTANT
-- across the batch, which is exactly what partition_by manufactures; naming
-- one that varies fails the step before any child exists.
--
-- `max_fanout` still counts ROWS, not children. It exists to stop a cross join
-- with a forgotten WHERE, and batching a runaway does not make it smaller.
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
    v_bsize     int;
    v_part      jsonb;
    v_batched   boolean;
    v_eff       int;
    v_cap       int;
    v_b         record;
    v_common    jsonb;
    v_brace     text;
    v_prev_run  text;
    v_input     jsonb;
    v_ref       text[];
    v_bad_ord   bigint;
    v_bad_type  text;
    v_bad_col   text;
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

        -- Batching (§20j). Shape checked here, before the row function runs,
        -- so a typo costs no query.
        v_bsize := nullif(v_spec->>'batch_size', '')::int;
        v_part  := v_spec->'partition_by';
        if v_bsize is not null and v_bsize < 1 then
            raise exception
                'matrix step ''%'' has batch_size %, which gives every child no rows. '
                'Omit it for one row per child.', t.step_key, v_bsize;
        end if;
        if v_part is not null then
            if jsonb_typeof(v_part) <> 'array' or jsonb_array_length(v_part) = 0
               or exists (select 1 from jsonb_array_elements(v_part) e
                          where jsonb_typeof(e) <> 'string') then
                raise exception
                    'matrix step ''%'' has partition_by %, where a non-empty array of '
                    'column names was expected.', t.step_key, v_part;
            end if;
        end if;
        v_batched := v_bsize is not null or v_part is not null;
        -- No cap under a bare partition_by: "one child per tenant" is the whole
        -- request, and a partition too big for one task is caught by the
        -- payload check below with batch_size named as the remedy.
        v_eff := coalesce(v_bsize, case when v_part is null then 1 else 2147483647 end);

        -- The row set. Exactly one source, checked rather than preferred, so
        -- a spec carrying both is a named error instead of a silent choice.
        if (v_spec ? 'rows') = (v_spec ? 'items') then
            raise exception
                'matrix step ''%'' must declare exactly one of `rows` (a registered '
                'function) or `items` (a literal list)', t.step_key;
        end if;

        -- THE ROW SOURCE RUNS FOR THIS RUN, and publishes it the way
        -- execute_sql_step does -- once, around both kinds of source. Two fixes
        -- arrived the same day from two directions: a `rows:` statement or a
        -- `rows: {function: p8ql}` read with the engine's reach instead of the
        -- starter's (the tour, act 8), and a row function that reads its run
        -- found nothing and returned an empty set, releasing the successor as if
        -- there were nothing to fan out over (dogfood, 2026-09-11). Restored
        -- after; an error unwinds it with the subtransaction.
        v_prev_run := coalesce(nullif(current_setting('workflow.current_run_id', true), ''), '');
        perform set_config('workflow.current_run_id', t.run_id::text, true);

        if v_spec ? 'items' then
            v_rows := v_spec->'items';
        elsif v_spec #> '{rows}' ? 'statement' then
            -- The row source may be the query itself, on the same terms as any
            -- other statement (schema.sql's "SQL a step wrote itself"), with
            -- one difference: it is ALWAYS read-only, whatever the step says. A
            -- row function that mutates while deciding how many children to
            -- make is re-run by every retry of this expansion, and there is no
            -- reading of `write: true` on a fan-out source that ends well.
            v_rows := workflow.run_sql(
                workflow.resolve_statement(v_spec#>>'{rows,statement}', t.run_id,
                                           t.input->'item'),
                false,
                coalesce((v_spec#>>'{rows,timeout_ms}')::int, 30000));
        else
            v_rows := workflow.call_step_function(
                v_spec#>>'{rows,function}', v_spec#>'{rows,args}', t.run_id, t.input->'item');
        end if;
        perform set_config('workflow.current_run_id', v_prev_run, true);

        if v_rows is null or jsonb_typeof(v_rows) <> 'array' then
            raise exception
                'matrix step ''%'' produced % where a JSON array of row objects was '
                'expected -- a matrix function must return jsonb shaped like '
                '[{"col": ...}, ...]', t.step_key, coalesce(jsonb_typeof(v_rows), 'null');
        end if;

        -- The ceiling is on the ROW SET, and stays there when the step batches.
        -- Batching divides the number of TASKS; it does nothing about a cross
        -- join that returned five million rows, and every one of those rows
        -- still has to be carried in some task's input.
        if jsonb_array_length(v_rows) > v_max then
            raise exception
                'matrix step ''%'' produced % rows, over its declared max_fanout of %. '
                'Narrow the query or raise the ceiling deliberately. max_fanout counts '
                'rows, not children -- batching makes fewer tasks, not a smaller '
                'runaway.',
                t.step_key, jsonb_array_length(v_rows), v_max;
        end if;

        -- ROWS MUST BE OBJECTS ONCE ANYTHING READS THEIR COLUMNS, and both
        -- readers are below: partition_by groups on named columns, and a
        -- batched child folds its rows together with jsonb_each to find the
        -- ones constant across the batch.
        --
        -- A scalar row set -- `items: [1, 2, 3]` -- is perfectly legal
        -- unbatched: substitute_item does `p_item #> path`, gets null, and the
        -- author is told '{{item.x}} is not a column of the row set'. Adding
        -- batch_size to that working step turned the same mistake into
        -- `cannot deconstruct a scalar` from inside jsonb_each, which names
        -- neither the step nor the change that caused it. Checked here, once,
        -- with the ordinal of the row that is wrong.
        if v_batched and jsonb_array_length(v_rows) > 0 then
            select x.ord, jsonb_typeof(x.e) into v_bad_ord, v_bad_type
            from jsonb_array_elements(v_rows) with ordinality x(e, ord)
            where jsonb_typeof(x.e) <> 'object'
            order by x.ord
            limit 1;
            if v_bad_ord is not null then
                raise exception
                    'matrix step ''%'': row % of the row set is a %, and batching or '
                    'partitioning reads rows BY COLUMN. Return objects shaped like '
                    '[{"col": ...}, ...], or drop batch_size/partition_by and let each '
                    'row be its own child.',
                    t.step_key, v_bad_ord, v_bad_type;
            end if;
        end if;

        -- Named columns must exist IN EVERY ROW, not in the first one.
        --
        -- This checked `v_rows->0` alone. A row function that omits the key on
        -- later rows then produced `item->c` = SQL NULL, jsonb_object_agg made
        -- `{"tenant": null}`, and every key-less row landed in one silently
        -- separate partition -- which is exactly the "rows that must stay
        -- together got split" outcome partition_by exists to prevent, with no
        -- diagnostic anywhere. The comment already claimed the check was over
        -- the whole set; now it is.
        if v_part is not null and jsonb_array_length(v_rows) > 0 then
            for v_bad_col in select e #>> '{}' from jsonb_array_elements(v_part) e loop
                select x.ord into v_bad_ord
                from jsonb_array_elements(v_rows) with ordinality x(e, ord)
                where not (x.e ? v_bad_col)
                order by x.ord
                limit 1;
                if v_bad_ord is not null then
                    raise exception
                        'matrix step ''%'': partition_by names ''%'', which row % of the '
                        'row set does not carry. That row has: %. Every row must carry '
                        'every partition column -- the ones that do not would have been '
                        'grouped together under a null key.',
                        t.step_key, v_bad_col, v_bad_ord,
                        coalesce((select string_agg(k, ', ' order by k)
                                    from jsonb_object_keys(v_rows->(v_bad_ord::int - 1)) k),
                                 '(no columns)');
                end if;
            end loop;
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
            update workflow.tasks set status = 'succeeded' where id = p_task_id;
            return (select count(*)::int from workflow.tasks where matrix_parent_id = p_task_id);
        end if;

        -- 1. The children. One per BATCH -- and an unbatched matrix is the
        --    degenerate batch of one, which is why there is one loop and not
        --    two. A second loop for the batched case would be a second place
        --    to fix the rewire, the collision check and the payload cap.
        --
        --    Each child carries its rows verbatim (`item` for a batch of one
        --    by construction, `items` when the step declared batching); the
        --    template's own {{...}} references are left untouched and resolve
        --    at dispatch, like every other step's.
        --
        --    Partitions are emitted in order of FIRST APPEARANCE, and rows
        --    keep their source order inside a batch, so the child keys are a
        --    deterministic function of the row set -- the same property the
        --    re-expansion hash depends on.
        v_cap := coalesce(
            nullif(current_setting('workflow.max_payload_bytes', true), '')::int, 65536);

        for v_b in
            with r as (
                select e as item, ord
                from jsonb_array_elements(v_rows) with ordinality x(e, ord)
            ), k as (
                select item, ord,
                       case when v_part is null then 'null'::jsonb
                            else (select coalesce(jsonb_object_agg(c, item->c), '{}'::jsonb)
                                  from jsonb_array_elements_text(v_part) c) end as pk
                from r
            ), g as (
                select item, ord, pk,
                       min(ord) over (partition by pk) as first_ord,
                       ((row_number() over (partition by pk order by ord) - 1) / v_eff)
                           as chunk
                from k
            )
            select jsonb_agg(item order by ord) as rows,
                   case when v_part is null then null else pk end as key,
                   first_ord, chunk
            from g
            group by pk, first_ord, chunk
            order by first_ord, chunk
        loop
            if v_batched then
                -- The columns a batched child may template: present in every
                -- row of the batch and holding one distinct value. Under
                -- partition_by the partition columns are constant by
                -- construction, which is what makes
                -- `.../tenant/{{item.tenant}}` legal on a batch of fifty.
                select coalesce(jsonb_object_agg(kk, vv), '{}'::jsonb) into v_common
                from (
                    select j.key as kk, (array_agg(j.value))[1] as vv
                    from jsonb_array_elements(v_b.rows) e, lateral jsonb_each(e) j
                    group by j.key
                    having count(distinct j.value) = 1
                       and count(*) = jsonb_array_length(v_b.rows)
                ) c;

                -- Checked here rather than left to substitute_item, because
                -- the two failures need different remedies: "no such column"
                -- is a typo, "varies within the batch" is a partition_by that
                -- was not declared, and one message cannot say both.
                for v_ref in select regexp_matches(
                        v_tmpl::text, '\{\{\s*item\.([a-zA-Z0-9_.]+)\s*\}\}', 'g')
                loop
                    if v_common #> string_to_array(v_ref[1], '.') is null
                       and (v_b.rows->0) #> string_to_array(v_ref[1], '.') is not null then
                        raise exception
                            'matrix step ''%'': the template names {{item.%}}, which VARIES '
                            'across the rows of batch %. A batched child owns many rows, so '
                            'only a column constant across the batch can be substituted into '
                            'it -- add ''%'' to partition_by to make it one, or read the rows '
                            'from input.items in the child instead.',
                            t.step_key, v_ref[1], v_i, v_ref[1];
                    end if;
                end loop;

                v_brace := workflow.brace_sentinel(v_tmpl, v_b.rows);
                v_input := workflow.substitute_item(
                               coalesce(v_tmpl->'input', '{}'::jsonb),
                               v_common, v_b.rows, t.step_key, v_brace)
                           || jsonb_build_object(
                                'items', v_b.rows,
                                'batch', jsonb_build_object(
                                    'index', v_i,
                                    'size',  jsonb_array_length(v_b.rows),
                                    'key',   v_b.key));
            else
                v_row := v_b.rows->0;
                -- Substituted, then the row appended verbatim. The child's
                -- input therefore says exactly what will be sent AND still
                -- carries the snapshot §20 records.
                v_brace := workflow.brace_sentinel(v_tmpl, v_row);
                v_input := workflow.substitute_item(
                               coalesce(v_tmpl->'input', '{}'::jsonb),
                               v_row, jsonb_build_array(v_row), t.step_key, v_brace)
                           || jsonb_build_object('item', v_row);
            end if;

            -- §20a-ter: the sentinel is recorded only when row text was
            -- escaped, so a child whose rows hold no `{` is unchanged.
            if position(v_brace in v_input::text) > 0 then
                v_input := v_input || jsonb_build_object('braces', v_brace);
            end if;

            -- A `sql` STATEMENT IS PUT BACK UNSUBSTITUTED, and this is the
            -- whole of the matrix half of the injection fix.
            --
            -- substitute_item interpolates {{item.*}} as text, which is right
            -- for every other field it fills -- a rest body, a URL, an agent
            -- argument -- and wrong for exactly one, because that one is handed
            -- to the SQL parser. Interpolated here, a site reference of
            -- `x'' || current_user || ''` expanded into a statement that ran and
            -- returned `xapp_owner`: arbitrary SQL out of ordinary row data,
            -- executing as the engine owner. Found by walking
            -- scenarios/evals/J2, recorded in runs/2026-09-04-J2.md.
            --
            -- So the template survives to execution, where execute_sql_step
            -- resolves it through resolve_statement_params and the row becomes
            -- a BOUND PARAMETER. The child still carries `item` in its input --
            -- appended below and unchanged -- which is what that resolution
            -- reads, so nothing else has to know this happened.
            if (v_tmpl->'input') ? 'statement' then
                v_input := v_input || jsonb_build_object(
                               'statement', v_tmpl->'input'->'statement');
            end if;

            -- §7's cap would catch this on INSERT, and its message would send the
            -- author to look for a big payload when what they have is too many
            -- small ones. A batch is the one case where the remedy is a number
            -- in the spec, so it is worth naming.
            if pg_column_size(v_input) > v_cap then
                raise exception
                    'matrix step ''%'': batch % holds % rows and % bytes of task input, '
                    'over the % byte cap. Lower batch_size (currently %), or raise '
                    'workflow.max_payload_bytes deliberately.',
                    t.step_key, v_i, jsonb_array_length(v_b.rows),
                    pg_column_size(v_input), v_cap, v_eff;
            end if;

            insert into workflow.tasks (
                run_id, step_key, queue, kind, input, rate_key,
                pending_deps, status, matrix_parent_id, parent_span_id,
                saga_group, compensation_task_key, tolerate_failure)
            values (
                t.run_id,
                t.step_key || '[' || v_i || ']',
                coalesce(v_tmpl->>'queue', t.queue),
                coalesce(v_tmpl->>'kind', 'work'),
                v_input,
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
        --
        -- `rows` is separate from `fanout` because batching made them different
        -- numbers, and a fan-in that reports "100 processed" off a count of
        -- children would be wrong by a factor of batch_size. They are equal on
        -- an unbatched matrix, which is why one field was enough until now.
        perform workflow.complete_task(p_task_id, jsonb_build_object('result',
            jsonb_build_object(
                'task_id',   p_task_id,
                'fanout',    coalesce(array_length(v_children, 1), 0),
                'rows',      jsonb_array_length(v_rows),
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
            -- A malformed spec, an unregistered function, a blown ceiling or
            -- a caller the database refused (42501) fails identically on every
            -- retry. A deadlock or timeout does not.
            sqlstate in ('42501','42883','42P01','P0001'));
        return 0;
    end;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The number expand_matrix put in a child's step_key, as a number.
--
-- Every reader of a fan-out's recorded rows wants them in the order the row
-- function produced, and every one of them had `order by created_at, step_key`
-- -- where created_at is the transaction timestamp, identical across an
-- expansion, so the text sort of step_key decided. `fan[10]` sorts before
-- `fan[2]`, so eleven children were enough to hand back a row set in an order
-- nothing produced. Every test used ten or fewer.
--
-- -1 for a key that carries no bracketed index, so a child named some other
-- way sorts ahead of the numbered ones deterministically rather than
-- disappearing into a null.
create or replace function workflow.child_ordinal(p_step_key text)
returns bigint
language sql
immutable
as $$
    select coalesce(nullif(substring(p_step_key from '\[([0-9]+)\]$'), '')::bigint, -1);
$$;

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

    -- `item` and `items` are both here and exactly one of them is ever
    -- non-null: `item` on an ordinary child, `items` on a batched one (§20j).
    -- Not collapsed into a single always-an-array field, which was the first
    -- shape tried: it would have duplicated every row of an unbatched fan-out
    -- inside a wrapper array, in the one function whose payload is already N
    -- outputs wide, to spare an aggregate a coalesce it mostly does not need.
    return (select coalesce(jsonb_agg(jsonb_build_object(
                'step_key', t.step_key, 'item', t.input->'item',
                'items', t.input->'items',
                'status', t.status, 'output', t.output)
            order by t.created_at, workflow.child_ordinal(t.step_key), t.step_key), '[]'::jsonb)
            from workflow.tasks t where t.matrix_parent_id = p_task_id);
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- The same guard, as a function, because three other files need it.
--
-- `aiq.land_embeddings`, `aiq.land_graph_fanout` and `content.land_graph_windows`
-- are all fan-in step functions handed a matrix task id by a step spec, so all
-- three need exactly the check above: the task must belong to the run being
-- executed, or a workflow author can name another tenant's matrix task and read
-- what it produced. All three had it copy-pasted verbatim, error message
-- included -- four places to change when the rule or its wording moves, and
-- four chances to change three. §20d states the rule this violates: two copies
-- of a function is how a fix lands in only one of them.
--
-- It returns the run id because every caller wants it next.
--
-- matrix_outputs() above deliberately does NOT call this. integration-rbac.sql
-- replaces that one with a version that WIDENS the failing branch to "or a run
-- the caller may read", for the human calling it directly with an identity --
-- a different rule wearing the same shape, and folding them together would
-- quietly give a step function the caller's authority as a second way in.
create or replace function workflow.assert_task_in_current_run(p_task_id uuid)
returns uuid as $$
declare v_run uuid; v_cur text;
begin
    select run_id into v_run from workflow.tasks where id = p_task_id;
    if not found then
        raise exception 'task % not found', p_task_id;
    end if;

    v_cur := nullif(current_setting('workflow.current_run_id', true), '');
    if v_cur is null or v_cur::uuid <> v_run then
        raise exception
            'task % belongs to run %, which is not the run being executed. Pass '
            '{{steps.<id>.result.task_id}} rather than a task id from elsewhere.',
            p_task_id, v_run;
    end if;
    return v_run;
end;
$$ language plpgsql stable set search_path = pg_catalog, public;

-- SECURITY INVOKER, deliberately, and that is what makes lifting it out of the
-- three callers a pure refactor rather than a change: inlined, this read ran
-- with whatever rights the caller had -- app_owner inside the two definer
-- functions, the caller's own inside aiq.land_embeddings, which is an invoker
-- function. As a definer it would have granted the read to anyone later handed
-- EXECUTE. Every real path reaches it through execute_sql_step, which IS
-- definer, so the effective reader is app_owner either way.
--
-- Defined after §16(b)'s blanket `revoke ... from public`, so it says so itself.
revoke execute on function workflow.assert_task_in_current_run(uuid) from public;

-- Read the recorded row set back, in expansion order. This is the "snapshot"
-- that §5's decision-task purity contract is about -- it is a query, not a
-- column, because the rows live where they are individually useful.
--
-- REPLACED by integration-rbac.sql (e), which adds the ownership check this
-- one cannot make: it is SECURITY DEFINER and granted to `authenticated`, so
-- without that check a guessed task id reads another tenant's row set. Edit
-- there; this body is dead wherever user-rbac is loaded.
--
-- It returns the ROW SET, not the children, which is why a batched fan-out
-- (§20j) is flattened here rather than returned as an array of arrays: the
-- snapshot this reads back is the thing the row function produced, and
-- batching is a decision about who executes it, not about what it is. A
-- caller wanting the batch boundaries wants matrix_outputs.
create or replace function workflow.matrix_rows(p_task_id uuid)
returns jsonb as $$
    select coalesce(jsonb_agg(r order by t.created_at, workflow.child_ordinal(t.step_key), t.step_key, r_ord),
                    '[]'::jsonb)
    from workflow.tasks t
    cross join lateral jsonb_array_elements(
        case when t.input ? 'items' then t.input->'items'
             else jsonb_build_array(t.input->'item') end) with ordinality x(r, r_ord)
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

        -- Batching (§20j), refused at registration for the same reason the
        -- ceiling is: a spec can arrive as JSON without passing the compiler,
        -- and `batch_size: 0` is a definition that can only ever fail at 3am.
        -- THE TYPE IS CHECKED BEFORE THE VALUE, because `::int` runs first
        -- otherwise. `"batch_size": "ten"` (or 2.5, or true) failed with
        -- `invalid input syntax for type integer` -- a cast error naming
        -- neither the step nor the key -- in the one branch written to produce
        -- a message, and the malformed-value case is exactly what a spec that
        -- never passed the compiler is most likely to carry.
        if v_in ? 'batch_size' then
            if jsonb_typeof(v_in->'batch_size') <> 'number'
               or (v_in->>'batch_size') !~ '^[0-9]+$' then
                raise exception
                    'matrix step ''%'' has batch_size %, where a whole number of rows was '
                    'expected.', v_step->>'key', v_in->'batch_size';
            end if;
            if (v_in->>'batch_size')::int < 1 then
                raise exception
                    'matrix step ''%'' has batch_size %, which gives every child no rows. '
                    'Omit it for one row per child.',
                    v_step->>'key', v_in->>'batch_size';
            end if;
        end if;
        if v_in ? 'partition_by'
           and (jsonb_typeof(v_in->'partition_by') <> 'array'
                or jsonb_array_length(v_in->'partition_by') = 0
                or exists (select 1 from jsonb_array_elements(v_in->'partition_by') e
                           where jsonb_typeof(e) <> 'string')) then
            raise exception
                'matrix step ''%'' has partition_by %, where a non-empty array of column '
                'names was expected.', v_step->>'key', v_in->'partition_by';
        end if;

        -- AN ABSOLUTE min_success CANNOT SURVIVE BATCHING OR PARTITIONING.
        --
        -- matrix_gate_passes counts CHILDREN, and both keys change how many
        -- children a row set becomes: `min_success: 90` over 100 rows with
        -- `batch_size: 10` needs ninety successes out of ten children, so the
        -- gate can never pass and every run of the step fails the whole run.
        -- Adding batch_size to a working step was enough to trigger it, which
        -- is the worst possible shape for it to have -- the change that breaks
        -- it is unrelated to the key that breaks.
        --
        -- The fraction is unaffected (it is a proportion of whatever the
        -- children turn out to be), so the remedy is exact and the message can
        -- name it.
        if v_in ? 'min_success' and (v_in ? 'batch_size' or v_in ? 'partition_by')
           and jsonb_typeof(v_in->'min_success') = 'number'
           and (v_in->>'min_success')::numeric > 1 then
            raise exception
                'matrix step ''%'' sets min_success to the COUNT % and also %. The gate '
                'counts children, and batching decides how many children the rows become '
                '-- so a count written against rows can be unreachable. Write it as a '
                'fraction (0 < x <= 1), which means the same thing at any batch size.',
                v_step->>'key', v_in->>'min_success',
                case when v_in ? 'batch_size'
                     then 'batch_size ' || (v_in->>'batch_size')
                     else 'partition_by ' || (v_in->'partition_by')::text end;
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
-- §20a-ter: resolve_args restores row braces through this, as its caller.
grant execute on function workflow.brace_restore(jsonb, text) to worker, authenticated;
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

-- ------------------------------------------------------------
-- 20j. Batching -- a child owns a chunk of the row set, not a row of it.
--
-- The map half of map-reduce had exactly one granularity: one row, one task.
-- That is right when a row is an HTTP call to somebody else's API, because the
-- task IS the concurrency unit and the rate limit is per call. It is wrong the
-- moment a row is cheap: a hundred rows that each take four milliseconds of
-- work become a hundred claims, a hundred heartbeats, a hundred completions
-- and a hundred cascade cycles -- the engine costing more than the job. Ten
-- workers owning ten rows each is the shape people actually ask for, and until
-- now the only way to express it was to make the row function return chunks,
-- which moves a scheduling decision into a domain query and hides it from
-- every reader of the YAML.
--
-- So it is declared on the step, in two spellings that answer two different
-- questions:
--
--   batch_size: 10          how many rows may one worker own
--   partition_by: [tenant]  which rows must NOT be split across workers
--
-- Either alone is enough. Together they partition first and then chunk each
-- partition at the cap, which is the combination with an actual use: "group by
-- tenant, but no single task swallows more than fifty".
--
-- FOUR THINGS THIS HAD TO GET RIGHT.
--
-- 1. The child's input shape SAYS how many rows it owns. A batched child
--    carries `items` (an array) and `batch` ({index, size, key}); an unbatched
--    one carries `item`, exactly as before. The tempting alternative -- always
--    `items`, an array of one when unbatched -- is a smaller rule and a worse
--    one: every existing handler, every fan-in function and every recorded
--    task input in the collection reads `item`, and rewriting all of them to
--    unwrap a one-element array buys uniformity at the cost of the thing that
--    made the row visible in the first place. A shape that changes when the
--    author asks for a different shape is the honest version.
--
-- 2. `{{item.<col>}}` still works on a batch -- for a column that is constant
--    across it. This is not a leniency, it is the entire reason partition_by
--    is a partition and not just a sort: `partition_by: [tenant]` guarantees
--    `tenant` is one value in the child, so `.../t/{{item.tenant}}` means
--    something. Naming a column that varies fails the step BEFORE any child
--    exists, with the remedy in the message, rather than silently substituting
--    the first row's value -- which would produce a task that processes fifty
--    rows and addresses one of them, and would look correct in every test with
--    a batch size of one.
--
-- 3. A batched child must be able to READ its batch, and that is a second
--    template reference: `{{items}}`. Without it batching is unusable on
--    exactly the step kind it is most worth having on -- a `sql` child whose
--    args are `['{{item.chunk_id}}']` has no spelling for "all fifty of mine",
--    and the whole point of the feature is to turn a hundred cheap writes into
--    ten. It is bound at EXPANSION, beside `{{item.*}}` and for the same
--    reason: a batched `rest` child POSTing its ten records as a body is the
--    headline case for batching over a network, and binding at dispatch
--    instead would put a fourth namespace into the contract of a shipped
--    worker image that knows three. It is an array of one when the step does
--    not batch, so `batch_size` stays a number an author can turn up or down
--    without rewriting the step it feeds; and a `work` child that would rather
--    read its rows off the task row finds them at `input.items`, which
--    get_task_context hands over as a peer of `item`.
--
-- 4. `max_fanout` still counts ROWS. It would have been easy to let it count
--    children, since children are what get inserted -- and then a forgotten
--    WHERE with `batch_size: 1000` would slip a five-million-row cross join
--    past a ceiling of 5000 and land it in five thousand task inputs. The
--    ceiling guards the row set; batching decides who carries it.
--
-- WHAT BATCHING COSTS, stated because it is not free. `min_success` and
-- `continue_on` (§21e) count CHILDREN, and a batched child is a batch: one
-- failure now loses ten rows instead of one, and a 90% floor over ten batches
-- tolerates a single failure rather than ten. That is a real coarsening of
-- partial-failure tolerance and it is the trade the author is making when they
-- set batch_size -- fewer, larger units of both work and blast radius.
-- Retries are per task too, so a batch retried re-does every row in it, which
-- makes an idempotent handler a precondition rather than a nicety.
--
-- The other cost is the payload cap. N rows in one task input is the one place
-- in this engine where a spec value directly multiplies a stored payload, so
-- expansion checks the built input against §7's cap itself instead of letting
-- the INSERT trigger do it -- same failure, but the message names batch_size,
-- which is the number the author has to change and the one the generic
-- "reduce the payload" message cannot know about.
-- ------------------------------------------------------------
-- workflow.expand_matrix(uuid) is defined in section 20c.
-- This section explains why it has the shape it does; the body is not repeated,
-- because two copies of a function is how a fix lands in only one of them.

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

    select count(*), count(*) filter (where status = 'succeeded')
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
-- Without this a fan-out with continue_on could never reach 'succeeded' --
-- it would sit in 'running' forever, which is the stall this whole section
-- exists to avoid.
create or replace function workflow.check_run_completion(p_run_id uuid) returns void as $$
    update workflow.runs r
    set status = 'succeeded', completed_at = now()
    where r.id = p_run_id
      and r.status = 'running'
      and not exists (
          select 1 from workflow.tasks t
          where t.run_id = p_run_id
            and t.status <> 'succeeded'
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
-- external_id is UNIQUE per owner, so a retry cannot silently mint a second
-- run under the same key; the honest move is to say so by name and let the
-- caller decide
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
-- One id per (run, group), so one run can hold two independent conversations,
-- and it is defined HERE rather than after run_meta because run_meta calls it.
--
-- percolate.uuidv5, not md5(...)::uuid. specs/identity/spec.md §3 bans the
-- second and the comment inside run_meta already explained why -- md5 produces
-- a value whose version nibble is 0, which is not a UUID and compares unequal
-- to a correctly derived one computed anywhere else. `fa59c8e` moved run_meta
-- and left its sibling behind, which is the postmortem's own class
-- (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §1): a fix
-- applied to one of two copies of one rule.
--
-- THE TWO WERE ALSO NOT THE SAME FUNCTION OF THEIR INPUTS, which is why this
-- merges them rather than converting both. run_meta derived `$session` from
-- `r.id::text`; run_session derived it from `run_id || ':' || group`, so even
-- with the same hash the empty group would not have agreed with run_meta -- the
-- trailing colon is a different string. Spelling the empty group as the bare
-- run id keeps run_meta's published value EXACTLY as it is today, so no run's
-- `$session` moves and there is nothing to migrate. A named group still gets
-- its own id, which is what dev/tests/workflow/05 asserts.
create or replace function workflow.run_session(p_run_id uuid, p_group text default '')
returns uuid as $$
    select percolate.uuidv5(
        percolate.id_namespace('session'),
        case when coalesce(p_group, '') = '' then p_run_id::text
             else p_run_id::text || ':' || p_group end);
$$ language sql immutable;

comment on function workflow.run_session(uuid, text) is
    'The conversation id for a run, derived rather than stored so a replay '
    'converges on the same value. The empty group is the run''s own session and '
    'is what run_meta publishes as $session.';

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
        -- workflow.run_session(), not a second copy of the derivation. It
        -- was spelled out here and computed differently one function along,
        -- which is the pair REM-58 collapsed; the value is unchanged.
        '$session',     workflow.run_session(r.id)::text)
    from workflow.runs r
    join workflow.definitions d on d.id = r.workflow_def_id
    where r.id = p_run_id;
$$ language sql stable security definer set search_path = pg_catalog, public;


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
            ('rate_key',     E'name: c\nsteps:\n  - id: s\n    rest: {url: http://x}\n    rate_key: k'),
            -- `input:` IS PART OF THE PROBE, not decoration. An agent step
            -- without one is now refused by the compiler (it would have sent
            -- the model an empty message), so a probe omitting it reports the
            -- whole `agent` CAPABILITY as missing -- and then the skew check
            -- below tells an author with a perfectly good document to rebuild
            -- their extension. A probe must exercise the feature the way it is
            -- meant to be used, or it measures its own shortcut.
            ('agent',        E'name: c\nsteps:\n  - id: s\n    agent: a\n    input: hi'),
            ('work',         E'name: c\nsteps:\n  - id: s\n    work: true'),
            ('matrix',       E'name: c\nsteps:\n  - id: s\n    matrix:\n      items: []\n      max_fanout: 1\n      template: {work: true}'),
            ('signal',       E'name: c\nsteps:\n  - id: s\n    signal: true'),
            ('timer',        E'name: c\nsteps:\n  - id: s\n    timer: 1'),
            ('sub_workflow', E'name: c\nsteps:\n  - id: s\n    workflow: other'),

            ('continue_on',  E'name: c\nsteps:\n  - id: s\n    matrix:\n      items: []\n      max_fanout: 1\n      continue_on: failed\n      min_success: 0.5\n      template: {work: true}'),

            -- §20j. Probed for exactly the reason 22c exists: the SQL half of
            -- batching can ship without the compiler half, and the error a
            -- reader then gets is `unknown field batch_size` on a document
            -- YAML.md documents in full. Compile-success IS evidence here,
            -- unlike output_schema below, because WfMatrix carries
            -- deny_unknown_fields -- a compiler that has not heard of
            -- batch_size refuses the document rather than dropping the key.
            ('batching',     E'name: c\nsteps:\n  - id: s\n    matrix:\n      items: []\n      max_fanout: 10\n      batch_size: 5\n      partition_by: [tenant]\n      template: {work: true}')
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
-- `update workflow.tasks set status = 'succeeded' where id = p_task_id` -- no
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
the existing run rather than a second one. It is YOUR key -- the match is made
only among the runs you may see, so somebody else using the same value gets
their own run and neither of you is handed the other's id.$c$;

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

-- Does this text parse as a JSON array or object? A predicate rather than an
-- inline cast, because the only way to ask Postgres is to try it and catch the
-- failure, and an exception block inside the lint's own loop would be a third
-- level of nesting around one boolean.
create or replace function workflow.parses_as_json_container(p_text text)
returns boolean as $$
begin
    return jsonb_typeof(p_text::jsonb) in ('array', 'object');
exception when others then
    return false;
end;
$$ language plpgsql immutable;

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

        -- (a2) a jsonb argument written as a QUOTED JSON STRING.
        --
        -- `args: ['[{"a":1}]']` is a JSON string, not an array. It reaches a
        -- step function declared `jsonb` as a scalar and the run fails at
        -- dispatch with Postgres's own `cannot extract elements from a scalar`
        -- -- true, and about a value the author cannot see, naming neither the
        -- argument nor the remedy. YAML.md documents type preservation for
        -- whole-string REFERENCES and says nothing about literals, so the
        -- natural thing to type is the wrong one.
        --
        -- The allow-list already holds the declared argument types, so this is
        -- answerable while the author is still looking at the document rather
        -- than on the third task of a run.
        if v_step->>'kind' = 'sql' and v_step->'input' ? 'function' then
            declare
                v_types text[]; v_arg jsonb; v_i int := 0; v_txt text;
            begin
                select arg_types into v_types from workflow.step_functions
                 where name = v_step->'input'->>'function';
                for v_arg in
                    select * from jsonb_array_elements(
                        coalesce(v_step->'input'->'args', '[]'::jsonb))
                loop
                    v_i := v_i + 1;
                    if v_types is not null and v_types[v_i] = 'jsonb'
                       and jsonb_typeof(v_arg) = 'string' then
                        v_txt := ltrim(v_arg #>> '{}');
                        -- A TEMPLATE IS NOT A LITERAL, and forgetting that made
                        -- the first version of this rule refuse the shipped
                        -- `ask_uploads` workflow at install time: p8ql_vec's
                        -- vector argument is
                        -- '{{steps.retrieve__embed.result}}', which starts with
                        -- '{' and resolves at dispatch to a real array. A lint
                        -- firing on a document the collection itself ships is
                        -- the loudest possible version of being wrong, so this
                        -- is written to be sure rather than suspicious: skip
                        -- anything holding a reference, and flag only text that
                        -- actually parses as a JSON array or object.
                        if v_txt not like '%{{%'
                           and left(v_txt, 1) in ('[', '{')
                           and workflow.parses_as_json_container(v_txt) then
                            severity := 'error';
                            detail := format(
                                'argument %s of %s is declared jsonb and was '
                                'written as a quoted JSON string, so it arrives '
                                'as a scalar and the step fails at dispatch with '
                                '"cannot extract elements from a scalar". Write '
                                'it as a real YAML list or mapping under args:, '
                                'not inside quotes.',
                                v_i, v_step->'input'->>'function');
                            return next;
                        end if;
                    end if;
                end loop;
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
        --
        -- Only for the spelling that names one. A step carrying its own
        -- statement has nothing to look up, and reporting it as unregistered
        -- was the first thing that broke when statements were allowed --
        -- every such step drew a warning naming a null function.
        if v_step->>'kind' = 'sql'
           and not (v_step->'input' ? 'statement')
           and not exists (select 1 from workflow.step_functions f
                            where f.name = v_step->'input'->>'function') then
            severity := 'warning';
            detail := format('sql step calls %L, which is not registered '
                             '(workflow.register_step_function)',
                             v_step->'input'->>'function');
            return next;
        end if;

        -- (d2) a statement the deployment's policy will refuse at dispatch.
        -- Worth catching at authoring time: `registered` is a lockdown a
        -- deployment chose, and the definition that trips it is usually one
        -- written against a different environment.
        if v_step->>'kind' = 'sql'
           and (v_step->'input' ? 'statement')
           and workflow.sql_policy() = 'registered' then
            severity := 'error';
            detail := 'carries its own SQL, and percolate.sql_policy is '
                      '''registered'' on this deployment -- register the query as a '
                      'step function and name it';
            return next;
        end if;

        -- (d3) a statement that writes without saying so. The engine refuses it
        -- at dispatch anyway (transaction_read_only), so this is the same
        -- refusal moved to where the author is looking.
        if v_step->>'kind' = 'sql'
           and (v_step->'input' ? 'statement')
           and not coalesce((v_step->'input'->>'write')::boolean, false)
           and v_step->'input'->>'statement' ~*
               '^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy)\M' then
            severity := 'error';
            detail := 'is a read step whose statement modifies the database -- '
                      'declare `write: true` on it, or make it a query';
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
        --
        -- THE TABLE IS NAMED IN DYNAMIC SQL, AND THE `to_regclass` GUARD IS
        -- WHY IT HAS TO BE. `agentic` loads after this schema and after
        -- world-model-ingestion, so on a fresh install this function exists
        -- while agentic.agents does not -- and plpgsql PLANS a whole IF
        -- condition before evaluating any of it, so the guard could never run
        -- first. Static, the reference costs nothing until something calls
        -- define_yaml during installation, and then it fails the entire
        -- CREATE EXTENSION with `relation "agentic.agents" does not exist`.
        -- Which is exactly what happened the day an ingestion pipeline started
        -- installing its own workflow at load time.
        if v_step->>'kind' = 'http_call'
           and v_step->'input'->>'url' like '%P8_AGENT_URL%'
           and to_regclass('agentic.agents') is not null then
            declare v_unknown boolean;
            begin
                execute 'select not exists (select 1 from agentic.agents a where a.name = $1)'
                   into v_unknown using v_step->'input'->'body'->>'model';
                if v_unknown then
                    severity := 'warning';
                    detail := format('agent step names %L, which is not in agentic.agents -- '
                                     'this task will queue and wait rather than fail',
                                     v_step->'input'->'body'->>'model');
                    return next;
                end if;
            end;
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

        -- (h) a compensation step that waits for a forward step.
        --
        -- A compensation is kept out of the forward graph and created only if
        -- the rollback happens -- but nothing it DEPENDS on is: those are
        -- ordinary steps and they run on every run, including the ones that
        -- succeed. The vector sugar makes this easy to reach without noticing,
        -- because a one-line `p8ql: 'SEARCH ...'` compensation quietly adds a
        -- model call to the happy path, but the shape predates it: any
        -- `needs:` on a compensation step does the same thing.
        --
        -- A warning, not an error, because it WORKS -- verified by running a
        -- saga to rollback: the compensation resolved {{steps.<its embed>.result}}
        -- and executed. What it does not do is what the author expects, and
        -- the cost lands on runs that never fail.
        if v_step->>'key' = any(workflow.compensation_keys(p_spec))
           and coalesce(jsonb_array_length(v_step->'depends_on'), 0) > 0 then
            severity := 'warning';
            detail := format(
                'is a compensation step and depends on %s, which is not one -- that step '
                'runs in the FORWARD graph, on every run, including the runs that never '
                'roll back',
                (select string_agg(format('%L', d), ', ')
                   from jsonb_array_elements_text(v_step->'depends_on') d));
            return next;
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

-- ============================================================================
-- Operating at scale: retention, a plan gate, and the failures that are silent.
--
-- Everything in this section exists because dev/scale/ found it missing while
-- measuring the engine, and every one of them was a shell script or an ad-hoc
-- query first. A scaling property you can only check by remembering to write
-- the query is a property nobody checks.
-- ============================================================================

-- ------------------------------------------------------------
-- 1. Retention. The task table only ever grew.
--
-- Nothing in this engine deleted a task, so `workflow.tasks` grew without
-- bound -- and scale.md found that the autoscaler's own probe changes plan on
-- the ratio of live rows to total rows, so an unbounded table degrades the
-- thing that decides how many workers you get.
--
-- BATCHED, and that is the whole reason this is a function rather than advice.
-- Deleting a million task rows in one statement takes tens of minutes: every
-- row costs an index update per index plus a foreign-key probe into
-- task_dependencies, and it accumulates in one transaction's WAL. Measured on
-- the harness: a single-statement delete of 1M rows was still running after 22
-- minutes. Each batch here commits on its own.
-- ------------------------------------------------------------

-- KEYED ON completed_at, FALLING BACK TO updated_at, and both halves matter.
--
-- completed_at first, because workflow.runs carries a touch trigger: updated_at
-- means "last modified" and is rewritten by any later write to the row, so
-- retention keyed on it alone would be retention keyed on when somebody last
-- looked at the run. completed_at is set once, when the run finished, which is
-- the question retention is actually asking.
--
-- The coalesce is not defensive padding. A run CAN reach a terminal status with
-- a null completed_at -- found by doing it -- and keyed on completed_at alone
-- such a run and every task under it would be immortal, invisibly, forever.
-- updated_at is a sound lower bound on the age of a row nobody is touching.
--
-- The old note, kept because the reasoning still applies:
-- workflow.runs carries a touch trigger, so updated_at means "last modified"
-- and is rewritten by any later write to the row. Retention keyed on it would
-- be retention keyed on when somebody last looked at the run. completed_at is
-- set once, when the run finished, which is the question retention is actually
-- asking.
--
-- The foreign keys that make workflow.lifecycle_states load-bearing rather than
-- documentation. Added after both tables exist, and written drop-then-add so an
-- installation that already has them picks the change up -- the discipline
-- resources_status_check and tasks_kind_check are written with.
--
-- The FK is the whole guarantee, which is why there is no second check that the
-- per-table CHECK subsets agree with this table: a CHECK admitting a state the
-- vocabulary does not define is unreachable, because the write would fail on
-- the reference first. An earlier version of this parsed pg_get_constraintdef
-- with a regex to assert the agreement, which is a lot of clever code to
-- restate something the database already enforces.
-- AND THE INLINE CHECKS, WHICH A REPLAY CANNOT REACH.
--
-- `runs.status` and `tasks.status` carry a CHECK written inside `create table
-- if not exists`, so on a database that already has the table the CREATE is a
-- no-op and the OLD constraint survives -- still spelling the terminal state
-- `completed` on runs and `done` on tasks. The FKs above are written
-- drop-then-add for exactly this reason; the CHECKs they sit beside were not,
-- and the vocabulary change would therefore have landed on fresh installs only.
--
-- What that leaves on an upgraded database is a column nothing can be written
-- to at all: `succeeded` fails the stale CHECK, and `completed` fails the new
-- FK, so the first run to finish after the upgrade fails both ways. Caught by
-- dev/upgrade-converges.sh, which diffs a fresh install against a replayed
-- upgrade and reported the two constraints differing by one word:
--
--     <  ... ARRAY['running', 'succeeded', 'failed', 'cancelled']     fresh
--     >  ... ARRAY['running', 'completed', 'failed', 'cancelled']     upgraded
--
-- Restated here drop-then-add, the discipline tasks_kind_check and
-- resources_status_check already use, so an existing installation picks the
-- change up. The ROWS holding the old words are rewritten first, in
-- specs/migrations/0.1.2--0.1.3.sql -- a replay cannot express that either, and
-- adding the FK below to a table still holding a `completed` row would fail the
-- upgrade outright.
alter table workflow.runs  drop constraint if exists runs_status_check;
alter table workflow.runs  add  constraint runs_status_check
    check (status in ('running','succeeded','failed','cancelled'));
alter table workflow.tasks drop constraint if exists tasks_status_check;
alter table workflow.tasks add  constraint tasks_status_check
    check (status in ('pending','ready','running','waiting_external',
                      'succeeded','failed','cancelled'));

-- AND THE IDEMPOTENCY KEY, for the same reason and with the same shape.
--
-- `runs.external_id` carried `unique` inside `create table if not exists`,
-- which reaches fresh installs only -- so it is restated here, where a replay
-- reaches it. `if not exists` matches the CONSTRAINT's index by name on a
-- database that already has one, so this is a no-op there rather than a second
-- declaration of the same fact.
--
-- GLOBAL HERE AND PER-OWNER THERE. The engine standalone has no identities and
-- no owner column, so the strongest form it can state is one run per key;
-- integration-rbac.sql §(e) drops this and narrows it to (owner, key) once
-- `owner_id` exists. That is the same stub-and-shadow shape may_define() and
-- assert_run_access() use, applied to a constraint instead of a function, and
-- it is what stops the match scope and the constraint scope disagreeing --
-- a start_workflow that matches only the caller's own runs, over a key that is
-- unique installation-wide, turns another tenant's row from a returned id into
-- a unique violation, which is the same existence oracle plus a broken write.
create unique index if not exists runs_external_id_key
    on workflow.runs (external_id);

alter table workflow.runs  drop constraint if exists runs_status_fk;
alter table workflow.runs  add  constraint runs_status_fk
    foreign key (status) references workflow.lifecycle_states(state);
alter table workflow.tasks drop constraint if exists tasks_status_fk;
alter table workflow.tasks add  constraint tasks_status_fk
    foreign key (status) references workflow.lifecycle_states(state);

-- THE TERMINAL STATUSES COME FROM ONE PLACE NOW.
--
-- This was a load-time assertion that workflow.runs still admitted the word
-- this function hard-codes, and it existed because the collection used three
-- words for one idea: workflow.tasks said 'done', workflow.runs said
-- 'completed', agentic.runs said 'succeeded'. The comment it replaces recorded
-- the cost: a version of purge written against the wrong one "would have purged
-- NOTHING, silently, forever, and reported a clean zero every time it ran" --
-- and since both constraints are named runs_status_check, the wrong vocabulary
-- looked right.
--
-- The assertion was the correct response to a vocabulary that could drift. It
-- is not needed once the vocabulary cannot: `workflow.lifecycle_states` is the
-- one home for these words and every status column carries a foreign key into
-- it, so a state this function names either exists everywhere or fails at the
-- reference rather than at a purge that quietly deletes nothing.
--
-- `succeeded`, not `completed`, because a failed run also completed -- the pair
-- has to be mutually exclusive in MEANING, not only in the constraint. It is
-- also what Kubernetes, Argo and Step Functions call it, so it is the word a
-- reader arrives already expecting.

drop function if exists workflow.purge_completed(interval, int, int);
create or replace function workflow.purge_completed(
    p_older_than  interval default interval '30 days',
    p_batch       int      default 50,      -- RUNS per batch, not tasks
    p_max_batches int      default 1000)
returns table(batches int, runs_purged bigint, tasks_purged bigint,
              events_purged bigint, runs_skipped bigint) as $$
declare
    v_cut     timestamptz := now() - p_older_than;
    v_has_agentic boolean := to_regclass('agentic.runs') is not null;
    v_sql     text;
    v_ids     uuid[];
    v_n       bigint;
    v_batches int := 0;
    v_runs    bigint := 0;
    v_tasks   bigint := 0;
    v_events  bigint := 0;
    v_skipped bigint := 0;
begin
    if p_batch < 1 then
        raise exception 'p_batch must be positive';
    end if;

    loop
        exit when v_batches >= p_max_batches;

        -- ELIGIBILITY IS PER RUN, AND EVERY CLAUSE HERE IS A REFERENCE THAT
        -- WOULD OTHERWISE ABORT THE PURGE MID-BATCH. Found by running it: the
        -- first version deleted tasks and then failed on
        -- schedules_last_run_id_fkey, leaving the run half-purged.
        --
        -- THE AGENTIC CLAUSE WAS WRONG IN THREE WAYS AND RIGHT ABOUT THE
        -- OUTCOME, which took two attempts to see.
        --
        -- It excluded any run whose tasks had triggered ANY agent run, saying
        -- the foreign key would abort the delete. The key is
        -- `agentic.runs.workflow_task_id ... on delete set null`, so the delete
        -- looked safe and the clause looked like pure over-caution -- removing
        -- it was the obvious fix. Removing it fails:
        --
        --     new row for relation "runs" violates check constraint
        --     "scheduled_runs_name_their_task"
        --
        -- because agentic.runs also carries `check (trigger_kind <> ''scheduled''
        -- or workflow_task_id is not null)`. The FK nulls the column, the CHECK
        -- refuses the null, and the whole purge transaction aborts. A cascade
        -- action and a constraint on the same column disagree, and neither file
        -- can see the other.
        --
        -- So the guard is back, and now it is (a) narrow -- only a SCHEDULED
        -- agent run pins its workflow run, because only that row cannot lose
        -- the reference; an interactive run with a task id nulls out cleanly
        -- and is no longer excluded, which is most of what the old clause was
        -- wrongly holding back; (b) dynamic, because plpgsql plans a statement
        -- whole and the old `not v_has_agentic or not exists (...)` resolved
        -- agentic.runs at parse time -- raising `relation "agentic.runs" does
        -- not exist` on an engine-only install, which is exactly the
        -- deployment the guard was written to protect; and (c) counted, so a
        -- run held this way appears in runs_skipped rather than quietly never
        -- shrinking the table.
        --
        -- WHAT IS STILL TRUE AND STILL A GAP: a deployment whose workflows run
        -- scheduled agents accumulates runs that retention cannot touch. That
        -- is not fixable from this side -- it needs agentic to retire its own
        -- runs, or that CHECK to tolerate a purged reference. Named here rather
        -- than left as a mysteriously growing table.
        v_sql := 'select array_agg(r.id) from ('
              || ' select r.id from workflow.runs r'
              || ' where workflow.is_terminal(r.status)'
              || '   and coalesce(r.completed_at, r.updated_at) < $1'
              -- A schedule points at its most recent run. Deleting it would
              -- lose the schedule's own history.
              || '   and not exists (select 1 from workflow.schedules s'
              || '                    where s.last_run_id = r.id)'
              -- A sub_workflow parent task points at its child run.
              || '   and not exists (select 1 from workflow.tasks t'
              || '                    where t.child_run_id = r.id)'
              || case when v_has_agentic then
                    '   and not exists (select 1 from workflow.tasks t'
                 || '                     join agentic.runs ar on ar.workflow_task_id = t.id'
                 || '                    where t.run_id = r.id'
                 || '                      and ar.trigger_kind = ''scheduled'')'
                 else '' end
              || ' order by coalesce(r.completed_at, r.updated_at)'
              || ' limit $2) r';
        execute v_sql into v_ids using v_cut, p_batch;

        exit when v_ids is null;

        -- THE EVENT LOG, WHICH THE FIRST VERSION LEFT BEHIND ENTIRELY.
        --
        -- task_events.run_id is a plain uuid with no foreign key (§6), so
        -- nothing cascaded and nothing complained: purging a 1M-task backlog
        -- left four to six million orphaned event rows -- one per status
        -- transition -- and replaced a table that only grew with a table that
        -- grows faster. Deleted FIRST, by run_id, which idx_task_events_run
        -- already indexes; deleting after the tasks would leave no way to find
        -- them.
        delete from workflow.task_events e where e.run_id = any(v_ids);
        get diagnostics v_n = row_count;
        v_events := v_events + v_n;

        -- A WHOLE RUN AT A TIME. Tasks reference each other within a run --
        -- compensates_task_id and matrix_parent_id are both NO ACTION -- so a
        -- batch that split a run would block on its own siblings.
        delete from workflow.tasks t where t.run_id = any(v_ids);
        get diagnostics v_n = row_count;
        v_tasks := v_tasks + v_n;

        delete from workflow.runs r where r.id = any(v_ids);
        get diagnostics v_n = row_count;
        v_runs := v_runs + v_n;

        v_batches := v_batches + 1;
    end loop;

    -- WHAT WAS ELIGIBLE BY AGE AND HELD BACK BY A REFERENCE -- which means
    -- carrying the same clauses, inverted, including the agentic one.
    --
    -- Without them this counted every run the loop had not reached, so
    -- purge_completed(interval '30 days', 50, 1) over a 10,000-run backlog
    -- reported 9,950 "skipped" runs that were perfectly purgeable and simply
    -- beyond p_max_batches. An operator reading that concludes references are
    -- blocking retention when nothing is -- a number that is worse than no
    -- number, because it answers the question wrongly rather than not at all.
    v_sql := 'select count(*) from workflow.runs r'
          || ' where workflow.is_terminal(r.status)'
          || '   and coalesce(r.completed_at, r.updated_at) < $1'
          || '   and (exists (select 1 from workflow.schedules s where s.last_run_id = r.id)'
          || '     or exists (select 1 from workflow.tasks t where t.child_run_id = r.id)'
          || case when v_has_agentic then
                '     or exists (select 1 from workflow.tasks t'
             || '                  join agentic.runs ar on ar.workflow_task_id = t.id'
             || '                 where t.run_id = r.id'
             || '                   and ar.trigger_kind = ''scheduled'')'
             else '' end
          || ')';
    execute v_sql into v_skipped using v_cut;

    return query select v_batches, v_runs, v_tasks, v_events, v_skipped;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function workflow.purge_completed(interval, int, int) from public;

-- ------------------------------------------------------------
-- 2. The plan gate.
--
-- THE DEFECT THIS EXISTS FOR: idx_tasks_claimable did not match claim_task's
-- ORDER BY, so on a deep queue the planner abandoned it for a sequential scan
-- plus a sort of the entire ready set -- to return twenty rows. 78 claims/s
-- against 13,965 on the same data. No functional test could see it, because
-- the engine was correct throughout; only the plan was wrong.
--
-- So the assertion is about the PLAN, and it belongs in the database rather
-- than in a shell script, because the thing it protects is a property of the
-- schema.
--
-- IT REFUSES TO PASS ON A SHALLOW QUEUE, and that is the design. The defect is
-- invisible below a few thousand ready rows: the planner picks the index
-- whatever its shape, so a gate that ran on a fixture would have reported
-- health for the entire life of the bug. Inconclusive is an honest answer and
-- a false pass is not.
-- ------------------------------------------------------------
create or replace function workflow.check_hot_paths(p_min_depth int default 2000)
returns table(path text, verdict text, detail text) as $$
declare
    v_queue text;
    v_depth bigint;
    v_plan  jsonb;
    v_nodes text[];
begin
    -- run_after IS PART OF THE DEPTH, because it is part of the plan below.
    -- Counting bare `status = 'ready'` let a queue of 100,000 backing-off
    -- tasks satisfy the depth gate and then explain a query whose own filter
    -- excluded every one of them -- the gate would have passed on a plan for
    -- zero rows, which is the shallow-queue false pass wearing a different
    -- hat.
    select t.queue, count(*) into v_queue, v_depth
    from workflow.tasks t
    where t.status = 'ready' and t.run_after <= now()
    group by t.queue
    order by count(*) desc
    limit 1;

    if v_queue is null or v_depth < p_min_depth then
        return query select
            'claim'::text, 'inconclusive'::text,
            format('deepest queue has %s ready task(s), below the %s needed to '
                   'judge -- the planner picks the index at any shape when the '
                   'ready set is small, so a pass here would mean nothing',
                   coalesce(v_depth, 0), p_min_depth);
        return;
    end if;

    execute format(
        'explain (format json) select * from workflow.tasks
          where queue = %L and status = ''ready'' and run_after <= now()
          order by priority desc, created_at
          for update skip locked limit 20', v_queue)
    into v_plan;

    select array_agg(distinct x #>> '{}')
      into v_nodes
      from jsonb_path_query(v_plan, '$.**."Node Type"') x;

    -- A PLAN THIS GATE COULD NOT READ IS NOT A PASS.
    --
    -- With no rows out of jsonb_path_query, v_nodes is NULL, `'Seq Scan' =
    -- any(NULL)` is NULL rather than false, and the CASE fell through to 'ok'
    -- -- reporting `index-backed at depth N ()` with an empty node list. The
    -- one gate in this collection whose whole design is that a false pass is
    -- unacceptable issued one on its own parse failure, and it would do it
    -- silently on any PG release that renames the key.
    if v_nodes is null then
        return query select
            'claim'::text, 'inconclusive'::text,
            format('EXPLAIN returned a plan with no "Node Type" keys, so this gate '
                   'read nothing. Not a pass: %s', left(v_plan::text, 300));
        return;
    end if;

    return query select
        'claim'::text,
        case
            when 'Seq Scan' = any(v_nodes) then 'FAIL'
            when 'Sort'     = any(v_nodes) then 'FAIL'
            else 'ok'
        end,
        case
            when 'Seq Scan' = any(v_nodes) or 'Sort' = any(v_nodes) then
                format('claim_task is scanning and sorting %s ready tasks on queue %L '
                       'to return 20. The claim index no longer matches its ORDER BY '
                       '(priority desc, created_at). Plan: %s',
                       v_depth, v_queue, array_to_string(v_nodes, ' -> '))
            else
                format('index-backed at depth %s on queue %L (%s)',
                       v_depth, v_queue, array_to_string(v_nodes, ' -> '))
        end;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function workflow.check_hot_paths(int) from public;

-- ------------------------------------------------------------
-- 3. Work nobody can claim -- the failure with no error in it.
--
-- `rate_key` is a REFERENCE to a row in workflow.rate_limits, not a
-- declaration of one. try_consume_rate_limit does `update ... where key = $1`,
-- which matches nothing when the bucket does not exist and therefore returns
-- false -- every time, forever. The task sits in `ready`, no worker ever claims
-- it, no attempt is recorded, nothing retries, and the worker beside it reports
-- an empty queue. Measured on this collection's own embed fan-out: six children
-- in `ready`, no error, no dead task, no signal of any kind.
--
-- v_stuck_tasks cannot see it either: it reports tasks that are OLD, and a
-- freshly created unclaimable task is not old yet. It becomes visible there an
-- hour later, described as something else.
-- ------------------------------------------------------------
-- ONE PASS OVER tasks, NOT ONE PER CANDIDATE ROW.
--
-- The second branch asked `not exists (select 1 from workflow.tasks c where
-- c.queue = t.queue and c.claimed_at > now() - '10 minutes')` per candidate,
-- and there is no index on claimed_at -- so at the million-row depth this
-- whole section is written for, the diagnostic that exists to make a scale
-- failure visible would itself have scanned the table once per stuck task.
-- Hoisted into a CTE: the queues something has claimed from lately are one
-- aggregate, computed once.
create or replace view workflow.v_unclaimable as
with served as (
    select distinct t.queue
      from workflow.tasks t
     where t.claimed_at > now() - interval '10 minutes'
)
    select t.id, t.run_id, t.queue, t.step_key, t.rate_key,
           'rate_key names no bucket in workflow.rate_limits'::text as reason,
           format('insert into workflow.rate_limits (key, capacity, tokens, refill_rate) '
                  'values (%L, 20, 20, 1);', t.rate_key) as remedy,
           now() - t.created_at as waiting
    from workflow.tasks t
    where t.status = 'ready'
      and t.rate_key is not null
      and not exists (select 1 from workflow.rate_limits rl where rl.key = t.rate_key)
  union all
    -- SAYS ONLY WHAT IT CHECKED. This used to report "queue has no worker pool
    -- and no config", with a remedy asserting "no workflow.queue_config row for
    -- queue X" -- and the predicate consults queue_config nowhere. A queue that
    -- HAD a config row and had simply lost its workers got a diagnostic that
    -- was half false, pointing the reader at a table with nothing wrong in it.
    -- A view whose whole job is making an invisible failure legible cannot
    -- afford to name a cause it did not test; that is the same "reports success
    -- it did not verify" shape this file keeps correcting, inverted.
    --
    -- So the config half is now looked up rather than assumed, and the sentence
    -- changes with the answer.
    select t.id, t.run_id, t.queue, t.step_key, null::text,
           case when qc.queue is null
                then 'queue has no worker pool and no config'
                else 'queue is configured but nothing has claimed from it' end::text,
           case when qc.queue is null
                then format('no workflow.queue_config row for queue %L, and nothing has '
                            'claimed from it in 10 minutes -- start a worker on that '
                            'queue, or check the name the step spec wrote', t.queue)
                else format('workflow.queue_config has a row for queue %L, so the name is '
                            'right and no worker has claimed from it in 10 minutes -- '
                            'the pool is down or scaled to zero', t.queue) end,
           now() - t.created_at
    from workflow.tasks t
    left join workflow.queue_config qc on qc.queue = t.queue
    where t.status = 'ready'
      and t.run_after <= now()
      and t.created_at < now() - interval '10 minutes'
      and t.queue not in (select s.queue from served s);

-- ------------------------------------------------------------
-- 4. The backlog, as an operator needs it rather than as a count.
--
-- v_queue_depth answers "how many rows are in each state", which is the shape
-- a dashboard wants and not the shape a decision wants. The question behind
-- scaling a pool is "how long has the oldest thing been waiting", because that
-- is the number an SLO is written against -- depth alone cannot distinguish a
-- queue of 10,000 draining in seconds from a queue of 50 that nothing is
-- serving.
-- ------------------------------------------------------------
create or replace view workflow.v_backlog as
    select t.queue,
           count(*) filter (where t.status = 'ready' and t.run_after <= now())  as claimable,
           count(*) filter (where t.status = 'ready' and t.run_after >  now())  as backing_off,
           count(*) filter (where t.status = 'running')                          as running,
           count(*) filter (where t.status = 'waiting_external')                 as waiting_on_a_person,
           coalesce(max(now() - t.created_at) filter
               (where t.status = 'ready' and t.run_after <= now()),
               interval '0')                                                     as oldest_wait,
           count(distinct t.claimed_by) filter
               (where t.claimed_at > now() - interval '5 minutes')               as workers_seen,
           max(t.claimed_at)                                                     as last_claim
    from workflow.tasks t
    where t.status in ('ready','running','waiting_external')
    group by t.queue;

-- ------------------------------------------------------------
-- 5. Connection headroom -- the ceiling that arrives before throughput does.
--
-- Measured on a three-node cluster: thirty worker pods at four connections
-- each, against max_connections = 100, produced "sorry, too many clients
-- already" for everybody INCLUDING the operator -- the role was a superuser and
-- superuser_reserved_connections is 3, and thirty pods reconnecting in a loop
-- won the race for those three slots. The failure mode of connection
-- exhaustion is not that work stops; it is that nobody can get in to see why.
--
-- Which makes headroom something to watch BEFORE it is gone, and there was
-- nothing reporting it.
-- ------------------------------------------------------------
create or replace view workflow.v_capacity as
    select (select setting::int from pg_settings where name = 'max_connections')      as max_connections,
           (select setting::int from pg_settings where name = 'superuser_reserved_connections') as reserved,
           -- EVERY BACKEND, DELIBERATELY, AND THE ATTEMPT TO NARROW IT IS
           -- WORTH KEEPING AS A COMMENT.
           --
           -- pg_stat_activity also lists the checkpointer, the walwriter,
           -- autovacuum workers and pg_cron's launcher, none of which occupy a
           -- max_connections slot -- so this overstates usage by a handful.
           -- Filtering `backend_type = 'client backend'` looks like the fix
           -- and reports ZERO: pg_stat_activity nulls every column but a few
           -- for a role that owns no backends, and app_owner -- who owns this
           -- view and every operator reading it -- owns none. The narrowed
           -- version therefore said `in_use = 0, headroom = 97` on a live
           -- cluster, which is a headroom view that never warns. Caught by the
           -- assertion in dev/tests/workflow/12 rather than in production,
           -- which is the entire argument for that file.
           --
           -- Reading it properly needs pg_read_all_stats, and granting a
           -- predefined role to app_owner to improve an estimate by eight is a
           -- bad trade. Over-counting is the safe direction for a headroom
           -- warning: it fires early rather than late.
           (select count(*)::int from pg_stat_activity)                               as in_use,
           -- RESERVED SLOTS ARE NOT HEADROOM. The incident this view was
           -- written for is precisely the case where the last free slots were
           -- the superuser-reserved ones: an operator reading `headroom = 3`
           -- had zero usable connections and no way in. Floored at zero so an
           -- over-committed cluster reads as 0 rather than as a negative
           -- number nobody will parse at 3am.
           greatest(0,
             (select setting::int from pg_settings where name = 'max_connections')
             - (select setting::int from pg_settings where name = 'superuser_reserved_connections')
             - (select count(*)::int from pg_stat_activity))                          as headroom,
           (select count(distinct claimed_by)::int from workflow.tasks
             where claimed_at > now() - interval '5 minutes')                         as workers_seen,
           case when (select count(*)::float from pg_stat_activity)
                     / nullif((select setting::float from pg_settings
                                where name = 'max_connections')
                              - (select setting::float from pg_settings
                                  where name = 'superuser_reserved_connections'), 0) > 0.8
                then 'connection budget over 80% used -- a pool scaling on queue '
                     'depth can exhaust this long before it exhausts throughput'
                else null end                                                          as warning;

-- NOT GRANTED, and the grant that was here was a leak.
--
-- workflow.runs and workflow.tasks carry RLS (integration-rbac.sql §2), and a
-- view is owner-privileged unless it says otherwise -- so a read through one
-- of these evaluates the policies as app_owner, which owns the tables and
-- bypasses them. Granted to `authenticated`, v_unclaimable handed every
-- logged-in user the run_id, step_key and rate_key of every tenant's stuck
-- work, and v_backlog handed over per-queue depth and worker identity.
--
-- Every operator view that came before these three (v_queue_depth,
-- v_stuck_tasks, v_lease_violations, v_compensation_status) is deliberately
-- ungranted for exactly this reason: they are read as the owner, by an
-- operator, not through PostgREST. These three are the same kind of object and
-- now match. An operator-facing REST surface is a real thing to want and it
-- needs a `security_invoker` view or a definer function that filters -- not a
-- grant on a view that was never written to be seen by a caller.
--
-- check_hot_paths(int) loses its grant for the same reason: it is SECURITY
-- DEFINER and returns queue names and backlog depth.

-- ------------------------------------------------------------
-- 6. Synthetic load, so a scaling test is one call rather than a script.
--
-- Inserts directly rather than going through start_workflow, deliberately: a
-- scale probe is measuring the CLAIM path, and routing a million tasks through
-- the compiler would measure that instead. Owner-only for the same reason
-- register_step_function is -- it decides what the deployment can be made to do.
-- ------------------------------------------------------------
create or replace function workflow.seed_load(
    p_queue text, p_count int, p_definition text default '__scale_probe')
returns uuid as $$
declare v_def uuid; v_run uuid;
begin
    insert into workflow.definitions (name, spec)
    select p_definition, jsonb_build_object('steps', jsonb_build_array(jsonb_build_object(
               'key','w','kind','work','queue',p_queue)))
    where not exists (select 1 from workflow.definitions where name = p_definition);

    select id into v_def from workflow.definitions where name = p_definition;
    insert into workflow.runs (workflow_def_id, status) values (v_def, 'running')
    returning id into v_run;

    insert into workflow.tasks (run_id, step_key, kind, queue, status, pending_deps, input)
    select v_run, 'p' || g, 'work', p_queue, 'ready', 0, '{}'::jsonb
    from generate_series(1, p_count) g;

    return v_run;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function workflow.seed_load(text, int, text) from public;

-- ============================================================================
-- The plan graph: a definition, expanded along what it names.
--
-- Numbered sections stopped at 25 and this is not one -- like the scale section
-- above it, it is a capability rather than a correction, and the numbers in
-- this file record the order failures were found in.
--
-- `definitions.spec` is a DAG of steps and nothing else. What a step REACHES
-- is spread across four schemas: the agent an `agent:` step calls and that
-- agent's servers and tools (agentic), the corpus a `p8ql:` step ranks and the
-- space it ranks in (aiq), the function a `sql:` step is allow-listed to run
-- and the queue and rate key that decide whether it is ever claimed (here).
-- Every one of those reaches is a place a plan can be wrong in a way that
-- compiles, registers and starts -- validate_spec checks the graph's SHAPE and
-- has nothing to say about whether the things it names exist.
--
-- This section is the join written down once. `plan_catalog()` collects what
-- exists, p8_plan_graph (the Rust half, plan_graph.rs) expands the spec against
-- it, and `plan_defects()` is the audit shape: the reaches that do not resolve,
-- each with the consequence of leaving it alone.
--
-- Two properties are deliberate and worth stating, because both are the kind
-- that erodes:
--
--   The catalog is an ARGUMENT, not a fetch. p8_plan_graph makes no query, so
--   the graph a caller gets is built from exactly the rows that caller could
--   see -- RLS, taken once by Postgres in these views, rather than a second
--   authorization model inside a graph builder.
--
--   Every call into the extension is DYNAMIC. `percolate_parser` is a separate
--   extension and this schema installs without it (define_yaml has said so
--   since §12). plpgsql plans a whole statement before any guard inside it
--   runs, so `if to_regprocedure(...) is not null then select p8_plan_graph(...)`
--   raises at first call on a deployment that does not have it -- the guard has
--   to sit outside a statement the planner never resolves. EXECUTE is what
--   makes the check mean what it reads as.
-- ============================================================================

-- What this deployment HAS, in the shape the graph builder reads: an object
-- per section, keyed by name. A section that is missing entirely means the
-- subsystem is not installed, and the builder treats that as "cannot judge"
-- rather than "everything you named is missing" -- the difference between a
-- plan graph on an engine-only install being empty of agents and being 40
-- errors about them.
create or replace function workflow.plan_catalog()
returns jsonb
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
    v_cat   jsonb;
    v_facet jsonb;
begin
    v_cat := jsonb_build_object(
        -- WITH THE COMMENT, which is the same text a bound tool carries into
        -- an LLM's context (§24) -- so what a `sql:` step DOES is answerable
        -- from the plan instead of from the source. The registry's own
        -- description first, since somebody wrote it for exactly this, and the
        -- function's COMMENT behind it.
        -- SIGNATURE, NOT JUST NAME AND TYPES. Three things come off pg_proc
        -- that the registry does not hold and a reader keeps having to guess:
        --
        --   `params`      the argument NAMES. A plan showing `args: [..., '8']`
        --                 against `arg_types: [text, text]` tells you the
        --                 second argument is a string and not that it is a
        --                 LIMIT. pg_get_function_arguments knows.
        --   `returns`     what comes back, so a step's output has a declared
        --                 shape even before anything has run.
        --   `mutates`     provolatile. A STABLE or IMMUTABLE function CANNOT
        --                 write -- Postgres enforces that, so it is a fact
        --                 rather than a promise -- which is what lets the graph
        --                 tell a step that changes the database from a step
        --                 that only asks it something, and therefore what lets
        --                 it spot a read whose result nothing consumes.
        'functions', coalesce((
            select jsonb_object_agg(f.name, jsonb_strip_nulls(jsonb_build_object(
                'fn', f.fn, 'arg_types', to_jsonb(f.arg_types),
                'description', coalesce(f.description,
                    obj_description(p.oid, 'pg_proc')),
                'params', pg_get_function_arguments(p.oid),
                'returns', pg_get_function_result(p.oid),
                'mutates', p.provolatile = 'v',
                'timeout_ms', f.timeout_ms)))
              from workflow.step_functions f
              left join pg_proc p on p.oid = to_regprocedure(
                  f.fn || '(' || array_to_string(f.arg_types, ',') || ')')),
            '{}'::jsonb),
        'queues', coalesce((
            select jsonb_agg(queue order by queue) from workflow.queue_config), '[]'::jsonb),
        'rate_keys', coalesce((
            select jsonb_agg(key order by key) from workflow.rate_limits), '[]'::jsonb),
        -- Names, not (name, version) pairs: a `workflow:` step names a
        -- workflow and start_workflow resolves the version, so a graph that
        -- demanded the version would report a defect the engine does not have.
        'workflows', coalesce((
            select jsonb_agg(distinct name) from workflow.definitions
             where deleted_at is null), '[]'::jsonb),
        -- WHAT A STATEMENT MAY NAME. With `sql: "select ..."` there is no
        -- registered function to check, so the plan checks the relations
        -- instead -- a better question, since naming a table that does not
        -- exist is the mistake people actually make.
        --
        -- Scoped to what the CALLER can select, like every other section here,
        -- and to schemas that are not the server's own furniture. An empty list
        -- means "cannot judge" to the graph builder, exactly as an absent
        -- section does elsewhere, so a caller with no table privileges gets a
        -- plan with no relation warnings rather than a plan that is all of them.
        --
        -- Read off pg_class BY OID, not through information_schema by name.
        -- has_table_privilege('cron.job', 'select') has to resolve the name
        -- first, and resolving it needs USAGE on the schema -- so the name form
        -- RAISES `permission denied for schema cron` instead of answering
        -- false, and one unreachable extension schema took the whole catalog
        -- with it. Found by running the plan-graph test on a database with
        -- pg_cron installed.
        'relations', coalesce((
            select jsonb_agg(n.nspname || '.' || c.relname order by n.nspname, c.relname)
              from pg_class c
              join pg_namespace n on n.oid = c.relnamespace
             where c.relkind in ('r', 'p', 'v', 'm', 'f')
               and n.nspname not in ('pg_catalog', 'information_schema')
               and n.nspname not like 'pg\\_%'
               and has_schema_privilege(n.oid, 'usage')
               and has_table_privilege(c.oid, 'select')), '[]'::jsonb));

    if to_regprocedure('agentic.plan_facet()') is not null then
        execute 'select agentic.plan_facet()' into v_facet;
        v_cat := v_cat || coalesce(v_facet, '{}'::jsonb);
    end if;
    if to_regprocedure('aiq.plan_facet()') is not null then
        execute 'select aiq.plan_facet()' into v_facet;
        v_cat := v_cat || coalesce(v_facet, '{}'::jsonb);
    end if;
    return v_cat;
end;
$$;

-- The graph itself. `p_version` null means the current version, which is what
-- an author asking about "the triage workflow" means -- and a run started
-- today would use.
create or replace function workflow.plan_graph(p_name text, p_version int default null)
returns jsonb
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
    v_spec jsonb;
    v_ver  int;
    v_out  jsonb;
begin
    if to_regprocedure('p8_plan_graph(jsonb,jsonb)') is null then
        raise exception
            'workflow.plan_graph needs the percolate extension (p8_plan_graph). '
            'The catalog half works without it: select workflow.plan_catalog().';
    end if;

    select d.spec, d.version into v_spec, v_ver
      from workflow.definitions d
     where d.name = p_name
       and (p_version is null or d.version = p_version)
       and d.deleted_at is null
     order by d.version desc
     limit 1;

    if v_spec is null then
        raise exception 'no workflow definition named % %', p_name,
            case when p_version is null then '(any version)'
                 else 'at version ' || p_version end;
    end if;

    -- The name and version ride INTO the spec so the graph's root node is
    -- labelled with what it is. The spec itself carries neither -- they are
    -- columns on the definition, and the builder should not have to be told
    -- where a workflow's identity lives.
    execute 'select p8_plan_graph($1, $2)'
       into v_out
      using jsonb_build_object('name', p_name, 'version', v_ver) || v_spec,
            workflow.plan_catalog();
    return v_out;
end;
$$;

-- The same expansion, read rather than traversed.
--
-- plan_graph answers "what does this reach, and does it resolve" -- the right
-- shape for a checker and the wrong one for a person, who wants the pipeline:
-- step, then what that step says and does, with the agent's prompt, the
-- corpus's columns and the tool's description sitting where they are USED
-- rather than in a node list to be joined by eye.
--
-- A projection of the graph, never a second resolver. Two views that resolve
-- separately are two answers to the only question that matters.
create or replace function workflow.plan_document(p_name text, p_version int default null)
returns jsonb
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
    v_spec jsonb;
    v_ver  int;
    v_out  jsonb;
begin
    if to_regprocedure('p8_plan_document(jsonb,jsonb)') is null then
        raise exception
            'workflow.plan_document needs the percolate extension (p8_plan_document). '
            'The catalog half works without it: select workflow.plan_catalog().';
    end if;

    select d.spec, d.version into v_spec, v_ver
      from workflow.definitions d
     where d.name = p_name
       and (p_version is null or d.version = p_version)
       and d.deleted_at is null
     order by d.version desc
     limit 1;

    if v_spec is null then
        raise exception 'no workflow definition named % %', p_name,
            case when p_version is null then '(any version)'
                 else 'at version ' || p_version end;
    end if;

    execute 'select p8_plan_document($1, $2)'
       into v_out
      using jsonb_build_object('name', p_name, 'version', v_ver) || v_spec,
            workflow.plan_catalog();
    return v_out;
end;
$$;

-- The audit shape. A view would have been the natural spelling and cannot be
-- one: a view referencing p8_plan_graph fails to CREATE where the parser
-- extension is absent, which would make an optional dependency a hard one at
-- load time.
--
-- `p_name` null walks every current definition on one catalog -- which is the
-- form a deployment gate wants, and the reason the catalog is computed once
-- here rather than per row.
create or replace function workflow.plan_defects(p_name text default null)
returns table (
    workflow    text,
    version     int,
    severity    text,
    code        text,
    node        text,
    message     text,
    consequence text
)
language plpgsql
stable
set search_path = pg_catalog, public
as $$
declare
    v_cat  jsonb;
    v_def  record;
    v_out  jsonb;
begin
    if to_regprocedure('p8_plan_graph(jsonb,jsonb)') is null then
        return;
    end if;
    v_cat := workflow.plan_catalog();

    for v_def in
        select distinct on (d.name) d.name, d.version, d.spec
          from workflow.definitions d
         where d.deleted_at is null
           and (p_name is null or d.name = p_name)
         order by d.name, d.version desc
    loop
        execute 'select p8_plan_graph($1, $2)'
           into v_out
          using jsonb_build_object('name', v_def.name, 'version', v_def.version) || v_def.spec,
                v_cat;
        return query
        select v_def.name, v_def.version,
               x->>'severity', x->>'code', x->>'node', x->>'message', x->>'consequence'
          from jsonb_array_elements(coalesce(v_out->'defects', '[]'::jsonb)) x;
    end loop;
end;
$$;

-- ============================================================================
-- PROBING: the cheap half of every step, actually executed.
--
-- plan_graph reads. This RUNS things -- the parts that cost nothing and prove
-- something, which is a different question and the one a reader actually has
-- before they start a pipeline they did not write.
--
--   `explain` on a statement       does it parse, and which relations does the
--                                  PLANNER say it touches -- which retires the
--                                  regex the graph uses to guess
--   a temp view on a read          the exact output column names and types,
--                                  without running the query
--   to_regprocedure on a function  it exists at that signature, and pg_proc
--                                  says whether it can write
--   a row lookup for an agent      it exists, and its servers have been synced
--
-- Nothing here executes a step. EXPLAIN without ANALYZE plans and discards, and
-- CREATE VIEW validates without running -- so probing a pipeline costs no SEC
-- request, no model call and no row.
--
-- WHAT IT CANNOT PROBE IS REPORTED AS `skipped`, NEVER AS `ok`. The worker's
-- environment, an external url, whether a credential resolves: all of those
-- belong to a process this database deliberately cannot see, and a probe that
-- returned ok for them would be the false pass this collection keeps removing.
--
-- Templates are substituted with `null` before probing, because `{{run.cik}}`
-- is not SQL. That is enough for parsing, relations and column types, and it is
-- honestly less than a real run: a query whose WHERE resolves to null plans the
-- same and returns nothing.
-- ============================================================================
create or replace function workflow.plan_probe(p_name text, p_version int default null)
returns table (step text, probe text, verdict text, detail text)
language plpgsql
volatile
set search_path = pg_catalog, public
as $$
declare
    v_spec  jsonb;
    v_step  jsonb;
    v_in    jsonb;
    v_kind  text;
    v_key   text;
    v_stmt  text;
    v_plan  jsonb;
    v_rel   text[];
    v_cols  jsonb;
    v_fn    text;
    v_oid   oid;
    v_env   text[];
begin
    select d.spec into v_spec
      from workflow.definitions d
     where d.name = p_name
       and (p_version is null or d.version = p_version)
       and d.deleted_at is null
     order by d.version desc
     limit 1;

    if v_spec is null then
        raise exception 'no workflow definition named %', p_name;
    end if;

    for v_step in select * from jsonb_array_elements(v_spec->'steps') loop
        v_key  := v_step->>'key';
        v_kind := v_step->>'kind';
        v_in   := coalesce(v_step->'input', '{}'::jsonb);

        -- Every {{env.X}} the step names. The database cannot resolve one --
        -- that is the worker's environment, deliberately -- so this is a list
        -- to check by hand, reported as skipped rather than passed.
        select array_agg(distinct m[1]) into v_env
          from regexp_matches(v_in::text, '\{\{env\.([A-Za-z0-9_]+)\}\}', 'g') m;
        if v_env is not null then
            step := v_key; probe := 'env'; verdict := 'skipped';
            detail := 'needs ' || array_to_string(v_env, ', ') ||
                      ' from the worker''s environment, which this database cannot read';
            return next;
        end if;

        if v_kind = 'sql' and (v_in ? 'statement') then
            -- A template is not SQL. Null is enough to plan with.
            v_stmt := regexp_replace(v_in->>'statement', '\{\{[^}]*\}\}', 'null', 'g');

            begin
                if coalesce((v_in->>'write')::boolean, false) then
                    -- THE SAME WRAPPING execute_as_viewer USES, from the same
                    -- home. EXPLAIN plans the first statement of the string it
                    -- is given and does not stop plpgsql running the rest, so
                    -- an unwrapped `explain (format json) ' || v_stmt` ran
                    -- whatever a workflow author put after the semicolon --
                    -- here, as the caller, from a function granted to
                    -- `authenticated` whose own comment promises it runs no
                    -- step.
                    execute format('explain (format json) %s',
                                   workflow.one_write_statement(v_stmt)) into v_plan;
                else
                    execute format(
                        'explain (format json) select * from (%s) t', v_stmt) into v_plan;
                end if;
                step := v_key; probe := 'parses'; verdict := 'ok';
                detail := 'the planner accepted it';
                return next;

                select array_agg(distinct x #>> '{}') into v_rel
                  from jsonb_path_query(v_plan, '$.**."Relation Name"') x;
                step := v_key; probe := 'relations';
                verdict := case when v_rel is null then 'skipped' else 'ok' end;
                detail := coalesce(
                    'reads ' || array_to_string(v_rel, ', '),
                    'the plan names no relation -- a values list, a function, or a '
                    'constant expression');
                return next;
            exception when others then
                step := v_key; probe := 'parses'; verdict := 'fail';
                detail := sqlerrm;
                return next;
                v_stmt := null;    -- a statement that does not parse has no shape
            end;

            -- The shape, without running the query. A view is validated and
            -- planned at creation and executes nothing.
            --
            -- Skipped entirely when the parse failed: reporting `returns:
            -- skipped -- relation does not exist` after `parses: fail --
            -- relation does not exist` says the same thing twice and makes the
            -- one line that matters harder to find.
            if v_stmt is not null and not coalesce((v_in->>'write')::boolean, false) then
                begin
                    execute format('create temp view _p8_probe as %s', v_stmt);
                    select jsonb_object_agg(column_name, data_type) into v_cols
                      from information_schema.columns
                     where table_name = '_p8_probe';
                    execute 'drop view _p8_probe';
                    step := v_key; probe := 'returns'; verdict := 'ok';
                    detail := coalesce(v_cols::text, '(no columns)');
                    return next;
                exception when others then
                    begin execute 'drop view if exists _p8_probe'; exception when others then null; end;
                    step := v_key; probe := 'returns'; verdict := 'skipped';
                    detail := 'could not describe the result: ' || sqlerrm;
                    return next;
                end;
            end if;

        elsif v_kind = 'sql' then
            v_fn := v_in->>'function';
            select f.fn || '(' || array_to_string(f.arg_types, ',') || ')'
              into v_stmt from workflow.step_functions f where f.name = v_fn;
            if v_stmt is null then
                step := v_key; probe := 'function'; verdict := 'fail';
                detail := format('%L is not registered', v_fn);
                return next;
            else
                v_oid := to_regprocedure(v_stmt);

                -- THE STEP'S ARGUMENTS AGAINST THE FUNCTION'S. The registry
                -- knows the signature and the step carries a list, and nothing
                -- compared the two until dispatch -- where the failure reads
                -- `function f(text) does not exist`, which sounds like a
                -- missing function rather than a step passing one argument to
                -- something that takes two.
                if v_oid is not null then
                    declare
                        v_want int := coalesce(array_length(
                            (select f.arg_types from workflow.step_functions f
                              where f.name = v_fn), 1), 0);
                        v_got  int := coalesce(jsonb_array_length(v_in->'args'), 0);
                    begin
                        if v_want <> v_got then
                            step := v_key; probe := 'arity'; verdict := 'fail';
                            detail := format(
                                '%L is registered with %s argument(s) and this step passes %s',
                                v_fn, v_want, v_got);
                            return next;
                        end if;
                    end;
                end if;

                step := v_key; probe := 'function';
                verdict := case when v_oid is null then 'fail' else 'ok' end;
                detail := case when v_oid is null
                    then format('registered as %s, which does not exist at that signature', v_stmt)
                    else format('%s returns %s%s', pg_get_function_arguments(v_oid),
                                pg_get_function_result(v_oid),
                                case when (select provolatile from pg_proc where oid = v_oid) = 'v'
                                     then ' (may write)' else ' (read-only)' end) end;
                return next;
            end if;

        elsif v_kind = 'http_call' and (v_in->>'url') like '%P8_AGENT_URL%' then
            if to_regclass('agentic.agents') is null then
                step := v_key; probe := 'agent'; verdict := 'skipped';
                detail := 'agentic is not installed on this deployment';
                return next;
            else
                execute format(
                    'select case when exists (select 1 from agentic.agents where name = %L)
                          then ''ok'' else ''fail'' end', v_in#>>'{body,model}')
                into verdict;
                step := v_key; probe := 'agent';
                detail := format('agent %L%s', v_in#>>'{body,model}',
                                 case when verdict = 'ok' then ' exists'
                                      else ' has no row in agentic.agents' end);
                return next;
            end if;

        elsif v_kind = 'http_call' then
            step := v_key; probe := 'endpoint'; verdict := 'skipped';
            detail := format('%s -- an outbound call is the worker''s to make, so nothing '
                             'here can tell you it answers', v_in->>'url');
            return next;

        elsif v_kind = 'sub_workflow' then
            step := v_key; probe := 'workflow';
            verdict := case when exists (
                select 1 from workflow.definitions d
                 where d.name = coalesce(v_in->>'workflow', v_in->>'name')
                   and d.deleted_at is null) then 'ok' else 'fail' end;
            detail := format('runs %L', coalesce(v_in->>'workflow', v_in->>'name'));
            return next;
        end if;
    end loop;
end;
$$;

-- ============================================================================
-- WHAT THE LAST RUN ACTUALLY DID, beside the plan that described it.
--
-- The gap a plan cannot close on its own: a step's declared output is `jsonb`,
-- and an author writing `{{steps.land.result.cik}}` has no way to know whether
-- `cik` is a key of it. One execution answers that, and the join is already
-- there -- workflow.tasks is keyed (run_id, step_key), which is why every step
-- node carries step_key.
--
-- Shapes, not values. A result's keys and their types are what a next step is
-- written against; the values are one select away and would make this
-- unreadable for a fan-out that returned four thousand rows.
-- ============================================================================
create or replace function workflow.plan_status(p_name text, p_run_id uuid default null)
returns table (
    step     text,
    status   text,
    attempts int,
    took     interval,
    returned jsonb
)
language sql
stable
set search_path = pg_catalog, public
as $$
    with r as (
        -- Runs point at a DEFINITION ID, not at a name: publishing v2 does not
        -- retarget a run that started under v1. So the newest run of "this
        -- workflow" is the newest run of any of its versions, which is what
        -- somebody asking about a name means.
        select coalesce(p_run_id, (
            select r.id from workflow.runs r
              join workflow.definitions d on d.id = r.workflow_def_id
             where d.name = p_name
             order by r.created_at desc limit 1)) as id
    )
    select t.step_key,
           t.status,
           t.attempts,
           t.completed_at - t.claimed_at,
           case jsonb_typeof(t.output->'result')
                -- An array of rows: how many, and the shape of one of them,
                -- which is what a template against it has to match.
                when 'array' then jsonb_build_object(
                    'rows', jsonb_array_length(t.output->'result'),
                    'of', case when jsonb_array_length(t.output->'result') = 0 then null
                          else (select jsonb_object_agg(k, jsonb_typeof(v))
                                  from jsonb_each(t.output#>'{result,0}') e(k, v)) end)
                when 'object' then (select jsonb_object_agg(k, jsonb_typeof(v))
                                      from jsonb_each(t.output->'result') e(k, v))
                when 'null' then null
                else to_jsonb(jsonb_typeof(t.output->'result'))
           end
      from workflow.tasks t, r
     where t.run_id = r.id
     order by t.created_at, t.step_key;
$$;

comment on function workflow.plan_probe(text, int) is
$c$Execute the cheap half of every step and report what it proves.
EXPLAIN for a statement (does it parse, which relations does the planner name),
a temp view for its result columns, a catalog lookup for a registered function
or an agent. Runs no step: anything needing the worker's environment or an
outbound call is reported skipped, never ok.$c$;

comment on function workflow.plan_status(text, uuid) is
$c$What the last run of this workflow actually did, per step.
Status, attempts, duration, and the SHAPE of what each step returned -- keys and
their types, or a row count -- which is the thing a plan cannot know and the
next step has to be written against.$c$;

-- Read surfaces over configuration only -- no run, no task, no per-tenant row
-- passes through any of them, which is why these three are granted where every
-- operator view in §22d is not.
grant execute on function workflow.plan_catalog() to authenticated;
grant execute on function workflow.plan_graph(text, int) to authenticated;
grant execute on function workflow.plan_document(text, int) to authenticated;
grant execute on function workflow.plan_defects(text) to authenticated;
grant execute on function workflow.plan_probe(text, int) to authenticated;
-- plan_status reads workflow.tasks, which is RLS-enabled and per-tenant, and
-- this function is SECURITY INVOKER (the default) precisely so that stays true:
-- a caller sees the runs their policies admit, and nothing else.
grant execute on function workflow.plan_status(text, uuid) to authenticated;

comment on function workflow.plan_document(text, int) is
    'A stored definition read as a pipeline: every step in order, carrying what '
    'it does and the expanded entity it does it to -- the agent and its prompt, '
    'the corpus and its columns, the tool and its description. A projection of '
    'workflow.plan_graph().';

comment on function workflow.plan_graph(text, int) is
    'A stored definition expanded along the entities it names -- agents, tool '
    'servers, tools, corpora, spaces, models, functions, queues, rate keys -- '
    'with every reach that does not resolve reported as a defect.';
