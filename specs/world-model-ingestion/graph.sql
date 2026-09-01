-- ============================================================
-- graph.sql -- a lightweight, runnable implementation of graph-index.md.
--
-- Scope, stated so it is not mistaken for the whole design doc: this file
-- builds the WRITE path -- the two reference tables, the vocabulary, the
-- resolver, and `aiq.upsert_graph`, which is the repository function the whole
-- thing exists for. It does NOT build the windowing row functions or the bulk
-- indexer's scope predicate (graph-index.md §6.2/§6.3), which need a running
-- extractor to be worth anything.
--
-- The point of doing it in this order: the model half of graph-index.md is a
-- prompt and a schema, and neither can be tested without spending money. The
-- DATABASE half -- "given this JSON, does the right graph appear, and does the
-- wrong JSON get refused" -- is completely testable with a literal, which is
-- what graph-demo.sql does.
--
-- Re-applicable: `if not exists` / `create or replace` throughout.
-- ============================================================

-- ------------------------------------------------------------
-- 1. The vocabulary -- what an extractor may emit, and what a machine-written
--    edge is worth on a walk.
--
-- SEPARATE FROM aiq.relation_types on purpose, rather than a column added to
-- it. That table is the CATALOGUE: what the edge table permits from anyone,
-- authored edges included. This one is what the null extractor is ALLOWED TO
-- SAY, plus its tier prior. Registering the vocabulary writes both, so they
-- cannot disagree; keeping them separate means a relation an analyst may
-- author by hand does not thereby become one a cheap model may invent.
-- ------------------------------------------------------------
create table if not exists aiq.graph_vocabulary (
    relation       text primary key,
    machine_weight real not null default 0.5
        check (machine_weight > 0 and machine_weight <= 1.0),
    description    text,
    registered_at  timestamptz not null default now()
);

comment on table aiq.graph_vocabulary is
    'What a structure extractor may emit as `r`, and what that edge is worth on '
    'a graph_walk. Distinct from aiq.relation_types, which is what the edge '
    'table permits from any writer.';

-- machine_weight is not decoration: aiq.graph_walk scores a path as the
-- PRODUCT of its edge weights and orders by that score. 0.5 means two machine
-- hops (0.25) sort below one authored hop (1.0), which is the ordering an
-- analyst wants and would otherwise impose by hand on every query. It is a
-- PROVENANCE TIER PRIOR -- it says who wrote the edge, not how true it is.

-- ------------------------------------------------------------
-- 2. Registering the vocabulary, and the cross product it implies.
--
-- aiq.edges rejects any (src_type, relation, dst_type) not in the catalogue.
-- The soft and lake tiers are ONE entity_type each, but the pg tier is N, so
-- the triples an extracted graph can need are
--     (every registered entity type + 'soft' + 'lake')^2 x relations.
-- Generated here rather than hand-maintained.
--
-- THE REFRESH OBLIGATION, stated because it is the thing that will bite:
-- registering a NEW entity table afterwards does not extend the catalogue, so
-- the first extracted edge touching that type raises. The error names the
-- missing triple, so the message is the instruction: re-run this function.
-- Deliberately not a trigger on aiq.entity_registry -- one module silently
-- writing another module's catalogue is worse than a legible failure.
-- ------------------------------------------------------------
create or replace function aiq.register_graph_vocabulary(
    p_relations jsonb default null   -- [{"relation":..,"machine_weight":..,"description":..}]
) returns jsonb as $$
declare
    v_types text[];
    v_rels  int;
    v_trip  int;
begin
    if p_relations is not null then
        insert into aiq.graph_vocabulary (relation, machine_weight, description)
        select e->>'relation',
               coalesce((e->>'machine_weight')::real, 0.5),
               e->>'description'
        from jsonb_array_elements(p_relations) e
        on conflict (relation) do update
            set machine_weight = excluded.machine_weight,
                description    = coalesce(excluded.description, aiq.graph_vocabulary.description);
    end if;

    -- Every type an extracted edge can have at either end.
    select array_agg(distinct t) into v_types
    from (select entity_type as t from aiq.entity_registry
          union select 'soft' union select 'lake') s;

    select count(*) into v_rels from aiq.graph_vocabulary;

    insert into aiq.relation_types (src_type, relation, dst_type, description)
    select s, v.relation, d,
           'machine-extractable (aiq.graph_vocabulary)'
    from unnest(v_types) s, unnest(v_types) d, aiq.graph_vocabulary v
    on conflict (src_type, relation, dst_type) do nothing;
    get diagnostics v_trip = row_count;

    return jsonb_build_object(
        'relations', v_rels,
        'types', to_jsonb(v_types),
        'triples_added', v_trip,
        'triples_total', v_rels * array_length(v_types,1) * array_length(v_types,1));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 3. The two reference tables (graph-index.md §4.4).
--
-- Neither holds adjacency. Edges live once, in aiq.edges. That is the single
-- property separating these from the JSONB kv_store cache specs/README.md
-- declines to carry forward from ../p8k8 -- if either grows a column pointing
-- at another node, that rejection has been reversed.
-- ------------------------------------------------------------

