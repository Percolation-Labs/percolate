-- CALDER -- the fixture the scenario evals run against.
--
-- One domain, built once, shared by every scenario in `scenarios.yaml`. A
-- pharmacovigilance desk: sponsors and the products they make, the sites and
-- investigators running trials on them, the safety signals raised against
-- them, and a stream of case reports that are rows nobody looks up by name.
--
-- WHY A DOMAIN AND NOT A HUNDRED FIXTURES. The interesting scenarios are the
-- ones where a query written for the retrieval category is answered by data
-- the graph category put there -- the seams are where this repo's bugs have
-- lived (`meta/skills/spec-driven-development`, "a scenario crossing two
-- surfaces is worth more than either alone"). A fixture per scenario would be
-- a hundred domains for a reader to hold in their head and no seams at all.
--
-- WHY NOT REUSE `demo` OR `harbour`. `dev/init/04-graph-sample.sql` is the
-- shape the graph TESTS assert against, exactly, and a scenario suite that
-- writes into it breaks them. `dev/examples/00-harbour.sql` is a cookbook
-- fixture whose output is quoted verbatim in published docs. Both are pinned
-- by something else. This one is ours to move.
--
-- WHAT IT DELIBERATELY DOES NOT TOUCH. Nothing here writes a row into
-- `content.resource_chunks` or into the `chunks` source, because that corpus
-- is what `dev/tests/query/08-retrieval.sql` ranks against and a second corpus
-- in the same source changes those rankings. The upload scenarios create
-- their `content.*` rows inside their own transaction and roll them back --
-- which is also more honest about what an upload IS: an event, not a fixture.
-- The persistent corpus here is `calder.chunks`, registered as its own
-- lexical and semantic source (`pv_chunks`) over its own 4-dimension space.
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8experiment \
--         < dev/tests/evals/fixtures.sql
--
-- Idempotent. Safe to re-run against a live stack; `./run.py --fixture` does.

set role app_owner;

-- The image may predate what this fixture registers. Bricking the load would
-- be the worse answer -- same division of labour as 04-graph-sample.sql.
do $$
begin
    if to_regprocedure('aiq.register_entity_table(text,text,text,text,text,text,text)') is null
       or to_regprocedure('aiq.register_lexical_source(text,text,text,text)') is null then
        raise exception
            'this database predates aiq.register_entity_table / '
            'register_lexical_source. Rebuild the image from the current '
            'specs: dev/build-image.sh';
    end if;
end $$;

create schema if not exists calder;

-- ============================================================================
-- 1. The typed tables.
--
-- Attributes live here. The node registry stores identity only -- that split
-- is graph-identity.md's, and copying a payload into aiq.nodes is the mistake
-- it exists to prevent.
-- ============================================================================
create table if not exists calder.sponsors (
    id        uuid primary key,
    name      text not null,
    code      text,
    parent_id uuid references calder.sponsors(id),
    is_active boolean not null default true,
    org_id    uuid,
    blurb     text
);

create table if not exists calder.products (
    id         uuid primary key,
    name       text not null,
    inn        text not null,          -- international nonproprietary name
    sponsor_id uuid references calder.sponsors(id),
    withdrawn  boolean not null default false,
    org_id     uuid
);

create table if not exists calder.sites (
    id      uuid primary key,
    name    text not null,
    city    text not null,
    country text not null,
    org_id  uuid
);

create table if not exists calder.investigators (
    id         uuid primary key,
    full_name  text not null,
    speciality text,
    org_id     uuid
);

create table if not exists calder.signals (
    id        uuid primary key,
    title     text not null,
    opened_on date not null,
    severity  text not null default 'routine'
                  check (severity in ('routine','elevated','urgent')),
    org_id    uuid
);

-- The data plane. High-rate, machine-generated, nobody LOOKUPs a case report
-- by name and no edge ever ends on one -- so it is registered as an entity
-- type nowhere, and that absence is asserted (graph-identity.md, inclusion
-- policy). It is also what the fan-out and batching scenarios fan out OVER.
create table if not exists calder.case_reports (
    id              uuid primary key,
    product_id      uuid not null references calder.products(id),
    site_id         uuid references calder.sites(id),
    received_on     date not null,
    seriousness     text not null check (seriousness in ('non_serious','serious','fatal')),
    outcome         text,
    narrative       text,
    processed       boolean not null default false,
    org_id          uuid
);

-- Where the record-collection scenarios land what they fetched. A registry
-- poll produces rows, and the honest question about a poll is not "did it 200"
-- but "is the row here, once, with its provenance".
create table if not exists calder.registry_records (
    id            uuid primary key default gen_random_uuid(),
    registry      text not null,
    external_ref  text not null,
    payload       jsonb not null default '{}'::jsonb,
    fetched_at    timestamptz not null default now(),
    org_id        uuid,
    unique (registry, external_ref)
);

-- Where a human decision lands. `signal:` holds the run open; this is what
-- the person's answer becomes once they give it.
create table if not exists calder.escalations (
    id           uuid primary key default gen_random_uuid(),
    signal_key   text not null,
    decision     text not null,
    decided_by   text,
    decided_at   timestamptz not null default now(),
    run_id       uuid
);

-- ============================================================================
-- 2. Rows.
--
-- Fixed uuids, not gen_random_uuid(): scenarios assert on specific nodes and a
-- fixture whose ids move every load can only be asserted about vaguely.
--   sponsors 51…  products 52…  sites 53…  investigators 54…  signals 56…
--   case reports 57…  chunks 58…  orgs aa…/bb…  users 55…
-- ============================================================================

-- THE TWO TENANTS THEMSELVES, before anything points at them.
--
-- Added after the eval suite stopped loading against
-- `percolationlabs/percolate-postgres:19-0.1.5` -- the image the published
-- compose file pins -- with
--
--     insert or update on table "nodes" violates foreign key constraint
--     "nodes_org_id_fkey" -- Key (org_id)=(aa000000-...-00a1) is not present
--
-- which is the SAME defect, in the same shape, that `samples/harbour/tenants.sql`
-- was written to fix and records at length: every row below carries an org id,
-- 0.1.4's scope work made `aiq.nodes.org_id` a real foreign key, and nothing
-- had ever created the orgs. The sample was fixed; this file has the same bug
-- and was not, so the fix landed at the site that hurt and the other place
-- performing the same transition was left behind -- failure-modes.md §5's
-- shape exactly, which that postmortem says has now reopened three times.
--
-- The consequence was worse here than there, because this is the suite: with
-- the fixture unloadable, EVERY scenario in `scenarios.yaml` was unrunnable
-- against a stack built from the published images, and nothing said so -- the
-- suite is normally pointed at `p8-experiment-pg19`, a long-lived dev container
-- whose orgs predate the foreign key.
--
-- GUARDED and IDEMPOTENT for the reason tenants.sql gives: `rbac.orgs` does not
-- exist before 0.1.4, and a fixture is loaded into whatever version the reader
-- installed.
do $$
begin
    if to_regclass('rbac.orgs') is null then
        return;
    end if;
    insert into rbac.orgs (id, slug, name) values
        ('aa000000-0000-0000-0000-0000000000a1','calder-org-a','Calder Tenant A'),
        ('bb000000-0000-0000-0000-0000000000b1','calder-org-b','Calder Tenant B')
    on conflict (id) do update
        set slug = excluded.slug, name = excluded.name;
end $$;

-- Two tenants and a shared tier. `org_id is null` is reference data every
-- tenant legitimately sees -- a marketed drug is not one customer's secret.
insert into calder.sponsors (id, name, code, parent_id, is_active, org_id, blurb) values
    -- The shared tier.
    ('51000000-0000-0000-0000-000000000001','Novara Group','NVRA',null,true,null,
     'the parent, reachable from a signal only at depth 3'),
    ('51000000-0000-0000-0000-000000000002','Altimer Therapeutics','ALTM',
     '51000000-0000-0000-0000-000000000001',true,null,
     'makes the hub product; a Novara subsidiary'),
    ('51000000-0000-0000-0000-000000000003','Beringer Pharma','BRNG',null,true,null,
     'makes the second product in the interaction pair'),
    ('51000000-0000-0000-0000-000000000004','Cyrene Biologics','CYRN',
     '51000000-0000-0000-0000-000000000001',true,null,
     'a second Novara subsidiary -- the shape that makes a walk find one node two ways'),
    -- No edges at all. A seed with no neighbours must return zero rows rather
    -- than erroring, and must not be confused with a key that did not resolve.
    ('51000000-0000-0000-0000-000000000005','Quillon Bio','QUIL',null,true,null,
     'deliberately unconnected'),
    -- EXCLUDED by the inclusion predicate. No node, no key, and therefore
    -- cannot be an edge endpoint however hard a scenario tries.
    ('51000000-0000-0000-0000-000000000006','Harrow Labs','HRRW',null,false,null,
     'wound up -- must never appear in aiq.nodes'),
    -- The two tenants. Active AND org-scoped: tenancy and inclusion are
    -- orthogonal, and a fixture that conflated them could not say which one
    -- did the filtering.
    ('51000000-0000-0000-0000-000000000007','Westmark Rare Disease','WSTM',null,true,
     'aa000000-0000-0000-0000-0000000000a1','org A only'),
    ('51000000-0000-0000-0000-000000000008','Ostara Generics','OSTA',null,true,
     'bb000000-0000-0000-0000-0000000000b1','org B only')
on conflict (id) do update set
    name = excluded.name, code = excluded.code, parent_id = excluded.parent_id,
    is_active = excluded.is_active, org_id = excluded.org_id, blurb = excluded.blurb;

insert into calder.products (id, name, inn, sponsor_id, withdrawn, org_id) values
    ('52000000-0000-0000-0000-000000000001','Tolvaxa','tolvaxen',
     '51000000-0000-0000-0000-000000000002',false,null),
    ('52000000-0000-0000-0000-000000000002','Beriflor','beriflor',
     '51000000-0000-0000-0000-000000000003',false,null),
    ('52000000-0000-0000-0000-000000000003','Cyranix','cyranix',
     '51000000-0000-0000-0000-000000000004',false,null),
    ('52000000-0000-0000-0000-000000000004','Dolmirase','dolmirase',
     '51000000-0000-0000-0000-000000000002',true,null),
    ('52000000-0000-0000-0000-000000000005','Westrelin','westrelin',
     '51000000-0000-0000-0000-000000000007',false,'aa000000-0000-0000-0000-0000000000a1'),
    ('52000000-0000-0000-0000-000000000006','Ostavir','ostavir',
     '51000000-0000-0000-0000-000000000008',false,'bb000000-0000-0000-0000-0000000000b1')
on conflict (id) do update set
    name = excluded.name, inn = excluded.inn, sponsor_id = excluded.sponsor_id,
    withdrawn = excluded.withdrawn, org_id = excluded.org_id;

insert into calder.sites (id, name, city, country, org_id) values
    ('53000000-0000-0000-0000-000000000001','Ravensbourne Clinical Unit','London','GB',null),
    ('53000000-0000-0000-0000-000000000002','Sankt Eriks Trial Centre','Stockholm','SE',null),
    ('53000000-0000-0000-0000-000000000003','Mercy Valley Research','Denver','US',null)
on conflict (id) do update set
    name = excluded.name, city = excluded.city, country = excluded.country,
    org_id = excluded.org_id;

insert into calder.investigators (id, full_name, speciality, org_id) values
    ('54000000-0000-0000-0000-000000000001','Ines Okonkwo','hepatology',null),
    ('54000000-0000-0000-0000-000000000002','Rafael Bittencourt','cardiology',null),
    ('54000000-0000-0000-0000-000000000003','Yun-Seo Park','nephrology',null),
    ('54000000-0000-0000-0000-000000000004','Halvard Nystrom','hepatology',
     'aa000000-0000-0000-0000-0000000000a1')
on conflict (id) do update set
    full_name = excluded.full_name, speciality = excluded.speciality,
    org_id = excluded.org_id;

insert into calder.signals (id, title, opened_on, severity, org_id) values
    -- The hub's signals. Four against one product is what makes the product a
    -- hub and makes "which product is the desk busiest about" a real question.
    ('56000000-0000-0000-0000-000000000001','SIG-114 hepatic injury','2026-06-02','urgent',null),
    ('56000000-0000-0000-0000-000000000002','SIG-118 QT prolongation','2026-06-19','elevated',null),
    ('56000000-0000-0000-0000-000000000003','SIG-121 rash cluster','2026-07-03','routine',null),
    ('56000000-0000-0000-0000-000000000004','SIG-130 renal impairment','2026-07-22','elevated',null),
    -- Against a different product, so a walk from the hub does not reach
    -- everything and "expand until you find it" has somewhere to fail.
    ('56000000-0000-0000-0000-000000000005','SIG-140 photosensitivity','2026-08-04','routine',null),
    -- The ambiguity case. Its short key is 'altimer', which is ALSO the short
    -- key of sponsor ALTM -- graph-identity.md's Bakhmut shape, one string
    -- naming two nodes of two types.
    ('56000000-0000-0000-0000-000000000006','Altimer recall notice','2026-08-11','urgent',null),
    ('56000000-0000-0000-0000-000000000007','SIG-151 infusion reaction','2026-08-20','elevated',
     'aa000000-0000-0000-0000-0000000000a1')
on conflict (id) do update set
    title = excluded.title, opened_on = excluded.opened_on,
    severity = excluded.severity, org_id = excluded.org_id;

-- Sixty case reports against three products across three sites. Sixty rather
-- than six because the batching scenarios need a row set big enough that
-- `batch_size` changes the answer, and the fan-out scenarios need one big
-- enough that `max_fanout` is a real ceiling rather than a formality.
insert into calder.case_reports (id, product_id, site_id, received_on, seriousness, outcome, narrative, processed, org_id)
select ('57000000-0000-0000-0000-0000000000' || lpad(g::text, 2, '0'))::uuid,
       (array['52000000-0000-0000-0000-000000000001',
              '52000000-0000-0000-0000-000000000002',
              '52000000-0000-0000-0000-000000000003'])[1 + (g % 3)]::uuid,
       -- DELIBERATELY DECORRELATED FROM THE PRODUCT. An earlier version keyed
       -- site and seriousness off `g % 3` as well, so all three columns moved
       -- together and partitioning by product also partitioned by the other
       -- two -- which made a scenario asserting that a VARYING column is
       -- refused inside a batch pass for the wrong reason, because no column
       -- varied. A fixture whose columns are correlated cannot tell
       -- `partition_by` from coincidence. `site` is left CONSTANT per product,
       -- deliberately: one column that varies inside a batch and one that does
       -- not is what lets a scenario assert the refusal AND the leniency it is
       -- the flip side of.
       (array['53000000-0000-0000-0000-000000000001',
              '53000000-0000-0000-0000-000000000002',
              '53000000-0000-0000-0000-000000000003'])[1 + ((g + 1) % 3)]::uuid,
       date '2026-05-01' + (g * 2),
       (array['non_serious','serious','fatal'])[1 + (g % 2) + (g % 5) / 4],
       case when g % 4 = 0 then 'recovered' else 'ongoing' end,
       'case narrative ' || g,
       false,
       null
from generate_series(1, 60) g
on conflict (id) do nothing;

-- Two people, because two scenarios need different ones: the officer who may
-- decide an escalation, and an analyst who may not.
insert into rbac.users (id, email, status) values
    ('55000000-0000-0000-0000-000000000001','safety.officer@calder.example','active'),
    ('55000000-0000-0000-0000-000000000002','analyst@calder.example','active'),
    ('55000000-0000-0000-0000-000000000003','orgb.user@ostara.example','active')
on conflict (id) do update set email = excluded.email, status = excluded.status;

-- ============================================================================
-- 3. Registration: five entity types, four different key expressions.
--
-- The expressions are SQL text evaluated against the source row aliased `n`.
-- That alias is part of the contract, not cosmetic.
-- ============================================================================
select aiq.register_entity_table(
    p_entity_type   => 'sponsor',
    p_source_table  => 'calder.sponsors',
    -- Code first: it is the short stable name a person types. Falling back to
    -- the name keeps a sponsor with no code addressable.
    p_key_expr      => 'coalesce(n.code, n.name)',
    p_summary_expr  => 'n.name',
    p_org_expr      => 'n.org_id',
    p_include_where => 'n.is_active');

select aiq.register_entity_table(
    p_entity_type   => 'product',
    p_source_table  => 'calder.products',
    -- The INN, not the brand. Two brands of one molecule are one thing to a
    -- safety desk, and keying on the brand would make them two.
    p_key_expr      => 'n.inn',
    p_summary_expr  => 'n.name',
    p_org_expr      => 'n.org_id');

select aiq.register_entity_table(
    p_entity_type   => 'site',
    p_source_table  => 'calder.sites',
    p_key_expr      => 'n.name',
    p_summary_expr  => 'n.name || '' ('' || n.city || '')''',
    p_org_expr      => 'n.org_id');

select aiq.register_entity_table(
    p_entity_type   => 'investigator',
    p_source_table  => 'calder.investigators',
    p_key_expr      => 'n.full_name',
    p_summary_expr  => 'n.full_name',
    p_org_expr      => 'n.org_id');

select aiq.register_entity_table(
    p_entity_type   => 'signal',
    p_source_table  => 'calder.signals',
    p_key_expr      => 'n.title',
    p_summary_expr  => 'n.title',
    p_org_expr      => 'n.org_id');

-- REGISTERING A TYPE DOES NOT EXTEND THE MACHINE VOCABULARY, and this line is
-- the obligation `graph-index.md` §10.9 names: an entity table registered after
-- `register_graph_vocabulary` makes the next extracted edge into that type fail
-- with the catalogue error. It is a documented, message-guided failure rather
-- than a surprise -- but a fixture that skipped the refresh would make every
-- file-to-graph scenario below fail for a reason that has nothing to do with
-- what it is testing.
select aiq.register_graph_vocabulary();

select aiq.rebuild_entity_type('sponsor');
select aiq.rebuild_entity_type('product');
select aiq.rebuild_entity_type('site');
select aiq.rebuild_entity_type('investigator');
select aiq.rebuild_entity_type('signal');

-- ============================================================================
-- 4. Aliases and short keys.
--
-- The projection writes CANONICAL keys only. Short keys and aliases are
-- editorial -- somebody decided that 'tolvaxa' means 'tolvaxen' -- so nothing
-- derives them and they go through add_node_key(), never a direct write to
-- node_keys.
-- ============================================================================
select aiq.add_node_key('ALTM', 'altimer', 'short');
select aiq.add_node_key('ALTM', 'altimer therapeutics', 'alias');
select aiq.add_node_key('NVRA', 'novara', 'short');
select aiq.add_node_key('tolvaxen', 'tolvaxa', 'alias');
select aiq.add_node_key('SIG-114 hepatic injury', 'sig-114', 'short');
select aiq.add_node_key('SIG-118 QT prolongation', 'sig-118', 'short');
select aiq.add_node_key('SIG-130 renal impairment', 'sig-130', 'short');
-- The same string, short for a sponsor above and short for a signal here.
-- Short-key lookup must therefore return several nodes, and GRAPH must refuse
-- to guess between them rather than walking whichever came back first.
select aiq.add_node_key('Altimer recall notice', 'altimer', 'short');

-- ============================================================================
-- 5. The relation catalogue.
--
-- Every allowed (src_type, relation, dst_type) triple. An unlisted triple is
-- refused at write, so the graph cannot accumulate typos-as-relations. The
-- inverse label is read-time only -- no reverse edge is ever stored.
-- ============================================================================
insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
    ('product','made_by','sponsor','makes',
     'marketing authorisation holder'),
    ('sponsor','subsidiary_of','sponsor','parent_of',
     'corporate ownership as an authored claim, not a foreign key'),
    ('signal','implicates','product','implicated_in',
     'the safety signal names this product'),
    ('signal','implicates','sponsor','implicated_in',
     'one relation NAME, two catalogue triples -- what makes TYPE cross types'),
    ('investigator','works_at','site','staffs','current appointment'),
    ('site','trials','product','trialled_at','an active trial site for this product'),
    ('product','interacts_with','product','interacts_with',
     'symmetric; stored once, walked both ways'),
    ('product','co_marketed_with','product','co_marketed_with',
     'used by the cross-tenant edge below'),
    ('investigator','knows','investigator','knows','symmetric acquaintance')
on conflict (src_type, relation, dst_type) do update
    set inverse_label = excluded.inverse_label, description = excluded.description;

-- ============================================================================
-- 6. The edges.
--
-- Endpoints resolve from typed-table ids through the registry: edges reference
-- node ids, never display keys, and names are resolved ONCE at write so a
-- traversal never parses one.
--
-- THE SHAPE THIS FIXTURE IS FOR. Weights are not decoration and depth is not
-- arbitrary. The chain
--
--     SIG-114 --implicates--> tolvaxen --made_by--> ALTM --subsidiary_of--> NVRA
--
-- is three hops, so "which corporate group is behind this signal" is
-- unanswerable at DEPTH 1, unanswerable at DEPTH 2, and answered at DEPTH 3.
-- That is the whole iterated-query category: an agent that expands gradually
-- must be able to be WRONG at the first two widths, or the scenario proves
-- nothing.
-- ============================================================================
insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id)
select s.id, d.id, v.relation, v.weight::real, v.provenance::jsonb, v.org_id::uuid
from (values
    -- The three-hop chain, weakening as it goes so path_weight orders it.
    ('signal','56000000-0000-0000-0000-000000000001','implicates','product','52000000-0000-0000-0000-000000000001',1.00,'{"source":"case series"}',null),
    ('product','52000000-0000-0000-0000-000000000001','made_by','sponsor','51000000-0000-0000-0000-000000000002',0.95,'{"source":"authorisation"}',null),
    ('sponsor','51000000-0000-0000-0000-000000000002','subsidiary_of','sponsor','51000000-0000-0000-0000-000000000001',0.90,'{"source":"registry"}',null),
    -- The hub: four signals against one product. Nothing else in the fixture
    -- has this in-degree, so "the busiest product" has one right answer.
    ('signal','56000000-0000-0000-0000-000000000002','implicates','product','52000000-0000-0000-0000-000000000001',0.80,'{"source":"spontaneous report"}',null),
    ('signal','56000000-0000-0000-0000-000000000003','implicates','product','52000000-0000-0000-0000-000000000001',0.40,'{"source":"forum","note":"single uncorroborated claim"}',null),
    ('signal','56000000-0000-0000-0000-000000000004','implicates','product','52000000-0000-0000-0000-000000000001',0.75,'{"source":"literature"}',null),
    -- A signal against a DIFFERENT product, and one naming a sponsor directly
    -- rather than a product -- the second catalogue triple for `implicates`.
    ('signal','56000000-0000-0000-0000-000000000005','implicates','product','52000000-0000-0000-0000-000000000002',0.65,'{"source":"literature"}',null),
    ('signal','56000000-0000-0000-0000-000000000006','implicates','sponsor','51000000-0000-0000-0000-000000000002',0.70,'{"source":"press"}',null),
    -- The second subsidiary. Cyranix reaches NVRA by its own route, so NVRA is
    -- reachable at depth 2 from two products and must appear ONCE, at its
    -- shortest depth, not once per path.
    ('product','52000000-0000-0000-0000-000000000003','made_by','sponsor','51000000-0000-0000-0000-000000000004',0.95,'{"source":"authorisation"}',null),
    ('sponsor','51000000-0000-0000-0000-000000000004','subsidiary_of','sponsor','51000000-0000-0000-0000-000000000001',0.90,'{"source":"registry"}',null),
    ('product','52000000-0000-0000-0000-000000000002','made_by','sponsor','51000000-0000-0000-0000-000000000003',0.95,'{"source":"authorisation"}',null),
    ('product','52000000-0000-0000-0000-000000000004','made_by','sponsor','51000000-0000-0000-0000-000000000002',0.95,'{"source":"authorisation"}',null),
    -- A three-cycle over interactions. Every walk has to survive returning to
    -- where it started.
    ('product','52000000-0000-0000-0000-000000000001','interacts_with','product','52000000-0000-0000-0000-000000000002',0.85,'{"source":"label"}',null),
    ('product','52000000-0000-0000-0000-000000000002','interacts_with','product','52000000-0000-0000-0000-000000000003',0.60,'{"source":"label"}',null),
    ('product','52000000-0000-0000-0000-000000000003','interacts_with','product','52000000-0000-0000-0000-000000000001',0.30,'{"source":"case report"}',null),
    -- Sites, investigators, and a person-to-person edge so a walk crosses
    -- entity types more than once.
    ('site','53000000-0000-0000-0000-000000000001','trials','product','52000000-0000-0000-0000-000000000001',1.00,'{"source":"protocol"}',null),
    ('site','53000000-0000-0000-0000-000000000002','trials','product','52000000-0000-0000-0000-000000000001',1.00,'{"source":"protocol"}',null),
    ('site','53000000-0000-0000-0000-000000000003','trials','product','52000000-0000-0000-0000-000000000002',1.00,'{"source":"protocol"}',null),
    ('investigator','54000000-0000-0000-0000-000000000001','works_at','site','53000000-0000-0000-0000-000000000001',1.00,'{"source":"protocol"}',null),
    ('investigator','54000000-0000-0000-0000-000000000002','works_at','site','53000000-0000-0000-0000-000000000002',1.00,'{"source":"protocol"}',null),
    ('investigator','54000000-0000-0000-0000-000000000003','works_at','site','53000000-0000-0000-0000-000000000003',1.00,'{"source":"protocol"}',null),
    ('investigator','54000000-0000-0000-0000-000000000001','knows','investigator','54000000-0000-0000-0000-000000000002',0.70,'{"source":"congress"}',null),
    -- The cross-tenant edge: org A's product to org B's product. Its endpoints
    -- are never both visible to anybody, so it must be visible to nobody --
    -- and must not disclose to either tenant that the other's node exists.
    ('product','52000000-0000-0000-0000-000000000005','co_marketed_with','product','52000000-0000-0000-0000-000000000006',0.50,'{"source":"rumour"}',null)
) as v(src_type, src_entity, relation, dst_type, dst_entity, weight, provenance, org_id)
join aiq.nodes s on s.entity_type = v.src_type and s.entity_id = v.src_entity::uuid
join aiq.nodes d on d.entity_type = v.dst_type and d.entity_id = v.dst_entity::uuid
on conflict (src_id, dst_id, relation) do update
    set weight = excluded.weight, provenance = excluded.provenance;

