-- ============================================================
-- ai-query-layer <-> user-rbac integration.
--
-- Applied AFTER ai-query-layer/schema.sql and user-rbac/schema.sql, as
-- app_owner. Split out for the same reason workflow-engine's equivalent is:
-- the core query layer must stay deployable with no identity system at all,
-- and everything that crosses the boundary belongs in one file applied last.
--
-- Round 3 established what makes this dangerous to get wrong, so it is worth
-- restating rather than assuming the reader remembers:
--   * A view owned by the TABLE owner bypasses RLS entirely -> every caller
--     sees every row.
--   * FORCE ROW LEVEL SECURITY "fixes" that and breaks all writes, because
--     the trusted SECURITY DEFINER path runs as the table owner too.
--   * The resolution is ownership separation (app_owner owns tables and
--     functions; api_viewer owns only the *_api views), never a policy flag.
-- The same shape is applied here.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Tenant scoping.
--
-- nodes/node_keys/edges already carry org_id. The rule, stated once:
--   org_id IS NULL  -> shared reference data, visible to everyone
--   org_id = <uuid> -> visible only to members of that org
--
-- "Shared reference data" is a real category here, not a loophole: a public
-- SEC filing or a well-known company is legitimately global, and forcing it
-- to be duplicated per tenant would defeat the whole point of one identity
-- registry (graph-identity.md "Node registry", org_id "null = shared").
--
-- Membership lives in rbac. This layer does not invent a second notion of
-- tenancy -- it asks the one that already exists.
-- ------------------------------------------------------------

-- user-rbac has no org model yet (specs/README.md scope decisions defer
-- tenant/org management deliberately). Rather than invent one here, the
-- predicate is expressed against a single function that a real deployment
-- replaces. Shipping a permissive default silently would be the worst option;
-- this one is explicit about being a seam, and errs closed for org-scoped rows
-- when no membership source exists.
-- Returns SETOF rather than an array, deliberately: `org_id = any (select ...)`
-- against an array-returning function compares uuid to uuid[] and fails, while
-- the array form `= any (f())` gives up the InitPlan hoisting that
-- user-rbac/schema.sql §9 measured as the difference between evaluating a
-- predicate once per query and once per row scanned. SETOF gives both --
-- `in (select ...)` type-checks and plans as a hashed SubPlan.
create or replace function aiq.current_org_ids() returns setof uuid as $$
    -- Reads the same request-scoped GUC mechanism as rbac.current_user_id():
    -- PostgREST sets request.jwt.claims per request, so an org claim rides in
    -- the verified token rather than being supplied as a spoofable argument.
    select (value #>> '{}')::uuid
    from jsonb_array_elements(
        coalesce(
            nullif(current_setting('request.jwt.claims', true), '')::jsonb -> 'orgs',
            '[]'::jsonb
        )
    );
$$ language sql stable;

alter table aiq.nodes     enable row level security;
alter table aiq.node_keys enable row level security;
alter table aiq.edges     enable row level security;

-- (select ...) wrapping for InitPlan caching, same as every other RLS policy
-- in this collection -- current_org_ids() is STABLE but that alone does not
-- get it hoisted (user-rbac/schema.sql §9's EXPLAIN finding).
create policy nodes_org_scoped on aiq.nodes for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));
create policy node_keys_org_scoped on aiq.node_keys for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));
create policy edges_org_scoped on aiq.edges for select
  using (org_id is null or org_id in (select aiq.current_org_ids()));

-- ------------------------------------------------------------
-- 2. Read path: views owned by api_viewer, exactly as user-rbac does.
--    A view owned by app_owner would bypass the policies above.
-- ------------------------------------------------------------
create view aiq.nodes_api as
  select id, entity_type, entity_id, org_id, summary, created_at, updated_at
  from aiq.nodes;
create view aiq.edges_api as
  select id, src_id, dst_id, relation, weight, valid_from, valid_to, org_id, created_at
  from aiq.edges;

