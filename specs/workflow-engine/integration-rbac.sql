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
-- A RUN GAINS AN ORG AND A SCOPE, not just an owner.
--
-- Ownership alone made a run unshareable: `owner_id = current_user_id()` has
-- no way to say "my colleague may watch this", so the only route to a run
-- somebody else started was a deployment-wide workflow_runs/select, which is
-- permission to read EVERY tenant's runs. The two available answers were
-- nobody and everybody.
select rbac.add_scope_columns('workflow.runs');
select rbac.add_scope_policy ('workflow.runs', 'workflow_runs');

-- AND SO DOES THE REGISTRY, in this section rather than beside its owner
-- trigger in (e), because `definitions_api` in (c2) below publishes these
-- three columns and a view cannot select a column that does not exist yet.
-- The same split `workflow.runs` has: columns and policy here, the trigger
-- that fills owner_id with the rest of the write path.
-- AND SO DOES THE REGISTRY. `workflow.definitions` carried no owner_id, no
-- org_id and no RLS, which is the root spec.md §17 names: there was nothing on
-- the row for a check to read, so no check could be written. Measured on
-- 2026-09-12 before this landed -- a plain `member` who owns nothing called
-- start_workflow() on a definition somebody else wrote and it succeeded --
-- and that included the per-user `source_<id>` workflows save_api_source()
-- compiles from a private data source.
--
-- BACKFILLED 'public', NOT 'private', and spec.md §17(d) said 'private' in a
-- sentence that contradicted the two either side of it. The intent it states
-- twice is that an upgraded database keeps working exactly as it does now and
-- the change is opt-in per definition; 'private' over a table whose rows have
-- no owner_id yet satisfies rbac.may_read() for nobody at all, so every
-- existing workflow would have become unstartable by everyone -- which §17(d)
-- itself calls "a worse failure than the gap it closes". 'public' is the same
-- answer agentic.agents/skills/tool_servers/plugins took, and for the same
-- reason: the policy being replaced was effectively `using (true)`.
--
-- The column DEFAULT stays 'private' (add_scope_columns sets it), so the
-- backfill is about rows that already exist and new definitions are private to
-- their author. That asymmetry is the whole of the fix.
select rbac.add_scope_columns('workflow.definitions', 'public');
select rbac.add_scope_policy ('workflow.definitions', 'workflow_definitions');

alter table workflow.tasks enable row level security;

-- Tasks inherit their run's visibility rather than restating the rule -- one
-- place to change it, and a task has no owner of its own.
drop policy if exists tasks_via_run on workflow.tasks;
create policy tasks_via_run on workflow.tasks for select
  using (exists (select 1 from workflow.runs r where r.id = workflow.tasks.run_id));

-- Reads go through views owned by api_viewer, NOT the table owner -- the
-- ownership split user-rbac/roles.sql §2 exists for. A view owned by the
-- table owner bypasses RLS and returns every row to every caller.
-- WHO STARTED THE RUN, NOT ONLY WHOSE IT IS (REM-171). A person's agent starts runs with a narrowed credential,
-- and execute_for minted only the owner's id, so every step of such a run ran as the person: a human-only
-- capability passed, the credential's scopes did not narrow, and revoking the key did not stop the next step.
-- The run keeps its starter from the verified claims and execute_for carries it into each step. Null on a run
-- from before this, and on a system run: those keep the reach they always had. Added here, above runs_api,
-- because the view publishes started_actor; set_run_owner (section e) fills both.
alter table workflow.runs add column if not exists started_actor text
    check (started_actor in ('person', 'agent', 'platform'));
alter table workflow.runs add column if not exists started_credential_id uuid;

create or replace view workflow.runs_api as
-- The scope columns are APPENDED rather than slotted in beside owner_id, and
-- the position is forced rather than chosen: `create or replace view` may only
-- ADD columns at the end. Inserting one in the middle is
-- `ERROR: cannot change name of view column "status" to "org_id"`, which a
-- fresh install never sees -- the view is being created, not replaced -- and
-- every upgrading database hits. Found by dev/upgrade-converges.sh, which is
-- the only check that applies this file to a database that already has the
-- old view.
  select r.id, r.workflow_def_id, r.owner_id, r.status, r.compensation_state,
         r.external_id, r.input, r.context, r.trace_id, r.created_at, r.updated_at, r.completed_at,
         r.org_id, r.visibility,
         -- `name` is here because every screen that LABELS a run had to fetch
         -- the definitions table and join it in JavaScript -- three reads for
         -- one column, and a client-side join is a number no test can check
         -- (browser-ui.md §3). A run without a readable definition still gets a
         -- row: the left join yields null, which the screen renders as the id,
         -- rather than dropping the run from the list.
         d.name,
         -- appended, not slotted in (see above): whether a person, their agent or the
         -- platform started the run (REM-171). The credential it carried is not published.
         r.started_actor,
         -- appended: the {{run.*}} keys the input did not supply (REM-1016)
         r.unsupplied_input
  from workflow.runs r
  left join workflow.definitions d on d.id = r.workflow_def_id;
create or replace view workflow.tasks_api as
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

-- ============================================================
-- (c2) The rest of the read surface: the registry, the audit trail, the
--      edges, the four aggregates, and rate limits minus the personal data.
--
--      These arrived as `applications/percolate-ui/sql/ui-views.sql`, applied
--      to a live deployment by hand, and that was the defect rather than the
--      views. `dev/owns-its-schema.py` states the rule: an application may
--      FILL a core schema and may not SHAPE one, because needing a view on a
--      core table is a signal the mechanism is general -- and every one of
--      these is. A screen is not the only thing that wants to list workflow
--      definitions or read a run's history.
--
--      Same pattern as (c) above, and it is load-bearing rather than
--      stylistic (user-rbac/spec.md §2, roles.sql §2): each view is created
--      by the table owner and then HANDED to api_viewer, which owns nothing
--      else. A view is owner-privileged, so RLS on the base table is
--      evaluated as the VIEW's owner. Leave these owned by the table owner
--      and they bypass RLS entirely; own them as superuser and they bypass it
--      twice. The self-check in (d) below asserts exactly that, which is why
--      this section sits before it rather than at the end of the file.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The registry. `workflow.definitions` was readable by nobody, so nothing
--    could list the workflows, and a run could not be labelled with its
--    workflow's name -- runs_api carries workflow_def_id and there was no row
--    on the other end of it.
--
--    `spec` IS STILL NOT PUBLISHED HERE, and the reason has changed. It used
--    to be that definitions had no owner_id, no org_id and no RLS, so every
--    authenticated caller in every tenant would read every workflow body. The
--    table adopts scope in section (e) below, so that reason is gone: this
--    view is owned by api_viewer, which owns nothing else, so a policy on the
--    base table now decides what it returns.
--
--    What is left is that nothing asks for the body. Adding a column to a view
--    is one line and is not reversible in the same way -- `create or replace
--    view` may only APPEND, so a column added here can be withdrawn only by
--    dropping the view on every deployment. Names and shapes are what a list
--    and a run label need; `spec` goes in the day a screen needs it, not the
--    day it becomes safe.
-- ------------------------------------------------------------
grant select on workflow.definitions to api_viewer;

