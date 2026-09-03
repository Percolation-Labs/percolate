-- ============================================================
-- Graph algorithms — the SQL surface over the compiled half.
--
-- Companion to graph-algorithms.md, which carries the measurements and the
-- verdict on each one. Everything here is a thin wrapper: it resolves names to
-- nodes, calls a `p8_graph_*` function from the parser extension, and hydrates
-- the returned ids back into something a caller can read. No algorithm lives
-- in this file, and none should — the split is the same one aiq_parse() makes,
-- and for the same reason (schema.sql §8): the compiled side is testable
-- without a database and the SQL side is where RLS, the catalogue and the key
-- resolver already are.
--
-- SECURITY INVOKER throughout, which is not a default but a requirement. The
-- extension builds its adjacency snapshot through SPI *as the caller*, so
-- these functions running as their owner would hand every caller a snapshot of
-- the whole graph. integration-rbac.sql makes the same argument about
-- aiq.sql_passthrough; it applies with more force here, because a traversal
-- reaches further from its seed than a single statement does.
-- ============================================================

-- Only the algorithms graph-algorithms.md marks SAFE get a surface here. That
-- is the whole expression of the verdict: the landmark-label index and the
-- partition are still callable as bare C functions for anyone re-running the
-- harness, and neither is reachable through `aiq.` — so nothing can start
-- depending on one before its number improves.
create or replace function aiq.graph_algorithms_available() returns boolean
language sql stable as $$
    select to_regprocedure('p8_graph_ppr(uuid[],float8,float8,int,int,bool,text,bigint)') is not null
$$;

-- ------------------------------------------------------------
-- 1. The snapshot — an operational surface, not a query one.
--
-- Backend-local, so this reports what THIS connection is holding. Through a
-- pooler that is a different backend per call and the honest answer is "it
-- depends"; graph-algorithms.md §2.1 and §2.3 are explicit about what a pooled
-- deployment has to do about that, and this function is how you find out which
-- backend you are on. (It said §6, which is the measurements table.)
--
-- The ARGUMENT NAMES here are `p_`-prefixed, and that is worth stating because
-- the ceiling error in graph.rs spent a while telling operators to call
-- `relations => ...`, which does not exist -- a remedy that fails with
-- "function does not exist" at the moment somebody is already in trouble.
-- ------------------------------------------------------------
create or replace function aiq.graph_snapshot(
    p_refresh      boolean default false,
    p_relations    text[] default null,
    p_weight_floor double precision default 0,
    p_as_of        timestamptz default null
) returns jsonb language plpgsql volatile as $$
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    return p8_graph_snapshot(
        p_refresh, p_relations, p_weight_floor,
        case when p_as_of is null then null
             else (extract(epoch from p_as_of) * 1000000)::bigint end);
end $$;

-- ------------------------------------------------------------
-- 2. RELATED — personalised PageRank from one or more named seeds.
--
-- The answer to "what is related to this", and deliberately NOT a depth-capped
-- walk: a walk returns everything within n hops in no particular order, which
-- for a hub is thousands of rows a caller must then rank with information it
-- does not have. This returns the ranking, and the ranking is the product.
--
-- `budget_exhausted` rides on every row rather than living in a second call.
-- It is redundant per row and correct per answer, and the alternative — a
-- caller that has to remember to ask — is how "the walk stopped early" turns
-- into "there is nothing else related", which is the exact confusion the
-- dialect's `unresolved` field exists to prevent.
-- ------------------------------------------------------------
create or replace function aiq.related(
    p_keys      text[],
    p_limit     int default 25,
    p_relation  text default null,
    p_budget_ms int default 250,
    p_as_of     timestamptz default null,
    p_directed  boolean default false
) returns table(node_id uuid, key text, entity_type text, summary text,
                score double precision, budget_exhausted boolean)
language plpgsql stable as $$
declare
    v_seeds uuid[];
    v_res   jsonb;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    -- Names resolve through the ONE resolver, exactly as the dialect's modes
    -- do. A second, private key lookup in this file would be a second answer
    -- to "which node is called that", and the first one to drift is the one
    -- nobody is testing.
    select array_agg(l.node_id) into v_seeds
      from unnest(p_keys) k
      cross join lateral (select * from aiq.lookup(k, false, 1)) l;
    if v_seeds is null then
        return;
    end if;

    v_res := p8_graph_ppr(v_seeds, 0.15, 0.000001, p_limit, p_budget_ms, p_directed,
                          p_relation,
                          case when p_as_of is null then null
                               else (extract(epoch from p_as_of) * 1000000)::bigint end);

    return query
    select n.id, kk.key, n.entity_type, n.summary,
           (r->>'score')::double precision,
           (v_res->'meta'->>'exhausted')::boolean
      from jsonb_array_elements(v_res->'rows') r
      join aiq.nodes n on n.id = (r->>'node_id')::uuid
      left join lateral (select nk.key from aiq.node_keys nk
                          where nk.node_id = n.id and nk.kind = 'canonical'
                          limit 1) kk on true
     -- The extension's own ordering is by score; jsonb_array_elements
     -- preserves it, and the join does not, so it is restated.
     order by (r->>'score')::double precision desc;
