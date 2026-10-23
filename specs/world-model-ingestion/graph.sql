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
    'The relation names an extractor may emit, and how much weight a machine-made one starts with.';

-- SINGLE-VALUED: a subject holds one current value of this relation at a time,
-- so a later edge for the same subject supersedes an earlier one (REM-961).
-- `lives_in`, `works_at`, `manager_is` are; `prefers` is not, because a person
-- prefers many things and which preference replaced which is a judgement. It is
-- a property of the TERM, so it lives here and not per triple in
-- aiq.relation_types.
--
-- NULLABLE for the reason relation_types.is_symmetric is: null is UNDECLARED and
-- reads as false, so a writer that said nothing and a writer that said false
-- stay distinguishable. aiq.dream() acts only on relations declared true.
-- Measured on our mem0 baseline's fixture: the four relations that
-- hold one value recover 7 of its 11 supersessions with no false one; treating
-- every relation as single-valued recovers 8 and invents 22.
alter table aiq.graph_vocabulary add column if not exists single_valued boolean;
comment on column aiq.graph_vocabulary.single_valued is
    'true: a subject holds one current value at a time, and aiq.dream() supersedes the older edge. null: undeclared, read as false.';

-- SHIPPED BY THE EXTENSION, OR ADDED BY THIS DEPLOYMENT. aiq.graph_vocabulary holds
-- both, and a backup must carry the second kind only -- see the HEADER's
-- `percolate.seeding` note and specs/contract/schema.sql section 4.
--
-- TWO STATEMENTS, AND THE SECOND IS THE ONE THAT REACHES AN UPGRADE. The
-- column is added `default false` so that rows which already exist on an
-- upgraded database are treated as the deployment's -- the safe direction,
-- since the cost of a wrong `false` is a loud duplicate key and the cost of a
-- wrong `true` is a row silently absent from every future backup. The default
-- is THEN repointed at the seeding flag, for rows inserted after this line.
-- Putting the flag-reading default on the `add column` instead would evaluate
-- it once, during the upgrade, with seeding on -- marking every deployment row
-- as shipped. Measured shape, not a worry: the same one-statement-short trap
-- cost REM-109 half a day on `queue_config`.
alter table aiq.graph_vocabulary add column if not exists shipped boolean not null default false;
alter table aiq.graph_vocabulary alter column shipped set default
    (coalesce(current_setting('percolate.seeding', true), 'off') = 'on');

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
        -- Was `do nothing`. It still changes nothing a caller can see: the
        -- only assignment is the backup flag, and the UPDATE below is what
        -- applies the payload. What it buys is the replay -- an upgraded
        -- database marks the relations the extension ships without a list of
        -- their names living anywhere.
        on conflict (relation) do update
           set shipped = excluded.shipped or graph_vocabulary.shipped;

        update aiq.graph_vocabulary g
           set machine_weight = coalesce((e->>'machine_weight')::real, g.machine_weight),
               description    = coalesce(e->>'description',            g.description),
               single_valued  = coalesce((e->>'single_valued')::boolean, g.single_valued)
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
comment on table aiq.soft_nodes is
    'A thing an extractor named but could not resolve, held until it resolves to a real node or is discarded.';

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
--
-- AND IT IS LOAD-BEARING AGAIN: §10 re-creates this index with owner_scope,
-- which is NULL for every candidate that is not private (REM-962). This first
-- shape is what a fresh install has until §10 adds the column it needs; on an
-- existing database the name is already taken and this line does nothing.
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
comment on table aiq.lake_nodes is
    'A row from the lake given a graph identity, so a DuckDB result can be walked with everything else.';
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
    p_include_where => 'n.resolved_node_id is null',
    -- The candidate's own scope, which upsert_graph takes from the memory it
    -- was read out of (REM-962). The default reads the org alone, and on the
    -- shared tier that is `public` for a private memory's names.
    -- Read through to_jsonb, as the projection reads owner_id, because the
    -- column arrives with add_scope_columns() further down and that call writes
    -- to the table first: the trigger this regenerates fires on that write,
    -- with the column not there yet. Until it is, the old rule.
    p_visibility_expr => $$coalesce(to_jsonb(n)->>'visibility',
                                 case when rbac.is_shared_org(n.org_id) then 'public' else 'org' end)$$);

