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
--   GRAPH depth 1    -> a join over aiq.edges_current, both directions
--   GRAPH depth n>1  -> WITH RECURSIVE over edges_current. No SQL/PGQ: it was
--                       withdrawn from PostgreSQL 19 before GA, and the
--                       extension runs on 18 (section 5 says what that cost).
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
create table if not exists aiq.nodes (
    id           uuid primary key default uuidv7(),
    entity_type  text not null,          -- owning table, e.g. 'company'
    entity_id    uuid not null,          -- PK in that table
    -- The tenant. NOT NULL, defaulted to rbac.shared_org_id() by
    -- rbac.adopt_shared_org() in integration-rbac.sql -- said there rather
    -- than here because that function lives in user-rbac, which is installed
    -- after this file. `null = shared reference data` is what this column used
    -- to mean and identity/spec.md §4 is why it stopped: a NULL may only mean
    -- unknown, and the shared tier is a value.
    org_id       uuid,
    summary      text,                   -- cheap human/agent-readable label
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (entity_type, entity_id)
);
comment on table aiq.nodes is
    'A thing the graph can reach, projected from whatever table actually owns it, carrying the owner and visibility it inherits from there.';
create index if not exists idx_nodes_org on aiq.nodes (org_id);

create or replace trigger trg_nodes_touch before update on aiq.nodes
    for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------
-- 2. Keys — how humans, agents and the query dialect NAME a node.
--    Not the edge foreign key (that is nodes.id, graph-identity.md D3).
--    entity_type is copied here so the unique index needs no join.
-- ------------------------------------------------------------
create table if not exists aiq.node_keys (
    node_id      uuid not null references aiq.nodes(id) on delete cascade,
    entity_type  text not null,
    key          text not null,          -- normalized (lowercased, trimmed)
    kind         text not null check (kind in ('canonical','short','alias')),
    -- Copied from the node, and NOT NULL for the same reason nodes.org_id is
    -- -- see integration-rbac.sql §2, where this table's adopt_shared_org()
    -- call lives. It is not declared `not null` here because a `create table
    -- if not exists` does nothing to a database that already has the table,
    -- so the constraint would reach fresh installs only.
    org_id       uuid,
    primary key (node_id, key, kind)
);
comment on table aiq.node_keys is
    'The names a node answers to — its identifiers and aliases — so a mention can be resolved without scanning summaries.';

-- `kind` HERE IS THE KEY'S CLASS, not the thing's kind, and the distinction is
-- worth a comment because the neighbouring table spends the same word on the
-- other meaning: aiq.soft_nodes.claimed_kind is 'company' or 'person', while
-- this one is always one of canonical/short/alias. A consumer filtering
-- entities on aiq.node_keys.kind gets 'canonical' for every row, filters
-- nothing, and gets no error -- which is how a real identity pass clustered a
-- company with a product. Neither name is wrong in isolation; the collision is
-- obvious once and invisible before, so it is written down at both ends.
comment on column aiq.node_keys.kind is
    'The KEY''s class: canonical, short or alias. Not the entity''s kind -- '
    'that is aiq.soft_nodes.claimed_kind for a candidate, and the entity_type '
    'of the registered table for anything resolved.';
comment on column aiq.nodes.entity_type is
    'Where the node LIVES -- soft, lake, document, or a registered entity '
    'type. Residence, never a claimed kind: everything the null extractor '
    'produces is ''soft'' whatever it claims to be.';
-- Canonical keys are unique per (org, type). Short keys and aliases are
-- deliberately NOT unique -- 'bakhmut' may be canonical for a place and an
-- event, and short-key lookup may legitimately return several nodes.
--
-- NULLS NOT DISTINCT IS NOW A NO-OP, AND IT IS KEPT DELIBERATELY.
--
-- It was the whole guarantee. org_id IS NULL meant shared reference data,
-- which integration-rbac.sql §1 calls "a real category here, not a loophole"
-- and which every public company in a deployment will be. Under the default
-- NULLS DISTINCT two NULLs never conflict -- so this index enforced
-- canonical-key uniqueness for exactly the tenants that have one and not at
-- all for the shared tier. Measured: two companies both took the canonical key
-- 'acme', and LOOKUP "ACME" -- the dialect's most common call, documented as
-- an exact match -- returned two different nodes with no way to tell which was
-- meant.
--
-- org_id is NOT NULL now (identity/spec.md §4, rbac.adopt_shared_org), so the
-- flag decides nothing: there are no NULLs left for it to be distinct or not
-- distinct about, and the shared tier is constrained by the same equality as
-- every other org. It stays because dropping it would be a rewrite of a unique
-- index on every deployment to change nothing, and because a reader arriving
-- at NULLS NOT DISTINCT with no note has to work out for themselves whether it
-- is load-bearing. It is not. Anything that makes org_id nullable again makes
-- it load-bearing again.
--
-- AND owner_scope MADE IT LOAD-BEARING AGAIN (REM-962). A thing named in a
-- PRIVATE memory is its owner's node, so two owners naming "Leeds" on one tier
-- hold two nodes with one canonical key -- one shared node meant the second
-- owner's facts landed on a node only the first could read, and Leo lost five
-- of his eight. owner_scope is the node's owner when the node is private and
-- NULL otherwise, so org and public scopes keep one node per key, and for them
-- NULLS NOT DISTINCT is the whole constraint once more. Copied from the node by
-- every writer, as org_id is, so the index needs no join.
alter table aiq.node_keys add column if not exists owner_scope uuid;
do $$
begin
    if exists (select 1 from pg_indexes
                where schemaname = 'aiq' and indexname = 'idx_node_keys_canonical'
                  and indexdef not like '%owner_scope%') then
        drop index aiq.idx_node_keys_canonical;
    end if;
end $$;
create unique index if not exists idx_node_keys_canonical
    on aiq.node_keys (org_id, key, entity_type, owner_scope) nulls not distinct
    where kind = 'canonical';
create index if not exists idx_node_keys_lookup on aiq.node_keys (key);
-- AND THE SAME KEY FOLDED, because the exact tier asks for it folded and this
-- is the tier meant to be cheap. `aiq.resolve_mention` normalises its argument
-- to `lower(btrim(...))` and then filters `lower(k.key) = v_norm` at three
-- sites (resolution.sql, the exact match, the ambiguous escalation and the
-- suffix probe). A b-tree on `key` cannot serve a predicate on `lower(key)`,
-- and the trigram index answers similarity rather than equality -- so the
-- FIRST and cheapest tier of resolution was the one that scanned, and its cost
-- grew with the whole key table instead of with the number of candidates.
--
-- MEASURED on 50,026 keys, the exact-match query from resolution.sql:
--
--   without this index   Seq Scan, 50,025 rows removed by filter, 569 buffers
--   with it              Index Scan, 3 buffers
--
-- An expression index rather than folding the column on write, and the reason
-- is `idx_node_keys_canonical` directly above: it is unique on `(org_id, key,
-- entity_type)` with `key` case-sensitive, so `Apple` and `apple` are today two
-- distinct canonical keys. Folding on write would collide them -- a change to
-- what the table permits, not a change to how it is read.
create index if not exists idx_node_keys_key_lower on aiq.node_keys (lower(key));
-- A SOFT NODE BY ITS BARE NAME (REM-995). A soft node's only canonical key is
-- `<kind>/<name>` -- 'project/harbour rewrite' -- so `LOOKUP "Harbour Rewrite"`
-- found nothing, and a reader had to know a kind prefix they were never shown.
-- aiq.lookup's soft step asks for the name after the first slash; this is the
-- index it asks, so the step costs a probe and not a scan of every key.
create index if not exists idx_node_keys_soft_name
    on aiq.node_keys (lower(substr(key, strpos(key, '/') + 1)))
    where kind = 'canonical' and entity_type = 'soft';
-- FUZZY lives here and ONLY here: a trigram index on this thin key table,
-- never on the data plane (graph-identity.md "Scale").
create index if not exists idx_node_keys_trgm on aiq.node_keys using gin (key gin_trgm_ops);

-- ------------------------------------------------------------
-- 3. Relation catalogue — every allowed (src_type, relation, dst_type).
--    Out-of-catalogue relations are rejected at write, so the graph cannot
--    accumulate typos-as-relations (graph-identity.md "Catalogue").
-- ------------------------------------------------------------
create table if not exists aiq.relation_types (
    src_type   text not null,
    relation   text not null,
    dst_type   text not null,
    inverse_label text,                  -- read-time inverse; NOT a stored edge
    description   text,
    -- A symmetric relation has no direction to lose, so it is stored once, in
    -- a canonical endpoint order (see the trigger below). Without this, both
    -- (a,b) and (b,a) satisfy the unique index and every consumer dedupes by
    -- hand -- and any degree-based algorithm over the graph double-counts the
    -- pair, which is not a cosmetic problem: personalised PageRank gives such
    -- a neighbour twice its share of the mass and k-core reads the degree as
    -- two. Declared per triple because that is this table's key, but it is a
    -- property of the TERM: the trigger reads it with bool_or over the term,
    -- and a term marked symmetric in one triple and not another is a
    -- modelling error rather than a supported state -- which the two triggers
    -- below now make it, instead of leaving it as prose in this comment.
    --
    -- NULLABLE, and that is the whole reason the inheritance below can work.
    -- `not null default false` made a writer that DID NOT SAY and a writer
    -- that said false the same row, so there was nothing for a new triple to
    -- inherit and nothing a disagreement check could distinguish. That is the
    -- same defect aiq.graph_vocabulary.machine_weight had -- a default applied
    -- at write, erasing the difference between an absent value and an explicit
    -- one -- and it is worth naming twice because it reads as a tightening
    -- both times. null means UNDECLARED; every reader coalesces to false, so
    -- the effective default is unchanged.
    --
    -- Named `is_symmetric`, not `symmetric`: SYMMETRIC is a reserved word in
    -- SQL (it belongs to BETWEEN), so the obvious spelling is a column that
    -- has to be double-quoted at every single use site forever.
    is_symmetric boolean,
    primary key (src_type, relation, dst_type)
);
comment on table aiq.relation_types is
    'The typed relations the graph admits, with their inverses and whether each is symmetric.';

-- ...and on a database that already has the table, where `create table if not
-- exists` above is a no-op and the column is still NOT NULL. Guarded for the
-- same reason agentic.sessions' rename is: this file is replayed on every
-- upgrade, and DROP NOT NULL has no IF EXISTS to make the second run a no-op.
-- (It is idempotent in effect -- dropping a constraint that is already gone
-- succeeds -- but the guard keeps the intent legible next to the column.)
do $$
begin
    if exists (select 1 from information_schema.columns
                where table_schema = 'aiq' and table_name = 'relation_types'
                  and column_name = 'is_symmetric' and is_nullable = 'NO') then
        alter table aiq.relation_types alter column is_symmetric drop not null;
        alter table aiq.relation_types alter column is_symmetric drop default;
    end if;
end $$;

-- ------------------------------------------------------------
-- 3a. is_symmetric and inverse_label are properties of the RELATION, and this
--     table is keyed by the TRIPLE. Two triggers reconcile that, and which one
--     fires is decided by whether the writer said anything at all.
--
-- THE RULE THIS IMPLEMENTS is graph-identity.md's own, applied to the
-- catalogue rather than to the edge: "a rule the writer has to know before it
-- can insert is a rule every writer gets wrong once". A term-level fact stored
-- per triple gives every writer of a NEW triple a fact to repeat, and the
-- writers in this tree demonstrate the failure rather than merely risking it:
-- dev/scale/graph/01-generate.sql catalogues `owns` and `mentions` over
-- scale_entity naming neither column, and dev/init/04-graph-sample.sql
-- catalogues `competes_with` and `knows` with a description that SAYS
-- symmetric and a flag that says nothing. Refusing all three would be correct
-- and useless.
--
-- So: absence INHERITS, and disagreement is REFUSED.
--   * A row that leaves either column null takes the term's value, if the term
--     has one. The scale generator keeps working and its `owns` triples get
--     `owned_by` without naming it.
--   * A row that names a value differing from the term's raises. That is the
--     modelling error the column comment has always described, and it is now
--     the database that says so rather than a reader of this file.
--
-- Statement-level for the check, with a transition table, so the cost is one
-- pass over the terms this statement touched rather than over the catalogue --
-- and so a pre-existing split somewhere else in the table cannot fail an
-- unrelated insert, which is how a global assertion becomes a mystery.
-- ------------------------------------------------------------
create or replace function aiq.relation_term_inherit() returns trigger as $$
declare
    v_sym boolean;
    v_inv text;
begin
    if new.is_symmetric is null or new.inverse_label is null then
        select bool_or(rt.is_symmetric), min(rt.inverse_label)
          into v_sym, v_inv
          from aiq.relation_types rt
         where rt.relation = new.relation
           and (rt.src_type, rt.dst_type) is distinct from (new.src_type, new.dst_type);
        if new.is_symmetric is null then
            new.is_symmetric := v_sym;
        end if;
        if new.inverse_label is null then
            new.inverse_label := v_inv;
        end if;
    end if;
    return new;
end $$ language plpgsql;

create or replace trigger relation_types_inherit_term
    before insert or update on aiq.relation_types
    for each row execute function aiq.relation_term_inherit();

create or replace function aiq.check_relation_term() returns trigger as $$
declare v_bad text;
begin
    select string_agg(format('%s (%s)', s.relation, s.saw), '; ' order by s.relation)
      into v_bad
      from (select rt.relation,
                   string_agg(distinct coalesce(rt.is_symmetric::text, 'null')
                              || '/' || coalesce(rt.inverse_label, 'null'), ', ') as saw
              from aiq.relation_types rt
             where rt.relation in (select t.relation from touched t)
             group by rt.relation
            having count(distinct rt.is_symmetric) > 1
                or count(distinct rt.inverse_label) > 1) s;
    if v_bad is not null then
        raise exception
            'these relations declare symmetry or an inverse differently on '
            'different triples: %', v_bad
        using hint =
            'is_symmetric and inverse_label describe the RELATION, not the '
            '(src_type, relation, dst_type) triple this table is keyed by. '
            'aiq.check_edge_catalogue reads symmetry with bool_or over the '
            'term, so a split term means an edge normalises or does not '
            'depending on which types are at its ends -- a wrong number rather '
            'than an error. Leave the column null to inherit the term''s value.';
    end if;
    return null;
end $$ language plpgsql;

-- TWO TRIGGERS, ONE FUNCTION, because `referencing new table` is refused on a
-- trigger with more than one event: "transition tables cannot be specified for
-- triggers with more than one event". The alternative -- dropping the
-- transition table and re-scanning the catalogue on every statement -- would
-- also let a pre-existing split somewhere else in the table fail an unrelated
-- insert, so the split pair is the better shape as well as the legal one.
create or replace trigger relation_types_term_consistent_ins
    after insert on aiq.relation_types
    referencing new table as touched
    for each statement execute function aiq.check_relation_term();

create or replace trigger relation_types_term_consistent_upd
    after update on aiq.relation_types
    referencing new table as touched
    for each statement execute function aiq.check_relation_term();

-- ------------------------------------------------------------
-- 4. Edges — canonical store for SOFT (authored) links only.
--    Hard FK/junction relationships are NEVER copied here (D4).
-- ------------------------------------------------------------
create table if not exists aiq.edges (
    id          uuid primary key default uuidv7(),
    src_id      uuid not null references aiq.nodes(id) on delete cascade,
    dst_id      uuid not null references aiq.nodes(id) on delete cascade,
    relation    text not null,
    weight      real not null default 1.0,
    -- BITEMPORAL, and `valid_from` defaults so that it is actually populated.
    -- It did not, and the consequence was that the pair was half built: every
    -- one of 9,502 edges carried a null `valid_from`, so a retraction could be
    -- dated against nothing and "when was this first asserted" had no answer.
    -- An edge inserted now holds from now; anything else is the writer's job
    -- to state explicitly, which is what a default is for.
    valid_from  timestamptz not null default now(),
    -- Null means "still holds". Set it to retract rather than deleting the
    -- row: a derivation that DELETEs what it can no longer derive leaves
    -- nothing to audit, and an append-only graph with no retraction path is
    -- the regime research-notes/build-knit-dream-theory.pdf §10 warns about.
    -- Read through `aiq.edges_current` unless you want retracted history.
    valid_to    timestamptz,
    provenance  jsonb not null default '{}'::jsonb,
    -- Authoring provenance, not read gating (integration-rbac.sql §3). NOT
    -- NULL and defaulted to the shared tier by adopt_shared_org() there.
    org_id      uuid,
    created_at  timestamptz not null default now(),
    -- WHAT HAS ACTUALLY BEEN USED, as opposed to what merely still holds.
    --
    -- A read path that answers a real question calls `aiq.note_recall()` with
    -- the edges it traversed. Consolidation can then distinguish an edge that
    -- is stale from one that is stale AND load-bearing, which nothing else in
    -- this schema can express.
    --
    -- PROBES ARE COUNTED SEPARATELY AND NEVER MERGED IN. A system that
    -- consolidates on usage and cannot tell its own monitoring from real
    -- traffic will consolidate around its monitoring. The two counters exist
    -- rather than one flag because a flag can be forgotten silently, which was
    -- measured: `set local` outside a transaction warns and does nothing, and
    -- the probe counted as use.
    recall_count     bigint not null default 0,
    probe_count      bigint not null default 0,
    last_recalled_at timestamptz,
    unique (src_id, dst_id, relation)
);
comment on table aiq.edges is
    'A directed, typed, provenanced link between two nodes, valid over an interval, counting how often it has been recalled.';
-- Forward and REVERSE both indexed: "what points at this?" is first-class,
-- and the inverse edge is never stored (graph-identity.md "Edge table").
create index if not exists idx_edges_src on aiq.edges (src_id);
create index if not exists idx_edges_dst on aiq.edges (dst_id);
create index if not exists idx_edges_relation on aiq.edges (relation);

-- EDGES THAT HOLD NOW. One named place for "currently asserted", because the
-- alternative is every caller remembering a predicate and most of them not
-- remembering it.
--
-- This table has been bitemporal since it was written and, for months,
-- decoratively so: `valid_to` was never set on any edge, and the derivations
-- that maintain the graph DELETEd what they could no longer derive. A graph
-- that forgets by deletion does not forget slowly. It forgets completely,
-- leaving nothing to audit and nothing able to answer "was this ever true".
--
-- Two consequences that are now contract rather than convention:
--
--   A derivation RETRACTS by setting `valid_to`. It does not delete. Deleting
--   is for a row that should never have existed; retraction is for one that
--   held and no longer does, and those are different facts.
--
--   A reader that means "now" reads this view. `aiq.edges` is the full
--   history including retracted intervals, and reading it raw while meaning
--   "now" is the bug this view exists to make hard.
--
-- Measured consequence, recorded because it is the argument: consolidation
-- cannot be evaluated at all without dated edges. "Does this consolidation
-- anticipate what happened next" needs a `next`, and a graph rebuilt by
-- delete-and-reinsert has no history to hold one out of.
--
-- COLUMNS NAMED, not `select *`. A view's column list is fixed when it is
-- created and `create or replace` refuses to widen it, so a `select *` view
-- silently stops reflecting the table the moment a column is added. Measured:
-- the recall counters above were invisible through this view until it was
-- recreated, and a function that plainly selected one failed with "column does
-- not exist".
--
-- ONE RULE FOR "DOES THIS EDGE HOLD AT t", and it is this function. There
-- were four: this view said `valid_to is null or valid_to > now()`, catalogue,
-- reliability, standing and the ingestion upsert said `valid_to is null`, the
-- compiled traversals applied a window only when a caller passed `as_of`, and
-- graph_neighbors, graph_walk and a since-removed property graph applied none -- so a
-- retracted edge went on answering every walk and every GRAPH query while
-- this view, the one place anybody looked, correctly hid it (REM-51).
-- Immutable and SQL, so the planner inlines it and a view that calls it costs
-- what the predicate written out would.
create or replace function aiq.edge_is_current(
    p_valid_from timestamptz, p_valid_to timestamptz, p_at timestamptz)