end $$;

-- ------------------------------------------------------------
-- 3. PATHS — the k cheapest routes between two named nodes.
--
-- JSONB rather than a table because a path is a nested thing, and flattening
-- it into (path_index, hop_index, ...) rows makes every caller reassemble what
-- was already assembled. `as_of` is the argument that makes this the first
-- read path in the collection to honour valid_from/valid_to — see
-- graph-identity.md, where the gap is recorded, and §7 of graph-algorithms.md
-- for why filtering at edge-relax time is the only correct place for it.
-- ------------------------------------------------------------
create or replace function aiq.graph_paths(
    p_src_key   text,
    p_dst_key   text,
    p_k         int default 3,
    p_max_hops  int default 6,
    p_budget_ms int default 250,
    p_relation  text default null,
    p_as_of     timestamptz default null
) returns jsonb language plpgsql stable as $$
declare v_src uuid; v_dst uuid; v_res jsonb;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    select node_id into v_src from aiq.lookup(p_src_key, false, 1);
    select node_id into v_dst from aiq.lookup(p_dst_key, false, 1);
    if v_src is null or v_dst is null then
        -- Which name failed is the whole content of this answer: "no path" and
        -- "no such node" are different facts and a caller acts differently on
        -- each.
        return jsonb_build_object(
            'ok', true, 'paths', '[]'::jsonb,
            'unresolved', (select jsonb_agg(x) from (
                select p_src_key where v_src is null
                union all select p_dst_key where v_dst is null) t(x)));
    end if;
    v_res := p8_graph_paths(v_src, v_dst, p_k, p_max_hops, p_budget_ms, false,
                            p_relation,
                            case when p_as_of is null then null
                                 else (extract(epoch from p_as_of) * 1000000)::bigint end);
    return v_res - 'snapshot';
end $$;

-- ------------------------------------------------------------
-- 4. CONNECT — the smallest subgraph joining a set of named nodes.
--
-- The follow-up to a retrieval, and the one question ranking cannot answer:
-- given the eight things that came back, what connects them. Approximate (it
-- is a Steiner tree) and budgeted, and it says how many terminals it actually
-- joined so a partial answer cannot be read as a complete one.
-- ------------------------------------------------------------
create or replace function aiq.graph_connect(
    p_keys      text[],
    p_budget_ms int default 500,
    p_relation  text default null
) returns jsonb language plpgsql stable as $$
declare v_ids uuid[]; v_res jsonb;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    select array_agg(l.node_id) into v_ids
      from unnest(p_keys) k
      cross join lateral (select * from aiq.lookup(k, false, 1)) l;
    if coalesce(array_length(v_ids, 1), 0) < 2 then
        return jsonb_build_object('ok', false,
            'error', 'connect needs at least two names that resolve to nodes');
    end if;
    v_res := p8_graph_connect(v_ids, p_budget_ms, p_relation);
    return v_res - 'snapshot';
end $$;

-- ------------------------------------------------------------
-- 5. DENSE — core numbers and cliques around a seed.
--
-- brief.md §3's "clique/collusion detection", bounded twice: the induced
-- neighbourhood is capped before the exponential part runs at all.
-- ------------------------------------------------------------
create or replace function aiq.graph_dense(
    p_key        text,
    p_max_nodes  int default 2000,
    p_min_clique int default 3,
    p_budget_ms  int default 250,
    p_relation   text default null
) returns jsonb language plpgsql stable as $$
declare v_id uuid; v_res jsonb;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    select node_id into v_id from aiq.lookup(p_key, false, 1);
    if v_id is null then
        return jsonb_build_object('ok', true, 'unresolved', jsonb_build_array(p_key));
    end if;
    v_res := p8_graph_dense(v_id, p_max_nodes, p_min_clique, p_budget_ms, p_relation);
    return v_res - 'snapshot';
end $$;

