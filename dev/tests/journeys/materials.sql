-- THE RAW MATERIAL A JOURNEY EVAL DRAWS ON -- and nothing else.
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8journey -v ON_ERROR_STOP=1 \
--         < dev/tests/journeys/materials.sql
--
-- WHAT IS AND IS NOT IN HERE, because the split is the whole design.
--
-- A journey eval (`scenarios/evals/`) is performed by an agent acting AS a
-- user: creating the orgs, signing the people up, uploading the files, asking
-- the questions. So this file contains NO orgs, NO users, NO memberships, NO
-- agents and NO runs. Every one of those is a thing a user does, and a fixture
-- that pre-creates them is a fixture that has already performed the half of the
-- journey most likely to be broken -- which is the failure
-- our user-rbac review of 4 September records twice over: the signup
-- path and the theft-detection branch were both DECLARED, shipped, and never
-- once executed, and both were found by the first transaction that ran them.
--
-- What is in here is the material those users act ON: the bodies of the files
-- they upload, the chunks a parser would have produced from them, the graph an
-- extractor would have proposed, and the workflow definitions they author.
-- Inert rows. Nothing here calls a percolate function, so loading it cannot
-- make a journey pass.
--
-- THE VECTORS ARE LITERALS, NOT MODEL OUTPUT, for the reason
-- `dev/init/05-corpus-sample.sql` states at length: a fixture that needs a
-- model server running to be reproducible is the "works on the machine where
-- somebody ran it" failure wearing a fixture's clothes. They live in the
-- `demo-quad-a` space that file registers -- four dimensions, one per theme, so
-- that which chunk wins which query is arithmetic a reader checks by eye rather
-- than a property of whichever model happened to be installed:
--
--     dim 1  scour and hydrology      dim 3  consent and planning
--     dim 2  bearings and structure   dim 4  cost and procurement
--
-- GRANTED TO NOBODY. `authenticated` and `web_anon` get nothing here, so this
-- schema cannot appear in the read surface `dev/tests/rbac/05` enumerates. That
-- matters because the enumeration is the point of that test: a table granted to
-- an application role and carrying no policy is exactly the defect it was
-- written to find, and a fixture that added one would be teaching the gate to
-- accept the shape it exists to refuse. Load this into a journey database
-- anyway -- never into the one the suite runs against.

\set ON_ERROR_STOP on

do $$
begin
    if to_regclass('content.resource_chunks') is null
       or not exists (select 1 from aiq.embedding_models where name = 'demo-quad-a') then
        raise exception
            'this database has no content plane or no demo-quad-a space, so the '
            'journey materials would be unusable. Build a journey database the '
            'way dev/tests/journeys/README.md says: dev/reload.sh p8journey';
    end if;
end $$;

set role app_owner;

drop schema if exists journey cascade;
create schema journey;

-- ---------------------------------------------------------------------
-- 1. THE FILES. Bodies, not paths: a journey uploads bytes it can show.
--
-- `content_type` and `size_bytes` are what `content.register_upload` asks for,
-- and `checksum` is what makes a re-upload of the same bytes recognisable as
-- the same file -- which is one of the things J1 Act 3 goes looking for.
-- ---------------------------------------------------------------------
create table journey.documents (
    slug         text primary key,
    title        text not null,
    content_type text not null,
    owner_hint   text not null,   -- which cast member would plausibly upload it
    body         text not null,
    size_bytes   bigint generated always as (octet_length(body)) stored,
    checksum     text generated always as (md5(body)) stored
);

comment on column journey.documents.owner_hint is
    'A HINT, not an instruction. The journey says who uploads what; this column '
    'exists so a performer who wants a second document for an improvised step '
    'can pick a plausible one rather than inventing bytes.';

insert into journey.documents (slug, title, content_type, owner_hint, body) values