returns boolean language sql immutable parallel safe as $$
    select (p_valid_from is null or p_valid_from <= p_at)
       and (p_valid_to   is null or p_valid_to   >  p_at)
$$;
comment on function aiq.edge_is_current(timestamptz, timestamptz, timestamptz) is
    'Whether an edge with this validity holds at p_at. The one currency rule: '
    'every read of "edges that hold" goes through it.';

-- SECURITY INVOKER, and it was not. The view ran as its owner, app_owner owns
-- aiq.edges, and a table's owner bypasses its policies -- so `authenticated`
-- reading this view saw every org's edges. Recorded as a hazard in
-- meta/postmortems/2026-09-08-what-the-move-made-visible.md §2 and left,
-- because every edge then carried the shared org and no leak could be shown;
-- the two-tenant sample shows it (15 edges through this view, 14 through the
-- table, as org A). meta/postmortems/2026-09-11-owner-privileged-views.md.
create or replace view aiq.edges_current with (security_invoker = true) as
    select id, src_id, dst_id, relation, weight, valid_from, valid_to,
           provenance, org_id, created_at,
           recall_count, probe_count, last_recalled_at
      from aiq.edges
     where aiq.edge_is_current(valid_from, valid_to, now());

-- Called by a read path with the edges it actually traversed. Not a trigger: a
-- SELECT does not fire one, and making every read a write would be a worse
-- problem than the one this solves. Two entry points rather than one function
-- and a flag, because the flag was forgotten on its first use.
-- SECURITY INVOKER, deliberately, and the first version was not.
--
-- dev/tests/query/06-graph-tenancy.sql refuses a SECURITY DEFINER function on
-- the aiq read path, in its own words: "these run on behalf of a user and must
-- be subject to that user's RLS". Written as DEFINER out of habit, it would
-- have let a caller increment counters on edges they cannot see, which is a
-- cross-tenant write dressed as bookkeeping.
--
-- INVOKER plus a column-level grant is the shape that works. RLS restricts
-- WHICH edges the update can reach, and the grant restricts WHICH COLUMNS it
-- may touch, so a caller can bump a counter on an edge they can already read
-- and can do nothing else to it. The policy on this table is SELECT-only, so
-- the UPDATE is additionally constrained to rows the caller can see.
create or replace function aiq.note_recall(p_edges uuid[])
returns bigint language plpgsql
set search_path = pg_catalog, public as $$
declare n bigint;
begin
    if p_edges is null or cardinality(p_edges) = 0 then return 0; end if;
    update aiq.edges
       set recall_count = recall_count + 1, last_recalled_at = now()
     where id = any(p_edges);
    get diagnostics n = row_count;
    return n;
end $$;

create or replace function aiq.note_probe(p_edges uuid[])
returns bigint language plpgsql
set search_path = pg_catalog, public as $$
declare n bigint;
begin
    if p_edges is null or cardinality(p_edges) = 0 then return 0; end if;
    update aiq.edges set probe_count = probe_count + 1 where id = any(p_edges);
    get diagnostics n = row_count;
    return n;
end $$;

-- RE-STATED, because these two are defined in schema.sql and the blanket
-- `revoke execute on all functions in schema aiq from public` lives in
-- integration-rbac.sql and graph-algorithms.sql, both of which load AFTER this
-- file. Without this line the functions carry the PUBLIC default they were born
-- with, which was measured: `web_anon` could execute both.
--
-- That matters more here than for a read. An anonymous caller able to call
-- note_recall() can inflate the usage counters on any edge, and consolidation
-- reads those counters to decide what to protect. It is a way to make the
-- system pay attention to the wrong thing, quietly.
--
-- Third instance of this shape in this collection: a function defined after a
-- blanket revoke owes another revoke. The rule is in agentic/schema.sql §9 and
-- it applies to every file, including the one that states it.
revoke execute on function aiq.note_recall(uuid[]) from public;
revoke execute on function aiq.note_probe(uuid[])  from public;
grant  execute on function aiq.note_recall(uuid[]) to authenticated;
grant  execute on function aiq.note_probe(uuid[])  to authenticated;
-- COLUMN-LEVEL, so the counters are the only thing a caller may write on an
-- edge. A blanket `grant update on aiq.edges` would let anyone rewrite a
-- relation's weight, provenance or validity through a function that exists to
-- count reads.
grant  update (recall_count, probe_count, last_recalled_at)
    on aiq.edges to authenticated;

comment on view aiq.edges_current is
    'Edges currently asserted. Read this rather than aiq.edges unless you '
    'specifically want retracted history.';

-- ------------------------------------------------------------
-- 4b. Belief periods: an edge that was retracted and re-asserted.
--
-- Edge identity is (src, dst, relation), so a retraction and the re-assertion
-- after it land on ONE row, and one row holds one interval. The revival sets
-- valid_to back to null and keeps the first valid_from, so the retraction
-- disappears: an as-of read inside it saw the edge as believed throughout
-- (REM-65; measured with an edge asserted, retracted four days later and
-- re-asserted five days after that -- an as-of read on day six returned it).
--
-- THE ROW STAYS THE CURRENT FACT. What is added is the history a revival
-- used to overwrite: one row here per retraction that was later undone, the
-- interval during which the edge did NOT hold. An edge's belief periods are
-- then its own [valid_from, valid_to) with these holes cut out of it, which
-- aiq.edge_periods below spells out. Stored as the holes rather than the
-- periods because almost every edge has none, so the table stays the size of
-- the event it records rather than the size of the graph, and every existing
-- reader of aiq.edges -- one row per triple, valid_from meaning "first
-- asserted" -- is unchanged.
--
-- A current read never needs it. Every hole closed at a revival that has
-- already happened, so "does this hold now" is still aiq.edge_is_current over
-- the row alone; only an as-of read before now looks here.
-- ------------------------------------------------------------
create table if not exists aiq.edge_retractions (
    edge_id      uuid not null references aiq.edges(id) on delete cascade,
    retracted_at timestamptz not null,
    revived_at   timestamptz not null,
    primary key (edge_id, retracted_at),
    check (revived_at > retracted_at)
);
comment on table aiq.edge_retractions is
    'When an edge was withdrawn, and when it was revived, so a correction is a row rather than a deletion.';
comment on table aiq.edge_retractions is
    'Retractions that were later undone: while [retracted_at, revived_at) the '
    'edge did not hold. Written by trg_record_edge_retraction on every path '
    'that revives an edge; read through aiq.edge_periods.';

-- A TRIGGER, not a line in each writer. Edges are revived by the ingestion
-- upsert, the catalogue refresh, the self-model's derivations and pgw's dream,
-- and each spells the revival `on conflict ... do update set valid_to = null`
-- in its own words -- the "fixed at the copy that failed" shape waiting to
-- happen. A trigger is the one place every revival passes through, including
-- the next writer nobody has written yet.
--
-- A retraction undone at the SAME instant is not a hole. A derivation that
-- retires what it owns and revives what still derives (selfmodel.rederive,
-- aiq.reconcile_edges) does both in one transaction at one now(), and the
-- edge held throughout; `o.valid_to < now()` is what tells that apart from a
-- fact that was genuinely withdrawn for a while.
--
-- SECURITY DEFINER because the statement that fires it may be a caller's:
-- aiq.note_recall() updates aiq.edges as `authenticated`, and a trigger runs
-- as whoever fired it. The write is the history of rows that caller could
-- already update, so owner privilege adds reach over nothing but this table.
create or replace function aiq.record_edge_retraction() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
    insert into aiq.edge_retractions (edge_id, retracted_at, revived_at)
    select n.id, o.valid_to, now()
      from new_rows n
      join old_rows o on o.id = n.id
     where o.valid_to is not null and n.valid_to is null
       and o.valid_to < now()
    on conflict (edge_id, retracted_at) do nothing;
    return null;
end $$;

-- Statement-level with transition tables (D6), so a bulk revival is one
-- INSERT ... SELECT. No column list: PG refuses transition tables on a trigger
-- that has one, so this fires on the counter updates too and inserts nothing.
create or replace trigger trg_record_edge_retraction
    after update on aiq.edges
    referencing old table as old_rows new table as new_rows
    for each statement execute function aiq.record_edge_retraction();

-- One row per BELIEF PERIOD. An edge with no undone retraction is its row; one
-- with k of them is k+1 rows, the holes cut out. `aiq.edge_is_current(
-- valid_from, valid_to, t)` over this view is the as-of read -- the same rule
-- a current read applies to aiq.edges, at a different t -- and it is what the
-- compiled snapshot is built from (graph-algorithms.md §7).
--
-- security_invoker for edges_current's reason: the caller's RLS on aiq.edges
-- decides which edges have periods at all.
create or replace view aiq.edge_periods with (security_invoker = true) as
    select e.id as edge_id, e.src_id, e.dst_id, e.relation, e.weight, e.org_id,
           e.valid_from, e.valid_to, e.provenance
      from aiq.edges e
     where not exists (select 1 from aiq.edge_retractions r where r.edge_id = e.id)
    union all
    -- the period that ends at each hole, starting where the previous hole ended
    select e.id, e.src_id, e.dst_id, e.relation, e.weight, e.org_id,
           coalesce(lag(r.revived_at) over (partition by r.edge_id
                                            order by r.retracted_at),
                    e.valid_from),
           r.retracted_at, e.provenance
      from aiq.edge_retractions r
      join aiq.edges e on e.id = r.edge_id
    union all
    -- and the period after the last hole, which is the row's own
    select e.id, e.src_id, e.dst_id, e.relation, e.weight, e.org_id,
           l.revived_at, e.valid_to, e.provenance
      from (select distinct on (edge_id) edge_id, revived_at
              from aiq.edge_retractions
             order by edge_id, retracted_at desc) l
      join aiq.edges e on e.id = l.edge_id;
comment on view aiq.edge_periods is
    'One row per interval over which an edge was believed. Filter with '
    'aiq.edge_is_current(valid_from, valid_to, t) for the edges that held at t.';