create or replace view workflow.definitions_api as
select d.id,
       d.name,
       d.version,
       d.created_at,
       jsonb_array_length(d.spec -> 'steps')            as step_count,
       (select array_agg(distinct coalesce(s ->> 'kind', 'work') order by coalesce(s ->> 'kind', 'work'))
          from jsonb_array_elements(d.spec -> 'steps') s) as step_kinds,
       (select array_agg(distinct s ->> 'queue')
          from jsonb_array_elements(d.spec -> 'steps') s
         where s ? 'queue')                              as queues,
       -- "is this the version a new run would use", answered here rather than
       -- by the screen sorting versions in JavaScript. Same reason as
       -- `runs_api.name`: a Start control that is enabled by a client-side
       -- max() is enabled by something no test executes.
       d.version = (select max(v.version) from workflow.definitions v
                     where v.name = d.name and v.deleted_at is null) as is_latest,
       -- APPENDED, and the position is forced for the reason runs_api states
       -- above: `create or replace view` may only add columns at the end, so a
       -- column slotted in beside `name` installs cleanly and fails on every
       -- upgrading database.
       --
       -- Published because a list of workflows that cannot say which are yours
       -- is a list somebody has to guess at -- the same three columns runs_api
       -- publishes, for the same screens. A caller sees only rows the policy
       -- admits, so `owner_id` here names either them or somebody they already
       -- share an org with.
       d.owner_id, d.org_id, d.visibility
  from workflow.definitions d
 where d.deleted_at is null;

-- ------------------------------------------------------------
-- 2. The audit trail. A trigger writes `task_events` on every status change
--    and nothing could read it, so a run timeline had no source.
--
--    The view inherits scope the way `tasks_via_run` does, by joining the run
--    whose policy already decides what this caller may see.
--
--    AND THE TABLE CARRIES THE SAME POLICY, because the view's join was never
--    the only way in (REM-551). The grant below exists so that api_viewer, the
--    view's owner, can read the table -- and api_viewer is also the role a
--    person's SQL step runs as (user-rbac/roles.sql §2). A step that named
--    `workflow.task_events` instead of the view read every tenant's history,
--    `input_snapshot` included: a copy of the task input that `tasks_via_run`
--    protects on workflow.tasks. rbac/02 §10 now refuses any table a web role
--    can reach with RLS off.
-- ------------------------------------------------------------
grant select on workflow.task_events to api_viewer;
alter table workflow.task_events enable row level security;
drop policy if exists task_events_via_run on workflow.task_events;
create policy task_events_via_run on workflow.task_events for select
  using (exists (select 1 from workflow.runs r where r.id = workflow.task_events.run_id));

create or replace view workflow.task_events_api as
select e.id,
       e.run_id,
       e.task_id,
       t.step_key,
       t.kind,
       t.queue,
       e.from_status,
       e.to_status,
       e.detail,
       e.at
  from workflow.task_events e
  join workflow.tasks t on t.id = e.task_id
 where exists (select 1 from workflow.runs r where r.id = e.run_id);

-- ------------------------------------------------------------
-- 3. The edges. The task graph a run detail draws is `task_dependencies`,
--    which nothing could read -- so a caller could list a run's tasks and not
--    the shape they form. Scoped through the run, same as above.
--    The table is policied as well, for the reason task_events is above.
-- ------------------------------------------------------------
grant select on workflow.task_dependencies to api_viewer;
alter table workflow.task_dependencies enable row level security;
drop policy if exists task_dependencies_via_task on workflow.task_dependencies;
create policy task_dependencies_via_task on workflow.task_dependencies for select
  using (exists (select 1 from workflow.tasks t where t.id = workflow.task_dependencies.task_id));

create or replace view workflow.task_dependencies_api as
select d.task_id,
       d.depends_on_task_id,
       t.run_id
  from workflow.task_dependencies d
  join workflow.tasks t on t.id = d.task_id
 where exists (select 1 from workflow.runs r where r.id = t.run_id);

-- ------------------------------------------------------------
-- 4. The shapes an aggregate would have answered. PostgREST aggregates are
--    disabled on this deployment (PGRST123), on purpose: a group-by from a
--    browser over a million-row task table is exactly the query that setting
--    exists to prevent. A view is the right answer anyway -- it is named,
--    grantable and testable, and it is one plan rather than whatever the
--    caller composed.
--
--    Both are RLS-scoped, so these are counts of what THIS caller may see.
-- ------------------------------------------------------------
create or replace view workflow.runs_by_status_api as
select status, compensation_state, count(*) as n,
       max(created_at) as latest
  from workflow.runs
 group by status, compensation_state;

create or replace view workflow.tasks_by_status_api as
select queue, status, kind, count(*) as n
  from workflow.tasks
 group by queue, status, kind;

-- ------------------------------------------------------------
-- 5. Queues. There is no `workflow.pools` in this schema -- pools.md
--    specifies pools, KEDA bounds and a reconciler, and what shipped is
--    queue_config and rate_limits. So the read surface publishes what exists:
--    the configured queues, and the depth of each.
--
--    `queue_depth(queue)` is SECURITY DEFINER, so it answers with the TRUE
--    depth rather than this caller's slice -- which is what an operator needs
--    and what KEDA already scales on. The per-status breakdown in (4) is
--    RLS-scoped and will be smaller. Two numbers that disagree, both correct,
--    and whoever renders them labels which is which.
-- ------------------------------------------------------------
grant select on workflow.queue_config to api_viewer;
grant select on workflow.queue_config to authenticated;   -- unbreaks plan_catalog()
grant execute on function workflow.queue_depth(text) to authenticated;

create or replace view workflow.queues_api as
select q.queue,
       q.stale_timeout,
       q.rate_lookahead,
       workflow.queue_depth(q.queue) as depth
  from workflow.queue_config q;

-- WHY THERE IS NO `pool` COLUMN HERE, though the Queues screen joins queue
-- depth to pool bindings in the browser and REM-62 asked for one.
--
-- `workflow.pool_queues` lives in `pools.sql`, which is NOT shipped with the
-- extension -- `reads.js` marks three Queues contracts `absent:` for exactly
-- that reason, and this database is one where the table does not exist. A
-- scalar subquery does not help: the relation has to exist when the view is
-- created, so adding the column here makes this file fail to apply on every
-- deployment without pools.
--
-- The alternative is for `pools.sql` to re-create this view with the column
-- appended, which is legal. It is also worse: `queues_api` would then have a
-- different column list on different deployments, and a screen projecting
-- `pool` would 400 on the ones without it -- which is precisely the failure
-- `1919bb7` fixed and the Surface audit exists to catch. A client-side join
-- over two reads that both declare their absence is the honest shape here.
  

-- ------------------------------------------------------------
-- 6. Rate limits, MINUS the ones that are personal data.
--
--    `workflow.rate_limits` is the shared token bucket, and user-rbac reuses
--    it for login and password-reset throttling keyed by email address
--    (`'login:' || lower(p_email)`). So `grant select on rate_limits` -- the
--    obvious way to publish this -- would publish the email address of
--    everyone who has recently tried to sign in, to every authenticated
--    caller. That is why this is a filtered view and not a grant.
--
--    AND WHY THE TABLE HOLDS THE SAME FILTER AS A POLICY (REM-551). The view
--    needs its owner, api_viewer, to read the table, and api_viewer is the role
--    a person's SQL step runs as -- so a step naming `workflow.rate_limits`
--    read every sign-in address the view hides. The token bucket's writers are
--    SECURITY DEFINER and own the table, so the policy does not reach them.
-- ------------------------------------------------------------
grant select on workflow.rate_limits to api_viewer;
alter table workflow.rate_limits enable row level security;
drop policy if exists rate_limits_not_personal on workflow.rate_limits;
create policy rate_limits_not_personal on workflow.rate_limits for select
  using (key not like 'login:%' and key not like 'reset:%');