-- ============================================================================
-- 7. The corpus -- its own source, its own space.
--
-- Six chunks, written so the three retrieval modes DISAGREE, because a corpus
-- where they agree cannot show why there are three:
--
--   p1  the rare token verbatim (LOT-4471B)  -- TEXT finds it, no embedding will
--   p2  the same meaning, no shared words    -- SEMANTIC finds it, TEXT cannot
--   p3  a distractor sharing neither
--   p4  the rare token again, in tenant A
--   p5  tenant B, and it must never answer a tenant A question
--   p6  shared reference prose
--
-- VECTORS ARE LITERALS, not model output, for the reason
-- `dev/init/05-corpus-sample.sql` states in capitals: a corpus that needs a
-- live embedding server to be reproducible is a fixture living in somebody's
-- session. Four dimensions is enough to make the modes disagree, which is the
-- only thing asked of them.
-- ============================================================================
create table if not exists calder.chunks (
    id          uuid primary key,
    resource    text not null,
    ordinal     int  not null,
    content     text not null,
    org_id      uuid
);

insert into calder.chunks (id, resource, ordinal, content, org_id) values
    ('58000000-0000-0000-0000-000000000001','psur-tolvaxen',0,
     'Batch LOT-4471B accounted for eleven of the hepatic injury reports in the period.',null),
    ('58000000-0000-0000-0000-000000000002','psur-tolvaxen',1,
     'Liver enzyme elevation was observed more often than the label anticipates.',null),
    ('58000000-0000-0000-0000-000000000003','site-audit-ravensbourne',0,
     'Cold chain storage and consent documentation were satisfactory throughout the visit.',null),
    ('58000000-0000-0000-0000-000000000004','westmark-internal',0,
     'Westmark exposure to LOT-4471B now covers two open studies.',
     'aa000000-0000-0000-0000-0000000000a1'),
    ('58000000-0000-0000-0000-000000000005','ostara-internal',0,
     'Ostara reports no hepatic findings across its generic portfolio this quarter.',
     'bb000000-0000-0000-0000-0000000000b1'),
    ('58000000-0000-0000-0000-000000000006','guidance-note',0,
     'A signal is a reported association that requires evaluation, not a confirmed causal relationship.',null)