-- ------------------------------------------------------------
-- 4c. A derivation withdraws what IT said, and nothing else.
--
-- "Retire the derived edges you own, revive the ones that re-derive" was
-- written three times -- selfmodel.rederive, selfmodel.rederive_decisions and
-- pgw.land_dream -- and the three disagreed about what "own" means. The
-- self-model retired by RELATION NAME across the whole database
-- (`relation = any(v_managed)`, a list that includes `mentions`); pgw retired
-- by theme within one org. pgw declares `issue mentions issue`, so a
-- self-model refresh on a database holding both retracted pgw's edges and
-- never revived them, because it does not derive them (REM-60). A relation
-- name says what an edge means, not who asserted it. Provenance says who.
--
-- OWNERSHIP IS PROVENANCE. An edge belongs to agent A when A wrote it as a
-- single writer (`provenance.agent`, the self-model's shape) or when A is one
-- of its sources (`provenance.sources[].agent`, the shape aiq.upsert_graph
-- writes). graph-index.md §7 then fixes what withdrawing means for an edge
-- that several writers assert: it is a refcount, not a retraction. A's
-- entries leave the sources list and the edge stays current on the others'
-- word; only an edge nobody else asserts is retracted, and it keeps its
-- provenance, because a retraction with its source stripped off cannot say
-- whose belief ended.
--
-- TWO WAYS TO CALL IT, matching the two idioms already in use:
--
--   before re-deriving, p_run null: withdraw everything, then let the
--   derivation's own inserts revive what still follows. Retire and revive
--   happen at one now(), so trg_record_edge_retraction records no hole for an
--   edge that held throughout.
--
--   after re-deriving, p_run = the run that just wrote: withdraw what this
--   agent asserted in any OTHER run. For writers that stamp run_id, which
--   aiq.upsert_graph does.
--
-- p_org and p_relations narrow it further; neither widens it past p_agent.
-- ------------------------------------------------------------
create or replace function aiq.retract_derived(
    p_agent     text,
    p_org       uuid   default null,
    p_relations text[] default null,
    p_run       text   default null
) returns jsonb language plpgsql
set search_path = pg_catalog, public as $$
declare
    v_now       timestamptz := now();
    v_mine      jsonb := jsonb_build_array(jsonb_build_object('agent', p_agent));
    v_this_run  jsonb := jsonb_build_array(jsonb_build_object('agent', p_agent, 'run_id', p_run));
    v_withdrawn bigint;
    v_retracted bigint;
begin
    if coalesce(p_agent, '') = '' then
        raise exception 'aiq.retract_derived needs the agent whose edges it withdraws. '
            'Without one every derived edge is in scope, which is the defect it exists '
            'to prevent (REM-60).';
    end if;

    -- 1. Shared edges: take this agent's entries out, leave the edge standing.
    --    First, so step 2 sees what is left and does not retract an edge
    --    somebody else still asserts.
    with shared as (
        select e.id,
               (select jsonb_agg(s)
                  from jsonb_array_elements(e.provenance->'sources') s
                 where s->>'agent' is distinct from p_agent) as rest
          from aiq.edges e
         where aiq.edge_is_current(e.valid_from, e.valid_to, v_now)
           and (p_org is null or e.org_id = p_org)
           and (p_relations is null or e.relation = any(p_relations))
           and e.provenance->'sources' @> v_mine
           and not (p_run is not null and e.provenance->'sources' @> v_this_run)
    )
    update aiq.edges e
       set provenance = e.provenance || jsonb_build_object('sources', sh.rest)
      from shared sh
     where e.id = sh.id and sh.rest is not null;
    get diagnostics v_withdrawn = row_count;

    -- 2. Edges this agent alone asserts: retract, provenance intact.
    update aiq.edges e
       set valid_to = v_now
     where aiq.edge_is_current(e.valid_from, e.valid_to, v_now)
       and (p_org is null or e.org_id = p_org)
       and (p_relations is null or e.relation = any(p_relations))
       and (e.provenance->>'agent' = p_agent
            or (e.provenance->'sources' @> v_mine
                and not exists (select 1 from jsonb_array_elements(e.provenance->'sources') s
                                 where s->>'agent' is distinct from p_agent)))
       -- coalesce, not a bare comparison: `provenance->>'run_id'` is NULL on
       -- every edge written in the sources shape, NULL = 'r1' is NULL, and
       -- `not (… or NULL)` is NULL -- which a WHERE clause does not satisfy,
       -- so the edges this argument exists to retract were the ones it
       -- skipped. Found by dev/tests/query/15 §5; it is the same three-valued
       -- trap the projection's eviction carries a comment about.
       and not (p_run is not null
                and (coalesce(e.provenance->>'run_id', '') = p_run
                     or e.provenance->'sources' @> v_this_run));
    get diagnostics v_retracted = row_count;

    return jsonb_build_object('agent', p_agent, 'retracted', v_retracted,
                              'withdrawn', v_withdrawn);
end $$;
comment on function aiq.retract_derived(text, uuid, text[], text) is
    'Withdraw one agent''s derived edges: its entries leave shared edges, and '
    'edges it alone asserts are retracted with provenance intact (REM-60).';
revoke execute on function aiq.retract_derived(text, uuid, text[], text) from public;
grant  execute on function aiq.retract_derived(text, uuid, text[], text) to worker;

-- Enforce the catalogue, and enforce that both endpoints are real nodes
-- (the FKs already do the latter; this makes the type-pair check real).
create or replace function aiq.check_edge_catalogue() returns trigger as $$
declare
    v_src_type text;
    v_dst_type text;
    v_symmetric boolean;
    v_swap uuid;
begin
    select entity_type into v_src_type from aiq.nodes where id = new.src_id;
    select entity_type into v_dst_type from aiq.nodes where id = new.dst_id;
    select bool_or(is_symmetric) into v_symmetric
      from aiq.relation_types where relation = new.relation;
    if not exists (
        select 1 from aiq.relation_types
        where relation = new.relation
          and ((src_type = v_src_type and dst_type = v_dst_type)
               -- A symmetric relation is catalogued in one orientation and
               -- accepted in either, because normalisation below may store it
               -- in the other one. Requiring both rows would make the flag a
               -- trap: you would declare a relation symmetric and then be
               -- refused for writing it the way you declared it.
               or (coalesce(v_symmetric, false)
                   and src_type = v_dst_type and dst_type = v_src_type))
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

    -- Normalise, rather than reject. A writer that has to know the ordering
    -- rule before it can insert is a rule every writer gets wrong once; a
    -- writer that inserts either way and lands on one row is a rule nobody has
    -- to know. The consequence to be aware of is that the second orientation
    -- now collides with the first on the unique index -- which is the point,
    -- and is why a bulk evidence load should say `on conflict do nothing`.
    --
    -- Compared as uuid, which is byte order in Postgres and needs no
    -- collation: the same constraint written over text keys is a genuine trap,
    -- because a client language's sort order and the database's collation
    -- disagree on strings that differ only by a separator.
    if coalesce(v_symmetric, false) and new.src_id > new.dst_id then
        v_swap := new.src_id;
        new.src_id := new.dst_id;
        new.dst_id := v_swap;
    end if;
    return new;
end;
$$ language plpgsql;

create or replace trigger trg_check_edge_catalogue
    before insert or update on aiq.edges
    for each row execute function aiq.check_edge_catalogue();

-- ------------------------------------------------------------
-- 5. No property graph. There was one, aiq.knowledge_graph, a SQL/PGQ
--    declaration over aiq.nodes and aiq.edges_current that graph_neighbors'
--    depth 1 read through GRAPH_TABLE. SQL/PGQ was withdrawn from PostgreSQL
--    19 before GA (October 2026), and nothing else in PostgreSQL has it, so
--    an extension that declared one ran on one beta and nowhere else.
--
--    It cost little to lose. The graph was catalog metadata over the same
--    two tables, never a second copy (D8, invariant 7), and every query
--    through it joined back to aiq.edges_current for the columns it could not
--    project; depth >1 never used it, because PG19 rejected path quantifiers.
--    graph_neighbors now reads aiq.edges_current directly in both directions.
--
--    A database built on a PG19 beta still has the object, and its grant
--    names it. Dropped here, through EXECUTE so a server without the syntax
--    never parses it; the catalog check is version-proof where a
--    server_version test would not be.
-- ------------------------------------------------------------
do $$
begin
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'aiq' and c.relname = 'knowledge_graph') then
        execute 'drop property graph aiq.knowledge_graph';
    end if;
end $$;

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
create table if not exists aiq.entity_registry (
    entity_type   text primary key,
    source_table  text not null,          -- schema-qualified
    key_expr      text not null,          -- SQL expr -> canonical key
    summary_expr  text not null default 'null',
    org_expr      text not null default 'null',
    -- SQL expr -> one of rbac.visibilities.scope. Defaulted from org_expr
    -- rather than required, because that default IS the semantics this layer
    -- had before scope existed: a node with no org was readable by everyone
    -- and a node with one was readable by that org. Stating it as an
    -- expression is what makes the OTHER case sayable -- a source table with
    -- its own visibility column projects private rows -- which `org_id is
    -- null means public` never could.
    visibility_expr text not null default 'null',
    include_where text not null default 'true',
    registered_at timestamptz not null default now()
);
comment on table aiq.entity_registry is
    'How an ordinary table is projected into the graph: its key, summary, org and visibility expressions. Registering one is an insert, never a schema change.';

-- SHIPPED BY THE EXTENSION, OR ADDED BY THIS DEPLOYMENT. aiq.entity_registry holds
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
alter table aiq.entity_registry add column if not exists shipped boolean not null default false;
alter table aiq.entity_registry alter column shipped set default
    (coalesce(current_setting('percolate.seeding', true), 'off') = 'on');
-- ...AND ON A DATABASE THAT ALREADY HAS THE TABLE, where the line above is a
-- no-op. Same shape as rbac's `alter column status set default`: the upgrade
-- script is this file replayed, and `create table if not exists` is perfectly
-- idempotent while being silently incomplete.
alter table aiq.entity_registry
    add column if not exists visibility_expr text not null default 'null';

-- THE PREVIOUS SIGNATURE IS DROPPED, not left beside this one. Adding
-- p_visibility_expr with a default does not replace the six-argument function;
-- it creates a seventh-argument OVERLOAD, and then every existing six-argument
-- call is `function aiq.register_entity_table(unknown, unknown, unknown,
-- unknown, unknown, unknown) is not unique` -- ambiguous, because both
-- candidates match. A fresh install never sees it (there is no old function to
-- be ambiguous with) and every upgrading database fails on the first
-- registration. Found by dev/upgrade-converges.sh; the same drop is in front
-- of content.register_upload for the same reason.
-- THE PROJECTION, WRITTEN ONCE. The four statements that make aiq.nodes and
-- aiq.node_keys agree with a registered table, generated from its registry row
-- over a named row source: `new_rows` (the transition table) for the live
-- trigger, the source table itself for aiq.rebuild_entity_type.
--
-- It was written twice, and the two copies disagreed in the way this file's
-- own comments kept predicting ("two code paths that must agree, with nothing
-- forcing them to" -- the `n`/`s` alias mismatch, then visibility_expr). The
-- third disagreement was statement 4: the trigger deleted a renamed row's
-- superseded canonical key and the rebuild did not, so a bulk load with the
-- triggers off followed by a rebuild left the node with two canonical keys and
-- the old name resolving forever (REM-51). Generating both from here is what
-- makes a fourth disagreement unwritable.
--
-- An array of statements rather than one string, because the rebuild runs
-- them with EXECUTE, which takes one command at a time.
create or replace function aiq.projection_statements(
    r aiq.entity_registry, p_rows text
) returns text[] language plpgsql stable as $$
begin
    return array[
        -- REM-152: preserve source ownership on inserts, updates and rebuilds.
        -- Private nodes without their owner's ID disappear from that owner's
        -- search. to_jsonb supports external tables that have no owner_id.
        -- 1. Rows that belong: upsert identity.
        -- rbac.org_or_shared() wraps the org expression at every one of the
        -- sites that writes it, and the wrap is not decoration. aiq.nodes.org_id
        -- is NOT NULL; org_expr is an expression over a table somebody else
        -- owns, whose org column is nullable and whose null has always meant
        -- "shared". Unwrapped, the first shared row a customer projects fails
        -- the not-null constraint and the failure names our column rather than
        -- their data.
        --
        -- visibility is projected on UPDATE for org_id's reason: the source row
        -- is the truth, and a node left at the scope it had when it was first
        -- projected would go on being readable after the row it mirrors
        -- stopped being.
        format($q$
            insert into aiq.nodes (entity_type, entity_id, org_id, summary, visibility, owner_id)
            select %1$L, n.id, rbac.org_or_shared(%2$s), %3$s, %4$s,
                   nullif(to_jsonb(n)->>'owner_id', '')::uuid from %5$s n where %6$s
            on conflict (entity_type, entity_id) do update
                set summary = excluded.summary, org_id = excluded.org_id,
                    visibility = excluded.visibility, owner_id = excluded.owner_id, updated_at = now()
        $q$, r.entity_type, r.org_expr, r.summary_expr, r.visibility_expr,
             p_rows, r.include_where),

        -- 2. Rows that no longer belong: evict. coalesce(..., false) rather
        --    than `not (...)` because a predicate that evaluates to NULL is not
        --    satisfied, and three-valued logic here would put the stale node
        --    back exactly where it was.
        format($q$
            delete from aiq.nodes nd
            where nd.entity_type = %1$L
              and nd.entity_id in (select n.id from %2$s n
                                    where not coalesce((%3$s), false))
        $q$, r.entity_type, p_rows, r.include_where),

        -- 3. The canonical key. DO UPDATE, not DO NOTHING: org_id scopes the
        --    canonical-key unique index, so leaving a stale copy on an
        --    existing key row silently corrupts that scoping after a tenancy
        --    change.
        format($q$
            insert into aiq.node_keys (node_id, entity_type, key, kind, org_id, owner_scope)
            select nd.id, %1$L, lower(trim(%2$s)), 'canonical', rbac.org_or_shared(%3$s),
                   case when nd.visibility = 'private' then nd.owner_id end
            from %4$s n
            join aiq.nodes nd on nd.entity_type = %1$L and nd.entity_id = n.id
            where %5$s
            on conflict (node_id, key, kind) do update
                set org_id = excluded.org_id, owner_scope = excluded.owner_scope
        $q$, r.entity_type, r.key_expr, r.org_expr, p_rows, r.include_where),

        -- 4. Superseded canonical keys. Runs AFTER the insert, so a key_expr
        --    that evaluates to NULL aborts on the not-null constraint above
        --    rather than deleting the name the node had. Short keys and
        --    aliases are editorial and are not touched: a rename is not a
        --    reason to forget that somebody taught the graph a synonym.
        format($q$
            delete from aiq.node_keys k
            using aiq.nodes nd, %3$s n
            where k.node_id = nd.id
              and nd.entity_type = %1$L and nd.entity_id = n.id
              and k.kind = 'canonical'
              and k.key is distinct from lower(trim(%2$s))
        $q$, r.entity_type, r.key_expr, p_rows)
    ];
end $$;

drop function if exists aiq.register_entity_table(text,text,text,text,text,text);

create or replace function aiq.register_entity_table(
    p_entity_type   text,
    p_source_table  text,
    p_key_expr      text,
    p_summary_expr  text default 'null',
    p_org_expr      text default 'null',
    p_include_where text default 'true',
    -- LAST, and that position is not cosmetic. Added before p_include_where,
    -- every existing positional caller silently handed its inclusion predicate
    -- to this parameter instead: `content.resources` registered with
    -- visibility_expr = "n.status = 'ready'", which projects the text `true`
    -- or `false` into a column whose foreign key admits neither. Measured as
    -- `insert or update on table "nodes" violates foreign key constraint
    -- "nodes_visibility_fkey"` from the corpus seed -- loud, but loud in a
    -- place that named neither the argument nor the caller. A new optional
    -- parameter goes at the end.
    p_visibility_expr text default null
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
    r       aiq.entity_registry;
    v_ins   text := quote_ident('project_' || p_entity_type || '_ins');
    v_del   text := quote_ident('project_' || p_entity_type || '_del');
    v_other text;
    -- Defaulted HERE and not in the signature, because the default is derived
    -- from another argument: "no org means everyone, an org means that org" is
    -- exactly what this layer meant by org_id before rbac.visibilities existed,
    -- so a registration that says nothing about visibility keeps the behaviour
    -- it had rather than projecting every node private and going dark.
    --
    -- rbac.is_shared_org() rather than `is null`, and this is the one place the
    -- sentinel has to absorb a NULL it did not create. p_org_expr is an
    -- expression over a table THIS COLLECTION DOES NOT OWN -- a customer's
    -- `calder.products.org_id`, nullable, meaning whatever they meant by it --
    -- so the NOT NULL guarantee stops at the registry boundary and the
    -- translation has to happen on the way in. is_shared_org(null) is true, so
    -- an application column that says nothing still projects as `public`,
    -- which is the behaviour this default has always had.
    v_vis text := coalesce(p_visibility_expr,
                           format('case when rbac.is_shared_org(%s) '
                                  'then ''public'' else ''org'' end',
                                  p_org_expr));
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

    -- THE TABLE MUST HAVE `id uuid`, and saying so HERE is the difference
    -- between a registration error and a broken table. The projection below
    -- writes `n.id` into aiq.nodes.entity_id (uuid), so a table keyed any other
    -- way registered cleanly, printed nothing, and then refused EVERY insert
    -- from then on -- `column n.id does not exist`, raised inside a generated
    -- trigger that names neither the entity type nor this function. Found by
    -- scenarios/tour, whose package keyed its tables by their natural keys.
    if to_regclass(p_source_table) is not null and not exists (
        select 1 from pg_attribute
         where attrelid = to_regclass(p_source_table) and attname = 'id'
           and atttypid = 'uuid'::regtype and not attisdropped) then
        raise exception
            '% has no `id uuid` column, and an entity table needs one: it is what '
            'aiq.nodes.entity_id points at. Add `id uuid not null default gen_random_uuid() unique` '
            'and keep the natural key in the key expression (%).',
            p_source_table, p_key_expr;
    end if;

    insert into aiq.entity_registry
        (entity_type, source_table, key_expr, summary_expr, org_expr,
         visibility_expr, include_where)
    values (p_entity_type, p_source_table, p_key_expr, p_summary_expr, p_org_expr,
            v_vis, p_include_where)
    on conflict (entity_type) do update
        set source_table = excluded.source_table, key_expr = excluded.key_expr,
            summary_expr = excluded.summary_expr, org_expr = excluded.org_expr,
            visibility_expr = excluded.visibility_expr,
            include_where = excluded.include_where,
            -- OR, not assignment: a re-registration by a deployment (seeding
            -- off, excluded.shipped false) must not un-ship a row the
            -- extension seeded, or the next restore collides on it.
            shipped = excluded.shipped or entity_registry.shipped;

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
    --
    -- The statements come from aiq.projection_statements(), the same place
    -- aiq.rebuild_entity_type() takes them from (REM-51).
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            %2$s;
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_ins, array_to_string(aiq.projection_statements(r, 'new_rows'), E';\n'));

    execute format($f$
        create or replace function aiq.%1$s() returns trigger as $b$
        begin
            delete from aiq.nodes
            where entity_type = %2$L and entity_id in (select id from old_rows);
            return null;
        end;
        $b$ language plpgsql;
    $f$, v_del, p_entity_type);

    -- DENY-BY-DEFAULT REACHES THE GENERATED FUNCTIONS TOO.
    --
    -- These two are created at RUNTIME, by whoever registers an entity type --
    -- long after the extension script's own revoke has run. So they were the
    -- one path in the collection that could still mint a function carrying
    -- PUBLIC's EXECUTE, and it is the path a deployment uses most: six of them
    -- were sitting public on a stack whose install-time invariant passed
    -- cleanly, because the seeds that registered them ran afterwards.
    --
    -- Harmless in themselves -- a trigger function called directly raises --
    -- but "harmless because of how it happens to be reached" is the reasoning
    -- user-rbac 1 records about set_password and answers with "never trust
    -- that again". A generator that emits functions owes the same revoke a
    -- file does.
    execute format('revoke execute on function aiq.%I() from public', v_ins);
    execute format('revoke execute on function aiq.%I() from public', v_del);

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
    v_stmt text;
begin
    select * into r from aiq.entity_registry where entity_type = p_entity_type;
    if not found then raise exception 'entity type % not registered -- SCHEMA "graph" lists the registered ones', p_entity_type; end if;

    -- THE LIVE TRIGGER'S STATEMENTS, over the whole table instead of the
    -- transition table. This function carried its own copy of them and three
    -- scars from the copies disagreeing: the `n`/`s` alias, visibility_expr
    -- left at the column default, and -- found by REM-51 -- no statement 4, so
    -- a rename made while the triggers were off (a bulk load) left the old
    -- canonical key resolving after the rebuild that was meant to repair it.
    foreach v_stmt in array aiq.projection_statements(r, r.source_table) loop
        execute v_stmt;
    end loop;

    -- The one statement the trigger has no need of: a source row that is GONE.
    -- Live, the delete trigger removes its node; a bulk load that deleted rows
    -- with the triggers off leaves nodes pointing at nothing.
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
-- 5b. WAS: the org-membership seam, aiq.current_org_ids().
--
-- Deleted, and the deletion is the point rather than a tidy-up. This function
-- read an `orgs` array straight off the JWT because user-rbac had no org model
-- to ask -- a working seam, never a tenancy system, and the file's own comment
-- said so: "a real deployment replaces this", and scenarios/round-4.md carried
-- it as the open item that would close "when it lands, this function is the
-- single place that changes".
--
-- It landed. rbac.orgs/rbac.org_members are real tables and
-- rbac.current_org_ids() reads them, so membership is a fact the database can
-- refuse a token about instead of one the token asserts about itself. Every
-- predicate in this file and in integration-rbac.sql calls the rbac function
-- now.
--
-- The build-ordering reason this lived in the core schema rather than in
-- integration-rbac.sql is gone with it: user-rbac/schema.sql is loaded before
-- this file, so `aiq.schema_graph` -- the §13 facet whose CREATE-time
-- validation forced the move -- resolves rbac.current_org_ids() on a pristine
-- install without anything being reordered.
-- ------------------------------------------------------------

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
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id, owner_scope)
    select v_node_id, n.entity_type, v_norm, p_kind, n.org_id,
           case when n.visibility = 'private' then n.owner_id end
    from aiq.nodes n where n.id = v_node_id
    on conflict (node_id, key, kind) do update
        set org_id = excluded.org_id, owner_scope = excluded.owner_scope;

    return v_node_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 6b. THE RESOLUTION LEDGER (graph-identity.md D11).
--
-- Two rows turning out to be one thing is the most consequential write this
-- schema accepts, and until now it was the only one that left no trace. D11 has
-- specified this table since the document was written; it was the single
-- absence a consumer building the whole identity pipeline on these surfaces
-- still had to work around, writing its clusters to a local table and saying so
-- in its output.
--
-- THREE PROPERTIES, and each one is the reason a column exists.
--
-- 1. A MERGE IS A RECORD, NOT AN INDEX BEHAVIOUR. Nothing here changes what
--    graph_neighbors or graph_walk traverse. That is deliberate
--    and it is D11's own wording: resolution is a decision to be inspected and
--    argued with, and a reader that wants it applied joins `aiq.node_current`
--    below. Making it implicit would mean every existing traversal quietly
--    changed meaning on the day somebody ran a resolver.
--
-- 2. NEITHER CONSTITUENT IS DELETED. The merged node keeps its id, its edges
--    and its history; only its canonical KEY moves, becoming an alias on the
--    survivor so a lookup of the old name reaches the new node. That is what
--    makes unresolve mechanical rather than reconstructive -- compare the
--    destructive path, collapse to one row and discard the loser, which cannot
--    be undone at any price because the evidence for the merge and the loser's
--    own history both left with it.
--
-- 3. `tier` IS LOAD-BEARING, for the same reason wm.claims.is_deterministic
--    is: a registry match on a CIK and an embedding-similarity guess are not
--    the same kind of assertion, and anything reading resolutions as ground
--    truth without reading `tier` is unsound. It is also what makes the cheap
--    audit a GROUP BY -- how much of this graph's identity rests on a model's
--    guess?
--
-- CANDIDATE IDENTITY DOES NOT LIVE HERE. "These two may be the same" is
-- uncertainty, not a decision; it belongs in the consumer's evidence plane
-- where it can accumulate without asserting anything. This table records only
-- what was decided, which is what stops embedding proximity -- legitimate for
-- proposing a merge, forbidden as a scoring input -- from entering the graph as
-- a fact.
-- ------------------------------------------------------------
create table if not exists aiq.node_resolutions (
    id           uuid primary key default uuidv7(),
    canonical_id uuid not null references aiq.nodes(id) on delete cascade,
    -- NO foreign key, and the omission is the point: `on delete cascade` from
    -- nodes would erase the record of a merge when the merged node is removed,
    -- which is the one event that makes the record most worth having.
    merged_id    uuid not null,
    -- decision_model: one option from a declared set in a forward pass, with no
    -- generation (Jev and its kind) -- neither an embedding score nor an LLM's
    -- answer. graph-identity.md said to add it with its first caller; that is
    -- meta/spikes/2026-09-30-jev-decisions.
    tier         text not null
                     check (tier in ('registry','crosswalk','embedding','llm',
                                     'decision_model','human')),
    -- The matched key, the score, the agent run. `moved_keys` under this is
    -- written by aiq.resolve_nodes and read by aiq.unresolve_node: reversing a
    -- merge needs to know which key rows moved, and re-deriving them later is
    -- exactly the reconstruction this design exists to avoid.
    evidence     jsonb not null default '{}',
    decided_by   text not null,
    undone_at    timestamptz,
    org_id       uuid,
    at           timestamptz not null default now(),
    -- A node is folded into at most one survivor at a time. An undone row does
    -- not hold the slot, so a pair may be resolved, unresolved and resolved
    -- again -- and every attempt stays on the record.
    constraint node_resolutions_no_self check (canonical_id <> merged_id)
);
comment on table aiq.node_resolutions is
    'A decision that two nodes were the same thing, with the evidence, who decided, and whether it was undone.';

-- The replayed upgrade keeps an existing table as it is, so the widened tier
-- list arrives by replacing the constraint, not through the create above.
alter table aiq.node_resolutions drop constraint if exists node_resolutions_tier_check;
alter table aiq.node_resolutions add constraint node_resolutions_tier_check
    check (tier in ('registry','crosswalk','embedding','llm','decision_model','human'));

create unique index if not exists idx_node_resolutions_live
    on aiq.node_resolutions (merged_id) where undone_at is null;
create index if not exists idx_node_resolutions_canonical
    on aiq.node_resolutions (canonical_id) where undone_at is null;

comment on table aiq.node_resolutions is
    'graph-identity.md D11: merges as records. Neither constituent is deleted, '
    'unresolve is a supported operation rather than a repair, and `tier` says '
    'what KIND of assertion the merge was -- a registry match and a model''s '
    'guess are not interchangeable and a reader that ignores tier is unsound.';

-- ------------------------------------------------------------
-- The other half of the ledger: a decision that two nodes are NOT the same.
--
-- A resolver that judged a candidate against a registered node and said no
-- had nowhere to put the answer, so the next landing of the same name asked
-- the same question and paid for it again: in the 30 September entity
-- resolution run, 323 of 1,000 names needed a decision the second time, most
-- of them names already judged to match nothing. It is also a fact a later
-- decision should have to reckon with -- the "cannot link" of record linkage
-- -- so a live row here makes aiq.resolve_nodes and aiq.promote_soft_node
-- refuse to merge the pair.
--
-- A SEPARATE TABLE, not a `relation` column on node_resolutions. Every reader
-- of that table (node_current first) takes a row as a merge; a column they do
-- not know to filter on would turn every "not the same" into a merge, silently.
--
-- The pair is stored ordered (a < b) because the relation is symmetric; no
-- foreign keys, for merged_id's reason: a candidate is evicted when it is
-- promoted elsewhere, and the record that it was judged is worth keeping.
-- ------------------------------------------------------------
create table if not exists aiq.node_distinctions (
    id          uuid primary key default uuidv7(),
    a_id        uuid not null,
    b_id        uuid not null,
    tier        text not null
                    check (tier in ('registry','crosswalk','embedding','llm',
                                    'decision_model','human')),
    evidence    jsonb not null default '{}',
    decided_by  text not null check (length(btrim(decided_by)) > 0),
    undone_at   timestamptz,
    -- The org of the node being resolved (the first argument to
    -- aiq.record_distinct), for authoring and audit. Reads are gated by the
    -- two nodes, as for an edge.
    org_id      uuid,
    at          timestamptz not null default now(),
    constraint node_distinctions_ordered check (a_id < b_id)
);
comment on table aiq.node_distinctions is
    'A decision that two nodes are different things, with the evidence, who decided, and whether it was undone.';
create unique index if not exists idx_node_distinctions_live
    on aiq.node_distinctions (a_id, b_id) where undone_at is null;
create index if not exists idx_node_distinctions_b
    on aiq.node_distinctions (b_id) where undone_at is null;

-- Whether a live decision says these two are different. Either order.
create or replace function aiq.decided_distinct(p_x uuid, p_y uuid)
returns boolean language sql stable as $$
    select exists (select 1 from aiq.node_distinctions
                    where a_id = least(p_x, p_y) and b_id = greatest(p_x, p_y)
                      and undone_at is null);
$$;

-- Resolution APPLIED, for readers that want it. Transitive, because a chain
-- (a into b, b into c) is legal and a caller asking "what is this now" means c
-- rather than b. Cycles cannot arise -- resolve_nodes refuses one -- so this
-- terminates without a depth cap.
--
-- SECURITY INVOKER for edges_current's reason: owned by app_owner, which owns
-- aiq.nodes, it listed every tenant's node ids to any caller (21 rows through
-- the view, 19 through the table, as org A on the two-tenant sample).
create or replace view aiq.node_current with (security_invoker = true) as
    with recursive step as (
        select n.id as node_id, n.id as current_id, 0 as hops
          from aiq.nodes n
        union all
        select s.node_id, r.canonical_id, s.hops + 1
          from step s
          join aiq.node_resolutions r
            on r.merged_id = s.current_id and r.undone_at is null
    )
    select distinct on (node_id) node_id, current_id, hops
      from step order by node_id, hops desc;

