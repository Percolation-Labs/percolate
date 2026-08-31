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
-- node_keys INHERITS its node's visibility rather than re-deriving it from
-- its own org_id copy. That copy exists for the canonical-key unique index
-- (two orgs may each have their own 'acme' -- graph-identity.md "Keys"), and
-- it is the wrong thing to gate reads on.
--
-- Found by running LOOKUP over REST after a rebuild: nodes.org_id had been
-- updated while node_keys.org_id had not (the projection's ON CONFLICT DO
-- NOTHING never touches an existing key row), so the key was visible and its
-- node was not. The join returned nothing and LOOKUP reported an empty result
-- -- indistinguishable from "no such key". A duplicated tenancy fact that can
-- drift is a silent-wrong-answer generator, and the same table cannot be both
-- the uniqueness scope and the visibility source without staying in lockstep.
--
-- One source of truth: visibility lives on nodes, keys inherit it. Drift is
-- now impossible rather than merely detected. (Same shape as workflow.tasks
-- inheriting visibility from workflow.runs.)
create policy node_keys_via_node on aiq.node_keys for select
  using (exists (select 1 from aiq.nodes n where n.id = aiq.node_keys.node_id));
-- Edges likewise inherit: an edge is visible only when BOTH endpoints are.
-- Its own org_id stays for authoring/provenance, not for read gating -- same
-- reasoning as node_keys above, and it additionally prevents an edge from
-- revealing that an invisible node exists.
create policy edges_via_endpoints on aiq.edges for select
  using (exists (select 1 from aiq.nodes s where s.id = aiq.edges.src_id)
     and exists (select 1 from aiq.nodes d where d.id = aiq.edges.dst_id));

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

-- Base-table SELECT for `authenticated` too -- and this is NOT the same
-- decision user-rbac made, so the difference is worth stating.
--
-- user-rbac grants no base-table access because its sensitivity is
-- COLUMN-level: password_hash and mfa_secret must never be selectable, and
-- RLS cannot hide a column. Only a view whose SELECT list omits them can.
--
-- Here the sensitivity is purely ROW-level (which org owns this node), which
-- is exactly what RLS does. There is no secret column to hide, so a view adds
-- nothing to safety -- and the query functions are SECURITY INVOKER by
-- design (§3), so they read as the CALLER and are filtered by the caller's
-- policies. Withholding the grant would simply make every mode fail with
-- "permission denied for table node_keys", which is what happened the first
-- time this was exercised over REST.
--
-- The rule, generalised: views for COLUMN secrecy, RLS for ROW visibility.
-- Reaching for a view when the problem is row-level buys nothing and costs a
-- layer of indirection.
grant select on aiq.nodes, aiq.node_keys, aiq.edges to authenticated;

-- A PROPERTY GRAPH is its own privilege object in PG19, separate from the
-- tables it is defined over. Granting SELECT on nodes and edges is NOT
-- sufficient: GRAPH mode fails with "permission denied for property graph
-- knowledge_graph" until this is granted too. Not guessable -- found by a
-- REST call failing after every table grant was already in place.
grant select on property graph aiq.knowledge_graph to authenticated, api_viewer;

-- Embedding spaces are created DYNAMICALLY by register_embedding_space(), so
-- they cannot be listed here -- and a table created after this file runs
-- inherits no grants, making every SEMANTIC/SEARCH call against a newly
-- registered model fail with "permission denied for table emb_<model>".
-- Found by registering a model and immediately querying it over REST.
--
-- ALTER DEFAULT PRIVILEGES is the mechanism that actually covers this: it
-- applies to objects app_owner creates in this schema FROM NOW ON, so a model
-- registered next month is readable without anyone remembering to come back
-- here. The existing grant covers spaces created before this line runs.
grant select on all tables in schema aiq to authenticated, api_viewer;
alter default privileges for role app_owner in schema aiq
    grant select on tables to authenticated, api_viewer;

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
grant execute on function aiq.lookup_many(text[], boolean, int) to authenticated;
grant execute on function aiq.graph_neighbors(uuid, text, int) to authenticated;
grant execute on function aiq.graph_walk(uuid, int, text, int) to authenticated;
grant execute on function aiq.semantic_in(vector, text, int) to authenticated;
grant execute on function aiq.lexical(text, text, int) to authenticated;
grant execute on function aiq.search(text, text, vector, text, int, int) to authenticated;
grant execute on function aiq.sql_passthrough(text) to authenticated;

-- Registry reads: an agent needs to know which models and sources exist to
-- form a valid query at all. Read-only, no row-level sensitivity.
grant select on aiq.embedding_models, aiq.lexical_sources,
                aiq.semantic_sources, aiq.relation_types to authenticated;

-- ------------------------------------------------------------
-- 3b. Consumer-owned content tables.
--
-- TEXT, SEMANTIC and SEARCH read the CONSUMER's tables (world-model
-- ingestion's resource_chunks, say), not aiq's own -- registered by name in
-- lexical_sources / semantic_sources. Because the query functions are
-- SECURITY INVOKER, the caller needs real access to those tables, and
-- without it every content mode fails with "permission denied for schema
-- <consumer>" even though every aiq grant is correct.
--
-- Deliberately NOT granted here: this file must not reach into a consumer
-- schema it does not own and decide who may read it. That is the consumer's
-- policy to set, alongside its own RLS. Stated explicitly because the failure
-- is confusing -- it looks like an ai-query-layer permissions bug and is not.
--
-- A consumer registering a source is signing up for, e.g.:
--     grant usage on schema wm to authenticated;
--     grant select on wm.resource_chunks to authenticated;
--     alter table wm.resource_chunks enable row level security;
--     create policy ... ;   -- the consumer's own visibility rule
-- ------------------------------------------------------------

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