on conflict (id) do update set content = excluded.content, org_id = excluded.org_id;

-- Lexical: adds the generated tsvector column and its GIN index to our table.
select aiq.register_lexical_source('pv_chunks', 'calder.chunks', 'content', 'english');

-- Semantic: the source registration is the join target; the SPACE is separate
-- and per-model. Two registrations, deliberately -- the failure-modes note on
-- "two registrations that look like one" is exactly this pair, and a scenario
-- below asserts each half fails by name when the other is missing.
insert into aiq.semantic_sources (name, source_table) values ('pv_chunks', 'calder.chunks')
on conflict (name) do update set source_table = excluded.source_table;

-- NOT is_default. `dev/tests/query/08-retrieval.sql` asserts SEMANTIC with no
-- USING resolves to demo-quad-a, and moving the default here would break a
-- test of a different surface to make this one convenient.
insert into aiq.embedding_models (name, dim, provider, distance_op, is_default, notes)
-- provider NULL: the notes below already said "no model server exists or is
-- needed", and the column now has a way to say it. `fixture` was a word that
-- resolved to nothing, which embedding_models.provider's foreign key onto
-- embedding_providers no longer admits.
values ('calder-quad', 4, null, 'vector_cosine_ops', false,
        'a 4-dimension fixture space over calder.chunks. Vectors are literals; '
        'no model server exists or is needed.')