create or replace view workflow.rate_limits_api as
select key, capacity, tokens, refill_rate, updated_at
  from workflow.rate_limits
 where key not like 'login:%'
   and key not like 'reset:%';

-- Hand all seven to api_viewer and publish them. ALTER ... OWNER TO requires
-- the NEW owner to hold CREATE on the schema, which is what the grant/revoke
-- pair around this is for -- api_viewer owns nothing but views, so CREATE here
-- buys it nothing except the ability to be handed one.
grant create on schema workflow to api_viewer;
alter view workflow.definitions_api        owner to api_viewer;
alter view workflow.task_events_api        owner to api_viewer;
alter view workflow.task_dependencies_api  owner to api_viewer;
alter view workflow.runs_by_status_api     owner to api_viewer;
alter view workflow.tasks_by_status_api    owner to api_viewer;
alter view workflow.queues_api             owner to api_viewer;
alter view workflow.rate_limits_api        owner to api_viewer;
revoke create on schema workflow from api_viewer;

grant select on workflow.definitions_api, workflow.task_events_api,
                workflow.task_dependencies_api, workflow.runs_by_status_api,
                workflow.tasks_by_status_api, workflow.queues_api,
                workflow.rate_limits_api
   to authenticated;

comment on view workflow.definitions_api is
$c$One row per registered workflow definition -- the catalog you start a run from.
Carries the name and version to start by, and the shape of the body without the
body itself: step_count, the distinct step_kinds, and the queues its steps
name. Filter it the PostgREST way -- ?name=eq.<name>, ?order=created_at.desc.$c$;

comment on view workflow.task_events_api is
$c$Every status transition of every task, for the runs you may see.
The timeline behind a run: from_status, to_status, when, and the step it
happened to. Filter by ?run_id=eq.<uuid> and ?order=at.asc to read one run's
history in order.$c$;

comment on view workflow.task_dependencies_api is
$c$The edges of a run's task graph -- which task waits on which.
tasks_api gives you the nodes; this gives you the shape they form. Filter by
?run_id=eq.<uuid>.$c$;

comment on view workflow.runs_by_status_api is
$c$How many runs are in each status right now, of the runs you may see.
One row per (status, compensation_state) with a count and the most recent
created_at. This is the aggregate to read instead of counting runs_api
yourself -- PostgREST aggregates are disabled here on purpose.$c$;

comment on view workflow.tasks_by_status_api is
$c$How many tasks are in each status right now, per queue and kind.
Counts what THIS caller may see. For the true depth of a queue regardless of
who is asking, read queues_api.depth.$c$;

comment on view workflow.queues_api is
$c$The configured queues and how deep each one is.
depth is the TRUE backlog -- every waiting task, not just yours -- because it
is what a worker pool scales on. stale_timeout is how long a claimed task may
go without a heartbeat before it is reaped.$c$;

comment on view workflow.rate_limits_api is
$c$The token buckets that throttle work, and how full each is.
capacity against tokens says how much burst is left; refill_rate is per second.
Login and password-reset buckets are excluded -- their keys are email
addresses.$c$;

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
--
-- AND THE RUN'S ORG COMES FROM THE DEFINITION, NOT FROM THE CALLER -- spec.md
-- §17(b), the other half of the scope REM-91 put on `workflow.definitions`.
--
-- A run of an org's workflow is that org's run. That is what makes the org
-- unambiguous when the caller belongs to several, and it is the one thing
-- `world-model-ingestion/lake.md` §8 asks for from this end: "lake outputs
-- land in the shared org, where dataset names are unique across every user,
-- and a second user's `sales` is refused as not theirs. Starting a run in a
-- named org is workflow-engine's to add." `e2e-lake.py` set `runs.org_id` by
-- hand and called it its one shim; this is the shim's replacement.
--
-- A `p_org_id` argument checked against rbac.current_org_ids() was the
-- alternative and §17(b) rejects it: it puts the choice in the caller's hands
-- for no gain, and every caller would then pass the value the definition
-- already carries. It is also the spoofable shape this function's own header
-- is about.
--
-- ONLY WHEN THE RUN IS STILL ON THE SHARED TIER, so an explicit org survives.
-- rbac.is_shared_org() rather than `org_id is null`: the column is NOT NULL
-- with the shared sentinel as its default, so "the caller did not choose one"
-- reads as the sentinel and not as a null (the reason that function exists).
--
-- VISIBILITY IS NOT TOUCHED, and that is deliberate rather than unfinished.
-- §17(b) makes the run BELONG to the org; it does not make it readable by
-- everyone in it, and a run is private to its owner exactly as before. The org
-- is what scopes dataset names in `content.datasets`, which is what lake.md §8
-- needs -- widening every run of a shared workflow to org-visible would be a
-- disclosure nobody asked for, on the same table where `add_scope_columns`
-- chose 'private' for precisely this reason.
--
-- It would not work anyway, which is worth writing down because the next
-- person will try it: `trg_runs_visibility` sorts before `trg_set_run_owner`,
-- and Postgres fires BEFORE triggers in name order -- so rbac.enforce_visibility()
-- has already validated the row by the time this runs. Setting `visibility`
-- here would skip its check; a caller who inserts visibility 'org' must still
-- supply the org themselves, and the error they get if they do not is
-- accurate.
create or replace function workflow.set_run_owner() returns trigger as $$
declare v_def_org uuid;
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    -- From the claims, never from the row: whatever an insert names is replaced.
    new.started_actor := case when rbac.current_user_id() is not null then rbac.current_actor() end;
    new.started_credential_id := rbac.current_credential_id();

    if rbac.is_shared_org(new.org_id) and new.workflow_def_id is not null then
        select d.org_id into v_def_org
          from workflow.definitions d where d.id = new.workflow_def_id;
        -- Shared-tier definitions keep today's behaviour and §17(b) says why:
        -- "a workflow nobody owns produces a run nobody owns". Assigning
        -- anything else would have to invent a tenant.
        if v_def_org is not null and not rbac.is_shared_org(v_def_org) then
            new.org_id := v_def_org;
        end if;
    end if;

    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger trg_set_run_owner
    before insert on workflow.runs
    for each row execute function workflow.set_run_owner();

-- The starter does not change after the insert. The one hand-over is tick's: a scheduled run is started with no
-- claims and then given to the schedule's owner, and the schedule's creator travels with it in that same update.
create or replace function workflow.keep_run_starter() returns trigger as $$
begin
    if old.owner_id is null and new.owner_id is not null then
        return new;
    end if;
    new.started_actor := old.started_actor;
    new.started_credential_id := old.started_credential_id;
    return new;
end;
$$ language plpgsql set search_path = pg_catalog, public;

create or replace trigger trg_keep_run_starter
    before update on workflow.runs
    for each row execute function workflow.keep_run_starter();

