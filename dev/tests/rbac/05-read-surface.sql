-- WHAT AN APPLICATION ROLE CAN READ, ENUMERATED -- because a table with no
-- policy is invisible to the test that checks policies.
--
-- `02-rls-is-actually-on.sql` §3 walks every table that HAS a policy and
-- asserts RLS is enabled on it. That is the right assertion and it has a hole
-- the shape of the thing it is for: a table with no policy at all never enters
-- the loop, so "nobody wrote a policy" and "the policy is inert" look
-- completely different to that test and identical to a tenant.
--
-- Found by enumerating instead. `aiq.soft_nodes` and `aiq.lake_nodes` carry
-- `org_id`, are granted SELECT to `authenticated`, and had no policy:
--
--   org B, through aiq.nodes    -> 1 row   (its own)
--   org B, from aiq.soft_nodes  -> 2 rows  (both, with key, label and attrs)
--
-- and those are extracted entity NAMES before resolution. The grant sat under
-- a comment explaining that the three functions above it are SECURITY INVOKER
-- "so a user calling them is filtered by their own policies", which was true
-- of the functions and never of the table.
--
-- `agentic/schema.sql` §7 already makes the argument this file turns into a
-- check: "no policy reads as an oversight, a policy that says `true` reads as a
-- decision". Sections 1 and 2 below make every table and every view state which
-- one it is.
--
-- "Every" is percolate.extension_schemas(). All three sections here named `wm`,
-- which does not exist, and not `percolate` (REM-45).

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- 1. EVERY READABLE TABLE EITHER HAS A POLICY OR IS NAMED SHARED CONFIG.
--
-- The list is the deliverable. Each entry is a decision that this table's rows
-- are the same for every tenant -- a catalogue, a registry, or the schema
-- document -- and a table that is none of those does not belong on it.
-- ---------------------------------------------------------------------
do $$
declare
    v_bad text;
    -- Shared by decision, with the tier each one belongs to.
    v_shared text[] := array[
        -- The relation and entity catalogues. aiq.edges refuses an
        -- out-of-catalogue relation, so every tenant reads the same vocabulary
        -- or cannot write an edge at all.
        'aiq.relation_types', 'aiq.graph_vocabulary', 'aiq.entity_registry',
        -- This database's own catalogue -- functions, tables, columns, roles.
        -- It carries no org_id on purpose: a schema is one shared fact about
        -- the installation, not a per-tenant one, and there is no sense in
        -- which `aiq.edges` belongs to an org. Anybody connected can already
        -- ask pg_catalog the same questions more slowly.
        'aiq.db_objects',
        -- The retrieval registries: which corpora and models exist. Naming a
        -- model is not reading anyone's data.
        'aiq.embedding_models', 'aiq.embedding_providers',
        'aiq.lexical_sources', 'aiq.semantic_sources',
        -- The SCHEMA document itself, which exists to be read before you know
        -- anything -- a per-tenant capability document would defeat it.
        'aiq.schema_examples', 'aiq.schema_facets', 'aiq.schema_revisions',
        -- Role and permission vocabulary. user-rbac/schema.sql calls these
        -- "reference/catalog data, not per-row sensitive" at the grant.
        'rbac.roles', 'rbac.role_permissions', 'rbac.permission_kinds',
        -- The allow-list a `sql` step may call. Registering is owner-only;
        -- reading the list is how an author knows what they may name.
        'workflow.step_functions',
        -- The queue registry: names, stale timeout, rate lookahead. Three
        -- knobs per queue and no tenant column -- a queue is a property of the
        -- installation, not of an org, and workflow.plan_catalog() (granted to
        -- authenticated, SECURITY INVOKER) reads it to say which queues a step
        -- may name. The DEPTH of a queue is a different question and goes
        -- through queues_api, whose queue_depth() is SECURITY DEFINER.
        'workflow.queue_config',
        -- The lifecycle vocabulary. One home for the words every status column
        -- references, identical for every tenant, and unreadable it would mean
        -- a caller could not name the state they are filtering on.
        'workflow.lifecycle_states',
        -- The published contract's declared payload shapes, compiled in from
        -- specs/contract/types and granted to web_anon by design: a client
        -- learns what it would have to send before it has credentials. This
        -- file could not see it while its schema list lacked `percolate`.
        'percolate.types',
        -- Plans, resource kinds, plan limits, application declarations and
        -- scope aliases (research-platform/schema.sql §1-2): installation
        -- vocabulary with no tenant column, readable so a caller can see what
        -- a plan allows. Who holds which plan is plan_assignments, which is policied.
        'rbac.plans', 'rbac.resource_kinds', 'rbac.plan_limits', 'rbac.applications', 'rbac.scope_aliases'
    ];
