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

-- The authorization check, and then the cascade -- which is the unchecked form
-- below, called rather than repeated. The first version inlined the same four
-- statements here, so the cascade existed twice and the tree walk reached the
-- copy: a fix to how cancellation propagates would have landed on the parent
-- run and not on any of its children, which is the worst available shape for
-- that particular bug. schema.sql §20d states the rule.
create or replace function workflow.cancel_run(p_run_id uuid) returns void as $$
begin
    perform workflow.assert_run_access(p_run_id, 'cancel');
    perform workflow.cancel_run_unchecked(p_run_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The recursive/internal form: no authorization, never granted to any user
-- role, reachable only from cancel_run() above (same owner) and from the
-- engine itself. Split out rather than adding a "skip the check" boolean
-- parameter, because a caller-supplied flag that disables authorization is
-- precisely the pattern this collection keeps finding to be exploitable.
--
-- Child runs are therefore cancelled by the same authority as their parent,
-- not re-checked against the caller: a child run is frequently system-owned
-- (no owner_id), and re-running the check would fail on exactly the runs a
-- legitimate parent cancellation most needs to reach. cancel_run's check is
-- the authorization boundary for the whole tree.
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
declare r record;
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
    -- The output is merged into runs.context for the same reason complete_task
    -- merges it: {{steps.<id>.…}} reads from there, so a person's decision that
    -- stops here is a decision no downstream step can act on. Kept in step with
    -- schema.sql's copy through the shared workflow.merge_step_context(), which
    -- is the point of that function existing -- the previous shape had the
    -- merge written once, at one of the three sites that mark a task done.
    for r in
        with signalled as (
            update workflow.tasks
            set status = 'done', output = p_payload, completed_at = clock_timestamp()
            where run_id = p_run_id and wait_signal = p_signal
              and status = 'waiting_external'
            returning id, output)
        select id, output from signalled
    loop
        perform workflow.merge_step_context(r.id, r.output);
    end loop;
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

    -- Batched children (schema.sql §20j) hold `items`, not `item`, and this
    -- returns the ROW SET -- so they are flattened back to it. Kept in step
    -- with the body this overrides; a checked copy that answers a different
    -- question is worse than no copy.
    --
    -- Which is exactly what it became: the ordering defect this fixes
    -- (`fan[10]` sorting before `fan[2]` once created_at ties, as it always
    -- does inside one expansion) lived in BOTH bodies, and the copy is the one
    -- that actually runs wherever user-rbac is installed. workflow.child_ordinal
    -- is in schema.sql so the two cannot drift again on this point.
    return (select coalesce(jsonb_agg(r order by t.created_at,
                                      workflow.child_ordinal(t.step_key),
                                      t.step_key, r_ord),
                            '[]'::jsonb)
            from workflow.tasks t
            cross join lateral jsonb_array_elements(
                case when t.input ? 'items' then t.input->'items'
                     else jsonb_build_array(t.input->'item') end)
                with ordinality x(r, r_ord)
            where t.matrix_parent_id = p_task_id);
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
                'items', t.input->'items',
                'status', t.status, 'output', t.output)
            order by t.created_at, workflow.child_ordinal(t.step_key),
                     t.step_key), '[]'::jsonb)
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

-- ------------------------------------------------------------
-- 6. The PUBLIC default, revoked -- because granting is not the same as
--    scoping, and this collection had only ever done the first one.
--
-- EXECUTE on a new function is granted to PUBLIC by Postgres unless you take
-- it away. Every `grant execute ... to worker` in these schemas therefore read
-- as "worker may call this" and MEANT "worker and everybody else may call
-- this" -- the grant materialised an ACL that still carried `=X/app_owner`.
-- Nobody was misreading the code; the code was missing a line.
--
-- Found by enumerating it rather than by reading: every SECURITY DEFINER
-- function reachable by `web_anon`, `authenticated` or `api_viewer`, checked
-- against what each one is FOR. Eleven engine internals were reachable by any
-- logged-in user over PostgREST, and one of them leaked:
--
--     POST /rpc/run_meta {"p_run_id": "<someone else's run>"}
--     -> {"$external_id": "private-external-id", "$trace_id": ..., "$definition": ...}
--
-- `run_meta` is the one run-scoped reader without the guard its siblings have.
-- `matrix_rows` and `matrix_outputs` are authorized against the run precisely
-- so a caller holding an id from elsewhere gets nothing, and there is a test
-- that says so; run_meta was written later, for the dispatcher, and never
-- joined that argument. Rather than add a check it does not need -- it is
-- called during dispatch, where there is no end-user identity to check
-- against -- it stops being reachable by an end user at all, which is the
-- exemption workflow-engine's own rule already grants worker-facing
-- functions: "their authorization IS the grant."
-- ------------------------------------------------------------
revoke execute on function workflow.run_meta(uuid) from public;
revoke execute on function workflow.check_run_completion(uuid) from public;
revoke execute on function workflow.autorun_sql_steps() from public;
revoke execute on function workflow.normalize_output(uuid, jsonb) from public;
revoke execute on function workflow.matrix_gate_passes(uuid) from public;
revoke execute on function workflow.encoding_drift() from public;
revoke execute on function workflow.execute_sql_step(uuid) from public;
revoke execute on function workflow.drain_sql_steps(uuid, int) from public;
revoke execute on function workflow.tick(timestamptz) from public;
-- workflow.register_artifact() is the eleventh and it is NOT revoked here:
-- content loads after the engine, so naming it in this file fails the install
-- with "function does not exist". The revoke belongs beside its definition in
-- world-model-ingestion/integration.sql, which is being rewritten as this
-- lands; one line, and the enumeration below will report it until it is
-- written.

-- The explicit grants above stand: worker keeps what it claims and completes,
-- scheduler keeps the clock. `authenticated` keeps nothing here -- a user
-- reaches its own runs through workflow.runs_api and the entry points that
-- authorize against the run.
grant execute on function workflow.encoding_drift() to worker;