select aiq.register_entity_table(
    p_entity_type   => 'lake',
    p_source_table  => 'aiq.lake_nodes',
    p_key_expr      => 'n.dataset || ''/'' || n.row_key',
    p_summary_expr  => 'coalesce(n.label, n.row_key)',
    p_org_expr      => 'n.org_id',
    -- Read through to_jsonb, as the projection reads owner_id, because the
    -- column arrives with add_scope_columns() further down and that call writes
    -- to the table first: the trigger this regenerates fires on that write,
    -- with the column not there yet. Until it is, the old rule.
    p_visibility_expr => $$coalesce(to_jsonb(n)->>'visibility',
                                 case when rbac.is_shared_org(n.org_id) then 'public' else 'org' end)$$);
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
              -- THE KINDS ARE LISTED, AND NO PREFIX IS SUGGESTED (REM-1066). The
              -- description used to read "kind; optionally pg:/lake:/soft:
              -- prefixed" and the prompt said "use a k from the kinds listed"
              -- with none listed, so gpt-4o answered `pg:/port` about one run
              -- in seven -- the description's own punctuation -- and the lander
              -- kept `/port`, which matched no table. A residence scheme is for
              -- a typed extractor with its own schema; this one names kinds.
              'k', jsonb_build_object('type','string',
                   'description', 'kind: a lowercase singular noun'
                     || coalesce(' -- one of ' || (select string_agg(entity_type, ', ' order by entity_type)
                                                   from aiq.entity_registry
                                                  where entity_type not in ('soft', 'lake'))
                                 || ' when it fits, otherwise your own', '')),
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
-- A PRIVATE NODE BINDS ONLY ITS OWNER'S PRIVATE MENTION (REM-976). With per-owner
-- private nodes (REM-962), a key on one tier can name Maya's private node and a
-- public one. This matched across every scope on the tier, so a private mention
-- could bind to a node its owner cannot read, and the owner lost sight of their
-- own fact. p_visibility and p_owner are the MENTION's scope, which upsert_graph
-- reads off the memory; omitted, they mean the caller's own. Of the nodes the
-- mention may bind, the nearest scope wins: its owner's, then the org's, then
-- public. Two at that scope are still a miss.
drop function if exists aiq.resolve_ref(text, text, boolean, real, uuid);
create or replace function aiq.resolve_ref(
    p_entity_type text, p_name text, p_fuzzy boolean default false,
    p_threshold real default 0.45, p_org_id uuid default null,
    p_visibility text default 'private', p_owner uuid default null
) returns uuid as $$
declare
    v_norm  text := lower(trim(p_name));
    v_owner uuid := case when p_visibility = 'private' then coalesce(p_owner, rbac.current_user_id()) end;
    v_ids   uuid[];
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
    with m as (
        select distinct n.id, case n.visibility when 'private' then 0 when 'org' then 1 else 2 end as r
        from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
        where k.key = v_norm and k.kind = 'canonical' and n.entity_type = p_entity_type
          and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id))
          and (n.visibility <> 'private' or n.owner_id = v_owner))
    select array_agg(m.id) into v_ids from m where m.r = (select min(r) from m);
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;  -- ambiguous: a miss

    -- 2. short / alias.
    with m as (
        select distinct n.id, case n.visibility when 'private' then 0 when 'org' then 1 else 2 end as r
        from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
        where k.key = v_norm and k.kind in ('short','alias') and n.entity_type = p_entity_type
          and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id))
          and (n.visibility <> 'private' or n.owner_id = v_owner))
    select array_agg(m.id) into v_ids from m where m.r = (select min(r) from m);
    if array_length(v_ids,1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids,1) > 1 then return null; end if;

    -- 3. fuzzy, opt-in, and only over node_keys -- never the data plane.
    if p_fuzzy then
        select array_agg(id) into v_ids from (
            select n.id, max(similarity(k.key, v_norm)) as sim
            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
            where n.entity_type = p_entity_type and k.key % v_norm
              and n.org_id in (rbac.shared_org_id(), rbac.org_or_shared(p_org_id))
              and (n.visibility <> 'private' or n.owner_id = v_owner)
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
    -- WHEN THE FACTS BEGAN, if the writer knows (REM-963). A memory loaded
    -- today about something said in January holds from January; without this
    -- every edge held from the moment of the write. Checked in the body.
    v_valid_from timestamptz;
    -- What a second assertion from the same source looks like in an edge's
    -- sources list, so a re-run appends nothing. Null: always append.
    v_dedup jsonb;
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
    v_novel_kinds text[] := '{}';  -- claimed kinds no catalogue knows, for the receipt
    v_lock record;              -- the canonical lock order, see the loop below
    -- THE SCOPE A NEW CANDIDATE IS WRITTEN AT, taken from the resource the
    -- facts were read out of whenever the context names one (REM-962). See
    -- the block after Validate.
    v_vis     text;
    v_owner   uuid;
    v_res_org uuid;
    v_ownerless boolean := false;  -- private, no source, no user: see REM-1012
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

    if nullif(p_context->>'valid_from', '') is not null then
        if not pg_input_is_valid(p_context->>'valid_from', 'timestamptz') then
            raise exception 'aiq.upsert_graph: valid_from % is not a time (agent %)',
                p_context->>'valid_from', coalesce(p_context->>'agent','?');
        end if;
        v_valid_from := (p_context->>'valid_from')::timestamptz;
        if v_valid_from > now() then
            raise exception 'aiq.upsert_graph: valid_from % is in the future; a fact is written '
                'once it holds (agent %)', v_valid_from, coalesce(p_context->>'agent','?');
        end if;
    end if;

    -- ---- A FACT IS NO MORE VISIBLE THAN THE MEMORY IT CAME FROM (REM-962).
    --
    -- The scope of what this writes used to come from the CONTEXT, and the
    -- context is whatever the worker remembered to pass. A context with no
    -- org_id is the shared tier, and on the shared tier a worker -- which has
    -- no request identity, so rbac.default_visibility() reads it as an
    -- operator -- wrote `public`. Measured on 0.2.23: Maya registers "Maya is
    -- allergic to peanuts" with no org, the resource is private and Leo reads
    -- none of it, and the worker's upsert_graph naming only that resource_id
    -- gave Leo `Maya O. -allergic_to-> peanuts` from aiq.edges. Inside an org
    -- the same shape gave every member a fact from one member's PRIVATE
    -- resource, because naming an org meant `org`.
    --
    -- So when the context names a resource, the RESOURCE says: its org (a
    -- context that disagrees is refused rather than believed), its visibility
    -- and its owner become the new candidate's. Without one, nothing changes:
    -- an extraction with no source is reference data or a run's own output,
    -- and keeps rbac.default_visibility()'s rule. Read here, as the definer,
    -- because a worker may not read a private resource and must still scope
    -- what it extracted from one.
    --
    -- This scopes the NODES. The FACTS are gated at read time by the edge
    -- policy (§10a), through every source an edge carries -- which is what an
    -- edge merged from two memories needs, and what scoping at write time
    -- cannot give it.
    if nullif(p_context->>'resource_id', '') is not null
       and nullif(p_context->>'session_id', '') is not null then
        raise exception 'a context names a resource or a session, not both (agent: %)',
            coalesce(p_context->>'agent','?');
    end if;

    if nullif(p_context->>'resource_id', '') is not null then
        if not pg_input_is_valid(p_context->>'resource_id', 'uuid') then
            raise exception 'context resource_id % is not a uuid (agent: %)',
                p_context->>'resource_id', coalesce(p_context->>'agent','?');
        end if;
        select r.org_id, r.visibility, r.owner_id into v_res_org, v_vis, v_owner
          from content.resources r where r.id = (p_context->>'resource_id')::uuid;
        if not found then
            raise exception 'context resource_id % names no resource, so the scope of what it '
                'yielded cannot be known (agent: %)',
                p_context->>'resource_id', coalesce(p_context->>'agent','?');
        end if;
        if nullif(p_context->>'org_id', '') is not null
           and rbac.org_or_shared(v_res_org) is distinct from v_org then
            raise exception 'context org_id % is not the org of resource % (%)',
                p_context->>'org_id', p_context->>'resource_id', rbac.org_or_shared(v_res_org)
                using hint = 'pass the resource alone; its org is read from it';
        end if;
        v_org := rbac.org_or_shared(v_res_org);
        -- A SOURCE IS A READING: the resource, the agent and the run (REM-1058).
        -- Keyed by the resource alone, a second reader of one document matched
        -- the first reader's entry and was dropped, so withdrawing the first
        -- ended a fact the second still supported. A re-run by the same agent in
        -- the same run still appends nothing.
        v_dedup := jsonb_strip_nulls(jsonb_build_object('resource_id', p_context->>'resource_id',
                                                        'agent', p_context->>'agent',
                                                        'run_id', p_context->>'run_id'));
    -- A CONVERSATION IS A MEMORY TOO (REM-969). What a session's messages
    -- state is scoped by the SESSION, exactly as a resource scopes what was
    -- read out of it: its org, visibility and owner. Without this a fact from
    -- a private conversation had no source to gate it and went to whoever
    -- could read both of its ends -- REM-962 again, by another door.
    elsif nullif(p_context->>'session_id', '') is not null then
        if not pg_input_is_valid(p_context->>'session_id', 'uuid') then
            raise exception 'context session_id % is not a uuid (agent: %)',
                p_context->>'session_id', coalesce(p_context->>'agent','?');
        end if;
        select se.org_id, se.visibility, se.owner_id into v_res_org, v_vis, v_owner
          from agentic.sessions se where se.id = (p_context->>'session_id')::uuid;
        if not found then
            raise exception 'context session_id % names no session, so the scope of what it '
                'yielded cannot be known (agent: %)',
                p_context->>'session_id', coalesce(p_context->>'agent','?');
        end if;
        if nullif(p_context->>'org_id', '') is not null
           and rbac.org_or_shared(v_res_org) is distinct from v_org then
            raise exception 'context org_id % is not the org of session % (%)',
                p_context->>'org_id', p_context->>'session_id', rbac.org_or_shared(v_res_org)
                using hint = 'pass the session alone; its org is read from it';
        end if;
        v_org := rbac.org_or_shared(v_res_org);
        v_dedup := jsonb_strip_nulls(jsonb_build_object('session_id', p_context->>'session_id',
                                                        'agent', p_context->>'agent',
                                                        'run_id', p_context->>'run_id',
                                                        'message_ids', p_context->'message_ids'));
    else
        v_vis := rbac.default_visibility(v_org);
        -- A PRIVATE CANDIDATE WITH NO SOURCE IS ITS WRITER'S (REM-1012).
        -- default_visibility says `private` for a caller with an identity and
        -- no org, and nothing here set the owner, so the node was private to
        -- nobody: measured on 0.2.23, knit signed in as one user left six
        -- soft nodes owner-null, and that user read 0 edges and 0 facts to
        -- embed. A caller whose claims name no user still writes edges
        -- between rows that exist (content/07); only a new candidate needs an
        -- owner, so the refusal is at the two inserts below.
        if v_vis = 'private' then
            v_owner := rbac.current_user_id();
            v_ownerless := v_owner is null;
        end if;
    end if;

    -- ---- LOCK IN A CANONICAL ORDER FIRST, or concurrent workers deadlock.
    --
    -- MEASURED, not anticipated: eight workers landing 1,200 documents over 274
    -- entities produced `deadlock detected ... while inserting index tuple in
    -- relation "soft_nodes"`, with both processes inside land_graph. The loop
    -- below upserts one soft node per ordinal, in the order the extractor
    -- happened to list them, and `on conflict (org_id, claimed_kind, key)` takes
    -- a lock on that index entry. Two documents naming Meridian and Halcyon in
    -- opposite orders therefore take the same two locks in opposite orders,
    -- which is a cycle, and Postgres kills one of them.
    --
    -- That is the exact concurrency this system recommends -- a KEDA-scaled
    -- pool of workers claiming extraction tasks -- so the failure is not an
    -- exotic one. It also gets MORE likely as a corpus gets denser, because the
    -- cycle needs two documents sharing two entities.
    --
    -- The fix is to make every transaction take these locks in the same order,
    -- and the order has to come from the DATA rather than from the payload.
    -- Advisory locks keyed on the node key, acquired sorted, do that in six
    -- lines and -- crucially -- WITHOUT REORDERING v_nodes, which the next
    -- comment explains is not allowed to happen.
    --
    -- Advisory rather than row locks because the rows may not exist yet: the
    -- deadlock is between two INSERTs, and there is nothing to lock until one
    -- of them wins. `pg_advisory_xact_lock` releases at commit or rollback with
    -- no unlock path to forget. A hash collision between two unrelated keys
    -- costs a little false serialisation and nothing else, which is the right
    -- direction for this trade.
    --
    -- An explicit loop, not `perform ... from (select ... order by)`: SQL does
    -- not promise to evaluate a function in a SELECT list in sort order, and a
    -- lock ordering that holds only by planner accident is not one.
    for v_lock in
        select distinct lower(trim(coalesce(n->>'k',''))) || '/'
                     || lower(trim(coalesce(n->>'n','')))  as k
          from jsonb_array_elements(v_nodes) n
         where coalesce(n->>'k','') <> '' and coalesce(n->>'n','') <> ''
         order by 1
    loop
        perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended(v_lock.k, 0));
    end loop;

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
        -- A slash around the kind is punctuation, not part of it: a model that
        -- writes `pg:/port` or `/port` means `port` (REM-1066). Kept, it made
        -- the key `/port/felixstowe`, which no table and no reader could match.
        if strpos(v_k, ':') > 0 then
            v_scheme := split_part(v_k, ':', 1);
            v_kind   := btrim(split_part(v_k, ':', 2), '/ ');
            if v_scheme not in ('pg','lake','soft') then
                raise exception
                    'node ordinal % has residence scheme ''%'', which is not one of '
                    'pg/lake/soft. A kind containing '':'' is read as a scheme.', i, v_scheme;
            end if;
        else
            v_kind := btrim(v_k, '/ ');
        end if;
        if v_kind = '' then
            raise exception 'node ordinal % has no kind once its punctuation is removed: %', i, v_node->>'k';
        end if;
        v_key := lower(trim(v_name));
        v_id  := null;

        -- (a) pg: the kind names a registered entity type and the name
        --     resolves. The edge lands on the REAL typed vertex, and PGQ walks
        --     it as that type because aiq.nodes.entity_type already says so.
        if coalesce(v_scheme,'pg') = 'pg'
           and exists (select 1 from aiq.entity_registry where entity_type = v_kind) then
            v_id := aiq.resolve_ref(v_kind, v_name, v_fuzzy, 0.45, v_org, v_vis, v_owner);
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
            if v_ownerless then
                raise exception 'a graph with no resource or session is private to its writer, '
                    'and this caller names no user, so new candidate % would be readable by '
                    'nobody (agent: %)', v_name, coalesce(p_context->>'agent','?')
                    using hint = 'sign in, or name the resource or session the facts were read from';
            end if;
            insert into aiq.lake_nodes (dataset, row_key, label, attrs, org_id, visibility, owner_id)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org,
                    v_vis, v_owner)
            -- Per owner when private, as a soft candidate is: see below.
            on conflict (org_id, dataset, row_key, owner_scope) do update
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
            -- A CLAIMED KIND NOTHING KNOWS IS NAMED IN THE RECEIPT, for the
            -- same reason `edges_dropped_unknown_relation` is, and the
            -- asymmetry it closes was found by a consumer rather than here.
            --
            -- `upsert_graph` refuses an unknown RELATION and says why: an
            -- extractor that can emit anything cannot be checked, costed, or
            -- swapped for a cheaper one. That reasoning was applied to the edge
            -- label and not to the thing edges connect -- and `k` is half of
            -- node identity, because a soft node is keyed
            -- `(org_id, claimed_kind, key)`. So a model that says `company/amd`
            -- in one document and `organization/amd` in the next produces TWO
            -- nodes for one company, `nodes: 2` is a true receipt, and nothing
            -- anywhere says the kind moved.
            --
            -- Measured on percolate-coherence's 159-document corpus: 295
            -- distinct kinds emitted against a catalogue of six, and 60 names
            -- split across more than one kind -- entities halved by a model
            -- changing its mind about a word. Its identity pass then could not
            -- recover them, because a pass that pairs across kinds would be
            -- proposing that a person is a company.
            --
            -- NAMED, NOT REFUSED, and the difference is the whole point of the
            -- soft plane. An unknown relation is dropped because the closed
            -- vocabulary is what makes an edge checkable; an unknown KIND is a
            -- candidate doing exactly its job, and refusing it would throw away
            -- the claim this branch exists to record. What was missing was not
            -- a constraint, it was the sentence -- a consumer had no way to
            -- learn from the substrate that its extractor was drifting.
            if not exists (select 1 from aiq.relation_types where src_type = v_kind)
               and not (v_kind = any(v_novel_kinds)) then
                v_novel_kinds := v_novel_kinds || v_kind;
            end if;

            -- A THING NAMED IN A PRIVATE MEMORY IS ITS OWNER'S CANDIDATE, so
            -- identity is (org_id, claimed_kind, key, owner_scope) and
            -- owner_scope is the owner of a private candidate, NULL otherwise
            -- (§10). Maya's "Leeds" and Leo's "Leeds" are two nodes, each read
            -- by its own owner; an org or public mention is one node for its
            -- scope, as before. One node shared by all of them was measured on
            -- jack's 48-fact fixture: whoever named a thing first owned it, and
            -- Leo read 3 of his own 8 facts. Joining the two Leeds is
            -- resolution's decision, made where it can be seen, not a side
            -- effect of who wrote first.
            if v_ownerless then
                raise exception 'a graph with no resource or session is private to its writer, '
                    'and this caller names no user, so new candidate % would be readable by '
                    'nobody (agent: %)', v_name, coalesce(p_context->>'agent','?')
                    using hint = 'sign in, or name the resource or session the facts were read from';
            end if;
            insert into aiq.soft_nodes (claimed_kind, key, label, attrs, org_id, visibility, owner_id)
            values (v_kind, v_key, v_name, coalesce(v_node->'a','{}'::jsonb), v_org,
                    v_vis, v_owner)
            on conflict (org_id, claimed_kind, key, owner_scope) do update
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
                'session_id',  p_context->>'session_id',
                'message_ids', p_context->'message_ids',
                'agent',       p_context->>'agent',
                'run_id',      p_context->>'run_id',
                'window',      p_context->'window',
                'valid_from',  to_char(v_valid_from,'YYYY-MM-DD"T"HH24:MI:SSOF'),
                'attrs',       nullif(v_e->'a','{}'::jsonb),
                'at',          to_char(now(),'YYYY-MM-DD"T"HH24:MI:SSOF')))));

        -- A REVIVAL is an edge that was NOT CURRENT when this upsert arrived,
        -- through aiq.edge_is_current rather than a fifth spelling of it. Note
        -- that this counts an edge retracted earlier in this same transaction,
        -- which trg_record_edge_retraction deliberately does not record as a
        -- hole: the receipt reports the state the upsert found, and the hole
        -- records a period during which nobody believed the edge. A derivation
        -- that retires and revives at one now() produces the first and not the
        -- second, and both readings are right for what they are for.
        select count(*),
               count(*) filter (where not aiq.edge_is_current(valid_from, valid_to, now()))
          into v_before, v_retracted
          from aiq.edges
         where src_id = v_ids[v_s+1] and dst_id = v_ids[v_t+1] and relation = v_rel;

        insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id, valid_from)
        values (v_ids[v_s+1], v_ids[v_t+1], v_rel, v_w, v_prov, v_org, coalesce(v_valid_from, now()))
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
            -- `- 'closed'`: a fact aiq.close_edge ended and a source now
            -- asserts again holds again, and the hole between is recorded by
            -- trg_record_edge_retraction, not by a stale closing entry.
            set provenance = (aiq.edges.provenance - 'closed') || jsonb_build_object(
                    'sources',
                    coalesce(aiq.edges.provenance->'sources', '[]'::jsonb)
                    || (case when v_dedup is not null
                                  and coalesce(aiq.edges.provenance->'sources','[]'::jsonb) @>
                                      jsonb_build_array(v_dedup)
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
                valid_to = null,
                -- The earliest time any source says the fact held. A later
                -- source cannot move it forward, which would shorten a belief
                -- somebody else stated.
                valid_from = least(aiq.edges.valid_from, excluded.valid_from);

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
        -- Beside the dropped relations, because they are the same fact about
        -- an extractor seen from the two halves of the graph.
        'node_kinds_unregistered', to_jsonb(v_novel_kinds),
        'node_ids', to_jsonb(v_ids));
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 6b. Close one fact at a stated time (REM-963).
--
-- A superseding memory ends exactly the fact it replaces: "Maya lives in
-- Lisbon", said in June, closes the lives_in edge "Maya lives in Leeds"
-- asserted, at June, and touches nothing else. The only retraction there was,
-- aiq.retract_derived, withdraws everything one agent derived, so the Mem0
-- quickstart closed the edge with an operator UPDATE.
--
-- p_edge names ONE current edge, and anything else is refused, so a close
-- cannot spread:
--   {"edge_id": "<uuid>"}
--   {"resource_id": "<memory>", "relation": "lives_in"}  -- the fact that
--      memory asserted, which is what a superseding writer knows. The worker
--      cannot read aiq.edges, so it names an edge by what it wrote.
--
-- The edge keeps its provenance, and `closed` records who ended it, from which
-- memory and when; history (aiq.edge_periods) then reads as "held from
-- January to June, said in r01, ended in r07". A later source asserting the
-- fact again revives it, and upsert_graph drops the stale `closed`.
-- ------------------------------------------------------------
create or replace function aiq.close_edge(
    p_edge jsonb, p_valid_to timestamptz, p_context jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_ids uuid[];
    v_e   aiq.edges;
begin
    if p_valid_to is null then
        raise exception 'aiq.close_edge needs the time the fact stopped holding';
    end if;
    if p_valid_to > now() then
        raise exception 'aiq.close_edge: % is in the future; a fact is closed once it has ended', p_valid_to;
    end if;
    if not (p_edge ? 'edge_id' or (p_edge ? 'resource_id' and p_edge ? 'relation')) then
        raise exception 'aiq.close_edge names an edge by {"edge_id"} or by {"resource_id", "relation"}, got %', p_edge;
    end if;

    select array_agg(e.id) into v_ids
      from aiq.edges e
     where aiq.edge_is_current(e.valid_from, e.valid_to, now())
       and case when p_edge ? 'edge_id'
                then e.id = (p_edge->>'edge_id')::uuid
                else e.relation = p_edge->>'relation'
                     and e.provenance->'sources' @> jsonb_build_array(
                             jsonb_build_object('resource_id', p_edge->>'resource_id'))
           end;
    if coalesce(cardinality(v_ids), 0) <> 1 then
        raise exception 'aiq.close_edge: % names % current edges, and it closes exactly one',
            p_edge, coalesce(cardinality(v_ids), 0);
    end if;

    update aiq.edges e
       set valid_to = p_valid_to,
           provenance = e.provenance || jsonb_build_object('closed', jsonb_strip_nulls(jsonb_build_object(
               'resource_id', p_context->>'resource_id',
               'agent',       p_context->>'agent',
               'run_id',      p_context->>'run_id',
               'valid_to',    to_char(p_valid_to,'YYYY-MM-DD"T"HH24:MI:SSOF'),
               'at',          to_char(now(),'YYYY-MM-DD"T"HH24:MI:SSOF'))))
     where e.id = v_ids[1] and e.valid_from < p_valid_to
    returning * into v_e;
    if not found then
        raise exception 'aiq.close_edge: edge % began after %, so it cannot end then', v_ids[1], p_valid_to;
    end if;

    return jsonb_build_object('edge_id', v_e.id, 'relation', v_e.relation,
                              'valid_from', v_e.valid_from, 'valid_to', v_e.valid_to);
end;
$$;

-- ------------------------------------------------------------
-- A DELETED MEMORY TAKES THE FACTS IT ALONE SUPPORTED WITH IT (REM-964).
--
-- An owner deletes their resource; its chunks go by foreign key, their
-- vectors by trg_forget_vectors, its document node by the projection. The
-- graph was the one place it survived: every edge upsert_graph wrote names
-- the memory in provenance.sources, and nothing read that list on a delete,
-- so "Maya is vegetarian" stayed a current diet edge with the deleted
-- memory's id and quote on it.
--
-- graph-index.md §7's refcount, applied to a source that no longer exists:
-- the memory's entries leave every edge's sources, an edge somebody else
-- still asserts stays on their word, and an edge nobody else asserts is
-- DELETED rather than retracted. A retraction keeps its provenance, which
-- here is the deleted memory's own words. Its retraction history goes with
-- it by foreign key. An authored edge carries no sources and is untouched.
--
-- Statement-level with a transition table, so a bulk delete is one pass; and
-- SECURITY DEFINER because the owner deleting the memory cannot write
-- aiq.edges, and should not need to.
-- ------------------------------------------------------------
create or replace function aiq.forget_deleted_sources() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    with gone as (select id::text as rid from deleted_rows),
    touched as (
        select e.id,
               (select jsonb_agg(s)
                  from jsonb_array_elements(e.provenance->'sources') s
                 where s->>'resource_id' is null
                    or s->>'resource_id' not in (select rid from gone)) as rest
          from aiq.edges e
         where jsonb_typeof(e.provenance->'sources') = 'array'
           and exists (select 1 from jsonb_array_elements(e.provenance->'sources') s
                        where s->>'resource_id' in (select rid from gone))
    ),
    shared as (
        update aiq.edges e
           set provenance = e.provenance || jsonb_build_object('sources', t.rest)
          from touched t
         where e.id = t.id and t.rest is not null
        returning e.id
    )
    delete from aiq.edges e
     using touched t
     where e.id = t.id and t.rest is null;
    return null;
end $$;
revoke execute on function aiq.forget_deleted_sources() from public;

create or replace trigger trg_forget_deleted_sources
    after delete on content.resources
    referencing old table as deleted_rows
    for each statement execute function aiq.forget_deleted_sources();

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
                                      'edges_dropped_unknown_relation','[]'::jsonb,
                                      'node_kinds_unregistered','[]'::jsonb);
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
        -- The resource's org, as aiq.land_graph passes it; omitted, it is the
        -- shared tier (content.land_graph_windows had the same omission).
        v_r := aiq.upsert_graph(v_child.graph, jsonb_build_object(
            'resource_id', v_child.rid, 'run_id', v_run,
            'org_id', (select r.org_id from content.resources r where r.id = v_child.rid::uuid),
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
                        || (v_r->'edges_dropped_unknown_relation')) x),
            -- Unioned for the same reason: across a fan-in the useful fact is
            -- WHICH kinds the model kept inventing, and a count of 295 sends a
            -- reader nowhere.
            'node_kinds_unregistered', (
                select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                  from jsonb_array_elements(
                        (v_acc->'node_kinds_unregistered')
                        || (v_r->'node_kinds_unregistered')) x));
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
-- The two-argument form recorded nothing about the decision (graph-index.md 4.5), so it is
-- dropped rather than overloaded: two arities would let a caller keep writing promotions the
-- ledger cannot see, which is the defect. `if exists` because the upgrade replays this body.
drop function if exists aiq.promote_soft_node(uuid, uuid);

