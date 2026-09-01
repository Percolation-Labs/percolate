-- ============================================================================
-- workflow-engine: worker pools
--
-- Companion DDL for pools.md. A worker pool is a row: a consumer declares an
-- image, a resource shape and scale bounds, and percolate-core's manager
-- reconciles those rows into Kubernetes Deployments. KEDA does the scaling.
-- Nobody gets cluster credentials to do it.
--
-- ONE NAMESPACE. Pools are deployed into a single namespace the manager is
-- configured with (P8_POOL_NAMESPACE, default `percolate`), which the manager
-- verifies at startup and never creates. That is why there is no `tenant`
-- column and no namespace column here: there is no per-pool or per-consumer
-- namespace decision for a row to carry. Multi-namespace is a deferred
-- extension (pools.md §11), not a thing this schema is bent around in advance.
--
-- Load order: after schema.sql (references workflow.tasks) and after
-- user-rbac's roles.sql + rbac.current_user_id().
--
-- The RLS conventions here follow the ones established and empirically
-- verified in user-rbac's schema (ENABLE not FORCE, app_owner owns the tables,
-- current_user_id() wrapped in a scalar subquery so the planner hoists it into
-- an InitPlan instead of re-evaluating per row). Deviating would be deviating
-- from a design that took three rounds of live failure to get right.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Image policy -- deny by default
--
-- An empty table means no pool may be declared at all. The other default is
-- running an arbitrary image from an arbitrary registry inside the cluster,
-- which is not a default anyone would choose deliberately.
--
-- Flat, not per-tenant: with one namespace there is one trust boundary, and a
-- per-consumer allow-list would be pretending otherwise.
-- ----------------------------------------------------------------------------
create table workflow.pool_image_policy (
    id      bigint generated always as identity primary key,
    pattern text not null unique,   -- glob, e.g. 'ghcr.io/acme/*'
    note    text,
    added_by uuid references rbac.users(id),
    added_at timestamptz not null default now()
);