-- Ownership from the JWT, never from an argument -- the third instance of the
-- shape set_run_owner() and set_schedule_owner() already use, and a trigger
-- for their reason rather than a modified define_yaml(): the core function
-- keeps no rbac dependency, and every other insert path (apply_package,
-- seed_load, a hand-written INSERT) gets it for free.
--
-- THE SECOND BRANCH IS NOT SYMMETRY, it is what keeps packages installable.
-- percolate.apply_package() is SECURITY DEFINER and is run by an operator with
-- no JWT, so current_user_id() is null and owner_id stays null -- and a row
-- with no owner at visibility 'private' is readable by nobody under
-- rbac.may_read(), including the operator who installed it. Every package
-- workflow would install successfully and then be startable by no signed-in
-- caller, with nothing to say so.
--
-- So: a definition nobody owns is the deployment's, and spec.md §17(c) already
-- decides what that means -- "a package is installed for the deployment, and
-- the shared tier is exactly what 'for the deployment' means". There is no
-- explicit-private case to protect: ownerless AND private is a row no caller
-- can ever read, so it cannot be what anybody meant.
create or replace function workflow.set_definition_owner() returns trigger as $$
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    if new.owner_id is null and new.visibility = 'private' then
        new.visibility := 'public';
    end if;
    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace trigger trg_set_definition_owner
    before insert on workflow.definitions
    for each row execute function workflow.set_definition_owner();

-- The real check, replacing schema.sql's `select true` stand-in. The row is
-- the argument because schema.sql cannot name columns rbac adds; see the stub
-- for why, and for the measurement showing why the policy alone cannot do
-- this job through a SECURITY DEFINER caller.
--
-- rbac.may_read() rather than a fourth copy of the predicate: its own header
-- says it exists for exactly this caller -- "what a SECURITY DEFINER function
-- calls, once, about one row it has already fetched" -- and the 58x per-row
-- cost that keeps it out of policies does not arise when it is asked once.
--
-- THREE ARMS, and each one was found by something failing rather than chosen.
--
-- is_operator() is load-bearing rather than defensive. `worker` and
-- `scheduler` hold no JWT, so may_read() alone answers false for every
-- definition that is not public -- and start_child_workflow() resolves its
-- definition as `worker` while the clock resolves one as `scheduler`. Without
-- this arm, making a workflow private silently stops its own sub-workflows and
-- its own schedule, and nothing reports it. Same arm, same position, as
-- rbac.scope_write_predicate().
--
-- has_permission() IS THE ARM THE POLICY HAS, and leaving it out made this
-- function and the policy beside it two rules that disagreed -- the exact drift
-- the "one rule, two spellings" argument above claims to prevent. Found by
-- dev/tests/content/03-sources.sql, which starts a private source workflow as
-- an `admin` to prove the transformation reader follows the RUN's owner rather
-- than the workflow input: the policy admitted that caller through
-- workflow_definitions:select and this function refused them, so a test about
-- impersonation failed as a missing workflow. add_scope_policy() emits this arm
-- whenever it is given a resource, so a predicate that means to agree with the
-- policy has to carry it. may_access_run() has the identical shape for the
-- identical reason.
create or replace function workflow.may_start(d workflow.definitions)
returns boolean as $$
    select rbac.is_operator()
        or rbac.may_read(d.owner_id, d.org_id, d.visibility)
        or rbac.has_permission(rbac.current_user_id(), 'workflow_definitions', 'select');
$$ language sql stable;

-- Called from inside current_definition(), which is SECURITY INVOKER and is
-- reached by every role that starts anything -- so EXECUTE is checked against
-- the caller, not against the engine owner, exactly as user-rbac §9 says of
-- the predicates its policies call.
revoke execute on function workflow.may_start(workflow.definitions) from public;
grant execute on function workflow.may_start(workflow.definitions)
    to authenticated, api_viewer, worker, scheduler;

-- AND THE IDEMPOTENCY KEY IS SCOPED THE SAME WAY THE ROWS ARE.
--
-- `schema.sql` declares one run per external_id, which is the strongest form
-- an engine with no identities can state. Here there are identities, so the
-- fact narrows: one run per OWNER per key. Anything weaker is a broken write
-- where the oracle used to be -- start_workflow() now matches only among the
-- runs the caller may see (reusable_run, below), and over an
-- installation-wide unique key a second person's INSERT with a key already
-- used would fail on the constraint instead of returning a row, which still
-- says the key exists and now also refuses legitimate work (REM-77).
--
-- The trigger above runs BEFORE this is checked, so the index sees the owner
-- the JWT assigned rather than the null the caller inserted.
--
-- WHY coalesce() AND NOT `nulls not distinct`. A null owner means SYSTEM-OWNED
-- -- assert_run_access() is explicit that it is not "owned by everyone" -- so
-- two system runs under one key must collide, which is what tick()'s retry
-- idempotence rests on. `nulls not distinct` would say that for owner_id and
-- also, index-wide, for external_id, whose null is an ABSENCE
-- (specs/identity/declarations.sql: "no idempotency key was supplied"), and
-- declaring an absence NOT DISTINCT is exactly what specs/identity/checks.sql
-- §3 refuses. One index cannot be both, so the null that means something is
-- resolved to the value it means -- in the index, where the question
-- specs/identity asks is answered rather than deferred. The nil UUID is not a
-- user id: rbac.users.id defaults to uuidv7().
--
-- Partial, because most runs carry no key at all and `nulls distinct` on a
-- column that is usually null is a constraint over almost nothing; `where
-- external_id is not null` says the same thing and indexes only the rows the
-- guarantee is about.
alter table workflow.runs drop constraint if exists runs_external_id_key;
drop index if exists workflow.runs_external_id_key;
create unique index if not exists runs_owner_external_id_key
    on workflow.runs (coalesce(owner_id, '00000000-0000-0000-0000-000000000000'::uuid),
                      external_id)
 where external_id is not null;

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

-- THE RULE ITSELF, AS A BOOLEAN, because two callers need the same question
-- asked and only one of them wants an exception for an answer.
--
-- assert_run_access() refuses; start_workflow's idempotency match has to CARRY
-- ON and start a new run when the answer is no, so a raise is the wrong shape
-- for it. Split rather than spelled twice: a second copy of this predicate is
-- how `resolve_file` came to ask the row while four siblings asked the org
-- (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §6). The
-- sentence is unchanged from the version assert_run_access carried.
--
-- SECURITY DEFINER because it must give the same answer whoever asks: it reads
-- workflow.runs, whose RLS would otherwise hide the very row being judged and
-- turn "not yours" and "not there" into one answer. Granted to nobody -- both
-- callers are definer functions owned by app_owner.
create or replace function workflow.may_access_run(p_run_id uuid, p_action text)
returns boolean as $$
    -- A system-owned run (owner_id null) is not "owned by everyone": it takes
    -- an explicit permission, never bare ownership, to act on.
    select exists (select 1 from workflow.runs r
                    where r.id = p_run_id
                      and r.owner_id is not null
                      and r.owner_id = rbac.current_user_id())
        or rbac.has_permission(rbac.current_user_id(), 'workflow_runs', p_action);
$$ language sql stable security definer set search_path = pg_catalog, public;

