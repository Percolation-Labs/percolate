-- ============================================================
-- AI Query Layer — schema v0.1
--
-- Implements graph-identity.md: a write-time node registry (identity), a
-- key index (lookup, exact/short/fuzzy), and an authored edge table (soft
-- links), kept strictly separate from each consumer's own typed tables
-- (attributes) and from hard FK relationships (which stay relational and are
-- never copied into edges).
--
-- Applied as app_owner, after workflow-engine and user-rbac. Depends on rbac
-- only for RLS predicates (org scoping), same boundary discipline as
-- workflow-engine/integration-rbac.sql.
--
-- The five REM-derived query modes (brief.md §2, §3) compile to:
--   LOOKUP           -> node_keys btree probe -> nodes -> typed-table PK fetch
--                       (takes a LIST of keys; each resolves independently)
--   FUZZY LOOKUP     -> pg_trgm over node_keys ONLY, never the data plane
--   SEMANTIC         -> pgvector over the embedding table for one entity type
--   GRAPH depth 1    -> GRAPH_TABLE over the property graph below
--   GRAPH depth n>1  -> WITH RECURSIVE over edges (PG19 has no quantified
--                       path patterns; confirmed empirically, brief.md §3)
--   SEARCH           -> RRF fusion of the lexical and semantic ranks
--   <ordinary SQL>   -> read-only passthrough, SECURITY INVOKER (brief.md §3);
--                       no keyword, recognised by how the statement starts
-- ============================================================

create extension if not exists vector;
create extension if not exists pg_trgm;

create schema if not exists aiq;

-- ------------------------------------------------------------
-- 1. Node registry — graph identity for one included typed row.
--    Does NOT store the payload; payload stays on the typed table.
-- ------------------------------------------------------------
create table aiq.nodes (
    id           uuid primary key default gen_random_uuid(),
    entity_type  text not null,          -- owning table, e.g. 'company'
    entity_id    uuid not null,          -- PK in that table
    org_id       uuid,                   -- tenant; null = shared reference data
    summary      text,                   -- cheap human/agent-readable label
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (entity_type, entity_id)
);
create index idx_nodes_org on aiq.nodes (org_id);

create trigger trg_nodes_touch before update on aiq.nodes
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Keys — how humans, agents and the query dialect NAME a node.
--    Not the edge foreign key (that is nodes.id, graph-identity.md D3).
--    entity_type is copied here so the unique index needs no join.
-- ------------------------------------------------------------
create table aiq.node_keys (
    node_id      uuid not null references aiq.nodes(id) on delete cascade,
    entity_type  text not null,
    key          text not null,          -- normalized (lowercased, trimmed)
    kind         text not null check (kind in ('canonical','short','alias')),
    org_id       uuid,
    primary key (node_id, key, kind)
);
-- Canonical keys are unique per (org, type). Short keys and aliases are
-- deliberately NOT unique -- 'bakhmut' may be canonical for a place and an
-- event, and short-key lookup may legitimately return several nodes.
--
-- NULLS NOT DISTINCT, and it is the whole guarantee rather than a detail.
-- org_id IS NULL means shared reference data, which integration-rbac.sql §1
-- calls "a real category here, not a loophole" and which every public company
-- in a deployment will be. Under the default NULLS DISTINCT, two NULLs never
-- conflict -- so this index enforced canonical-key uniqueness for exactly the
-- tenants that have one and not at all for the shared tier. Measured: two
-- companies both took the canonical key 'acme', and LOOKUP "ACME" -- the
-- dialect's most common call, documented as an exact match -- returned two
-- different nodes with no way to tell which was meant.
create unique index idx_node_keys_canonical
    on aiq.node_keys (org_id, key, entity_type) nulls not distinct
    where kind = 'canonical';
create index idx_node_keys_lookup on aiq.node_keys (key);
-- FUZZY lives here and ONLY here: a trigram index on this thin key table,
-- never on the data plane (graph-identity.md "Scale").
create index idx_node_keys_trgm on aiq.node_keys using gin (key gin_trgm_ops);

-- ------------------------------------------------------------
-- 3. Relation catalogue — every allowed (src_type, relation, dst_type).
--    Out-of-catalogue relations are rejected at write, so the graph cannot
--    accumulate typos-as-relations (graph-identity.md "Catalogue").
-- ------------------------------------------------------------
create table aiq.relation_types (
    src_type   text not null,
    relation   text not null,
    dst_type   text not null,
    inverse_label text,                  -- read-time inverse; NOT a stored edge
    description   text,
    primary key (src_type, relation, dst_type)
);

-- ------------------------------------------------------------
-- 4. Edges — canonical store for SOFT (authored) links only.
--    Hard FK/junction relationships are NEVER copied here (D4).
-- ------------------------------------------------------------
create table aiq.edges (
    id          uuid primary key default gen_random_uuid(),
    src_id      uuid not null references aiq.nodes(id) on delete cascade,
    dst_id      uuid not null references aiq.nodes(id) on delete cascade,
    relation    text not null,
    weight      real not null default 1.0,
    valid_from  timestamptz,
    valid_to    timestamptz,
    provenance  jsonb not null default '{}'::jsonb,
    org_id      uuid,
    created_at  timestamptz not null default now(),
    unique (src_id, dst_id, relation)
);
-- Forward and REVERSE both indexed: "what points at this?" is first-class,
-- and the inverse edge is never stored (graph-identity.md "Edge table").
create index idx_edges_src on aiq.edges (src_id);
create index idx_edges_dst on aiq.edges (dst_id);
create index idx_edges_relation on aiq.edges (relation);

-- Enforce the catalogue, and enforce that both endpoints are real nodes
-- (the FKs already do the latter; this makes the type-pair check real).
create or replace function aiq.check_edge_catalogue() returns trigger as $$
declare
    v_src_type text;
    v_dst_type text;
begin
    select entity_type into v_src_type from aiq.nodes where id = new.src_id;
    select entity_type into v_dst_type from aiq.nodes where id = new.dst_id;
    if not exists (
        select 1 from aiq.relation_types
        where src_type = v_src_type and relation = new.relation and dst_type = v_dst_type
    ) then
        -- `%s` here, not `%`: RAISE takes % as the placeholder, so the
        -- original spelling appended a literal 's' to every value and the
        -- message read `relation (companys, competes_withs, persons)`. An
        -- error that misnames the types it is complaining about sends the
        -- reader looking for an entity type that does not exist.
        raise exception
            'relation (%, %, %) is not in the catalogue -- add it to aiq.relation_types first',
            coalesce(v_src_type, '<no node>'), new.relation,
            coalesce(v_dst_type, '<no node>');
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_check_edge_catalogue
    before insert or update on aiq.edges
    for each row execute function aiq.check_edge_catalogue();

-- ------------------------------------------------------------
-- 5. The property graph (SQL/PGQ). Read-only catalog metadata over the
--    tables above -- no second copy of the graph, no writers (D8, invariant 7).
--    Hard-link junctions get added here as EDGE TABLES by each consumer that
--    wants them walkable; nothing about that is stored twice either.
-- ------------------------------------------------------------
-- Two PG19 syntax constraints, both found by the parser rejecting the
-- obvious form, and both worth stating because neither is guessable:
--   * KEY must precede SOURCE/DESTINATION in an edge table definition.
--   * SOURCE/DESTINATION ... REFERENCES takes the vertex table's ALIAS
--     (its unqualified name as declared above), never a schema-qualified
--     name -- `references aiq.nodes (id)` is a syntax error.
--   * The KEY column is NOT implicitly a property. Selecting a.id in a
--     GRAPH_TABLE COLUMNS clause fails with `property "id" does not exist`
--     unless id is also listed in PROPERTIES. Since every useful query needs
--     the node id to join back to the typed tables, id is declared twice
--     here by necessity, not redundancy.
create property graph aiq.knowledge_graph
    vertex tables (
        aiq.nodes key (id) label node properties (id, entity_type, org_id, summary)
    )
    edge tables (
        aiq.edges key (id)
            source key (src_id) references nodes (id)
            destination key (dst_id) references nodes (id)
            label related properties (relation, weight, org_id)
    );

-- ------------------------------------------------------------
-- 6. Projection: keeping nodes/node_keys in sync with typed tables.
--
--    D6: STATEMENT-level triggers with transition tables, not row-level.
--    The difference is the whole scalability argument -- a 10k-row COPY pays
--    ONE set-based INSERT here, not 10k trigger firings. Row-level triggers
--    are permitted only on tiny interactive tables, and are not the default.
--
--    Registration is generic: a consumer calls aiq.register_entity_table()
--    and gets projection for free, rather than hand-writing three triggers
--    per table. The inclusion policy (which rows become nodes) is expressed
--    as a WHERE predicate on the source table -- rebuild and live projection
--    MUST use the same predicate, or a rebuild resurrects evicted nodes
--    (graph-identity.md "Inclusion policy").
-- ------------------------------------------------------------
create table aiq.entity_registry (
    entity_type   text primary key,
    source_table  text not null,          -- schema-qualified
    key_expr      text not null,          -- SQL expr -> canonical key
    summary_expr  text not null default 'null',
    org_expr      text not null default 'null',
    include_where text not null default 'true',
    registered_at timestamptz not null default now()
);

create or replace function aiq.register_entity_table(
    p_entity_type   text,
    p_source_table  text,
    p_key_expr      text,
    p_summary_expr  text default 'null',
    p_org_expr      text default 'null',
    p_include_where text default 'true'
) returns void as $$
declare
    -- Named after the ENTITY TYPE, not after the source table's short name.
    --
    -- The short name was `split_part(p_source_table, '.', 2)`, which is not
    -- unique: registering `s1.thing` as `t_one` and `s2.thing` as `t_two`
    -- generated `aiq.project_thing_ins` twice, and the second CREATE OR
    -- REPLACE silently rewrote the first with the other type's entity_type
    -- baked in. Rows inserted into s1.thing were then projected as `t_two`.
    -- Confirmed by running it: identity for a whole table came back wrong,
    -- with nothing raised anywhere. entity_type is the registry's primary
    -- key, so it is the only name that cannot collide.
    v_ins   text := quote_ident('project_' || p_entity_type || '_ins');
    v_del   text := quote_ident('project_' || p_entity_type || '_del');
    v_other text;
begin
    -- One table, one entity type. Two types over one table cannot both work
    -- anyway -- the trigger names are fixed, so the second registration's
    -- triggers replace the first's and only one type ever projects -- and the
    -- failure is silent. Refusing is the honest form of the same limit.
    select entity_type into v_other from aiq.entity_registry
     where source_table = p_source_table and entity_type <> p_entity_type;
    if v_other is not null then
        raise exception
            '% is already registered as entity type % -- one table projects into '
            'one entity type. Drop the other registration first, or project the '
            'second view of this table from its own view or table.',
            p_source_table, v_other;
    end if;

    insert into aiq.entity_registry
        (entity_type, source_table, key_expr, summary_expr, org_expr, include_where)
    values (p_entity_type, p_source_table, p_key_expr, p_summary_expr, p_org_expr, p_include_where)
    on conflict (entity_type) do update
        set source_table = excluded.source_table, key_expr = excluded.key_expr,
            summary_expr = excluded.summary_expr, org_expr = excluded.org_expr,
            include_where = excluded.include_where;

    -- One projection function per registered type, generated from the
    -- registry row. Generated rather than generic-at-runtime because a
    -- statement trigger's transition table cannot be addressed dynamically
    -- by name from a shared function -- the trigger body has to know its own
    -- table. This is the concrete cost of D6's statement-level requirement,
    -- and it is worth paying: the alternative is a row-level trigger and a
    -- projection per row.
    --
    -- The function has FOUR statements, not two, and the two added ones are
    -- both evictions. A projection that only ever inserts keeps a registry
    -- that only ever grows, and both halves of that were real: an UPDATE that
    -- made a row fail the inclusion predicate left its node and key in place
    -- (invariant 3 broken by the projection itself, and the drift check duly
    -- reported the node it had just created), and a rename left the old
    -- canonical key behind, so the previous name went on resolving forever
    -- and the node ended up with two keys each claiming to be the derived one.
    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            -- 1. Rows that belong: upsert identity.
            insert into aiq.nodes (entity_type, entity_id, org_id, summary)
            select %2$L, n.id, %3$s, %4$s from new_rows n where %5$s
            on conflict (entity_type, entity_id) do update
                set summary = excluded.summary, org_id = excluded.org_id,
                    updated_at = now();

            -- 2. Rows that no longer belong: evict. coalesce(..., false)
            --    rather than `not (...)` because a predicate that evaluates to
            --    NULL is not satisfied, and three-valued logic here would put
            --    the stale node back exactly where it was.
            delete from aiq.nodes nd
            where nd.entity_type = %2$L
              and nd.entity_id in (select n.id from new_rows n
                                    where not coalesce((%5$s), false));

            -- 3. The canonical key.
            insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
            select nd.id, %2$L, lower(trim(%6$s)), 'canonical', %3$s
            from new_rows n
            join aiq.nodes nd on nd.entity_type = %2$L and nd.entity_id = n.id
            where %5$s
            -- DO UPDATE, not DO NOTHING: org_id scopes the canonical-key
            -- unique index, so leaving a stale copy on an existing key row
            -- silently corrupts that scoping after a tenancy change.
            on conflict (node_id, key, kind) do update set org_id = excluded.org_id;

            -- 4. Superseded canonical keys. Runs AFTER the insert, so a
            --    key_expr that evaluates to NULL aborts on the not-null
            --    constraint above rather than deleting the name the node had.
            --    Short keys and aliases are editorial and are not touched:
            --    a rename is not a reason to forget that somebody taught the
            --    graph a synonym.
            delete from aiq.node_keys k
            using aiq.nodes nd, new_rows n
            where k.node_id = nd.id
              and nd.entity_type = %2$L and nd.entity_id = n.id
              and k.kind = 'canonical'
              and k.key is distinct from lower(trim(%6$s));
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_ins, p_entity_type, p_org_expr, p_summary_expr, p_include_where, p_key_expr);

    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            delete from aiq.nodes
            where entity_type = %2$L and entity_id in (select id from old_rows);
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_del, p_entity_type);

    execute format('drop trigger if exists trg_aiq_project_ins on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_ins
            after insert on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_ins);

    execute format('drop trigger if exists trg_aiq_project_upd on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_upd
            after update on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_ins);

    execute format('drop trigger if exists trg_aiq_project_del on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_del
            after delete on %1$s
            referencing old table as old_rows
            for each statement execute function aiq.%2$s();
    $f$, p_source_table, v_del);