('scour-survey', 'Mill Lane footbridge - river scour survey', 'text/markdown', 'nour', $doc$
# Mill Lane footbridge: river scour survey

Bed level readings were taken at eleven cross-sections over the November
freshet. The scour hole at the north abutment has deepened by 340mm since the
2024 survey, and the measured depth now sits 120mm below the underside of the
pile cap. Riprap placed in 2019 has migrated approximately four metres
downstream and no longer armours the abutment toe.

Recommendation: the north abutment requires either extended scour protection
or an underpinning scheme before the next high-flow season. Design flow for
the reassessment should be the 1-in-100 year event with a climate allowance of
25 percent, not the 1-in-50 used in the original design.
$doc$),

('bearing-inspection', 'Mill Lane footbridge - bearing and deck inspection', 'text/markdown', 'nour', $doc$
# Mill Lane footbridge: bearing and deck inspection

Both elastomeric bearings at the south abutment show visible bulging and
surface cracking consistent with age hardening. Movement capacity appears
reduced; the deck is showing restraint cracking at the south end which is
consistent with bearings that have stopped articulating.

The steel deck plate is otherwise sound. Coating breakdown is limited to the
handrail fixings. Recommendation: replace both south bearings, and re-check
the north pair against the movement demand implied by the revised thermal
range.
$doc$),

('consent-note', 'Mill Lane footbridge - planning and consent position', 'text/markdown', 'nour', $doc$
# Mill Lane footbridge: planning and consent position

The bridge sits within the Mill Lane conservation area, so any change to the
visible profile requires listed structure consent. Works below the waterline
additionally require a flood risk activity permit from the environment
authority, which has a statutory determination period of thirteen weeks.

An underpinning scheme confined to below-water works does not alter the
visible profile and would therefore need the permit but not the consent. A
scheme that raises the deck does need both, and the consent should be assumed
to run in parallel rather than in series with the permit.
$doc$),

('cost-plan', 'Mill Lane footbridge - outline cost plan', 'text/markdown', 'bram', $doc$
# Mill Lane footbridge: outline cost plan

Two options were priced at outline stage. Option A, extended scour protection
with rock mattresses, carries a construction cost of GBP 180,000 and a
programme of nine weeks. Option B, underpinning the north abutment with mini
piles, carries a construction cost of GBP 410,000 and a programme of twenty-two
weeks including the permit determination period.

Neither figure includes bearing replacement, priced separately at GBP 65,000.
Option B is the only one that removes the need to revisit the abutment within
the next twenty-five years.
$doc$),

-- Kestrel's own document. It exists so that Act 8 can prove tenancy in the
-- direction that actually matters: not "the stranger sees nothing", which an
-- empty database also satisfies, but "the stranger sees THEIR OWN row and not
-- the other tenant's". A test whose pass condition is emptiness passes on a
-- broken query, a wrong seat and an unseeded fixture alike.
('kestrel-check', 'Kestrel Structural - independent category 3 check', 'text/markdown', 'ivy', $doc$
# Mill Lane footbridge: independent category 3 check

Reviewed the north abutment reassessment against the revised design flow. The
capacity check is accepted subject to two comments.

First, the pile cap underside level used in the scour comparison is taken from
the 1998 record drawing and has not been verified on site; the survey should
confirm it before the underpinning depth is fixed. Second, the thermal range
used for the bearing movement demand is the pre-2021 value and should be
updated, which will increase the demand by approximately 15 percent.
$doc$);

-- ---------------------------------------------------------------------
-- 2. THE CHUNKS a parser would have produced, with their vectors.
--
-- One row per span, with the offsets `content.record_chunks` requires. The key
-- set it accepts is checked BEFORE the delete and a wrong spelling is refused
-- by name -- that refusal is `upload-13` in dev/tests/evals, and the spelling
-- here is the one it accepts. If a journey step finds otherwise, that is a
-- finding and not a fixture bug.
--
-- The vectors are near-unit along one theme each, so a query vector along an
-- axis ranks its own chunks first and the others last, in an order a reader can
-- verify without running anything.
-- ---------------------------------------------------------------------
create table journey.chunks (
    doc_slug     text not null references journey.documents(slug),
    ordinal      int  not null,
    start_offset int  not null,
    end_offset   int  not null,
    content      text not null,
    embedding    vector(4) not null,
    primary key (doc_slug, ordinal)
);