begin
    select string_agg(n.nspname || '.' || c.relname, E'\n       ' order by 1)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r'
       and n.nspname in (select percolate.extension_schemas())
       and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
       and (has_table_privilege('authenticated', c.oid, 'select')
            or has_table_privilege('web_anon', c.oid, 'select'))
       and n.nspname || '.' || c.relname <> all (v_shared)
       -- Embedding spaces are created dynamically by register_embedding_space,
       -- so they cannot be listed by name. They hold (chunk_id, vector) and no
       -- tenant column; query/09 records the residue -- reading a space
       -- directly returns rows the mode would filter -- as documented rather
       -- than fixed, because the vector is keyed by a chunk id the caller
       -- still cannot resolve through any policied table.
       and c.relname not like 'emb\_%';

    if v_bad is not null then
        raise exception
            E'these tables are readable by an application role and have no policy:\n       %\n\n'
            'Either give it a policy, or add it to this file''s shared-config '
            'list with the tier it belongs to. A table with no policy is '
            'invisible to rbac/02 §3, which walks only tables that have one -- '
            'so "nobody wrote a policy" and "the policy is inert" look '
            'different to that test and identical to a tenant.', v_bad;
    end if;
    raise notice 'rbac/05: every readable table has a policy or is declared shared config';
end $$;

-- ---------------------------------------------------------------------
-- 1b. AND THE MIRROR: EVERY READ POLICY HAS A READER.
--
-- Section 1 asks "readable, with no policy". This asks "policy, with no
-- reader", and the two are not the same question. Section 1 enumerates what a
-- client role can already see, so a table NOBODY can see never enters its loop
-- -- which means "nobody granted it" and "correctly locked down" are
-- indistinguishable to every check in this repository. rbac/10 does not close
-- it either: it walks `permission_kinds.checked_by` and asserts the named
-- policy EXISTS, and an unreachable policy exists perfectly well.
--
-- MEASURED, which is why this is a list of three and not of sixteen.
-- `rbac.orgs` and `rbac.org_members` each carried a correct SELECT policy
-- written for `current_org_ids()`, and SELECT was held only by `api_viewer` --
-- which is NOLOGIN and exists to own the *_api views. There is no orgs_api
-- view, so no role that could log in could reach either table by any path, and
-- a member asking "which organisations am I in?" got `permission denied`. Both
-- policies had been dormant since they were written.
--
-- The naive form of this check returns SIXTEEN tables, because `users`,
-- `refresh_tokens`, `runs`, `tasks`, `sessions` and the rest are legitimately
-- reached through an *_api view or a SECURITY DEFINER function. Excluding
-- tables that back a view a client role may select brings it to the real set --
-- and a lint that reports sixteen when three are wrong is one people learn to
-- skim, which is the failure this file exists to avoid.
-- ---------------------------------------------------------------------
do $$
declare
    v_bad text;
    -- Declared, with the reason, exactly as §1's shared-config list is. An
    -- entry here says "no client role may read this and that is the design",
    -- which is a decision somebody made rather than a grant somebody forgot.
    v_no_reader_by_design text[] := array[
        -- Reset tokens are written by request_password_reset and consumed by
        -- reset_password, both SECURITY DEFINER. A caller who could read this
        -- table could redeem somebody else's reset; the policy on it is
        -- defence in depth behind a grant that must never exist.
        'rbac.password_reset_tokens'
    ];
begin
    with reachable_via_view as (
        -- A table is legitimately unreadable when a view over it is readable:
        -- that is the *_api pattern, where the view owner holds the grant and
        -- RLS still applies through it.
        select distinct dep.refobjid as tbl
          from pg_depend dep
          join pg_rewrite r on r.oid = dep.objid
          join pg_class v on v.oid = r.ev_class
         where dep.classid = 'pg_rewrite'::regclass
           and dep.refclassid = 'pg_class'::regclass
           and v.relkind = 'v'
           and (has_table_privilege('authenticated', v.oid, 'select')
                or has_table_privilege('web_anon', v.oid, 'select'))
    )
    select string_agg(n.nspname || '.' || c.relname, E'\n       ' order by 1)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r'
       and n.nspname in (select percolate.extension_schemas())
       and exists (select 1 from pg_policy p
                    where p.polrelid = c.oid and p.polcmd in ('r','*'))
       and not has_table_privilege('authenticated', c.oid, 'select')
       and not has_table_privilege('web_anon', c.oid, 'select')
       and c.oid not in (select tbl from reachable_via_view)
       and n.nspname || '.' || c.relname <> all (v_no_reader_by_design);

    if v_bad is not null then
        raise exception
            E'these tables carry a read policy that no client role can reach:\n       %\n\n'
            'The policy is dormant and nothing else in this repository will say '
            'so -- §1 above only walks tables a client role can already read, '
            'and rbac/10 only asserts the named policy exists. Either grant '
            'SELECT to the role the policy was written for, or add it to this '
            'block''s list with the reason it must have no reader.', v_bad;
    end if;
    raise notice 'rbac/05: every read policy is reachable by the role it was written for';
end $$;