end;
-- `drop trigger if exists` raises a NOTICE per trigger it did not find, so a
-- first registration emitted three lines of "does not exist, skipping" that
-- say nothing and bury anything that does. WARNING and above still get
-- through, which is everything a caller of this function needs to see.
$$ language plpgsql set client_min_messages = warning;

-- Rebuild + drift detection (D7). The rebuild MUST use the same predicate as
-- the live trigger -- both read it from entity_registry, so they cannot drift
-- apart by editing one and forgetting the other.
--
-- The source row is aliased `n` here, matching the alias the live trigger's
-- transition table uses. That is not cosmetic: registry expressions are stored
-- as SQL text (`n.is_public`, `coalesce(n.ticker, n.name)`), so the alias is
-- part of their contract. An earlier version aliased the source `s` in rebuild
-- and `n` in the trigger, which made every rebuild fail outright with
-- "missing FROM-clause entry for table n" -- caught by running it. Worse than
-- a silent drift, but the same root cause D7 is about: two code paths that
-- must agree, with nothing forcing them to.
create or replace function aiq.rebuild_entity_type(p_entity_type text)
returns bigint as $$
declare
    r aiq.entity_registry;
    v_count bigint;
begin
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    if not found then raise exception 'entity type % not registered -- SCHEMA "graph" lists the registered ones', p_entity_type; end if;

    execute format($q$
        insert into aiq.nodes (entity_type, entity_id, org_id, summary)
        select %1$L, n.id, %2$s, %3$s from %4$s n where %5$s
        on conflict (entity_type, entity_id) do update
            set summary = excluded.summary, org_id = excluded.org_id, updated_at = now()
    $q$, r.entity_type, r.org_expr, r.summary_expr, r.source_table, r.include_where);

    execute format($q$
        insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
        select nd.id, %1$L, lower(trim(%2$s)), 'canonical', %3$s
        from %4$s n
        join aiq.nodes nd on nd.entity_type = %1$L and nd.entity_id = n.id
        where %5$s
        on conflict (node_id, key, kind) do update set org_id = excluded.org_id
    $q$, r.entity_type, r.key_expr, r.org_expr, r.source_table, r.include_where);

    -- Evict nodes whose source row is gone or no longer satisfies inclusion.
    execute format($q$
        delete from aiq.nodes nd
        where nd.entity_type = %1$L
          and not exists (select 1 from %2$s n where n.id = nd.entity_id and %3$s)
    $q$, r.entity_type, r.source_table, r.include_where);

    -- Returns how many nodes this type HAS now, not how many rows the last
    -- statement touched. `get diagnostics row_count` after the eviction
    -- DELETE meant a rebuild that had just projected ten nodes returned 0,
    -- which reads as "did nothing" to the bulk-load caller that asked for it.
    execute format('select count(*) from aiq.nodes where entity_type = %L',
                   p_entity_type) into v_count;
    return v_count;
end;
$$ language plpgsql;

-- Two-way EXCEPT drift check (D7). Non-empty result = a writer bug, not a
-- routine merge to paper over. Run as a scheduled workflow-engine task
-- (D10), not a bespoke cron job.
create or replace function aiq.check_drift(p_entity_type text)
returns table(direction text, entity_id uuid) as $$
declare r aiq.entity_registry;
begin
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    if not found then raise exception 'entity type % not registered -- SCHEMA "graph" lists the registered ones', p_entity_type; end if;

    return query execute format($q$
        select 'missing_node'::text, n.id from %2$s n where %3$s
        except
        select 'missing_node'::text, nd.entity_id from aiq.nodes nd where nd.entity_type = %1$L
        union all
        select 'orphan_node'::text, nd.entity_id from aiq.nodes nd where nd.entity_type = %1$L
        except
        select 'orphan_node'::text, n.id from %2$s n where %3$s
    $q$, r.entity_type, r.source_table, r.include_where);
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 5b. The org-membership seam.
--
-- This lives in the CORE schema and not in integration-rbac.sql, where its
-- policies live and where it was first written, for a reason found by building
-- a pristine database from the generated extension script: `aiq.schema_graph`
-- -- a core §13 facet -- scopes the sample keys it shows to the caller's orgs,
-- and a `language sql` function is validated at CREATE time. The integration
-- file is applied AFTER this one, so the facet could not be created at all on a
-- fresh install: SCHEMA "graph" was missing from every new database and present
-- in every database where somebody had loaded the file by hand. Existence is
-- not currency, and this is the shape currency.sh exists to catch.
--
-- The design point it was written with is unchanged and still applies: this
-- layer does not invent a second notion of tenancy. user-rbac has no org model
-- yet (specs/README.md defers tenant management deliberately), so the predicate
-- is expressed against a single function that a real deployment replaces.
-- Shipping a permissive default silently would be the worst option; this errs
-- closed for org-scoped rows when no membership source exists.
--
-- Returns SETOF rather than an array, deliberately: `org_id = any (select ...)`
-- against an array-returning function compares uuid to uuid[] and fails, while
-- the array form `= any (f())` gives up the InitPlan hoisting that
-- user-rbac/schema.sql §9 measured as the difference between evaluating a
-- predicate once per query and once per row scanned. SETOF gives both --
-- `in (select ...)` type-checks and plans as a hashed SubPlan.
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- 6b. Aliases and short keys -- the only supported write path into node_keys.
--
-- Invariant 5 says application code never writes nodes or node_keys except
-- through the projection. The projection writes exactly one row per source
-- row, the CANONICAL key from key_expr, because that is all a source row can
-- derive. The other two kinds are editorial: 'kiev' is an alias for 'kyiv'
-- because somebody decided so, and no expression over the typed table
-- produces it.
--
-- So two thirds of LOOKUP's cascade (graph-identity.md "Keys": exact
-- canonical, then short, then fuzzy over both) had no write path the
-- invariant permitted -- the branches existed, were tested with hand-inserted
-- rows, and no caller could reach them without breaking the rule the schema
-- states. This is that path: the invariant's exception, named and narrow,
-- rather than an unwritten convention that inserting into node_keys is fine
-- if you are careful.
--
-- It refuses to write a canonical key. Canonical belongs to the projection,
-- and a second canonical key on one node is not a synonym -- it is two names
-- each claiming to be the derived one. The (org_id, key, entity_type) unique
-- index does not prevent it, because that index scopes uniqueness ACROSS
-- nodes, not within one.
--
-- Not granted to `authenticated`: naming is an editorial act with the same
-- blast radius as registration (an alias silently re-points every LOOKUP that
-- uses it), so it stays with the role that runs migrations, like
-- register_entity_table above.
-- ------------------------------------------------------------
create or replace function aiq.add_node_key(
    p_node_key text, p_key text, p_kind text default 'alias'
) returns uuid as $$
declare
    v_node_id uuid;
    v_n       int;
    v_norm    text := lower(trim(p_key));
begin
    if p_kind = 'canonical' then
        raise exception
            'canonical keys come from the projection (entity_registry.key_expr), '
            'not from add_node_key -- change key_expr and rebuild, or add this '
            'name as a short key or an alias';
    elsif p_kind not in ('short','alias') then
        raise exception 'kind must be short or alias, not %', p_kind;
    end if;
    if v_norm is null or v_norm = '' then
        raise exception 'an empty key matches nothing and would sit in the '
                        'trigram index forever';
    end if;

    -- Resolved through the ordinary cascade, so an alias can be hung off a
    -- node found by its short name. Ambiguity is refused rather than resolved
    -- by picking one: attaching a name to the wrong node is not recoverable by
    -- reading the row back, since it looks exactly like the right one.
    -- (array_agg(...))[1] rather than min(): there is no min(uuid) in PG19,
    -- and the aggregate is only here to make "how many" and "which one" one
    -- pass over a result that is nearly always a single row.
    select count(*), (array_agg(l.node_id))[1] into v_n, v_node_id
    from aiq.lookup(p_node_key) l;
    if v_n = 0 then
        raise exception 'no node is named % -- add_node_key names an existing '
                        'node, it does not create one', p_node_key;
    elsif v_n > 1 then
        raise exception '% resolves to % nodes -- name the one you mean by its '
                        'canonical key', p_node_key, v_n;
    end if;

    -- entity_type and org_id are COPIED from the node for the same reason the
    -- projection copies them: the canonical-key unique index reads them
    -- without a join, and a hand-supplied value could disagree with the node.
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
    select v_node_id, n.entity_type, v_norm, p_kind, n.org_id
    from aiq.nodes n where n.id = v_node_id
    on conflict (node_id, key, kind) do update set org_id = excluded.org_id;

    return v_node_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 7. The query modes.
--
-- Each is an ordinary SQL function so PostgREST exposes it as an RPC and the
-- planner can see through it. aiq_query() (§8) is the single dispatch entry
-- point the dialect compiles to; these are the per-mode implementations, also
-- callable directly when a caller already knows the mode it wants.
-- ------------------------------------------------------------

-- LOOKUP: exact canonical -> short -> (caller opts in) fuzzy. Returns
-- identity + summary only; hydrating the typed row is a second, deliberate
-- step (REM's lazy-then-load discipline, brief.md §2).
create or replace function aiq.lookup(
    p_key text, p_fuzzy boolean default false, p_limit int default 20
) returns table(node_id uuid, entity_type text, entity_id uuid, key text,
                match_kind text, score real) as $$
declare v_norm text := lower(trim(p_key));
begin
    -- 1. exact canonical. distinct on (n.id) throughout, see the fuzzy
    -- branch below for why.
    return query
    select distinct on (n.id)
           n.id, n.entity_type, n.entity_id, k.key, 'canonical'::text, 1.0::real
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind = 'canonical'
    limit p_limit;
    if found then return; end if;

    -- 2. short / alias -- may legitimately return several NODES (and several
    -- types: 'bakhmut' as both a place and an event is the canonical example
    -- from graph-identity.md). Several nodes is correct; the same node twice
    -- is not.
    return query
    select distinct on (n.id)
           n.id, n.entity_type, n.entity_id, k.key, k.kind, 1.0::real
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind in ('short','alias')
    limit p_limit;
    if found then return; end if;

    -- 3. fuzzy, opt-in, and ONLY over node_keys -- never the data plane.
    --
    -- DISTINCT ON (n.id): a node with several matching keys (canonical
    -- 'acme', short 'acme', alias 'acme robotics') otherwise comes back once
    -- PER KEY. Confirmed on the fixture: one company returned three times for
    -- a single misspelling. LOOKUP answers "which NODES match this string",
    -- not "which key rows matched" -- the caller is going to hydrate nodes,
    -- and a duplicate is a bug at the call site every time. Best-scoring key
    -- wins and is reported, so the caller can still see WHICH name matched.
    if p_fuzzy then
        return query
        select * from (
            select distinct on (n.id)
                   n.id, n.entity_type, n.entity_id, k.key, 'fuzzy'::text,
                   similarity(k.key, v_norm) as score
            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
            where k.key % v_norm
            order by n.id, similarity(k.key, v_norm) desc
        ) d
        order by d.score desc
        limit p_limit;
    end if;
end;
$$ language plpgsql stable;

-- LOOKUP over a LIST of keys -- what the dialect's `LOOKUP "a", "b"` compiles
-- to, and the shape an agent actually needs: it rarely holds exactly one name.
--
-- Each key runs the full cascade independently. That is the whole subtlety:
-- resolving them as one set would let one key's canonical hit suppress
-- another key's fuzzy match, so a list of five names would answer differently
-- than five separate calls. Independence keeps the list a convenience rather
-- than a change of meaning.
--
-- It returns `input_key` alongside each row, which the scalar form has no need
-- for. Without it a caller cannot tell WHICH of five names produced a row, or
-- which produced none -- and "which of these did you not find" is usually the
-- question worth asking.
--
-- Deliberately NOT an overload of aiq.lookup(text, ...): an untyped literal
-- like aiq.lookup('acme') would then be ambiguous between text and text[],
-- and "function is not unique" is a poor greeting for the dialect's most
-- common call.
create or replace function aiq.lookup_many(
    p_keys text[], p_fuzzy boolean default false, p_limit int default 20
) returns table(input_key text, node_id uuid, entity_type text, entity_id uuid,
                key text, match_kind text, score real) as $$
    -- LEFT join lateral, so a key that matched nothing comes back as a row
    -- with a null node_id rather than not coming back at all. The comment
    -- above has always said "which of these did you not find" is usually the
    -- question worth asking; the inner join meant input_key could only ever
    -- report keys that HAD been found, which is the one case where the caller
    -- can already tell.
    select k.key_in, l.node_id, l.entity_type, l.entity_id, l.key,
           l.match_kind, l.score
    from unnest(p_keys) as k(key_in)
    left join lateral aiq.lookup(k.key_in, p_fuzzy, p_limit) l on true;
$$ language sql stable;

-- GRAPH depth 1: native SQL/PGQ. Confirmed working on PG19 beta3.
-- The `key` column, and why it is not optional.
--
-- This function returned `neighbor_id` and `summary` and no key, and the
-- worked example in USAGE.md reads fine because its summaries happen to BE
-- names ("Acme Robotics", "Dana Whitfield"). Run it against a graph whose
-- summaries are what summaries are for -- a band label, a status, a one-line
-- description -- and the answer is a column of UUIDs. Asked "which pairs moved
-- with sterling", the query layer returned eight ids and nothing that could be
-- said back to a person.
--
-- What made that unrecoverable rather than merely inconvenient: the dialect
-- has no mode that takes an id. LOOKUP resolves a key to a node; nothing
-- resolves a node back to a key. So a GRAPH result could not be turned into
-- names by any further p8ql query, only by dropping to SQL against node_keys
-- -- from a mode whose entire purpose is naming things.
--
-- graph-identity.md's rule is that a node is NAMED by its canonical key and
-- traversal happens by id. Both halves are load-bearing, and the read path was
-- keeping only the second.
create or replace function aiq.graph_neighbors(
    p_node_id uuid, p_relation text default null, p_limit int default 100
) returns table(neighbor_id uuid, key text, entity_type text, summary text,
                relation text, weight real, direction text) as $$
    select * from (
        select b.id, kb.key, b.entity_type, b.summary, e.relation, e.weight, 'out'::text
        from graph_table (aiq.knowledge_graph
            match (a is node) -[e is related]-> (b is node)
            columns (a.id as a_id, b.id as b_id, e.relation as relation, e.weight as weight)
        ) g
        join aiq.nodes b on b.id = g.b_id
        join aiq.edges e on e.src_id = g.a_id and e.dst_id = g.b_id and e.relation = g.relation
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = b.id and nk.kind = 'canonical'
                            limit 1) kb on true
        where g.a_id = p_node_id and (p_relation is null or g.relation = p_relation)
        union all
        -- The reverse question is first-class: no inverse edge is stored, so
        -- it is answered by walking dst_id, and the label comes from the
        -- catalogue at read time (graph-identity.md "Edge table").
        select a.id, ka.key, a.entity_type, a.summary,
               coalesce(rt.inverse_label, e.relation || '_by'), e.weight, 'in'::text
        from aiq.edges e
        join aiq.nodes a on a.id = e.src_id
        join aiq.nodes b2 on b2.id = e.dst_id
        left join aiq.relation_types rt
               on rt.src_type = a.entity_type and rt.relation = e.relation
              and rt.dst_type = b2.entity_type
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = a.id and nk.kind = 'canonical'
                            limit 1) ka on true
        -- The inverse label is matched too, and this is a round-trip fix
        -- rather than a convenience. The row above REPORTS `employs` for an
        -- inbound `works_at`; asking `GRAPH "ACME" TYPE employs` then returned
        -- nothing, so the dialect was displaying a relation name it refused to
        -- accept back. From this node's point of view both names name the same
        -- edge, and a caller that reads one should be able to write it.
        where e.dst_id = p_node_id
          and (p_relation is null or e.relation = p_relation
               or coalesce(rt.inverse_label, e.relation || '_by') = p_relation)
    ) x
    limit p_limit;