insert into journey.chunks (doc_slug, ordinal, start_offset, end_offset, content, embedding) values
('scour-survey', 0, 0, 300,
 'Bed level readings at eleven cross-sections. The scour hole at the north abutment deepened 340mm since 2024 and now sits 120mm below the underside of the pile cap.',
 '[0.97,0.10,0.10,0.10]'),
('scour-survey', 1, 300, 620,
 'Riprap placed in 2019 migrated four metres downstream and no longer armours the abutment toe. Design flow should be the 1-in-100 year event with a 25 percent climate allowance.',
 '[0.94,0.14,0.20,0.10]'),

('bearing-inspection', 0, 0, 290,
 'Both elastomeric bearings at the south abutment show bulging and surface cracking consistent with age hardening. Movement capacity appears reduced.',
 '[0.10,0.97,0.10,0.10]'),
('bearing-inspection', 1, 290, 560,
 'Restraint cracking at the south end of the deck is consistent with bearings that have stopped articulating. Replace both south bearings and re-check the north pair.',
 '[0.12,0.95,0.10,0.14]'),

('consent-note', 0, 0, 320,
 'The bridge sits within the Mill Lane conservation area, so any change to the visible profile requires listed structure consent.',
 '[0.10,0.10,0.97,0.10]'),
('consent-note', 1, 320, 640,
 'Works below the waterline require a flood risk activity permit with a statutory determination period of thirteen weeks. Consent should run in parallel rather than in series.',
 '[0.22,0.10,0.93,0.14]'),

('cost-plan', 0, 0, 300,
 'Option A, extended scour protection with rock mattresses, is GBP 180,000 over nine weeks. Option B, underpinning with mini piles, is GBP 410,000 over twenty-two weeks.',
 '[0.24,0.10,0.14,0.94]'),
('cost-plan', 1, 300, 540,
 'Bearing replacement is priced separately at GBP 65,000. Option B is the only option that removes the need to revisit the abutment within twenty-five years.',
 '[0.10,0.26,0.10,0.94]'),

('kestrel-check', 0, 0, 300,
 'The pile cap underside level used in the scour comparison comes from the 1998 record drawing and has not been verified on site.',
 '[0.90,0.14,0.10,0.10]'),
('kestrel-check', 1, 300, 560,
 'The thermal range used for the bearing movement demand is the pre-2021 value and should be updated, increasing the demand by approximately 15 percent.',
 '[0.14,0.90,0.10,0.10]');

-- The query vectors, named, so a journey step says "ask the scour question"
-- rather than pasting sixteen digits -- and so the EXPECTED WINNER is written
-- down beside the vector instead of being decided after the result is seen.
-- A step whose expectation is formed after the answer is a step that cannot
-- fail, which is the class our postmortems call the largest here.
--
-- NOT ON THE AXES, AND THAT IS THE WHOLE POINT OF THESE PARTICULAR DIGITS.
-- The first version of this table used exact unit vectors -- [1,0,0,0] and so
-- on -- and `dev/init/05-corpus-sample.sql` uses exact unit vectors too. They
-- collided perfectly: on the first performance of J1 all four probes were won
-- at distance 0.0000 by dev-sample chunks belonging to nobody in the journey,
-- and Act 4 was void. See runs/2026-09-04-J1.md §3.7.
--
-- The part worth not repeating is HOW IT WAS VERIFIED, not what the numbers
-- were. The header claimed all four probes rank their expect_top_doc first and
-- that was checked against `journey.chunks` ALONE -- which is the one place the
-- interference cannot appear, because the corpus `aiq` actually ranks over is
-- `content.resource_chunks`, and this README calls the dev samples sitting in
-- it "a feature: another tenant's data in the same tables". The interference
-- was designed in and then verified where it was invisible.
--
-- So these are the centroid direction of each theme's own chunks -- where a
-- real query embedding would sit -- and the assertion below checks them against
-- the LIVE corpus rather than against this file's own rows.
create table journey.probes (
    name           text primary key,
    asks           text not null,
    embedding      vector(4) not null,
    expect_top_doc text not null references journey.documents(slug),
    because        text not null
);

