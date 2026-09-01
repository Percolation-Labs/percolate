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
create unique index idx_node_keys_canonical
    on aiq.node_keys (org_id, key, entity_type) where kind = 'canonical';
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
        raise exception
            'relation (%s, %s, %s) is not in the catalogue -- add it to aiq.relation_types first',
            v_src_type, new.relation, v_dst_type;
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
    v_tbl_short text := split_part(p_source_table, '.', 2);
begin
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
    execute format($f$
        create or replace function aiq.project_%1$s_ins() returns trigger as $b$
        begin
            insert into aiq.nodes (entity_type, entity_id, org_id, summary)
            select %2$L, n.id, %3$s, %4$s from new_rows n where %5$s
            on conflict (entity_type, entity_id) do update
                set summary = excluded.summary, org_id = excluded.org_id,
                    updated_at = now();

            insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
            select nd.id, %2$L, lower(trim(%6$s)), 'canonical', %3$s
            from new_rows n
            join aiq.nodes nd on nd.entity_type = %2$L and nd.entity_id = n.id
            where %5$s
            -- DO UPDATE, not DO NOTHING: org_id scopes the canonical-key
            -- unique index, so leaving a stale copy on an existing key row
            -- silently corrupts that scoping after a tenancy change.
            on conflict (node_id, key, kind) do update set org_id = excluded.org_id;
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_tbl_short, p_entity_type, p_org_expr, p_summary_expr, p_include_where, p_key_expr);

    execute format($f$
        create or replace function aiq.project_%1$s_del() returns trigger as $b$
        begin
            delete from aiq.nodes
            where entity_type = %2$L and entity_id in (select id from old_rows);
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_tbl_short, p_entity_type);

    execute format('drop trigger if exists trg_aiq_project_ins on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_ins
            after insert on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.project_%2$s_ins();
    $f$, p_source_table, v_tbl_short);

    execute format('drop trigger if exists trg_aiq_project_upd on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_upd
            after update on %1$s
            referencing new table as new_rows
            for each statement execute function aiq.project_%2$s_ins();
    $f$, p_source_table, v_tbl_short);

    execute format('drop trigger if exists trg_aiq_project_del on %s', p_source_table);
    execute format($f$
        create trigger trg_aiq_project_del
            after delete on %1$s
            referencing old table as old_rows
            for each statement execute function aiq.project_%2$s_del();
    $f$, p_source_table, v_tbl_short);
end;
$$ language plpgsql;

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

    get diagnostics v_count = row_count;
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
    select k.key_in, l.node_id, l.entity_type, l.entity_id, l.key,
           l.match_kind, l.score
    from unnest(p_keys) as k(key_in),
         lateral aiq.lookup(k.key_in, p_fuzzy, p_limit) l;
$$ language sql stable;

-- GRAPH depth 1: native SQL/PGQ. Confirmed working on PG19 beta3.
create or replace function aiq.graph_neighbors(
    p_node_id uuid, p_relation text default null, p_limit int default 100
) returns table(neighbor_id uuid, entity_type text, summary text,
                relation text, weight real, direction text) as $$
    select * from (
        select b.id, b.entity_type, b.summary, e.relation, e.weight, 'out'::text
        from graph_table (aiq.knowledge_graph
            match (a is node) -[e is related]-> (b is node)
            columns (a.id as a_id, b.id as b_id, e.relation as relation, e.weight as weight)
        ) g
        join aiq.nodes b on b.id = g.b_id
        join aiq.edges e on e.src_id = g.a_id and e.dst_id = g.b_id and e.relation = g.relation
        where g.a_id = p_node_id and (p_relation is null or g.relation = p_relation)
        union all
        -- The reverse question is first-class: no inverse edge is stored, so
        -- it is answered by walking dst_id, and the label comes from the
        -- catalogue at read time (graph-identity.md "Edge table").
        select a.id, a.entity_type, a.summary,
               coalesce(rt.inverse_label, e.relation || '_by'), e.weight, 'in'::text
        from aiq.edges e
        join aiq.nodes a on a.id = e.src_id
        join aiq.nodes b2 on b2.id = e.dst_id
        left join aiq.relation_types rt
               on rt.src_type = a.entity_type and rt.relation = e.relation
              and rt.dst_type = b2.entity_type
        where e.dst_id = p_node_id and (p_relation is null or e.relation = p_relation)
    ) x
    limit p_limit;
$$ language sql stable;