create or replace function workflow.assert_run_access(p_run_id uuid, p_action text)
returns void as $$
begin
    if not exists (select 1 from workflow.runs where id = p_run_id) then
        raise exception 'run % not found', p_run_id;
    end if;
    if workflow.may_access_run(p_run_id, p_action) then
        return;
    end if;
    raise exception 'not authorized to % run %', p_action, p_run_id
        using errcode = 'insufficient_privilege',
              hint = 'needs workflow_runs:' || p_action || ', or ownership of the run';
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- WHOSE RUN AN IDEMPOTENCY KEY RESOLVES TO -- schema.sql §9's stub, with the
-- identity model installed.
--
-- start_workflow() is idempotent on external_id and did not ask whose run it
-- had matched, so naming a value another person had used -- and these are
-- values a caller picks: a ticket reference, a document id, a date -- returned
-- that run's id, or named it in the error. The rows themselves stayed refused
-- (runs_api and tasks_api are RLS-filtered, cancel and signal go through
-- assert_run_access), so what it bought was the id, the knowledge that a run
-- under that key exists, and whatever the caller's next step did with a run id
-- it had been handed. REM-77.
--
-- THE RULE IS assert_run_access'S, through may_access_run: the caller's own
-- run, or one their permissions reach. Own runs are preferred over reachable
-- ones, so an administrator holding workflow_runs:select -- who reaches every
-- tenant's runs -- still gets their OWN run back for their own key rather
-- than whichever row was inserted first.
--
-- AND THE ENGINE ITSELF IS NOT A TENANT. tick() fires a schedule as
-- `scheduler` with no JWT and makes the fire idempotent through this key
-- (`schedule:<name>:<minute>`), then stamps the schedule's owner onto the run
-- afterwards (§21j) -- so on a retried tick the run is owned by a person the
-- caller is not, and a scoped match would start a second run for the same
-- minute, which is the double-fire §19 uses the key to prevent. An operator's
-- authorization is the grant, not an identity (the rule this file states for
-- every worker-facing function), and rbac.is_operator() is how the collection
-- already spells "a direct database session rather than a request": over
-- PostgREST session_user is authenticator, a member of authenticated, so no
-- request can take this branch.
create or replace function workflow.reusable_run(p_external_id text)
returns uuid as $$
    select r.id
      from workflow.runs r
     where r.external_id = p_external_id
       and (rbac.is_operator() or workflow.may_access_run(r.id, 'select'))
     order by (r.owner_id = rbac.current_user_id()) desc nulls last, r.created_at
     limit 1;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- AUTHORING A WORKFLOW IS THE SAME RULE, APPLIED TO THE OTHER SIDE OF THE
-- ENGINE, and it was the one place the rule above was not applied.
--
-- `schema.sql`'s `may_define()` returns true, because the engine standalone has
-- no identity to check. This is the version that runs once the identity plane
-- is installed, and it exists because define_yaml was a SECURITY DEFINER
-- function reachable by an end user with no authorization check and Postgres's
-- PUBLIC default still on it. `schema.sql`'s open sql_policy says plainly that
-- a step's statement runs as the engine owner and therefore reads across
-- tenants; that trade is only survivable while defining a workflow is a
-- privileged act, and it was not. Reproduced end to end: a user holding no
-- permissions, refused on `select from rbac.users`, defined a one-step
-- workflow and got back every row of it.
--
-- Same shape as agentic.may_author, deliberately -- a permission, or the
-- bootstrap case where there is no end-user identity at all and the caller can
-- already write the table directly. The second branch is what lets an operator
-- and `dev/init/` seed definitions, and it is unreachable over PostgREST:
-- there `session_user` is `authenticator`, which has no INSERT anywhere.
create or replace function workflow.may_define()
returns boolean as $$
    select rbac.has_permission(rbac.current_user_id(), 'workflows', 'update')
        or (rbac.is_operator()
            and pg_catalog.has_table_privilege(
                    session_user, 'workflow.definitions'::regclass, 'insert'));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- A STEP'S STATEMENT RUNS AS THE PERSON WHO STARTED THE RUN -- the rbac half
-- of schema.sql's "WHOSE REACH A STATEMENT HAS".
--
-- WHO. The run's owner, stamped from the verified JWT at start (set_run_owner,
-- below). Not the current caller: a step executes long after the request that
-- started it, often on a worker's connection with no claims at all. Orgs are
-- not captured, because rbac.current_org_ids() derives them from org_members
-- by user id -- so a person removed from an org loses that org's rows at their
-- run's next step, the same "revocation is immediate" the read path promises.
create or replace function workflow.run_owner_of(p_run_id uuid)
returns uuid as $$
    select owner_id from workflow.runs where id = p_run_id;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- TWO FUNCTIONS, because the role that runs the statement must not be the role
-- that says whose statement it is. `request.jwt.claims` is the caller for every
-- row rule in the collection, and since REM-44 only authenticator, app_owner,
-- worker and scheduler may write it (user-rbac/roles.sql §6). api_viewer is
-- not among them, because it runs SQL a workflow's AUTHOR wrote, and an
-- author's `select set_config('request.jwt.claims', ...)` inside a read step
-- would otherwise read as anyone at all. So execute_for (app_owner) sets the
-- claims and restores them; execute_as_viewer (api_viewer) runs the statement
-- and cannot touch them. The first version was one function owned by
-- api_viewer that did both, which needed api_viewer to hold set_config, which
-- is the door.
--
-- What this still does not close: a WRITE step's statement is executed as a
-- statement, so it can be `SET LOCAL request.jwt.claims = ...` or a DO block
-- that issues one, and SET is not a function a grant can take away. That door
-- is an author's, not a signed-in person's, and closing it needs the setting
-- declared superuser-only by a C module (REM-64).
--
-- HOW, and why this is possible at all when the roadmap said it was not.
--
-- execute_sql_step is SECURITY DEFINER owned by app_owner, which owns every
-- table and so bypasses RLS. Postgres refuses `SET ROLE` anywhere in a
-- SECURITY DEFINER stack, so the step cannot become the person. What it CAN do
-- is call another SECURITY DEFINER function, and that switches identity to the
-- callee's owner. execute_as_viewer is owned by api_viewer -- the role that already
-- owns every *_api view for exactly this reason: it is not the table owner, so
-- RLS applies to it, and the claims decide whose rows it sees. With the claims
-- set to the run's owner, a statement here sees what that person would see
-- through PostgREST, no more. (api_viewer holds authenticated's grants by
-- membership -- roles.sql / bootstrap.sql -- so it can read what they can.)
--
-- Replaying the claims WITHOUT changing identity would change nothing, since
-- an owner bypasses RLS whatever the claims say -- which is why the role
-- switch, done by ownership rather than SET ROLE, is the whole mechanism.
--
-- NOBODY BUT THE ENGINE MAY CALL EITHER. execute_for takes a user id and a
-- statement, so a caller who could reach it could read as anyone. EXECUTE on
-- both is granted to app_owner alone, and nobody is a member of api_viewer but
-- app_owner.
--
-- The claims are restored on BOTH exit paths, in execute_for's own exception
-- handler, and NOT left to the caller's subtransaction. The caller's abort does
-- roll the set_config back -- but `tick()` and an autorun cascade run several
-- sql tasks in one transaction, and a design where the identity outlives a
-- failing step until something else happens to unwind it is one set_config away
-- from the next task in that tick running as the previous run's owner. So this
-- restores and re-raises itself, and the restore does not depend on who calls
-- it. (Regression covered in dev/tests/workflow/15: two owners in one
-- transaction, the first failing.)
create or replace function workflow.execute_as_viewer(
    p_statement text, p_write boolean, p_params jsonb)