-- ---------------------------------------------------------------------
-- 2. AND THE TWO REFERENCE TABLES ARE SCOPED, ASSERTED BY READING THEM.
--
-- Section 1 would catch the missing policy. This catches a policy that is
-- present and wrong, which is the failure a catalogue check cannot see.
-- ---------------------------------------------------------------------
begin;

-- visibility is stated per row, because the fixture is now saying two things
-- that `org_id` alone used to conflate. The shared row is `public` BECAUSE
-- SOMEBODY DECIDED IT IS, not because its org happens to be null -- which is
-- the change scope makes, and the reason the row below had to grow a column.
--
-- And the shared row now NAMES its tier: rbac.shared_org_id() rather than
-- null. org_id is NOT NULL (specs/identity/spec.md §4), so "shared" is a value
-- this fixture states rather than an absence a reader has to interpret.
insert into aiq.soft_nodes (claimed_kind, key, label, org_id, visibility, attrs) values
  ('company', 't-rs-org-a', 'A', 'a0000000-0000-0000-0000-00000000000a', 'org', '{"deal":"condor"}'),
  ('company', 't-rs-org-b', 'B', 'a0000000-0000-0000-0000-00000000000b', 'org', '{"deal":"heron"}'),
  ('company', 't-rs-shared', 'S', rbac.shared_org_id(), 'public', '{}');

do $$
declare v_n int; v_keys text;
begin
    set local role authenticated;
    execute format('set local request.jwt.claims = %L', '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}');

    select count(*), coalesce(string_agg(key, ', ' order by key), '')
      into v_n, v_keys
      from aiq.soft_nodes where key like 't-rs-%';

    reset role;

    -- Its own row and the shared one; never the other tenant's.
    if v_n <> 2 or v_keys <> 't-rs-org-b, t-rs-shared' then
        raise exception
            'org B reads % row(s) from aiq.soft_nodes (%) where it should read '
            'its own and the shared one. These hold extracted entity names '
            'before resolution, and the projection registers them with '
            'p_org_expr => n.org_id precisely so the node they become is '
            'scoped -- a direct read must not go round that.', v_n, v_keys;
    end if;
    raise notice 'rbac/05: the reference tables are org-scoped when read directly (%)', v_keys;
end $$;

rollback;

-- ---------------------------------------------------------------------
-- 3. EVERY VIEW IS EITHER READABLE BY SOMEBODY OR DELIBERATELY OPERATOR-ONLY.
--
-- `agentic.agents_pickable` had no grant at all. brief.md calls it "the view an
-- interactive UI reads" and quotes a verification of its behaviour -- run as
-- the owner, in a privilege context no UI has. `authenticated` and
-- `api_viewer` both got "permission denied for view agents_pickable".
--
-- The operator views are the other half and are owner-only on purpose:
-- workflow/12 asserts that a caller cannot read them. So the check is not
-- "everything must be granted" -- it is that each view says which it is.
-- ---------------------------------------------------------------------
do $$
declare
    v_bad text;
    v_operator_only text[] := array[
        -- workflow/12: "the operator views and the plan gate are not readable
        -- by a caller". Queue depth, capacity and stuck work are a deployment's
        -- health, not a tenant's data.
        'workflow.v_backlog', 'workflow.v_capacity', 'workflow.v_queue_depth',
        'workflow.v_run_progress', 'workflow.v_stuck_tasks',
        'workflow.v_unclaimable', 'workflow.v_lease_violations',
        'workflow.v_decision_history', 'workflow.v_compensation_status',
        -- The extractor fleet as an operations surface, mirroring the shape
        -- content.v_connectors will have when connectors.sql ships.
        'agentic.v_extractors',
        -- auth_events counted by kind over the last day. The base table IS
        -- granted to `authenticated` and carries auth_events_self_or_admin, so
        -- a caller already has the read this view would look like -- their own
        -- rows. This one is read as the owner and counts everybody's, which is
        -- the only way to see credential stuffing at all and the reason it is
        -- granted to nobody. user-rbac/schema.sql's section 10 self-check
        -- refuses the grant at load time as well as here.
        'rbac.v_auth_activity',
        -- identity/schema.sql's guess at each table's kind, for whoever is
        -- writing percolate.table_kinds rows: a tool for the schema's author,
        -- not a read surface. Unseen here until this file read `percolate`.
        'percolate.table_kind_proposal'
    ];
begin
    select string_agg(n.nspname || '.' || c.relname, ', ' order by 1)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'v'
       and n.nspname in (select percolate.extension_schemas())
       and not exists (select 1 from aclexplode(c.relacl) a
                        where a.grantee <> c.relowner and a.privilege_type = 'SELECT')
       and n.nspname || '.' || c.relname <> all (v_operator_only);

    if v_bad is not null then
        raise exception
            'these views can be read only by their owner: %. A view documented '
            'as a read surface and granted to nobody is a surface that works '
            'in psql and nowhere else. Grant it, or add it to this file''s '
            'operator-only list.', v_bad;
    end if;
    raise notice 'rbac/05: every view is granted to a caller or declared operator-only';
end $$;