create or replace function workflow.pool_image_allowed(p_image text)
returns boolean
language sql stable as $$
    select exists (
        select 1 from workflow.pool_image_policy
        -- Escape LIKE's own metacharacters BEFORE turning '*' into '%', or
        -- 'ghcr.io/acme_prod/*' silently matches 'ghcr.io/acmeXprod/'.
        where p_image like replace(
                             replace(
                               replace(
                                 replace(pattern, '\', '\\'),
                               '%', '\%'),
                             '_', '\_'),
                           '*', '%') escape '\'
    );
$$;

-- ----------------------------------------------------------------------------
-- 2. Pools -- desired state, consumer-owned
--
-- Absent columns are as deliberate as present ones (pools.md §3.1):
--   no `namespace` / `tenant` -- manager configuration, not row data
--   no `replicas`            -- KEDA owns it; a desired-state row that also
--                               names a replica count guarantees a fight with
--                               the HPA
--   no `environment`         -- one Postgres cluster per environment, so these
--                               rows ARE that environment's desired state
--   no `dsn`                 -- injected by the manager from a Secret it
--                               controls; see the reserved-key trigger below
-- ----------------------------------------------------------------------------
create table workflow.pools (
    name          text primary key
                      -- RFC 1123 label, minus room for the 'p8-pool-' prefix
                      check (name ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),

    -- Set by trigger, not DEFAULT: a subquery is not legal in a DEFAULT
    -- expression. workflow.schedules hit this first (set_schedule_owner) and
    -- this gets that shape rather than a second one. The FK matches
    -- workflow.runs.owner_id -- without it a deleted user leaves pools nobody
    -- can edit under RLS but which the manager happily keeps reconciling.
    owner_id      uuid references rbac.users(id),

    image         text not null,
    command       text[] not null default array['worker'],

    min_replicas  int  not null default 0  check (min_replicas >= 0),
    max_replicas  int  not null default 10 check (max_replicas >= 1),

    cpu_request   text not null default '100m',
    cpu_limit     text not null default '1',
    mem_request   text not null default '256Mi',
    mem_limit     text not null default '1Gi',
    node_class    text not null default 'standard'
                      check (node_class in ('gpu','highmem','standard')),

    -- KEDA's targetQueryValue: tasks per replica. 1 means one pod per
    -- in-flight-or-waiting task, right for the common case where a task
    -- saturates a pod. Raise it for cheap, I/O-bound steps.
    tasks_per_replica int not null default 1 check (tasks_per_replica >= 1),

    -- Feeds BOTH terminationGracePeriodSeconds and cooldownPeriod, from one
    -- column, so the two cannot drift apart. They answer the same question:
    -- how long is a pod allowed to finish what it is holding?
    drain_seconds int not null default 300 check (drain_seconds between 30 and 3600),

    env           jsonb  not null default '{}',   -- non-secret only; filtered below
    secret_refs   text[] not null default '{}',   -- k8s Secret NAMES in the pool namespace

    enabled       boolean not null default true,

    -- Bumped by trigger on any change to the columns above. Status lives in a
    -- separate table precisely so writing status cannot bump this and schedule
    -- the reconcile that writes status again, forever.
    generation    bigint not null default 1,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    check (max_replicas >= min_replicas)
);

create index on workflow.pools (enabled) where enabled;

-- ----------------------------------------------------------------------------
-- 3. Queue binding
--
-- PRIMARY KEY on queue is the point: at most one pool serves a queue, enforced
-- by the database rather than by the manager. Two pools on one queue is not a
-- scaling strategy -- it is two ScaledObjects each computing a replica count
-- from a depth the other is also draining, which oscillates.
--
-- The reverse cardinality is open in the schema: one pool may bind several
-- queues. See pools.md §3.2 for why that is not yet usable -- the worker takes
-- a single --queue today.
-- ----------------------------------------------------------------------------
create table workflow.pool_queues (
    queue text primary key,
    pool  text not null references workflow.pools(name) on delete cascade
);

create index on workflow.pool_queues (pool);

-- Default 1:1 -- declaring a pool named `embed` binds queue `embed` unless the
-- consumer says otherwise. Convenience, not policy: delete the row and bind
-- something else.
create or replace function workflow.pools_bind_default_queue()
returns trigger language plpgsql as $$
begin
    insert into workflow.pool_queues (queue, pool)
    values (new.name, new.name)
    on conflict (queue) do nothing;
    return new;
end;
$$;

create trigger pools_bind_default_queue
    after insert on workflow.pools
    for each row execute function workflow.pools_bind_default_queue();

-- ----------------------------------------------------------------------------
-- 4. Observed state -- manager-owned, and the manager writes NOWHERE else
--
-- observed_generation < generation   -> the manager has not caught up
-- observed_generation = generation
--   with phase = 'error'             -> it caught up and Kubernetes refused
--
-- Different problems, different responses; a single status column cannot tell
-- them apart. That is the whole argument for carrying the pair.
-- ----------------------------------------------------------------------------
create table workflow.pool_status (
    pool                text primary key references workflow.pools(name) on delete cascade,
    observed_generation bigint,
    ready_replicas      int,
    desired_replicas    int,
    phase               text not null default 'pending'
                            check (phase in ('pending','applying','ready','degraded','error')),
    message             text,
    last_applied_at     timestamptz,
    last_error_at       timestamptz,
    updated_at          timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 5. Validation triggers
-- ----------------------------------------------------------------------------

-- 5a. Reserved environment keys.
--
-- The connection string is injected by the manager from a Secret it controls,
-- and it is the `worker` role -- which holds no table privileges at all
-- (user-rbac roles.sql §4). A consumer-settable P8_DSN would hand a
-- consumer-supplied image the ability to connect as whatever role it can name.
-- Enforced here AND again in the manager's renderer: a filter that exists in
-- one place is a filter that gets bypassed the first time someone adds a
-- second write path.
create or replace function workflow.pools_check_env()
returns trigger language plpgsql as $$
declare k text;
begin
    for k in select jsonb_object_keys(new.env) loop
        if k in ('P8_DSN','P8_ROLE','P8_SERVICE_ROLE','P8_WORKER_ID')
           or k like 'P8\_%\_SECRET'
        then
            raise exception 'pool %: environment key % is reserved and injected by the manager', new.name, k
                using errcode = 'check_violation';
        end if;
    end loop;
    return new;
end;
$$;

-- 5b. Image allow-list.
--
-- Fails at INSERT with a comprehensible message rather than as an
-- ImagePullBackOff the consumer cannot see. The cluster-side ResourceQuota and
-- PodSecurity admission still exist and are still what actually bound a pool;
-- this is the good error, not the boundary.
create or replace function workflow.pools_check_policy()
returns trigger language plpgsql as $$
begin
    if not workflow.pool_image_allowed(new.image) then
        raise exception 'image % is not permitted -- see workflow.pool_image_policy', new.image
            using errcode = 'check_violation';
    end if;
    return new;
end;
$$;

-- 5c. Generation bump + change notification.
--
-- Fires on the spec columns only. There is nothing to exclude here because
-- status lives in another table -- which is why it lives in another table.
create or replace function workflow.pools_bump_generation()
returns trigger language plpgsql as $$
begin
    if tg_op = 'UPDATE' then
        new.generation := old.generation + 1;
        new.updated_at := now();
    end if;
    -- Latency optimisation only. The manager's periodic resync is what makes
    -- convergence correct; a missed NOTIFY costs seconds, not consistency.
    -- Channel namespaced per meta/module-composition.md.
    perform pg_notify('p8_pool_changed', new.name);
    return new;
end;
$$;

-- 5d. DELETE must notify too.
--
-- Without this, deleting a pool removes the row and nothing tells the manager,
-- so the Deployment keeps running -- and keeps claiming tasks -- until the next
-- periodic resync happens to notice it. Deleting a pool is exactly the case
-- where waiting up to a resync interval is least acceptable, because the
-- reason people delete pools is usually that they want them to stop.
create or replace function workflow.pools_notify_delete()
returns trigger language plpgsql as $$
begin
    perform pg_notify('p8_pool_changed', old.name);
    return old;
end;
$$;

-- 5e. Ownership. Mirrors workflow.set_schedule_owner(): creating a pool is the
-- one action with no existing row to own, so any authenticated caller may do
-- it and this makes them its owner. An anonymous caller has no identity to own
-- it and is refused, which is what keeps `web_anon` out.
create or replace function workflow.set_pool_owner()
returns trigger language plpgsql as $$
begin
    if new.owner_id is null then
        new.owner_id := rbac.current_user_id();
    end if;
    if new.owner_id is null then
        raise exception 'a pool needs an owner -- no authenticated identity in this session'
            using errcode = 'insufficient_privilege';
    end if;
    return new;
end;
$$;

create trigger pools_set_owner       before insert on workflow.pools
    for each row execute function workflow.set_pool_owner();
create trigger pools_check_env       before insert or update on workflow.pools
    for each row execute function workflow.pools_check_env();
create trigger pools_check_policy    before insert or update on workflow.pools
    for each row execute function workflow.pools_check_policy();
create trigger pools_bump_generation before insert or update on workflow.pools
    for each row execute function workflow.pools_bump_generation();
create trigger pools_notify_delete   after delete on workflow.pools
    for each row execute function workflow.pools_notify_delete();

-- ----------------------------------------------------------------------------
-- 6. The scaler query -- MOVED
--
-- workflow.queue_depth(text) is no longer defined here. It lives in
-- workflow-engine/schema.sql, next to workflow.tasks, and ships in the
-- extension.
--
-- It moved because it turned out not to be a pool's function at all. The Helm
-- chart in get-percolate autoscales on queue depth with no manager and no
-- pools table anywhere, and its KEDA trigger could not read the number: as
-- `worker` it got `permission denied for table tasks`, and once granted that,
-- `permission denied for table runs` -- the RLS policy on tasks reads runs.
-- Two tables, to answer one number, for a credential the KEDA operator holds
-- across every namespace it serves.
--
-- So the thing on the other end of queue_depth() is any autoscaler at all, not
-- this file's manager, and it belongs with the queue it counts. What stays
-- here is everything that genuinely presumes a manager.
--
-- The reasoning about WHAT it counts -- `running` as well as claimable-`ready`,
-- because a pool of pods mid-task must not read as idle -- is unchanged and now
-- lives with the function. pools.md §6.1 is still where the argument is made.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- 7. Operational views
-- ----------------------------------------------------------------------------

-- Desired and observed, joined -- what a human or an agent actually reads.
create or replace view workflow.v_pools as
select p.name, p.image, p.enabled,
       p.min_replicas, p.max_replicas, p.node_class,
       p.generation,
       s.observed_generation,
       (s.observed_generation is distinct from p.generation) as reconcile_pending,
       s.phase, s.ready_replicas, s.desired_replicas, s.message,
       s.last_applied_at,
       array(select queue from workflow.pool_queues where pool = p.name) as queues
from workflow.pools p
left join workflow.pool_status s on s.pool = p.name;

-- For a postgres_exporter custom query (KEDA's scaler needs one row, one
-- number, so it calls queue_depth directly rather than reading this).
create or replace view workflow.v_pool_depth as
select pq.pool, pq.queue, workflow.queue_depth(pq.queue) as depth
from workflow.pool_queues pq;

-- Queues with tasks and no pool to run them.
--
-- NOT "otherwise invisible" -- v_stuck_tasks already catches ready tasks older
-- than five minutes, so unserved work surfaces on the alerting path that
-- already exists. What v_stuck_tasks cannot say is WHY: "stuck" is the same
-- signal for no pool, crash-looping pods, a pool pinned at max_replicas, and a
-- pool whose namespace is over quota. Four causes, four different responses.
-- This view discriminates between them; it does not make an invisible thing
-- visible.
--
-- Deliberately NOT a constraint on workflow.definitions: definitions and pool
-- declarations have independent lifecycles and independent authors, so
-- rejecting a definition whose queue has no pool yet would impose an ordering
-- between two things people edit separately. validate_spec() rejects what is
-- permanently wrong; an unserved queue is temporarily unserved.
create or replace view workflow.v_unserved_queues as
select t.queue,
       count(*) filter (where t.status = 'ready')   as ready_tasks,
       count(*) filter (where t.status = 'running') as running_tasks,
       min(t.created_at)                            as oldest_task
from workflow.tasks t
left join workflow.pool_queues pq on pq.queue = t.queue
where pq.queue is null
  and t.status in ('ready','running')
  -- `sql` steps execute inside Postgres and need no pool, so their queue
  -- having none is not a finding.
  and t.kind <> 'sql'
group by t.queue;

-- ----------------------------------------------------------------------------
-- 8. The manager's only write
--
-- SECURITY DEFINER so pool_manager needs no table grant, matching how every
-- other service role in this collection reaches the database.
-- ----------------------------------------------------------------------------
create or replace function workflow.report_pool_status(
    p_pool             text,
    p_generation       bigint,
    p_phase            text,
    p_ready_replicas   int  default null,
    p_desired_replicas int  default null,
    p_message          text default null
) returns void
language sql security definer set search_path = workflow, pg_catalog as $$
    insert into workflow.pool_status
        (pool, observed_generation, phase, ready_replicas, desired_replicas, message,
         last_applied_at, last_error_at, updated_at)
    values
        (p_pool, p_generation, p_phase, p_ready_replicas, p_desired_replicas, p_message,
         case when p_phase in ('ready','applying') then now() end,
         case when p_phase = 'error' then now() end,
         now())
    on conflict (pool) do update set
        observed_generation = excluded.observed_generation,
        phase               = excluded.phase,
        ready_replicas      = excluded.ready_replicas,
        desired_replicas    = excluded.desired_replicas,
        message             = excluded.message,
        last_applied_at     = coalesce(excluded.last_applied_at, workflow.pool_status.last_applied_at),
        last_error_at       = coalesce(excluded.last_error_at,   workflow.pool_status.last_error_at),
        updated_at          = now();
$$;

-- ----------------------------------------------------------------------------
-- 9. Roles and grants
--
-- pool_manager gets SELECT on desired state and EXECUTE on one function. It
-- gets NO write on workflow.pools, and that omission is load-bearing: a
-- compromised manager cannot rewrite desired state to make its own actions
-- look correct, and the desired/observed split stays real rather than
-- cosmetic.
--
-- keda_scaler is separate from `worker` on purpose. The scaler's credential
-- lives in a KEDA ClusterTriggerAuthentication readable by the KEDA operator
-- across namespaces; a worker credential in that position would be a
-- task-claiming credential in that position.
-- ----------------------------------------------------------------------------
create role pool_manager nologin;
create role keda_scaler  nologin;

grant usage on schema workflow to pool_manager, keda_scaler;

grant select on workflow.pools, workflow.pool_queues to pool_manager;
grant select on workflow.v_pools, workflow.v_unserved_queues to pool_manager;
grant execute on function workflow.report_pool_status(text,bigint,text,int,int,text) to pool_manager;

-- Exactly one function, and nothing else.
grant execute on function workflow.queue_depth(text) to keda_scaler;

-- Consumers reach pools as themselves, through PostgREST, under RLS.
grant select, insert, update, delete on workflow.pools       to authenticated;
grant select, insert, update, delete on workflow.pool_queues to authenticated;
grant select on workflow.pool_status, workflow.v_pools, workflow.v_unserved_queues,
                workflow.pool_image_policy to authenticated;

-- ----------------------------------------------------------------------------
-- 10. RLS
--
-- ENABLE, not FORCE -- user-rbac's schema documents at length why FORCE breaks
-- the SECURITY DEFINER trusted path, and the same applies to
-- report_pool_status(). Ownership separation is what makes the read path safe,
-- not a policy flag.
--
-- Every predicate wraps current_user_id() in a scalar subquery so the planner
-- produces one InitPlan rather than inlining the call into a per-row Filter.
-- STABLE alone does not make it hoist; that was measured, not assumed.
--
-- Read is deliberately WIDE: one namespace means one operational surface, and
-- an operator who cannot see a pool cannot diagnose the queue it is failing to
-- drain. Write is narrow -- owner, or an explicit permission, mirroring
-- workflow.schedules exactly.
-- ----------------------------------------------------------------------------
alter table workflow.pools       enable row level security;
alter table workflow.pool_queues enable row level security;
alter table workflow.pool_status enable row level security;

create policy pools_read on workflow.pools
    for select to authenticated
    using (true);

create policy pools_write on workflow.pools
    for all to authenticated
    using      (owner_id = (select rbac.current_user_id())
                or (select rbac.has_permission(rbac.current_user_id(), 'workflow_pools', 'update')))
    with check (owner_id = (select rbac.current_user_id())
                or (select rbac.has_permission(rbac.current_user_id(), 'workflow_pools', 'update')));

create policy pool_queues_read on workflow.pool_queues
    for select to authenticated using (true);

create policy pool_queues_write on workflow.pool_queues
    for all to authenticated
    using (pool in (select name from workflow.pools
                    where owner_id = (select rbac.current_user_id())))
    with check (pool in (select name from workflow.pools
                         where owner_id = (select rbac.current_user_id())));

create policy pool_status_read on workflow.pool_status
    for select to authenticated using (true);

-- pool_manager reads desired state for every pool -- it is the cluster's
-- reconciler, not a consumer.
create policy pools_manager_read       on workflow.pools       for select to pool_manager using (true);
create policy pool_queues_manager_read on workflow.pool_queues for select to pool_manager using (true);
