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