returns jsonb as $$
declare
    v_out   jsonb;
    v_count bigint;
    v_cur   refcursor;
begin
    if p_write then
        -- ONE STATEMENT THAT CANNOT CHANGE WHOSE STEP THIS IS, and Postgres's
        -- grammar decides, not a pattern. A write is wrapped as the body of a
        -- data-modifying CTE (workflow.one_write_statement), which parses only
        -- as ONE INSERT, UPDATE, DELETE or MERGE, and whose count is the row
        -- count the step reports. A read is wrapped as a subquery below.
        --
        -- BUT THE WRAPPING IS NOT ENOUGH ON ITS OWN, and this was the REM-64
        -- hole for a whole release: plpgsql's EXECUTE runs a string of SEVERAL
        -- statements one after another, so an author who closes the CTE bracket
        -- himself smuggles the rest past it --
        --   `update t set x=x where false returning 1) select 1;
        --    set local request.jwt.claims = '{"sub":"<victim>"}';
        --    with p8_write as (update ... where owner='<victim>'`
        -- wraps into three statements, the SET runs as api_viewer, and the
        -- third rewrites the victim's rows. PREPARE has the same flaw -- it
        -- prepares the first and EXECUTE runs the rest. Measured before this
        -- fix: the victim's row was rewritten.
        --
        -- So the wrapped string is OPENED AS A CURSOR rather than EXECUTEd.
        -- SPI parses the whole string before running any of it and refuses to
        -- open a multi-statement plan as a cursor ('cannot open multi-query
        -- plan as cursor', invalid_cursor_definition) -- and a CTE body holding
        -- a SET or a DO or a second statement is a syntax error before that.
        -- Either way nothing runs: it is the grammar enforcing one statement,
        -- SQL-only, and it is exact. Trailing semicolons are dropped by
        -- one_write_statement, since an author writes them and a CTE body
        -- cannot hold one. A system run does not come through here: it runs as
        -- the engine, the operator's trade (run_sql).
        begin
            if p_params is not null then
                open v_cur for execute workflow.one_write_statement(p_statement) using p_params;
            else
                open v_cur for execute workflow.one_write_statement(p_statement);
            end if;
            fetch v_cur into v_count;
            close v_cur;
        exception when syntax_error or invalid_cursor_definition then
            raise exception
                'a write step run for a person must be one INSERT, UPDATE, DELETE or MERGE '
                'statement without its own RETURNING, and this is not (%)', sqlerrm
                using errcode = 'syntax_error',
                      hint = 'a SET, a DO block or a second statement would change whose '
                             'rows the step acts on; write the change as one statement';
        end;
        return jsonb_build_object('rows_affected', v_count);
    end if;

    -- A read is one query, enforced the same way and for the same reason: the
    -- `(%s) t` subquery is closable too, so `select 1) t; set local
    -- request.jwt.claims = ...; select ... from (select <victim's rows>` read
    -- as the victim under plain EXECUTE (identical shape to aiq.sql_passthrough,
    -- where it was measured). Opening as a cursor refuses the multi-statement
    -- string; a genuine error in a single query (a missing relation, say) is a
    -- different SQLSTATE and propagates unchanged, so the author still sees it.
    begin
        if p_params is not null then
            open v_cur for execute
                format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement)
                using p_params;
        else
            open v_cur for execute
                format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement);
        end if;
        fetch v_cur into v_out;
        close v_cur;
    exception when syntax_error or invalid_cursor_definition then
        raise exception
            'a read step run for a person must be a single query, and this is not (%)', sqlerrm
            using errcode = 'syntax_error',
                  hint = 'a SET or a second statement would change whose rows the step '
                         'reads; write the read as one query';
    end;
    return coalesce(v_out, '[]'::jsonb);
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

-- Handed to api_viewer the way the *_api views are (section (c)): app_owner is a
-- member of api_viewer, and the new owner needs CREATE on the schema for the
-- moment of the transfer.
grant create on schema workflow to api_viewer;
alter function workflow.execute_as_viewer(text, boolean, jsonb) owner to api_viewer;
revoke create on schema workflow from api_viewer;
revoke execute on function workflow.execute_as_viewer(text, boolean, jsonb) from public;
grant execute on function workflow.execute_as_viewer(text, boolean, jsonb) to app_owner;

create or replace function workflow.execute_for(
    p_user uuid, p_statement text, p_write boolean, p_params jsonb)
returns jsonb as $$
declare
    v_prev   text := current_setting('request.jwt.claims', true);
    v_out    jsonb;
    v_run    workflow.runs;
    v_claims jsonb;
begin
    if p_user is null then
        raise exception 'execute_for was given nobody to run as';
    end if;
    -- The step runs as its run's starter, not only its owner (REM-171): an agent's run carries the agent and its
    -- credential, so rbac.decide refuses a human-only capability, a scope the key lacks and a key revoked since
    -- the run began. Only the run being executed, and only when it is p_user's, lends its starter.
    select * into v_run from workflow.runs
     where id = nullif(current_setting('workflow.current_run_id', true), '')::uuid and owner_id = p_user;
    v_claims := jsonb_build_object('sub', p_user, 'role', 'authenticated');
    if v_run.started_actor in ('agent', 'platform') then
        v_claims := v_claims || jsonb_build_object('actor', v_run.started_actor);
    end if;
    if v_run.started_credential_id is not null then
        v_claims := v_claims || jsonb_build_object('api_key_id', v_run.started_credential_id);
    end if;
    perform set_config('request.jwt.claims', v_claims::text, true);
    begin
        v_out := workflow.execute_as_viewer(p_statement, p_write, p_params);
    exception when others then
        perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
        raise;
    end;
    perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
    return v_out;
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

-- OWNED BY app_owner, said explicitly. `create or replace` keeps an existing
-- function's owner, and the first version of execute_for was api_viewer's, so a
-- database upgraded from it would keep an execute_for that runs as api_viewer --
-- which can no longer call set_config, and fails every person's sql step.
alter function workflow.execute_for(uuid, text, boolean, jsonb) owner to app_owner;
revoke execute on function workflow.execute_for(uuid, text, boolean, jsonb) from public;
grant execute on function workflow.execute_for(uuid, text, boolean, jsonb) to app_owner;

-- workflow.p8ql runs inside execute_for when a person's step calls it, and its
-- SQL-mode guard asks the policy there. It reads one setting.
grant execute on function workflow.sql_policy() to api_viewer;

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