on conflict (name) do update set dim = excluded.dim, provider = excluded.provider,
                                 notes = excluded.notes;

select aiq.register_embedding_space('calder-quad');

-- The question the scenarios ask is "a liver problem", spelled [0,0,0.707,0.707].
-- p2 sits exactly on it while sharing not one word with the question, which is
-- the TEXT/SEMANTIC disagreement made reproducible.
insert into aiq.emb_calder_quad (chunk_id, embedding) values
    ('58000000-0000-0000-0000-000000000001','[0,0,0.9,0.436]'),
    ('58000000-0000-0000-0000-000000000002','[0,0,0.707,0.707]'),
    ('58000000-0000-0000-0000-000000000003','[0.707,0.707,0,0]'),
    ('58000000-0000-0000-0000-000000000004','[0,0,0.6,0.8]'),
    ('58000000-0000-0000-0000-000000000005','[0,1,0,0]'),
    ('58000000-0000-0000-0000-000000000006','[0.5,0.5,0.5,0.5]')
on conflict (chunk_id) do update set embedding = excluded.embedding;

grant usage on schema calder to authenticated, worker;
grant select on calder.chunks, calder.sponsors, calder.products, calder.sites,
                calder.investigators, calder.signals, calder.case_reports,
                calder.registry_records, calder.escalations
             to authenticated, worker;