create or replace function aiq.promote_soft_node(p_soft_id uuid, p_target_node_id uuid,
                                                 p_decided_by text, p_tier text,
                                                 p_evidence jsonb default '{}'::jsonb)
returns jsonb as $$
declare
    v_cand uuid; v_moved int := 0; v_merged int := 0; v_self int := 0; v_c int; v_res uuid;
    v_key text; v_type text; v_same_org boolean; v_same_owner boolean; v_name jsonb;
    v_moved_keys jsonb := '[]'::jsonb;
begin
    -- No default for either: a promotion attributed to nobody reads as evidence that
    -- somebody checked. tier is the column the audit groups by (graph-identity.md D11).
    if coalesce(btrim(p_decided_by), '') = '' then
        raise exception 'promote_soft_node needs p_decided_by: the resolver version, agent id or user id';
    end if;
    select id into v_cand from aiq.nodes where entity_type = 'soft' and entity_id = p_soft_id;
    if v_cand is null then
        raise exception 'soft node % has no registry node (already promoted?)', p_soft_id;
    end if;
    if not exists (select 1 from aiq.nodes where id = p_target_node_id) then
        raise exception 'target node % does not exist', p_target_node_id;
    end if;
    if aiq.decided_distinct(v_cand, p_target_node_id) then
        raise exception 'candidate % and node % were decided distinct', v_cand, p_target_node_id
            using hint = 'aiq.undo_distinct the decision first if it was wrong.';
    end if;

    -- 1/2. Repoint, merging on conflict.
    --
    -- THE MERGE IS aiq.upsert_graph's CONFLICT BRANCH, applied to two rows
    -- that already exist, and it disagreed with it on both columns that
    -- decide a walk. It took `least` of the weights, which the upsert
    -- abandoned because corroboration by a weaker source is not evidence
    -- against a stronger one (graph-index.md §11.2). And it never asked
    -- whether either row HELD: it kept the target's valid_to and deleted the
    -- candidate's row, so a retracted target merged with a current candidate
    -- left the fact retracted and deleted the one row that still asserted
    -- it. Measured with dev/tests/query/10-graph-index.sql §10b.
    --
    -- So: weight is `greatest`; the provenance write is the upsert's `||` on
    -- the object with coalesce on the arrays, because `jsonb_set` over an
    -- authored edge's absent `sources` is NULL (§11.3), which NOT NULL turned
    -- into a failed promotion; and the period is the envelope of the two --
    -- earliest valid_from, and valid_to NULL if either side is open, else the
    -- later end. Whenever aiq.edge_is_current holds for either row at now(),
    -- it holds for the envelope, which is the property a merge owes. The
    -- envelope reads a gap between the two periods as belief, the same
    -- one-row-per-triple limit the upsert's revival comment names, and a
    -- revival here is recorded in aiq.edge_retractions by the same trigger.
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
           set provenance = x.provenance || jsonb_build_object('sources',
                                coalesce(x.provenance->'sources', '[]'::jsonb)
                                || coalesce(e.provenance->'sources', '[]'::jsonb)),
               weight     = greatest(x.weight, e.weight),
               valid_from = least(x.valid_from, e.valid_from),
               valid_to   = case when x.valid_to is null or e.valid_to is null then null
                                 else greatest(x.valid_to, e.valid_to) end
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
           set provenance = x.provenance || jsonb_build_object('sources',
                                coalesce(x.provenance->'sources', '[]'::jsonb)
                                || coalesce(e.provenance->'sources', '[]'::jsonb)),
               weight     = greatest(x.weight, e.weight),
               valid_from = least(x.valid_from, e.valid_from),
               valid_to   = case when x.valid_to is null or e.valid_to is null then null
                                 else greatest(x.valid_to, e.valid_to) end
          from aiq.edges e
         where e.dst_id = v_cand and x.dst_id = p_target_node_id
           and x.src_id = e.src_id and x.relation = e.relation
        returning 1)
    select count(*) into v_c from merged;  v_merged := v_merged + v_c;
    delete from aiq.edges where dst_id = v_cand;

    -- 3. An edge the repoint made self-referential.
    delete from aiq.edges where src_id = p_target_node_id and dst_id = p_target_node_id;
    get diagnostics v_self = row_count;

    -- 4a. The target answers to the candidate's name, as an alias -- graph-identity.md
    --     invariant 8, which aiq.resolve_nodes already keeps: a merge deletes no key. The
    --     candidate's name lives in aiq.soft_nodes, not node_keys, so eviction dropped it,
    --     and the next extraction of the same name became a candidate again and was decided
    --     again. Measured 30 Sept in a spike: 45 promotions,
    --     then aiq.resolve_mention found 0 of the 45 names.
    --
    --     ONLY WITHIN ONE ORG. A key is visible to whoever can see its node; its own
    --     org_id is the uniqueness scope, not a read gate (node_keys_via_node). So a
    --     tenant's candidate promoted onto a shared node would publish the tenant's
    --     spelling to every reader of that node. Across orgs the name is not moved, and
    --     the evidence says so rather than leaving the absence to be guessed at.
    --
    --     AND ONLY FROM ONE OWNER'S PRIVATE CANDIDATE ONTO THAT OWNER'S OWN NODE
    --     (REM-962). A private candidate is one person's spelling from one
    --     person's memory; aliased onto a shared node it becomes a key every
    --     reader of that node resolves, which is the same publication the org
    --     rule refuses. The edges still move, and stay gated by their sources.
    select s.key, cn.org_id is not distinct from tn.org_id, tn.entity_type,
           cn.visibility <> 'private'
               or (tn.visibility = 'private' and tn.owner_id is not distinct from cn.owner_id)
      into v_key, v_same_org, v_type, v_same_owner
      from aiq.soft_nodes s, aiq.nodes cn, aiq.nodes tn
     where s.id = p_soft_id and cn.id = v_cand and tn.id = p_target_node_id;
    if not v_same_org then
        v_name := jsonb_build_object('kept', false,
                                     'why', 'candidate and target are in different orgs');
    elsif not v_same_owner then
        v_name := jsonb_build_object('kept', false,
                                     'why', 'the candidate is private to its owner and the target is not theirs');
    elsif exists (select 1 from aiq.node_keys where node_id = p_target_node_id and key = v_key) then
        v_name := jsonb_build_object('kept', true, 'already', true);
    else
        insert into aiq.node_keys (node_id, entity_type, key, kind, org_id)
        select p_target_node_id, v_type, v_key, 'alias', org_id
          from aiq.nodes where id = p_target_node_id;
        v_name := jsonb_build_object('kept', true);
        v_moved_keys := jsonb_build_array(jsonb_build_object(
                            'key', v_key, 'kind', 'alias', 'entity_type', v_type));
    end if;

    -- 4b. Only now: evict. The candidate stops satisfying the inclusion
    --     predicate and the projection's UPDATE eviction removes its node.
    update aiq.soft_nodes set resolved_node_id = p_target_node_id where id = p_soft_id;

    -- 5. And record that a decision was made. `merged_id` carries no foreign key precisely
    --    so this row outlives the node step 4 just evicted -- the column's own comment calls
    --    that "the one event that makes the record most worth having", and this is it.
    --    `via` marks the row a promotion, which is what aiq.unresolve_node refuses on: the
    --    edges moved and the candidate is gone, so there is nothing to restore.
    insert into aiq.node_resolutions (canonical_id, merged_id, tier, decided_by, evidence, org_id)
    values (p_target_node_id, v_cand, p_tier, p_decided_by,
            -- moved_keys has resolve_nodes' shape, so "which names does a model's decision
            -- answer to" is one query over both kinds of merge, grouped by tier.
            p_evidence || jsonb_build_object('via', 'promote_soft_node', 'soft_id', p_soft_id,
                                             'edges_moved', v_moved, 'edges_merged', v_merged,
                                             'name', v_name, 'moved_keys', v_moved_keys),
            (select org_id from aiq.nodes where id = p_target_node_id))
    returning id into v_res;

    return jsonb_build_object('moved', v_moved, 'merged', v_merged, 'self_removed', v_self,
                              'target', p_target_node_id, 'resolution', v_res, 'name', v_name);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- DREAM: the graph reconciles itself on a schedule (REM-961).