-- 3a. Candidates: an entity the extractor named that resolved to nothing.
create table if not exists aiq.soft_nodes (
    id               uuid primary key default gen_random_uuid(),
    kind             text not null,     -- normalized claimed kind
    key              text not null,     -- normalized name
    label            text,              -- name as first seen, for display
    attrs            jsonb not null default '{}'::jsonb,
    org_id           uuid,
    -- NO `observations` COUNTER HERE, deliberately. An earlier version had one
    -- commented "distinct resources" and nothing ever incremented it -- a
    -- column making a claim no code kept. How often a thing was named is
    -- already answerable from the provenance of its edges, at the grain that
    -- actually means something (which document said it), so a second counter
    -- at node level would be a worse copy of a better answer.
    first_seen_at    timestamptz not null default now(),
    last_seen_at     timestamptz not null default now(),
    -- Set by promotion. Makes the row fail the inclusion predicate, which is
    -- how the candidate node is evicted -- see aiq.promote_soft_node.
    resolved_node_id uuid references aiq.nodes(id)
);

-- NULLS NOT DISTINCT, and it is the whole guarantee rather than a detail --
-- the same lesson node_keys learned. org_id IS NULL means shared reference
-- data, which is the normal state, and under the default two NULLs never
-- conflict: the constraint would hold for tenants and not at all for the tier
-- with the most rows.
create unique index if not exists idx_soft_nodes_key
    on aiq.soft_nodes (org_id, kind, key) nulls not distinct;
create index if not exists idx_soft_nodes_unresolved
    on aiq.soft_nodes (kind, key) where resolved_node_id is null;

-- 3b. Lake references: the entity's row is in Parquet, not in Postgres.
--
-- IDENTITY IS ALWAYS IN POSTGRES. PAYLOAD NEED NOT BE. aiq.nodes never stored
-- payload -- it stores entity_type + entity_id and lookup hydrates against the
-- owning table's key -- so nothing in graph-identity.md requires that owning
-- thing to be a Postgres table. A dataset row is hydrated by a different fetch
-- (DuckDB over content.dataset_uri) and is otherwise an ordinary vertex.
create table if not exists aiq.lake_nodes (
    id            uuid primary key default gen_random_uuid(),
    dataset       text not null,        -- content.datasets.name
    row_key       text not null,        -- the dataset's business key for the row
    label         text,
    -- A DISPLAY CACHE, and it must be treated as one: it exists so a walk can
    -- render a hundred vertices without a hundred DuckDB round trips. It is
    -- not the row, it may be stale, and NOTHING MAY COMPUTE ON IT. The row is
    -- in the Parquet; content.dataset_uri() names where; that is the only
    -- authority. The moment something joins or filters on this column, the
    -- lake has been forked into Postgres and this table has become the copy it
    -- exists to avoid.
    attrs         jsonb not null default '{}'::jsonb,
    org_id        uuid,
    first_seen_at timestamptz not null default now(),
    last_seen_at  timestamptz not null default now()
);
create unique index if not exists idx_lake_nodes_key
    on aiq.lake_nodes (org_id, dataset, row_key) nulls not distinct;

-- The move that makes both legal: they are ORDINARY ENTITY TABLES. The
-- projection gives them nodes/node_keys rows in the same transaction, so
-- invariant 4 (LOOKUP sees a committed insert) holds with no special case, and
-- invariant 5 is not bent -- application code writes a typed table it owns and
-- the projection writes aiq.nodes. Both are PGQ vertices already, because the
-- vertex table is aiq.nodes.
--
-- The canonical key is `kind/key`, the qualified form graph-identity.md calls
-- unambiguous. It is why ONE entity_type per residence does not collapse two
-- kinds into one identity.
--
-- NOTE the residence scheme is NOT in the key: `shipments/abc-771`, never
-- `lake:shipments/abc-771`. Residence is a fact about where a row currently
-- sits, and a dataset promoted into a table must not invalidate every name
-- that refers to it.
select aiq.register_entity_table(
    p_entity_type   => 'soft',
    p_source_table  => 'aiq.soft_nodes',
    p_key_expr      => 'n.kind || ''/'' || n.key',
    p_summary_expr  => 'coalesce(n.label, n.key)',
    p_org_expr      => 'n.org_id',
    p_include_where => 'n.resolved_node_id is null');

select aiq.register_entity_table(
    p_entity_type   => 'lake',
    p_source_table  => 'aiq.lake_nodes',
    p_key_expr      => 'n.dataset || ''/'' || n.row_key',
    p_summary_expr  => 'coalesce(n.label, n.row_key)',
    p_org_expr      => 'n.org_id');
-- No include_where on lake: a reference has no promotion path, because the row
-- it points at is already the real thing. There is nothing to resolve it INTO,
-- which is exactly what distinguishes a reference from a candidate.

-- ------------------------------------------------------------
-- 4. The output contract -- one definition, used three ways.
--
-- graph-index.md's wire shape, as a JSON Schema. It is the null extractor's
-- structured_output_schema, the step's output_schema, and what
-- aiq.is_graph_schema recognises. Defined ONCE here so those three cannot
-- drift, which is the same reason expand_embed_steps resolves a model in one
-- place rather than letting an author name it twice.
--
-- Short per-item keys are the token argument, and the ordinal is most of it:
-- naming endpoints by string makes a document that states eight relations
-- about "Acme Corporation" pay that string sixteen times. An ordinal is one
-- token. Top-level names are spelled out because they are paid once.
-- ------------------------------------------------------------
create or replace function aiq.graph_schema() returns jsonb as $$
    select jsonb_build_object(
      'type','object',
      'required', jsonb_build_array('nodes','edges'),
      'additionalProperties', false,
      'properties', jsonb_build_object(
        'nodes', jsonb_build_object(
          'type','array',
          'items', jsonb_build_object(
            'type','object',
            'required', jsonb_build_array('k','n'),
            'additionalProperties', false,
            'properties', jsonb_build_object(
              'k', jsonb_build_object('type','string',
                   'description','kind; optionally pg:/lake:/soft: prefixed'),
              'n', jsonb_build_object('type','string',
                   'description','the name as the document wrote it'),
              'a', jsonb_build_object('type','object')))),
        'edges', jsonb_build_object(
          'type','array',
          'items', jsonb_build_object(
            'type','object',
            'required', jsonb_build_array('s','t','r'),
            'additionalProperties', false,
            'properties', jsonb_build_object(
              's', jsonb_build_object('type','integer',
                   'description','ordinal into nodes, 0-based'),
              't', jsonb_build_object('type','integer',
                   'description','ordinal into nodes, 0-based'),
              'r', jsonb_build_object('type','string',
                   'enum', (select coalesce(jsonb_agg(relation order by relation),'[]'::jsonb)
                              from aiq.graph_vocabulary)),
              'a', jsonb_build_object('type','object'))))));
