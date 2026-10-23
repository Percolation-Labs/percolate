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
-- 1. Scope.
--
-- WAS: a policy that admitted a null org OR an org drawn from the retired
-- aiq.current_org_ids seam -- spelled out here originally, and deliberately
-- not any more: check-references.py reads `select <schema>.<fn>(` as a CALLER
-- being told to run something, and it is right to. A historical note is still
-- a name a reader may try, and this one names a function that no longer
-- exists. The rule it stated: "org_id IS NULL -> shared reference data,
-- visible to everyone; org_id = <uuid> -> visible only to members of that
-- org".
--
-- That rule was right about what it wanted and wrong about how it said it,
-- because `org_id is null` also means "nobody set it". world-model-ingestion
-- measured the consequence on this exact predicate: register_upload() called
-- without its optional org argument wrote a null org, and a different tenant
-- read the row. One value cannot be both "deliberately global" and "not filled
-- in" while a policy treats it as the first.
--
-- user-rbac §2b's scope column says which one is meant, so the null org stops
-- being load-bearing: a shared SEC filing is `public` because somebody chose
-- it, and a row nobody scoped is `private` because that is the default.
--
-- AND THE NULL ITSELF IS GONE. identity/spec.md §4 finished the argument: a
-- NULL may only mean unknown, so the shared tier is a ROW -- user-rbac
-- §2b(i)'s rbac.shared_org_id() -- and org_id is NOT NULL on all sixteen
-- tables that carry it. "org_id IS NULL -> shared" is now "org_id =
-- rbac.shared_org_id() -> shared", which is the same sentence with nothing
-- left for a reader to guess and nothing left for a unique index to skip.
--
-- "Shared reference data" is still a real category and not a loophole -- a
-- public filing or a well-known company is legitimately global, and forcing it
-- to be duplicated per tenant would defeat the whole point of one identity
-- registry. It is now spelled `public`, on the shared org.
--
-- Membership lives in rbac, as it always claimed to. What has changed is that
-- there is now something there to ask: rbac.org_members rather than an array
-- the caller's own token asserts.
-- ------------------------------------------------------------

-- Two calls, and no policy written by hand -- see rbac.add_scope_policy()'s
-- header for why the predicate is generated rather than copied. nodes gains
-- owner_id and visibility; its existing org_id gains the foreign key to
-- rbac.orgs it never had, so an org_id naming no org is refused at the write
-- instead of producing a row nobody can see.
--
-- No `<resource>` argument, deliberately: there is no deployment-wide
-- permission to read every tenant's graph, and adding one here would create it.
select rbac.add_scope_columns('aiq.nodes', 'public');
select rbac.add_scope_policy ('aiq.nodes');

alter table aiq.node_keys enable row level security;
alter table aiq.edges     enable row level security;
alter table aiq.node_resolutions enable row level security;
alter table aiq.node_distinctions enable row level security;

-- THE TWO TABLES THAT CARRY org_id AND DO NOT TAKE add_scope_columns.
--
-- Both keep their own org_id -- node_keys because the canonical-key unique
-- index is scoped by it, edges for authoring provenance -- and neither takes
-- the scope columns, for the reasons written out below. That makes them the
-- only two of the sixteen where the NOT NULL does not arrive with
-- add_scope_columns(), so it is asked for explicitly. Two lines rather than a
-- rule, and stated where the exception itself is stated: a catalogue sweep
-- that quietly fixed them would hide the fact that they are exceptions.
--
-- identity/checks.sql asserts nobody adds a seventeenth org_id column and
-- forgets both routes.
select rbac.adopt_shared_org('aiq.node_keys');
select rbac.adopt_shared_org('aiq.edges');
-- A resolution carries the survivor's org for authoring and audit, the same
-- way an edge does -- not for read gating, which the policy below takes from
-- the node. Adopted so `org_id is null` cannot mean two things.
select rbac.adopt_shared_org('aiq.node_resolutions');
select rbac.adopt_shared_org('aiq.node_distinctions');

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
-- inheriting visibility from workflow.runs.) This is also why node_keys does
-- NOT get add_scope_columns -- a second `visibility` column here would be the
-- identical bug one generation later.
drop policy if exists node_keys_via_node on aiq.node_keys;
create policy node_keys_via_node on aiq.node_keys for select
  using (exists (select 1 from aiq.nodes n where n.id = aiq.node_keys.node_id));
-- Edges likewise inherit: an edge is visible only when BOTH endpoints are.
-- Its own org_id stays for authoring/provenance, not for read gating -- same
-- reasoning as node_keys above, and it additionally prevents an edge from
-- revealing that an invisible node exists.
--
-- THE POLICY ITSELF IS WRITTEN IN world-model-ingestion/graph.sql §10a, which
-- adds the second half: an edge is also read through the memories it was
-- extracted from (REM-962). That gate reads content.resources, which does not
-- exist yet when this file is assembled, and one policy written in two files is
-- two policies that drift. Until §10a runs during an install, aiq.edges has RLS
-- on and no read policy, so it returns nothing to a caller -- closed, and only
-- for the length of the install.
-- An edge's retraction history is visible exactly when the edge is, by the
-- same inheritance. It carries no org of its own to gate on, and the schema's
-- blanket `grant select on all tables in schema aiq` reaches it, so without
-- this a caller could list the edge ids and dates of every tenant's
-- retractions.
alter table aiq.edge_retractions enable row level security;
drop policy if exists edge_retractions_via_edge on aiq.edge_retractions;
create policy edge_retractions_via_edge on aiq.edge_retractions for select
  using (exists (select 1 from aiq.edges e where e.id = aiq.edge_retractions.edge_id));