insert into journey.probes (name, asks, embedding, expect_top_doc, because) values
('scour',   'How bad is the scour at the north abutment?',
 '[0.97,0.10,0.11,0.10]', 'scour-survey',
 'dim 1 is the hydrology axis and the survey chunks are the only near-unit vectors on it'),
('bearings','What is wrong with the bearings?',
 '[0.11,0.96,0.10,0.12]', 'bearing-inspection',
 'dim 2 is the structural axis; the Kestrel check is second on it, which is the point of Act 9'),
('consent', 'What consents do we need before we can start?',
 '[0.16,0.10,0.95,0.12]', 'consent-note',
 'dim 3 is the consent axis and no other document is near it'),
('cost',    'What will each option cost?',
 '[0.17,0.18,0.12,0.94]', 'cost-plan',
 'dim 4 is the commercial axis; the cost plan is the only document on it');

-- EVERY PROBE MUST BE NEARER ITS OWN CHUNK THAN ANY CHUNK ALREADY IN THE
-- CORPUS. This is the check whose absence voided Act 4 on the first
-- performance, and the only thing that makes it work is WHERE IT LOOKS: at
-- `aiq.emb_demo_quad_a`, the space the query actually ranks over, and not at
-- `journey.chunks`, which is this file's own rows and cannot disagree with
-- itself. The journey's own chunks are not in that space yet -- Act 3 puts them
-- there -- so the comparison is against what is already in it, which on a
-- dev/reload.sh database is the sample corpus. That is the interference, and it
-- is exactly what was missed.
do $$
declare v_bad text;
begin
    -- round()::text, not format('%.4f'): Postgres format() has no precision
    -- specifier and raises "unrecognized format() type specifier" -- which is a
    -- check failing for a reason other than the one it names, caught here only
    -- because this assertion was made to fail on purpose before being trusted.
    select string_agg(format('%s: own %s, nearest other journey doc %s, nearest corpus chunk %s',
                             name, round(own::numeric,5), round(sibling::numeric,5), round(rival::numeric,5)), E'\n  ')
      into v_bad
      from (
        select p.name,
               (select min(j.embedding <=> p.embedding) from journey.chunks j
                 where j.doc_slug = p.expect_top_doc)          as own,
               (select min(e.embedding <=> p.embedding) from aiq.emb_demo_quad_a e) as rival,
               -- AND THE OTHER HALF, which the first version of this check
               -- missed and which cost a second round: a probe must also beat
               -- every OTHER journey document, not just the corpus. The Kestrel
               -- check is scour-flavoured on purpose (it comments on the scour
               -- comparison) and at [0.95,0.12,0.15,0.10] it beat the scour
               -- survey itself, 0.0015 to 0.0016. `expect_top_doc` is a claim
               -- about the whole ranking; checking half of it is how the first
               -- version passed while being wrong.
               (select min(j.embedding <=> p.embedding) from journey.chunks j
                 where j.doc_slug <> p.expect_top_doc)         as sibling
          from journey.probes p
      ) d
     where (rival is not null and rival <= own) or sibling <= own;
    if v_bad is not null then
        raise exception E'a probe does not rank the document it names first:\n  %\n'
            'Act 4 would report whichever chunk actually won, and the journey '
            'would read the collision as a retrieval defect. Move the probe '
            'vectors, not the expectation.', v_bad;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. THE GRAPH an extractor would have proposed from those documents.