--
-- Knit writes fast and loud: every session lands what it heard, and a name it
-- cannot bind lands soft. Reconciling that was a pair of calls somebody made by
-- hand -- promote_soft_node and retract_derived -- and nothing ran them, so
-- "write fast, reconcile later" happened only when someone remembered.
--
-- aiq.dream() does the part that is known BY CONSTRUCTION, and only that. It
-- makes no judgement about meaning, because a scheduled job inside the database
-- has no way to make one it could show its working for:
--
--   1. Supersession, for relations declared single-valued
--      (aiq.graph_vocabulary.single_valued). Where a subject holds more than one
--      current edge of such a relation within one org, every one but the newest
--      ends where the next begins: valid_to = the next edge's valid_from. The
--      edge is not deleted and keeps its provenance, so an as-of read before
--      the change still finds it.
--   2. Soft nodes whose key is EXACTLY the canonical key of one node of the kind
--      they claimed, in the same org: promoted through aiq.promote_soft_node at
--      tier 'registry', which is what that tier means (a match on a registered
--      entity's key, not a model's guess), so the move, the kept name and the
--      resolution row are the ones a hand promotion makes.
--
-- Everything else is counted and left: an unresolved soft node with no exact
-- match (an alias like "P. Raman" is a judge's call), and a relation nobody
-- declared. The receipt carries counts only, never another owner's names.
--
-- Idempotent: a second run finds nothing to supersede and nothing to promote.
-- A DREAM IS A WORKFLOW RUN (REM-1163). aiq.schedule_dream installs the
-- `dream` workflow, whose one step calls this function, so the engine keeps
-- each scheduled run's receipt as that step's output, and the newest receipt's
-- `until` is the next run's `since`. Supersession looks only at subjects with an
-- edge written since then, and promotion at every soft node still unresolved,
-- because an exact target can appear long after the soft node did. A direct
-- call is a one-off: its receipt is its return value, and it moves no
-- watermark. There was a table of runs, aiq.dream_runs, which repeated what the
-- engine already kept for every scheduled run; the 0.2.31 migration drops it.
-- With no run yet the window starts at -infinity, which is only slower, since a
-- dream is idempotent.
create or replace function aiq.dream(p_since timestamptz default null,
                                     p_decided_by text default 'dream')
returns jsonb as $$
declare
    v_until      timestamptz := clock_timestamp();
    v_since      timestamptz;
    v_superseded int := 0;
    v_promoted   int := 0;
    v_refused    int := 0;
    v_why        jsonb := '{}'::jsonb;   -- refusals by kind (REM-1041)
    v_triples    text[] := '{}';
    v_msg        text;
    v_state      text;
    v_kind       text;
    v_left       int := 0;
    v_left_ids   uuid[] := '{}';
    v_queued     int := 0;
    r            record;
    v_receipt    jsonb;
begin
    if coalesce(btrim(p_decided_by), '') = '' then
        raise exception 'aiq.dream needs p_decided_by: who or what decided, for the resolution rows it writes';
    end if;
    -- The newest finished dream run's window end. The step running now is not
    -- finished, so it never reads itself.
    v_since := coalesce(p_since,
        (select max((wt.output->'result'->>'until')::timestamptz)
           from workflow.tasks wt
           join workflow.runs wr on wr.id = wt.run_id
           join workflow.definitions wd on wd.id = wr.workflow_def_id
          where wd.name = 'dream' and wt.step_key = 'reconcile' and wt.status = 'succeeded'),
        '-infinity'::timestamptz);

    -- 1. Supersession. One UPDATE: within each (subject, relation, org) of a
    --    single-valued relation, an edge with a later current one after it ends
    --    where that one begins. Only subjects touched since the watermark.
    with groups as (
        select distinct e.src_id, e.relation, e.org_id
          from aiq.edges e
          join aiq.graph_vocabulary v on v.relation = e.relation and v.single_valued
         where e.created_at > v_since or e.valid_from > v_since
    ), ordered as (
        select e.id,
               lead(e.valid_from) over (partition by e.src_id, e.relation, e.org_id
                                        order by e.valid_from, e.created_at, e.id) as next_from
          from aiq.edges e
          join groups g on g.src_id = e.src_id and g.relation = e.relation
                       and g.org_id is not distinct from e.org_id
         where aiq.edge_is_current(e.valid_from, e.valid_to, v_until)
    ), ended as (
        update aiq.edges e set valid_to = o.next_from
          from ordered o
         where e.id = o.id and o.next_from is not null
        returning 1
    )
    select count(*) into v_superseded from ended;

    -- 2. Exact soft nodes. Each promotion runs on its own, so one the resolver
    --    refuses (decided distinct, a scope mismatch) is counted, not fatal.
    for r in
        select s.id as soft_id,
               array_agg(distinct t.id) filter (where t.id is not null) as targets
          from aiq.soft_nodes s
          join aiq.nodes sn on sn.entity_type = 'soft' and sn.entity_id = s.id
          left join (aiq.node_keys k join aiq.nodes t on t.id = k.node_id)
                 on k.kind = 'canonical' and k.key = lower(btrim(s.key))
                and t.entity_type = s.claimed_kind
                and t.org_id is not distinct from s.org_id
         where s.resolved_node_id is null
         group by s.id
    loop
        if cardinality(r.targets) = 1 then
            begin
                perform aiq.promote_soft_node(r.soft_id, r.targets[1], p_decided_by, 'registry',
                                              jsonb_build_object('rule', 'exact canonical key, same kind, same org'));
                v_promoted := v_promoted + 1;
            exception when others then
                v_refused := v_refused + 1;
                -- WHY, by kind, and never the message whole: a refusal can name
                -- another owner's node by id (REM-1041). The catalogue refusal
                -- names kinds and a relation only, so its triple is kept, because
                -- it is the fix.
                get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
                v_kind := case when v_msg like 'relation (%) is not in the catalogue%' then 'missing_triple'
                               when v_msg like '% were decided distinct' then 'decided_distinct'
                               else 'sqlstate_' || v_state end;
                v_why := jsonb_set(v_why, array[v_kind], to_jsonb(coalesce((v_why->>v_kind)::int, 0) + 1));
                if v_kind = 'missing_triple' then
                    v_triples := v_triples || substring(v_msg from '^relation (\(.*\)) is not in the catalogue');
                end if;
            end;
        else
            v_left := v_left + 1;
            v_left_ids := v_left_ids || r.soft_id;
        end if;
    end loop;

    -- 3. What no rule decided waits for a judge (REM-1055), once per case.
    v_queued := aiq.enqueue_soft_judgements(v_left_ids, p_decided_by);

    v_receipt := jsonb_build_object(
        'since', v_since, 'until', v_until,
        'superseded', v_superseded,
        'promoted_exact', v_promoted,
        'promotion_refused', v_refused,
        'soft_left_for_a_judge', v_left,
        'queued_for_a_judge', v_queued);
    -- Only when something was refused, so a clean run's receipt is unchanged.
    if v_refused > 0 then
        v_receipt := v_receipt || jsonb_build_object('refusals', v_why);
        if cardinality(v_triples) > 0 then
            v_receipt := v_receipt || jsonb_build_object(
                'missing_triples', (select jsonb_agg(distinct t) from unnest(v_triples) t),
                'hint', 'a kind registered after the vocabulary has no relations yet: '
                        'select aiq.register_graph_vocabulary() widens the catalogue to it, then run dream again');
        end if;
    end if;
    return v_receipt;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- JUDGEMENTS: what dream leaves, waiting for a judge (REM-1055).
--
-- dream decides only what is known by construction. Every other case -- a soft
-- node with no exact target, or with several -- used to be a count in its
-- receipt and then a person's job: the Zep tutorial piped a shell call to a
-- model into aiq.promote_soft_node. Percolate runs on the person's own AI, so
-- the case waits HERE, the way a review request waits for a connected agent,
-- and nothing decides it until a judge does. A configured model is a judge
-- behind the same calls (tier 'llm' or 'decision_model'), not a default.
--
-- `evidence` is what a judge needs that it could not otherwise ask for: the
-- name, the kind it claimed, and up to five candidates a trigram match
-- proposes, each with its key and summary. It does NOT carry what was said
-- about the subject: a fact is gated by the memory it came from (§10a), so the
-- judge reads the subject with aiq.query, as itself.
--
-- THE JUDGE ACTS AS ITSELF, UNDER ROW POLICY. The four calls below are SECURITY
-- INVOKER (query/06: nothing a person reaches in aiq runs past their policies).
-- A judge sees an item when it can see the item's subject node, so a private
-- memory's candidate stays its owner's. It may UPDATE the row, and a BEFORE
-- trigger allows only the moves a judge has: claim, release, decide or pass to
-- a person, each by the live claimant. Applying a decision -- promoting the
-- soft node, recording a distinction -- is the engine's write path, so an AFTER
-- trigger does it as the owner. Nobody can call that trigger; the guard is what
-- stands between a caller and it.
--
-- NOT A `hire:` QUEUE YET, and why (hired-steps.md §7 asks). A hired step is
-- a workflow task claimed through claim_task under the run starter's grant, and
-- that is the mechanism this should converge on. Two things stop it today:
-- claim_task is the worker's alone (REM-1060 is the change that lets a caller
-- claim as itself), and who may see a judgement is decided by its SUBJECT,
-- while a hired step is scoped to the run's starter, which for dream is the
-- engine. When REM-1060 lands, this becomes a `hire:judge` queue whose claim
-- predicate is this table's row policy, and these four calls keep their names.
--
-- kind: 'bind' (a soft node to a typed one) is the only one dream queues today;
-- 'merge' (two typed nodes) and 'withdraw' (a fact to retract) are declared so a
-- client renders them when a rule starts leaving them.
create table if not exists aiq.judgements (
    id              uuid primary key default uuidv7(),
    kind            text not null check (kind in ('bind','merge','withdraw','challenge')),
    -- The soft node's registry node, for a bind. No foreign key: promotion
    -- evicts that node, and the decided row is the record of why.
    subject_node_id uuid not null,
    evidence        jsonb not null default '{}'::jsonb,
    status          text not null default 'open'
                        check (status in ('open','claimed','to_human','decided','moot')),
    queued_by       text not null,
    queued_at       timestamptz not null default now(),
    claimed_by      uuid,
    -- What the item goes back to on release: open, or to_human.
    claimed_from    text,
    lease_until     timestamptz,
    verdict         jsonb,
    reason          text,
    decided_by      text,
    tier            text check (tier in ('llm','decision_model','agent','human')),
    decided_at      timestamptz,
    -- The resolution and distinction ids the verdict wrote, so it can be undone
    -- by name (aiq.unresolve_node, aiq.undo_distinct).
    result          jsonb,
    org_id          uuid
);
comment on table aiq.judgements is
    'A case a rule could not decide, waiting for a judge: the connected agent, a configured model or a person. Its verdict, reason, decider and tier, and what it wrote.';
select rbac.adopt_shared_org('aiq.judgements');
create unique index if not exists idx_judgements_live
    on aiq.judgements (kind, subject_node_id) where status in ('open','claimed','to_human');
create index if not exists idx_judgements_queue on aiq.judgements (status, queued_at);

-- A CHALLENGE (REM-659, specs/claims/graph.md §5 *Did you mean*): a newly
-- embedded claim, and the claims nearest it that its WRITER may read, put to
-- that writer to say whether one of them is the same claim or bears on it.
-- Its subject is the claim's identity (claims.claims), not a graph node, and
-- it is addressed: a challenge is seen by the person it was put to and by
-- nobody else, because its candidates were chosen under that person's read
-- policy and another reader's horizon would choose different ones. Their own
-- connected agent answers it through the same four calls, and the answer is
-- claims.assert_relation as the judge, so an agent's lands proposed.
--
-- Added rather than written into the CREATE above, so a fresh install and an
-- upgraded one reach the same table by the same statements.
alter table aiq.judgements add column if not exists addressee uuid;
comment on column aiq.judgements.addressee is
    'For a challenge, the writer it is put to: the only person who sees it. Null for every other kind.';
alter table aiq.judgements drop constraint if exists judgements_kind_check;
alter table aiq.judgements add constraint judgements_kind_check
    check (kind in ('bind','merge','withdraw','challenge'));
alter table aiq.judgements drop constraint if exists judgements_challenge_addressed;
alter table aiq.judgements add constraint judgements_challenge_addressed
    check ((kind = 'challenge') = (addressee is not null));

alter table aiq.judgements enable row level security;
-- Seen through the subject, or -- once a bind is decided and promotion has
-- evicted the subject -- through the node it was bound to. As the caller: the
-- subqueries read aiq.nodes under the caller's own policy. Not a challenge,
-- whose subject is a claim and which has its own policy below.
drop policy if exists judgements_via_subject on aiq.judgements;
create policy judgements_via_subject on aiq.judgements for select
  using (aiq.judgements.kind <> 'challenge'
     and (exists (select 1 from aiq.nodes n where n.id = aiq.judgements.subject_node_id)
      or (aiq.judgements.verdict->>'decision' = 'bind'
          and exists (select 1 from aiq.nodes n
                       where n.id::text = aiq.judgements.verdict->>'target'))));
drop policy if exists judgements_judge_moves on aiq.judgements;
create policy judgements_judge_moves on aiq.judgements for update
  using (aiq.judgements.kind <> 'challenge'
     and exists (select 1 from aiq.nodes n where n.id = aiq.judgements.subject_node_id));
-- A challenge is its addressee's, to read and to decide.
drop policy if exists judgements_challenge_addressee on aiq.judgements;
create policy judgements_challenge_addressee on aiq.judgements for select
  using (aiq.judgements.kind = 'challenge' and aiq.judgements.addressee = rbac.current_user_id());
drop policy if exists judgements_challenge_moves on aiq.judgements;
create policy judgements_challenge_moves on aiq.judgements for update
  using (aiq.judgements.kind = 'challenge' and aiq.judgements.addressee = rbac.current_user_id());
revoke all on aiq.judgements from public, authenticated, api_viewer;
grant select on aiq.judgements to authenticated;
grant update (status, claimed_by, claimed_from, lease_until, verdict, reason, decided_by, tier, decided_at)
    on aiq.judgements to authenticated;