-- ============================================================================
-- 8. Channels.
--
-- Two, because the two ingest shapes are different acts: bytes somebody
-- uploaded, and records something fetched. Both are config rows and survive a
-- rolled-back scenario; the resources and chunks a scenario creates through
-- them do not.
-- ============================================================================
insert into content.channels (id, name, kind, config, org_id) values
    ('11110000-0000-0000-0000-0000000000c1','pv-reports','file_upload',
     '{"description":"PSUR and case narrative uploads"}'::jsonb, null),
    ('11110000-0000-0000-0000-0000000000c2','pv-registry','http_pull',
     '{"description":"a regulator record feed","url":"http://p8-faultsrv:8099/empty"}'::jsonb,
     null)
on conflict (id) do update set name = excluded.name, kind = excluded.kind,
    config = excluded.config;

-- ============================================================================
-- 9. Step functions -- the allow-list a `sql:` step and a `matrix: rows:` may
--    name.
--
-- `rows:` names a registered function rather than taking an inline SELECT,
-- because expansion is SECURITY DEFINER and a step that could supply a
-- statement would be a privilege-escalation primitive with a YAML front end.
-- Registering is the price and it is the correct one.
-- ============================================================================

-- Fan-out width from a query: the signals a desk is actually working.
create or replace function calder.open_signals()
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'signal', s.title, 'severity', s.severity,
               'product', coalesce(p.inn, 'unknown'))
               order by s.opened_on), '[]'::jsonb)
    from calder.signals s
    left join aiq.nodes sn on sn.entity_type = 'signal' and sn.entity_id = s.id
    left join aiq.edges e  on e.src_id = sn.id and e.relation = 'implicates'
    left join aiq.nodes pn on pn.id = e.dst_id and pn.entity_type = 'product'
    left join calder.products p on p.id = pn.entity_id
    where s.severity in ('elevated','urgent');