$$ language sql stable;

-- Detection exists to REFUSE at definition time, never to route at runtime
-- (graph-index.md §3). Routing is declared: a workflow names land_graph.
create or replace function aiq.is_graph_schema(p_schema jsonb) returns boolean as $$
    select coalesce(
        p_schema->'properties'->'nodes'->'items'->'properties' ?& array['k','n']
        and p_schema->'properties'->'edges'->'items'->'properties' ?& array['s','t','r'],
        false);
$$ language sql immutable;

-- ------------------------------------------------------------
-- 5. Type-scoped resolution.
--
-- WHY THIS IS NOT aiq.lookup, since duplicating a cascade is normally the
-- wrong answer here: aiq.lookup returns as soon as a STAGE matches, globally
-- across types. Filtering its result by entity_type afterwards is not the same
-- function -- a canonical hit of the wrong type would stop the cascade and
-- hide a short key of the right one, so "Acme Robotics" as a company would
-- resolve to nothing because some document happened to be canonically named
-- the same. A type filter has to live INSIDE the cascade.
--
-- If this ships beyond a trial, the consolidation is to give aiq.lookup an
-- optional entity_type and have this call it. Recorded here rather than left
-- as an unexplained twin.
-- ------------------------------------------------------------
-- ORG SCOPING IS AN EXPLICIT ARGUMENT, NOT AMBIENT RLS, AND THAT IS THE WHOLE
-- POINT OF THE PARAMETER. This function is SECURITY INVOKER, so a user calling
-- it directly is filtered by their own policies -- but aiq.upsert_graph is
-- SECURITY DEFINER (it writes tables the worker holds no grants on), and a
-- function called from inside a definer runs as the DEFINER. So resolution
-- inside the write path is not RLS-filtered at all, and without p_org_id a
-- tenant's document naming another tenant's private company would resolve to
-- it and hang an edge on it -- a cross-tenant write with nothing raised.
--
-- Found by dev/tests/query/06-graph-tenancy.sql §5 rejecting these functions
-- as definer-and-user-reachable; the grant was the surface bug, and this was
-- the one underneath it. `org_id is null` is the shared reference tier, which
-- integration-rbac.sql calls "a real category here, not a loophole."
create or replace function aiq.resolve_ref(
    p_entity_type text, p_name text, p_fuzzy boolean default false,
    p_threshold real default 0.45, p_org_id uuid default null
) returns uuid as $$
declare
    v_norm text := lower(trim(p_name));
    v_ids  uuid[];