$$ language sql stable;

-- GRAPH depth n>1: WITH RECURSIVE. PG19's GRAPH_TABLE rejects quantified path
-- patterns outright ("element pattern quantifier is not supported") -- not a
-- beta gap to wait out, deliberately scoped out of the initial implementation
-- (brief.md §3). Depth- AND degree-capped, per graph-identity.md "Non-goals".
drop function if exists aiq.graph_walk(uuid, int, text, int);
create or replace function aiq.graph_walk(
    p_node_id uuid, p_depth int default 2, p_relation text default null,
    p_max_nodes int default 500
) returns table(node_id uuid, key text, entity_type text, summary text,
                depth int, path_relations text[], path_weight real) as $$
    with recursive walk as (
        select n.id, n.entity_type, n.summary, 0 as depth,
               array[]::text[] as rels, array[n.id] as seen, 1.0::real as score
        from aiq.nodes n where n.id = p_node_id
        union all
        -- path_weight is the PRODUCT of the edge weights along the path, not
        -- their sum or their minimum. brief.md §3.6 puts a coherence score in
        -- edges.weight and says a walk should not treat every edge as equally
        -- believed; a product is what makes a two-hop path through one
        -- barely-promoted 0.35 edge rank below two strong hops, which is the
        -- example that section actually gives. Sum would reward length, and
        -- min would make a long chain of near-certainties indistinguishable
        -- from a single one.
        --
        -- Until this existed §3.6's claim that "graph_walk orders by
        -- accumulated weight along the path" was simply false: the walk
        -- ordered by node id and ignored weight entirely, so the whole
        -- ingestion pipeline's scoring was discarded at the read step -- the
        -- exact failure that section is about.
        select nx.id, nx.entity_type, nx.summary, w.depth + 1,
               w.rels || e.relation, w.seen || nx.id, (w.score * e.weight)::real
        from walk w
        join aiq.edges e on (e.src_id = w.id or e.dst_id = w.id)
        join aiq.nodes nx on nx.id = case when e.src_id = w.id then e.dst_id else e.src_id end
        where w.depth < p_depth
          and not nx.id = any(w.seen)          -- cycle guard
          -- Same round-trip rule as graph_neighbors: a relation may be named
          -- by its catalogue name or by the inverse label the read path shows.
          and (p_relation is null or e.relation = p_relation
               or exists (select 1 from aiq.relation_types rt
                           where rt.relation = e.relation
                             and rt.inverse_label = p_relation))
    )
    -- DISTINCT ON (id) ... ORDER BY depth: a node reachable by several paths
    -- otherwise appears once PER PATH. Confirmed on the fixture: 'Acme
    -- Robotics' came back three times from one walk (depth 1 directly, depth
    -- 2 via two other routes). This mode answers "what is related to this,
    -- and how far away" -- one row per node, at its SHORTEST distance, with
    -- the path that achieved it. That is what REM's lazy-then-load discipline
    -- (brief.md §2) actually needs: a candidate SET to review, then hydrate.
    --
    -- Enumerating every distinct PATH between two nodes is a genuinely
    -- different question (provenance/explanation, not discovery). It is not
    -- this function, and it should not be a boolean flag on this function --
    -- the result shape differs, and callers of the two want different limits.
    -- Left unbuilt until a real consumer needs it.
    -- The same `key` graph_neighbors carries, and for the same reason: a
    -- walk that returns ids is a walk whose result cannot be spoken.
    --
    -- The cap is applied to an ORDERED result, which it previously was not.
    -- `limit p_max_nodes` over a DISTINCT ON's node-id order dropped an
    -- arbitrary subset -- a walk capped at 3 returned three nodes chosen by
    -- uuid. Nearest first, then best-corroborated, so a capped walk keeps the
    -- part of the neighbourhood the caller would have kept.
    select * from (
        select distinct on (w.id) w.id, k.key, w.entity_type, w.summary,
               w.depth, w.rels, w.score
        from walk w
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = w.id and nk.kind = 'canonical'
                            limit 1) k on true
        where w.depth > 0
        order by w.id, w.depth, w.score desc
    ) d
    order by d.depth, d.score desc, d.id
    limit p_max_nodes;
$$ language sql stable;

-- SEMANTIC's corpus registry: which table a `FROM <name>` names, for the
-- vector modes. Registered per corpus rather than hardcoded, because the
-- content belongs to the consumer (world-model-ingestion owns
-- resource_chunks), not to this layer.
create table aiq.semantic_sources (
    name          text primary key,
    source_table  text not null,       -- schema-qualified, has (id, content)
    content_col   text not null default 'content',
    -- Kept, and no longer read by anything. It described the superseded
    -- storage shape below, where the vector was a column on the consumer's own
    -- table. §10 moved embeddings into per-MODEL spaces owned by this schema,
    -- which is what makes two models over one corpus possible at all; a column
    -- on the chunk table can hold exactly one model's output.
    embedding_col text not null default 'embedding',
    link_expr     text                 -- optional SQL expr -> owning node's entity_id
);

-- The superseded implementation, removed rather than left to be found.
--
-- `aiq.semantic(source, vector, limit)` read `<source_table>.<embedding_col>`
-- -- an embedding column on the consumer's own chunk table. §10 replaced that
-- storage model with one table per registered MODEL, and this function was
-- never updated, never called by the dispatch (which routes SEMANTIC to
-- semantic_in), and never declared in surface.sql. It had therefore been
-- broken for as long as the schema has shipped: calling it against the
-- registered `chunks` source raises `column c.embedding does not exist`,
-- because content.resource_chunks has no such column and never did.
--
-- Two implementations of one mode, one of them unreachable and non-working, is
-- worse than one: it is a function an agent can find in the catalog, call, and
-- receive a schema error from. The drop is explicit because `create or replace`
-- cannot remove it from a database that already installed it.
drop function if exists aiq.semantic(text, vector, int);

-- ============================================================
-- 8. Verified properties (measured on PG19 beta3, not asserted).
--
-- graph-identity.md's "Verification" section lists these as the criteria a
-- correct implementation must meet. Results from running them against this
-- schema with a real fixture:
--
--  * LOOKUP is an index probe, NOT an Append of typed-table scans:
--        Nested Loop
--          -> Index Scan using idx_node_keys_canonical on node_keys
--          -> Index Scan using nodes_pkey on nodes
--    This is the whole scale argument (10^9 KEYS stays O(log n)) and it holds.
--
--  * SQL/PGQ is a rewriter onto ordinary joins, exactly as the standard
--    describes. An unfiltered GRAPH_TABLE plans as hash joins over
--    edges + nodes; there is no separate graph engine and no index-free
--    adjacency to hope for.
--
--  * Predicates push down THROUGH GRAPH_TABLE into the base-table indexes,
--    and -- the part worth knowing -- it does not matter whether the
--    predicate is written inside the MATCH pattern
--    (`match (a is node where a.id = $1)`) or applied to the GRAPH_TABLE
--    result (`where g.a_id = $1`). Both produce:
--        Index Only Scan using nodes_pkey  (seed)
--        Bitmap Index Scan on idx_edges_src (expand)
--    So callers need no special construction discipline, and the reverse
--    direction is served by idx_edges_dst the same way. This is a direct
--    consequence of PGQ being a rewriter: the ordinary planner optimises it.
--
--  * Inclusion policy is enforced at projection time: with
--    include_where = 'n.is_public', a private company got no node, no key and
--    therefore could not be an edge endpoint. Data-plane rows
--    (resource_chunks) are never nodes, and the semantic path reaches them
--    through a relational join instead -- the read-path split the design
--    requires, working end to end.
--
--  * A hard FK (events.primary_company_id) is absent from aiq.edges and still
--    answerable by an indexed join -- the "two memories" claim (D4), concrete.
--
-- ------------------------------------------------------------
-- 8b. What a second, exhaustive pass measured -- and what it corrected.
--
-- The results above were measured against a fixture that lived in a psql
-- session and was never committed, so nothing could re-run them. That fixture
-- is now dev/init/04-graph-sample.sql, and the properties above are now
-- assertions in dev/tests/query/04-06 rather than paragraphs. Running the
-- whole surface rather than the happy path changed several of them:
--
--  * "LOOKUP is an index probe, NOT an Append of typed-table scans" is not
--    assertable in that form at any fixture size worth shipping: with 22 keys
--    the planner reads the table sequentially and is correct to. The
--    size-independent statements are that the predicate is index-servable and
--    that the plan touches no registered source table -- which is what
--    invariant 6 actually claims. Recorded because the original phrasing would
--    have had to be neutered to pass, and a neutered assertion is worse than
--    none.
--
--  * The projection was insert-only. An UPDATE that made a row fail the
--    inclusion predicate left its node, its key, and its edges in place --
--    invariant 3 broken by the projection itself -- and a rename ADDED a
--    canonical key rather than replacing one, so the old name resolved
--    forever. Both are fixed above; both were invisible to any assertion that
--    only inserts.
--
--  * The canonical-key unique index was NULLS DISTINCT, so it enforced nothing
--    at all for shared reference data (org_id is null), which is most of a
--    real deployment. Two rows took the key 'acme' and LOOKUP returned both.
--
--  * Generated projection functions were named after the source table's SHORT
--    name, so two registered tables called `thing` in different schemas shared
--    one function and one of them projected under the other's entity_type.
--
--  * GRAPH resolved its seed key with fuzzy matching, always, and took the
--    first row: a typo walked a different node's neighbourhood and the answer
--    said nothing about it. The seed is now exact and reported.
--
--  * The walk ignored edges.weight entirely, contradicting brief.md §3.6's
--    claim to be coherence-ranked, and applied its row cap to a uuid-ordered
--    result.
--
--  * SQL/PGQ is RLS-filtered through the property graph, which was worth
--    checking rather than assuming: a property graph is a separate privilege
--    object compiled to joins, and neither fact settles whether the base
--    tables' policies still apply. They do (dev/tests/query/06 §3).
-- ============================================================

-- ------------------------------------------------------------
-- 9. Single dispatch entry point.
--
-- One PostgREST RPC for the whole dialect, so an agent posts
--     {"p_query": "GRAPH \"acme\" DEPTH 2 TYPE competes_with"}
-- to ONE endpoint rather than choosing between five. This is the
-- "query directly on the API" property the Rust parser exists to enable.
--
-- Parse and execute are deliberately split (see the parser's own comment in
-- the pgrx crate): aiq_parse() is pure computation in Rust, unit-testable
-- off-database, and returns the PLAN; this function executes it in SQL, where
-- the planner, RLS and the indexes already live. A caller can also call
-- aiq_parse() alone to see how its string was understood -- for an
-- agent-facing dialect that matters, because a misparse is otherwise
-- indistinguishable from an empty result.
--
-- Returns jsonb rather than a fixed row type: the modes genuinely return
-- different shapes, and forcing them into one row type would mean a lowest
-- common denominator that loses each mode's useful columns.
-- ------------------------------------------------------------
-- DEPENDENCY: aiq_parse(), from the p8_query extension. REQUIRED, not
-- optional -- the dialect is the primary interface to this layer, and
-- install.sh treats p8_query exactly like pgcrypto or pgvector.
--
-- The per-mode functions (lookup, graph_neighbors, graph_walk, semantic_in,
-- lexical, hybrid) remain plain SQL and callable directly. That is a
-- convenience for SQL clients and a fallback for a broken install, not a
-- supported alternative interface -- new capability lands in the dialect.
--
-- Checked at call time so a missing extension says WHICH extension and how to
-- get it, rather than failing on an unqualified "function does not exist"
-- that reads as a corrupt schema.
create or replace function aiq.query(p_query text, p_embedding vector default null)
returns jsonb as $$
declare
    p        jsonb;
    v_node   uuid;
    v_n      int;
    v_seed   jsonb;
    v_out    jsonb;
    v_unresolved jsonb := '[]'::jsonb;