$f$;

-- A cheap row: sixty of them, which is what makes batching worth measuring.
create or replace function calder.unprocessed_cases()
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'case_id', c.id, 'product', p.inn, 'site', st.name,
               'seriousness', c.seriousness)
               order by c.received_on), '[]'::jsonb)
    from calder.case_reports c
    join calder.products p on p.id = c.product_id
    left join calder.sites st on st.id = c.site_id
    where not c.processed;
$f$;

-- The reduce half, handed a WHOLE batch. One call per ten rows rather than ten
-- calls is the shape batching exists to make possible.
create or replace function calder.land_cases(p_items jsonb)
returns jsonb language sql volatile as $f$
    with upd as (
        update calder.case_reports c set processed = true
        from jsonb_array_elements(p_items) e
        where c.id = (e->>'case_id')::uuid
        returning c.id)
    select jsonb_build_object('landed', count(*)) from upd;
$f$;

-- What a registry poll lands. Takes the whole batch for the same reason.
create or replace function calder.land_registry_records(p_items jsonb)
returns jsonb language sql volatile as $f$
    with ins as (
        insert into calder.registry_records (registry, external_ref, payload)
        select e->>'registry', e->>'ref', coalesce(e->'payload','{}'::jsonb)
        from jsonb_array_elements(p_items) e
        on conflict (registry, external_ref) do update
            set payload = excluded.payload, fetched_at = now()
        returning 1)
    select jsonb_build_object('landed', (select count(*) from ins));