begin
    -- 1. exact canonical, scoped to the type AND the caller's tenancy.
    select array_agg(distinct n.id) into v_ids
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind = 'canonical' and n.entity_type = p_entity_type
      and (n.org_id is null or n.org_id is not distinct from p_org_id);
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;  -- ambiguous: a miss

    -- 2. short / alias.
    select array_agg(distinct n.id) into v_ids
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind in ('short','alias') and n.entity_type = p_entity_type
      and (n.org_id is null or n.org_id is not distinct from p_org_id);
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;

    -- 3. fuzzy, opt-in, and only over node_keys -- never the data plane.
    if p_fuzzy then
        select array_agg(id) into v_ids from (
            select n.id, max(similarity(k.key, v_norm)) as sim
            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
            where n.entity_type = p_entity_type and k.key % v_norm
              and (n.org_id is null or n.org_id is not distinct from p_org_id)
            group by n.id having max(similarity(k.key, v_norm)) >= p_threshold
            order by 2 desc limit 2) d;
        -- Exactly one candidate above threshold, or it is a miss. AN AMBIGUOUS
        -- RESOLUTION IS A MISS, NOT A COIN FLIP -- the same rule add_node_key
        -- already applies ("refuses an ambiguous target rather than picking
        -- one"). Picking is wrong silently; a candidate is wrong visibly.
        if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    end if;

    return null;
end;
$$ language plpgsql stable security invoker;

-- ------------------------------------------------------------
-- 6. aiq.upsert_graph -- THE REPOSITORY FUNCTION.
--
-- Takes the structure an extractor produced and lands it: resolve every node
-- to a node id under the residence rules, then write the edges. Everything
-- else in this file exists to make this one call correct.
--
-- p_context: {"resource_id":uuid, "agent":text, "run_id":uuid, "window":int,
--             "org_id":uuid, "fuzzy":bool}
-- ------------------------------------------------------------
create or replace function aiq.upsert_graph(p_graph jsonb, p_context jsonb default '{}'::jsonb)
returns jsonb as $$
declare
    v_nodes   jsonb := p_graph->'nodes';
    v_edges   jsonb := coalesce(p_graph->'edges', '[]'::jsonb);
    v_n       int;
    v_ids     uuid[] := '{}';          -- ordinal -> node id
    v_res     text[] := '{}';          -- ordinal -> residence, for the receipt
    v_org     uuid   := (p_context->>'org_id')::uuid;
    -- FUZZY IS OFF BY DEFAULT, and that default was inverted after running it.
    --
    -- The obvious reading -- "resolve_ref implements the cascade, and the
    -- cascade ends in fuzzy, so use the cascade" -- gives a machine writer
    -- trigram matching over every name in the deployment. Measured on the test
    -- fixture: an extracted "Northgate Freight Ltd" bound itself to the
    -- existing "Northgate Freight" and no candidate was created, so an
    -- assertion about a company nobody had heard of landed on a real company's
    -- vertex with nothing raised.
    --
    -- That is the exact failure this file refuses everywhere else. Picking is
    -- wrong silently; a candidate is wrong visibly. A human typing LOOKUP is
    -- present to judge a fuzzy hit; an extractor is not, and its output is
    -- durable. So the machine path resolves on EXACT canonical, short and
    -- alias keys only -- which is what makes populating aliases a real step
    -- (graph-demo.sql §2) rather than a nicety -- and fuzzy is available
    -- per-call for a caller that has a reason.
    v_fuzzy   boolean := coalesce((p_context->>'fuzzy')::boolean, false);
    v_e       jsonb;
    v_node    jsonb;
    v_k       text; v_scheme text; v_kind text; v_name text; v_key text;
    v_id      uuid; v_soft uuid; v_lake uuid;
    v_s int; v_t int;
    v_rel text; v_w real;
    v_prov jsonb;
    v_counts jsonb := jsonb_build_object('pg',0,'lake',0,'soft',0);
    v_edges_written int := 0;
    v_self int := 0;
    v_merged int := 0;
    v_before bigint;
begin
    -- ---- Validate. This gate is LOAD-BEARING, not belt-and-braces: the
    -- step-level output_schema check is reported unimplemented by
    -- workflow.compiler_capabilities(), so nothing upstream is checking shape
    -- today. An error here names the agent so the reader knows who to blame.
    if v_nodes is null or jsonb_typeof(v_nodes) <> 'array' then
        raise exception 'graph payload has no `nodes` array (agent: %)',
            coalesce(p_context->>'agent','?');
    end if;
    if jsonb_typeof(v_edges) <> 'array' then
        raise exception 'graph payload `edges` is not an array (agent: %)',
            coalesce(p_context->>'agent','?');
    end if;
    v_n := jsonb_array_length(v_nodes);

    -- ---- Resolve, BY ORDINAL POSITION, from the list as emitted.
    --
    -- G5: ordinals are resolved exactly once, here, and nothing may reorder,
    -- filter or dedupe v_nodes first. An ordinal is a POSITIONAL reference, so
    -- a filter applied before this loop silently rewires every edge -- an edge
    -- from the wrong company to the wrong person, no error, and a graph that
    -- goes on answering confidently. Deduplication is a dedup of RESOLVED IDS,
    -- after this loop, never of the emitted list.
    for i in 0 .. greatest(v_n - 1, 0) loop
        exit when v_n = 0;
        v_node := v_nodes -> i;
        v_k    := lower(trim(coalesce(v_node->>'k','')));
        v_name := trim(coalesce(v_node->>'n',''));
        if v_k = '' or v_name = '' then
            raise exception 'node ordinal % has an empty kind or name (agent: %)',
                i, coalesce(p_context->>'agent','?');
        end if;

        -- Residence scheme, if the extractor pinned one. Bare is the normal
        -- case: a cheap model does not know where anything in this deployment
        -- lives, and asking it to say would be asking it to hallucinate
        -- infrastructure. The scheme is for a TYPED extractor that knows what
        -- it is mapping onto.
        v_scheme := null;
        if strpos(v_k, ':') > 0 then
            v_scheme := split_part(v_k, ':', 1);
            v_kind   := split_part(v_k, ':', 2);
            if v_scheme not in ('pg','lake','soft') then
                raise exception
                    'node ordinal % has residence scheme ''%'', which is not one of '
                    'pg/lake/soft. A kind containing '':'' is read as a scheme.', i, v_scheme;
            end if;
        else
            v_kind := v_k;
        end if;
        v_key := lower(trim(v_name));
        v_id  := null;

        -- (a) pg: the kind names a registered entity type and the name
        --     resolves. The edge lands on the REAL typed vertex, and PGQ walks
        --     it as that type because aiq.nodes.entity_type already says so.
        if coalesce(v_scheme,'pg') = 'pg'
           and exists (select 1 from aiq.entity_registry where entity_type = v_kind) then
            v_id := aiq.resolve_ref(v_kind, v_name, v_fuzzy, 0.45, v_org);
            if v_id is not null then
                v_counts := jsonb_set(v_counts, '{pg}',
                            to_jsonb((v_counts->>'pg')::int + 1));
                v_res := v_res || 'pg'::text;
            end if;
        end if;

        -- (b) lake: the kind names a registered dataset. A reference is
        --     CREATED rather than resolved-or-refused, and the asymmetry with
        --     (c) is the point: refusing to invent a `companies` row is right
        --     because that table has an owner, an inclusion predicate and a
        --     projection that a back-door insert would bypass. aiq.lake_nodes
        --     has none of those -- it is a reference table this path owns, and
        --     writing a pointer to a Parquet row is not writing the row.
        --
        --     The DATASET is checked; the row_key is taken on trust, because
        --     checking it means a DuckDB read from inside a Postgres function.
        --     A dangling reference is a known gap (graph-index.md §9).
        if v_id is null
           and coalesce(v_scheme,'') in ('lake','')
           and exists (select 1 from content.datasets where name = v_kind) then
            insert into aiq.lake_nodes (dataset, row_key, label, attrs, org_id)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org)
            on conflict (org_id, dataset, row_key) do update
                set last_seen_at = now(),
                    label = coalesce(aiq.lake_nodes.label, excluded.label),
                    attrs = content.merge_policy(aiq.lake_nodes.attrs, excluded.attrs)
            returning id into v_lake;
            -- The projection fired with the statement above, so the node
            -- exists NOW -- invariant 4, with no special case.
            select id into v_id from aiq.nodes
             where entity_type = 'lake' and entity_id = v_lake;
            v_counts := jsonb_set(v_counts, '{lake}', to_jsonb((v_counts->>'lake')::int + 1));
            v_res := v_res || 'lake'::text;
        elsif v_scheme = 'lake' and v_id is null then
            raise exception
                'node ordinal % pins residence lake:% but no dataset named ''%'' is '
                'registered in content.datasets. A pinned residence is a claim by the '
                'EXTRACTOR AUTHOR, not by the model, so it is refused rather than '
                'downgraded to a candidate.', i, v_kind, v_kind;
        end if;

        -- (c)/(d) soft: a registered kind whose name did not resolve, or a
        --     kind nothing knows. Either way a CANDIDATE, carrying the kind it
        --     claimed. It is not a company; binding it to one is entity
        --     resolution (brief.md §4's tiered cascade), a separate and later
        --     job. What this contributes is the claim, written down with its
        --     provenance, so that cascade has something to resolve.
        if v_id is null then
            insert into aiq.soft_nodes (kind, key, label, attrs, org_id)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org)
            on conflict (org_id, kind, key) do update
                set last_seen_at = now(),
                    label = coalesce(aiq.soft_nodes.label, excluded.label),
                    attrs = content.merge_policy(aiq.soft_nodes.attrs, excluded.attrs)
            returning id into v_soft;
            select id into v_id from aiq.nodes
             where entity_type = 'soft' and entity_id = v_soft;
            v_counts := jsonb_set(v_counts, '{soft}', to_jsonb((v_counts->>'soft')::int + 1));
            v_res := v_res || 'soft'::text;
        end if;

        v_ids := v_ids || v_id;
    end loop;

    -- ---- Edges.
    for v_e in select value from jsonb_array_elements(v_edges) loop
        v_s := (v_e->>'s')::int;
        v_t := (v_e->>'t')::int;
        v_rel := lower(trim(v_e->>'r'));

        -- Out of range RAISES rather than skipping. A dropped edge is a hole
        -- in a graph that still answers questions, which is worse than a run
        -- that failed loudly.
        if v_s is null or v_t is null or v_s < 0 or v_t < 0 or v_s >= v_n or v_t >= v_n then
            raise exception
                'edge references node ordinal s=%, t=% but only % nodes were emitted. '
                'Ordinals are positions in the `nodes` array as the model wrote it.',
                v_s, v_t, v_n;
        end if;
        if not exists (select 1 from aiq.graph_vocabulary where relation = v_rel) then
            raise exception
                'relation ''%'' is not in aiq.graph_vocabulary. The vocabulary is closed: '
                'an extractor that can emit anything cannot be checked, costed, or '
                'swapped for a cheaper one.', v_rel;
        end if;

        -- A self-edge is a model artefact ("Acme, a subsidiary of Acme"), not
        -- a wiring bug, so it is dropped -- but COUNTED IN THE RECEIPT, never
        -- silently, which is how this collection has previously reported
        -- success while losing data.
        if v_ids[v_s+1] = v_ids[v_t+1] then
            v_self := v_self + 1;
            continue;
        end if;

        select machine_weight into v_w from aiq.graph_vocabulary where relation = v_rel;

        -- Provenance: WHERE THIS EDGE CAME FROM, and it is not bookkeeping --
        -- it is what makes the machine tier separable from the authored tier.
        -- An edge with no provenance did not come from here.
        --
        -- Edge attributes ride INSIDE the source entry rather than in a column
        -- of their own, and that is deliberate: "since 2019" is something a
        -- particular document asserted, not a property of the edge in general.
        -- Two documents may disagree, and a column would have to pick.
        v_prov := jsonb_build_object(
            'tier','machine',
            'sources', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                'resource_id', p_context->>'resource_id',
                'agent',       p_context->>'agent',
                'run_id',      p_context->>'run_id',
                'window',      p_context->'window',
                'attrs',       nullif(v_e->'a','{}'::jsonb),
                'at',          to_char(now(),'YYYY-MM-DD"T"HH24:MI:SSOF')))));

        select count(*) into v_before from aiq.edges
         where src_id = v_ids[v_s+1] and dst_id = v_ids[v_t+1] and relation = v_rel;

        insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id)
        values (v_ids[v_s+1], v_ids[v_t+1], v_rel, v_w, v_prov, v_org)
        -- THE SAME EDGE FROM TWO DOCUMENTS IS ONE ROW, because edge identity is
        -- (src, dst, relation). The second assertion merges into the
        -- provenance list rather than replacing it -- and the resulting count
        -- IS a distinct-resource count, because a document-level extractor
        -- emits each edge once per document. It is still the weak, gameable
        -- proxy brief.md §4 warns about, and it is NOT a trust score.
        on conflict (src_id, dst_id, relation) do update
            -- `||` on the OBJECT, and coalesce on the array, because this edge
            -- may not have been written by this path at all. Written as
            -- jsonb_set(existing, '{sources}', existing->'sources' || new) it
            -- is a silent total erase: an AUTHORED edge has no `sources` key,
            -- so `existing->'sources'` is NULL, `NULL || jsonb` is NULL, and
            -- jsonb_set returns NULL -- the whole provenance column, including
            -- whatever the analyst put there. The NOT NULL constraint caught
            -- it here only by luck; on a nullable column it would have been a
            -- silent data loss on the most ordinary event there is, a machine
            -- agreeing with a human. Found by asserting §11.
            set provenance = aiq.edges.provenance || jsonb_build_object(
                    'sources',
                    coalesce(aiq.edges.provenance->'sources', '[]'::jsonb)
                    || (case when coalesce(aiq.edges.provenance->'sources','[]'::jsonb) @>
                                  jsonb_build_array(jsonb_build_object(
                                      'resource_id', p_context->>'resource_id'))
                             then '[]'::jsonb
                             else excluded.provenance->'sources' end)),
                -- GREATEST, not least: weight is the BEST provenance tier that
                -- ever asserted this edge. A cheap model agreeing with an
                -- analyst adds nothing, but it must not subtract -- and
                -- `least` did exactly that, quietly demoting an authored edge
                -- from 1.0 to the machine prior and reordering every walk
                -- through it. Corroboration by a weaker source is not evidence
                -- against a stronger one.
                weight = greatest(aiq.edges.weight, excluded.weight);

        if v_before > 0 then v_merged := v_merged + 1; else v_edges_written := v_edges_written + 1; end if;
    end loop;

    -- A receipt (outputs.md §2): counts and what was written, never the rows.
    return jsonb_build_object(
        'nodes', v_n,
        'residence', v_counts,
        'edges_new', v_edges_written,
        'edges_merged', v_merged,
        'self_edges_dropped', v_self,
        'node_ids', to_jsonb(v_ids));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 7. The two workflow entry points (graph-index.md §5).
