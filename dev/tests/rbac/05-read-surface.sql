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
        -- The lifecycle vocabulary. One home for the words every status column
        -- references, identical for every tenant, and unreadable it would mean
        -- a caller could not name the state they are filtering on.
        'workflow.lifecycle_states'
    ];
begin
    select string_agg(n.nspname || '.' || c.relname, E'\n       ' order by 1)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'r'
       and n.nspname in ('rbac','workflow','aiq','content','agentic','wm')
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
insert into aiq.soft_nodes (claimed_kind, key, label, org_id, visibility, attrs) values
  ('company', 't-rs-org-a', 'A', 'a0000000-0000-0000-0000-00000000000a', 'org', '{"deal":"condor"}'),
  ('company', 't-rs-org-b', 'B', 'a0000000-0000-0000-0000-00000000000b', 'org', '{"deal":"heron"}'),
  ('company', 't-rs-shared', 'S', null, 'public', '{}');

do $$
declare v_n int; v_keys text;
begin
    set local role authenticated;
    perform set_config('request.jwt.claims',
        '{"sub":"22222222-2222-2222-2222-222222222222","orgs":["a0000000-0000-0000-0000-00000000000b"]}', true);

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
        'agentic.v_extractors'
    ];
begin
    select string_agg(n.nspname || '.' || c.relname, ', ' order by 1)
      into v_bad
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where c.relkind = 'v'
       and n.nspname in ('rbac','workflow','aiq','content','agentic','wm')
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