$f$;

-- The endpoints a collection run walks. A literal set would have been simpler
-- and would not have exercised the thing that matters: the width comes from a
-- query, so it changes when the data does.
create or replace function calder.registry_targets()
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'registry', 'eudra', 'ref', p.inn, 'path', 'empty')
               order by p.inn), '[]'::jsonb)
    from calder.products p where not p.withdrawn and p.org_id is null;
$f$;

-- A fan-in that reads its children through the documented handle rather than
-- by joining to workflow.tasks itself.
create or replace function calder.tally_children(p_task_id uuid)
returns jsonb language sql stable as $f$
    select jsonb_build_object(
        'children', count(*),
        'succeeded',     count(*) filter (where c->>'status' = 'succeeded'),
        'failed',   count(*) filter (where c->>'status' = 'failed'))
    from jsonb_array_elements(workflow.matrix_outputs(p_task_id)) c;
$f$;

-- What a human decision becomes once it is given. The signal payload arrives
-- as the step's input, so this is the whole of "resume with what they said".
create or replace function calder.record_escalation(p_decision jsonb)
returns jsonb language sql volatile as $f$
    with ins as (
        insert into calder.escalations (signal_key, decision, decided_by)
        values (coalesce(p_decision->>'signal','unknown'),
                coalesce(p_decision->>'decision','none'),
                p_decision->>'by')
        returning id)
    select jsonb_build_object('escalation_id', (select id from ins));
$f$;

-- A step that fails on demand, for the recovery scenarios. Deterministic:
-- a test whose failure depends on a clock is a test that fails in CI.
create or replace function calder.always_fails(p_note text)
returns jsonb language plpgsql volatile as $f$
begin
    raise exception 'calder: deliberate failure -- %', p_note;
end;
$f$;

create or replace function calder.echo(p_note text)
returns jsonb language sql immutable as $f$
    select jsonb_build_object('echo', p_note);
$f$;

-- How many products a sponsor is on the hook for -- a `sql:` step over the
-- graph rather than over the typed table, so it goes through the registry the
-- way a real consumer does.
create or replace function calder.products_of(p_sponsor text)
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(pk.key order by pk.key), '[]'::jsonb)
    from aiq.node_keys sk
    join aiq.nodes sn on sn.id = sk.node_id and sn.entity_type = 'sponsor'
    join aiq.edges e   on e.dst_id = sn.id and e.relation = 'made_by'
    join aiq.node_keys pk on pk.node_id = e.src_id and pk.kind = 'canonical'
    -- Normalised, because `node_keys` stores keys lower/trimmed and a consumer
    -- that forgets gets an empty array rather than an error -- the shape
    -- `SEARCH` degrading to semantic-only had, one layer up.
    where sk.key = lower(trim(p_sponsor));
$f$;

select workflow.register_step_function('open_signals', 'calder.open_signals', '{}',
    p_description => 'signals at elevated or urgent severity, one row each');
select workflow.register_step_function('unprocessed_cases', 'calder.unprocessed_cases', '{}',
    p_description => 'case reports not yet landed -- sixty of them');
select workflow.register_step_function('land_cases', 'calder.land_cases', '{jsonb}',
    p_description => 'mark a whole batch of case reports processed');
select workflow.register_step_function('land_registry_records', 'calder.land_registry_records', '{jsonb}',
    p_description => 'upsert a batch of fetched registry records');
select workflow.register_step_function('registry_targets', 'calder.registry_targets', '{}',
    p_description => 'the endpoints a collection run walks');
select workflow.register_step_function('tally_children', 'calder.tally_children', '{uuid}',
    p_description => 'fan-in: count a matrix step''s children by status');
select workflow.register_step_function('record_escalation', 'calder.record_escalation', '{jsonb}',
    p_description => 'land a human escalation decision');
select workflow.register_step_function('always_fails', 'calder.always_fails', '{text}',
    p_description => 'raises, deterministically -- for the recovery scenarios');
select workflow.register_step_function('calder_echo', 'calder.echo', '{text}',
    p_description => 'returns its argument');
select workflow.register_step_function('products_of', 'calder.products_of', '{text}',
    p_description => 'the products a sponsor holds, read through the graph');

-- ============================================================================
-- 10. What landed, in one query, so a reader can check it.
-- ============================================================================
do $$
declare
    v_nodes int; v_edges int; v_keys int; v_excluded int; v_cases int;
begin
    select count(*) into v_nodes from aiq.nodes
     where entity_type in ('sponsor','product','site','investigator','signal');
    select count(*) into v_edges from aiq.edges e
      join aiq.nodes n on n.id = e.src_id
     where n.entity_type in ('sponsor','product','site','investigator','signal');
    select count(*) into v_keys from aiq.node_keys k
      join aiq.nodes n on n.id = k.node_id
     where n.entity_type in ('sponsor','product','site','investigator','signal');
    select count(*) into v_excluded from calder.sponsors s
     where not exists (select 1 from aiq.nodes n
                        where n.entity_type = 'sponsor' and n.entity_id = s.id);
    select count(*) into v_cases from calder.case_reports;

    if v_excluded <> 1 then
        raise exception 'calder: expected exactly one sponsor excluded by the '
                        'inclusion policy, found % -- the fixture no longer '
                        'has an excluded row to assert about', v_excluded;
    end if;
    if v_cases <> 60 then
        raise exception 'calder: expected 60 case reports, found % -- the '
                        'batching scenarios assume the width', v_cases;
    end if;

    raise notice 'calder fixture: % nodes, % edges, % keys, % case reports, % chunks',
        v_nodes, v_edges, v_keys, v_cases, (select count(*) from calder.chunks);
