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

-- ------------------------------------------------------------
-- WHAT `upsert_graph` WILL ACTUALLY ACCEPT, which is wider than the table
-- above and was not discoverable from anywhere.
--
-- `graph_vocabulary` holds the forward names. Since inverses were accepted,
-- `upsert_graph` also takes any vocabulary relation's `inverse_label` and
-- stores it flipped -- so the table under-reports the accepted set, and a
-- consumer pre-filtering against it drops exactly the edges the flip exists to
-- recover. That is not hypothetical: percolate-coherence read this table,
-- pre-filtered `owned_by` out client-side, and defeated the feature from the
-- outside while its own counter reported the drops as a vocabulary gap.
--
-- A VIEW rather than a column on the table, because the answer is derived and a
-- copy would drift: this reproduces `upsert_graph`'s resolution exactly, right
-- down to the join that keeps the flip from being a side door into
-- authored-only terms, and to vocabulary membership winning where a term is
-- also some other term's inverse.
-- ------------------------------------------------------------
create or replace view aiq.graph_accepted_relations as
    select relation as accepted, relation as stored_as, false as flipped
      from aiq.graph_vocabulary
    union
    select distinct rt.inverse_label, rt.relation, true
      from aiq.relation_types rt
      join aiq.graph_vocabulary gv on gv.relation = rt.relation
     where rt.inverse_label is not null
       and not exists (select 1 from aiq.graph_vocabulary v
                        where v.relation = rt.inverse_label);

comment on view aiq.graph_accepted_relations is
    'Every spelling aiq.upsert_graph will accept as `r`, and what each is stored '
    'as. A consumer that pre-filters an extractor''s output reads THIS, not '
    'aiq.graph_vocabulary -- the latter omits the inverse labels, so filtering '
    'on it discards the edges upsert_graph would have flipped and landed.';

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
    p_relations jsonb default null
    -- [{"relation":..,"machine_weight":..,"description":..,
    --   "is_symmetric":..,"inverse_label":..}]
) returns jsonb as $$
declare
    v_types  text[];
    v_rels   int;
    v_trip   int;
    v_before int;