-- Returns how many waiting steps it resolved: 0 is a signal that reached
-- nothing (sent early, sent twice, or under the wrong name). schema.sql's copy
-- carries the note (REM-977).
create or replace function workflow.signal_task(p_run_id uuid, p_signal text, p_payload jsonb)
returns integer as $$
declare
    r   record;
    v_n integer := 0;
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
    -- Selected, merged, then transitioned -- and the ORDER is the fix, not an
    -- arrangement. A `sql` successor auto-runs inside the statement that marks
    -- it ready, so merging afterwards leaves runs.context perfectly correct and
    -- the acting step already failed. schema.sql's merge_step_context carries
    -- the full note; this is the copy that actually runs.
    for r in
        select id from workflow.tasks
        where run_id = p_run_id and wait_signal = p_signal
          and status = 'waiting_external'
        for update
    loop
        -- Nested under `result`: the one idiom every other step kind honours.
        perform workflow.merge_step_context(
            r.id, jsonb_build_object('result', p_payload));
        update workflow.tasks
        set status = 'succeeded', output = jsonb_build_object('result', p_payload),
            completed_at = clock_timestamp()
        where id = r.id;
        v_n := v_n + 1;
    end loop;
    -- A signal can be a run's last step, and nothing else asks the question
    -- complete_task asks: so a run ending on a person's decision stayed
    -- `running` with every task succeeded (REM-957).
    perform workflow.check_run_completion(p_run_id);
    return v_n;
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
    -- 'select', not 'read'. Both call sites here are READING run-scoped rows, and
    -- the RLS policy on workflow.runs already spells that authority 'select' --
    -- so a deployment that granted the run-read permission the policy asks for
    -- was still refused by these two functions, which asked for a string nothing
    -- else in the collection uses. role_permissions.action is matched with `=`,
    -- so the two spellings were two permissions, not one with an alias.
    perform workflow.assert_run_access(v_run, 'select');

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
        perform workflow.assert_run_access(v_run, 'select');
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
-- Both are the authorization rule itself, called only from functions that own
-- their check. A grant to anybody would hand out an existence probe over
-- another tenant's runs, which is the defect they were written to close.
revoke execute on function workflow.may_access_run(uuid, text) from public;
revoke execute on function workflow.reusable_run(text) from public;
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
-- Who created the schedule, which tick hands to every run it starts (REM-171): an agent's schedule fires as the
-- agent, not as the person it works for.
alter table workflow.schedules add column if not exists created_actor text
    check (created_actor in ('person', 'agent', 'platform'));
alter table workflow.schedules add column if not exists created_credential_id uuid;

-- Ownership from the JWT, never from an argument -- the same rule, and the
-- same trigger shape, as runs above. schedule_workflow() therefore has no
-- owner parameter to spoof.
create or replace function workflow.set_schedule_owner() returns trigger as $$
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    new.created_actor := case when rbac.current_user_id() is not null then rbac.current_actor() end;
    new.created_credential_id := rbac.current_credential_id();
    return new;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- The creator does not change after the insert, whoever updates the schedule later.
create or replace function workflow.keep_schedule_creator() returns trigger as $$
begin
    new.created_actor := old.created_actor;
    new.created_credential_id := old.created_credential_id;
    return new;
end;
$$ language plpgsql set search_path = pg_catalog, public;

create or replace trigger trg_keep_schedule_creator
    before update on workflow.schedules
    for each row execute function workflow.keep_schedule_creator();

create or replace trigger trg_set_schedule_owner
    before insert on workflow.schedules
    for each row execute function workflow.set_schedule_owner();

-- schedules already carried BOTH owner_id and org_id and used only the first:
-- the org column was added for a scheduled run to be RLS-scoped by and then
-- had no policy that read it. It has one now.
select rbac.add_scope_columns('workflow.schedules');
select rbac.add_scope_policy ('workflow.schedules', 'workflow_schedules');

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
    -- AND NOBODY IS BEHIND IT (rbac.is_operator). Membership alone returned
    -- early with a person's claims in force, so a session that could become
    -- the owner skipped the owner check below even when acting for someone.
    if rbac.is_operator() and pg_has_role(session_user, v_tbl_owner, 'member') then
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
            using errcode = 'insufficient_privilege',
                  hint = 'authenticate first: a schedule needs an owner';
    end if;

    if v_owner is not null and v_owner = v_caller then
        return;
    end if;
    if rbac.has_permission(v_caller, 'workflow_schedules', p_action) then
        return;
    end if;
    raise exception 'not authorized to % schedule "%"', p_action, p_name
        using errcode = 'insufficient_privilege',
              hint = 'needs workflow_schedules:' || p_action || ', or ownership of the schedule';
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- The read path: a view owned by api_viewer, never the table owner.
create or replace view workflow.schedules_api as
  select id, name, workflow_name, cron_expr, timezone, input, enabled,
         overlap_policy, owner_id, org_id, last_tick_at, last_fired_at,
         last_run_id, fire_count, skip_count, last_error, last_error_at,
         created_at, updated_at,
         -- appended, not slotted in: see runs_api above
         visibility,
         -- who created the schedule, which every run it starts carries (REM-171)
         created_actor
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