--
-- THE SHAPE IS THE EXTRACTOR'S, NOT A CONVENIENT ONE. `aiq.upsert_graph` reads
-- `k` (kind) and `n` (name) on a node, and `s`/`t`/`r` on an edge where s and t
-- are ORDINALS INTO THE NODES ARRAY as the model wrote it -- not names. Written
-- that way here because a fixture that used a friendlier shape would be testing
-- a translation layer that does not exist in production.
--
-- THREE HOPS FROM THE BRIDGE TO THE DEFECT, on purpose:
--
--     Mill Lane footbridge -> North abutment -> Riprap apron -> Scour hole
--
-- so "what is actually wrong with this bridge" is unanswerable at depth 1,
-- unanswerable at depth 2 and answered at depth 3. There is deliberately NO
-- short-circuit edge from the abutment straight to the defect: a fixture whose
-- first hop already contains the answer proves nothing about iteration and
-- hides that widening is expensive, which dev/tests/evals/README.md records
-- learning the hard way about its own three-hop chain.
--
-- TWO KINDS OF NODE, BECAUSE A REAL EXTRACTION PRODUCES BOTH.
--
--   * `document` IS a registered entity type (aiq.entity_registry: it resolves
--     off content.resources, keyed on title, and only where status = 'ready').
--     So the document node resolves to the row Act 3 uploaded -- IF ingestion
--     has finished. If it has not, the same node lands as a candidate instead.
--     That is not a fixture bug and Act 5 says so: which of the two happened is
--     a thing the performer finds out, and the answer is a fact about the
--     system rather than about this file.
--
--   * `structure`, `component` and `defect` are NOT registered entity types,
--     so they land as candidates in aiq.soft_nodes carrying the claimed kind.
--     That is the correct behaviour for a domain nobody has registered tables
--     for, and it is what gives Act 5 something real to promote.
--
-- EVERY RELATION HERE IS IN THE CLOSED VOCABULARY (`aiq.graph_vocabulary`),
-- checked at load below. An unlisted relation is DROPPED AND COUNTED rather
-- than raised, so a typo here would not fail the load -- it would quietly
-- produce a graph with a hole in it that still answers questions. The assertion
-- at the end of this section is what stops this file being the source of that.
-- ---------------------------------------------------------------------
create table journey.graphs (
    doc_slug text primary key references journey.documents(slug),
    payload  jsonb not null
);

insert into journey.graphs (doc_slug, payload) values
('scour-survey', $g${
  "nodes": [
    {"k": "document",  "n": "Mill Lane footbridge - river scour survey"},
    {"k": "structure", "n": "Mill Lane footbridge"},
    {"k": "component", "n": "North abutment"},
    {"k": "component", "n": "Riprap apron 2019"},
    {"k": "defect",    "n": "Scour hole 2026"}
  ],
  "edges": [
    {"s": 0, "t": 1, "r": "mentions"},
    {"s": 1, "t": 2, "r": "contains"},
    {"s": 2, "t": 3, "r": "contains"},
    {"s": 3, "t": 4, "r": "causal"}
  ]
}$g$),
('bearing-inspection', $g${
  "nodes": [
    {"k": "document",  "n": "Mill Lane footbridge - bearing and deck inspection"},
    {"k": "structure", "n": "Mill Lane footbridge"},
    {"k": "component", "n": "South abutment"},
    {"k": "component", "n": "Elastomeric bearings"},
    {"k": "defect",    "n": "Bearing degradation"}
  ],
  "edges": [
    {"s": 0, "t": 1, "r": "mentions"},
    {"s": 1, "t": 2, "r": "contains"},
    {"s": 2, "t": 3, "r": "contains"},
    {"s": 3, "t": 4, "r": "causal"}
  ]
}$g$);