-- A resolution inherits from the SURVIVOR only, and the asymmetry is the point.
-- Gating on both constituents would hide the merge from a caller who can see
-- the node that survived -- which is the node they will actually be looking at,
-- and D11's whole claim is that a merge is inspectable by whoever holds the
-- result. Gating on the merged node instead would let a resolution reveal that
-- an invisible node exists, which is what edges_via_endpoints above is
-- avoiding. The survivor is the one a reader already has.
drop policy if exists node_resolutions_via_canonical on aiq.node_resolutions;
create policy node_resolutions_via_canonical on aiq.node_resolutions for select
  using (exists (select 1 from aiq.nodes n where n.id = aiq.node_resolutions.canonical_id));
-- A distinction names two nodes; like an edge it is visible only when both
-- are, so it cannot reveal that an invisible node exists.
drop policy if exists node_distinctions_via_both on aiq.node_distinctions;
create policy node_distinctions_via_both on aiq.node_distinctions for select
  using (exists (select 1 from aiq.nodes a where a.id = aiq.node_distinctions.a_id)
     and exists (select 1 from aiq.nodes b where b.id = aiq.node_distinctions.b_id));

-- ------------------------------------------------------------
-- 2. Read path: views owned by api_viewer, exactly as user-rbac does.
--    A view owned by app_owner would bypass the policies above.
-- ------------------------------------------------------------
create or replace view aiq.nodes_api as
-- The scope columns are APPENDED rather than slotted in beside owner_id, and
-- the position is forced rather than chosen: `create or replace view` may only
-- ADD columns at the end. Inserting one in the middle is
-- `ERROR: cannot change name of view column "status" to "org_id"`, which a
-- fresh install never sees -- the view is being created, not replaced -- and
-- every upgrading database hits. Found by dev/upgrade-converges.sh, which is
-- the only check that applies this file to a database that already has the
-- old view.
  select id, entity_type, entity_id, org_id, summary, created_at, updated_at,
         owner_id, visibility
  from aiq.nodes;
create or replace view aiq.edges_api as
  select id, src_id, dst_id, relation, weight, valid_from, valid_to, org_id, created_at
  from aiq.edges;

grant usage on schema aiq to api_viewer, authenticated;
grant select on aiq.nodes, aiq.node_keys, aiq.edges, aiq.edges_current,
                aiq.node_resolutions, aiq.node_distinctions, aiq.node_current to api_viewer;
-- rbac.current_org_ids() and the scope predicates are granted in user-rbac
-- §9, to api_viewer and authenticated among others -- the policies above are
-- evaluated as the view owner, so api_viewer is who must be able to run them.

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
grant select on aiq.nodes, aiq.node_keys, aiq.edges, aiq.edges_current,
                aiq.node_resolutions, aiq.node_distinctions, aiq.node_current to authenticated;

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
-- The grant is what a space's read policies are written for: one per role
-- that holds it (schema.sql §10a-iii, REM-567). Rewritten here as well, so a
-- space this grant reached for the first time does not stay unreadable.
select aiq.police_embedding_spaces();

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
-- Not the last word: `graph-algorithms.sql` and `world-model-ingestion/
-- graph.sql` both define aiq functions after this line, and PUBLIC's default
-- comes back with each one. The statement that holds the invariant for every
-- schema, after the last file that can add to any of them, is at the end of
-- `world-model-ingestion/ingestion.sql`.
revoke execute on all functions in schema aiq from public;

grant execute on function aiq.query(text, vector) to authenticated;
grant execute on function aiq.lookup(text, boolean, int) to authenticated;
grant execute on function aiq.lookup_many(text[], boolean, int) to authenticated;
grant execute on function aiq.graph_neighbors(uuid, text, int, timestamptz) to authenticated;
grant execute on function aiq.graph_walk(uuid, int, text, int, timestamptz) to authenticated;
-- aiq.edges_current is security_invoker and calls this, so a reader of the
-- view needs it. Without the grant the view, and every GRAPH query over it,
-- fails for exactly the roles it is granted to.
grant execute on function aiq.edge_is_current(timestamptz, timestamptz, timestamptz)
    to authenticated, api_viewer;
grant execute on function aiq.semantic_in(text, vector, text, int, jsonb) to authenticated;
grant execute on function aiq.semantic_ranks_exactly(text, jsonb, int) to authenticated;
-- semantic_in's one setting, set as the owner because its caller holds no
-- set_config (schema.sql, above semantic_in). api_viewer has it by membership.
grant execute on function aiq.set_scan_order(text) to authenticated;
grant execute on function aiq.lexical(text, text, int, jsonb) to authenticated;
-- Both halves build their scoped relation through it as the caller (REM-965).
grant execute on function aiq.scoped_source(text, jsonb) to authenticated;
-- aiq.query raises result exceptions through it as the caller (REM-948).
grant execute on function aiq.result_exceptions(jsonb, int, int, boolean) to authenticated;
grant execute on function aiq.search(text, text, vector, text, int, int, jsonb) to authenticated;
grant execute on function aiq.sql_passthrough(text) to authenticated;
-- Diagnostic, and granted for the same reason the error messages name the fix:
-- the caller who hits "function p8_graph_ppr does not exist" is the one who
-- needs to see which halves are in step, and they are rarely the DBA.
grant execute on function aiq.extension_boundary() to authenticated;

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