begin
    if to_regprocedure('aiq_parse(text)') is null then
        raise exception
            'aiq_parse is missing. It ships in the same extension as this '
            'function, so this should be impossible -- if you are seeing it, the '
            'extension is partially installed. The per-mode functions '
            '(aiq.lookup, aiq.graph_neighbors, aiq.graph_walk, aiq.semantic_in, '
            'aiq.lexical, aiq.search) still work directly.';
    end if;
    p := aiq_parse(p_query);

    if not (p->>'ok')::boolean then
        raise exception 'query parse error: %', p->>'error';
    end if;

    case p->>'mode'
    when 'LOOKUP' then
        -- The dialect takes a list, so the dispatch does too. Resolving five
        -- names is one round trip and one plan, not five -- which is the
        -- normal case for an agent holding several entities at once.
        --
        -- A MISS IS NOT A ROW. lookup_many LEFT JOINs deliberately, so a key
        -- that matched nothing comes back as a row of nulls with input_key
        -- echoed -- useful to a SQL caller, who can filter, and actively
        -- misleading here: through this JSON envelope `rows` is non-empty and
        -- a miss is indistinguishable from a hit to anything that does not
        -- inspect the fields. `LOOKUP "sterling"` against a graph holding no
        -- such node returned one row, and a model reading it concluded it had
        -- found something. USAGE.md documented the opposite -- "absent rather
        -- than returned as an empty row" -- so the two halves of this system
        -- disagreed in writing, each with its reasoning stated next to it.
        --
        -- Both intents survive by separating them: matches in `rows`, the
        -- names that resolved to nothing in `unresolved`. The set difference
        -- USAGE.md promises is then handed over directly instead of being left
        -- as an exercise, and an empty result is empty.
        select coalesce(jsonb_agg(to_jsonb(l)) filter (where l.node_id is not null),
                        '[]'::jsonb),
               coalesce(jsonb_agg(distinct l.input_key) filter (where l.node_id is null),
                        '[]'::jsonb)
          into v_out, v_unresolved
        from aiq.lookup_many(
            (select array_agg(value) from jsonb_array_elements_text(p->'args')),
            (p->>'fuzzy')::boolean, (p->>'limit')::int) l;

    when 'GRAPH' then
        -- Four things are checked before anything is walked, and all four are
        -- the same rule the dialect already states for USING: a modifier the
        -- caller wrote and the engine ignored, or a value the engine quietly
        -- reinterpreted, is how a query comes to mean something other than
        -- what it says. Each of these was measured doing exactly that.

        -- (a) FROM names a CORPUS -- which chunk table TEXT/SEMANTIC/SEARCH
        --     read. A walk has no corpus; it starts at a node. The parser
        --     accepts `GRAPH "acme" FROM chunks` and the walk ignored it,
        --     which is the same silent drop USING is refused for. Ideally the
        --     parser would refuse it, next to the USING rule it already
        --     enforces; until the crate is rebuilt this is the backstop, and
        --     it fails in the same direction.
        if p->>'source' is not null then
            raise exception
                'FROM <source> applies only to TEXT, SEMANTIC and SEARCH -- a '
                'walk starts at a node, not in a corpus. Drop `FROM %`.',
                p->>'source';
        end if;

        -- (b) DEPTH below 1 asked for something and got depth 1. `GRAPH "x"
        --     DEPTH 0` returned the full neighbour list, because the dispatch
        --     routed depth <= 1 to graph_neighbors without looking at what
        --     the caller actually wrote.
        if (p->>'depth')::int < 1 then
            raise exception
                'DEPTH must be at least 1 -- DEPTH % asked for no traversal and '
                'would have been served a depth-1 one', p->>'depth';
        end if;

        -- (c) ...and DEPTH above the cap. graph-identity.md's non-goals list
        --     "unbounded traversal" and nothing enforced a bound: DEPTH 1000
        --     was accepted and run. 5 is a working ceiling rather than a
        --     measured one -- the documented discipline is lazy-then-load at
        --     depth 2 (brief.md §2) -- and it is enforced HERE rather than in
        --     graph_walk so a deliberate deep analytic walk can still call the
        --     function directly.
        if (p->>'depth')::int > 5 then
            raise exception
                'DEPTH % exceeds the dialect''s ceiling of 5. The documented '
                'pattern is a shallow walk, then LOOKUP of what looks worth '
                'loading; call aiq.graph_walk() directly if you really want '
                'depth %.', p->>'depth', p->>'depth';
        end if;

        -- (d) A relation nobody ever catalogued is a typo, always -- the write
        --     path refuses one, so the read path should not answer it with an
        --     empty result. `TYPE not_a_relation` returned [], which on this
        --     surface is indistinguishable from "nothing is related".
        if p->>'relation' is not null
           and not exists (select 1 from aiq.relation_types rt
                            where rt.relation = p->>'relation'
                               or rt.inverse_label = p->>'relation') then
            raise exception
                'no relation named % is in the catalogue -- SCHEMA "graph" lists '
                'the registered ones', p->>'relation';
        end if;

        -- Resolve the key ONCE, here, then traverse by id: the dialect names
        -- nodes by key, but traversal never parses names
        -- (graph-identity.md "Edges -- canonical, written directly").
        --
        -- EXACT, and this is a correction. The resolution was
        -- `aiq.lookup(arg, true, 1) limit 1` -- fuzzy, always, take whatever
        -- comes first. So `GRAPH "ACMEE"` walked Acme's neighbourhood and the
        -- answer said nothing about it, and `GRAPH "borealis"` -- a short key
        -- that graph-identity.md's own Bakhmut example says belongs to two
        -- nodes -- picked one of them by coin flip. Neither the typo nor the
        -- ambiguity was visible in the result.
        --
        -- The cascade LOOKUP already runs (canonical, then short, then alias)
        -- is what a seed needs; trigram matching is not, and the dialect has
        -- no FUZZY GRAPH to ask for it with -- `FUZZY` is refused on every
        -- mode but LOOKUP. On a miss the near matches come back as
        -- suggestions, so the affordance survives without the guess.
        select count(*), (array_agg(l.node_id))[1]
          into v_n, v_node
          from aiq.lookup(p->>'arg', false, 50) l;

        if v_n = 0 then
            return jsonb_build_object('mode','GRAPH','plan',p,'rows','[]'::jsonb,
                'error', format('no node matches key %L', p->>'arg'),
                'did_you_mean', coalesce((
                    select jsonb_agg(jsonb_build_object(
                               'key', f.key, 'entity_type', f.entity_type,
                               'score', f.score))
                    from aiq.lookup(p->>'arg', true, 5) f), '[]'::jsonb));
        elsif v_n > 1 then
            return jsonb_build_object('mode','GRAPH','plan',p,'rows','[]'::jsonb,
                'error', format(
                    '%L names %s nodes -- name the one you mean by its canonical key',
                    p->>'arg', v_n),
                'candidates', (
                    select jsonb_agg(jsonb_build_object(
                               'key', c.key, 'entity_type', c.entity_type,
                               'match_kind', c.match_kind))
                    from aiq.lookup(p->>'arg', false, 50) c));
        end if;

        -- Which node was walked, reported alongside the rows. A walk names its
        -- seed by key and answers by id, and the result carried neither -- so
        -- nothing downstream could check that the string it wrote resolved to
        -- the node it meant.
        select jsonb_build_object('node_id', s.node_id, 'key', s.key,
                                  'entity_type', s.entity_type,
                                  'match_kind', s.match_kind)
          into v_seed
          from aiq.lookup(p->>'arg', false, 1) s limit 1;

        if (p->>'depth')::int <= 1 then
            select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) into v_out
            from aiq.graph_neighbors(v_node, p->>'relation', (p->>'limit')::int) g;
        else
            select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) into v_out
            from aiq.graph_walk(v_node, (p->>'depth')::int, p->>'relation',
                                (p->>'limit')::int) w;
        end if;
        return jsonb_build_object('mode','GRAPH','plan',p,'seed',v_seed,'rows',v_out);

    when 'SEMANTIC' then
        -- The embedding is supplied by the caller, not computed here:
        -- embedding generation is an external model call, one of the few
        -- things structurally outside SQL (brief.md §4). The dialect carries
        -- the TEXT so the plan stays legible; the vector arrives alongside it.
        -- USING names the model, so the caller controls WHICH space is
        -- searched -- two 768-dim models are not interchangeable (§10).
        if p_embedding is null then
            raise exception
                'SEMANTIC requires p_embedding -- embed ''%'' with your model and pass the vector',
                p->>'arg';
        end if;
        -- `FROM <source>` is passed through, which it was not: the parser
        -- REQUIRES it on SEMANTIC and the dispatch dropped it, so every
        -- SEMANTIC query searched every registered corpus regardless of the
        -- one the caller was made to name. See semantic_in's own comment for
        -- what that leaked.
        select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_out
        from aiq.semantic_in(p->>'source', p_embedding, p->>'model',
                             (p->>'limit')::int) s;

    when 'TEXT' then
        -- Lexical only. Needs no embedding at all, which is exactly why it
        -- answers the rare-exact-token case (§11) that SEMANTIC misses.
        select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_out
        from aiq.lexical(p->>'source', p->>'arg', (p->>'limit')::int) l;

    when 'SEARCH' then
        if p_embedding is null then
            raise exception
                'SEARCH fuses lexical and semantic ranks, so it needs p_embedding. '
                'Use TEXT ''%'' for the lexical half alone.', p->>'arg';
        end if;
        select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) into v_out
        from aiq.search(p->>'source', p->>'arg', p_embedding, p->>'model',
                        (p->>'limit')::int) h;

    when 'SCHEMA' then
        -- The one mode that returns a document rather than rows, so it says
        -- `schema` rather than pretending to be a one-element result set.
        -- `arg` is '' rather than null when SCHEMA carried no facet -- the
        -- parser emits the first argument of a possibly-empty list -- and the
        -- index is what an empty facet means (§13c).
        return jsonb_build_object('mode','SCHEMA','plan', p,
            'schema', aiq.schema(nullif(p->>'arg', ''), p->>'source'));

    when 'SQL' then
        -- Deliberately NOT executed here. Returning the statement keeps this
        -- function's security mode irrelevant to it; the caller runs it
        -- through the SECURITY INVOKER, read-only-enforced passthrough
        -- (brief.md §3's correction).
        return jsonb_build_object('mode','SQL','statement', p->>'arg',
            'note','execute via the SECURITY INVOKER read-only passthrough, not here');
    else
        raise exception 'unhandled mode %', p->>'mode';
    end case;

    -- `unresolved` only appears where it means something. A key absent from
    -- the envelope is a mode that does not resolve names; a key present and
    -- empty is "every name you gave me resolved". Emitting it always, empty,
    -- for SEMANTIC and TEXT would make the second reading unavailable.
    return jsonb_build_object('mode', p->>'mode', 'plan', p, 'rows', v_out)
        || case when p->>'mode' = 'LOOKUP'
                then jsonb_build_object('unresolved', v_unresolved)
                else '{}'::jsonb end;
end;
$$ language plpgsql stable;

-- ============================================================
-- 10. Embedding spaces: multiple models, multiple dimensions.
--
-- THE CONSTRAINT, measured rather than assumed:
--   * `vector(n)` is fixed-width -- inserting 1536 dims into vector(768)
--     fails with "expected 768 dimensions, not 1536".
--   * An UNTYPED `vector` column DOES accept mixed dimensions, but cannot be
--     indexed at all: `create index ... using hnsw` fails with "column does
--     not have dimensions". So it is unusable for search -- every query
--     becomes a seq scan.
-- Therefore embeddings of different shapes MUST live in different columns
-- with their own indexes. There is no single-table shortcut.
--
-- THE CORRECTION worth stating: the partition key is the MODEL, not the
-- dimension. Two different 768-dimension models do not produce comparable
-- vectors -- cosine distance between them is meaningless, not merely
-- imprecise. Naming storage after the dimension alone (embedding_768) invites
-- exactly that mistake, because it makes two incompatible things look
-- interchangeable. Dimension is an ATTRIBUTE of a model here, never the
-- identity of a space.
--
-- One table per registered model, each with its own typed column and its own
-- HNSW index. A chunk may have rows in several of them simultaneously, which
-- is what makes migrating models (or A/B-ing them) possible without a
-- destructive rewrite: embed into the new space alongside the old, compare,
-- switch the default, drop the old space when nothing references it.
--
-- THE CONSEQUENCE FOR TENANCY, which is not obvious from any of the above and
-- was measured rather than reasoned: a space is keyed by MODEL, so it holds
-- every registered corpus's chunks together, and it has no way to know which
-- consumer table a chunk_id came from -- `chunk_id` deliberately carries no
-- foreign key, because one space serves many corpora. A generated space
-- therefore cannot carry a row policy of its own.
--
-- Two things follow, and only the first is fixed.
--
--  1. THE MODE MUST SCOPE ITSELF. aiq.semantic_in() joins the space to the
--     table registered under the corpus named in `FROM`, which both restricts
--     the search to that corpus and puts the consumer's policies in the path
--     (the mode is SECURITY INVOKER, so the join reads as the caller). Before
--     that join, SEMANTIC returned chunk ids and cosine distances for rows the
--     caller could not read: on the committed fixture, a caller holding org
--     B's claim saw five of six chunks and SEMANTIC returned all six.
--
--  2. THE SPACE ITSELF IS STILL READABLE, and this is a known, open exposure
--     rather than a decision. integration-rbac.sql grants SELECT on this
--     schema's tables -- and sets ALTER DEFAULT PRIVILEGES so spaces
--     registered later are covered -- precisely because the modes are SECURITY
--     INVOKER and must read them as the caller; withholding the grant would
--     break every SEMANTIC call. So `select * from aiq.emb_<model>` still
--     hands any authenticated caller chunk ids and raw vectors for content it
--     cannot read, and raw vectors are not innocuous (embedding inversion is a
--     published attack). Closing it needs per-source row policies generated
--     onto each space from aiq.semantic_sources, refreshed as corpora are
--     registered. That is real machinery and it is not built.
--     dev/tests/query/09 §5 pins the current state so that building it is a
--     deliberate act that updates this paragraph.
-- ============================================================

create table aiq.embedding_models (
    name        text primary key,          -- 'nomic-embed-text', 'text-embedding-3-small'
    dim         int  not null check (dim > 0),
    provider    text not null,             -- 'ollama' | 'openai' | ...
    -- Resolved by the WORKER, not called from SQL -- and it may be written as
    -- a `{{env.X}}` reference ('{{env.LLM_URL}}/api/embeddings'), because the
    -- worker resolves that namespace and the database deliberately cannot.
    -- That is what lets one registry row serve dev, staging and production
    -- without a per-deployment UPDATE.
    endpoint    text,
    -- The env var name the worker reads a bearer token from, for a hosted
    -- provider. Never the token: a secret in a table is a secret in every
    -- backup, every logical replica and every pg_dump.
    credential_ref text,
    distance_op text not null default 'vector_cosine_ops'
                    check (distance_op in ('vector_cosine_ops','vector_l2_ops','vector_ip_ops')),
    is_default  boolean not null default false,
    notes       text,
    created_at  timestamptz not null default now()
);

-- Exactly one default at a time. A partial unique index rather than a trigger:
-- the database enforces it, so a bad deploy fails loudly instead of leaving
-- two defaults and a coin-flip about which one SEMANTIC uses.
create unique index idx_embedding_models_one_default
    on aiq.embedding_models ((true)) where is_default;

-- ------------------------------------------------------------
-- 10a. What an embedding CALL looks like -- one row per provider.
--
-- `provider` above was a label: it recorded which service produced a space and
-- nothing could act on it. Everything needed to actually make the call -- the
-- request body's shape and where the vector sits in the response -- lived in
-- whatever YAML an author happened to write, which is how two workflows in one
-- deployment end up embedding differently against the same model.
--
-- It is a TABLE rather than code in the worker for the reason the rest of this
-- collection is tables: a new provider is then a row, insertable by a
-- deployment that cannot rebuild an image. Both shipped rows were written from
-- the providers' published request formats; a deployment whose gateway differs
-- overrides the row rather than forking anything.
--
-- The template is deliberately ONE LEVEL DEEP, and that is a limit worth
-- naming rather than discovering: `{{model}}` and `{{text}}` are substituted
-- as whole VALUES of top-level keys, never inside a longer string. Substituting
-- into arbitrary nested JSON text would mean escaping author-supplied text into
-- a JSON literal by hand, and hand-rolled JSON escaping is a defect waiting for
-- a quote character. Both providers' bodies are flat objects, so the limit
-- costs nothing today and fails loudly rather than silently if it ever does.
--
-- `{{text}}` may itself arrive holding a workflow template ('{{run.question}}')
-- -- it is left intact, and the worker resolves it at dispatch like any other
-- REST body. Two template layers, resolved in the right order by the two halves
-- that own them.
-- ------------------------------------------------------------
create table aiq.embedding_providers (
    provider         text primary key,
    request_template jsonb not null,
    response_path    text  not null,   -- dotted path, the worker's `jsonpath`
    method           text  not null default 'POST',
    notes            text
);

insert into aiq.embedding_providers (provider, request_template, response_path, notes) values
    ('ollama', '{"model": "{{model}}", "prompt": "{{text}}"}'::jsonb, 'embedding',
     'POST /api/embeddings -- one vector, at the top level under "embedding".'),
    ('openai', '{"model": "{{model}}", "input": "{{text}}"}'::jsonb, 'data.0.embedding',
     'POST /v1/embeddings -- a list, because the API embeds a batch; a single '
     'text still comes back as data[0]. Needs credential_ref on the model row.')
on conflict (provider) do nothing;

-- Each registered model gets its own storage table + HNSW index, generated
-- from the registry so the dimension and operator class can never drift from
-- what the model actually produces.
create or replace function aiq.register_embedding_space(p_model text)
returns void as $$
declare m aiq.embedding_models;
begin
    select * into m from aiq.embedding_models where name = p_model;
    if not found then raise exception 'embedding model % not registered -- SCHEMA "graph" lists the registered ones', p_model; end if;

    execute format($q$
        create table if not exists aiq.%1$I (
            chunk_id   uuid primary key,
            embedding  vector(%2$s) not null,
            embedded_at timestamptz not null default now()
        )$q$, 'emb_' || replace(m.name, '-', '_'), m.dim);

    execute format($q$
        create index if not exists %1$I on aiq.%2$I
        using hnsw (embedding %3$s)$q$,
        'idx_' || replace(m.name,'-','_') || '_hnsw',
        'emb_' || replace(m.name, '-', '_'), m.distance_op);
end;
$$ language plpgsql;

-- SEMANTIC against a named corpus and a named model (or the default model when
-- null). The caller still supplies the vector -- embedding generation is an
-- external model call (§4), and which model produced that vector is now
-- explicit rather than implied.
--
-- THE SOURCE IS FIRST AND IT IS NOT OPTIONAL, and that is a security fix, not
-- a signature preference.
--
-- This function took (vector, model, limit) and searched the whole embedding
-- space. The space is keyed by MODEL, not by corpus, so it holds every
-- registered corpus's chunks together; and `aiq.emb_*` tables carry no
-- row-level policy, because a generated space has no way to know which
-- consumer table a chunk_id came from. So the mode returned chunk ids and
-- cosine distances for rows the caller could not read.
--
-- Measured, on the committed fixture: a caller holding org B's claim can see
-- five of six chunks -- content's own RLS correctly hides org A's memo -- and
-- SEMANTIC returned all six, org A's memo included, at rank three. The text
-- did not come back, but the id, the existence and the similarity did, and a
-- similarity oracle over private content that answers an arbitrary probe
-- vector is the whole attack, not a precursor to it.
--
-- The dialect made this worse rather than causing it: the parser REQUIRES
-- `FROM <source>` on SEMANTIC ("SEMANTIC, TEXT and SEARCH each require FROM
-- <source>"), and the dispatch then dropped it on the floor and searched
-- everything. The caller was compelled to name a corpus that was not used.
--
-- The fix is the join, and it fixes both halves at once: joining the space to
-- the registered source table scopes the search to the corpus the caller
-- named, AND puts the consumer's own RLS in the path, because this function is
-- SECURITY INVOKER and the join reads as the caller.
--
-- The cost is honest to state: an HNSW scan feeding a join that may discard
-- rows means the index can be walked further than `limit` rows to fill the
-- result. That is the price of a filtered vector search and it is the correct
-- price to pay; the alternative is a fast wrong answer.
--
-- What this does NOT fix, and what dev/tests/query/09 pins: `aiq.emb_*` is
-- still directly SELECT-able by `authenticated`, because integration-rbac.sql
-- grants the schema's tables so that SECURITY INVOKER modes can read them. A
-- caller who queries the space directly still sees chunk ids and raw vectors
-- for content they cannot read. Closing that needs per-source policies on
-- generated spaces, which is real machinery and is not built.
drop function if exists aiq.semantic_in(vector, text, int);
create or replace function aiq.semantic_in(
    p_source text, p_query vector, p_model text default null, p_limit int default 10
) returns table(chunk_id uuid, distance float8, model text) as $$
declare
    m aiq.embedding_models;
    src aiq.semantic_sources;
    v_tbl text;
begin
    if p_source is null then
        raise exception
            'SEMANTIC needs the corpus it is searching -- name one with '
            'FROM <source>. Without it a vector search reads every registered '
            'corpus and cannot be filtered by the consumer''s own policies.';
    end if;
    select * into src from aiq.semantic_sources where name = p_source;
    if not found then
        raise exception 'semantic source % not registered -- SCHEMA "graph" lists the registered ones', p_source;
    end if;
    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
        if not found then raise exception
            'no default embedding model -- set one, or name a model explicitly'; end if;
    else
        select * into m from aiq.embedding_models where name = p_model;
        if not found then raise exception 'embedding model % not registered -- SCHEMA "graph" lists the registered ones', p_model; end if;
    end if;

    -- Dimension mismatch is caught HERE with a message naming both sides,
    -- rather than surfacing as pgvector's bare "expected N dimensions".
    -- Querying the wrong space is the single easiest mistake to make once
    -- more than one model exists.
    if vector_dims(p_query) <> m.dim then
        raise exception
            'query vector has % dimensions but model % expects % -- embedded with the wrong model?',
            vector_dims(p_query), m.name, m.dim;
    end if;

    -- The join is the filter. `c` is the consumer's table, read as the caller,
    -- so the consumer's policies decide which chunks may rank at all -- and
    -- ranks are computed after it, so a chunk the caller cannot see does not
    -- silently occupy a position and shift everyone else's fused score.
    v_tbl := 'emb_' || replace(m.name, '-', '_');
    return query execute format(
        'select e.chunk_id, (e.embedding <=> $1)::float8, %L
         from aiq.%I e
         join %s c on c.id = e.chunk_id
         order by e.embedding <=> $1 limit $2', m.name, v_tbl, src.source_table)
        using p_query, p_limit;
end;
$$ language plpgsql stable;

-- ============================================================
-- 11. Lexical search -- the mode that was missing entirely.
--
-- THE GAP, demonstrated rather than argued: the dialect had LOOKUP (exact
-- keys), FUZZY (trigram over KEYS), SEMANTIC (vectors) and GRAPH -- and
-- nothing that searches document TEXT lexically. Asking for the part number
-- "R7", which appears verbatim in a chunk:
--     LOOKUP 'R7'        -> 0 hits   (node_keys only; chunks are not nodes)
--     LOOKUP 'R7' FUZZY  -> 0 hits   (trigram over keys, not content)
--     native FTS         -> found it immediately
-- Rare exact tokens -- part numbers, tickers, error codes, case IDs, proper
-- nouns -- are precisely where embeddings are weakest and lexical search is
-- strongest, which is why production RAG is near-universally hybrid. We had
-- only half of it.
--
-- Native tsvector/ts_rank, NOT BM25, and the difference is worth being honest
-- about: ts_rank uses its own length-normalisation and has no k1/b term
-- saturation, so a term occurring 20 times keeps accruing score in a way BM25
-- deliberately damps. For short chunks the practical difference is small; for
-- long documents with repeated terms it is not.
--
-- Chosen as the DEFAULT anyway because it is permissive-licensed, already in
-- core Postgres, costs one GIN index and zero new dependencies. pg_search
-- (ParadeDB, real BM25) is the promote-on-evidence upgrade -- see
-- meta/postgres-manifest.md for its AGPLv3 posture, which is the one
-- non-permissive license in the collection and deserves a deliberate decision
-- rather than a default.
-- ============================================================

create table aiq.lexical_sources (
    name         text primary key,
    source_table text not null,
    content_col  text not null default 'content',
    regconfig    text not null default 'english'
);

-- A generated tsvector column + GIN index is the standard shape: the vector
-- is maintained by Postgres on write, never by application code that can
-- forget, and the index is what makes it a search rather than a scan.
create or replace function aiq.register_lexical_source(
    p_name text, p_source_table text,
    p_content_col text default 'content', p_regconfig text default 'english'
) returns void as $$
declare v_short text := split_part(p_source_table, '.', 2);
begin
    insert into aiq.lexical_sources (name, source_table, content_col, regconfig)
    values (p_name, p_source_table, p_content_col, p_regconfig)
    on conflict (name) do update set source_table = excluded.source_table,
        content_col = excluded.content_col, regconfig = excluded.regconfig;

    execute format(
        'alter table %s add column if not exists search_tsv tsvector
         generated always as (to_tsvector(%L, coalesce(%I, ''''))) stored',
        p_source_table, p_regconfig, p_content_col);
    execute format(
        'create index if not exists %I on %s using gin (search_tsv)',
        'idx_' || v_short || '_tsv', p_source_table);
end;
$$ language plpgsql;

-- TEXT mode. Deliberately returns the same (id, score) shape as
-- aiq.semantic_in() so the two can be fused without reshaping either.
create or replace function aiq.lexical(
    p_source text, p_query text, p_limit int default 10
) returns table(chunk_id uuid, content text, score real) as $$
declare s aiq.lexical_sources;
begin
    select * into s from aiq.lexical_sources where name = p_source;
    if not found then raise exception 'lexical source % not registered -- SCHEMA "graph" lists the registered ones', p_source; end if;
    return query execute format(
        'select c.id, c.%I::text, ts_rank(c.search_tsv, plainto_tsquery(%L, $1))::real
         from %s c where c.search_tsv @@ plainto_tsquery(%L, $1)
         order by ts_rank(c.search_tsv, plainto_tsquery(%L, $1)) desc limit $2',
        s.content_col, s.regconfig, s.source_table, s.regconfig, s.regconfig)
        using p_query, p_limit;
end;
$$ language plpgsql stable;

-- SEARCH: reciprocal rank fusion of lexical + semantic.
--
-- RRF rather than score-weighted blending, deliberately: ts_rank and cosine
-- distance are not on the same scale, not even the same direction (higher is
-- better vs lower is better), and no fixed normalisation of the two survives a
-- change of model or corpus. RRF only uses RANK, so it is invariant to both.
-- k=60 is the value from the original RRF paper and the common default; it
-- damps the contribution of low-ranked items without a tunable that needs
-- per-corpus fitting.
--
-- This is the mode that answers the "R7" case AND "is this product
-- dangerous?" with one call -- which is the actual argument for a unified
-- dialect over three separate APIs.
create or replace function aiq.search(
    p_lexical_source text, p_query_text text,
    p_query_vector vector, p_model text default null,
    p_limit int default 10, p_k int default 60
) returns table(chunk_id uuid, content text, rrf_score real,
                lexical_rank int, semantic_rank int) as $$
declare
    src aiq.lexical_sources;
begin
    select * into src from aiq.lexical_sources where name = p_lexical_source;
    if not found then
        raise exception 'lexical source % not registered -- SCHEMA "graph" lists the registered ones', p_lexical_source;
    end if;

    return query execute format($q$
    with lex as (
        select l.chunk_id, row_number() over (order by l.score desc)::int as rnk
        from aiq.lexical($1, $2, $4 * 4) l
    ),
    sem as (
        -- The SAME source name feeds both halves, so `SEARCH "..." FROM x`
        -- means one corpus and not two. It must therefore be registered in
        -- both registries; the semantic branch says so by name if it is not.
        select s.chunk_id, row_number() over (order by s.distance asc)::int as rnk
        from aiq.semantic_in($1, $3, $6, $4 * 4) s
    )
    -- Content is fetched by id AFTER the fusion, not carried through the
    -- lexical branch: a chunk matched only semantically has no row in `lex`,
    -- so taking content from there returns NULL for exactly the results the
    -- semantic side contributed. Found by running it -- the fused output had
    -- blank content for every vector-only hit.
    select f.chunk_id, c.%1$I::text, f.rrf, f.lexical_rank, f.semantic_rank
    from (
        select coalesce(lex.chunk_id, sem.chunk_id) as chunk_id,
               (coalesce(1.0 / ($5 + lex.rnk), 0)
                + coalesce(1.0 / ($5 + sem.rnk), 0))::real as rrf,
               lex.rnk as lexical_rank, sem.rnk as semantic_rank
        from lex full outer join sem on sem.chunk_id = lex.chunk_id
    ) f
    join %2$s c on c.id = f.chunk_id
    order by f.rrf desc
    limit $4
    $q$, src.content_col, src.source_table)
    using p_lexical_source, p_query_text, p_query_vector, p_limit, p_k, p_model;
end;
$$ language plpgsql stable;

-- ------------------------------------------------------------
-- 12. The SQL escape hatch, actually implemented.
--
-- §9 returned the statement and told the caller to run it "via the SECURITY
-- INVOKER read-only passthrough" -- which did not exist. Written now, because
-- a spec that names a component it never defines is exactly the kind of gap
-- these prototype rounds keep finding.
--
-- SECURITY INVOKER, not DEFINER (brief.md §3's correction): this function
-- executes caller-supplied SQL, so DEFINER would make it an RLS-bypass and
-- privilege-escalation primitive -- the same class of bug as workflow's
-- cancel_run and rbac's grant_role, and the reason those were fixed.
--
-- Read-only is enforced by the DATABASE, not by inspecting the string. A
-- parser that tries to decide whether SQL is "read-only" is a filter to be
-- bypassed; a read-only transaction is a guarantee. Any write, DDL, or
-- function with a side effect raises inside the block and the whole thing
-- aborts.
-- ------------------------------------------------------------
create or replace function aiq.sql_passthrough(p_statement text)
returns jsonb as $$
declare
    v_result jsonb;
begin
    -- Rejected up front only for the things that are unambiguous and cheap to
    -- catch, giving a clear error instead of a confusing transaction abort.
    -- This is a courtesy, NOT the security boundary -- the read-only
    -- transaction below is.
    if p_statement ~* '^\s*(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy)\M' then
        raise exception
            'the SQL passthrough is read-only: statement starts with a write/DDL keyword';
    end if;

    -- The actual boundary. set_config(..., true) is transaction-local, so it
    -- reverts on commit or rollback and cannot leak into a pooled connection's
    -- next transaction -- the same pooling hazard rbac.current_user_id() was
    -- hardened against.
    perform set_config('transaction_read_only', 'on', true);

    execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (%s) t', p_statement)
    into v_result;

    return v_result;
end;
$$ language plpgsql volatile security invoker;

-- ============================================================
-- 13. `SCHEMA` -- the mode that answers "what IS this database".
--
-- Every other mode requires you to already know something: a key to look up,
-- a source to search, a relation to walk. An agent arriving cold can write
-- none of them. `SCHEMA` is the one query answerable before you know
-- anything, and bare `SCHEMA` returns the index of what you may ask about.
--
-- The reason to build it here rather than hand agents markdown: the registries
-- it reports on ALREADY EXIST and are already the truth --
-- `aiq.entity_registry`, `aiq.relation_types`, `aiq.semantic_sources`,
-- `aiq.lexical_sources`, `aiq.embedding_models`, `workflow.step_functions`,
-- `agentic.agents`. Every one of them is a table a caller could read if it
-- knew to. Nothing joins them into one caller-facing surface, and the failure
-- that costs is visible in this file's own error messages: `semantic source %
-- not registered` tells you the name was wrong and nothing about which names
-- are right.
--
-- THREE COMMITMENTS, each of which is what makes this a capability report
-- rather than documentation:
--
--   1. DERIVED BEATS DECLARED, AND THE SPLIT IS VISIBLE. Anything the catalog
--      can prove is read from the catalog -- the legal `kind` values come off
--      the check constraint, the callable functions off the allow-list, the
--      relation catalogue off the table that enforces it. What a catalog
--      cannot express (what a `matrix` step is FOR, how the YAML is spelled)
--      is emitted by the Rust crate that implements it, so the grammar an
--      agent reads is the grammar that parses its input. Every facet reports
--      both halves under `derived` and `declared`, so a reader knows which
--      half could go stale.
--
--   2. EXAMPLES ARE VERIFIED BY EXECUTION, NOT TRUSTED. The example corpus is
--      a table, and every read feeds each example back through the real parser
--      (`aiq_parse`) or the real compiler (`p8_compile_workflow`) and reports
--      what it did. An example that stops parsing says so on its own row
--      rather than teaching an agent a syntax this deployment no longer
--      accepts. This is the same discipline `../../surface.sql` applies to
--      capabilities, applied to the sentences that describe them.
--
--   3. THE VERSION IS A HASH, NOT A NUMBER SOMEBODY REMEMBERS TO BUMP.
--      `aiq.schema_revisions` records one row per facet per distinct content
--      hash, so "versioned and maintained with updates" is literal: registering
--      a step function, adding a relation type or shipping a new step kind
--      changes the hash, and capture writes a new revision you can diff
--      against the last. A hand-maintained semver would be a second thing to
--      keep true, and this collection's whole method is to not have those.
--
-- A FACET IS A REGISTRATION, NOT A BRANCH. `SCHEMA "tradecraft"` over
-- `tradecraft.likelihood`/`evidence_classes`/`source_reliability`, or a facet
-- over `content.v_required_credentials`, needs an INSERT and a function --
-- never a change to the parser or to this dispatch. That is the extensibility
-- the "soft schema we might add later" case actually requires, and it is the
-- second-consumer evidence that justifies a registry over a CASE statement.
-- ============================================================

create table if not exists aiq.schema_facets (
    name          text primary key,          -- what SCHEMA "<name>" names
    provider_fn   text not null,             -- schema-qualified, (text) -> jsonb
    title         text not null,
    description   text not null,
    -- A GLOBAL facet describes the deployment and reads the same for
    -- everyone, so its provider is SECURITY DEFINER over metadata tables no
    -- user role holds a grant on. A CALLER-SCOPED facet describes what YOU can
    -- reach, so its provider must be SECURITY INVOKER -- a schema document
    -- listing tables the reader cannot select from is both a leak and a lie.
    caller_scoped boolean not null default false,
    registered_at timestamptz not null default now()
);

-- Owner-only, and for the same reason workflow.register_step_function is: it
-- decides what a `SCHEMA` query can cause to run.
create or replace function aiq.register_schema_facet(
    p_name text, p_fn text, p_title text, p_description text,
    p_caller_scoped boolean default false
) returns void as $$
begin
    if to_regprocedure(p_fn || '(text)') is null then
        raise exception
            'schema facet provider %(text) does not exist. A provider takes the optional '
            'FROM argument (null when absent) and returns jsonb.', p_fn;
    end if;
    insert into aiq.schema_facets (name, provider_fn, title, description, caller_scoped)
    values (lower(p_name), p_fn, p_title, p_description, p_caller_scoped)
    on conflict (name) do update set provider_fn = excluded.provider_fn,
        title = excluded.title, description = excluded.description,
        caller_scoped = excluded.caller_scoped;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 13a. The example corpus -- data, and checked by running it.
--
-- Few-shot examples are the single most useful thing a schema document can
-- give an agent, and the single most likely thing to go quietly wrong: an
-- example written against an older dialect keeps being served, keeps looking
-- authoritative, and teaches a syntax that now fails. So examples are rows,
-- and every read executes them.
--
-- `kind` says which executor verifies it. Adding a third (a p8ql fragment, a
-- cron expression, a JSON spec) is a new branch in aiq.verify_example and
-- nothing else.
-- ------------------------------------------------------------
create table if not exists aiq.schema_examples (
    facet     text not null references aiq.schema_facets(name) on delete cascade,
    label     text not null,
    kind      text not null check (kind in ('p8ql', 'workflow_yaml')),
    example   text not null,
    note      text,
    ordinal   int  not null default 100,
    primary key (facet, label)
);

create or replace function aiq.register_schema_example(
    p_facet text, p_label text, p_kind text, p_example text,
    p_note text default null, p_ordinal int default 100
) returns void as $$
    insert into aiq.schema_examples (facet, label, kind, example, note, ordinal)
    values (lower(p_facet), p_label, p_kind, p_example, p_note, p_ordinal)
    on conflict (facet, label) do update set kind = excluded.kind,
        example = excluded.example, note = excluded.note, ordinal = excluded.ordinal;
$$ language sql;

-- Run one example through the thing that actually consumes it.
--
-- `verified` is three-valued on purpose. true/false is a claim about the
-- example; null means "this deployment cannot check" -- which is what you get
-- when the extension is older than the example's kind. Collapsing null into
-- false would report a correct example as broken every time the .so lags the
-- schema, and collapsing it into true would report an unchecked example as
-- proven. Neither is the truth, so neither is what is returned.
create or replace function aiq.verify_example(p_kind text, p_example text)
returns jsonb as $$
declare v jsonb;
begin
    if p_kind = 'p8ql' then
        if to_regprocedure('aiq_parse(text)') is null then
            return jsonb_build_object('verified', null,
                'note', 'aiq_parse is unavailable -- the p8_query extension is not installed');
        end if;
        v := aiq_parse(p_example);
        return jsonb_build_object('verified', coalesce((v->>'ok')::boolean, false),
                                  'plan', v);
    elsif p_kind = 'workflow_yaml' then
        if to_regprocedure('p8_compile_workflow(text)') is null then
            return jsonb_build_object('verified', null,
                'note', 'p8_compile_workflow is unavailable -- the percolate extension is not installed');
        end if;
        v := p8_compile_workflow(p_example);
        return jsonb_build_object('verified', coalesce((v->>'ok')::boolean, false),
                                  'compiles_to', v->'workflow'->'spec',
                                  'error', v->>'error');
    end if;
    raise exception 'unknown example kind %', p_kind;
end;
$$ language plpgsql stable;

create or replace function aiq.facet_examples(p_facet text)
returns jsonb as $$
    select coalesce(jsonb_agg(
        jsonb_build_object('label', e.label, 'kind', e.kind, 'example', e.example,
                           'note', e.note)
        || aiq.verify_example(e.kind, e.example)
        order by e.ordinal, e.label), '[]'::jsonb)
    from aiq.schema_examples e where e.facet = p_facet;
$$ language sql stable;

-- ------------------------------------------------------------
-- 13b. Revisions -- what "versioned and maintained with updates" means here.
--
-- Reads never write. A schema query is on the read path and must stay
-- `stable`; recording a revision from it would also mean a poll loop writes a
-- row every time nothing has changed. So capture is a separate, deliberate
-- act -- `aiq.capture_schema_revisions()` -- run from CI next to
-- ../../surface.sql, or as a scheduled workflow, or by hand after a
-- migration.
--
-- The consequence is the interesting part: a read can find that the live hash
-- differs from the last recorded revision, and it SAYS SO (`captured: false`)
-- rather than silently serving an uncaptured document as if it were versioned.
-- That is the drift signal. An agent that caches by hash still gets a correct
-- answer; an operator watching `aiq.schema_drift()` learns the schema moved
-- and nobody recorded it.
-- ------------------------------------------------------------
create table if not exists aiq.schema_revisions (
    facet       text not null references aiq.schema_facets(name) on delete cascade,
    revision    int  not null,
    hash        text not null,
    doc         jsonb not null,
    captured_at timestamptz not null default now(),
    primary key (facet, revision)
);
create index if not exists idx_schema_revisions_hash on aiq.schema_revisions (facet, hash);

-- The one place a facet is produced, so hashing, scoping and the FROM
-- argument cannot be done three slightly different ways.
--
-- The hash covers the document only -- not the revision, not the timestamp --
-- because it has to be comparable across captures. Timestamps in a hashed
-- payload make every capture a new revision, which is a changelog of nothing.
create or replace function aiq.render_facet(p_facet text, p_name text default null)
returns jsonb as $$
declare
    f    aiq.schema_facets;
    v    jsonb;
begin
    select * into f from aiq.schema_facets where name = lower(p_facet);
    if not found then
        raise exception
            'no schema facet named %. Registered facets: %',
            p_facet,
            coalesce((select string_agg(name, ', ' order by name) from aiq.schema_facets),
                     '(none)');
    end if;
    execute format('select %s($1)', f.provider_fn) into v using p_name;
    return coalesce(v, '{}'::jsonb);
end;
$$ language plpgsql stable;

-- Record a revision for every facet whose content hash has moved. Returns the
-- facets it captured, so a CI step can print what changed rather than only
-- that something did.
--
-- Caller-scoped facets are captured as the OWNER sees them, and that is the
-- honest definition: the revision describes what this DATABASE is, while a
-- caller's read describes what that caller can reach. A read of a
-- caller-scoped facet therefore carries `scoped: true` next to the global
-- revision, so nobody mistakes the hash for a hash of what they received.
create or replace function aiq.capture_schema_revisions()
returns table (facet text, revision int, hash text) as $$
declare
    f      aiq.schema_facets;
    v_doc  jsonb;
    v_hash text;
    v_last text;
    v_rev  int;
begin
    for f in select * from aiq.schema_facets order by name loop
        v_doc  := aiq.render_facet(f.name, null);
        v_hash := md5(v_doc::text);

        select r.hash into v_last from aiq.schema_revisions r
        where r.facet = f.name order by r.revision desc limit 1;

        if v_last is distinct from v_hash then
            select coalesce(max(r.revision), 0) + 1 into v_rev
            from aiq.schema_revisions r where r.facet = f.name;
            insert into aiq.schema_revisions (facet, revision, hash, doc)
            values (f.name, v_rev, v_hash, v_doc);
            facet := f.name; revision := v_rev; hash := v_hash;
            return next;
        end if;
    end loop;
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

-- Which facets have moved since anyone recorded them. The read-only half of
-- capture, so a CI gate can fail on drift without writing anything.
create or replace function aiq.schema_drift()
returns table (facet text, live_hash text, recorded_hash text, recorded_at timestamptz) as $$
    select f.name,
           md5(aiq.render_facet(f.name, null)::text),
           r.hash,
           r.captured_at
    from aiq.schema_facets f
    left join lateral (
        select hash, captured_at from aiq.schema_revisions
        where facet = f.name order by revision desc limit 1) r on true
    where r.hash is distinct from md5(aiq.render_facet(f.name, null)::text)
    order by f.name;
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13c. The read. `SCHEMA` with no argument is the index.
--
-- SECURITY INVOKER, deliberately: a caller-scoped provider has to see the
-- caller. Everything it reads directly (the three tables above) is deployment
-- metadata already granted to `authenticated`, the same way
-- aiq.entity_registry and workflow.step_functions already are.
-- ------------------------------------------------------------
create or replace function aiq.schema(p_facet text default null, p_name text default null)
returns jsonb as $$
declare
    f      aiq.schema_facets;
    v_doc  jsonb;
    v_hash text;
    r      record;
begin
    -- The index. Deliberately cheap -- it does NOT render every facet to
    -- report their hashes, because rendering the whole deployment to answer
    -- "what may I ask about" would make the one query an agent writes first
    -- the most expensive one it ever writes.
    if p_facet is null or btrim(p_facet) = '' then
        return jsonb_build_object(
            'facet', null,
            'facets', coalesce((
                select jsonb_agg(jsonb_build_object(
                    'name', f2.name, 'title', f2.title, 'description', f2.description,
                    'caller_scoped', f2.caller_scoped,
                    -- Double quotes: %L would emit the single-quoted form,
                    -- which parses but is not how the dialect is written down
                    -- anywhere else, and an index whose copy-paste spelling
                    -- differs from the documentation teaches a second dialect.
                    'query', format('SCHEMA "%s"', f2.name),
                    'revision', (select max(revision) from aiq.schema_revisions
                                 where facet = f2.name))
                order by f2.name) from aiq.schema_facets f2), '[]'::jsonb),
            'note', 'Ask for one with SCHEMA "<name>". Some facets narrow with FROM, '
                    'e.g. SCHEMA "sql" FROM chunks.');
    end if;

    select * into f from aiq.schema_facets where name = lower(p_facet);
    if not found then
        raise exception
            'no schema facet named %. Write SCHEMA with no argument for the list.', p_facet;
    end if;

    v_doc  := aiq.render_facet(f.name, p_name);
    v_hash := md5(v_doc::text);

    select revision, hash, captured_at into r from aiq.schema_revisions
    where facet = f.name order by revision desc limit 1;

    return jsonb_build_object(
        'facet',       f.name,
        'title',       f.title,
        'description', f.description,
        'narrowed_to', p_name,
        -- For a global facet these agree or the schema has moved since the
        -- last capture. For a caller-scoped one they are not expected to
        -- agree at all, which is exactly what `scoped` says.
        'scoped',      f.caller_scoped,
        'hash',        v_hash,
        'revision',    r.revision,
        'captured_at', r.captured_at,
        'captured',    case when f.caller_scoped then null
                            else (r.hash is not distinct from v_hash) end,
        'doc',         v_doc);
end;
$$ language plpgsql stable security invoker;

-- ------------------------------------------------------------
-- 13d. Facet: p8ql -- the dialect, described by what parses it.
--
-- The declared half comes from `p8_query_grammar()` in the parser crate, so
-- there is exactly one copy of the grammar and it lives next to the code that
-- implements it. When the extension predates that function the facet says so
-- by name and still returns the examples, which are verified against the
-- parser that IS installed -- so the useful half never depends on the
-- packaging step.
-- ------------------------------------------------------------
create or replace function aiq.schema_p8ql(p_name text default null)
returns jsonb as $$
declare v_grammar jsonb;
begin
    if to_regprocedure('p8_query_grammar()') is null then
        v_grammar := jsonb_build_object('unavailable',
            'p8_query_grammar() is not in the installed extension -- the grammar prose '
            'ships with the parser, so this deployment''s .so predates it. The examples '
            'below are still verified against the parser that IS installed.');
    else
        execute 'select p8_query_grammar()' into v_grammar;
    end if;

    return jsonb_build_object(
        'declared', v_grammar,
        'derived', jsonb_build_object(
            'parser_installed', to_regprocedure('aiq_parse(text)') is not null,
            -- Which corpora the content-searching modes may name in FROM.
            -- These are the registries whose "not registered" errors do not
            -- list the alternatives; this is where the alternatives live.
            'text_sources',     coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name, 'regconfig', regconfig) order by name)
                                 from aiq.lexical_sources), '[]'::jsonb),
            'semantic_sources', coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name) order by name)
                                 from aiq.semantic_sources), '[]'::jsonb),
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                                    'name', name, 'dim', dim, 'provider', provider,
                                    'is_default', is_default) order by name)
                                 from aiq.embedding_models), '[]'::jsonb)),
        'examples', aiq.facet_examples('p8ql'));
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13e. Facet: workflow -- enough to author one unaided.
--
-- The derived half is the part that matters and the part that cannot drift.
-- `step_kinds` is read off the CHECK CONSTRAINT rather than listed, so
-- shipping a new kind (as `matrix` was) updates this document with no edit
-- here; `step_functions` is the allow-list itself, with the real registered
-- signatures, so an agent writing a `sql:` step is reading the same row the
-- executor will look the function up in.
--
-- SECURITY DEFINER because workflow.queue_config and agentic.agents hold no
-- grants for user roles. Only names and shapes are returned -- no run, task or
-- session data crosses this boundary. Queue and agent names are deployment
-- topology, and an agent that cannot see them cannot author a step that
-- routes anywhere.
-- ------------------------------------------------------------
create or replace function aiq.schema_workflow(p_name text default null)
returns jsonb as $$
declare
    v_grammar jsonb;
    v_kinds   text[];
    v_def     text;
begin
    if to_regprocedure('p8_workflow_grammar()') is null then
        v_grammar := jsonb_build_object('unavailable',
            'p8_workflow_grammar() is not in the installed extension. The step vocabulary '
            'ships with the compiler that reads it; this deployment''s .so predates it. '
            'The derived half below is complete, and the examples are compiled against '
            'the compiler that IS installed.');
    else
        execute 'select p8_workflow_grammar()' into v_grammar;
    end if;

    -- Off the constraint, not off a list. `kind in ('work','decision',...)`
    -- becomes an array of the quoted literals inside it.
    select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'workflow' and t.relname = 'tasks' and c.conname = 'tasks_kind_check';

    if v_def is not null then
        select array_agg(m[1] order by ord) into v_kinds
        from regexp_matches(v_def, '''([a-z_]+)''', 'g') with ordinality as x(m, ord);
    end if;

    return jsonb_build_object(
        'declared', v_grammar,
        'derived', jsonb_build_object(
            -- SUPPORTED vs AUTHORABLE, and the split was found the hard way.
            -- step_kinds is derived from the engine's check constraint, so it
            -- was true about the ENGINE and false about what a person can
            -- write: an agent read all eight kinds as legal, authored a
            -- `signal` step, and the compiler refused it. Deriving from the
            -- catalog protects against drift; it does not protect against
            -- describing the wrong layer. A capability document has to be
            -- derived from the layer the reader will act THROUGH.
            'step_kinds', coalesce(to_jsonb(v_kinds), '[]'::jsonb),
            -- Not a list of what the compiler is SUPPOSED to accept -- what
            -- the installed one actually does, probed with a canary per
            -- feature. The two halves of this system can ship out of step, and
            -- when they do the compile error describes a syntax problem in a
            -- document whose syntax is correct. Someone lost an afternoon to
            -- that; this is so nobody loses a second.
            'compiler', workflow.compiler_capabilities(),
            'authorable_in_yaml', to_jsonb(array[
                'work','sql','http_call','matrix','signal','timer','sub_workflow']),
            'engine_only', coalesce((
                select jsonb_agg(k) from unnest(v_kinds) k
                where k <> all(array['work','sql','http_call','matrix',
                                     'signal','timer','sub_workflow'])), '[]'::jsonb),
            'kinds_note', 'step_kinds is what the ENGINE accepts; authorable_in_yaml is '
                          'what the compiler accepts. Anything in engine_only is reachable '
                          'only by inserting a spec as JSON.',
            'step_functions', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'arg_types', to_jsonb(arg_types),
                    'timeout_ms', timeout_ms, 'description', description) order by name)
                from workflow.step_functions), '[]'::jsonb),
            -- QUEUES ARE UNIONED FROM THREE PLACES, and the first version read
            -- only queue_config. Running a real fan-out exposed why that was
            -- useless: queue_config holds per-queue TUNING and is empty on a
            -- deployment that has not tuned anything, so the facet reported
            -- `queues: []` on a database with a live worker polling `http`.
            -- An agent authoring a `rest:` step was told the one queue that
            -- works does not exist.
            --
            -- A queue is not a registry entry; it is a string a worker polls
            -- and a step names. So the honest answer is every queue anything
            -- has actually used, with where each was learned from -- and the
            -- explicit caveat that a worker which has never claimed anything
            -- is invisible here, because nothing in the database knows it
            -- exists.
            'queues', coalesce((
                select jsonb_agg(jsonb_build_object('queue', q.queue, 'seen_in', q.src)
                       order by q.queue)
                from (
                    select queue, min(src) as src from (
                        select queue, 'queue_config (tuned)' as src from workflow.queue_config
                        union all
                        select distinct queue, 'in use by tasks' from workflow.tasks
                        where queue <> 'none'
                    ) u group by queue
                ) q), '[]'::jsonb),
            'queues_note', 'Unioned from per-queue tuning config and queues tasks have '
                           'actually used. A worker polling a queue that has never had a '
                           'task is not visible: nothing in the database records it.',
            'agents', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'model', model) order by name)
                from agentic.agents), '[]'::jsonb),
            -- What an `embed:` step -- and therefore a SEMANTIC or SEARCH
            -- `p8ql:` step, which compiles to one -- may name. It belongs in
            -- THIS facet and not only in `graph`, on the rule the queues note
            -- above was written for: an author is told what they may write in
            -- the document they are writing, not sent to a second facet to
            -- find out whether the step they just authored can run.
            --
            -- `callable` is the half a registration can get wrong: a model row
            -- with no endpoint, or a provider with no request shape, is
            -- registered as a SPACE and unusable as a STEP -- and the two
            -- registrations are made in different places by different people.
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', m.name, 'dim', m.dim, 'provider', m.provider,
                    'is_default', m.is_default,
                    'callable', (m.endpoint is not null and p.provider is not null))
                    order by m.name)
                from aiq.embedding_models m
                left join aiq.embedding_providers p on p.provider = m.provider), '[]'::jsonb),
            'embedding_note', 'An `embed:` step names a model, never a url: the endpoint, '
                              'request shape and response path come from aiq.embedding_models '
                              'and aiq.embedding_providers, and define_yaml writes them in. '
                              'A SEMANTIC or SEARCH `p8ql:` step compiles to one of these '
                              'plus the search, and the model is pinned into both halves.',
            -- Everything a template can name. {{run.*}} reads the run INPUT;
            -- the run's own identity is under the reserved $ prefix, because
            -- an input key called `id` is not unusual and shadowing it would
            -- make the same template mean different things per caller. This
            -- block exists because the natural thing to write -- {{run.id}} --
            -- silently resolved to nothing and failed 8 of 18 tasks in a real
            -- pipeline.
            'templates', jsonb_build_object(
                'run',   '{{run.<key>}} -- from the run input passed to start_workflow',
                -- The field NAMES, not a sample from whatever ran last: a
                -- facet that reads from live rows is empty on a fresh install,
                -- which is exactly when someone is reading it.
                'engine', jsonb_build_object(
                    '{{run.$id}}',          'this run''s uuid -- unreachable before this existed, '
                                            'and unpassable as input because the caller does not '
                                            'know it until start_workflow returns',
                    '{{run.$trace_id}}',    'the W3C trace id shared by every task in the run',
                    '{{run.$external_id}}', 'the idempotency key, if one was given',
                    '{{run.$definition}}',  'the workflow name',
                    '{{run.$version}}',     'the definition version this run was expanded from',
                    '{{run.$started_at}}',  'when the run began, ISO-8601 UTC',
                    '{{run.$session}}',     'an engine-minted conversation id, stable for the run '
                                            '-- see `sessions` below'),
                'steps', '{{steps.<id>.result}} -- a completed step''s output. EVERY step '
                         'kind nests its payload under `result`, so this is the one idiom '
                         'to learn.',
                'item',  '{{item.<col>}} -- one matrix row; bound only on fan-out children, '
                         'and substituted at expansion so a worker never sees it',
                'env',   '{{env.<VAR>}} -- resolved by the WORKER only; sql steps have no '
                         'env, because the database has no business reading the '
                         'deployment''s environment',
                'when',  'run/steps/env resolve at DISPATCH; item and run.$* are bound by '
                         'the engine before the worker sees them'),
            'sessions', jsonb_build_object(
                'how', 'An agent step declaring `session_group: <name>` gets an '
                       'engine-minted session id, stable for the life of the run, bound to '
                       '{{run.$session}}. Steps naming the same group share one '
                       'conversation; declaring none stays stateless.',
                'why', 'A workflow could not originate a session: `session:` only resolved '
                       'if the CALLER supplied an id, and the natural key derives from the '
                       'run -- which the run could not see.'),
            'limits', jsonb_build_object(
                'max_payload_bytes', coalesce(
                    nullif(current_setting('workflow.max_payload_bytes', true), '')::int, 65536),
                'max_fanout', 'declared per matrix step; there is no global default, '
                              'because the ceiling is the thing the author must think about'),
            'definitions', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'version', version) order by name, version)
                from workflow.definitions where deleted_at is null), '[]'::jsonb)),
        'examples', aiq.facet_examples('workflow'));
end;
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13f. Facet: sql -- caller-scoped, and that is the whole point.
--
-- SECURITY INVOKER, so `has_table_privilege(current_user, ...)` is the
-- caller's. A schema document that lists tables the reader cannot select from
-- is worse than no document: it is a directory of things to try, and it tells
-- one tenant that another's tables exist.
--
-- `SCHEMA "sql" FROM <relation>` narrows to one table, which is the form worth
-- having -- the unnarrowed document over a real deployment is large, and an
-- agent almost always wants one relation it just learned the name of.
-- ------------------------------------------------------------
create or replace function aiq.schema_sql(p_name text default null)
returns jsonb as $$
    with visible as (
        select c.oid, n.nspname, c.relname, c.relkind, c.relrowsecurity,
               obj_description(c.oid, 'pg_class') as comment
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where c.relkind in ('r', 'v', 'm', 'p', 'f')
          and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
          and n.nspname not like 'pg_temp%'
          and has_table_privilege(c.oid, 'SELECT')
          and (p_name is null
               or c.relname = p_name
               or n.nspname || '.' || c.relname = p_name)
    )
    select jsonb_build_object(
        'declared', jsonb_build_object(
            'note', 'Relations you can SELECT from, as your current role. Another role '
                    'sees a different document; the recorded revision is the owner''s '
                    'view of the whole database, not this.',
            'narrow_with', 'SCHEMA "sql" FROM <relation>'),
        'derived', jsonb_build_object(
            'role', current_user,
            'relation_count', (select count(*) from visible),
            'relations', coalesce((
                select jsonb_agg(jsonb_build_object(
                    'schema', v.nspname, 'name', v.relname,
                    'kind', case v.relkind when 'r' then 'table' when 'p' then 'partitioned table'
                                           when 'v' then 'view'  when 'm' then 'materialized view'
                                           else 'foreign table' end,
                    -- Worth surfacing: on an RLS table, "you may select" and
                    -- "you will see rows" are different statements, and an
                    -- agent that does not know the difference reads an empty
                    -- result as an absent fact.
                    'row_level_security', v.relrowsecurity,
                    'comment', v.comment,
                    'columns', (
                        select jsonb_agg(jsonb_build_object(
                            'name', a.attname,
                            'type', format_type(a.atttypid, a.atttypmod),
                            'not_null', a.attnotnull,
                            'default', pg_get_expr(d.adbin, d.adrelid))
                        order by a.attnum)
                        from pg_attribute a
                        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                        where a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped),
                    'constraints', (
                        select jsonb_agg(jsonb_build_object(
                            'name', co.conname, 'definition', pg_get_constraintdef(co.oid))
                        order by co.conname)
                        from pg_constraint co where co.conrelid = v.oid))
                order by v.nspname, v.relname)
                from visible v), '[]'::jsonb)),
        'examples', aiq.facet_examples('sql'));
$$ language sql stable security invoker;

-- ------------------------------------------------------------
-- 13g. Facet: graph -- the soft schema, which was already written down.
--
-- `aiq.relation_types` is the richest thing in this collection for this
-- purpose: it is the edge catalogue the insert trigger ENFORCES, it carries an
-- inverse label and a human description, and until now nothing served it to
-- the caller who needs it. An agent writing `GRAPH "acme" TYPE competes_with`
-- has no other way to learn that `competes_with` exists, that it runs
-- company -> company, or what it means.
-- ------------------------------------------------------------
create or replace function aiq.schema_graph(p_name text default null)
returns jsonb as $$
    select jsonb_build_object(
        'declared', jsonb_build_object(
            'model', 'Nodes are projections of typed rows registered in aiq.entity_registry; '
                     'keys in aiq.node_keys are how the dialect NAMES them; edges are soft '
                     '(authored) links validated against the relation catalogue below.',
            'traversal', 'GRAPH "<key>" [DEPTH n] [TYPE <relation>] -- the key is resolved '
                         'once and the walk proceeds by id, never by name.'),
        'derived', jsonb_build_object(
            -- How to WRITE one, not just which ones exist. The catalogue told
            -- an author that `competes_with` runs company -> company and
            -- nothing about the table it goes in -- so the first edge written
            -- from this document guessed the column names and failed.
            'edge_write', jsonb_build_object(
                'table', 'aiq.edges',
                'columns', jsonb_build_object(
                    'src_id', 'uuid -> aiq.nodes.id  (NOT src_node_id)',
                    'dst_id', 'uuid -> aiq.nodes.id',
                    'relation', 'text, must exist in the catalogue below',
                    'weight', 'real, default 1.0',
                    'provenance', 'jsonb, default {}'),
                'enforced_by', 'a trigger validates (src_type, relation, dst_type) '
                               'against aiq.relation_types; an unlisted triple is refused',
                'resolve_ids', 'nodes are found by key: select node_id from aiq.lookup(''<key>'')'),
            -- `sample_keys`, and the dead end it closes.
            --
            -- Every mode except SCHEMA requires the caller to ALREADY HOLD a
            -- key (USAGE.md says so outright), and until now nothing anywhere
            -- showed one. So the discovery path terminated: SCHEMA "graph"
            -- said an `fx_pair` entity type exists and a `same_band` relation
            -- runs between them, and left the caller to invent the name of an
            -- instance.
            --
            -- Observed, on the first real question ever put to the sample
            -- agent: it read both schema facets correctly, then guessed
            -- `sterling`, `gbp`, `gbp_usd` and `gbpusd`, got four empty
            -- results, and gave up. The keys were `usd/gbp`. Three example
            -- keys would have ended it at the first call -- the shape of a key
            -- is the one thing a naming convention cannot be reasoned out of.
            --
            -- Scoped explicitly, because this function is SECURITY DEFINER and
            -- therefore does NOT get the RLS that protects aiq.nodes: the
            -- predicate below is the nodes_org_scoped policy written out by
            -- hand. Without it the facet would be a cross-tenant key
            -- disclosure dressed as documentation.
            'entity_types', coalesce((select jsonb_agg(jsonb_build_object(
                    'entity_type', r.entity_type, 'source_table', r.source_table,
                    'key_expr', r.key_expr, 'include_where', r.include_where,
                    'sample_keys', coalesce((
                        select jsonb_agg(k.key order by k.key)
                        from (select nk.key
                                from aiq.node_keys nk
                                join aiq.nodes n on n.id = nk.node_id
                               where n.entity_type = r.entity_type
                                 and nk.kind = 'canonical'
                                 and (n.org_id is null
                                      or n.org_id in (select aiq.current_org_ids()))
                               order by nk.key
                               limit 3) k), '[]'::jsonb))
                    order by r.entity_type)
                from aiq.entity_registry r
                where p_name is null or r.entity_type = p_name), '[]'::jsonb),
            'relations', coalesce((select jsonb_agg(jsonb_build_object(
                    'src_type', src_type, 'relation', relation, 'dst_type', dst_type,
                    'inverse_label', inverse_label, 'description', description)
                    order by src_type, relation, dst_type)
                from aiq.relation_types
                where p_name is null
                   or p_name in (src_type, relation, dst_type)), '[]'::jsonb),
            'semantic_sources', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'source_table', source_table, 'content_col', content_col)
                    order by name) from aiq.semantic_sources), '[]'::jsonb),
            'lexical_sources', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'source_table', source_table, 'regconfig', regconfig)
                    order by name) from aiq.lexical_sources), '[]'::jsonb),
            'embedding_models', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', name, 'dim', dim, 'provider', provider,
                    'distance_op', distance_op, 'is_default', is_default) order by name)
                from aiq.embedding_models), '[]'::jsonb)),
        'examples', aiq.facet_examples('graph'));
$$ language sql stable security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 13h. Registration, and the starting example corpus.
--
-- Four facets and nothing hardcoded anywhere above them. A fifth --
-- `tradecraft` over the controlled vocabularies in
-- world-model-ingestion/tradecraft.sql, or `connectors` over
-- content.v_required_credentials -- is these two calls and a function.
-- ------------------------------------------------------------
select aiq.register_schema_facet('p8ql', 'aiq.schema_p8ql',
    'The query dialect',
    'Every mode, its syntax, and the sources and models you may name in FROM and USING. '
    'The grammar is emitted by the parser itself; the examples are parsed on every read.');

select aiq.register_schema_facet('workflow', 'aiq.schema_workflow',
    'Authoring a workflow',
    'The step vocabulary, the legal step kinds read off the engine''s own constraint, the '
    'allow-listed functions a sql step may call with their real signatures, the queues and '
    'agents a step may route to, and worked YAML that is compiled on every read.');

select aiq.register_schema_facet('sql', 'aiq.schema_sql',
    'Relations you can read',
    'Tables, views and columns your current role may SELECT, with constraints and whether '
    'row-level security applies. Narrow with FROM <relation>.', true);

select aiq.register_schema_facet('graph', 'aiq.schema_graph',
    'The entity and relation catalogue',
    'Registered entity types, the enforced edge catalogue with descriptions and inverse '
    'labels, and the search sources and embedding spaces behind them.');

select aiq.register_schema_example('p8ql', 'lookup-list', 'p8ql',
    'FUZZY LOOKUP "acme", "globex" LIMIT 5',
    'Resolving several names is one round trip, not N.', 10);
select aiq.register_schema_example('p8ql', 'graph-walk', 'p8ql',
    'GRAPH "acme" DEPTH 2 TYPE competes_with',
    'DEPTH and TYPE apply only to GRAPH; written elsewhere they are refused, not ignored.', 20);
select aiq.register_schema_example('p8ql', 'lexical', 'p8ql',
    'TEXT "R7 recall notice" FROM chunks LIMIT 10',
    'No embedding needed -- this is the rare-exact-token case SEMANTIC misses.', 30);
select aiq.register_schema_example('p8ql', 'fused', 'p8ql',
    'SEARCH "safety recall" FROM chunks USING nomic-embed-text LIMIT 5',
    'Needs an embedding passed alongside; the database makes no model calls.', 40);
select aiq.register_schema_example('p8ql', 'self', 'p8ql',
    'SCHEMA "workflow"',
    'The query that produced this document.', 50);

-- The `graph` facet had a document and no examples, which is the half of it
-- most likely to be read and the half that rots. Registered as kind `p8ql`, so
-- every read runs them through the real parser: an example that stops parsing
-- is served as `verified: false` rather than as authority.
select aiq.register_schema_example('graph', 'neighbours', 'p8ql',
    'GRAPH "ACME"',
    'Depth 1 is native SQL/PGQ. Both directions come back; an inbound edge is '
    'labelled with the catalogue''s inverse label, and that label works as a '
    'TYPE filter too.', 10);
select aiq.register_schema_example('graph', 'typed-walk', 'p8ql',
    'GRAPH "ACME" DEPTH 2 TYPE competes_with',
    'DEPTH above 1 falls back to WITH RECURSIVE -- PG19 has no quantified path '
    'patterns. One row per node at its shortest depth, ordered by depth then by '
    'the product of the edge weights along the path.', 20);
select aiq.register_schema_example('graph', 'seed-then-load', 'p8ql',
    'LOOKUP "acme", "borealis"',
    'The seed of a walk is resolved exactly -- canonical, then short, then '
    'alias, never trigram. LOOKUP first when a name might be ambiguous: it '
    'returns every node that answers to it, and reports the names it did not '
    'find as rows with a null node_id.', 30);

select aiq.register_schema_example('workflow', 'sql-only', 'workflow_yaml',
$y$name: reindex_nightly
steps:
  - id: rebuild
    sql: {function: rebuild_graph_index, args: [company]}
$y$, 'A workflow of only sql steps completes with nothing running anywhere.', 10);

select aiq.register_schema_example('workflow', 'search', 'workflow_yaml',
$y$name: hybrid_research
steps:
  - id: retrieve
    p8ql: 'SEARCH "{{run.question}}" FROM chunks LIMIT 3'
$y$, 'A vector mode still runs as two tasks -- a sql step cannot embed text, because that '
     'is a model call -- but the compiler writes the embed step, and define_yaml pins the '
     'model into both halves. Compile it and look: there are two steps, and the query in '
     'the stored spec carries USING.', 20);

select aiq.register_schema_example('workflow', 'search-spelled-out', 'workflow_yaml',
$y$name: hybrid_research_raw
steps:
  - id: q
    embed: {text: '{{run.question}}', model: nomic-embed-text}
  - id: retrieve
    needs: [q]
    sql:
      function: p8ql_vec
      args: ['SEARCH "{{run.question}}" FROM chunks USING nomic-embed-text LIMIT 3',
             '{{steps.q.result}}']
$y$, 'The same two tasks, written by hand. Worth knowing they are the same rows: the '
     'shorthand is not a second execution path, and reaching for this form costs nothing '
     'when a pipeline embeds once and searches twice.', 25);

select aiq.register_schema_example('workflow', 'matrix-fanout', 'workflow_yaml',
$y$name: edgar_restatements
steps:
  - id: fan
    matrix:
      rows: {function: tier1_concepts, args: ['{{run.tier}}']}
      max_fanout: 5000
      template:
        queue: edgar-xbrl
        rest:
          url: https://data.sec.gov/api/xbrl/companyconcept/CIK{{item.cik}}/us-gaap/{{item.concept}}.json
          jsonpath: units.USD
  - id: checks
    needs: [fan]
    sql: {function: detect_restatements, args: ['{{run.tier}}']}
$y$, 'One task per row, inserted by the statement that completes the parent. `checks` waits '
     'for every child, not for the expansion.', 30);

-- ------------------------------------------------------------
-- 13i. Grants.
--
-- The three registry tables are readable by `authenticated`, exactly as
-- aiq.entity_registry, aiq.relation_types and workflow.step_functions already
-- are: they describe the deployment, not a tenant. Registration is NOT granted
-- -- it decides what a SCHEMA query can cause to run, the same rule
-- workflow.register_step_function follows.
-- ------------------------------------------------------------
grant select on aiq.schema_facets, aiq.schema_examples, aiq.schema_revisions
    to authenticated, api_viewer;

grant execute on function aiq.schema(text, text) to authenticated, web_anon;
grant execute on function aiq.render_facet(text, text) to authenticated;
grant execute on function aiq.verify_example(text, text) to authenticated;
grant execute on function aiq.facet_examples(text) to authenticated;
grant execute on function aiq.schema_p8ql(text)    to authenticated;
grant execute on function aiq.schema_workflow(text) to authenticated;
grant execute on function aiq.schema_sql(text)     to authenticated;
grant execute on function aiq.schema_graph(text)   to authenticated;

-- Capture writes history, so it is the operator's, not the caller's. It is
-- the same shape as workflow.reap_stale_tasks: scheduled maintenance, granted
-- to `scheduler`, callable from CI beside ../../surface.sql.
grant execute on function aiq.capture_schema_revisions() to scheduler;
grant execute on function aiq.schema_drift() to scheduler, authenticated;
revoke execute on function aiq.register_schema_facet(text, text, text, text, boolean) from public;
revoke execute on function aiq.register_schema_example(text, text, text, text, text, int) from public;