-- THE SECOND ENUMERATION, and the reason it is a test rather than a list.
--
-- The revokes above came from enumerating the engine by hand once. Six more
-- functions were created AFTER `schema.sql`'s `revoke execute on all functions
-- in schema workflow from public`, which only touches functions that exist when
-- it runs -- so each of them kept the PUBLIC default while carrying an explicit
-- `grant ... to authenticated` that read as if it were the whole ACL. Every one
-- already grants the callers it means to; revoking PUBLIC changes who can call
-- them and nothing else.
--
-- A hand-maintained list is what let define_yaml through the first time, so the
-- rule is now asserted generically in dev/tests/rbac/04-definer-surface.sql: no
-- SECURITY DEFINER function in this collection may carry the PUBLIC default.
revoke execute on function workflow.define_yaml(text) from public;
revoke execute on function workflow.matrix_rows(uuid) from public;
revoke execute on function workflow.matrix_outputs(uuid) from public;
revoke execute on function workflow.schedule_workflow(text, text, text, jsonb, text, text) from public;
revoke execute on function workflow.set_schedule_enabled(text, boolean) from public;
revoke execute on function workflow.unschedule_workflow(text) from public;
revoke execute on function workflow.may_define() from public;
revoke execute on function workflow.run_owner_of(uuid) from public;
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

-- The principal of a claimed task comes from the run, never from run input.
-- Workers use this only to authenticate an agent step to the configured runtime.
create or replace function workflow.task_owner(p_task_id uuid, p_worker_id text)
returns uuid as $$
declare v_owner uuid;
begin
    select r.owner_id into v_owner
      from workflow.tasks t join workflow.runs r on r.id = t.run_id
     where t.id = p_task_id and t.status = 'running'
       and t.claimed_by = p_worker_id;
    if not found then
        raise exception 'task is not currently held by this worker' using errcode = '42501';
    end if;
    if v_owner is null then
        raise exception 'agent execution requires a run owner' using errcode = '42501';
    end if;
    return v_owner;
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;
revoke all on function workflow.task_owner(uuid, text) from public;
grant execute on function workflow.task_owner(uuid, text) to worker;

-- WHO STARTED THE RUN, FOR THE TOKEN AN AGENT STEP CARRIES (REM-247). task_owner answers "whose run is this", and
-- the worker minted `{"sub": owner}` from that alone, so an agent step in a run a person's agent started called the
-- runtime as the person: a human-only capability passed, the key's scopes did not narrow, and revoking the key
-- stopped nothing. REM-171 records the starter's actor and credential on the run for SQL steps; this returns them
-- beside the owner, under task_owner's guards, so the worker mints `actor` and `api_key_id` too and the runtime's
-- rbac.decide narrows the step exactly as it narrowed whoever started the run. task_owner stays, for a worker that
-- predates this function. A run from before REM-171 has no starter, and its token stays owner-only.
create or replace function workflow.task_principal(p_task_id uuid, p_worker_id text)
returns table (owner_id uuid, started_actor text, started_credential_id uuid) as $$
declare v_run workflow.runs;
begin
    select r.* into v_run
      from workflow.tasks t join workflow.runs r on r.id = t.run_id
     where t.id = p_task_id and t.status = 'running'
       and t.claimed_by = p_worker_id;
    if not found then
        raise exception 'task is not currently held by this worker' using errcode = '42501';
    end if;
    if v_run.owner_id is null then
        raise exception 'agent execution requires a run owner' using errcode = '42501';
    end if;
    return query select v_run.owner_id, v_run.started_actor, v_run.started_credential_id;
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;
revoke all on function workflow.task_principal(uuid, text) from public;
grant execute on function workflow.task_principal(uuid, text) to worker;

-- ============================================================
-- (h) READING A PLAN'S PROGRESS, FOR THE ROLE IT IS GRANTED TO
-- ============================================================
--
-- workflow.plan_status is granted to `authenticated` in schema.sql and, until
-- this shadow, could not be called by any member of that role. Measured, on
-- extension 0.2.0:
--
--     => begin; set local role authenticated;
--     => select * from workflow.plan_status('ingest_file', null) limit 1;
--     ERROR:  permission denied for table tasks
--
-- Not a leak -- the opposite. A capability offered to every signed-in caller
-- that none of them can use, failing with the name of a table they have never
-- heard of. Its five siblings -- plan_catalog, plan_graph, plan_document,
-- plan_defects, plan_probe -- share the grant line and read only
-- workflow.definitions, which `authenticated` may select, so they work.
-- plan_status is the one that reads run rows.
--
-- The standalone body's comment gave the reason as RLS: "this function is
-- SECURITY INVOKER precisely so that stays true -- a caller sees the runs
-- their policies admit". The policies never got to run. `authenticated` holds
-- no SELECT on workflow.runs or workflow.tasks at all (§(a) above: "No
-- base-table grant to authenticated at all"), so the grant check refused
-- before RLS was consulted. The sentence described a design that was never
-- reached, which is why reading it did not reveal the defect.
--
-- THE PREDICATE IS may_access_run, WHICH THIS FILE ALREADY OWNS. cancel_run,
-- signal_task and reusable_run all ask the same question of a caller-supplied
-- run, and REM-77 extracted it so there would be one copy. A second spelling
-- here is how `resolve_file` came to ask the row while four siblings asked the
-- org (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §6).
--
-- READING runs_api/tasks_api INSTEAD WAS TRIED AND IS WRONG, and the measurement
-- is the reason rather than a preference. Those views are owned by api_viewer
-- so RLS applies to them -- which is what makes them safe for `authenticated`
-- and also what makes them empty for an operator: `app_owner` with no JWT has
-- no current_user_id, so the run policy admits nothing and plan_status returns
-- zero rows to the caller who has always used it. dev/tests/workflow/11 §10
-- caught exactly that ("plan_status did not report the row count: <NULL>").
-- rbac.is_operator() is the collection's one spelling of "a direct session
-- rather than a request", and reusable_run above carries the same leading arm
-- for the same reason.
--
-- AND THE RUN-LESS FORM NOW MEANS *MY* NEWEST RUN. `plan_status(name)` with no
-- run id resolves "the newest run of this workflow", and the newest run of an
-- installation-wide definition belongs to whoever started it. Filtered through
-- the predicate, the newest run the CALLER may see is the only one it can name
-- -- which is what somebody asking "how far has my run got" means, and what the
-- standalone body could not express because it had every run to choose from.
-- An operator still gets the installation's newest, which is what a diagnostic
-- is for.
--
-- A run id handed in goes through the same predicate rather than being trusted,
-- so naming somebody else's run returns no rows instead of their steps.
--
-- Declared in build-sql.py's DECLARED_SHADOWS, like the eight before it.
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
security definer
set search_path = pg_catalog, public
as $$
    with visible as (
        select r.id, r.created_at, r.workflow_def_id
          from workflow.runs r
         where rbac.is_operator() or workflow.may_access_run(r.id, 'select')
    ), r as (
        -- Runs point at a DEFINITION ID, not at a name: publishing v2 does not
        -- retarget a run that started under v1. So the newest run of "this
        -- workflow" is the newest run of any of its versions, which is what
        -- somebody asking about a name means.
        select coalesce(
            (select v.id from visible v where v.id = p_run_id),
            (select v.id from visible v
               join workflow.definitions d on d.id = v.workflow_def_id
              where d.name = p_name
              order by v.created_at desc limit 1)) as id
    )
    select t.step_key,
           t.status,
           t.attempts,
           t.completed_at - t.claimed_at,
           case jsonb_typeof(t.output->'result')
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

comment on function workflow.plan_status(text, uuid) is
$c$What the last run of this workflow actually did, per step.
Status, attempts, duration, and the SHAPE of what each step returned -- keys and
their types, or a row count -- which is the thing a plan cannot know and the
next step has to be written against. Scoped to the runs you may see: with no run
id it answers about YOUR newest run of this workflow.$c$;

-- ------------------------------------------------------------
-- AND THE OTHER FIVE ARE NOT GRANTED TO `authenticated` AT ALL, because they
-- cannot be honoured without publishing something §1 of this file refuses.
--
-- REM-81 was filed about plan_status alone, on the premise that its five
-- siblings "read only workflow.definitions, which `authenticated` can read, so
-- they work". Measured as `authenticated` on a live 0.2.0, all six refused:
--
--     plan_catalog  -> permission denied for table rate_limits
--     plan_graph    -> permission denied for table definitions
--     plan_document -> permission denied for table definitions
--     plan_defects  -> permission denied for table definitions
--     plan_probe    -> permission denied for table definitions
--     plan_status   -> permission denied for table tasks
--
-- `authenticated` holds no SELECT on workflow.definitions. §1 above says why,
-- and it is not an oversight to correct here: "definitions has no owner_id, no
-- org_id and no RLS, so every authenticated caller in every tenant would read
-- every workflow body." definitions_api exists precisely to publish the names
-- and shapes WITHOUT `spec` -- and `spec` is the entire input to plan_graph,
-- plan_document, plan_defects and plan_probe. There is no version of those
-- four over the published view; expanding a plan IS reading the body.
--
-- So the choice these five make is the other one REM-81 offers: not granted,
-- rather than granted and unusable. They stay operator diagnostics -- reachable
-- by app_owner and by a direct session, which is who has been running them --
-- and what would make them a tenant capability is workflow.definitions
-- adopting scope (`rbac.add_scope_columns` + `add_scope_policy`, the primitive
-- §1 already names), which is REM-42's work and REM-40's spec. Restoring the
-- grant is one line on the day that lands.
--
-- A grant that always raises is worse than no grant: the caller is told about
-- a table they have never heard of instead of being refused, and the surface
-- audit counts the capability as present. dev/tests/workflow/11 §8 now asserts
-- the rule this leaves behind -- every plan function granted to `authenticated`
-- answers for it -- which is a gate rather than a list, and goes green on its
-- own the day definitions adopts scope and the grants come back.
revoke execute on function workflow.plan_catalog()        from authenticated;
revoke execute on function workflow.plan_graph(text, int)    from authenticated;
revoke execute on function workflow.plan_document(text, int) from authenticated;
revoke execute on function workflow.plan_defects(text)       from authenticated;
revoke execute on function workflow.plan_probe(text, int)    from authenticated;