--
-- The split is FORCED BY THE ENGINE, not chosen. A matrix step's result is
-- {"result":{"task_id":..,"fanout":N}}, which is why land_embeddings can take
-- a task id; an ordinary step's result is its payload, and a step has NO
-- TEMPLATE FOR ITS OWN TASK ID. Document granularity makes the ordinary upload
-- a single agent step, so it has no task id to hand a landing function and
-- must pass the graph itself -- which is fine here and would not have been for
-- embeddings, because a graph is a few KB and a fan-out of 1536-dim vectors is
-- not.
-- ------------------------------------------------------------
create or replace function aiq.land_graph(p_graph jsonb, p_resource_id uuid default null)
returns jsonb as $$
declare v_org uuid; v_agent text;
begin
    if p_resource_id is not null then
        select org_id into v_org from content.resources where id = p_resource_id;
    end if;
    -- No run guard is needed and none is written: this function takes a
    -- payload and a resource id from its own run's input, so there is no task
    -- id to point at somebody else's run. land_graph_fanout, which does take
    -- one, carries the guard.
    return aiq.upsert_graph(p_graph, jsonb_build_object(
        'resource_id', p_resource_id, 'org_id', v_org,
        'run_id', nullif(current_setting('workflow.current_run_id', true),''),
        'agent', 'structure_null'));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