comment on view aiq.node_current is
    'Every node and the node it currently resolves to, following chains. A node '
    'that has not been merged maps to itself, so this can be joined '
    'unconditionally without turning an unmerged node into a NULL.';

-- ------------------------------------------------------------
-- Merge. Records the decision and MOVES the merged node's canonical keys onto
-- the survivor as aliases -- so a lookup of the old name finds the new node,
-- while the old node keeps every edge ever written against it.
-- ------------------------------------------------------------
create or replace function aiq.resolve_nodes(
    p_canonical uuid, p_merged uuid, p_tier text,
    p_decided_by text, p_evidence jsonb default '{}'
) returns uuid as $$
declare v_id uuid; v_moved jsonb; v_org uuid;
begin
    if p_canonical = p_merged then
        raise exception 'a node cannot be merged into itself';
    end if;
    if not exists (select 1 from aiq.nodes where id = p_canonical) then
        raise exception 'no node % to merge into', p_canonical;
    end if;
    if not exists (select 1 from aiq.nodes where id = p_merged) then
        raise exception 'no node % to merge', p_merged;
    end if;
    -- A cycle would make node_current non-terminating, and the caller that
    -- would create one is a resolver whose clustering has already gone wrong.
    -- Refused here rather than defended against in the view, so the bad state
    -- never exists.
    if exists (select 1 from aiq.node_current where node_id = p_canonical
                                               and current_id = p_merged) then
        raise exception
            'node % already resolves to % -- merging the other way would make a '
            'cycle. Unresolve first if the direction is wrong.',
            p_canonical, p_merged;
    end if;

    -- A recorded "these are different" stands until it is undone; merging over it
    -- would leave the ledger asserting both.
    if aiq.decided_distinct(p_canonical, p_merged) then
        raise exception 'nodes % and % were decided distinct', p_canonical, p_merged
            using hint = 'aiq.undo_distinct the decision first if it was wrong.';
    end if;

    select org_id into v_org from aiq.nodes where id = p_canonical;

    -- The keys that are about to move, captured BEFORE moving them: unresolve
    -- restores exactly these, and re-deriving them afterwards is the
    -- reconstruction D11 says this design exists to avoid.
    select coalesce(jsonb_agg(jsonb_build_object(
               'key', k.key, 'kind', k.kind, 'entity_type', k.entity_type)), '[]')
      into v_moved
      from aiq.node_keys k
     where k.node_id = p_merged and k.kind = 'canonical';

    insert into aiq.node_resolutions
        (canonical_id, merged_id, tier, decided_by, evidence, org_id)
    values (p_canonical, p_merged, p_tier, p_decided_by,
            p_evidence || jsonb_build_object('moved_keys', v_moved), v_org)
    returning id into v_id;

    -- The survivor answers to the merged node's name. `alias`, never
    -- `canonical`: the canonical slot is unique per (org, key, entity_type) and
    -- the survivor already holds its own.
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id, owner_scope)
    select p_canonical, n.entity_type, k.key, 'alias', n.org_id,
           case when n.visibility = 'private' then n.owner_id end
      from aiq.node_keys k, aiq.nodes n
     where k.node_id = p_merged and k.kind = 'canonical' and n.id = p_canonical
    on conflict (node_id, key, kind) do nothing;

    -- And the merged node gives up the canonical slot, so LOOKUP of that name
    -- no longer returns two nodes. Its edges, its provenance and its id are
    -- untouched -- this is a name moving, not a row dying.
    delete from aiq.node_keys where node_id = p_merged and kind = 'canonical';

    return v_id;
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- Unresolve. A supported operation, not a repair -- which is only true because
-- nothing was destroyed, and is what this whole shape buys.
-- ------------------------------------------------------------
create or replace function aiq.unresolve_node(p_resolution uuid, p_by text)
returns void as $$
declare r aiq.node_resolutions;
begin
    select * into r from aiq.node_resolutions where id = p_resolution;
    if not found then
        raise exception 'no resolution %', p_resolution;
    end if;
    if r.undone_at is not null then
        raise exception 'resolution % was already undone at %', p_resolution, r.undone_at;
    end if;
    -- A promotion (world-model-ingestion/graph-index.md 4.5) repointed the candidate's
    -- edges and evicted its node, so there is no row to give the name back to. Left to
    -- run, the moved_keys loop below finds nothing, the insert writes nothing, undone_at
    -- is set and the caller is told it worked -- the worst of the three outcomes, because
    -- the ledger then says a merge was reversed that is still in the graph. A promotion's
    -- row is a record, not a reversal point.
    if r.evidence->>'via' = 'promote_soft_node' then
        raise exception 'resolution % records a promotion and cannot be undone', p_resolution
            using hint = 'The candidate node was evicted. Re-landing its document is the way back.';
    end if;

    -- The survivor stops answering to the name it borrowed...
    delete from aiq.node_keys k
     using jsonb_array_elements(r.evidence->'moved_keys') m
     where k.node_id = r.canonical_id and k.kind = 'alias'
       and k.key = m->>'key';

    -- ...and the merged node takes it back as canonical, which is the operation
    -- D11 calls mechanical. It is mechanical because the row it belongs to was
    -- never deleted.
    insert into aiq.node_keys (node_id, entity_type, key, kind, org_id, owner_scope)
    select r.merged_id, m->>'entity_type', m->>'key', m->>'kind', nd.org_id,
           case when nd.visibility = 'private' then nd.owner_id end
      from jsonb_array_elements(r.evidence->'moved_keys') m
      join aiq.nodes nd on nd.id = r.merged_id
    on conflict (node_id, key, kind) do nothing;

    -- The row is never deleted: an undone merge is part of the record, and a
    -- ledger that forgets its reversals is not a ledger.
    update aiq.node_resolutions
       set undone_at = now(),
           evidence = evidence || jsonb_build_object('undone_by', p_by)
     where id = p_resolution;
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

    -- 3. a soft node by its bare name (REM-995). Only after every typed tier
    -- has missed, so a typed node of the same name still wins. The key that
    -- comes back is the kind-prefixed one, 'project/harbour rewrite', which is
    -- what says under which kind the name was found; match_kind 'soft' says it
    -- was this step. Several kinds may hold one name, and each is a row.
    return query
    select distinct on (n.id)
           n.id, n.entity_type, n.entity_id, k.key, 'soft'::text, 1.0::real
    from aiq.node_keys k join aiq.nodes n on n.id = k.node_id
    where lower(substr(k.key, strpos(k.key, '/') + 1)) = v_norm
      and k.kind = 'canonical' and k.entity_type = 'soft'
    limit p_limit;
    if found then return; end if;

    -- 4. fuzzy, opt-in, and ONLY over node_keys -- never the data plane.
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
$$ language plpgsql stable security invoker;   -- caller's RLS, deliberately

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

-- GRAPH depth 1: one hop each way over aiq.edges_current.
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
        from aiq.edges_current e
        join aiq.nodes b on b.id = e.dst_id
        left join lateral (select nk.key from aiq.node_keys nk
                            where nk.node_id = b.id and nk.kind = 'canonical'
                            limit 1) kb on true
        where e.src_id = p_node_id and (p_relation is null or e.relation = p_relation)
        union all
        -- The reverse question is first-class: no inverse edge is stored, so
        -- it is answered by walking dst_id, and the label comes from the
        -- catalogue at read time (graph-identity.md "Edge table").
        select a.id, ka.key, a.entity_type, a.summary,
               coalesce(rt.inverse_label, e.relation || '_by'), e.weight, 'in'::text
        -- edges_current on BOTH branches. The reverse half read aiq.edges
        -- raw, so an inbound edge answered after its retraction (REM-51).
        from aiq.edges_current e
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

-- GRAPH depth n>1: WITH RECURSIVE. Depth- AND degree-capped, per
-- graph-identity.md "Non-goals".
--
-- Depth 1 here and graph_neighbors are two mechanisms over the same view, and
-- failure-modes.md §5 says what two mechanisms owe: agreement, asserted.
-- `dev/tests/evals/scenarios.yaml` iter-01 runs the same neighbourhood both
-- ways and requires the node sets to match.
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
        -- What holds now, not the history: this read aiq.edges, so a walk
        -- went on crossing an edge its derivation had retracted (REM-51).
        join aiq.edges_current e on (e.src_id = w.id or e.dst_id = w.id)
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
$$ language sql stable security invoker;   -- caller's RLS, deliberately

-- SEMANTIC's corpus registry: which table a `FROM <name>` names, for the
-- vector modes. Registered per corpus rather than hardcoded, because the
-- content belongs to the consumer (world-model-ingestion owns
-- resource_chunks), not to this layer.
create table if not exists aiq.semantic_sources (
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
comment on table aiq.semantic_sources is
    'Which column of which table carries a vector, and how a hit links back to the row.';

-- SHIPPED BY THE EXTENSION, OR ADDED BY THIS DEPLOYMENT. aiq.semantic_sources holds
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
alter table aiq.semantic_sources add column if not exists shipped boolean not null default false;
alter table aiq.semantic_sources alter column shipped set default
    (coalesce(current_setting('percolate.seeding', true), 'off') = 'on');

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
--  * (Two results here concerned SQL/PGQ: that GRAPH_TABLE planned as
--    ordinary joins, and that predicates pushed through it into the edge
--    indexes. Both stopped mattering when the property graph was removed;
--    section 5.)
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
--    at all for shared reference data (org_id = rbac.shared_org_id()), which is most of a
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
-- ============================================================

-- ------------------------------------------------------------
-- 8z. Semantic exceptions the result raises, raised where the rows are (REM-948).
--
-- percolate-core's `semantic_exceptions` module answers a search with rows AND
-- the exceptions they raise, each carrying a prompt the model reads. It runs in
-- Python, outside the transaction, so it sees only what the envelope carries --
-- and the envelope carries the rows returned, never how many matched. Its own
-- comment says so: TRUNCATED_AT_LIMIT "also needs the total the envelope does
-- not carry". The database is the one party that knows the total, so the kinds
-- that need it are raised here, in the statement that ran the search, with no
-- round trip.
--
-- ONE VOCABULARY. Codes, stages, severities and prompts are core's catalogue,
-- copied verbatim between the markers below, and `dev/semantic-exceptions.py
-- --check` fails when a copy differs from `core/percolate_core/semantic_exceptions/
-- catalogue.py`. Moving the catalogue itself into the database is a later card;
-- this is the three result kinds that only the store can raise honestly.
--
-- TOO_BROAD's bar is core's default (Limits.too_broad, 1000). A count is a
-- bounded probe, never an unbounded scan: `p_total` is at most bar + 1, and
-- `capped` says when it stopped counting.
-- ------------------------------------------------------------
create or replace function aiq.result_exceptions(
    p_rows jsonb, p_limit int default null, p_total int default null,
    p_capped boolean default false)
returns jsonb as $$
    with k(code, stage, severity, prompt) as (values
        -- semantic-exception kinds: begin
        ('EMPTY', 'result', 'warning', 'Nothing matched. Rephrase in the records'' own words, widen the filters, or report that the store holds nothing on this.'),
        ('TRUNCATED_AT_LIMIT', 'result', 'warning', 'The result filled the limit, so more matches exist. The answer may be partial: page further or say so.'),
        ('TOO_BROAD', 'result', 'warning', 'A very large number of records match. Add a filter or a time window.')
        -- semantic-exception kinds: end
    ), raised(code, evidence) as (
        select 'EMPTY', '{}'::jsonb
         where jsonb_array_length(coalesce(p_rows, '[]')) = 0
        union all
        select 'TOO_BROAD', jsonb_build_object('total', p_total, 'capped', p_capped)
         where p_total > 1000
        union all
        -- Only when the store KNOWS more matched, as core's own rule says: a
        -- ranked search always fills its limit, so without a total this would
        -- fire on every search and mean nothing.
        select 'TRUNCATED_AT_LIMIT',
               jsonb_build_object('returned', jsonb_array_length(p_rows), 'limit', p_limit,
                                  'total', p_total, 'capped', p_capped)
         where p_limit is not null and p_total is not null
           and jsonb_array_length(p_rows) >= p_limit and p_total > jsonb_array_length(p_rows)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'code', k.code, 'stage', k.stage, 'severity', k.severity,
               'prompt', k.prompt, 'evidence', r.evidence) order by k.code), '[]'::jsonb)
      from raised r join k using (code);