-- A bind's evidence: the soft node and up to five candidates, in its org or the
-- shared one, never itself, not already decided distinct:
--   * typed nodes of the kind it claimed, by key or summary;
--   * OTHER SOFT NODES (jack, 20 Oct): an alias claimed as the same kind ("A.
--     Costa" beside "Ana Costa"), and the same name claimed as another kind
--     ("Tagus Ceramics" as organization and as company). A soft name's twin is
--     usually another soft name, and with typed rows only, all eight binds the
--     Zep tutorial queued had no candidate. A bind to a soft target is what
--     aiq.promote_soft_node does when a person merges two soft nodes by hand.
-- Each candidate says which it is, so the judge can weigh a typed row above a
-- name somebody else's extractor wrote.
create or replace function aiq.soft_bind_evidence(p_soft_id uuid)
returns jsonb language sql stable set search_path = pg_catalog, public as $$
    select jsonb_build_object(
        'soft_id', s.id, 'key', s.key, 'label', s.label,
        'claimed_kind', s.claimed_kind, 'attrs', s.attrs,
        'candidates', coalesce((
            select jsonb_agg(jsonb_build_object('node_id', c.node_id, 'key', c.key,
                                                'entity_type', c.entity_type, 'summary', c.summary,
                                                'candidate', c.candidate,
                                                'sim', round(c.sim::numeric, 3))
                             order by c.sim desc)
              from (select * from (
                      select distinct on (m.node_id) m.* from (
                          select n.id as node_id, k.key, n.entity_type, n.summary,
                                 similarity(k.key, s.key) as sim, 'typed' as candidate
                            from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
                           where k.key % s.key and n.entity_type = s.claimed_kind
                             and n.org_id in (rbac.shared_org_id(), s.org_id)
                          union all
                          select n.id, null, n.entity_type, n.summary, similarity(lower(n.summary), s.key), 'typed'
                            from aiq.nodes n
                           where lower(n.summary) % s.key and n.entity_type = s.claimed_kind
                             and n.org_id in (rbac.shared_org_id(), s.org_id)
                          union all
                          select n2.id, s2.key, n2.entity_type, n2.summary,
                                 case when s2.key = s.key then 1.0 else similarity(s2.key, s.key) end,
                                 case when s2.claimed_kind = s.claimed_kind then 'soft'
                                      else 'soft, claimed as ' || s2.claimed_kind end
                            from aiq.soft_nodes s2
                            join aiq.nodes n2 on n2.entity_type = 'soft' and n2.entity_id = s2.id
                           where s2.id <> s.id and s2.resolved_node_id is null
                             and ((s2.claimed_kind = s.claimed_kind and s2.key % s.key)
                                  or (s2.claimed_kind <> s.claimed_kind and s2.key = s.key))
                             and n2.org_id in (rbac.shared_org_id(), s.org_id)) m
                       where not aiq.decided_distinct(sn.id, m.node_id)
                       order by m.node_id, m.sim desc) best
                     order by best.sim desc limit 5) c), '[]'::jsonb))
      from aiq.soft_nodes s
      join aiq.nodes sn on sn.entity_type = 'soft' and sn.entity_id = s.id
     where s.id = p_soft_id;
$$;

-- Queue a bind for each soft node given, unless one is already live; refresh
-- an open one's candidates; mark moot a bind whose soft node resolved some
-- other way. Returns how many were added.
-- dream is the one caller (freddie, 19 Oct: knit fires loud, dream reconciles
-- -- a landing must not queue what a rule would settle).
create or replace function aiq.enqueue_soft_judgements(p_soft_ids uuid[], p_queued_by text)
returns int language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_n int;
begin
    with ins as (
        insert into aiq.judgements (kind, subject_node_id, evidence, queued_by, org_id)
        select 'bind', sn.id, ev.evidence, p_queued_by,
               coalesce(s.org_id, rbac.shared_org_id())
          from aiq.soft_nodes s
          join aiq.nodes sn on sn.entity_type = 'soft' and sn.entity_id = s.id
          cross join lateral (select aiq.soft_bind_evidence(s.id) as evidence) ev
         where s.id = any(p_soft_ids) and s.resolved_node_id is null
           -- ONLY A CASE WITH A CANDIDATE (bob, 20 Oct). A name nothing is
           -- like can only be decided "none", so it sat open forever and
           -- crowded the queue: four of five in the advanced article. It stays
           -- counted in dream's soft_left_for_a_judge, and is queued on the
           -- first run that finds it a candidate.
           and jsonb_array_length(ev.evidence->'candidates') > 0
        on conflict (kind, subject_node_id) where status in ('open','claimed','to_human') do nothing
        returning 1)
    select count(*) into v_n from ins;
    -- AN OPEN ITEM'S EVIDENCE IS REFRESHED, because candidates appear after a
    -- case is queued -- a typed row registered, or another soft name landed --
    -- and an item queued with none could otherwise never be bound. Not a
    -- claimed one, whose judge is reading what it was given.
    update aiq.judgements j set evidence = aiq.soft_bind_evidence((j.evidence->>'soft_id')::uuid)
     where j.kind = 'bind' and j.status in ('open','to_human')
       and (j.evidence->>'soft_id')::uuid = any(p_soft_ids)
       and j.evidence is distinct from aiq.soft_bind_evidence((j.evidence->>'soft_id')::uuid);
    update aiq.judgements j set status = 'moot', claimed_by = null, lease_until = null
     where j.kind = 'bind' and j.status in ('open','claimed','to_human')
       and not exists (select 1 from aiq.nodes n where n.id = j.subject_node_id and n.entity_type = 'soft');
    -- An open item left with no candidate -- queued by 0.2.25, which queued
    -- every leftover name -- leaves the queue the same way; it comes back when
    -- a candidate does.
    update aiq.judgements j set status = 'moot'
     where j.kind = 'bind' and j.status = 'open'
       and jsonb_array_length(coalesce(j.evidence->'candidates', '[]'::jsonb)) = 0;
    return v_n;
end;
$$;

-- THE GUARD: the moves a judge may make by UPDATE, and nothing else. Runs as
-- the caller, so "the target is a candidate you can see" is the caller's own
-- policy answering. The engine (any role but authenticated) is not guarded:
-- dream and the apply trigger below write as the owner.
--
-- Leases are clock time, not transaction time: now() stands still for a whole
-- transaction, so a lease measured by it could not lapse inside one.
create or replace function aiq.judgements_guard()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare
    v_uid uuid := rbac.current_user_id(); v_live boolean; v_dec text;
begin
    if current_user <> 'authenticated' then
        return new;
    end if;
    if v_uid is null then
        raise exception 'a judgement is decided by somebody: no signed-in caller';
    end if;
    if new.id <> old.id or new.kind <> old.kind or new.subject_node_id <> old.subject_node_id
       or new.evidence <> old.evidence or new.queued_by <> old.queued_by
       or new.queued_at <> old.queued_at or new.result is distinct from old.result
       or new.org_id <> old.org_id or new.addressee is distinct from old.addressee then
        raise exception 'a judge changes only a judgement''s claim and verdict';
    end if;
    v_live := old.status = 'claimed' and old.claimed_by = v_uid and old.lease_until > clock_timestamp();

    if new.status = 'claimed' then
        -- Take: an open item, one whose lease lapsed, or (by id, see
        -- claim_judgement) one passed to a person.
        if not (old.status in ('open','to_human')
                or (old.status = 'claimed' and old.lease_until <= clock_timestamp())
                or v_live) then
            raise exception 'judgement % is held by someone else', old.id;
        end if;
        if new.claimed_by is distinct from v_uid
           or new.lease_until is null or new.lease_until <= clock_timestamp()
           or new.lease_until > clock_timestamp() + interval '1 hour'
           or new.verdict is distinct from old.verdict or new.decided_at is distinct from old.decided_at then
            raise exception 'a claim is yours, for up to an hour, and decides nothing';
        end if;
        return new;
    end if;

    if not v_live then
        raise exception 'you do not hold a live claim on judgement %', old.id
            using hint = 'aiq.claim_judgement(p_id => ...) first; a lapsed lease must be claimed again';
    end if;

    if new.status in ('open','to_human')
       and (new.verdict is null or new.verdict is not distinct from old.verdict
            or (old.kind = 'challenge' and new.status = 'to_human' and new.verdict ? 'suggested'
                and new.verdict - 'suggested' - 'suggested_by' = '{}'::jsonb
                and new.verdict->>'suggested_by' = 'agent:' || v_uid)) then
        -- Release, or pass to a person: the claim ends and nothing is decided. A challenge passed to the person
        -- carries the agent's answer as its suggestion (REM-1123), which decides nothing either.
        if new.claimed_by is not null or new.lease_until is not null or new.decided_at is not null then
            raise exception 'a release ends the claim and records nothing';
        end if;
        return new;
    end if;

    if new.status <> 'decided' then
        raise exception 'a judge moves a judgement to claimed, open, to_human or decided, not %', new.status;
    end if;
    v_dec := new.verdict->>'decision';
    if old.kind = 'challenge' then
        if v_dec is null or v_dec not in ('relate','none') then
            raise exception 'a challenge is decided relate or none, not %', coalesce(v_dec, 'missing')
                using hint = 'relate names the candidate and the relation; none says no candidate bears on the claim';
        end if;
    elsif v_dec is null or v_dec not in ('bind','distinct','none') then
        raise exception 'decision must be bind, distinct or none, not %', coalesce(v_dec, 'missing');
    end if;
    if coalesce(btrim(new.reason), '') = '' then
        raise exception 'a judgement needs a reason: it is the record a later reader checks the verdict against';
    end if;
    if new.tier is null then
        raise exception 'a judgement needs a tier: agent, human, llm or decision_model';
    end if;
    -- THE TIER CANNOT CLAIM MORE THAN THE CALLER IS (REM-1123). It was the caller's word, and decided_by below is
    -- built from it: an agent could record its decision as the person's, and anyone as the platform's models.
    -- Only a person decides as human, and only the platform as llm or decision_model. A person may still record
    -- their decision as agent, under their own id -- the article tours decide that way, and it claims nothing a
    -- person lacks; settling, which is an agent's alone, asks rbac.current_actor() itself (claims.settle_challenge).
    if (new.tier = 'human' and rbac.current_actor() <> 'person')
       or (new.tier in ('llm', 'decision_model') and rbac.current_actor() <> 'platform') then
        raise insufficient_privilege using
            message = format('a judgement decided as %s cannot be recorded as %s', rbac.current_actor(), new.tier),
            hint = 'only a person decides as human, and only the platform as llm or decision_model';
    end if;
    -- A RELATE IS A RELATION THAT EXISTS. complete_judgement asserts each one
    -- as the judge and writes its id into the verdict; a verdict written
    -- straight onto the row names relations nobody asserted, and is refused
    -- here: each must be a candidate the judge can still read, and the id a
    -- relation from this claim to it, with that predicate, that the judge can
    -- read.
    if old.kind = 'challenge' and v_dec = 'relate' then
        if jsonb_typeof(new.verdict->'relations') is distinct from 'array'
           or jsonb_array_length(new.verdict->'relations') = 0 then
            raise exception 'a relate names at least one relation';
        end if;
        if exists (
            select 1 from jsonb_array_elements(new.verdict->'relations') r
             where not exists (
                       select 1 from jsonb_array_elements(old.evidence->'candidates') c
                        where c->>'claim_id' = r->>'target'
                          and research.revision_readable((c->>'revision_id')::uuid))
                or not exists (
                       select 1 from claims.relations x
                        where pg_input_is_valid(r->>'relation_id', 'bigint')
                          and x.id = (r->>'relation_id')::bigint and x.src = old.subject_node_id
                          and x.dst::text = r->>'target' and x.predicate = r->>'predicate')) then
            raise exception 'a relate names candidates of this challenge and the relations asserted to them'
                using hint = 'decide it with aiq.complete_judgement, which asserts each relation as you';
        end if;
    end if;
    if v_dec = 'bind' and not exists (
            select 1 from jsonb_array_elements(old.evidence->'candidates') c
              join aiq.nodes n on n.id::text = c->>'node_id'
             where c->>'node_id' = new.verdict->>'target') then
        raise exception 'a bind names one of the candidates you can see as target; % is not one',
            coalesce(new.verdict->>'target', 'missing')
            using hint = 'if it is something else, decide none and say what';
    end if;
    -- Who decided is the caller, whatever the row says.
    new.decided_by := case new.tier when 'human' then 'user:' else new.tier || ':' end || v_uid;
    new.decided_at := clock_timestamp();
    new.claimed_by := null; new.claimed_from := null; new.lease_until := null;
    return new;
end;
$$;
create or replace trigger judgements_guard before update on aiq.judgements
    for each row execute function aiq.judgements_guard();

-- THE APPLY: a decided verdict, carried out by the engine's own write path and
-- recorded on the row. Distinct is recorded against every candidate the
-- decider could see when deciding.
create or replace function aiq.judgements_apply()
returns trigger language plpgsql security definer set search_path = pg_catalog, public as $$
declare
    v_ev jsonb := jsonb_build_object('judgement', new.id, 'reason', new.reason);
    v_res uuid[] := '{}'; v_dist uuid[] := '{}'; v_c jsonb;
begin
    -- A challenge's verdict was carried out by the judge, as the judge
    -- (complete_judgement asserted each relation); what it wrote is recorded.
    if new.kind = 'challenge' then
        update aiq.judgements
           set result = jsonb_build_object('relation_ids', coalesce(
                   (select jsonb_agg((r->>'relation_id')::bigint)
                      from jsonb_array_elements(coalesce(new.verdict->'relations', '[]'::jsonb)) r), '[]'::jsonb))
         where id = new.id;
        return null;
    end if;
    if new.verdict->>'decision' = 'bind' then
        perform aiq.promote_soft_node((new.evidence->>'soft_id')::uuid, (new.verdict->>'target')::uuid,
                                      new.decided_by, new.tier, v_ev);
        select coalesce(array_agg(r.id), '{}') into v_res from aiq.node_resolutions r
         where r.merged_id = new.subject_node_id and r.canonical_id = (new.verdict->>'target')::uuid
           and r.undone_at is null;
    elsif new.verdict->>'decision' = 'distinct' then
        for v_c in select * from jsonb_array_elements(coalesce(new.verdict->'seen', '[]'::jsonb)) loop
            v_dist := v_dist || aiq.record_distinct(new.subject_node_id, (v_c #>> '{}')::uuid,
                                                    new.decided_by, new.tier, v_ev);
        end loop;
    end if;
    update aiq.judgements
       set result = jsonb_build_object('resolution_ids', to_jsonb(v_res), 'distinction_ids', to_jsonb(v_dist))
     where id = new.id;

    -- THE TWIN SETTLES WITH IT (jack, 20 Oct). A pair of aliases is queued
    -- from both sides -- "A. Costa, candidate Ana Costa" and "Ana Costa,
    -- candidate A. Costa" -- and binding one evicts the node the other
    -- proposed. So the bound node leaves every open item's candidates, and an
    -- item left with none is moot, naming the judgement that settled it,
    -- rather than open with nothing a judge could do but close it by hand.
    if new.verdict->>'decision' = 'bind' then
        update aiq.judgements j
           set evidence = j.evidence || jsonb_build_object('candidates', coalesce(
                   (select jsonb_agg(c) from jsonb_array_elements(j.evidence->'candidates') c
                     where c->>'node_id' <> new.subject_node_id::text), '[]'::jsonb))
         where j.id <> new.id and j.status in ('open','to_human')
           and j.evidence->'candidates' @> jsonb_build_array(jsonb_build_object('node_id', new.subject_node_id::text));
        update aiq.judgements j
           set status = 'moot',
               evidence = j.evidence || jsonb_build_object('settled_by', jsonb_build_object(
                   'judgement', new.id, 'bound', new.subject_node_id, 'onto', new.verdict->>'target'))
         where j.id <> new.id and j.status = 'open'
           and jsonb_array_length(coalesce(j.evidence->'candidates', '[]'::jsonb)) = 0
           and j.evidence ? 'candidates'
           and exists (select 1 from aiq.nodes n where n.id = j.subject_node_id)
           and j.subject_node_id = (new.verdict->>'target')::uuid;
    end if;
    return null;
end;
$$;
create or replace trigger judgements_apply after update on aiq.judgements
    for each row when (new.status = 'decided' and old.status is distinct from 'decided')
    execute function aiq.judgements_apply();

-- WHAT WAS SAID ABOUT A NODE, as the caller may read it (bob, 20 Oct). A judge
-- given only names and a similarity score cannot quote its evidence, and both
-- tutorials' reasons cited sentences the tools had never shown. So each fact
-- touching the node comes with where it was said: the message (session and
-- message id, and its text) or the resource (id, title, and the chunk that
-- names it), cut to 300 characters. SECURITY INVOKER: aiq.edges, the messages
-- and the chunks are read under the caller's own policies, so a fact from a
-- memory they may not read is simply not here.
create or replace function aiq.judgement_said(p_node uuid, p_limit int default 5)
returns jsonb language sql stable set search_path = pg_catalog, public as $$
    select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select jsonb_strip_nulls(jsonb_build_object(
                   'relation', e.relation,
                   'direction', case when e.src_id = p_node then 'out' else 'in' end,
                   'other', ok.key,
                   'session_id', s->>'session_id',
                   'message_id', s->'message_ids'->>0,
                   'resource_id', s->>'resource_id',
                   'title', r.title,
                   'said', left(coalesce(m.content, ch.content), 300))) as x
          from aiq.edges e
          join aiq.node_keys ok
            on ok.node_id = case when e.src_id = p_node then e.dst_id else e.src_id end
           and ok.kind = 'canonical'
          cross join lateral jsonb_array_elements(coalesce(e.provenance->'sources', '[]'::jsonb)) s
          left join lateral (select agentic.message_said((s->'message_ids'->>0)::uuid) as content
                              where pg_input_is_valid(s->'message_ids'->>0, 'uuid')) m on true
          left join content.resources r
            on pg_input_is_valid(s->>'resource_id', 'uuid') and r.id = (s->>'resource_id')::uuid
          left join lateral (
              select c.content from content.resource_chunks c, aiq.nodes me
               where c.resource_id = r.id and me.id = p_node
                 and c.content ilike '%' || coalesce(me.summary, '') || '%'
               order by c.ordinal limit 1) ch on true
         where p_node in (e.src_id, e.dst_id)
           and aiq.edge_is_current(e.valid_from, e.valid_to, now())
         order by e.created_at desc
         limit greatest(least(coalesce(p_limit, 5), 20), 1)) t;
$$;

-- What the claimant may see of an item: the candidates it can see, and how to
-- decide it in words an agent passes through.
create or replace function aiq.judgement_for_judge(p_id uuid)
returns jsonb language plpgsql stable set search_path = pg_catalog, public as $$
declare j aiq.judgements; v_ev jsonb; v_ids text;
begin
    select * into j from aiq.judgements where id = p_id;
    if j.kind = 'challenge' then
        -- The candidates the judge can still read: one whose revision has
        -- since been withdrawn from them leaves the item rather than its text
        -- staying in the evidence.
        v_ev := j.evidence || jsonb_build_object('candidates', coalesce(
            (select jsonb_agg(c order by (c->>'distance')::float8)
               from jsonb_array_elements(j.evidence->'candidates') c
              where research.revision_readable((c->>'revision_id')::uuid)), '[]'::jsonb));
        select string_agg(c->>'claim_id' || ' (' || (c->>'claim_key') || ')', ', ')
          into v_ids from jsonb_array_elements(v_ev->'candidates') c;
        return jsonb_build_object(
            'id', j.id, 'kind', j.kind, 'status', j.status, 'lease_until', j.lease_until,
            'evidence', v_ev,
            'how_to_decide', format(
                'Your claim %s, %L, was saved, and these claims already in the graph are the nearest to it that you may read: %s. '
                'Decide whether each is the same claim, or how it bears on yours, and quote both in your reason. '
                'Distance only ranks them; it says nothing about meaning (specs/claims/graph.md §5). '
                'Decide it -- the decide_judgement tool over MCP, or aiq.complete_judgement(%L, verdict, reason) in SQL -- with verdict one of: '
                '{"decision":"relate","relations":[{"target":"<candidate claim_id>","predicate":"<relation>","spans":{...}}]}, '
                'where predicate is the first that holds of same_as (substitutable: spans.src and spans.dst quoted from each, and spans.slots.src and .dst each naming subject, predicate, object, scope, polarity and modality), '
                'qualifies, agrees, contradicts or different_scope (comparative: spans.src, spans.dst and spans.frame_match, each slot same, overlaps, differs, unknown, or unstated when neither claim states it), '
                'and each is asserted as you; '
                'add "confidence": a number from 0 to 1 saying how sure you are. Where the deployment lets the writer''s agent settle what it is sure of (REM-1123), '
                'an answer at or above its setting settles the challenge and the person is not asked, and one below it, or with no confidence, '
                'goes to the person with your answer as the suggestion; otherwise a relation you assert lands proposed until the person confirms it; '
                '{"decision":"none"} if no candidate bears on the claim (recorded, so these candidates are not put to you again); '
                '{"decision":"human"} to pass it to a person. '
                'Not sure: release_judgement (aiq.release_judgement(%L)) gives it back with nothing recorded. Your claim ends at %s.',
                j.evidence->>'claim_key', j.evidence->>'text',
                coalesce(v_ids, 'none you can still read (decide none)'), j.id, j.id, j.lease_until));
    end if;
    v_ev := j.evidence || jsonb_build_object(
        'said', aiq.judgement_said(j.subject_node_id),
        'candidates', coalesce(
        (select jsonb_agg(c || jsonb_build_object('said', aiq.judgement_said((c->>'node_id')::uuid, 3)))
           from jsonb_array_elements(j.evidence->'candidates') c
          where exists (select 1 from aiq.nodes n where n.id::text = c->>'node_id')), '[]'::jsonb));
    select string_agg(c->>'node_id' || ' (' || coalesce(c->>'key', c->>'summary')
                      || coalesce(', ' || (c->>'candidate'), '') || ')', ', ')
      into v_ids from jsonb_array_elements(v_ev->'candidates') c;
    return jsonb_build_object(
        'id', j.id, 'kind', j.kind, 'status', j.status, 'lease_until', j.lease_until,
        'evidence', v_ev,
        'how_to_decide', format(
            'Decide whether %L, named as a %s, is the same thing as one of the candidates. '
            'What was said about it and about each candidate is in evidence.said, with the message or resource each fact came from: quote it in your reason. '
            'For more, read as yourself: aiq.query(''LOOKUP "%s"'') or GRAPH. '
            'Then decide it -- the decide_judgement tool over MCP, or aiq.complete_judgement(%L, verdict, reason) in SQL -- with verdict one of: '
            '{"decision":"bind","target":"<node_id>"} where target is one of %s; '
            '{"decision":"distinct"} if it is none of them (recorded against each, so it is not asked again); '
            '{"decision":"none"} to leave it unresolved and say why; '
            '{"decision":"human"} to pass it to a person. '
            'Not sure: release_judgement (aiq.release_judgement(%L)) gives it back with nothing recorded. Your claim ends at %s.',
            coalesce(v_ev->>'label', v_ev->>'key'), v_ev->>'claimed_kind', v_ev->>'key', j.id,
            coalesce(v_ids, 'none (no candidate: distinct does nothing, so use none or human)'),
            j.id, j.lease_until));
end;
$$;

-- Take one item. Your own live claim comes back first, so a retry after a lost
-- response is the same item. An open item, or one whose lease lapsed, is taken
-- SKIP LOCKED; a to_human item only by id, since it was passed to a person.
create or replace function aiq.claim_judgement(p_kinds text[] default null, p_id uuid default null,
                                               p_lease interval default '10 minutes')
returns jsonb language plpgsql set search_path = pg_catalog, public as $$
declare v_uid uuid := rbac.current_user_id(); v_id uuid;
begin
    if v_uid is null then
        raise exception 'claim_judgement needs a signed-in caller: a judgement is decided by somebody';
    end if;
    if p_lease is null or p_lease <= interval '0' or p_lease > interval '1 hour' then
        raise exception 'p_lease must be between 0 and 1 hour, not %', p_lease;
    end if;
    select id into v_id from aiq.judgements
     where status = 'claimed' and claimed_by = v_uid and lease_until > clock_timestamp()
       and (p_id is null or id = p_id) and (p_kinds is null or kind = any(p_kinds))
     order by queued_at limit 1;
    if v_id is null then
        select id into v_id from aiq.judgements
         where (status = 'open' or (status = 'claimed' and lease_until <= clock_timestamp())
                or (status = 'to_human' and p_id is not null))
           and (p_id is null or id = p_id) and (p_kinds is null or kind = any(p_kinds))
         order by queued_at
         for update skip locked limit 1;
        if v_id is null then
            if p_id is not null then
                raise exception 'judgement % is not open to you: it does not exist, you cannot see it, or someone holds it', p_id;
            end if;
            return jsonb_build_object('empty', true);
        end if;
        update aiq.judgements
           set claimed_from = case when status = 'claimed' then coalesce(claimed_from, 'open') else status end,
               status = 'claimed', claimed_by = v_uid, lease_until = clock_timestamp() + p_lease
         where id = v_id;
    end if;
    return aiq.judgement_for_judge(v_id);
end;
$$;

create or replace function aiq.release_judgement(p_id uuid)
returns jsonb language plpgsql set search_path = pg_catalog, public as $$
declare v_status text;
begin
    update aiq.judgements
       set status = coalesce(claimed_from, 'open'), claimed_by = null, claimed_from = null, lease_until = null
     where id = p_id and status = 'claimed' and claimed_by = rbac.current_user_id()
    returning status into v_status;
    if not found then
        raise exception 'you hold no claim on judgement %', p_id;
    end if;
    return jsonb_build_object('id', p_id, 'status', v_status);
end;
$$;

-- Decide an item you hold. The same verdict again is idempotent; a different
-- one after the decision is refused -- undo by the ids in `result` and judge
-- again. The guard trigger checks the claim, the lease and the verdict; the
-- apply trigger carries it out.
create or replace function aiq.complete_judgement(p_id uuid, p_verdict jsonb, p_reason text,
                                                  p_tier text default 'agent')
returns jsonb language plpgsql set search_path = pg_catalog, public as $$
declare
    j aiq.judgements; v_verdict jsonb := p_verdict; v_rels jsonb; v_mode jsonb;
    -- judgements_guard refuses a tier that claims more than the caller is (REM-1123).
    v_tier text := coalesce(p_tier, 'agent');
begin
    select * into j from aiq.judgements where id = p_id;
    if not found then
        raise exception 'no judgement % you can see', p_id;
    end if;
    if j.status = 'decided' then
        if j.verdict - 'seen' = p_verdict
           or (j.kind = 'challenge' and j.verdict->>'decision' = p_verdict->>'decision'
               and (select array_agg(r->>'target' order by r->>'target')
                      from jsonb_array_elements(coalesce(j.verdict->'relations', '[]'::jsonb)) r)
                   is not distinct from
                   (select array_agg(r->>'target' order by r->>'target')
                      from jsonb_array_elements(case when jsonb_typeof(p_verdict->'relations') = 'array'
                                                     then p_verdict->'relations'
                                                     when p_verdict ? 'target' then jsonb_build_array(p_verdict)
                                                     else '[]'::jsonb end) r)) then
            return jsonb_build_object('id', j.id, 'status', j.status, 'verdict', j.verdict,
                                      'decided_by', j.decided_by, 'tier', j.tier, 'already', true) || j.result;
        end if;
        raise exception 'judgement % was already decided (%), by %', p_id, j.verdict, j.decided_by
            using hint = 'undo what it wrote (result: resolution_ids, distinction_ids) and queue it again';
    end if;
    if v_tier not in ('agent','human','llm','decision_model') then
        raise exception 'p_tier must be agent, human, llm or decision_model, not %', v_tier;
    end if;
    -- A CHALLENGE'S RELATE IS CARRIED OUT HERE, AS THE JUDGE. Each relation is
    -- claims.assert_relation from the challenged claim to the candidate, so the
    -- vocabulary's own rules decide whether it holds, an agent's lands proposed
    -- and only a person's lands confirmed; the guard then checks each id. The
    -- claim is checked first so nothing is asserted on an item the caller
    -- does not hold. One relation may be given as target/predicate/spans.
    if j.kind = 'challenge' and p_verdict->>'decision' = 'relate' then
        if not (j.status = 'claimed' and j.claimed_by = rbac.current_user_id()
                and j.lease_until > clock_timestamp()) then
            raise exception 'you do not hold a live claim on judgement %', p_id
                using hint = 'aiq.claim_judgement(p_id => ...) first; a lapsed lease must be claimed again';
        end if;
        v_rels := case when jsonb_typeof(p_verdict->'relations') = 'array' then p_verdict->'relations'
                       else jsonb_build_array(p_verdict - 'decision') end;
        if exists (select 1 from jsonb_array_elements(v_rels) r
                    where not exists (select 1 from jsonb_array_elements(j.evidence->'candidates') c
                                       where c->>'claim_id' = r->>'target'
                                         and research.revision_readable((c->>'revision_id')::uuid))) then
            raise exception 'a relate names candidates of this challenge, and % is not one you can read',
                (select string_agg(coalesce(r->>'target', 'a missing target'), ', ') from jsonb_array_elements(v_rels) r)
                using hint = 'claim_judgement lists them in evidence.candidates; if none bears on the claim, decide none';
        end if;
        -- WHAT THE WRITER'S AGENT MAY SETTLE (REM-1123): claims.settle_challenge says whether this answer settles
        -- the challenge, goes to the person as a suggestion, or is recorded as before.
        if v_tier = 'agent' then
            v_mode := claims.settle_challenge(p_id, p_verdict);
        end if;
    end if;
    if j.kind = 'challenge' and p_verdict->>'decision' = 'none' and v_tier = 'agent' then
        v_mode := claims.settle_challenge(p_id, p_verdict);
    end if;
    if v_mode->>'mode' = 'to_human' then
        update aiq.judgements
           set status = 'to_human', verdict = v_mode->'verdict', claimed_by = null, claimed_from = null,
               lease_until = null
         where id = p_id;
        return jsonb_build_object('id', p_id, 'status', 'to_human', 'suggested', p_verdict,
                                  'settle_at', v_mode->'settle_at');
    end if;
    if j.kind = 'challenge' and p_verdict->>'decision' = 'relate' then
        v_verdict := jsonb_build_object('decision', 'relate', 'relations', (
            select jsonb_agg(r.value || jsonb_build_object('relation_id', claims.assert_relation(
                       j.evidence->>'claim_key', r.value->>'predicate', c.value->>'claim_key',
                       (j.evidence->>'revision_id')::uuid, (c.value->>'revision_id')::uuid,
                       case when v_mode->>'mode' = 'settle' then 'settled' end, r.value->'spans',
                       p_reason)) order by r.ordinality)
              from jsonb_array_elements(v_rels) with ordinality r
              cross join lateral (select e.value from jsonb_array_elements(j.evidence->'candidates') e
                                   where e.value->>'claim_id' = r.value->>'target' limit 1) c));
    end if;
    if v_mode->>'mode' = 'settle' then
        perform claims.settle_challenge_done();
        v_verdict := v_verdict || jsonb_build_object('settled', true);
    end if;
    -- The confidence is kept whenever one is given, settled or not: settle_at is chosen from the confidences
    -- agents gave before it was set (claims.challenge_outcomes), and a relate's verdict is rebuilt above.
    if j.kind = 'challenge' and p_verdict ? 'confidence' then
        v_verdict := v_verdict || jsonb_build_object('confidence', p_verdict->'confidence');
    end if;
    -- A person deciding what the agent passed them keeps the agent's suggestion in the record.
    if j.kind = 'challenge' and j.verdict ? 'suggested' then
        v_verdict := v_verdict || jsonb_build_object('suggested', j.verdict->'suggested',
                                                     'suggested_by', j.verdict->'suggested_by');
    end if;
    if p_verdict->>'decision' = 'human' then
        if v_tier = 'human' then
            raise exception 'a person deciding uses bind, distinct or none';
        end if;
        update aiq.judgements
           set status = 'to_human', claimed_by = null, claimed_from = null, lease_until = null
         where id = p_id;
        return jsonb_build_object('id', p_id, 'status', 'to_human');
    end if;
    -- Distinct is recorded against the candidates the decider can see now.
    if p_verdict->>'decision' = 'distinct' then
        v_verdict := p_verdict || jsonb_build_object('seen', coalesce(
            (select jsonb_agg(c->'node_id') from jsonb_array_elements(j.evidence->'candidates') c
              where exists (select 1 from aiq.nodes n where n.id::text = c->>'node_id')), '[]'::jsonb));
    end if;
    update aiq.judgements
       set status = 'decided', verdict = v_verdict, reason = p_reason, tier = v_tier
     where id = p_id;
    select * into j from aiq.judgements where id = p_id;
    return jsonb_build_object('id', j.id, 'status', j.status, 'verdict', j.verdict,
                              'decided_by', j.decided_by, 'tier', j.tier) || coalesce(j.result, '{}'::jsonb);
end;
$$;

-- What waits, or what was decided, among the items the caller can see.
create or replace function aiq.list_judgements(p_status text default 'open', p_limit int default 50)
returns jsonb language sql stable set search_path = pg_catalog, public as $$
    select coalesce(jsonb_agg(x order by x->>'queued_at'), '[]'::jsonb) from (
        select jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status,
                                  'label', coalesce(j.evidence->>'label', j.evidence->>'key'),
                                  'claimed_kind', j.evidence->>'claimed_kind',
                                  'candidates', jsonb_array_length(coalesce(j.evidence->'candidates', '[]'::jsonb)),
                                  -- A challenge's candidates are claims, readable through their revision.
                                  'candidate_claims', case when j.kind = 'challenge' then coalesce((
                                      select jsonb_agg(jsonb_build_object('claim_id', c->'claim_id', 'claim_key', c->'claim_key',
                                                                          'text', c->'text', 'distance', c->'distance'))
                                        from jsonb_array_elements(j.evidence->'candidates') c
                                       where research.revision_readable((c->>'revision_id')::uuid)), '[]'::jsonb) end,
                                  -- The candidates themselves, as the caller may see
                                  -- them, so a judge can choose before claiming (bob, 20 Oct).
                                  'candidate_nodes', coalesce((
                                      select jsonb_agg(jsonb_build_object('node_id', c->'node_id', 'key', c->'key',
                                                                          'candidate', c->'candidate', 'summary', c->'summary'))
                                        from jsonb_array_elements(j.evidence->'candidates') c
                                       where exists (select 1 from aiq.nodes n where n.id::text = c->>'node_id')),
                                      '[]'::jsonb),
                                  'queued_at', j.queued_at, 'verdict', j.verdict, 'reason', j.reason,
                                  'decided_by', j.decided_by, 'tier', j.tier, 'decided_at', j.decided_at) as x
          from aiq.judgements j
         where j.status = coalesce(p_status, j.status)
         order by j.queued_at
         limit greatest(least(coalesce(p_limit, 50), 500), 1)) t;