-- Every relation named above is one the extractor is allowed to emit. Asserted
-- rather than trusted because the failure is silent: an unlisted relation is
-- dropped and counted, so a typo in this file would land a graph that is missing
-- an edge and still answers questions -- and the journey would read that hole as
-- a defect in the walk.
do $$
declare v_bad text;
begin
    select string_agg(distinct r, ', ') into v_bad
      from journey.graphs g,
           lateral jsonb_array_elements(g.payload->'edges') e,
           lateral (select lower(trim(e.value->>'r')) as r) x
     where not exists (select 1 from aiq.graph_vocabulary v where v.relation = x.r);
    if v_bad is not null then
        raise exception
            'journey graph payloads name relation(s) the extractor vocabulary does '
            'not admit (%): upsert_graph would DROP those edges and count them '
            'rather than refusing, so the journey would walk a graph with a hole '
            'in it and read the hole as a defect', v_bad;
    end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. THE WORKFLOWS the cast authors.
--
-- Stored as text, unparsed, because `workflow.define_yaml` is the thing under
-- test: a fixture that pre-validated the YAML would have performed the step
-- whose refusals Act 6 is about.
--
-- `ingest_survey` is deliberately the shape that has bitten this engine twice
-- and is cheap to get wrong: a fan-out whose successor needs two upstreams, one
-- of which is named twice. `cc0fc91` is the commit where naming one dependency
-- twice deadlocked a run in silence, and `workflow.outstanding_deps` is the fix.
-- If the run started from this definition never completes, that fix has come
-- undone -- and a run that never ends is indistinguishable from a run that is
-- merely slow, so Act 6 says how long to wait before calling it.
-- ---------------------------------------------------------------------
create table journey.workflows (
    name       text primary key,
    authored_by text not null,
    intent     text not null,
    yaml       text not null
);

insert into journey.workflows (name, authored_by, intent, yaml) values
('mill_lane_triage', 'nour',
 'Read the two surveys, work out which abutment is worse, and leave a note a person can act on.',
$y$
name: mill_lane_triage
steps:
  - id: find_structure
    p8ql: 'LOOKUP "Mill Lane footbridge"'

  - id: walk_defects
    needs: [find_structure]
    p8ql: 'GRAPH "Mill Lane footbridge" DEPTH 3'

  - id: cost_context
    needs: [find_structure]
    p8ql: 'TEXT "underpinning" FROM chunks'

  - id: summarise
    needs: [walk_defects, cost_context, walk_defects]
    sql: {function: p8ql, args: ['SCHEMA "graph"']}
$y$),

('mill_lane_watch', 'nour',
 'Re-run the triage every morning so a new survey does not sit unread.',
$y$
name: mill_lane_watch
steps:
  - id: triage
    sql: {function: p8ql, args: ['LOOKUP "Mill Lane footbridge"']}
$y$);

-- ---------------------------------------------------------------------
-- 5. NOTHING IS GRANTED. See the header: a table granted to an application
-- role and carrying no policy is the exact defect dev/tests/rbac/05 enumerates
-- for, so this schema stays where only the owner can reach it.
-- ---------------------------------------------------------------------
revoke all on schema journey from public;
revoke all on all tables in schema journey from public;

do $$
declare v_leaked text;
begin
    select string_agg(c.relname, ', ')
      into v_leaked
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'journey'
       and (has_table_privilege('authenticated', c.oid, 'select')
            or has_table_privilege('web_anon', c.oid, 'select'));
    if v_leaked is not null then
        raise exception
            'journey materials are readable by an application role (%) -- that '
            'puts a policy-less table on the read surface dev/tests/rbac/05 '
            'enumerates, which is the defect that test exists to find', v_leaked;
    end if;
end $$;

reset role;

\echo ''
\echo 'journey materials loaded:'
select
  (select count(*) from journey.documents) as documents,
  (select count(*) from journey.chunks)    as chunks,
  (select count(*) from journey.probes)    as probes,
  (select count(*) from journey.graphs)    as graphs,
  (select count(*) from journey.workflows) as workflows;
\echo ''
\echo 'No orgs, users, agents or runs were created. Those are the journey.'