$$ language sql immutable;

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
    v_exhausted  boolean := false;
    v_limit      int;
    v_total      bigint;
    v_exceptions jsonb;
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

    -- LIMIT, ONCE, FOR EVERY MODE -- the same rule GRAPH already applies to
    -- DEPTH, and the reason it belongs here rather than in three branches is
    -- that it was missing from all of them in different ways.
    --
    -- `RELEVANCE "acme" LIMIT -1` came back `rows: []`, `exhausted: false`,
    -- `unresolved: []` -- which is this envelope's way of saying "that entity
    -- exists and nothing is related to it". It is the exact collapse
    -- `unresolved` exists to prevent, arrived at from the other side: not a
    -- name that failed to resolve, but a bound that could not be honoured.
    -- LOOKUP was luckier and no better -- the negative reached Postgres and
    -- came back as `LIMIT must not be negative`, an engine error with no mode
    -- in it. One check, one sentence, before any of them run.
    if (p->>'limit') is not null and (p->>'limit')::int < 1 then
        raise exception
            'LIMIT must be at least 1 -- % asks for no rows, and an empty '
            'answer is indistinguishable from "there is nothing to find"',
            p->>'limit';
    end if;
    v_limit := coalesce((p->>'limit')::int, 10);   -- the per-mode functions' own default

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
        v_exceptions := aiq.result_exceptions(v_out);

    when 'TEXT' then
        -- Lexical only. Needs no embedding at all, which is exactly why it
        -- answers the rare-exact-token case (§11) that SEMANTIC misses.
        --
        -- One scan answers both the rows and the count: the text index finds
        -- every match and the sort keeps the top, so asking for up to 1001
        -- ranked rows costs what asking for ten does, and the first LIMIT of
        -- them are the rows. The count is what raises TRUNCATED_AT_LIMIT and
        -- TOO_BROAD below (REM-948).
        select coalesce(jsonb_agg(to_jsonb(l) - 'n' order by l.n) filter (where l.n <= v_limit), '[]'::jsonb),
               count(*)
          into v_out, v_total
        from (select x.*, row_number() over (order by x.score desc) as n
                from aiq.lexical(p->>'source', p->>'arg', greatest(v_limit, 1001)) x) l;
        v_exceptions := aiq.result_exceptions(v_out, v_limit, least(v_total, 1001)::int,
                                              v_total > 1000);

    when 'SEARCH' then
        if p_embedding is null then
            raise exception
                'SEARCH fuses lexical and semantic ranks, so it needs p_embedding. '
                'Use TEXT ''%'' for the lexical half alone.', p->>'arg';
        end if;
        select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) into v_out
        from aiq.search(p->>'source', p->>'arg', p_embedding, p->>'model',
                        (p->>'limit')::int) h;
        v_exceptions := aiq.result_exceptions(v_out);

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

    when 'LAKE' then
        -- Planned here, run in the lake worker (world-model-ingestion/lake.md
        -- §6): the datasets are in object storage and Postgres has no route
        -- there. content.lake_plan resolves the FROM list AS THE CALLER and
        -- returns the plan; a `p8ql:` step with a LAKE query compiles to the
        -- work step that runs it. Called dynamically because this file loads
        -- before the content plane, and a missing lake says so by name.
        if to_regprocedure('content.lake_plan(jsonb)') is null then
            raise exception
                'LAKE needs the lake half of the content plane (content.lake_plan), '
                'which this database does not have';
        end if;
        execute 'select content.lake_plan($1)' into v_out using p;
        return v_out;
    when 'PATH' then
        -- Two arities, one question. Two names is the route between them;
        -- three or more is the smallest structure joining all of them, which
        -- is the two-terminal case generalised rather than a second mode --
        -- a shortest path IS the Steiner tree of two terminals.
        select coalesce(jsonb_agg(distinct a.key) filter (where l.node_id is null),
                        '[]'::jsonb)
          into v_unresolved
        from jsonb_array_elements_text(p->'args') a(key)
        left join lateral (select node_id from aiq.lookup(a.key, false, 1)) l on true;

        -- DEPTH: refuse what cannot be meant, and REPORT what was used.
        --
        -- The dispatch passed `greatest(depth, 2)` and the envelope went on
        -- echoing whatever the caller wrote, so `PATH "a" "b" DEPTH -3`
        -- returned a two-hop walk under a plan saying `depth: -3` -- the one
        -- artefact this envelope tells a reader to trust, reporting a bound the
        -- walk had not used. GRAPH refuses depth < 1 two hundred lines up for
        -- exactly this reason and PATH never got the same treatment.
        --
        -- The clamp itself stays, because depth 1 is the dialect's default
        -- rather than something a caller asked for and a route between two
        -- distinct nodes needs two hops to be worth searching for. What changes
        -- is that the plan is corrected to the depth actually walked, so the
        -- clamp is visible instead of silent.
        if (p->>'depth')::int < 1 then
            raise exception
                'DEPTH must be at least 1 -- DEPTH % asked for no traversal, and '
                'PATH would have served a depth-2 walk under a plan still '
                'saying %', p->>'depth', p->>'depth';
        end if;
        p := jsonb_set(p, '{depth}', to_jsonb(greatest((p->>'depth')::int, 2)));

        begin
            if jsonb_array_length(p->'args') = 2 then
                v_out := aiq.graph_paths(p->'args'->>0, p->'args'->>1,
                             (p->>'limit')::int, (p->>'depth')::int,
                             250, p->>'relation');
                v_exhausted := coalesce((v_out->'meta'->>'exhausted')::boolean, false);
                v_out := v_out->'paths';
            else
                v_out := aiq.graph_connect(
                             (select array_agg(value) from jsonb_array_elements_text(p->'args')),
                             500, p->>'relation');
                v_exhausted := coalesce((v_out->'meta'->>'exhausted')::boolean, false);
                v_out := jsonb_build_array(v_out - 'meta' - 'unresolved');
            end if;
        exception when insufficient_privilege then
            raise exception
                'PATH needs the graph algorithms, which ship switched off. '
                'Turn them on for this role with '
                'select aiq.enable_graph_algorithms(''%'')', current_user;
        end;

    when 'RELEVANCE' then
        -- The one mode that reaches across the extension boundary TWICE: the
        -- parser that understood the string is a C function, and so is the
        -- walk that answers it. brief.md §3.6 maps every crossing and says
        -- what each one does when the compiled half is absent or behind.
        --
        -- `unresolved` is computed the same way LOOKUP computes it, and for
        -- the same reason: aiq.related drops a seed it cannot resolve, which
        -- through this envelope makes "no such entity" indistinguishable from
        -- "that entity has nothing near it".
        select coalesce(jsonb_agg(distinct a.key) filter (where l.node_id is null),
                        '[]'::jsonb)
          into v_unresolved
        from jsonb_array_elements_text(p->'args') a(key)
        left join lateral (select node_id from aiq.lookup(a.key, false, 1)) l on true;

        begin
            select coalesce(jsonb_agg(to_jsonb(r) - 'budget_exhausted'), '[]'::jsonb),
                   coalesce(bool_or(r.budget_exhausted), false)
              into v_out, v_exhausted
            from aiq.related(
                    (select array_agg(value) from jsonb_array_elements_text(p->'args')),
                    (p->>'limit')::int, p->>'relation') r;
        exception when insufficient_privilege then
            -- The graph algorithms ship switched off, so this is the expected
            -- state of a fresh install rather than a broken one, and the
            -- message says the sentence that fixes it rather than naming a
            -- compiled function the caller has never heard of.
            raise exception
                'RELEVANCE needs the graph algorithms, which ship switched off. '
                'Turn them on for this role with '
                'select aiq.enable_graph_algorithms(''%'')', current_user;
        end;

    else
        raise exception 'unhandled mode %', p->>'mode';
    end case;

    -- `unresolved` only appears where it means something. A key absent from
    -- the envelope is a mode that does not resolve names; a key present and
    -- empty is "every name you gave me resolved". Emitting it always, empty,
    -- for SEMANTIC and TEXT would make the second reading unavailable.
    return jsonb_build_object('mode', p->>'mode', 'plan', p, 'rows', v_out)
        || case when p->>'mode' in ('LOOKUP', 'RELEVANCE', 'PATH')
                then jsonb_build_object('unresolved', v_unresolved)
                else '{}'::jsonb end
        -- Only the budgeted mode reports a budget. Emitting `exhausted` on
        -- every mode would make it noise on the six that cannot be truncated,
        -- and a reader would stop looking at it on the one that can.
        || case when p->>'mode' in ('RELEVANCE', 'PATH')
                then jsonb_build_object('exhausted', v_exhausted)
                else '{}'::jsonb end
        -- Only the retrieval modes raise result exceptions, and they always say
        -- so: an empty list is "the store looked and found none to raise", which
        -- a missing key could not distinguish from "this mode never looks".
        || case when p->>'mode' in ('TEXT', 'SEMANTIC', 'SEARCH')
                then jsonb_build_object('exceptions', coalesce(v_exceptions, '[]'::jsonb))
                else '{}'::jsonb end;
end;
$$ language plpgsql stable security invoker;   -- caller's RLS, deliberately

-- ------------------------------------------------------------
-- 9b. The extension boundary, reported rather than remembered.
--
-- This collection is TWO extensions, and the split is structural rather than
-- stylistic: `percolate_parser` carries C functions and must be installed by a
-- superuser; `percolate` owns tables and RLS policies and must NOT be, because
-- a superuser-owned table has inert policies. Neither half can be what the
-- other is.
--
-- So there is a boundary, and SQL crosses it. `aiq.query` calls `aiq_parse`,
-- the six graph wrappers call `p8_graph_*`, and the workflow compiler calls
-- `p8_compile_workflow`. Every one of those is late-bound -- plpgsql resolves
-- a function name at execution, not at creation -- which is exactly why the
-- failure is quiet: a database can install cleanly, pass a surface audit, and
-- then fail on the first call because the compiled half is older than the SQL
-- half. That is not hypothetical: a SQL reload does not carry a .so, so it is
-- the NORMAL state of any stack that pulled a new schema without a new image.
--
-- This function answers "are my two halves in step" from the catalog rather
-- than from a hand-maintained list, because a hand-maintained list of
-- crossings drifts in the direction of claiming a crossing that no longer
-- exists and missing the one somebody just added. It reads the bodies.
-- ------------------------------------------------------------
create or replace function aiq.extension_boundary() returns jsonb
language sql stable as $$
with provided as (
    -- What the compiled half actually offers, from pg_proc rather than from
    -- the control file: an extension can be registered while its library is
    -- an older build, and it is the library that answers calls.
    select p.proname, p.oid::regprocedure::text as signature
      from pg_proc p
     where p.prolang = (select oid from pg_language where lanname = 'c')
       and coalesce(p.probin, '') like '%percolate_parser%'
), bodies as (
    select n.nspname || '.' || p.proname as caller, p.prosrc
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where p.prolang = (select oid from pg_language where lanname = 'plpgsql')
       -- every schema the extension owns, not the four this once named (REM-45)
       and n.nspname in (select percolate.extension_schemas())
), callers as (
    -- The SQL half's own entry points, with whether the CALLING ROLE may
    -- execute them. `present` and `callable by me` are different facts and the
    -- second is the one a consumer needs: the graph algorithms ship switched
    -- off per-role on purpose, so a stock install has all nine wrappers present
    -- in pg_proc, every crossing satisfied, and `permission denied for function
    -- graph_components` on the first call. A consumer writing a preflight check
    -- does the obvious thing -- look the function up in the catalog -- and gets
    -- nine false OKs on a stack where nothing will run. This function exists
    -- for exactly that class of quiet failure and used to stop one step short
    -- of it. (surface.sql has the same blind spot for the same reason, and says
    -- so in its own header.)
    select n.nspname || '.' || p.proname as caller,
           bool_and(has_function_privilege(current_user, p.oid, 'execute')) as callable
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in (select percolate.extension_schemas())
     group by 1
), crossings as (
    -- A call with arguments. `[^)]` after the paren is what separates a call
    -- from a MENTION, and the mention is not hypothetical: several of these
    -- functions raise an error whose text says "the same extension as
    -- aiq_parse()", and the first version of this query reported four
    -- crossings that were apologies rather than calls.
    select distinct b.caller, m[1] as callee
      from bodies b
      cross join lateral regexp_matches(
            b.prosrc, '\m(aiq_parse|p8_[a-z0-9_]+)\s*\([^)]', 'g') m
    union
    -- And a genuine zero-argument call, which the rule above would drop.
    -- `p8_query_grammar()` is reached exactly this way, through dynamic SQL,
    -- so requiring a select in front of it keeps the call and still refuses
    -- the prose.
    select distinct b.caller, m[1] as callee
      from bodies b
      cross join lateral regexp_matches(
            b.prosrc, '\mselect\s+(aiq_parse|p8_[a-z0-9_]+)\s*\(\s*\)', 'g') m
)
select jsonb_build_object(
    'provider', jsonb_build_object(
        'extension', (select extname from pg_extension where extname = 'percolate_parser'),
        'version',   (select extversion from pg_extension where extname = 'percolate_parser'),
        'functions', (select count(*) from provided)),
    'role', current_user,
    'crossings', coalesce((
        select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'caller', c.caller, 'callee', c.callee,
                   'present', exists (select 1 from provided v where v.proname = c.callee),
                   'callable', coalesce(a.callable, false),
                   -- The diagnostic carries its own fix, the way the
                   -- slot-exhaustion error does. A reader who has to go and
                   -- find the remedy usually finds a different one.
                   'remedy', case
                             when coalesce(a.callable, false) then null
                             -- The gate that is actually shut, when it is one:
                             -- the graph algorithms are the only surface here
                             -- that ships granted to nobody. Anything else
                             -- unreachable is an ordinary missing grant, and
                             -- saying `enable_graph_algorithms` about it would
                             -- send the reader to a function that will not
                             -- mention their table.
                             when c.callee like 'p8\_graph\_%'
                             then format('select aiq.enable_graph_algorithms(%L)', current_user)
                             else format('grant execute on function %s to %I',
                                         c.caller, current_user)
                             end))
                   order by c.caller, c.callee)
          from crossings c left join callers a on a.caller = c.caller), '[]'::jsonb),
    'missing', coalesce((
        select jsonb_agg(distinct c.callee)
          from crossings c
         where not exists (select 1 from provided v where v.proname = c.callee)),
        '[]'::jsonb),
    'unreachable', coalesce((
        select jsonb_agg(distinct c.caller order by c.caller)
          from crossings c left join callers a on a.caller = c.caller
         where not coalesce(a.callable, false)), '[]'::jsonb),
    -- `ok` FOLDS IN REACHABILITY, so the one field a preflight actually reads
    -- is false on a stack where nothing will run. A report whose summary says
    -- true while its own rows say the caller cannot execute a single crossing
    -- is worse than no report: it is the false OK, with corroboration.
    'ok', not exists (
        select 1 from crossings c
          left join callers a on a.caller = c.caller
         where not exists (select 1 from provided v where v.proname = c.callee)
            or not coalesce(a.callable, false)))
$$;

comment on function aiq.extension_boundary() is
    'Every place the SQL half calls the compiled half: whether the compiled '
    'half provides it, and whether the calling role may execute it.';

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
-- foreign key, because one space serves many corpora. A space's row policy
-- therefore cannot be written with the table: it is generated from the
-- registry of sources.
--
-- Two things follow.
--
--  1. THE MODE MUST SCOPE ITSELF. aiq.semantic_in() joins the space to the
--     table registered under the corpus named in `FROM`, which both restricts
--     the search to that corpus and puts the consumer's policies in the path
--     (the mode is SECURITY INVOKER, so the join reads as the caller). Before
--     that join, SEMANTIC returned chunk ids and cosine distances for rows the
--     caller could not read: on the committed fixture, a caller holding org
--     B's claim saw five of six chunks and SEMANTIC returned all six.
--
--  2. THE SPACE ITSELF MUST BE POLICIED. integration-rbac.sql grants SELECT on
--     this schema's tables -- and sets ALTER DEFAULT PRIVILEGES so spaces
--     registered later are covered -- because the modes are SECURITY INVOKER
--     and must read them as the caller. Until REM-567 the spaces had RLS off,
--     so `select * from aiq.emb_<model>` handed any authenticated caller chunk
--     ids and raw vectors for content it could not read, and raw vectors are
--     not innocuous (embedding inversion is a published attack). Each space
--     now carries read policies generated from aiq.semantic_sources and
--     refreshed as sources are registered: §10a-iii. dev/tests/rbac/20 proves
--     it per user and query/09 §5 compares the space with the mode.
-- ============================================================