begin
    if p_relations is not null then
        -- INSERT THEN UPDATE, rather than one INSERT ... ON CONFLICT, and the
        -- shape is the fix rather than a style choice.
        --
        -- What was wrong: `coalesce((e->>'machine_weight')::real, 0.5)` ran in
        -- the SELECT, so by the time `excluded` was formed a caller who named
        -- no weight and a caller who named 0.5 were the same caller -- and the
        -- unconditional `set machine_weight = excluded.machine_weight` then
        -- reset a tuned weight to the prior on every re-registration.
        -- `description` was protected against exactly this one line below it.
        --
        -- That was not a hypothetical bootstrap. The shipped vocabulary at the
        -- foot of this file re-registers all twelve relations on every
        -- ALTER EXTENSION percolate UPDATE, so an operator's tuning was undone
        -- by UPGRADING. And it was invisible: aiq.upsert_graph seeds a new edge
        -- from this column and merges with `greatest(edges.weight,
        -- excluded.weight)`, so existing edges refuse the demotion and only
        -- edges written after the reset carry it -- a silent retune of
        -- everything ingested from then on.
        --
        -- Why not just move the coalesce into the conflict clause: a column
        -- default applies when the column is OMITTED, never when NULL is
        -- supplied for it, so the same statement cannot both pass NULL through
        -- to `excluded` and fall back to `default 0.5`. It fails with a
        -- not-null violation on the first registration -- which is what
        -- dev/tests/query/10 caught before this comment was true.
        --
        -- Insert-then-update has neither problem, and keeps 0.5 in ONE place:
        -- the column. A new relation takes the column default because the
        -- insert does not name the column; then the update applies whatever
        -- the payload ACTUALLY said, and nothing when it said nothing. A caller
        -- who genuinely means 0.5 says 0.5.
        insert into aiq.graph_vocabulary (relation, description)
        select e->>'relation', e->>'description'
        from jsonb_array_elements(p_relations) e
        on conflict (relation) do nothing;

        update aiq.graph_vocabulary g
           set machine_weight = coalesce((e->>'machine_weight')::real, g.machine_weight),
               description    = coalesce(e->>'description',            g.description)
          from jsonb_array_elements(p_relations) e
         where g.relation = e->>'relation';
    end if;

    -- Every type an extracted edge can have at either end.
    select array_agg(distinct t) into v_types
    from (select entity_type as t from aiq.entity_registry
          union select 'soft' union select 'lake') s;

    select count(*) into v_rels from aiq.graph_vocabulary;
    select count(*) into v_before from aiq.relation_types;

    -- SYMMETRY AND INVERSES COME THROUGH HERE, because this is the only path
    -- that writes a machine relation's triples and it used to write four
    -- columns and no others -- so every relation any consumer registered took
    -- `is_symmetric` false and `inverse_label` null, with no later pass and no
    -- other function exposing either. The only remaining way to declare a
    -- relation symmetric was to connect as app_owner and hand-write SQL
    -- against a base table (integration-rbac.sql grants SELECT and nothing
    -- else), which is the one thing the whole grant design exists to avoid.
    -- The catalogue trigger that normalises endpoint order was therefore built
    -- and unreachable, and every symmetric relation a consumer registers is
    -- stored in both orientations: twice the mass in a ranked walk and a degree
    -- of two in k-core, which is a wrong number rather than an error.
    --
    -- Both are properties of the RELATION and this table is keyed by the
    -- triple, so they are written across every triple the relation generates.
    -- aiq.relation_types' own triggers hold that invariant for writers who are
    -- not this function.
    --
    -- READ FROM THE PAYLOAD FIRST AND FROM THE EXISTING TRIPLES SECOND,
    -- because the no-payload call is the REFRESH call -- registering a new
    -- entity table re-runs this to widen the cross product (see the refresh
    -- obligation above), and a refresh that reset symmetry to the column
    -- default would be the machine_weight bug wearing a different column.
    with declared as (
        select e->>'relation'                as relation,
               (e->>'is_symmetric')::boolean as is_symmetric,
               e->>'inverse_label'           as inverse_label
          from jsonb_array_elements(coalesce(p_relations, '[]'::jsonb)) e
    ), term as (
        select v.relation,
               coalesce(d.is_symmetric,  x.is_symmetric)  as is_symmetric,
               coalesce(d.inverse_label, x.inverse_label) as inverse_label
          from aiq.graph_vocabulary v
          left join declared d on d.relation = v.relation
          left join lateral (
              select bool_or(rt.is_symmetric) as is_symmetric,
                     min(rt.inverse_label)    as inverse_label
                from aiq.relation_types rt
               where rt.relation = v.relation) x on true
    )
    insert into aiq.relation_types (src_type, relation, dst_type, description,
                                    is_symmetric, inverse_label)
    select s, t.relation, d,
           'machine-extractable (aiq.graph_vocabulary)',
           t.is_symmetric, t.inverse_label
    from unnest(v_types) s, unnest(v_types) d, term t
    -- `do update` rather than `do nothing`: a second registration that adds a
    -- declaration has to reach the triples the first one already made, or the
    -- only way to declare symmetry would be to get it right before the first
    -- call. description is deliberately not in the SET -- an authored triple
    -- keeps its own words.
    on conflict (src_type, relation, dst_type) do update
        set is_symmetric  = excluded.is_symmetric,
            inverse_label = excluded.inverse_label;

    -- Counted by difference rather than by `get diagnostics`: row_count now
    -- includes the updated rows, so the old reading would report every triple
    -- in the catalogue as newly added on every refresh.
    select count(*) - v_before into v_trip from aiq.relation_types;

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
    id               uuid primary key default uuidv7(),
    -- RENAMED from `kind`, and the rename is the point rather than tidying.
    -- graph-index.md §4.3(c) and (d) have called this `claimed_kind` in prose
    -- since it was designed, and the column did not -- while the ADJACENT table
    -- in the same schema spends the same four letters on the other meaning:
    -- aiq.node_keys.kind is the KEY's class, always canonical/short/alias.
    --
    -- The collision is obvious once and invisible before, and it costs a real
    -- wrong answer rather than a moment's confusion. node_keys is the table a
    -- consumer reaches FIRST, because it is the one carrying the name they
    -- matched on; filtering entities on its `kind` returns 'canonical' for
    -- every row, filters nothing, and raises nothing. A real identity pass
    -- clustered `company/nxp semiconductors` with `product/semiconductors` on
    -- exactly this, and naming the column what the design already called it cut
    -- its candidate pairs by more than half.
    --
    -- CLAIMED, not asserted: this is what the extractor SAID the thing was,
    -- recorded verbatim, including kinds no registered table has. The kind
    -- vocabulary is open (§4.3(d)) precisely so an unindexed corpus is not
    -- refused, which makes "claimed" the honest half of the name as well as the
    -- disambiguating one.
    claimed_kind     text not null,     -- normalized claimed kind
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
-- ...and on a database that already has the table, where `create table if not
-- exists` above is a no-op and the column is still called kind. Guarded,
-- because RENAME COLUMN has no IF EXISTS and this file is replayed on every
-- upgrade: unguarded it succeeds exactly once and fails every run after. Same
-- shape as agentic.sessions' user_id -> owner_id, and no delta file is needed
-- for the same reason that one needed half of one -- no view selects this
-- column, so nothing has to be dropped and recreated around it.
do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'aiq' and table_name = 'soft_nodes'
                  and column_name = 'kind') then
        alter table aiq.soft_nodes rename column kind to claimed_kind;
    end if;
    -- AND THE CONSTRAINT THE COLUMN CARRIES. Postgres 17 gave NOT NULL its own
    -- catalog entry with a generated name, and RENAME COLUMN moves the
    -- constraint without renaming it -- so an upgraded database ended up with
    -- `soft_nodes_kind_not_null` on a column called claimed_kind while a fresh
    -- install had `soft_nodes_claimed_kind_not_null`. Same enforcement, two
    -- names, and the two ways of reaching 0.1.4 no longer agree.
    --
    -- Found by dev/upgrade-converges.sh rather than by reasoning about it,
    -- which is the entire argument for that script: nothing else in this
    -- repository compares an upgraded database to a fresh one, so this would
    -- have shipped as an invisible difference and surfaced years later as a
    -- migration that works on one deployment and not another.
    if exists (select 1 from pg_constraint
                where conrelid = 'aiq.soft_nodes'::regclass
                  and conname = 'soft_nodes_kind_not_null') then
        alter table aiq.soft_nodes
            rename constraint soft_nodes_kind_not_null to soft_nodes_claimed_kind_not_null;
    end if;