-- GRAPH depth n>1: WITH RECURSIVE. PG19's GRAPH_TABLE rejects quantified path
-- patterns outright ("element pattern quantifier is not supported") -- not a
-- beta gap to wait out, deliberately scoped out of the initial implementation
-- (brief.md §3). Depth- AND degree-capped, per graph-identity.md "Non-goals".
create or replace function aiq.graph_walk(
    p_node_id uuid, p_depth int default 2, p_relation text default null,
    p_max_nodes int default 500
) returns table(node_id uuid, entity_type text, summary text,
                depth int, path_relations text[]) as $$
    with recursive walk as (
        select n.id, n.entity_type, n.summary, 0 as depth,
               array[]::text[] as rels, array[n.id] as seen
        from aiq.nodes n where n.id = p_node_id
        union all
        select nx.id, nx.entity_type, nx.summary, w.depth + 1,
               w.rels || e.relation, w.seen || nx.id
        from walk w
        join aiq.edges e on (e.src_id = w.id or e.dst_id = w.id)
        join aiq.nodes nx on nx.id = case when e.src_id = w.id then e.dst_id else e.src_id end
        where w.depth < p_depth
          and not nx.id = any(w.seen)          -- cycle guard
          and (p_relation is null or e.relation = p_relation)
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
    select distinct on (id) id, entity_type, summary, depth, rels
    from walk where depth > 0
    order by id, depth
    limit p_max_nodes;
$$ language sql stable;

-- SEMANTIC: pgvector over one entity type's chunk table. Registered per type
-- rather than hardcoded, because the embedding table belongs to the consumer
-- (world-model-ingestion owns resource_chunks), not to this layer.
create table aiq.semantic_sources (
    name          text primary key,
    source_table  text not null,       -- schema-qualified, has (id, content, embedding)
    content_col   text not null default 'content',
    embedding_col text not null default 'embedding',
    link_expr     text                 -- optional SQL expr -> owning node's entity_id
);

create or replace function aiq.semantic(
    p_source text, p_query vector, p_limit int default 10
) returns table(chunk_id uuid, content text, distance float8) as $$
declare s aiq.semantic_sources;
begin
    select * into s from aiq.semantic_sources where name = p_source;
    if not found then raise exception 'semantic source % not registered -- SCHEMA "graph" lists the registered ones', p_source; end if;
    return query execute format(
        'select c.id, c.%I::text, (c.%I <=> $1)::float8 as distance
         from %s c order by c.%I <=> $1 limit $2',
        s.content_col, s.embedding_col, s.source_table, s.embedding_col
    ) using p_query, p_limit;
end;
$$ language plpgsql stable;

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
    v_out    jsonb;
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
        select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) into v_out
        from aiq.lookup_many(
            (select array_agg(value) from jsonb_array_elements_text(p->'args')),
            (p->>'fuzzy')::boolean, (p->>'limit')::int) l;

    when 'GRAPH' then
        -- Resolve the key ONCE, here, then traverse by id: the dialect names
        -- nodes by key, but traversal never parses names
        -- (graph-identity.md "Edges -- canonical, written directly").
        select node_id into v_node from aiq.lookup(p->>'arg', true, 1) limit 1;
        if v_node is null then
            return jsonb_build_object('mode','GRAPH','rows','[]'::jsonb,
                'error', format('no node matches key %L', p->>'arg'));
        end if;

        if (p->>'depth')::int <= 1 then
            select coalesce(jsonb_agg(to_jsonb(g)), '[]'::jsonb) into v_out
            from aiq.graph_neighbors(v_node, p->>'relation', (p->>'limit')::int) g;
        else
            select coalesce(jsonb_agg(to_jsonb(w)), '[]'::jsonb) into v_out
            from aiq.graph_walk(v_node, (p->>'depth')::int, p->>'relation',
                                (p->>'limit')::int) w;
        end if;

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
        select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_out
        from aiq.semantic_in(p_embedding, p->>'model', (p->>'limit')::int) s;

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

    return jsonb_build_object('mode', p->>'mode', 'plan', p, 'rows', v_out);
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
-- ============================================================

create table aiq.embedding_models (
    name        text primary key,          -- 'nomic-embed-text', 'text-embedding-3-small'
    dim         int  not null check (dim > 0),
    provider    text not null,             -- 'ollama' | 'openai' | ...
    endpoint    text,                      -- resolved by the worker, not called from SQL
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

-- SEMANTIC against a named model (or the default when null). The caller still
-- supplies the vector -- embedding generation is an external model call (§4),
-- and which model produced that vector is now explicit rather than implied.
create or replace function aiq.semantic_in(
    p_query vector, p_model text default null, p_limit int default 10
) returns table(chunk_id uuid, distance float8, model text) as $$
declare
    m aiq.embedding_models;
    v_tbl text;
begin
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

    v_tbl := 'emb_' || replace(m.name, '-', '_');
    return query execute format(
        'select e.chunk_id, (e.embedding <=> $1)::float8, %L
         from aiq.%I e order by e.embedding <=> $1 limit $2', m.name, v_tbl)
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
        select s.chunk_id, row_number() over (order by s.distance asc)::int as rnk
        from aiq.semantic_in($3, $6, $4 * 4) s
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
            'step_kinds', coalesce(to_jsonb(v_kinds), '[]'::jsonb),
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
            'entity_types', coalesce((select jsonb_agg(jsonb_build_object(
                    'entity_type', entity_type, 'source_table', source_table,
                    'key_expr', key_expr, 'include_where', include_where) order by entity_type)
                from aiq.entity_registry
                where p_name is null or entity_type = p_name), '[]'::jsonb),
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

select aiq.register_schema_example('workflow', 'sql-only', 'workflow_yaml',
$y$name: reindex_nightly
steps:
  - id: rebuild
    sql: {function: rebuild_graph_index, args: [company]}
$y$, 'A workflow of only sql steps completes with nothing running anywhere.', 10);

select aiq.register_schema_example('workflow', 'rest-then-search', 'workflow_yaml',
$y$name: hybrid_research
steps:
  - id: embed
    rest:
      url: http://localhost:11435/api/embeddings
      method: POST
      body: {model: nomic-embed-text, prompt: '{{run.question}}'}
      jsonpath: embedding
  - id: retrieve
    needs: [embed]
    sql:
      function: p8ql_vec
      args: ['SEARCH "{{run.question}}" FROM chunks LIMIT 3', '{{steps.embed.result}}']
$y$, 'Vector modes take two steps: a sql step cannot embed text, because that is a model call.', 20);

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