create table if not exists aiq.embedding_models (
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
comment on table aiq.embedding_models is
    'A registered embedding model: its dimension, endpoint, credential and distance operator. A query names a space rather than a URL.';

-- Exactly one default at a time. A partial unique index rather than a trigger:
-- the database enforces it, so a bad deploy fails loudly instead of leaving
-- two defaults and a coin-flip about which one SEMANTIC uses.
create unique index if not exists idx_embedding_models_one_default
    on aiq.embedding_models ((true)) where is_default;

-- TWO MODELS MAY NOT DERIVE ONE STORAGE TABLE.
--
-- `register_embedding_space` builds `aiq.emb_<name with - replaced by _>`, and
-- that mapping is not injective: `text-embedding-3-small` and
-- `text_embedding_3_small` are two models and one table. `create table if not
-- exists` then adopts whichever was registered first, at the FIRST model's
-- dimension, and the second registration returns void as though it had built
-- something. Measured: probe-x (768) and probe_x (1536) produced one table,
-- vector(768).
--
-- Refused HERE rather than in register_embedding_space, because this is where
-- the mistake is made -- the second model is the one that cannot exist, and
-- refusing at space-build time would also refuse the first model, which owns
-- the name and has done nothing wrong. The derived name is the real key, so it
-- is the one carrying the constraint; `name` remains the primary key because
-- it is what every other table and every document refers to.
--
-- An expression index rather than a stored column: nothing should be able to
-- write a derived value, and a generated column would be a second place the
-- derivation lives -- which is the thing this collection keeps removing.
--
-- THE DERIVATION ITSELF HAD FIFTEEN HOMES, and the comment above is the reason
-- that mattered: it argues against a generated column on the grounds that a
-- second place for the derivation is the thing to avoid, four lines above an
-- index expression that was the fifteenth. `aiq.embedding_space_name()` is the
-- one home now, and this index calls it -- which is the case that made a
-- function necessary rather than merely tidy. An index expression is a STORED
-- artifact: until it is dropped and recreated it keeps indexing whatever
-- spelling it was built with, so a naming change that updated fourteen call
-- sites would have left this one silently disagreeing with all of them.
--
-- `immutable` is what makes it indexable, and it is honestly immutable:
-- replace() and || over one argument, no reads, no settings.
--
-- `set search_path` for the reason every other function here has it: the body
-- is parsed in the caller's search_path, and an index expression is evaluated
-- on every write to the table, so an unpinned one lets a writer decide which
-- `replace` runs. It does NOT fix the convergence problem below, which is what
-- it was first written to do -- see the drop.
create or replace function aiq.embedding_space_name(p_model text)
returns text language sql immutable parallel safe strict
set search_path = pg_catalog as $$
    select 'emb_' || replace(p_model, '-', '_')
$$;

comment on function aiq.embedding_space_name(text) is
    'The table name for a model''s embedding space, derived from the model '
    'name. The ONE home of that derivation -- it was spelled fifteen times, '
    'one of them inside idx_embedding_models_derived_space, where it is a '
    'stored artifact that cannot be kept in step by anybody remembering to.';

-- GRANTED, because the read path reaches it as the caller. The retrieval
-- functions that resolve a model to its space are SECURITY INVOKER, so
-- `permission denied for function embedding_space_name` is what a signed-in
-- caller got the moment this replaced the inline concatenation -- caught by
-- dev/tests/query/09-retrieval-tenancy.sql and query/13-retrieval-at-scale.sql on the
-- first run, which is the argument for having those at all. Deny-by-default is
-- the posture (identity/closing.sql), so a new function reaching a caller is a
-- grant somebody writes rather than an omission that happens to work.
grant execute on function aiq.embedding_space_name(text) to authenticated;

-- DROPPED BEFORE IT IS CREATED, AND THE COMMENT ABOVE IS WHY -- three lines
-- above, this file says an index expression is a stored artifact that keeps
-- indexing whatever spelling it was built with. Then it wrote
-- `create unique index if not exists` over a name 0.1.6 had already shipped
-- with `(('emb_' || replace(name, '-', '_')))` inline, which makes the replay
-- a NO-OP: `if not exists` matches on the NAME and never looks at the
-- expression. Every upgraded database would have gone on indexing the inline
-- spelling while all fifteen call sites read the function, which is exactly the
-- silent disagreement the paragraph above argues the function prevents.
--
-- Measured, not reasoned: `dev/upgrade-converges.sh` failed on 2026-09-12 with
-- the two `pg_get_indexdef` strings side by side, and failed again identically
-- after a first fix that pinned the function's search_path -- which was a guess
-- at an inlining mechanism that is not what happened.
--
-- So: drop, then create. The drop is a no-op on a fresh install and on every
-- replay after this one; `embedding_models` holds a handful of rows, so
-- rebuilding the index costs nothing. `create ... if not exists` is the right
-- default for a table and the wrong one for an index whose EXPRESSION changes,
-- because the name is all the guard compares.
-- The `if not exists` stays because build-sql.py's replay lint requires it
-- (`create index -> create index if not exists <name>`), and after the drop it
-- is inert rather than load-bearing. Note what that lint can and cannot see: it
-- proves the statement can run twice, and a no-op runs twice happily. Nothing
-- in the tree could have caught this one -- `dev/upgrade-converges.sh` did, by
-- comparing the two databases instead of reading the statement.
drop index if exists aiq.idx_embedding_models_derived_space;
create unique index if not exists idx_embedding_models_derived_space
    on aiq.embedding_models ((aiq.embedding_space_name(name)));

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
create table if not exists aiq.embedding_providers (
    provider         text primary key,
    request_template jsonb not null,
    response_path    text  not null,   -- dotted path, the worker's `jsonpath`
    method           text  not null default 'POST',
    notes            text
);
comment on table aiq.embedding_providers is
    'How to call one provider''s embedding API, as request and response templates rather than code.';

-- `do update`, NOT `do nothing`, because these rows are the EXTENSION's
-- (REM-68). The schema is replayed on every upgrade, so `do nothing` means a
-- corrected value reaches fresh installs only and every existing database keeps
-- the old one forever -- silently, because dev/upgrade-converges.sh compares
-- OBJECTS and cannot see a row. Whose rows these are is not a judgement call:
-- specs/contract/schema.sql §4's `deployment_tables` is the list, and this
-- table is not on it. Tables that ARE on it -- rbac.role_permissions, roles --
-- keep `do nothing`, because a deployment may edit them and an update would
-- overwrite somebody's change on every upgrade.
insert into aiq.embedding_providers (provider, request_template, response_path, notes) values
    ('ollama', '{"model": "{{model}}", "prompt": "{{text}}"}'::jsonb, 'embedding',
     'POST /api/embeddings -- one vector, at the top level under "embedding".'),
    ('openai', '{"model": "{{model}}", "input": "{{text}}"}'::jsonb, 'data.0.embedding',
     'POST /v1/embeddings -- a list, because the API embeds a batch; a single '
     'text still comes back as data[0]. Needs credential_ref on the model row.')
on conflict (provider) do update
    set request_template = excluded.request_template,
        response_path    = excluded.response_path,
        method           = excluded.method,
        notes            = excluded.notes;


-- Each registered model gets its own storage table + HNSW index, generated
-- from the registry so the dimension and operator class can never drift from
-- what the model actually produces.
create or replace function aiq.register_embedding_space(p_model text)
returns void as $$
declare
    m     aiq.embedding_models;
    v_tbl text;
    v_dim int;
begin
    select * into m from aiq.embedding_models where name = p_model;
    if not found then raise exception 'embedding model % not registered -- SCHEMA "graph" lists the registered ones', p_model; end if;

    -- THE DERIVED NAME IS NOT UNIQUE, WHICH IS THE BUG register_entity_table
    -- ALREADY RECORDS, ONE FUNCTION ALONG.
    --
    -- The storage table is `emb_` || replace(name, '-', '_'), and that mapping
    -- is not injective: `text-embedding-3-small` and `text_embedding_3_small`
    -- derive the same table. `create table if not exists` then silently adopts
    -- whichever was registered FIRST, at the FIRST model's dimension, and this
    -- function returns void -- reporting success for a space it did not create.
    --
    -- Measured, registering two models in one transaction:
    --
    --     probe-x (dim 768) and probe_x (dim 1536)
    --       -> 1 storage table, aiq.emb_probe_x
    --       -> vector(768), the first registration's dimension
    --
    -- What follows is the failure §10 of this file exists to prevent: the
    -- second model's vectors either fail the dimension check or, where the
    -- dimensions happen to agree, share one table keyed by chunk_id and
    -- overwrite each other -- so `semantic` ranks a query vector from one model
    -- against stored vectors from another, which §10 states plainly cannot be
    -- done ("two different 768-dimension models are not interchangeable").
    --
    -- THE COLLISION IS REFUSED WHERE IT IS MADE -- a unique index on the
    -- derived name, beside the table, so registering the second MODEL fails
    -- rather than registering its space. Putting it here instead was tried and
    -- was wrong in a way worth recording: with both rows already inserted, a
    -- check for "another model deriving my table" refuses the FIRST
    -- registration too, which has done nothing wrong and owns the name.
    --
    -- What stays here is the shape of a table that ALREADY EXISTS, which the
    -- index cannot speak to: a space built before that index existed, or a
    -- model whose `dim` was edited after its space was built. Same silent wrong
    -- answer, different route in.
    v_tbl := aiq.embedding_space_name(m.name);

    -- And if the table is already there, it has to be the right shape. A space
    -- registered before this check existed, or a model whose dim was edited
    -- after its space was built, both land here -- and both are the same
    -- silent-wrong-answer as the collision above.
    select a.atttypmod into v_dim
      from pg_attribute a
      join pg_class c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'aiq' and c.relname = v_tbl and a.attname = 'embedding';
    if v_dim is not null and v_dim <> m.dim then
        raise exception
            'aiq.% already stores vector(%) and model % declares dimension % -- '
            'the existing space was built for a different model or a different '
            'dimension, and reusing it would rank one model''s query against '
            'another''s vectors. Drop the table deliberately, or register the '
            'model under a name that does not collide.',
            v_tbl, v_dim, m.name, m.dim;
    end if;

    execute format($q$
        create table if not exists aiq.%1$I (
            chunk_id   uuid primary key,
            embedding  vector(%2$s) not null,
            embedded_at timestamptz not null default now()
        )$q$, aiq.embedding_space_name(m.name), m.dim);

    execute format($q$
        create index if not exists %1$I on aiq.%2$I
        using hnsw (embedding %3$s)$q$,
        'idx_' || replace(m.name,'-','_') || '_hnsw',
        aiq.embedding_space_name(m.name), m.distance_op);

    -- DECLARE WHAT THIS TABLE IS, here, because nothing else can. A space is
    -- created at REGISTRATION, not at install, so specs/identity's
    -- declarations -- which run once, when the extension is created -- cannot
    -- name it. A table created by a function is declared by that function or
    -- it stays undeclared forever, and specs/identity/checks.sql will say so.
    insert into percolate.table_kinds (schema_name, table_name, kind, why)
    values ('aiq', aiq.embedding_space_name(p_model), 'natural',
            'an embedding space: chunk_id is the identity and nothing '
            'references it by surrogate; created per registered model')
    on conflict (schema_name, table_name) do nothing;

    -- RLS and its read policies (§10a-iii, REM-567). A space created without
    -- them would be every tenant's vectors to every caller the grant reaches.
    perform aiq.police_embedding_spaces();
end;
$$ language plpgsql;

-- ------------------------------------------------------------
-- 10a-ii. A deleted row takes its vectors with it.
--
-- Deleting a resource cascades to its chunks, and until this section the
-- vectors stayed. Found on 0.1.6, and measured on 0.2.0 before this section:
-- delete a resource with two embedded chunks, and both chunks go while their
-- rows in each aiq.emb_<model> remain --
-- ranked by nothing, because semantic_in() joins them away, and still handed
-- to anyone who selects the space directly (§10's open exposure, now about
-- content that no longer exists). record_chunks() made the same orphans on
-- every re-ingest, because it replaces a resource's chunks with new ids.
--
-- WHY A TRIGGER ON THE SOURCE AND NOT A FOREIGN KEY ON THE SPACE. A space
-- holds every registered corpus that was embedded with its model: `chunks`
-- (content.resource_chunks) and `skills` (agentic.skills) ship registered,
-- and a deployment may add its own table to aiq.semantic_sources. A chunk_id
-- is therefore an id from one of several tables, and a foreign key names one
-- table. So the rule is attached to each registered source table instead:
-- after a delete, the ids it removed are removed from every space. The spaces
-- are listed when the delete happens, which is why a model registered after
-- its source needs nothing done to it.
--
-- Deleting by id alone, without asking which source a vector came from,
-- assumes nothing the space's key does not already assume: chunk_id is its
-- primary key, so two sources sharing an id would already be sharing one
-- vector.
--
-- TRUNCATE fires no delete trigger and carries no transition table, so a
-- truncated source is reconciled by the sweep below rather than by id.
-- ------------------------------------------------------------

-- The sweep: every vector whose id is in no registered source table.
--
-- It runs once in this body, which is how a database upgraded from a version
-- without the triggers loses the orphans it already has, and again after a
-- TRUNCATE. It is SECURITY DEFINER so it can delete from the spaces, and that
-- makes the refusal below necessary rather than cautious: the anti-join reads
-- each source as this function's owner, and a source the owner cannot read
-- in full would make every row it cannot see look deleted. So it does nothing
-- unless every registered source exists, has an `id`, and is readable without
-- a row policy getting in the way.
create or replace function aiq.forget_orphan_vectors()
returns int as $$
declare
    v_live  text;
    v_tbl   text;
    v_n     int;
    v_total int := 0;
begin
    if exists (
        select 1
          from aiq.semantic_sources s
          left join pg_class c on c.oid = to_regclass(s.source_table)
         where c.oid is null
            or not exists (select 1 from pg_attribute a
                            where a.attrelid = c.oid and a.attname = 'id'
                              and not a.attisdropped)
            or not has_table_privilege(c.oid, 'select')
            or (c.relrowsecurity
                and (c.relforcerowsecurity or not pg_has_role(c.relowner, 'usage'))))
    then
        raise warning 'aiq.forget_orphan_vectors: skipped -- a registered semantic '
                      'source is missing, has no id column, or is not fully readable '
                      'by %, so a vector could not be told apart from an orphan',
                      current_user;
        return 0;
    end if;

    select string_agg(format('not exists (select 1 from %s s where s.id = e.chunk_id)',
                             to_regclass(s.source_table)), ' and ')
      into v_live
      from aiq.semantic_sources s;
    -- No source registered: nothing to compare against, which is not the same
    -- as every vector being an orphan.
    if v_live is null then
        return 0;
    end if;

    for v_tbl in
        select aiq.embedding_space_name(m.name)
          from aiq.embedding_models m
         where to_regclass('aiq.' || quote_ident(aiq.embedding_space_name(m.name))) is not null
    loop
        execute format('delete from aiq.%I e where %s', v_tbl, v_live);
        get diagnostics v_n = row_count;
        v_total := v_total + v_n;
    end loop;
    return v_total;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function aiq.forget_orphan_vectors() from public;

-- The trigger each source table carries. Statement-level over a transition
-- table, so a resource with three hundred chunks costs one DELETE per space
-- rather than three hundred.
--
-- SECURITY DEFINER because the role deleting the row may hold no grant on the
-- spaces -- a user removing their own skill under RLS, say -- and removing the
-- vector of a row that was just deleted is no more authority than the delete.
create or replace function aiq.forget_vectors()
returns trigger as $$
declare
    v_tbl text;
begin
    if tg_op = 'TRUNCATE' then
        perform aiq.forget_orphan_vectors();
        return null;
    end if;
    for v_tbl in
        select aiq.embedding_space_name(m.name)
          from aiq.embedding_models m
         where to_regclass('aiq.' || quote_ident(aiq.embedding_space_name(m.name))) is not null
    loop
        execute format('delete from aiq.%I e using gone g where e.chunk_id = g.id', v_tbl);
    end loop;
    return null;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function aiq.forget_vectors() from public;

-- Registering a source attaches the two triggers to its table, so every way of
-- registering one -- the inserts in integration.sql and agentic/schema.sql, a
-- fixture, a deployment's own INSERT -- gets them without calling anything.
--
-- Creating a trigger needs ownership of the table. A source whose table the
-- registrar does not own, or which does not exist yet, is still registered and
-- gets a WARNING naming what it lacks: refusing the registration would make
-- the corpus unsearchable, and refusing the upgrade that replays this would
-- stop a database on a row it cannot change.
create or replace function aiq.attach_forget_vectors()
returns trigger as $$
declare
    v_rel regclass := to_regclass(new.source_table);
begin
    if v_rel is null then
        raise warning 'semantic source % names %, which does not exist -- its '
                      'vectors will outlive its rows until it is registered again',
                      new.name, new.source_table;
        return null;
    end if;
    execute format('create or replace trigger trg_forget_vectors after delete on %s '
                   'referencing old table as gone for each statement '
                   'execute function aiq.forget_vectors()', v_rel);
    execute format('create or replace trigger trg_forget_vectors_truncate after truncate on %s '
                   'for each statement execute function aiq.forget_vectors()', v_rel);
    return null;
exception when insufficient_privilege then
    raise warning 'semantic source %: % cannot put a trigger on % (%) -- its '
                  'vectors will outlive its rows. Register it as the table''s owner.',
                  new.name, current_user, v_rel, sqlerrm;
    return null;
end;
$$ language plpgsql;

revoke execute on function aiq.attach_forget_vectors() from public;

create or replace trigger trg_semantic_source_forgets
    after insert or update of source_table on aiq.semantic_sources
    for each row execute function aiq.attach_forget_vectors();

-- AN UPGRADE BRINGS ITS EXISTING SOURCES AND SPACES INTO LINE HERE. On a fresh
-- install both statements find nothing: no source is registered yet and no
-- space exists. On a database from before this section, the update re-fires
-- the trigger above for every source already registered, and the sweep removes
-- the vectors earlier deletes left behind.
update aiq.semantic_sources set source_table = source_table;

-- A WARNING rather than a notice, because CREATE and ALTER EXTENSION run their
-- script with client_min_messages raised to warning: a notice here was measured
-- reaching nobody, on an upgrade that had just deleted two rows.
do $$
declare v_n int;
begin
    v_n := aiq.forget_orphan_vectors();
    if v_n > 0 then
        raise warning 'aiq: removed % vector(s) whose rows had already been deleted', v_n;
    end if;
end $$;

-- ------------------------------------------------------------
-- 10a-iii. A caller reads a vector only if they may read its row (REM-567).
--
-- integration-rbac.sql grants SELECT on every space to authenticated and
-- api_viewer, because semantic_in is SECURITY INVOKER and reads the space as
-- the caller. With RLS off that grant handed every tenant's chunk ids and
-- vectors to anyone who selected the table, and a vector is readable content.
-- rbac/02 §10 found it (REM-551).
--
-- Revoking the grant instead was considered and does not work: the search has
-- to read the space as the caller, so that the consumer table it joins is
-- filtered by the caller's policies, and an HNSW scan cannot be split across a
-- definer boundary without losing the iterative scan that gives a narrow
-- tenant any recall at all (semantic_in, below).
--
-- So each space carries a SELECT policy through its source rows: a vector is
-- visible when one registered source has a row with that id that the caller
-- can see, which puts that source's own policy in the path. It is generated
-- from aiq.semantic_sources, because a space does not know which source a
-- chunk_id came from.
--
-- ONE POLICY PER READING ROLE, not one policy. A policy that names a table the
-- caller cannot SELECT fails the whole read with "permission denied", so a
-- clause is written only for a role that may read that source: authenticated
-- cannot read agentic.skills and api_viewer can, so skill vectors are visible
-- to api_viewer (skill discovery) and to no other web role. api_viewer is a
-- member of authenticated and gets both policies; its own carries only the
-- sources the parent's does not. A role reading the space that this function
-- does not name gets no policy and reads nothing, which is the side to fail on.
--
-- Cost: an index lookup per candidate vector through the source's primary key
-- and its policy. semantic_in already joins the same source, so a search pays
-- the check twice; dev/tests/query/13 runs it at scale.
--
-- Run by register_embedding_space for a new space, by the trigger below when a
-- source is registered, changed or removed, and once below for an upgrade. It
-- has to run as the spaces' owner; a registrar that is not gets a WARNING and
-- the old policies stay.
create or replace function aiq.police_embedding_spaces()
returns void as $$
declare
    v_tbl   text;
    v_rel   regclass;
    v_pol   text;
    v_role  text;
    v_using text;
    v_roles text[] := array['web_anon', 'authenticated', 'api_viewer'];
begin
    for v_tbl in
        select aiq.embedding_space_name(m.name)
          from aiq.embedding_models m
         where to_regclass('aiq.' || quote_ident(aiq.embedding_space_name(m.name))) is not null
    loop
        v_rel := to_regclass('aiq.' || quote_ident(v_tbl));
        execute format('alter table %s enable row level security', v_rel);
        for v_pol in select polname from pg_policy
                      where polrelid = v_rel and polname like 'space\_read\_%'
        loop
            execute format('drop policy %I on %s', v_pol, v_rel);
        end loop;

        for v_role in
            select r from unnest(v_roles) r
             where exists (select 1 from pg_roles where rolname = r)
               and has_table_privilege(r, v_rel, 'select')
        loop
            -- `offset 0` IS THE WHOLE PERFORMANCE OF EVERY VECTOR SEARCH IN THE DEPLOYMENT, and it is not a
            -- no-op even though it selects the same rows. Without it the planner rewrites each correlated
            -- EXISTS into `chunk_id IN (select id from <source>)` and HASHES it, which reads the whole source
            -- table once per query with that table's own row security evaluated per row. With it the subquery
            -- stays correlated and each candidate vector costs one index probe.
            --
            -- Measured on p8cand, `emb_demo_quad_a` holding ELEVEN chunk vectors, a top-5 semantic query, after
            -- research.claims (3,909 rows, function-based RLS) joined the registered sources:
            --
            --     as written before this line   443 ms    (216 ms of it a seq scan of research.claims)
            --     with `offset 0`               0.41 ms
            --
            -- The cost does not belong to the space being searched: it is paid on spaces holding no rows of the
            -- expensive source at all, because every registered source is a branch of every space's policy. So
            -- it scales with the LARGEST registered corpus and with the number of sources, and the deployment
            -- that notices first is the one whose content table is big -- which is every deployment.
            --
            -- Alphabetical order buys nothing here, and it was worth measuring rather than assuming: a hashed
            -- subplan is built whether or not an earlier branch would have matched, so `chunks` sorting before
            -- `claims` does not spare the content read path.
            select string_agg(format('exists (select 1 from %s s where s.id = %I.chunk_id offset 0)',
                                     src.rel, v_tbl), ' or ' order by src.name)
              into v_using
              from (select s.name, to_regclass(s.source_table) as rel
                      from aiq.semantic_sources s) src
             where src.rel is not null
               and exists (select 1 from pg_attribute a
                            where a.attrelid = src.rel and a.attname = 'id'
                              and not a.attisdropped)
               and has_table_privilege(v_role, src.rel, 'select')
               -- Already written into the policy of a role this one inherits.
               and not exists (
                   select 1 from unnest(v_roles) p
                    where p <> v_role
                      and exists (select 1 from pg_roles where rolname = p)
                      and pg_has_role(v_role, p, 'member')
                      and has_table_privilege(p, v_rel, 'select')
                      and has_table_privilege(p, src.rel, 'select'));
            execute format('create policy %I on %s for select to %I using (%s)',
                           'space_read_' || v_role, v_rel, v_role, coalesce(v_using, 'false'));
        end loop;
    end loop;
end;
$$ language plpgsql set search_path = pg_catalog, public;

revoke execute on function aiq.police_embedding_spaces() from public;

create or replace function aiq.police_embedding_spaces_on_change()
returns trigger as $$
begin
    perform aiq.police_embedding_spaces();
    return null;
exception when insufficient_privilege then
    raise warning 'aiq: % does not own the embedding spaces, so their read policies '
                  'still name only the sources registered before this change (%). '
                  'Vectors of a new source stay hidden until the owner runs '
                  'aiq.police_embedding_spaces().', current_user, sqlerrm;
    return null;
end;
$$ language plpgsql;

revoke execute on function aiq.police_embedding_spaces_on_change() from public;

create or replace trigger trg_semantic_source_polices
    after insert or update of source_table or delete on aiq.semantic_sources
    for each statement execute function aiq.police_embedding_spaces_on_change();

-- A database from before REM-567 has spaces with RLS off; this turns it on.
select aiq.police_embedding_spaces();

-- ------------------------------------------------------------
-- 10b. Embedding a CORPUS, in batches, and why that is not the `embed:` step.
--
-- `embed:` is one text per call, and for a query that is exactly right: embed
-- the question, rank against it, discard the vector. For a corpus it is the
-- wrong unit by two orders of magnitude. A 300-chunk document fanned out as
-- one `embed:` child per chunk is 300 HTTP requests, 300 task rows and 300
-- round trips to a provider that accepts an array of 2048 inputs in one call.
--
-- IT CANNOT BE FIXED BY BATCHING THE FAN-OUT, and the reason is structural
-- rather than a missing feature: a step's output is capped
-- (workflow.max_payload_bytes, 64KB) and one 1536-dimension vector is ~31KB of
-- JSON. Two vectors do not fit in one task output. Any design that carries
-- corpus vectors through `tasks.output` is limited to batches of one or two,
-- whatever else it does -- so the vectors have to be written by the process
-- that received them, and what comes back to the engine is a receipt.
--
-- Hence these two functions: one hands a worker the request shape from the
-- registry (so the model, its url and its request body still live in exactly
-- one place), and the other takes the vectors back. The declarative
-- `embed:` + `land_embeddings` path stays exactly as it is and is still what
-- a query-shaped fan-out uses; it is simply not what a corpus uses.
-- ------------------------------------------------------------
alter table aiq.embedding_providers
    add column if not exists batch_request_template jsonb,
    add column if not exists batch_response_path text;

-- A PROVIDER MAY RUN IN THE WORKER RATHER THAN OVER HTTP (REM-628).
--
-- Every provider so far is a url and a request body, because every provider so
-- far was somebody else's service. A small ONNX model is not: it loads in the
-- worker and answers in milliseconds, so there is no url to call, no credential
-- to resolve and no request shape to describe. `in_process` says which kind a
-- row is, and it is the only thing about the model that the worker branches on.
--
-- The two template columns become nullable because an in-process provider has
-- nothing to put in them, and the check keeps them required for every provider
-- that is still a url: a row with neither a template nor in_process would
-- describe nothing, and the first thing to notice would be a worker asking an
-- endpoint of null for a vector.
alter table aiq.embedding_providers add column if not exists in_process boolean not null default false;
alter table aiq.embedding_providers alter column request_template drop not null;
alter table aiq.embedding_providers alter column response_path    drop not null;
alter table aiq.embedding_providers drop constraint if exists embedding_providers_describes_a_call;
alter table aiq.embedding_providers add constraint embedding_providers_describes_a_call
    check (in_process or (request_template is not null and response_path is not null));

-- The in-process provider (REM-628). No url, no credential, no bill: the
-- worker loads the model named by the model row's `endpoint` and answers from
-- memory. Kept in its own statement because its template columns are null and
-- the upsert above sets them from `excluded`.
insert into aiq.embedding_providers (provider, request_template, response_path, method, in_process, notes) values
    ('fastembed', null, null, 'LOCAL', true,
     'Runs in the worker through fastembed (ONNX, CPU, no torch). The model '
     'row''s endpoint is the model id the runtime loads, such as '
     'BAAI/bge-small-en-v1.5, not a url; credential_ref is not used.')
on conflict (provider) do update
    set request_template = excluded.request_template,
        response_path    = excluded.response_path,
        method           = excluded.method,
        in_process       = excluded.in_process,
        notes            = excluded.notes;

-- A MODEL MAY NOT NAME A PROVIDER THAT DOES NOT EXIST.
--
-- `embedding_models.provider` was free text with a comment ('ollama' | 'openai'
-- | ...) and `embedding_providers.provider` is a primary key declared seventy
-- lines above it in this same file -- a vocabulary table and a column that
-- should reference it, sitting next to each other, joined by nothing.
--
-- embed_call() already raises a good error for the mismatch, and that is the
-- problem rather than the mitigation: it raises at CALL time. A registration
-- naming a provider with no row installs clean, reports success, and surfaces
-- on somebody's first SEMANTIC search -- which is the furthest possible point
-- from the mistake. The foreign key moves it to the INSERT that made it.
--
-- Added by ALTER rather than in the CREATE TABLE because both tables already
-- exist in every installed database, and written drop-then-add so an upgrade
-- picks it up -- the discipline tasks_kind_check and runs_status_fk are
-- written with.
-- NULL IS A REAL ANSWER HERE, and adding the key is what made that visible.
--
-- `provider` was `not null`, and the fixture spaces the demo corpus registers
-- (`demo-quad-a`, `demo-quad-b`) satisfied it by inventing the word 'fixture'
-- -- a provider that is not one, has no request template, and would never have
-- matched a row in embedding_providers. It went unnoticed for exactly the
-- reason this key exists: nothing joined the two tables, so an invented word
-- and a real one were indistinguishable until something tried to embed with it.
--
-- A model whose vectors are supplied directly genuinely HAS no provider, so
-- the column is made nullable rather than the fiction being given a row. The
-- key then reads correctly in both directions: a name that is not null must
-- resolve, and null means "nothing here embeds this -- the vectors come from
-- outside". Dropping the NOT NULL is safe on an existing database; every row
-- that satisfied it still does.
alter table aiq.embedding_models alter column provider drop not null;
alter table aiq.embedding_models drop constraint if exists embedding_models_provider_fk;
alter table aiq.embedding_models add  constraint embedding_models_provider_fk
    foreign key (provider) references aiq.embedding_providers(provider);

comment on column aiq.embedding_models.provider is
    'References aiq.embedding_providers. NULL means this space is not embedded '
    'by this system -- its vectors are written directly, as the demo fixture '
    'spaces are -- so aiq.embed_call refuses it rather than guessing.';

comment on column aiq.embedding_providers.batch_request_template is
    'The request body for MANY texts at once, with {{texts}} where the array goes. '
    'Null means the provider embeds one text per call and a batch is N calls.';

-- OpenAI''s /v1/embeddings takes `input` as a string OR an array and answers
-- with `data` in input order. Ollama''s /api/embeddings takes one prompt, so
-- it keeps a null batch template and is called per text -- which is honest
-- rather than a limitation of this design.
update aiq.embedding_providers
   set batch_request_template = '{"model": "{{model}}", "input": "{{texts}}"}'::jsonb,
       batch_response_path    = 'data'
 where provider = 'openai' and batch_request_template is null;

-- Everything a worker needs to embed a batch, from the registry rather than
-- from a document: url, method, the body with the array substituted, where the
-- vectors are in the response, and the NAME of the credential to use.
--
-- Returns the same shape aiq.embed_call does for one text, deliberately: two
-- functions describing one endpoint differently is how a batch path starts
-- calling a different model than the single path.
create or replace function aiq.embed_batch_call(p_model text, p_texts jsonb)
returns jsonb as $$
declare
    m aiq.embedding_models;
    p aiq.embedding_providers;
    v_body jsonb;
    v_out  jsonb;
begin
    if p_model is null then
        select * into m from aiq.embedding_models where is_default;
    else
        select * into m from aiq.embedding_models where name = p_model;
    end if;
    if not found then
        raise exception
            'embedding model % is not registered -- SCHEMA "graph" lists the '
            'registered ones', coalesce(p_model, '(the default)');
    end if;

    -- Null is now reachable and means something specific, so it is answered
    -- specifically: a caller who asks a fixture space to embed text has made a
    -- different mistake from one who named a provider nobody registered, and
    -- one error message for both would send them to the wrong fix.
    if m.provider is null then
        raise exception
            'embedding model ''%'' has no provider: its vectors are written '
            'directly rather than produced here, so there is nothing to call. '
            'Set aiq.embedding_models.provider, or embed against a model that '
            'has one.', m.name;
    end if;

    select * into p from aiq.embedding_providers where provider = m.provider;
    if not found then
        raise exception
            'embedding model ''%'' is served by provider ''%'', which has no row in '
            'aiq.embedding_providers -- so nothing here knows what its request body '
            'looks like or where the vector sits in its response.', m.name, m.provider;
    end if;
    -- An in-process provider is answered here and returns before any of the
    -- url and body machinery below, which has nothing to say about it. The
    -- endpoint is still required and still means "where the model comes from":
    -- for a url provider that is a service, and for this one it is the model id
    -- the worker's runtime loads. A worker without that runtime installed fails
    -- the task naming the extra, which is a better failure than a null url.
    if p.in_process then
        if m.endpoint is null then
            raise exception
                'embedding model ''%'' runs in the worker (provider ''%''), so its '
                'endpoint must be the model id the runtime loads, such as '
                '''BAAI/bge-small-en-v1.5''. It is null.', m.name, m.provider;
        end if;
        return jsonb_build_object(
            'model',      m.name,
            'dim',        m.dim,
            'in_process', true,
            'provider',   m.provider,
            'model_id',   m.endpoint);
    end if;

    if m.endpoint is null then
        raise exception
            'embedding model ''%'' has no endpoint, so there is nowhere to send its '
            'text. Set aiq.embedding_models.endpoint.', m.name;
    end if;

    -- Whole VALUES only, exactly as embed_call does: the texts become a jsonb
    -- ARRAY rather than a string containing JSON, so the provider receives a
    -- list and the database did the escaping.
    if p.batch_request_template is not null then
        select jsonb_object_agg(k,
                   case when v = '"{{texts}}"'::jsonb then p_texts
                        when v = '"{{model}}"'::jsonb then to_jsonb(m.name)
                        else v end)
          into v_body
          from jsonb_each(p.batch_request_template) e(k, v);
    end if;

    v_out := jsonb_build_object(
        'model',     m.name,
        'dim',       m.dim,
        'url',       m.endpoint,
        'method',    p.method,
        'batch',     p.batch_request_template is not null,
        -- The single-text shapes too, so a provider that cannot batch is
        -- called N times by the same caller rather than by a second one.
        'single_template', p.request_template,
        'single_path',     p.response_path,
        'body',      v_body,
        'jsonpath',  coalesce(p.batch_response_path, p.response_path));

    if m.credential_ref is not null then
        v_out := v_out || jsonb_build_object('credential_ref', m.credential_ref);
    end if;
    return v_out;
end;
-- SECURITY DEFINER, and revoked from PUBLIC below rather than left open.
--
-- It reads aiq.embedding_models and aiq.embedding_providers on behalf of a
-- caller that holds no table grants anywhere -- which is the WORKER, by
-- design, and which is why "permission denied for table embedding_models" is
-- what the first batching run got. What it hands back is a url, a request
-- shape and the NAME of a credential; never a secret, and never a row of
-- anyone's content. Its authorization is its grant, the exemption
-- workflow-engine/integration-rbac.sql already states for worker-facing
-- functions -- so the grant has to be the only one, hence the revoke.
$$ language plpgsql stable security definer set search_path = pg_catalog, public;

revoke execute on function aiq.embed_batch_call(text, jsonb) from public;

-- Take the vectors back. One call for a whole batch, so a worker that embedded
-- 96 chunks writes them in one statement rather than 96.
--
-- p_rows: [{"chunk_id": uuid, "embedding": [floats]}, ...]
--
-- SECURITY DEFINER and granted to `worker` only: aiq.emb_* tables are owned by
-- app_owner and a worker holds no table grants at all, so the grant IS the
-- authorization -- the same exemption workflow-engine states for its own
-- worker-facing functions. It is not granted to `authenticated`, because a
-- user who could write vectors could poison what every SEMANTIC search in the
-- deployment ranks against.
create or replace function aiq.record_embeddings(p_model text, p_rows jsonb)
returns int as $$
declare
    m     aiq.embedding_models;
    v_tbl text;
    v_n   int;
begin
    select * into m from aiq.embedding_models where name = p_model;
    if not found then
        raise exception 'embedding model % is not registered', p_model;
    end if;
    -- Idempotent, so the space existing is not a precondition the caller has
    -- to arrange separately.
    perform aiq.register_embedding_space(m.name);
    v_tbl := aiq.embedding_space_name(m.name);

    execute format($q$
        insert into aiq.%1$I (chunk_id, embedding)
        select (r->>'chunk_id')::uuid,
               (select array_agg((v #>> '{}')::real order by ord)
                  from jsonb_array_elements(r->'embedding') with ordinality e(v, ord))::vector
        from jsonb_array_elements($1) r
        -- Re-embedding a chunk REPLACES its vector: a resource whose text
        -- changed must not leave the old vector ranking against the new text.
        on conflict (chunk_id) do update
            set embedding = excluded.embedding, embedded_at = now()
    $q$, v_tbl) using p_rows;
    get diagnostics v_n = row_count;
    return v_n;
end;
$$ language plpgsql security definer set search_path = pg_catalog, public;

revoke execute on function aiq.record_embeddings(text, jsonb) from public;

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
-- The space is policied as well (§10a-iii, REM-567), so a caller who selects
-- `aiq.emb_*` directly sees only the vectors of chunks they may read. This
-- join still does the scoping to one corpus.
-- THE ONE SETTING semantic_in CHANGES, changed on the caller's behalf.
--
-- semantic_in runs as its caller, so RLS filters the join by the caller's
-- rows. It used to set hnsw.iterative_scan with set_config, and the caller no
-- longer holds set_config: it was taken from every role a person can become,
-- because the same call writes request.jwt.claims (user-rbac/roles.sql §6).
-- A SET statement would do it without the function, and Postgres refuses a SET
-- inside a STABLE function, which semantic_in is. So this does it, as the
-- owner, for this one parameter and pgvector's three values of it, and nothing
-- else -- a definer that took the parameter name as an argument would be
-- set_config again under another name. The change is transaction-local and
-- outlives this call, which is what semantic_in's restore relies on.
create or replace function aiq.set_scan_order(p_value text)
returns void as $$
begin
    if p_value is null or p_value not in ('off', 'relaxed_order', 'strict_order') then
        raise exception 'hnsw.iterative_scan takes off, relaxed_order or strict_order, not %', p_value;
    end if;
    perform set_config('hnsw.iterative_scan', p_value, true);
end;
$$ language plpgsql volatile security definer set search_path = pg_catalog, public;

drop function if exists aiq.semantic_in(vector, text, int);
create or replace function aiq.semantic_in(
    p_source text, p_query vector, p_model text default null, p_limit int default 10
) returns table(chunk_id uuid, distance float8, model text) as $$
declare
    m aiq.embedding_models;
    src aiq.semantic_sources;
    v_tbl text;
    v_iter text;
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

    -- A model row and a model SPACE are two registrations, and only the first
    -- is this table. Registering the row and forgetting
    -- aiq.register_embedding_space() produced `relation "aiq.emb_x" does not
    -- exist` from inside a generated query -- a message naming an internal
    -- table, at query time, for a registration that was never made. It is the
    -- mirror of the case the workflow compiler already refuses (a space with
    -- no endpoint, so it can be searched and not embedded into), and it
    -- deserves the same treatment: say which registration is missing.
    v_tbl := aiq.embedding_space_name(m.name);
    if to_regclass('aiq.' || quote_ident(v_tbl)) is null then
        raise exception
            'embedding model % is registered but its space does not exist -- '
            'nothing can have been embedded into it. Create it with '
            'aiq.register_embedding_space(''%'').', m.name, m.name;
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

    -- THE JOIN IS THE FILTER, AND THE FILTER IS WHY THE INDEX MUST ITERATE.
    --
    -- `c` is the consumer's table, read as the caller, so the consumer's
    -- policies decide which chunks may rank at all -- and ranks are computed
    -- after it, so a chunk the caller cannot see does not silently occupy a
    -- position and shift everyone else's fused score. That is the precision
    -- half, and it has been right since 09-retrieval-tenancy.sql was written.
    --
    -- The RECALL half was wrong, and only above fixture scale. An HNSW scan
    -- with `hnsw.iterative_scan = off` -- pgvector's default -- yields a
    -- BOUNDED candidate set (ef_search, 40 by default) and is then exhausted.
    -- The join runs afterwards. So a tenant who owns a small share of a large
    -- corpus has every one of those candidates removed by their own policy and
    -- receives an EMPTY answer to a query that has a thousand correct ones:
    -- measured at 200k chunks, a tenant holding 0.5% of them asked for 10 and
    -- got 0, and asking for 50 also got 0 -- because the limit is not what
    -- bounds the index scan. Nothing raises. `aiq.search` inherits it and
    -- degrades to lexical-only while still reporting success, which is the
    -- worse half: its `semantic_rank` is null on every row and no other symptom
    -- exists.
    --
    -- Six chunks cannot show this. Below a few thousand rows the planner does
    -- not choose the HNSW index at all, so every test in dev/tests/query
    -- exercised the exact path and passed.
    --
    -- `strict_order` makes the scan resume instead of stopping, and it is
    -- strict rather than relaxed because aiq.search fuses these ranks with RRF
    -- and relaxed ordering would corrupt the rank it fuses on. Measured cost at
    -- 200k chunks: on the common path -- a caller who can see most of the
    -- corpus -- 0.86 ms p50 against 0.94 ms with it off, which is noise. On the
    -- narrow-tenant path it is 29 ms against 1.5 ms, and that is the trade
    -- being made deliberately: a right answer in 29 ms beats an empty one in
    -- 1.5 ms.
    --
    -- The residue is `hnsw.max_scan_tuples` (20000 by default), which bounds
    -- the resumed scan. A tenant owning a small enough share of a large enough
    -- corpus still gets a SHORT answer rather than a full one -- but a short
    -- best effort under a named ceiling, not silence. Operators with very
    -- narrow tenants should raise it.
    --
    -- Probed rather than assumed, and probed HERE rather than in the function
    -- header: `create function ... set hnsw.iterative_scan` is refused at
    -- install time because pgvector's GUCs are registered when its module
    -- loads, not when the extension is created, so the parameter is still an
    -- unrecognised placeholder and only a superuser may name one. By this line
    -- vector_dims() above has loaded the module, so current_setting() answers
    -- and an end-user role may set it -- through aiq.set_scan_order, since the
    -- caller no longer holds set_config itself.
    v_iter := current_setting('hnsw.iterative_scan', true);
    if v_iter is not null and v_iter <> 'strict_order' then
        perform aiq.set_scan_order('strict_order');
    end if;

    return query execute format(
        'select e.chunk_id, (e.embedding <=> $1)::float8, %L
         from aiq.%I e
         join %s c on c.id = e.chunk_id
         order by e.embedding <=> $1 limit $2', m.name, v_tbl, src.source_table)
        using p_query, p_limit;

    -- Restored rather than left set, because SET LOCAL lasts to the end of the
    -- caller's TRANSACTION and not the end of this function. Leaving it on
    -- would silently change the index behaviour of every later vector query in
    -- the same transaction, including ones this layer did not write.
    if v_iter is not null and v_iter <> 'strict_order' then
        perform aiq.set_scan_order(v_iter);
    end if;
end;
$$ language plpgsql stable security invoker;   -- caller's RLS, deliberately

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

create table if not exists aiq.lexical_sources (
    name         text primary key,
    source_table text not null,
    content_col  text not null default 'content',
    regconfig    text not null default 'english'
);
comment on table aiq.lexical_sources is
    'Which column of which table is full-text searchable, and which function searches it.';

-- SHIPPED BY THE EXTENSION, OR ADDED BY THIS DEPLOYMENT. aiq.lexical_sources holds
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
alter table aiq.lexical_sources add column if not exists shipped boolean not null default false;
alter table aiq.lexical_sources alter column shipped set default
    (coalesce(current_setting('percolate.seeding', true), 'off') = 'on');

-- A SOURCE WITH ITS OWN SEARCH, which aiq.lexical refuses (REM-519). Under row
-- security the policy runs on every row before `@@`, because ts_match_vq is not
-- leakproof, so a search as the caller reads the whole table: 3 to 7 minutes
-- over 960 K research claims (specs/research-platform/scale.md §2). A schema
-- whose policy is that expensive writes a definer search that asks the index
-- first and readability of each candidate, and names it here; aiq.lexical then
-- refuses the source and names the function. Null for every other source, and
-- `chunks` and `skills` stay searchable as the caller, by design (the note
-- above aiq.search).
alter table aiq.lexical_sources add column if not exists search_with text;

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
        content_col = excluded.content_col, regconfig = excluded.regconfig,
        shipped = excluded.shipped or lexical_sources.shipped;

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
    if s.search_with is not null then
        raise exception 'lexical source % is searched with %, not aiq.lexical', p_source, s.search_with
            using errcode = 'feature_not_supported',
                  hint = 'as the caller, its row security reads every row before the text index (REM-519)';
    end if;
    return query execute format(
        'select c.id, c.%I::text, ts_rank(c.search_tsv, plainto_tsquery(%L, $1))::real
         from %s c where c.search_tsv @@ plainto_tsquery(%L, $1)
         order by ts_rank(c.search_tsv, plainto_tsquery(%L, $1)) desc limit $2',
        s.content_col, s.regconfig, s.source_table, s.regconfig, s.regconfig)
        using p_query, p_limit;
end;
$$ language plpgsql stable security invoker;   -- caller's RLS, deliberately

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
-- ------------------------------------------------------------
-- RETRIEVAL IS `SECURITY INVOKER`, AND THAT IS THE WHOLE OF THE TENANT
-- BOUNDARY ON THE READ PATH.
--
-- Every mode below -- SEARCH, TEXT, SEMANTIC, LOOKUP, GRAPH -- runs as the
-- CALLER, so the RLS policies on the underlying sources apply inside the
-- search. Two users over one corpus get different result sets from the same
-- query, and neither can reach the other's `private` rows.
--
-- Make one of them `security definer` and the tables still look correctly
-- protected while every tenant's chunks come back to everyone: the policies are
-- intact, and nothing evaluates them. That is the classic retrieval leak, and
-- it is a one-word edit away at all times -- which is why it is written down
-- here and spelled out on each function rather than left to the default.
--
-- The pressure to make the edit is real and will recur: a definer function
-- needs no grant on the source tables, so `permission denied for table chunks`
-- looks like it is asking for one. It is asking for a GRANT, not for DEFINER.
--
-- The exceptions are deliberate and are not retrieval: `sql_passthrough` (§12)
-- is invoker for the same reason, and the catalog/registry helpers that read
-- only this schema's own configuration are definer because there is no tenant
-- data in them to scope.
-- ------------------------------------------------------------

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
$$ language plpgsql stable security invoker;   -- caller's RLS, deliberately

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
    v_max    int;
    v_cur    refcursor;
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
    --
    -- AND IT IS UNWOUND AFTERWARDS, which the first version did not do.
    --
    -- Transaction-local means "until this transaction ends", not "until this
    -- function returns" -- so a caller that ran this and then tried to write in
    -- the same transaction got `cannot execute UPDATE in a read-only
    -- transaction`, from a line nowhere near the query. It never bit over
    -- PostgREST, where every call is its own transaction; it bites the moment
    -- something composes -- a workflow step that runs a query and then marks
    -- its own task done, which is exactly what workflow.p8ql now does.
    --
    -- Setting it back is not available: `transaction_read_only = off` inside a
    -- read-only transaction raises 25001. A subtransaction is the only way
    -- back, so the read runs in one and the block is deliberately unwound --
    -- the rows are in a plpgsql variable by then, and a variable is not
    -- transactional.
    --
    -- A SET statement and not set_config(), because the caller here is a person
    -- and a person no longer holds set_config: the same function writes
    -- request.jwt.claims, and through this very passthrough it was how anyone
    -- became anyone (user-rbac/roles.sql §6). SET needs no grant, so wrapping
    -- the caller's statement as a subquery is NOT enough to keep one out: the
    -- `(%s) _p8_passthrough` bracket is closable, and `select 1) _p8_passthrough
    -- limit 1) t; set local request.jwt.claims = '{"sub":"<victim>"}'; select
    -- ... from (select <victim's rows>` read as the victim under plain EXECUTE
    -- (measured -- the same REM-64 break-out execute_as_viewer took). So the
    -- statement is OPENED AS A CURSOR below, which SPI refuses to open on a
    -- multi-statement string and parses whole before running any of it -- the
    -- grammar keeps it to one query, which the subquery wrapping alone did not.
    -- AND A ROW CAP, because read-only is not the same as bounded (REM-113).
    -- The aggregate below builds one jsonb value out of the whole result set,
    -- in memory, in the server -- so `select * from aiq.nodes` is a read that
    -- cannot write anything and can still take the backend down. The
    -- transaction_read_only boundary above says nothing about size.
    --
    -- REFUSED RATHER THAN TRUNCATED. Silently returning the first N rows is the
    -- worse failure: the caller gets a well-formed answer to a question they
    -- did not ask and cannot tell. So it fetches one more than the cap and
    -- raises if that row exists, naming the cap and what to do about it.
    --
    -- The LIMIT is inside its own subquery rather than on the aggregate, which
    -- would bound the one row the aggregate returns and nothing else.
    --
    -- Through current_setting so an operator can raise it per database or per
    -- role without a schema change -- the same shape as the timeouts in
    -- dev/image-init/00-superuser.sql, rather than a literal somebody has to
    -- find. `true` makes it missing-safe, and the coalesce is the default.
    v_max := coalesce(
        nullif(current_setting('percolate.sql_passthrough_max_rows', true), '')::int,
        10000);

    begin
        set local transaction_read_only = on;
        begin
            open v_cur for execute format(
                'select coalesce(jsonb_agg(t), ''[]''::jsonb) from '
                '(select * from (%s) _p8_passthrough limit %s) t',
                p_statement, v_max + 1);
            fetch v_cur into v_result;
            close v_cur;
        exception when syntax_error or invalid_cursor_definition then
            raise exception
                'the SQL passthrough runs a single read query, and this is not (%)', sqlerrm
                using errcode = 'syntax_error',
                      hint = 'a SET or a second statement would change whose rows are read; '
                             'write the read as one query';
        end;
        if jsonb_array_length(v_result) > v_max then
            raise exception
                'the SQL passthrough returned more than % rows. It aggregates the '
                'whole result set into one jsonb value in the server, so it is '
                'capped. Add a LIMIT, or aggregate in the statement itself.', v_max
                using errcode = 'program_limit_exceeded',
                      hint = 'percolate.sql_passthrough_max_rows raises the cap.';
        end if;
        raise exception using errcode = 'P0001', message = '__aiq_readonly_done__';
    exception when others then
        if sqlerrm <> '__aiq_readonly_done__' then
            raise;
        end if;
    end;

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
-- ------------------------------------------------------------
-- 13a. PROGRESSIVE DISCLOSURE, which is the contract every facet owes.
--
-- SCHEMA answers at three depths, and each depth names the next:
--
--   L0  SCHEMA                      which facets exist, and the query for each
--   L1  SCHEMA "<facet>"            the VOCABULARY of that facet: every name
--                                   you may use, with enough to choose between
--                                   them
--   L2  SCHEMA "<facet>" FROM <n>   the DETAIL of one name
--
-- THE RULE THAT DECIDES WHICH LEVEL A FIELD BELONGS TO: L1 must be answerable
-- BEFORE you know which name you want; L2 is what you ask once you do. So
-- per-instance detail -- every column of every relation, every (src, dst)
-- triple of every relation type -- is L2 by construction, and a per-name fact
-- that helps you CHOOSE (a description, a count, whether RLS applies) is L1.
--
-- WHY THIS IS A CONTRACT AND NOT A PREFERENCE. Both facets that dump detail at
-- L1 grew past `workflow.max_payload_bytes` (65,536), which means a `sql` step
-- calling them fails terminally -- and `p8ql-schema-first`, the skill shipped
-- with the sample agent, tells every agent to call SCHEMA FIRST. Two correct
-- designs that could not both be followed. Measured, as `authenticated`:
--
--     SCHEMA "graph"   83,598 -> 8,599 bytes   (439 triples -> 19 relations)
--     SCHEMA "sql"     71,482 -> 11,549        (60 relations, columns moved to L2)
--
-- Not one fact was dropped; both are reachable at L2. All four facets together
-- are now 43,616 bytes, so an agent can read the WHOLE schema and still fit in
-- one step's output, which is the property that makes "start with SCHEMA"
-- followable advice rather than a trap.
--
-- The cost of the L1 dump was never only the limit, either: 94% of the graph
-- facet was one `relations` array repeating each per-relation fact once per
-- pair, including one identical `description` string 439 times for 18KB. That
-- is paid in context on every conversation's first call, limit or no limit.
--
-- Found by walking scenarios/evals/J1-mill-lane.md Act 6, where the workflow a
-- user would actually write failed on it; runs/2026-09-04-J1.md §3.2.
-- `dev/tests/query/03-schema.sql` §7 holds the contract: every registered
-- facet fits the budget at L1, states how to narrow, and narrows to something
-- smaller.
-- ------------------------------------------------------------
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
comment on table aiq.schema_facets is
    'The registry behind SCHEMA mode: each facet''s provider function, its description, and whether its answer is scoped to the caller.';

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
comment on table aiq.schema_examples is
    'Worked examples attached to a facet, so the capability document shows rather than only describes.';

-- SHIPPED BY THE EXTENSION, OR ADDED BY THIS DEPLOYMENT. aiq.schema_examples holds
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
alter table aiq.schema_examples add column if not exists shipped boolean not null default false;
alter table aiq.schema_examples alter column shipped set default
    (coalesce(current_setting('percolate.seeding', true), 'off') = 'on');

create or replace function aiq.register_schema_example(
    p_facet text, p_label text, p_kind text, p_example text,
    p_note text default null, p_ordinal int default 100
) returns void as $$
    insert into aiq.schema_examples (facet, label, kind, example, note, ordinal)
    values (lower(p_facet), p_label, p_kind, p_example, p_note, p_ordinal)
    on conflict (facet, label) do update set kind = excluded.kind,
        example = excluded.example, note = excluded.note, ordinal = excluded.ordinal,
        shipped = excluded.shipped or schema_examples.shipped;
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
comment on table aiq.schema_revisions is
    'A hash of each facet''s answer over time, so drift in what the database says about itself is visible.';
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
                                    'name', name, 'regconfig', regconfig, 'search_with', search_with) order by name)
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
            -- The agents THIS CALLER may read, not every agent. This function
            -- is SECURITY DEFINER, so the `agents_scoped` policy never runs
            -- here and the row question has to be asked by name; it used to
            -- list every agent's name and model to any signed-in caller -- the
            -- probe 2e5995e removed from may_invoke, still open one function
            -- over (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md).
            -- A connection with no claims is an operator, as everywhere else.
            'agents', coalesce((select jsonb_agg(jsonb_build_object(
                    'name', a.name, 'model', a.model) order by a.name)
                from agentic.agents a
                where rbac.is_operator()
                   or rbac.may_read(a.owner_id, a.org_id, a.visibility)), '[]'::jsonb),
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
                    'callable', (m.endpoint is not null and p.provider is not null),
                    'space_exists', to_regclass('aiq.' ||
                        quote_ident(aiq.embedding_space_name(m.name))) is not null)
                    order by m.name)
                from aiq.embedding_models m
                left join aiq.embedding_providers p on p.provider = m.provider), '[]'::jsonb),
            'embedding_note', 'Two registrations, and they fail differently: `callable` is '
                              'the endpoint and provider an embed STEP needs, `space_exists` '
                              'is the table a SEARCH reads. A model can be one without the '
                              'other, and each missing half is refused by name rather than '
                              'surfacing as a 404 or a missing relation. '
                              'An `embed:` step names a model, never a url: the endpoint, '
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
                    -- COLUMNS AND CONSTRAINTS ARE LEVEL-2 DETAIL -- §13a.
                    -- Unnarrowed, this facet answers "which relations may I
                    -- read", which is the question you have BEFORE you know
                    -- which one you want; every column of every one of them is
                    -- what you ask for once you have chosen. Measured as
                    -- `authenticated` on a dev database: 60 relations with
                    -- every column is 70,600 bytes, which is over
                    -- workflow.max_payload_bytes, while `SCHEMA "sql" FROM
                    -- chunks` is 880. The directory is a twentieth of the size
                    -- and is what the narrowing pointer is FOR.
                    --
                    -- `column_count` stays because it is the one per-relation
                    -- fact that helps you choose, and because a relation that
                    -- reports columns and then returns none on narrowing is a
                    -- difference worth being able to see.
                    'column_count', (
                        select count(*) from pg_attribute a
                        where a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped),
                    'columns', case when p_name is null then null else (
                        select jsonb_agg(jsonb_build_object(
                            'name', a.attname,
                            'type', format_type(a.atttypid, a.atttypmod),
                            'not_null', a.attnotnull,
                            'default', pg_get_expr(d.adbin, d.adrelid))
                        order by a.attnum)
                        from pg_attribute a
                        left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                        where a.attrelid = v.oid and a.attnum > 0 and not a.attisdropped) end,
                    'constraints', case when p_name is null then null else (
                        select jsonb_agg(jsonb_build_object(
                            'name', co.conname, 'definition', pg_get_constraintdef(co.oid))
                        order by co.conname)
                        from pg_constraint co where co.conrelid = v.oid) end)
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
                         'once and the walk proceeds by id, never by name.',
            -- The level-2 pointer. Every facet states one, because a document
            -- that has deliberately withheld detail owes the reader the query
            -- that produces it -- see §13a.
            'narrow_with', 'SCHEMA "graph" FROM <entity_type|relation> -- the (src, dst) '
                           'pairs and sample keys for one name, rather than the vocabulary.'),
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
            -- therefore does NOT get the RLS that protects aiq.nodes. Without it
            -- the facet would be a cross-tenant key disclosure dressed as
            -- documentation.
            --
            -- THE ROW'S QUESTION, rbac.may_read, and not the org's. This was
            -- "the nodes_org_scoped policy written out by hand", and the policy
            -- moved on to owner and visibility while the hand copy stayed on
            -- the org: every node on the shared tier qualified, private or not,
            -- so anybody signed in was shown up to three canonical keys of
            -- other people's private nodes of each type. The sibling of
            -- 75abb1d's resolve_file fix, found by declaring how each reachable
            -- definer authorizes (dev/tests/rbac/14, REM-46).
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
                                 and rbac.may_read(n.owner_id, n.org_id, n.visibility)
                               order by nk.key
                               limit 3) k), '[]'::jsonb))
                    order by r.entity_type)
                from aiq.entity_registry r
                where p_name is null or r.entity_type = p_name), '[]'::jsonb),
            -- ONE ENTRY PER RELATION, NOT PER TRIPLE -- §13a, progressive
            -- disclosure. aiq.relation_types is src_type x relation x dst_type,
            -- so emitting it row-wise repeats every per-RELATION fact once per
            -- pair: measured on six entity types and nineteen relations, 439
            -- rows, 78,250 bytes, of which one identical `description` string
            -- appeared 439 times for 18KB, and twelve of the nineteen relations
            -- admitted all thirty-six pairs. Grouped, with the universal case
            -- collapsed to `* > *`: 3,050 bytes. Twenty-five times smaller and
            -- not one fact fewer.
            --
            -- That mattered because the row-wise form put this facet 1.27x OVER
            -- workflow.max_payload_bytes, so a `sql` step calling the mode that
            -- `p8ql-schema-first` tells every agent to call FIRST failed
            -- terminally. Found by walking scenarios/evals/J1-mill-lane.md Act
            -- 6; the run log is runs/2026-09-04-J1.md §3.2.
            --
            -- `pairs` is the level-2 detail: which (src, dst) a relation admits
            -- is what you need once you have CHOSEN a relation, and the choice
            -- is made from the name and the description. A caller who wants the
            -- triples for one type asks `SCHEMA "graph" FROM <entity_type>`.
            'relations', coalesce((
                select jsonb_agg(z.entry order by z.rel)
                from (
                    select relation as rel,
                           jsonb_build_object(
                               'relation', relation,
                               'description', min(description),
                               'inverse_label', min(inverse_label),
                               -- Coalesced, because the column is nullable to
                               -- keep "undeclared" distinct from "declared
                               -- false" INSIDE the catalogue; a consumer reading
                               -- the published shape wants the effective answer,
                               -- and null would only invite each of them to
                               -- coalesce it again differently.
                               'is_symmetric', bool_or(coalesce(is_symmetric, false)),
                               'pairs', case
                                   when p_name is null
                                    and count(*) = (select count(*) * count(*)
                                                      from aiq.entity_registry)
                                   then jsonb_build_array('* > *')
                                   else jsonb_agg(distinct src_type || ' > ' || dst_type)
                               end) as entry
                    from aiq.relation_types
                    where p_name is null
                       or p_name in (src_type, relation, dst_type)
                    group by relation) z), '[]'::jsonb),
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
    'DEPTH applies to GRAPH and PATH, TYPE to GRAPH, PATH and RELEVANCE; '
    'written elsewhere they are refused, not ignored.', 20);
select aiq.register_schema_example('p8ql', 'path', 'p8ql',
    'PATH "acme", "nwnd" LIMIT 3',
    'Two names is the three cheapest routes between them, ordered. Three or '
    'more names is the smallest subgraph joining all of them -- the same '
    'question generalised, because a shortest path is the Steiner tree of two '
    'terminals. DEPTH bounds the longest route worth considering.', 27);
select aiq.register_schema_example('p8ql', 'relevance', 'p8ql',
    'RELEVANCE "acme", "ndlr" LIMIT 10',
    'Ranked, not depth-capped: GRAPH answers "what is within n hops", this '
    'answers "what matters most", and DEPTH is refused here for that reason. '
    'Takes a list, because relatedness to a SET of seeds is the question an '
    'agent holding several entities actually has.', 25);
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
    'Depth 1 is one hop each way. Both directions come back; an inbound edge is '
    'labelled with the catalogue''s inverse label, and that label works as a '
    'TYPE filter too.', 10);
select aiq.register_schema_example('graph', 'typed-walk', 'p8ql',
    'GRAPH "ACME" DEPTH 2 TYPE competes_with',
    'DEPTH above 1 falls back to WITH RECURSIVE -- PG19 has no quantified path '
    'patterns. One row per node at its shortest depth, ordered by depth then by '
    'the product of the edge weights along the path.', 20);
select aiq.register_schema_example('graph', 'ranked', 'p8ql',
    'RELEVANCE "ACME" TYPE competes_with LIMIT 10',
    'The mode that is not a walk. It runs in the compiled extension and ships '
    'switched off -- aiq.enable_graph_algorithms(role) turns it on -- and it '
    'reports `exhausted` because it is budgeted: "nothing else is related" and '
    '"I ran out of time" are different answers.', 25);
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