$$;

-- The schedule, on the engine's own clock (workflow.schedules, ticked by
-- workflow.tick()). Not installed by default: like every other schedule here,
-- it is an operator's choice, and without the tick it would never fire anyway.
-- Re-running it changes the cron and keeps one schedule.
create or replace function aiq.schedule_dream(p_cron text default '*/15 * * * *',
                                              p_enabled boolean default true)
returns jsonb as $$
declare v_id uuid;
begin
    perform workflow.register_step_function('dream', 'aiq.dream', '{}', 300000,
        'reconcile the graph: supersede declared single-valued relations, promote exact soft nodes');
    perform workflow.define_yaml($y$
name: dream
steps:
  - id: reconcile
    sql: {function: dream, args: []}
$y$);
    select id into v_id from workflow.schedules where name = 'dream';
    if v_id is null then
        v_id := workflow.schedule_workflow('dream', 'dream', p_cron);
    else
        update workflow.schedules set cron_expr = p_cron where id = v_id;
    end if;
    perform workflow.set_schedule_enabled('dream', p_enabled);
    return jsonb_build_object('schedule', 'dream', 'cron', p_cron, 'enabled', p_enabled, 'id', v_id);
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 8b. "Not the same": the decision a resolver makes most often, recorded.
--
-- aiq.node_distinctions (ai-query-layer/schema.sql) holds it. A resolver that
-- judged a candidate against a node and said no calls this, and before asking
-- again filters its candidates on aiq.decided_distinct. Same attribution rules
-- as a promotion: no default decider, tier required. A repeat of a live
-- decision returns the existing row rather than adding a second.
-- ------------------------------------------------------------
create or replace function aiq.record_distinct(p_node uuid, p_other uuid,
                                               p_decided_by text, p_tier text,
                                               p_evidence jsonb default '{}'::jsonb)