end $$;

reset role;

-- ============================================================================
-- 11. Row-level security on the corpus -- because registering a source grants
--     nothing and imposes nothing.
--
-- `ai-query-layer/USAGE.md` states this in the two things registration does
-- NOT do: the query functions are SECURITY INVOKER, so a caller needs real
-- access to your tables, and setting your own RLS is your call to make, not
-- the layer's. A fixture that skipped it would let every tenancy scenario in
-- `scenarios.yaml` pass for the wrong reason -- the rows would be visible to
-- everybody and the assertions would be measuring nothing.
--
-- The predicate is the same one `aiq` and `content` use: null org is shared
-- reference data; a non-null org is visible to members of that org, taken from
-- the verified claim and never from a parameter.
-- ============================================================================
set role app_owner;

do $rls$
declare t text;
begin
    foreach t in array array['chunks','sponsors','products','signals',
                             'investigators','sites','case_reports',
                             'registry_records']
    loop
        -- Through rbac.add_scope_columns/add_scope_policy rather than a
        -- hand-written predicate, which is what every shipped consumer does
        -- now. The predicate this used to spell out -- `org_id is null or
        -- org_id in (select aiq.current_org_ids())` -- is the idiom scope
        -- replaced: the null tier meant both "shared" and "unset", and the
        -- membership came from an array in the token rather than from a table.
        -- A fixture that keeps its own copy of a security predicate is a
        -- sixteenth copy that nothing regenerates.
        execute format('select rbac.add_scope_columns(''calder.%I'', ''public'')', t);
        execute format('select rbac.add_scope_policy(''calder.%I'')', t);
        execute format('drop policy if exists %I on calder.%I', t || '_read', t);
    end loop;
end $rls$;

-- NOT `force row level security`, and finding out why is worth the line.
--
-- A table owner is exempt from its own policies unless forced, and forcing it
-- here breaks the thing that makes this file usable: the owner is who reloads
-- the fixture, so FORCE turns every idempotent `on conflict do update` above
-- into `new row violates row-level security policy`. It also breaks the
-- engine, which executes a `sql:` step through a SECURITY DEFINER function
-- owned by app_owner and acting on its own behalf rather than a user's
-- (failure-modes.md §4, "the engine acting on its own behalf").
--
-- The scenarios that assert tenancy therefore run as `authenticated`, which
-- is not the owner and to which the policy does apply. That is not a weaker
-- test -- it is the seat the guarantee is actually about. A scenario that
-- asserted tenancy from the OWNER's seat would pass on a table with no
-- policies at all.

reset role;

-- ============================================================================
-- 12. The agents -- because delegation is data, not code.
--
-- A tool server is a row naming an endpoint; an agent is a row naming tools BY
-- NAME, with no foreign key able to hold either (that is `dev/tests/agentic/`'s
-- whole subject). Four agents, arranged so the delegation scenarios have
-- something with shape to assert about:
--
--   pv_triage        the one a workflow calls. Delegates.
--   pv_hepatology    a specialist, narrowed to ONE tool of a server that
--                    exposes two -- so "the allowlist is a list, not a string"
--                    is checkable.
--   pv_cardiology    a second specialist, so a fan-out over verdicts has more
--                    than one shape of answer.
--   pv_auditor       reads the envelope rather than the assistant text, which
--                    is what `jsonpath: ''` on an agent step is for.
-- ============================================================================
set role app_owner;

select (agentic.upsert_tool_server($srv${
  "name": "pv-query",
  "kind": "mcp",
  "url": "http://query-mcp:8090",
  "emits_citations": true,
  "cached_tools": [{"name": "query"}, {"name": "schema"}, {"name": "lookup"}]
}$srv$::jsonb)).name as tool_server;

select (agentic.upsert_agent($ag${
  "name": "pv_triage",
  "audience": "user",
  "category": "tool_user",
  "model": "anthropic:claude-sonnet-5",
  "tags": ["pharmacovigilance", "triage"],
  "system_prompt": "You triage safety signals. Start with SCHEMA, resolve names with LOOKUP, and expand a GRAPH one depth at a time rather than guessing a width. Delegate to a specialist rather than answering outside your competence.",
  "tools": [{"server": "pv-query", "tools": ["query", "schema", "lookup"]}]
}$ag$::jsonb)).name as agent;

select (agentic.upsert_agent($ag${
  "name": "pv_hepatology",
  "audience": "internal",
  "category": "tool_user",
  "model": "anthropic:claude-sonnet-5",
  "tags": ["pharmacovigilance", "hepatic"],
  "system_prompt": "You assess hepatic injury reports against Hy's law and say which criterion is met.",
  "tools": [{"server": "pv-query", "tools": ["query"]}]
}$ag$::jsonb)).name as agent;

select (agentic.upsert_agent($ag${
  "name": "pv_cardiology",
  "audience": "internal",
  "category": "tool_user",
  "model": "anthropic:claude-sonnet-5",
  "tags": ["pharmacovigilance", "cardiac"],
  "system_prompt": "You assess QT prolongation reports and say whether the interval is actionable.",
  "tools": [{"server": "pv-query", "tools": ["query"]}]
}$ag$::jsonb)).name as agent;

select (agentic.upsert_agent($ag${
  "name": "pv_auditor",
  "audience": "internal",
  "category": "extractor",
  "model": "anthropic:claude-sonnet-5",
  "tags": ["pharmacovigilance", "audit"],
  "system_prompt": "You record what a run did, not what it concluded.",
  "structured_output_schema": {
    "type": "object",
    "required": ["verdict", "confidence"],
    "properties": {
      "verdict":    {"type": "string", "enum": ["SAFETY", "QUALITY", "OTHER"]},
      "confidence": {"type": "number"}
    }
  },
  "tools": []
}$ag$::jsonb)).name as agent;

reset role;