create or replace function aiq.land_graph_fanout(p_matrix_task uuid)
returns jsonb as $$
declare
    v_run uuid; v_cur text; v_child record;
    v_missing int; v_total int;
    v_acc jsonb := jsonb_build_object('graphs',0,'edges_new',0,'edges_merged',0,'self_edges_dropped',0);
    v_r jsonb;
begin
    select run_id into v_run from workflow.tasks where id = p_matrix_task;
    if not found then raise exception 'task % not found', p_matrix_task; end if;

    -- The same guard workflow.matrix_outputs() uses, for the same reason: a
    -- step may read the fan-out of its OWN run. Without it a registered step
    -- function handed an arbitrary task id is a read of someone else's run.
    v_cur := nullif(current_setting('workflow.current_run_id', true), '');
    if v_cur is null or v_cur::uuid <> v_run then
        raise exception
            'task % belongs to run %, which is not the run being executed. Pass '
            '{{steps.<id>.result.task_id}} rather than a task id from elsewhere.',
            p_matrix_task, v_run;
    end if;

    select count(*) into v_total from workflow.tasks where matrix_parent_id = p_matrix_task;
    -- A child that succeeded and left no `result` was offloaded as an artifact.
    -- Raised rather than skipped: a document silently absent from the index is
    -- a hole in a graph that still answers questions.
    select count(*) into v_missing from workflow.tasks
     where matrix_parent_id = p_matrix_task and status = 'done'
       and (output is null or not (output ? 'result'));
    if v_missing > 0 then
        raise exception
            '% of % graph children completed with no payload -- they were offloaded as '
            'artifacts because the response exceeded workflow.max_payload_bytes. Raise '
            'the cap for the queue that indexes, or window the document.', v_missing, v_total;
    end if;

    for v_child in
        select t.output->'result' as graph, t.input->'item'->>'resource_id' as rid,
               t.input->'item'->'window_ordinal' as win
        from workflow.tasks t
        where t.matrix_parent_id = p_matrix_task and t.status = 'done'
    loop
        v_r := aiq.upsert_graph(v_child.graph, jsonb_build_object(
            'resource_id', v_child.rid, 'run_id', v_run,
            'window', v_child.win, 'agent', 'structure_null'));
        v_acc := jsonb_build_object(
            'graphs',             (v_acc->>'graphs')::int + 1,
            'edges_new',          (v_acc->>'edges_new')::int + (v_r->>'edges_new')::int,
            'edges_merged',       (v_acc->>'edges_merged')::int + (v_r->>'edges_merged')::int,
            'self_edges_dropped', (v_acc->>'self_edges_dropped')::int + (v_r->>'self_edges_dropped')::int);
    end loop;

    return v_acc || jsonb_build_object('children', v_total);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 8. Promotion -- and it must rewrite edges BEFORE it evicts.