-- ------------------------------------------------------------
-- 6. TRUST — confidence and corroboration, propagated from seeds you believe.
--
-- graph-index.md §5 discards what does not resolve; what survives is still a
-- mixture of registry matches and model guesses, and after two hops nothing
-- downstream can tell them apart. `support` is the corroboration count and is
-- the column to read second: a confident number with support 0 is one path's
-- opinion.
-- ------------------------------------------------------------
create or replace function aiq.graph_trust(
    p_keys      text[],
    p_floor     double precision default 0.01,
    p_limit     int default 25,
    p_budget_ms int default 250,
    p_relation  text default null,
    p_as_of     timestamptz default null
) returns table(node_id uuid, key text, entity_type text,
                confidence double precision, support int, budget_exhausted boolean)
language plpgsql stable as $$
declare v_seeds uuid[]; v_res jsonb;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    select array_agg(l.node_id) into v_seeds
      from unnest(p_keys) k
      cross join lateral (select * from aiq.lookup(k, false, 1)) l;
    if v_seeds is null then
        return;
    end if;
    v_res := p8_graph_trust(v_seeds, p_floor, p_limit, p_budget_ms, false, p_relation,
                            case when p_as_of is null then null
                                 else (extract(epoch from p_as_of) * 1000000)::bigint end);
    return query
    select n.id, kk.key, n.entity_type,
           (r->>'confidence')::double precision,
           (r->>'support')::int,
           (v_res->'meta'->>'exhausted')::boolean
      from jsonb_array_elements(v_res->'rows') r
      join aiq.nodes n on n.id = (r->>'node_id')::uuid
      left join lateral (select nk.key from aiq.node_keys nk
                          where nk.node_id = n.id and nk.kind = 'canonical'
                          limit 1) kk on true
     order by (r->>'confidence')::double precision desc;
end $$;

-- ------------------------------------------------------------
-- 7. FRONTIER — how big is the neighbourhood, before walking it.
--
-- The planning input, and the reason the sketch index exists. `estimate` is
-- null until p8_graph_reach_build() has run in this backend, and a null
-- estimate must be read as "unknown", never as "small" — which is why this
-- returns the index's state alongside the number rather than a bare integer.
-- ------------------------------------------------------------
create or replace function aiq.graph_frontier(
    p_key text, p_depth int default 2, p_exact boolean default false,
    p_budget_ms int default 250
) returns jsonb language plpgsql stable as $$
declare v_id uuid;
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    select node_id into v_id from aiq.lookup(p_key, false, 1);
    if v_id is null then
        return jsonb_build_object('ok', true, 'unresolved', jsonb_build_array(p_key));
    end if;
    return p8_graph_frontier(v_id, p_depth, p_exact, p_budget_ms);
end $$;

-- Building the sketches is a maintenance operation with a real cost, so it is
-- its own entry point rather than something a query does implicitly. It is the
-- natural body of a workflow-engine scheduled task, beside the drift check and
-- the node-registry rebuild (graph-identity.md D10) — one scheduler, one retry
-- mechanism, not a third invented cron job.
create or replace function aiq.graph_reach_build(
    p_depth int default 3, p_budget_ms int default 60000
) returns jsonb language plpgsql volatile as $$
begin
    return p8_graph_reach_build(p_depth, p_budget_ms);
end $$;

-- ------------------------------------------------------------
-- 7b. Two bulk primitives, addressed by id rather than by name.
--
-- Every wrapper above takes keys, because every wrapper above answers a
-- question a person or an agent asked in words. These two are different: they
-- are called with ids that came out of a previous call, in a loop, by code --
-- so a key resolution per row would be a lookup nobody asked for and a join
-- nobody reads. They also deliberately do not hydrate the result into keys and
-- summaries: at a million rows that join costs more than the algorithm.
--
-- Both read the snapshot AS BUILT. That is the whole reason
-- aiq.graph_snapshot() takes a filter: components over an unfiltered evidence
-- graph are one blob, because the near-zero edges a threshold exists to ignore
-- connect everything to everything. Filter the snapshot, then take components.
-- ------------------------------------------------------------
create or replace function aiq.graph_components(
    p_min_size int default 2, p_budget_ms int default 30000
) returns table(node_id uuid, component uuid, size int)
language plpgsql stable as $$
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    return query select * from p8_graph_components(p_min_size, p_budget_ms);
end $$;

create or replace function aiq.graph_induced(
    p_node_ids uuid[], p_relation text default null, p_as_of timestamptz default null
) returns table(src_id uuid, dst_id uuid, relation text, weight double precision)
language plpgsql stable as $$
begin
    if not aiq.graph_algorithms_available() then
        raise exception 'the graph algorithms are not installed -- they ship in '
            'percolate_parser, the same extension as aiq_parse()';
    end if;
    return query select * from p8_graph_induced(
        p_node_ids, p_relation,
        case when p_as_of is null then null
             else (extract(epoch from p_as_of) * 1000000)::bigint end);
end $$;