returns uuid as $$
declare v_id uuid;
begin
    if coalesce(btrim(p_decided_by), '') = '' then
        raise exception 'record_distinct needs p_decided_by: the resolver version, agent id or user id';
    end if;
    if p_node = p_other then
        raise exception 'a node is not distinct from itself';
    end if;
    if not exists (select 1 from aiq.nodes where id = p_node)
       or not exists (select 1 from aiq.nodes where id = p_other) then
        raise exception 'both nodes must exist to be decided distinct';
    end if;
    -- Already one thing: saying they are two would contradict the ledger.
    if (select current_id from aiq.node_current where node_id = p_node)
       = (select current_id from aiq.node_current where node_id = p_other) then
        raise exception 'nodes % and % are resolved to the same node', p_node, p_other
            using hint = 'aiq.unresolve_node the merge first if it was wrong.';
    end if;
    select id into v_id from aiq.node_distinctions
     where a_id = least(p_node, p_other) and b_id = greatest(p_node, p_other)
       and undone_at is null;
    if v_id is not null then
        return v_id;
    end if;
    insert into aiq.node_distinctions (a_id, b_id, tier, decided_by, evidence, org_id)
    values (least(p_node, p_other), greatest(p_node, p_other), p_tier, p_decided_by,
            p_evidence || jsonb_build_object('node', p_node),
            (select org_id from aiq.nodes where id = p_node))
    returning id into v_id;
    return v_id;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- Undone, never deleted: a "not the same" that turned out wrong is evidence
-- about the resolver that made it.
create or replace function aiq.undo_distinct(p_id uuid, p_by text)
returns void as $$
begin
    if coalesce(btrim(p_by), '') = '' then
        raise exception 'undo_distinct needs p_by';
    end if;
    update aiq.node_distinctions
       set undone_at = now(), evidence = evidence || jsonb_build_object('undone_by', p_by)
     where id = p_id and undone_at is null;
    if not found then
        raise exception 'no live distinction %', p_id;
    end if;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

-- ------------------------------------------------------------
-- 8c. What a resolver is asked to decide: candidates and their proposals.
--
-- A resolver (percolate_core.resolve, `percolate resolve serve`) runs as
-- `worker`, which holds no table grants, so the question it puts to a decision
-- model has to come from here. Each row is one (candidate, registered node)
-- pair: up to p_k nodes of the target type per unresolved candidate, by trigram
-- similarity of their keys. A candidate with nothing to propose comes back once
-- with a null node_id, so a page is never silently short.
--
-- PAGED BY KEYSET, p_after = the last soft_id of the previous page. soft_nodes
-- ids are uuidv7, so this is also oldest first. An "oldest p_limit" window
-- without it starves: candidates with nothing to propose stay unresolved, stay
-- oldest, and fill every page.
--
-- PROPOSING IS LOOSE ON PURPOSE. 0.30 is far below resolve_mention's 0.62
-- because this proposes and does not decide; the measured run that set it found
-- the true company among the proposals for 279 of 285 candidates whose company
-- existed (a spike, 30 September).
--
-- Two exclusions, both refusals rather than preferences:
--   * a pair already decided distinct (aiq.decided_distinct) is not proposed
--     again, which is the point of recording it -- and it is removed from the
--     top p_k, not replaced by the next proposal;
--   * a node outside the candidate's org and the shared tier is never
--     proposed. This is SECURITY DEFINER, so it reads past row security, and a
--     tenant's candidate matched against another tenant's company would hand
--     the resolver -- and the model -- that company's name.
-- The target type defaults to the claimed kind, which is what upsert_graph
-- records when a kind names a registered type and the name does not resolve.
-- ------------------------------------------------------------
-- The summary half of the proposal is served by this index; without it every
-- candidate scans aiq.nodes.
create index if not exists idx_nodes_summary_trgm
    on aiq.nodes using gin (lower(summary) gin_trgm_ops);