end $$;

-- AFTER the rename, not before: on an upgrading database the statement above is
-- what makes the column exist under this name, and `create index if not exists`
-- is matched on the index NAME, so it would neither fail nor fix an index built
-- over the old column. (It does not have to: a rename carries its indexes.)
-- NULLS NOT DISTINCT IS A NO-OP HERE AND IS KEPT DELIBERATELY. It was
-- load-bearing while `org_id is null` meant the shared tier: without it this
-- index constrained every tenant except the shared one. org_id is NOT NULL now
-- (identity/spec.md §4, rbac.adopt_shared_org), so there are no NULLs for the
-- flag to rule on. Left in place rather than dropped because removing it means
-- rebuilding a unique index on every deployment to change nothing -- and
-- written down rather than left silent, because a reader who finds the flag
-- with no note has to derive for themselves whether it still matters. It does
-- not, unless somebody makes org_id nullable again.
create unique index if not exists idx_soft_nodes_key
    on aiq.soft_nodes (org_id, claimed_kind, key) nulls not distinct;
create index if not exists idx_soft_nodes_unresolved
    on aiq.soft_nodes (claimed_kind, key) where resolved_node_id is null;

-- 3b. Lake references: the entity's row is in Parquet, not in Postgres.
--
-- IDENTITY IS ALWAYS IN POSTGRES. PAYLOAD NEED NOT BE. aiq.nodes never stored
-- payload -- it stores entity_type + entity_id and lookup hydrates against the
-- owning table's key -- so nothing in graph-identity.md requires that owning
-- thing to be a Postgres table. A dataset row is hydrated by a different fetch
-- (DuckDB over content.dataset_uri) and is otherwise an ordinary vertex.
create table if not exists aiq.lake_nodes (
    id            uuid primary key default uuidv7(),
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
-- NULLS NOT DISTINCT: a no-op on a NOT NULL column, kept for the reason
-- idx_soft_nodes_key above states in full.
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
    -- The canonical key keeps its `company/acme corp` shape: the prefix is
    -- the claimed kind, and it is the only place the kind survives into
    -- node_keys -- which is why a consumer that needs it has been doing
    -- string surgery on the key instead of joining the column.
    p_key_expr      => 'n.claimed_kind || ''/'' || n.key',
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
-- the one underneath it. `org_id = rbac.shared_org_id()` is the shared
-- reference tier, which integration-rbac.sql calls "a real category here, not
-- a loophole."
create or replace function aiq.resolve_ref(
    p_entity_type text, p_name text, p_fuzzy boolean default false,
    p_threshold real default 0.45, p_org_id uuid default null
) returns uuid as $$
declare
    v_norm text := lower(trim(p_name));
    v_ids  uuid[];
begin
    -- 1. exact canonical, scoped to the type AND the caller's tenancy.
    --
    -- `n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id))` is
    -- what `(org_id is null or org_id is not distinct from p_org_id)` used to
    -- say: the shared tier, plus the caller's own org. It is now an ordinary
    -- IN over a NOT NULL column -- no three-valued logic, no `is not distinct
    -- from` to read twice -- and when p_org_id is itself omitted the two
    -- elements collapse to the same value and the predicate is the shared tier
    -- alone, which is exactly what an unscoped call should resolve against.
    select array_agg(distinct n.id) into v_ids
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind = 'canonical' and n.entity_type = p_entity_type
      and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id));
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;  -- ambiguous: a miss

    -- 2. short / alias.
    select array_agg(distinct n.id) into v_ids
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where k.key = v_norm and k.kind in ('short','alias') and n.entity_type = p_entity_type
      and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id));
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;

    -- 3. fuzzy, opt-in, and only over node_keys -- never the data plane.
    if p_fuzzy then
        select array_agg(id) into v_ids from (
            select n.id, max(similarity(k.key, v_norm)) as sim
            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
            where n.entity_type = p_entity_type and k.key % v_norm
              and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id))
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
    -- COALESCED AT THE BOUNDARY, once, rather than at the four sites that
    -- write it. p_context is caller-supplied jsonb: a context with no `org_id`
    -- key means the extraction was not on any tenant's behalf, which is the
    -- shared tier -- and aiq.nodes/soft_nodes/lake_nodes/edges.org_id is NOT
    -- NULL (identity/spec.md §4). This is the seam where an ABSENCE (a key
    -- nobody set) legitimately becomes a VALUE (the shared org), and it is a
    -- single line precisely so that it is one decision rather than four.
    v_org     uuid   := rbac.org_or_shared((p_context->>'org_id')::uuid);
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
    v_fwd text;                 -- the forward relation an inverse resolves to
    v_swap int;
    v_unknown text[] := '{}';   -- relations the model invented, for the receipt
    v_flipped int := 0;
    v_revived int := 0;         -- retracted edges a fresh assertion brought back
    v_retracted bigint;
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
            -- visibility set explicitly, because this function is SECURITY
            -- DEFINER and runs for a WORKER extracting on some tenant's
            -- behalf: the column default (`private`) with a null owner writes
            -- a reference row nobody -- not the tenant, not the worker's next
            -- pass -- can read. rbac.default_visibility() gives it the org's
            -- scope when the extraction named one and `public` when this is
            -- shared reference data, which is the same rule everything else
            -- in the collection uses.
            insert into aiq.lake_nodes (dataset, row_key, label, attrs, org_id, visibility)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org,
                    rbac.default_visibility(v_org))
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
            -- visibility set explicitly, because this function is SECURITY
            -- DEFINER and runs for a WORKER extracting on some tenant's
            -- behalf: the column default (`private`) with a null owner writes
            -- a reference row nobody -- not the tenant, not the worker's next
            -- pass -- can read. rbac.default_visibility() gives it the org's
            -- scope when the extraction named one and `public` when this is
            -- shared reference data, which is the same rule everything else
            -- in the collection uses.
            insert into aiq.soft_nodes (claimed_kind, key, label, attrs, org_id, visibility)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org,
                    rbac.default_visibility(v_org))
            on conflict (org_id, claimed_kind, key) do update
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
        -- AN UNLISTED RELATION IS DROPPED AND COUNTED, not raised. The closed
        -- vocabulary is right and is not in question here -- an extractor that
        -- can emit anything cannot be checked, costed, or swapped for a cheaper
        -- one. What was wrong was the BLAST RADIUS: raising aborts the
        -- transaction, so one invented relation discarded every node and every
        -- valid edge the document produced. Measured on a four-node, five-edge
        -- payload with one bad edge: 4 nodes and 4 good edges lost.
        --
        -- This file already makes the opposite choice one screen down, for the
        -- same species of thing -- "a self-edge is a model artefact, not a
        -- wiring bug, so it is dropped, but COUNTED IN THE RECEIPT, never
        -- silently, which is how this collection has previously reported
        -- success while losing data". A relation the model invented is a model
        -- artefact by the same reading. An out-of-range ORDINAL still raises,
        -- and the comment above says why: that one is a wiring bug.
        --
        -- FIRST, THOUGH, TRY THE INVERSE. On 159 real documents 8 of 1,041
        -- edges were refused this way and all eight were `owned_by` or `owned`
        -- -- the model reaching for the inverse of `owns`, which the catalogue
        -- can express and the extractor's enum cannot offer. If the name is
        -- some relation's inverse_label, the edge is not wrong, it is written
        -- backwards: swap the endpoints and store the forward form, which is
        -- the one orientation this design stores precisely so a reader can ask
        -- either way. Vocabulary membership is checked FIRST, so a term that is
        -- also some other term's inverse stays forward.
        if not exists (select 1 from aiq.graph_vocabulary where relation = v_rel) then
            -- Joined to the vocabulary rather than merely existing in the
            -- catalogue: the flip may only land a relation the extractor was
            -- allowed to emit in the first place, or an invented name could
            -- reach an authored-only term through its inverse and the closed
            -- vocabulary would have a side door.
            select rt.relation into v_fwd
              from aiq.relation_types rt
              join aiq.graph_vocabulary gv on gv.relation = rt.relation
             where rt.inverse_label = v_rel
             limit 1;
            if v_fwd is not null then
                v_rel := v_fwd;
                v_swap := v_s; v_s := v_t; v_t := v_swap;
                v_flipped := v_flipped + 1;
            else
                -- Named, not merely counted: "3 edges dropped" sends a reader
                -- to the extractor with nothing to look for, and the whole
                -- point of a closed vocabulary is that the gap between what a
                -- model says and what the schema admits is a thing you act on.
                if not (v_rel = any(v_unknown)) then
                    v_unknown := v_unknown || v_rel;
                end if;
                continue;
            end if;
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

        select count(*), count(*) filter (where valid_to is not null)
          into v_before, v_retracted
          from aiq.edges
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
                weight = greatest(aiq.edges.weight, excluded.weight),
                -- A FRESH ASSERTION REVIVES A RETRACTED EDGE, and without this
                -- line it silently does not. `valid_to` became load-bearing in
                -- 0.2.0 -- the graph forgets on purpose rather than by DELETE --
                -- but edge identity is still `(src, dst, relation)` with no time
                -- in it, so a retracted edge and its re-assertion are the same
                -- row. This branch is that row's only writer, and it used to
                -- touch provenance and weight alone: the second document's
                -- source was appended, the weight was raised, `edges_merged`
                -- counted it, the receipt said success -- and `valid_to` stayed
                -- set, so `aiq.edges_current` never showed the edge again. The
                -- source came back and the graph did not, with nothing raised
                -- and nothing to see in the return value. Measured on 0.2.0
                -- before this line existed.
                --
                -- WHAT THIS DOES NOT FIX, stated because the receipt now names
                -- a revival and a reader will ask where the gap went. One row
                -- per triple can hold one interval, so an edge asserted, then
                -- retracted, then re-asserted comes back as `valid_from` at the
                -- FIRST assertion and `valid_to` null -- which reads as
                -- continuously believed, and it was not. The gap survives in
                -- `provenance.sources`, whose entries are individually dated,
                -- and that is the audit trail until edge identity carries a
                -- period. Making it carry one changes what an edge IS for every
                -- reader in aiq -- graph_snapshot, the compiled traversals, and
                -- every consumer relying on `unique (src_id, dst_id, relation)`
                -- to keep one channel to one row -- so it is a version's worth
                -- of work, not a line, and it is not smuggled in under a bug fix.
                valid_to = null;

        if v_before > 0 then
            v_merged := v_merged + 1;
            if v_retracted > 0 then v_revived := v_revived + 1; end if;
        else
            v_edges_written := v_edges_written + 1;
        end if;
    end loop;

    -- A receipt (outputs.md §2): counts and what was written, never the rows.
    --
    -- `residence` was a jsonb of three totals while v_res -- commented "ordinal
    -- -> residence, for the receipt" and appended in all three residence
    -- branches -- was never returned by anything. A consumer that wants to know
    -- WHICH node landed soft had to re-derive it by querying back the ids. Both
    -- are here now: the totals because they are what a workflow logs, and the
    -- per-ordinal array because it is what a caller actually asks next, and it
    -- lines up with node_ids index for index.
    return jsonb_build_object(
        'nodes', v_n,
        'residence', v_counts,
        'node_residence', to_jsonb(v_res),
        'edges_new', v_edges_written,
        'edges_merged', v_merged,
        'self_edges_dropped', v_self,
        -- Beside self_edges_dropped, in the same place, for the same reason:
        -- an edge the schema refused is a fact about the extractor, and a
        -- receipt that omitted it would be reporting success while losing data.
        'edges_flipped_to_inverse', v_flipped,
        -- Reported for the same reason as the two above: a revival is a real
        -- change of belief, and a caller that retracts on a schedule needs to
        -- see its retractions being undone rather than infer it from a count
        -- of edges that stopped falling.
        'edges_revived', v_revived,
        'edges_dropped_unknown_relation', to_jsonb(v_unknown),
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
    v_run uuid; v_child record;
    v_missing int; v_total int;
    v_acc jsonb := jsonb_build_object('graphs',0,'edges_new',0,'edges_merged',0,
                                      'self_edges_dropped',0,'edges_flipped_to_inverse',0,
                                      'edges_revived',0,
                                      'edges_dropped_unknown_relation','[]'::jsonb);
    v_r jsonb;
begin
    -- Raises unless this task belongs to the run being executed: a registered
    -- step function handed an arbitrary task id would otherwise be a read of
    -- someone else's run. One body, in workflow-engine/schema.sql §20c.
    v_run := workflow.assert_task_in_current_run(p_matrix_task);

    select count(*) into v_total from workflow.tasks where matrix_parent_id = p_matrix_task;
    -- A child that succeeded and left no `result` was offloaded as an artifact.
    -- Raised rather than skipped: a document silently absent from the index is
    -- a hole in a graph that still answers questions.
    select count(*) into v_missing from workflow.tasks
     where matrix_parent_id = p_matrix_task and status = 'succeeded'
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
        where t.matrix_parent_id = p_matrix_task and t.status = 'succeeded'
    loop
        v_r := aiq.upsert_graph(v_child.graph, jsonb_build_object(
            'resource_id', v_child.rid, 'run_id', v_run,
            'window', v_child.win, 'agent', 'structure_null'));
        -- The dropped relations are UNIONED rather than summed: the useful
        -- fact across a fan-in is which names the model kept inventing, and a
        -- count of 40 says nothing a reader can act on.
        v_acc := jsonb_build_object(
            'graphs',             (v_acc->>'graphs')::int + 1,
            'edges_new',          (v_acc->>'edges_new')::int + (v_r->>'edges_new')::int,
            'edges_merged',       (v_acc->>'edges_merged')::int + (v_r->>'edges_merged')::int,
            'self_edges_dropped', (v_acc->>'self_edges_dropped')::int + (v_r->>'self_edges_dropped')::int,
            'edges_flipped_to_inverse',
                (v_acc->>'edges_flipped_to_inverse')::int + (v_r->>'edges_flipped_to_inverse')::int,
            'edges_revived',      (v_acc->>'edges_revived')::int + (v_r->>'edges_revived')::int,
            'edges_dropped_unknown_relation', (
                select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                  from jsonb_array_elements(
                        (v_acc->'edges_dropped_unknown_relation')
                        || (v_r->'edges_dropped_unknown_relation')) x));
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
    -- DELETED, not retracted, and the distinction matters now that
    -- `ai-query-layer/schema.sql` makes retraction the contract for removal.
    -- A merge is the one legitimate reason to delete an edge: the fact is not
    -- ceasing to hold, it is moving to the node that now carries the identity,
    -- and the surviving edge on the target keeps the merged provenance. A
    -- retracted duplicate would assert that the relationship stopped being
    -- true, which is exactly what did not happen.
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

-- AND THE POLICIES THAT MAKE THAT GRANT SAFE, which it was written without.
--
-- The sentence above -- "the read helpers are SECURITY INVOKER, so a user
-- calling them is filtered by their own policies" -- is true of the three
-- functions and was never true of the table grant appended under it. Neither
-- reference table had a policy, so there was nothing to be filtered by:
--
--   org B, through aiq.nodes         -> 1 row   (its own)
--   org B, from aiq.soft_nodes       -> 2 rows  (both, with key, label, attrs)
--
-- Measured. The projection beside it is what proves the intent: both tables are
-- registered with `p_org_expr => 'n.org_id'` precisely so the node they become
-- is scoped, and reading the staging table went round it. These carry extracted
-- entity NAMES before resolution, which is the most identifying thing in the
-- pipeline.
--
-- Same predicate as aiq.nodes' own policy, and the same reason for the shared
-- branch: `org_id = rbac.shared_org_id()` is shared reference data, which §4.4
-- says is the normal state. `graph_vocabulary` stays policy-free deliberately -- it is the
-- relation catalogue, the same shared-config tier as aiq.relation_types.
--
-- Nothing on the write path changes: the worker reaches these through
-- SECURITY DEFINER functions owned by app_owner, and an owner is not subject
-- to its own policies (rbac/02 §3 asserts that is still true).
select rbac.add_scope_columns('aiq.soft_nodes', 'public');
select rbac.add_scope_policy ('aiq.soft_nodes');
select rbac.add_scope_columns('aiq.lake_nodes', 'public');
select rbac.add_scope_policy ('aiq.lake_nodes');

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
--
-- `affiliated_with` IS SYMMETRIC, and is the first shipped relation to say so.
-- "connected, unspecified" has no direction to lose -- a is affiliated with b
-- exactly when b is affiliated with a -- and storing both rows would give the
-- pair twice its share of the mass in a ranked walk and a degree of two in
-- k-core. aiq.relation_types has carried the mechanism from the start and
-- nothing could reach it, so until now the catalogue declared no symmetric
-- relation at all, here or in any consumer's.
--
-- THE INVERSES are declared because a model reaching for one is the single
-- largest source of dropped edges: on a 159-document extraction, 8 of 1,041
-- edges were refused and all eight were `owned_by` or `owned`. aiq.upsert_graph
-- now flips an edge naming a relation's inverse instead of refusing it, and
-- these are the labels it flips on. They also repair the read path, which was
-- reporting an in-edge of `owns` as `owns_by` -- graph_neighbors falls back to
-- `relation || '_by'` when there is no label, and there was never a label.
--
-- `part_of` deliberately gets none: its natural inverse is `contains`, which is
-- a relation in its own right one line down, and a label that is also a term
-- would make the flip below ambiguous with the forward edge.
--
-- Comments live out here rather than beside the entries because everything
-- between the dollar quotes is a JSON literal, where `--` is two characters of
-- invalid JSON rather than a comment.
-- ------------------------------------------------------------
select aiq.register_graph_vocabulary($v$[
  {"relation":"is_a",            "machine_weight":0.6,  "description":"classification (extraction.md motif)"},
  {"relation":"part_of",         "machine_weight":0.6,  "description":"composition, ownership (motif)"},
  {"relation":"succession",      "machine_weight":0.5,  "description":"replacement over time (motif)"},
  {"relation":"causal",          "machine_weight":0.25, "description":"deliberately low-confidence (motif)"},
  {"relation":"mentions",        "machine_weight":0.4,  "description":"co-occurrence; the weakest useful edge",
                                 "inverse_label":"mentioned_in"},
  {"relation":"located_in",      "machine_weight":0.6,  "description":"physical or jurisdictional containment"},
  {"relation":"affiliated_with", "machine_weight":0.5,  "description":"connected, unspecified",
                                 "is_symmetric":true},
  {"relation":"owns",            "machine_weight":0.6,  "description":"ownership or control",
                                 "inverse_label":"owned_by"},
  {"relation":"supplies",        "machine_weight":0.6,  "description":"provides goods or services to",
                                 "inverse_label":"supplied_by"},
  {"relation":"party_to",        "machine_weight":0.7,  "description":"a named party of an agreement"},
  {"relation":"binds",           "machine_weight":0.7,  "description":"a clause imposing an obligation on a party"},
  {"relation":"contains",        "machine_weight":0.8,  "description":"a document containing a part of itself"}
]$v$::jsonb);