-- ------------------------------------------------------------
-- 8. Deny by default, and one call to change that.
--
-- integration-rbac.sql already revoked EXECUTE on everything in `aiq` from
-- PUBLIC and then granted the seven dialect modes to `authenticated`. This
-- file runs AFTER it, so its functions were created under the default PUBLIC
-- EXECUTE and were never covered by that revoke -- which is how a "deny by
-- default" posture quietly becomes "deny the things we wrote first".
--
-- The revoke is repeated here for that reason. The grant is NOT: these are
-- shipped experimental (graph-algorithms.md), so a fresh install has them
-- present, inert and unreachable by any end-user role. Nothing builds a
-- snapshot, nothing allocates, nothing runs, until somebody asks for it -- and
-- asking is one call rather than a page of grants nobody will get exactly
-- right the first time.
-- ------------------------------------------------------------
revoke execute on all functions in schema aiq from public;

create or replace function aiq.enable_graph_algorithms(
    p_role name default 'authenticated', p_enabled boolean default true
) returns jsonb language plpgsql as $$
declare r record; v_did text[] := '{}';
begin
    if not exists (select 1 from pg_roles where rolname = p_role) then
        raise exception 'no such role: %', p_role;
    end if;
    for r in
        -- The query entry points and the compiled functions under them.
        -- `enable_graph_algorithms` itself is deliberately absent: a gate an
        -- end-user role can open is not a gate.
        --
        -- `graph_reach_build` IS included, which the first version of this
        -- function got wrong by reasoning rather than by running. It is a
        -- maintenance operation, so it looked like one to withhold -- but the
        -- sketch it builds lives in the backend that built it, over the graph
        -- THAT CALLER could see. Built by the owner and read by a tenant, the
        -- tenant's snapshot is rebuilt under their own fingerprint and the
        -- estimate comes back null. An index only its author can use is not an
        -- index; the cost it carries is bounded by the same budget as
        -- everything else here.
        select p.oid::regprocedure as sig
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where (n.nspname = 'aiq'
                and p.proname in ('related','graph_paths','graph_connect',
                                  'graph_dense','graph_trust','graph_frontier',
                                  'graph_snapshot','graph_components','graph_induced',
                                  'graph_reach_build',
                                  -- every wrapper's first statement calls it,
                                  -- so a grant that omits it grants nothing
                                  'graph_algorithms_available'))
            or p.proname like 'p8\_graph\_%'
    loop
        if p_enabled then
            execute format('grant execute on function %s to %I', r.sig, p_role);
        else
            execute format('revoke execute on function %s from %I', r.sig, p_role);
        end if;
        v_did := v_did || r.sig::text;
    end loop;
    return jsonb_build_object(
        'role', p_role,
        'enabled', p_enabled,
        'functions', cardinality(v_did),
        -- Said out loud, because the reason this gate exists is that the cost
        -- is not in the call, it is in the first call.
        'note', case when p_enabled
                then 'the first call in each backend builds an adjacency snapshot; '
                     'see graph-algorithms.md §2.3 for what that costs per connection'
                else 'revoked' end);
end $$;

comment on function aiq.enable_graph_algorithms(name, boolean) is
    'Grant (or revoke) the experimental graph algorithms to a role. Off by default.';

-- The blanket revoke above ran BEFORE this function existed, so it did not
-- cover it -- and a gate the gated role can open is not a gate. Caught by
-- dev/tests/query/11 §7, which is the assertion that exists for exactly this
-- class of ordering mistake.
revoke execute on function aiq.enable_graph_algorithms(name, boolean) from public;

comment on function aiq.related(text[], int, text, int, timestamptz, boolean) is
    'Personalised PageRank from named seeds: what is related to these, ranked.';
comment on function aiq.graph_paths(text, text, int, int, int, text, timestamptz) is
    'The k cheapest paths between two named nodes, with as_of temporal filtering.';
comment on function aiq.graph_connect(text[], int, text) is
    'The smallest subgraph connecting a set of named nodes (approximate Steiner tree).';
comment on function aiq.graph_dense(text, int, int, int, text) is
    'Core numbers and maximal cliques in the neighbourhood of a named node.';
comment on function aiq.graph_trust(text[], float8, int, int, text, timestamptz) is
    'Confidence and corroboration propagated from seeds, over edge weights.';
comment on function aiq.graph_frontier(text, int, boolean, int) is
    'Estimated size of the k-hop neighbourhood, for deciding whether to walk it.';
comment on function aiq.graph_components(int, int) is
    'Connected components of the snapshot as built, named by their smallest node id.';
comment on function aiq.graph_induced(uuid[], text, timestamptz) is
    'The edges internal to a set of nodes -- one call answers many components at once.';