--
-- THE SHARP EDGE OF THE WHOLE DESIGN. aiq.edges cascades on node delete, so
-- setting resolved_node_id (which makes the row fail the inclusion predicate,
-- which evicts the candidate node) DESTROYS EVERY EDGE THE INDEXER WROTE about
-- it -- which is the entire product.
--
-- And the conflict in step 1/2 is the EXPECTED state, not a corner case: the
-- reason a candidate is being promoted is usually that it and the real node
-- were talked about in the same corpus, so a shared edge is normal. A
-- promotion that fails on the unique constraint is an outage; one that drops
-- the conflicting edge is silent loss. Merging is the only correct option.
-- ------------------------------------------------------------
create or replace function aiq.promote_soft_node(p_soft_id uuid, p_target_node_id uuid)
returns jsonb as $$
declare
    v_cand uuid; v_moved int := 0; v_merged int := 0; v_self int := 0; v_c int;
begin
    select id into v_cand from aiq.nodes where entity_type = 'soft' and entity_id = p_soft_id;
    if v_cand is null then
        raise exception 'soft node % has no registry node (already promoted?)', p_soft_id;
    end if;
    if not exists (select 1 from aiq.nodes where id = p_target_node_id) then
        raise exception 'target node % does not exist', p_target_node_id;
    end if;

    -- 1/2. Repoint, merging provenance on conflict.
    for v_c in select 1 loop end loop;  -- (no-op; keeps the block shape readable)

    with moved as (
        update aiq.edges e set src_id = p_target_node_id
        where e.src_id = v_cand
          and not exists (select 1 from aiq.edges x
                          where x.src_id = p_target_node_id and x.dst_id = e.dst_id
                            and x.relation = e.relation)
        returning 1)
    select count(*) into v_c from moved;  v_moved := v_moved + v_c;

    with merged as (
        update aiq.edges x
           set provenance = jsonb_set(x.provenance, '{sources}',
                            (x.provenance->'sources') || (e.provenance->'sources')),
               weight = least(x.weight, e.weight)
          from aiq.edges e
         where e.src_id = v_cand and x.src_id = p_target_node_id
           and x.dst_id = e.dst_id and x.relation = e.relation
        returning 1)
    select count(*) into v_c from merged;  v_merged := v_merged + v_c;
    delete from aiq.edges where src_id = v_cand;

    with moved as (
        update aiq.edges e set dst_id = p_target_node_id
        where e.dst_id = v_cand
          and not exists (select 1 from aiq.edges x
                          where x.dst_id = p_target_node_id and x.src_id = e.src_id
                            and x.relation = e.relation)
        returning 1)
    select count(*) into v_c from moved;  v_moved := v_moved + v_c;

    with merged as (
        update aiq.edges x
           set provenance = jsonb_set(x.provenance, '{sources}',
                            (x.provenance->'sources') || (e.provenance->'sources')),
               weight = least(x.weight, e.weight)
          from aiq.edges e
         where e.dst_id = v_cand and x.dst_id = p_target_node_id
           and x.src_id = e.src_id and x.relation = e.relation
        returning 1)
    select count(*) into v_c from merged;  v_merged := v_merged + v_c;
    delete from aiq.edges where dst_id = v_cand;

    -- 3. An edge the repoint made self-referential.
    delete from aiq.edges where src_id = p_target_node_id and dst_id = p_target_node_id;
    get diagnostics v_self = row_count;

    -- 4. Only now: evict. The candidate stops satisfying the inclusion
    --    predicate and the projection's UPDATE eviction removes its node.
    update aiq.soft_nodes set resolved_node_id = p_target_node_id where id = p_soft_id;

    return jsonb_build_object('moved', v_moved, 'merged', v_merged,
                              'self_removed', v_self, 'target', p_target_node_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 9. The default mapping agent -- data, not code.
--
-- Authored form, for the record (agentic/brief.md §6: the JSON Schema a
-- pydantic model emits IS the agent -- the docstring is the system prompt and
-- the properties are the output contract):
--
--   class GraphMap(BaseModel):
--       """Read the document and return only what it NAMES and how those
--       things CONNECT. Use a `k` from the kinds listed; if none fits, invent
--       a lowercase singular noun. `n` is the name exactly as written. Edges
--       reference nodes by their ORDINAL in your `nodes` list, and `r` must be
--       one of the listed relations. Assert nothing the document does not
--       state."""
--       model_config = ConfigDict(json_schema_extra={
--           "name": "structure_null", "model": "claude-haiku-4-5-20251001",
--           "category": "extractor", "audience": "internal"})
--       nodes: list[GraphNode]
--       edges: list[GraphEdge]
--
-- There is no `prompt` key in that convention -- the system prompt is the
-- schema's description, which is the docstring. Registering it here is the
-- deployment step, and it is an INSERT.
--
-- category='extractor' is not decoration: agentic.schema.sql enforces that an
-- extractor declares a structured_output_schema, because the shape is what
-- makes N extractions combinable and what makes a bad answer RETRYABLE rather
-- than silently wrong.
-- ------------------------------------------------------------
create or replace function aiq.install_structure_null(p_model text default null)
returns text as $$
declare v_row agentic.agents;
begin
    v_row := agentic.upsert_agent(jsonb_build_object(
        'name', 'structure_null',
        'model', p_model,
        'category', 'extractor',
        'audience', 'internal',
        'tags', jsonb_build_array('graph','structure','null-extractor'),
        'system_prompt',
            'Read the document and return only what it NAMES and how those things '
         || 'CONNECT. Use a `k` from the kinds listed; if none fits, invent a '
         || 'lowercase singular noun. `n` is the name exactly as written. Edges '
         || 'reference nodes by their ORDINAL in your `nodes` list, and `r` must be '
         || 'one of the listed relations. Assert nothing the document does not state.',
        'structured_output_schema', aiq.graph_schema()));
    return 'structure_null: ' || v_row.id::text
        || ' (' || coalesce(v_row.model,'no model pinned') || ')';
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 10. Workflow registration and grants.
-- ------------------------------------------------------------
select workflow.register_step_function(
    'land_graph', 'aiq.land_graph', array['jsonb','uuid'], 60000,
    'Upsert one extracted graph into nodes/edges');

select workflow.register_step_function(
    'land_graph_fanout', 'aiq.land_graph_fanout', array['uuid'], 120000,
    'Upsert every graph a matrix fan-out produced');

-- REVOKE FROM PUBLIC FIRST. Postgres grants EXECUTE on a new function to
-- PUBLIC by default, so "granted to worker" is not a restriction -- it is an
-- addition to an access every role already had. Every SECURITY DEFINER
-- function below was therefore reachable by `authenticated`, which is exactly
-- what query/06 §5 refuses: a definer function a user can call must either do
-- its own authorization check or not be callable by a user at all. These are
-- worker-facing, so the grant IS the authorization -- but only once the
-- default one is taken away.
revoke execute on function aiq.upsert_graph(jsonb, jsonb)                  from public;
revoke execute on function aiq.land_graph(jsonb, uuid)                     from public;
revoke execute on function aiq.land_graph_fanout(uuid)                     from public;
revoke execute on function aiq.promote_soft_node(uuid, uuid)               from public;
revoke execute on function aiq.register_graph_vocabulary(jsonb)            from public;
revoke execute on function aiq.install_structure_null(text)                from public;

grant execute on function aiq.upsert_graph(jsonb, jsonb)      to worker;
grant execute on function aiq.land_graph(jsonb, uuid)         to worker;
grant execute on function aiq.land_graph_fanout(uuid)         to worker;
-- promote_soft_node is entity resolution's write path, which is background
-- work, not a user action -- so it is worker-facing too.
grant execute on function aiq.promote_soft_node(uuid, uuid)   to worker;

-- The read helpers are SECURITY INVOKER, so a user calling them is filtered by
-- their own policies and the grant is safe.
grant execute on function aiq.resolve_ref(text, text, boolean, real, uuid)
                                                              to worker, authenticated;
grant execute on function aiq.graph_schema()                  to worker, authenticated;
grant execute on function aiq.is_graph_schema(jsonb)          to worker, authenticated;
grant select on aiq.soft_nodes, aiq.lake_nodes, aiq.graph_vocabulary to authenticated, api_viewer;

-- ------------------------------------------------------------
-- 11. The default vocabulary, installed rather than left to a first caller.
--
-- Ships as DATA because it is not a preference: aiq.edges refuses an
-- out-of-catalogue relation, so a deployment whose vocabulary is empty cannot
-- land a single extracted edge and the failure is a catalogue error rather
-- than "nobody registered a vocabulary". The agent is NOT installed here --
-- it is one `select aiq.install_structure_null()` away, the same shape as
-- content.install_ingest_workflow(), because which model to point it at is a
-- deployment's decision and an install may not make it.
--
-- The relational subset of extraction.md's motif list, plus a small generic
-- remainder, so the null extractor and the templated extractors land in ONE
-- vocabulary rather than two that drift. Generic on purpose: this runs over a
-- corpus with no known format, and a rich vocabulary would mostly be a menu a
-- cheap model picks from at random. A source that has earned a template should
-- use the template's motifs instead.
--
-- IT IS AN ARGUMENT, NOT A MEASUREMENT, unlike extraction.md's eight motifs,
-- which came from 32 real documents. The first operational task after this
-- ships is to count which of these are ever emitted and which never resolve.
-- ------------------------------------------------------------
select aiq.register_graph_vocabulary($v$[
  {"relation":"is_a",            "machine_weight":0.6,  "description":"classification (extraction.md motif)"},
  {"relation":"part_of",         "machine_weight":0.6,  "description":"composition, ownership (motif)"},
  {"relation":"succession",      "machine_weight":0.5,  "description":"replacement over time (motif)"},
  {"relation":"causal",          "machine_weight":0.25, "description":"deliberately low-confidence (motif)"},
  {"relation":"mentions",        "machine_weight":0.4,  "description":"co-occurrence; the weakest useful edge"},
  {"relation":"located_in",      "machine_weight":0.6,  "description":"physical or jurisdictional containment"},
  {"relation":"affiliated_with", "machine_weight":0.5,  "description":"connected, unspecified"},
  {"relation":"owns",            "machine_weight":0.6,  "description":"ownership or control"},
  {"relation":"supplies",        "machine_weight":0.6,  "description":"provides goods or services to"},
  {"relation":"party_to",        "machine_weight":0.7,  "description":"a named party of an agreement"},
  {"relation":"binds",           "machine_weight":0.7,  "description":"a clause imposing an obligation on a party"},
  {"relation":"contains",        "machine_weight":0.8,  "description":"a document containing a part of itself"}
]$v$::jsonb);