create or replace function aiq.resolution_candidates(
    p_claimed_kind text default null, p_entity_type text default null,
    p_after uuid default null, p_limit int default 50, p_k int default 5,
    p_min_sim real default 0.3)
returns table(soft_id uuid, candidate_node_id uuid, name text, attrs jsonb,
              node_id uuid, node_key text, entity_type text, summary text, sim real)
-- No `set pg_trgm.similarity_threshold` clause: an upgrade's ALTER EXTENSION is
-- refused it ("permission denied to set parameter"), though a fresh install is
-- not. `%` uses the session's threshold, 0.3 by default, which is also this
-- function's floor; resolve_mention relies on the same default.
language sql stable security definer
set search_path = pg_catalog, public
as $$
    with pending as (
        select s.id, cn.id as cand, s.key, coalesce(s.label, s.key) as label, s.attrs,
               coalesce(p_entity_type, s.claimed_kind) as target, cn.org_id
          from aiq.soft_nodes s
          join aiq.nodes cn on cn.entity_type = 'soft' and cn.entity_id = s.id
         where s.resolved_node_id is null
           and (p_claimed_kind is null or s.claimed_kind = p_claimed_kind)
           and (p_after is null or s.id > p_after)
         order by s.id
         limit greatest(p_limit, 0))
    select p.id, p.cand, p.label, p.attrs, m.node_id, m.key, m.entity_type, m.summary, m.sim
      from pending p
      left join lateral (
        -- Best match per node first (a node answers to several keys, and to its
        -- summary), then the top p_k.
        --
        -- THE SUMMARY TOO, because a key is not always a name. A document is
        -- keyed by its URL and named only in its summary, so on production --
        -- where documents were the one registered type -- matching keys alone
        -- could never propose a document by its title (1 October 2026).
        select * from (
            select distinct on (m.node_id) m.* from (
                select n.id as node_id, k.key, n.entity_type, n.summary,
                       similarity(k.key, p.key) as sim
                  from aiq.node_keys k
                  join aiq.nodes n on n.id = k.node_id
                 where k.key % p.key
                   and n.entity_type = p.target
                   and n.org_id in (rbac.shared_org_id(), p.org_id)
                union all
                select n.id, null, n.entity_type, n.summary,
                       similarity(lower(n.summary), p.key)
                  from aiq.nodes n
                 where lower(n.summary) % p.key
                   and n.entity_type = p.target
                   and n.org_id in (rbac.shared_org_id(), p.org_id)) m
             where m.sim >= greatest(p_min_sim, 0.3)
             order by m.node_id, m.sim desc) best
         order by best.sim desc
         limit greatest(p_k, 1)) m
        -- Decided pairs are dropped AFTER the top p_k is chosen, not before, so
        -- a re-run proposes nothing new unless the registry changed. Dropping
        -- them first made each pass slide to the next p_k: 259 more pairs on a
        -- second pass over unchanged data, for one more match. Recall is p_k's.
        on not aiq.decided_distinct(p.cand, m.node_id)
     order by p.id, m.sim desc nulls last;
$$;

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
revoke execute on function aiq.close_edge(jsonb, timestamptz, jsonb)        from public;
revoke execute on function aiq.land_graph(jsonb, uuid)                     from public;
revoke execute on function aiq.land_graph_fanout(uuid)                     from public;
revoke execute on function aiq.promote_soft_node(uuid, uuid, text, text, jsonb) from public;
revoke execute on function aiq.record_distinct(uuid, uuid, text, text, jsonb) from public;
revoke execute on function aiq.undo_distinct(uuid, text)                   from public;
revoke execute on function aiq.resolution_candidates(text, text, uuid, int, int, real) from public;
revoke execute on function aiq.register_graph_vocabulary(jsonb)            from public;
revoke execute on function aiq.install_structure_null(text)                from public;
-- Dream reconciles every owner's graph, so it is the engine's (a registered
-- sql step runs as the engine owner) and an operator's, never a user's.
revoke execute on function aiq.dream(timestamptz, text)                    from public;
revoke execute on function aiq.schedule_dream(text, boolean)               from public;
revoke execute on function aiq.soft_bind_evidence(uuid)                    from public;
revoke execute on function aiq.enqueue_soft_judgements(uuid[], text)       from public;
-- The two triggers run when the table is written; nobody calls them.
revoke execute on function aiq.judgements_guard()                          from public;
revoke execute on function aiq.judgements_apply()                          from public;
-- The four a judge calls, as themselves: SECURITY INVOKER, under the table's
-- row policy and its guard trigger (see JUDGEMENTS).
revoke execute on function aiq.judgement_for_judge(uuid)                   from public;
revoke execute on function aiq.judgement_said(uuid, int)                   from public;
revoke execute on function aiq.claim_judgement(text[], uuid, interval)     from public;
revoke execute on function aiq.release_judgement(uuid)                     from public;
revoke execute on function aiq.complete_judgement(uuid, jsonb, text, text) from public;
revoke execute on function aiq.list_judgements(text, int)                  from public;
grant execute on function aiq.judgement_for_judge(uuid)                   to authenticated;
grant execute on function aiq.judgement_said(uuid, int)                   to authenticated;
grant execute on function aiq.claim_judgement(text[], uuid, interval)     to authenticated;
grant execute on function aiq.release_judgement(uuid)                     to authenticated;
grant execute on function aiq.complete_judgement(uuid, jsonb, text, text) to authenticated;
grant execute on function aiq.list_judgements(text, int)                  to authenticated;

grant execute on function aiq.upsert_graph(jsonb, jsonb)      to worker;
grant execute on function aiq.close_edge(jsonb, timestamptz, jsonb) to worker;
grant execute on function aiq.land_graph(jsonb, uuid)         to worker;
grant execute on function aiq.land_graph_fanout(uuid)         to worker;
-- promote_soft_node is entity resolution's write path, which is background
-- work, not a user action -- so it is worker-facing too.
grant execute on function aiq.promote_soft_node(uuid, uuid, text, text, jsonb) to worker;
-- Its other half, on the same reasoning.
grant execute on function aiq.record_distinct(uuid, uuid, text, text, jsonb) to worker;
grant execute on function aiq.undo_distinct(uuid, text)                   to worker;
grant execute on function aiq.resolution_candidates(text, text, uuid, int, int, real) to worker;

-- The read helpers are SECURITY INVOKER, so a user calling them is filtered by
-- their own policies and the grant is safe.
grant execute on function aiq.resolve_ref(text, text, boolean, real, uuid, text, uuid)
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

-- A PRIVATE CANDIDATE IS ITS OWNER'S, AND THE KEY SAYS SO (REM-962).
--
-- owner_scope is the owner of a private candidate and NULL for an org or a
-- public one, so the identity index keeps one node per scope for those and one
-- per owner for private memory. GENERATED, so no writer can set it out of step
-- with the scope it describes, and here rather than beside the tables because
-- it reads the columns add_scope_columns() adds just above. Each index is
-- re-created only while it lacks the column, so a replay leaves it alone.
alter table aiq.soft_nodes add column if not exists owner_scope uuid
    generated always as (case when visibility = 'private' then owner_id end) stored;
alter table aiq.lake_nodes add column if not exists owner_scope uuid
    generated always as (case when visibility = 'private' then owner_id end) stored;
do $$
begin
    if exists (select 1 from pg_indexes where schemaname = 'aiq'
                and indexname = 'idx_soft_nodes_key' and indexdef not like '%owner_scope%') then
        drop index aiq.idx_soft_nodes_key;
    end if;
    if exists (select 1 from pg_indexes where schemaname = 'aiq'
                and indexname = 'idx_lake_nodes_key' and indexdef not like '%owner_scope%') then
        drop index aiq.idx_lake_nodes_key;
    end if;
end $$;
create unique index if not exists idx_soft_nodes_key
    on aiq.soft_nodes (org_id, claimed_kind, key, owner_scope) nulls not distinct;
create unique index if not exists idx_lake_nodes_key
    on aiq.lake_nodes (org_id, dataset, row_key, owner_scope) nulls not distinct;

-- RE-PROJECTED WHERE A NODE'S SCOPE DIFFERS FROM ITS ROW'S, which is what the
-- registration change above leaves behind on an existing database (REM-962):
-- the trigger it regenerates projects the next write, not the rows already
-- there. Gated on that drift rather than run on every replay, because a
-- rebuild is a pass over every candidate and a converged database has nothing
-- for it to correct. After add_scope_columns, because the projection reads the
-- column it adds. A candidate written before the fix keeps the scope it was
-- written at, which for a no-org memory was `public`; its facts are gated
-- through their source regardless (§10a).
do $$
begin
    if exists (select 1 from aiq.nodes nd join aiq.soft_nodes n on n.id = nd.entity_id
                where nd.entity_type = 'soft' and nd.visibility is distinct from n.visibility) then
        perform aiq.rebuild_entity_type('soft');
    end if;
    if exists (select 1 from aiq.nodes nd join aiq.lake_nodes n on n.id = nd.entity_id
                where nd.entity_type = 'lake' and nd.visibility is distinct from n.visibility) then
        perform aiq.rebuild_entity_type('lake');
    end if;
end $$;

-- ------------------------------------------------------------
-- 10a. A fact is read through the memory it came from (REM-962).
--
-- An edge used to be readable whenever both its endpoints were, and that is
-- not enough once a candidate's NAME can be public while a fact about it is
-- private: "peanuts" is a public word, and Maya's allergy to it is hers. So an
-- edge is now also gated through its provenance. Every source that names a
-- resource is a memory the fact was read out of, and the caller reads the fact
-- when they may read ANY of them -- which is what an edge merged from two
-- memories needs, and what Leo's own "lives in Leeds" needs when Maya said it
-- first. A source with no resource (an authored edge, reference data, a run's
-- own output) gates nothing, which leaves every edge written before this
-- behaving as it did.
--
-- At read time and in the policy, rather than as a scope stamped on the row at
-- write time, because the row is shared and its sources are not: a stamp would
-- have to be the widest of them (publishing the private one) or the narrowest
-- (hiding the public one from its own author). And because the resource's
-- scope is the truth, a memory made private or deleted later takes its facts
-- with it, with nothing to re-project.
--
-- content.resources is read AS THE CALLER, so its own policy is the whole
-- decision; this function adds no rule of its own. SQL rather than plpgsql so
-- the planner inlines it into the policy. A resource_id that is not a uuid
-- matches nothing rather than raising, because an error inside a read policy
-- fails every read of the table.
--
-- Defined here and not beside nodes' policy in ai-query-layer/integration-rbac.sql,
-- because that file is assembled before the content plane exists; that file
-- says so where the policy used to be.
-- Whether the caller may read a session, by the scope rule its own policy
-- applies. DEFINER, because a caller holds no grant on agentic.sessions (they
-- read sessions_api), and a policy runs its functions as the caller.
create or replace function agentic.session_readable(p_session uuid) returns boolean
language sql stable security definer set search_path = pg_catalog, public as $$
    select coalesce((select rbac.may_read(se.owner_id, se.org_id, se.visibility)
                       from agentic.sessions se where se.id = p_session), false);
$$;
grant execute on function agentic.session_readable(uuid) to authenticated, api_viewer;

create or replace function aiq.edge_sources_readable(p_provenance jsonb)
returns boolean as $$
    -- CASE, not OR, because OR promises no order and both array functions
    -- raise on a `sources` that is not an array.
    select case
        when jsonb_typeof(p_provenance->'sources') is distinct from 'array' then true
        when jsonb_array_length(p_provenance->'sources') = 0 then true
        else exists (
            select 1
              from jsonb_array_elements(p_provenance->'sources') s
             where not (s ? 'resource_id' or s ? 'session_id')
                or exists (select 1 from content.resources r
                            where r.id = case when pg_input_is_valid(s->>'resource_id', 'uuid')
                                              then (s->>'resource_id')::uuid end)
                -- A conversation gates what was said in it, by the session's
                -- own rule (REM-969).
                or agentic.session_readable(case when pg_input_is_valid(s->>'session_id', 'uuid')
                                                 then (s->>'session_id')::uuid end))
    end;
$$ language sql stable parallel safe;
comment on function aiq.edge_sources_readable(jsonb) is
    'True when the caller may read some memory an edge was read out of, or it names none.';
-- Every role the policy reads edges for, and no other: a policy calls its
-- functions as the caller.
grant execute on function aiq.edge_sources_readable(jsonb) to authenticated, api_viewer;

drop policy if exists edges_via_endpoints on aiq.edges;
create policy edges_via_endpoints on aiq.edges for select
  using (exists (select 1 from aiq.nodes s where s.id = aiq.edges.src_id)
     and exists (select 1 from aiq.nodes d where d.id = aiq.edges.dst_id)
     and aiq.edge_sources_readable(aiq.edges.provenance));

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