grant usage on schema aiq to api_viewer, authenticated;
grant select on aiq.nodes, aiq.node_keys, aiq.edges to api_viewer;
grant execute on function aiq.current_org_ids() to api_viewer, authenticated;

grant create on schema aiq to api_viewer;
alter view aiq.nodes_api owner to api_viewer;
alter view aiq.edges_api owner to api_viewer;
revoke create on schema aiq from api_viewer;

grant select on aiq.nodes_api, aiq.edges_api to authenticated;

-- ------------------------------------------------------------
-- 3. Query functions: deny by default, then grant the entry points.
--
-- aiq.query() and the per-mode functions are deliberately left SECURITY
-- INVOKER. This is the opposite call from workflow-engine, and the difference
-- is the point: workflow's mutators run on behalf of a WORKER that has no
-- user identity and must bypass RLS to do its job. These are READ paths run
-- on behalf of a USER, so they must be subject to that user's RLS -- making
-- them SECURITY DEFINER would silently return every tenant's rows, which is
-- precisely the bug the ownership split exists to prevent.
-- ------------------------------------------------------------
revoke execute on all functions in schema aiq from public;

grant execute on function aiq.query(text, vector) to authenticated;
grant execute on function aiq.lookup(text, boolean, int) to authenticated;
grant execute on function aiq.graph_neighbors(uuid, text, int) to authenticated;
grant execute on function aiq.graph_walk(uuid, int, text, int) to authenticated;
grant execute on function aiq.semantic_in(vector, text, int) to authenticated;
grant execute on function aiq.lexical(text, text, int) to authenticated;
grant execute on function aiq.hybrid(text, text, vector, text, int, int) to authenticated;
grant execute on function aiq.sql_passthrough(text) to authenticated;

-- Registry reads: an agent needs to know which models and sources exist to
-- form a valid query at all. Read-only, no row-level sensitivity.
grant select on aiq.embedding_models, aiq.lexical_sources,
                aiq.semantic_sources, aiq.relation_types to authenticated;

-- Registration and projection are ADMIN operations, not user operations, and
-- stay owner-only: register_entity_table() and register_embedding_space()
-- execute DDL built from their arguments, so exposing them to `authenticated`
-- would be a SQL-injection surface with DDL privileges attached. Not granted
-- to anyone; a deployment runs them as app_owner during migration.

-- ------------------------------------------------------------
-- 4. Self-check, mirroring the other two schemas.
-- ------------------------------------------------------------
do $$
declare v_bad text;
begin
    -- The read path must NOT be SECURITY DEFINER (see §3's reasoning).
    select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'aiq'
      and p.proname in ('query','lookup','graph_neighbors','graph_walk',
                        'semantic_in','lexical','hybrid','sql_passthrough')
      and p.prosecdef;
    if v_bad is not null then
        raise exception
            'READ-PATH FUNCTIONS ARE SECURITY DEFINER: %. These run on behalf of a '
            'user and must be subject to that user''s RLS -- SECURITY DEFINER here '
            'returns every tenant''s rows.', v_bad;
    end if;

    -- Same view-ownership invariant as user-rbac §10 and workflow §16.
    select string_agg(v.relname, ', ') into v_bad
    from pg_class v
    join pg_namespace n on n.oid = v.relnamespace
    join pg_class t on t.relnamespace = v.relnamespace and t.relkind = 'r'
                   and t.relname = replace(v.relname, '_api', '')
    where n.nspname = 'aiq' and v.relkind = 'v' and v.relname like '%\_api'
      and (v.relowner = t.relowner
           or (select rolsuper from pg_roles where oid = v.relowner));
    if v_bad is not null then
        raise exception
            'VIEW OWNERSHIP INVARIANT VIOLATED: %. Each *_api view must be owned by a '
            'non-superuser role distinct from the base table owner.', v_bad;
    end if;

    raise notice 'ai-query-layer self-check passed: read path is SECURITY INVOKER; api views separately owned';
end $$;
