-- ============================================================
-- Cluster-level roles for this spec collection.
--
-- Applied ONCE, by a superuser/DBA, BEFORE any schema.sql in this
-- collection. Separate from schema.sql deliberately, not for tidiness:
--
--   * Roles are CLUSTER-level objects, shared by every database in the
--     cluster; schemas/tables/policies are database- and schema-level.
--     Different scope, different lifecycle -- a second database in the
--     same cluster reuses these roles rather than re-creating them.
--   * A non-superuser cannot CREATE ROLE (no CREATEROLE attribute), and
--     user-rbac/schema.sql REFUSES to load as a superuser (its own
--     assertion block: a superuser-owned view silently bypasses RLS for
--     every caller -- confirmed empirically against PG19 beta3). So role
--     creation structurally cannot live in the same file as the schema.
--     That's a correct boundary, not an inconvenience to engineer around.
--
-- Apply as superuser:  psql -v ON_ERROR_STOP=1 -f roles.sql
-- Then apply the schemas as app_owner (NOT as a superuser -- schema.sql
-- refuses to load as one):
--     psql -c 'set role app_owner;' -f ../workflow-engine/schema.sql
--     psql -c 'set role app_owner;' -f schema.sql
-- ============================================================

-- ------------------------------------------------------------
-- 1. Schema owner -- owns every table and function in this collection.
--    MUST NOT be a superuser: superusers bypass RLS unconditionally,
--    so a superuser here makes every RLS guarantee in this collection
--    inert. Confirmed the hard way -- a non-admin user read every row
--    through users_api with correct policies in place, purely because
--    the owner was a superuser.
--
--    app_owner DOES bypass RLS on its own tables, deliberately: RLS is
--    ENABLEd but not FORCEd, so the SECURITY DEFINER functions (owned
--    by app_owner) can write, and can read during login before any JWT
--    exists. That is the trusted path, and it is exactly what SECURITY
--    DEFINER is for. The untrusted path is api_viewer, below.
-- ------------------------------------------------------------
create role app_owner nologin;

-- ------------------------------------------------------------
-- 2. View owner -- owns ONLY the *_api views, and must be a DIFFERENT
--    role from app_owner. This separation is what makes RLS actually
--    enforce on the read path, and it is not a stylistic choice:
--
--      * The *_api views are owner-privileged (NOT security_invoker --
--        that was tried and re-requires base-table grants, defeating
--        the point). So a read through a view evaluates RLS as the
--        VIEW's owner, not the querying role.
--      * If the view owner were also the table owner, that read would
--        bypass RLS entirely (owners bypass, absent FORCE) and every
--        caller would see every row.
--      * FORCE ROW LEVEL SECURITY looks like the fix for that, but it
--        breaks the other side: FORCE also subjects the SECURITY
--        DEFINER functions to RLS, and with no JWT during signup/login
--        they are denied -- signup, login, token issuance and audit
--        writes ALL fail. Confirmed empirically against PG19 beta3.
--      * Splitting the owners resolves both at once, with no FORCE:
--        app_owner (table owner) bypasses RLS on the trusted function
--        path; api_viewer (non-owner) is subject to RLS on the read
--        path, filtered per-request by current_user_id().
--
--    api_viewer must also not be a superuser, for the same reason
--    app_owner must not be.
-- ------------------------------------------------------------
create role api_viewer nologin;

-- app_owner creates the views (it owns the schema) and then hands them to
-- api_viewer. Postgres requires the role doing an ALTER ... OWNER TO to be a
-- member of the target role, so this grant is what makes schema.sql's
-- `alter view ... owner to api_viewer` legal. It does NOT let api_viewer do
-- anything as app_owner -- membership only flows in the direction granted.
grant api_viewer to app_owner;

-- ------------------------------------------------------------
-- 3. PostgREST's role model (user-rbac/spec.md §2, schema.sql §9).
--    web_anon: unauthenticated requests. authenticated: valid JWT.
--    authenticator: what PostgREST's db-uri actually connects as; it
--    holds no privileges of its own and SWITCHES INTO one of the other
--    two per request (hence noinherit -- without it, authenticator
--    would hold both roles' privileges simultaneously at all times,
--    defeating the separation).
-- ------------------------------------------------------------
create role web_anon nologin;
create role authenticated nologin;
create role authenticator noinherit login;
grant web_anon to authenticator;
grant authenticated to authenticator;

-- The authenticator LOGIN password belongs in deployment config, never
-- in a checked-in file:
--     alter role authenticator with password '<from your secret store>';

-- ------------------------------------------------------------
-- 4. Workflow-engine roles (workflow-engine/schema.sql §16).
--
--    worker: what a KEDA-scaled task worker connects as. It holds NO table
--    privileges at all -- every interaction is a SECURITY DEFINER function
--    call (claim/heartbeat/complete/fail). That is not minimalism for its
--    own sake: granting a worker direct table access was prototyped, and it
--    required SELECT/UPDATE on tasks, INSERT on task_events, SELECT on
--    task_dependencies, SELECT/UPDATE on runs, and EXECUTE on
--    rbac.current_user_id() -- including write access to the audit log that
--    audits it, which it could then forge entries in.
--
--    scheduler: what pg_cron (or an operator) runs maintenance as --
--    workflow.tick(), promote_due_timers(), reap_stale_tasks(). Separated
--    from worker because "run the state machine" and "sweep stale state" are
--    different jobs with different blast radii, and a worker should not be
--    able to reap.
--
--    Neither may be a superuser, for the same reason as every other role
--    here. Both are NOLOGIN here: real deployments grant them to a LOGIN role
--    whose credential lives in deployment config.
--
--    One caveat worth stating because it costs an hour to rediscover:
--    pg_cron does not run a job inside the server, it opens a libpq
--    CONNECTION as the job's username. A NOLOGIN scheduler therefore produces
--    "cron job N connection failed" in the server log once a minute -- the
--    job is registered, active, and silently doing nothing. A deployment that
--    drives the clock with pg_cron must give this role LOGIN (dev/ does, over
--    loopback); one that drives tick() from outside does not.
-- ------------------------------------------------------------
create role worker nologin;
create role scheduler nologin;

-- ------------------------------------------------------------
-- 5. The worker-pool control plane's two roles.
--
--    They live here rather than in workflow-engine/pools.sql for the reason
--    §1 of this file gives and pools.sql could not obey: a schema file loads
--    as app_owner, app_owner has no CREATEROLE, and `create role` inside it
--    therefore fails on every clean install. Found by loading pools.sql
--    against the dev stack -- "permission denied to create role", after
--    every table in the file had already been created.
--
--    pool_manager: what percolate-core's manager connects as. SELECT on
--    desired state, EXECUTE on report_pool_status(), and deliberately NO
--    write on workflow.pools -- so a compromised manager cannot rewrite
--    desired state to make its own actions look correct, and the
--    desired/observed split stays real rather than cosmetic.
--
--    keda_scaler: what KEDA's Postgres scaler connects as, holding EXECUTE
--    on workflow.queue_depth(text) and nothing else. Separate from `worker`
--    on purpose: the scaler's credential lives in a KEDA
--    ClusterTriggerAuthentication that the operator reads across every
--    namespace it serves, and a worker credential in that position is a
--    task-claiming credential in that position.
--
--    The grants themselves stay in pools.sql, beside the objects they name.
--    Only the CREATE ROLE moves, which is the half that needs a superuser.
-- ------------------------------------------------------------
create role pool_manager nologin;
create role keda_scaler  nologin;

