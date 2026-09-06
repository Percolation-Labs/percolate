-- Sample: the worked graph, as data.
--
-- The graph surface had no fixture in this repository. Every measured claim in
-- `specs/ai-query-layer/schema.sql` §8 -- the LOOKUP plan, the inclusion
-- policy holding, the hard FK that is answerable without being an edge -- was
-- measured against a fixture that existed only in somebody's psql session, and
-- `specs/agentic/reference/README.md`'s worked output quotes an `fx_pair`
-- entity type that appears in no file here. Same mistake as `02-seed.sql`'s
-- header records for the workflow examples, one subsystem over: a demo that
-- lives only in a running container.
--
-- So this is the fixture, committed. It is deliberately not minimal -- the
-- graph surface's characteristic failure is a WRONG ANSWER rather than an
-- error (dev/tests/README.md), and a wrong answer needs a graph with enough
-- shape to be wrong about:
--
--   * three entity types, three different key expressions, one inclusion
--     predicate that actually excludes rows;
--   * tenancy in all three states -- shared (rbac.shared_org_id()), org A, org B --
--     including one edge whose endpoints sit in DIFFERENT orgs, which must be
--     visible to neither;
--   * a cycle, a hub, a node reachable at two different depths by two
--     different routes, and a node with no edges at all;
--   * a hard foreign key (`demo.events.primary_company_id`) that is NOT an
--     edge and must stay answerable anyway (graph-identity.md D4);
--   * a data-plane table (`demo.filings`) that must never become a node.
--
-- Runs as app_owner at initdb, after the extension. Idempotent and safe to
-- re-run by hand against a live stack:
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8experiment \
--         < dev/init/04-graph-sample.sql

set role app_owner;

-- The image may predate the graph sample's dependencies, in which case the
-- other four subsystems are fine and bricking initdb would be the worse
-- answer. Same division of labour as 03-sample-agent.sql: warn and skip here,
-- and let ../../surface.sql turn the absence back into a failure where a
-- failure is useful.
do $$
begin
    if to_regprocedure('aiq.register_entity_table(text,text,text,text,text,text,text)') is null then
        raise warning
            'skipping the graph sample: this database image predates '
            'aiq.register_entity_table. Everything else installed normally. '
            'Rebuild the image from the current specs: dev/build-image.sh';
        return;
    end if;
end $$;

create schema if not exists demo;

-- ------------------------------------------------------------
-- 1. The typed tables. Attributes live here and only here; the registry
--    stores identity, never the payload (graph-identity.md "Node registry").
--
-- Two tenants and a shared tier. The shared tier is a real category and not a
-- loophole -- a publicly listed company is legitimately global, and
-- duplicating it per tenant defeats the point of one identity registry
-- (integration-rbac.sql §1). These are APPLICATION tables, so their org_id
-- stays nullable and a null here means "no tenant in particular"; the
-- projection reads that through rbac.org_or_shared() and the node it creates
-- carries rbac.shared_org_id(), which is where the NOT NULL rule starts.
-- ------------------------------------------------------------
create table if not exists demo.companies (
    id        uuid primary key,
    name      text not null,
    ticker    text,
    is_public boolean not null default true,
    org_id    uuid,
    blurb     text
);

create table if not exists demo.people (
    id        uuid primary key,
    full_name text not null,
    role      text,
    org_id    uuid
);

-- The hard link. `primary_company_id` is a foreign key with an identity of its
-- own, so per D4 it is NEVER copied into aiq.edges -- and the "two memories"
-- claim is that it stays answerable anyway, by an indexed join from the typed
-- row once identity is known. dev/tests/query/04 asserts both halves.
create table if not exists demo.events (
    id                 uuid primary key,
    title              text not null,
    occurred_at        date not null,
    primary_company_id uuid references demo.companies(id),
    org_id             uuid
);
create index if not exists idx_demo_events_company on demo.events (primary_company_id);

-- The data plane. High-rate, machine-generated, never LOOKUP-able and never an
-- edge endpoint, therefore never a node (graph-identity.md "Inclusion
-- policy"). It is registered nowhere below; that absence is the point, and
-- dev/tests/query/04 asserts it stays absent.
create table if not exists demo.filings (
    id         uuid primary key,
    company_id uuid not null references demo.companies(id),
    filed_on   date not null,
    form       text not null,
    body       text
);

-- ------------------------------------------------------------
-- 2. Rows.
--
-- Fixed UUIDs, not gen_random_uuid(): the tests assert on specific nodes, and
-- a fixture whose ids move every load can only be asserted about vaguely.
--   companies c0…  people b0…  events e0…  filings f0…  orgs a0…
-- ------------------------------------------------------------
insert into demo.companies (id, name, ticker, is_public, org_id, blurb) values
    -- The shared tier: public companies, visible to every tenant.
    ('c0000000-0000-0000-0000-000000000001','Acme Robotics','ACME',true,null,
     'industrial arms, the hub of this fixture'),
    ('c0000000-0000-0000-0000-000000000002','Nadler Systems','NDLR',true,null,
     'control software'),
    ('c0000000-0000-0000-0000-000000000003','Borealis Mining','BRLS',true,null,
     'rare earths'),
    ('c0000000-0000-0000-0000-000000000004','Cygnus Labs','CYGL',true,null,
     'a subsidiary of Acme'),
    ('c0000000-0000-0000-0000-000000000005','Helios Freight','HLFR',true,null,
     'a second subsidiary of Acme'),
    -- Reachable only at depth 2, and by two different routes -- the shape that
    -- makes a per-path result set say 'Meridian' three times when the caller
    -- asked what is related to Acme (schema.sql, graph_walk's DISTINCT ON).
    ('c0000000-0000-0000-0000-000000000006','Meridian Optics','MRDN',true,null,
     'reached at depth 2 by two routes'),
    -- No edges at all. A seed with no neighbours must return zero rows rather
    -- than erroring, and must not be confused with a key that did not resolve.
    ('c0000000-0000-0000-0000-000000000007','Quill & Sons',null,true,null,
     'deliberately unconnected'),
    -- EXCLUDED by the inclusion predicate: is_public = false. No node, no key,
    -- and therefore cannot be an edge endpoint. schema.sql §8 measured exactly
    -- this and had no committed fixture to measure it against again.
    ('c0000000-0000-0000-0000-000000000008','Vantage Partners',null,false,null,
     'private -- must never appear in aiq.nodes'),
    -- The two tenants. Public AND org-scoped: tenancy and inclusion are
    -- orthogonal, and a fixture that conflated them could not tell which one
    -- was doing the filtering.
    ('c0000000-0000-0000-0000-000000000009','Northwind Capital','NWND',true,
     'a0000000-0000-0000-0000-00000000000a','org A only'),
    ('c0000000-0000-0000-0000-00000000000a','Eastgate Holdings','ESTG',true,
     'a0000000-0000-0000-0000-00000000000b','org B only')
on conflict (id) do update set
    name = excluded.name, ticker = excluded.ticker,
    is_public = excluded.is_public, org_id = excluded.org_id,
    blurb = excluded.blurb;

insert into demo.people (id, full_name, role, org_id) values
    ('b0000000-0000-0000-0000-000000000001','Dana Whitfield','chief executive',null),
    ('b0000000-0000-0000-0000-000000000002','Marcus Oyelaran','chief engineer',null),
    ('b0000000-0000-0000-0000-000000000003','Priya Raman','geologist',null),
    ('b0000000-0000-0000-0000-000000000004','Tomas Lindqvist','analyst',
     'a0000000-0000-0000-0000-00000000000a')
on conflict (id) do update set
    full_name = excluded.full_name, role = excluded.role, org_id = excluded.org_id;

insert into demo.events (id, title, occurred_at, primary_company_id, org_id) values
    ('e0000000-0000-0000-0000-000000000001','Acme Q3 results','2026-07-14',
     'c0000000-0000-0000-0000-000000000001',null),
    ('e0000000-0000-0000-0000-000000000002','Borealis strike','2026-08-02',
     'c0000000-0000-0000-0000-000000000003',null),
    -- No primary company: the hard link is nullable, and a walk seeded here
    -- must not assume it resolves.
    ('e0000000-0000-0000-0000-000000000003','Sector rout','2026-08-19',null,null)
on conflict (id) do update set
    title = excluded.title, occurred_at = excluded.occurred_at,
    primary_company_id = excluded.primary_company_id, org_id = excluded.org_id;

-- Twelve data-plane rows against three companies. They exist to be counted and
-- found absent from the registry.
insert into demo.filings (id, company_id, filed_on, form, body)
select ('f0000000-0000-0000-0000-0000000000' || lpad(g::text, 2, '0'))::uuid,
       (array['c0000000-0000-0000-0000-000000000001',
              'c0000000-0000-0000-0000-000000000002',
              'c0000000-0000-0000-0000-000000000003'])[1 + (g % 3)]::uuid,
       date '2026-01-15' + (g * 21),
       case when g % 2 = 0 then '10-Q' else '8-K' end,
       'filing body ' || g
from generate_series(1, 12) g
on conflict (id) do nothing;

-- ------------------------------------------------------------
-- 3. Registration: three entity types, three key expressions.
--
-- The expressions are SQL text evaluated against the source row aliased `n`
-- -- that alias is part of the contract, not cosmetic (schema.sql's note on
-- rebuild_entity_type). Registering also builds the projection triggers, so
-- the inserts above are picked up by the rebuild below rather than by the
-- trigger; a second run of this file goes through the trigger instead. Both
-- paths must produce the same registry, which is what D7's drift check is for
-- and what dev/tests/query/04 asserts directly.
-- ------------------------------------------------------------
select aiq.register_entity_table(
    p_entity_type   => 'company',
    p_source_table  => 'demo.companies',
    -- Ticker first: it is the short, stable name a person actually types.
    -- Falling back to the name keeps Quill & Sons (no ticker) addressable.
    p_key_expr      => 'coalesce(n.ticker, n.name)',
    p_summary_expr  => 'n.name',
    p_org_expr      => 'n.org_id',
    p_include_where => 'n.is_public');

select aiq.register_entity_table(
    p_entity_type   => 'person',
    p_source_table  => 'demo.people',
    p_key_expr      => 'n.full_name',
    p_summary_expr  => 'n.full_name',
    p_org_expr      => 'n.org_id');

select aiq.register_entity_table(
    p_entity_type   => 'event',
    p_source_table  => 'demo.events',
    p_key_expr      => 'n.title',
    p_summary_expr  => 'n.title',
    p_org_expr      => 'n.org_id');

select aiq.rebuild_entity_type('company');
select aiq.rebuild_entity_type('person');
select aiq.rebuild_entity_type('event');

-- THE REFRESH OBLIGATION, discharged where it is incurred. Registering a new
-- entity type does not widen the machine relation catalogue -- the triples are
-- (every registered type + soft + lake)^2 x relations, generated at
-- registration time and deliberately NOT by a trigger on entity_registry,
-- because one module silently writing another's catalogue is worse than a
-- legible failure. The legible failure is real: without this line the stack
-- came up with `party_to` catalogued over the three types that existed when
-- the extension installed and none of the three added here, so
-- specs/world-model-ingestion/graph-demo.sql -- whose own header says it needs
-- this call -- died on `relation (document, party_to, company) is not in the
-- catalogue`. The error names the remedy, and this is the remedy; a sample
-- stack that ships needing an undocumented manual step is a step nobody runs.
select aiq.register_graph_vocabulary() -> 'triples_added' as catalogue_widened;

-- ------------------------------------------------------------
-- 4. Aliases and short keys.
--
-- The projection writes CANONICAL keys only -- one per row, from key_expr.
-- Short keys and aliases are the other two thirds of the lookup cascade
-- (graph-identity.md "Keys": exact canonical, then short, then fuzzy), and
-- nothing projects them because they are editorial, not derived: 'kiev' is an
-- alias for 'kyiv' because somebody said so.
--
-- They are added through aiq.add_node_key(), not by writing node_keys
-- directly -- invariant 5 says application code never touches that table, and
-- until this function existed the entire short/alias branch of LOOKUP had no
-- supported way to be populated at all.
-- ------------------------------------------------------------
select aiq.add_node_key('ACME',  'acme',           'short');
select aiq.add_node_key('ACME',  'acme robotics',  'alias');
select aiq.add_node_key('NDLR',  'nadler',         'short');
select aiq.add_node_key('BRLS',  'borealis',       'short');
-- The same short string, canonical for one type and short for another: this
-- is graph-identity.md's Bakhmut case, and it is why short-key lookup returns
-- several nodes rather than one.
select aiq.add_node_key('Borealis strike', 'borealis', 'short');

-- ------------------------------------------------------------
-- 5. The relation catalogue.
--
-- Every allowed (src_type, relation, dst_type) triple. An unlisted triple is
-- refused at write, so the graph cannot accumulate typos-as-relations. The
-- inverse label is read-time only: the reverse edge is never stored.
-- ------------------------------------------------------------
insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
    -- NOT declared is_symmetric, and the description used to say it was.
    -- `competes_with` IS symmetric by meaning, and declaring it here would make
    -- the catalogue trigger normalise endpoint order -- which would reorder the
    -- sample's own edges and with them the `out`/`in` column of the walk output
    -- USAGE.md 5 quotes as measured. The fixture is what several documented
    -- outputs are measured against, so the flag is a fixture change rather than
    -- a one-line fix, and the honest thing in the meantime is a description
    -- that does not claim behaviour the flag never produced.
    ('company','competes_with','company','competes_with',
     'rivalry; symmetric by meaning, stored with direction here (see above)'),
    ('company','subsidiary_of','company','parent_of',
     'ownership as an authored claim, not a foreign key'),
    ('person','works_at','company','employs', 'current employment'),
    ('person','knows','person','knows',
     'acquaintance; symmetric by meaning, stored with direction (see competes_with)'),
    ('event','mentions','company','mentioned_in', 'the event names this company'),
    ('event','mentions','person','mentioned_in', 'the event names this person'),
    ('company','partners_with','company','partners_with',
     'used by the cross-tenant edge below')
on conflict (src_type, relation, dst_type) do update
    set inverse_label = excluded.inverse_label, description = excluded.description;

-- ------------------------------------------------------------
-- 6. The soft edges.
--
-- Endpoints are resolved from the typed-table ids through the registry, which
-- is the only supported way: edges reference node ids, never display keys
-- (D3), and names are resolved ONCE at write so traversal never parses them.
--
-- Weights are not decoration. `edges.weight` is where a coherence score lands
-- (brief.md §3.6), so the fixture carries a spread -- a barely-corroborated
-- 0.35 next to a 0.95 -- rather than nine copies of the default 1.0 that no
-- ordering assertion could tell apart.
-- ------------------------------------------------------------
-- rbac.org_or_shared() on the way in: the `null` each row below carries is
-- this fixture saying "no tenant in particular", and aiq.edges.org_id is NOT
-- NULL (specs/identity/spec.md §4). The literal stays `null` because that is
-- what the fixture MEANS -- an omission -- and the coercion to the shared org
-- happens at the boundary, exactly as it does for every writer in the
-- collection. Edges are not read-gated by org_id anyway; both endpoints are.
insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id)
select s.id, d.id, v.relation, v.weight::real, v.provenance::jsonb,
       rbac.org_or_shared(v.org_id::uuid)
from (values
    -- A three-cycle. Every walk has to survive returning to where it started.
    ('company','c0000000-0000-0000-0000-000000000001','competes_with','company','c0000000-0000-0000-0000-000000000002',0.90,'{"source":"analyst"}',null),
    ('company','c0000000-0000-0000-0000-000000000002','competes_with','company','c0000000-0000-0000-0000-000000000003',0.55,'{"source":"analyst"}',null),
    ('company','c0000000-0000-0000-0000-000000000003','competes_with','company','c0000000-0000-0000-0000-000000000001',0.35,'{"source":"blog","note":"single uncorroborated claim"}',null),
    -- The hub: two subsidiaries pointing IN to Acme. The reverse question
    -- ("what points at Acme?") is answered from dst_id with the catalogue's
    -- inverse label, never from a second stored row.
    ('company','c0000000-0000-0000-0000-000000000004','subsidiary_of','company','c0000000-0000-0000-0000-000000000001',0.95,'{"source":"registry"}',null),
    ('company','c0000000-0000-0000-0000-000000000005','subsidiary_of','company','c0000000-0000-0000-0000-000000000001',0.95,'{"source":"registry"}',null),
    -- Meridian at depth 2 from Acme by two routes (via Cygnus, via Helios).
    ('company','c0000000-0000-0000-0000-000000000004','partners_with','company','c0000000-0000-0000-0000-000000000006',0.60,'{"source":"press"}',null),
    ('company','c0000000-0000-0000-0000-000000000005','partners_with','company','c0000000-0000-0000-0000-000000000006',0.60,'{"source":"press"}',null),
    -- People, and a person-to-person edge so the walk crosses entity types.
    ('person','b0000000-0000-0000-0000-000000000001','works_at','company','c0000000-0000-0000-0000-000000000001',1.00,'{"source":"filing"}',null),
    ('person','b0000000-0000-0000-0000-000000000002','works_at','company','c0000000-0000-0000-0000-000000000002',1.00,'{"source":"filing"}',null),
    ('person','b0000000-0000-0000-0000-000000000003','works_at','company','c0000000-0000-0000-0000-000000000003',1.00,'{"source":"filing"}',null),
    ('person','b0000000-0000-0000-0000-000000000001','knows','person','b0000000-0000-0000-0000-000000000002',0.70,'{"source":"conference"}',null),
    -- Events mention both companies and people: one relation NAME, two
    -- catalogue triples, which is what makes TYPE mentions cross types.
    ('event','e0000000-0000-0000-0000-000000000001','mentions','company','c0000000-0000-0000-0000-000000000001',1.00,'{}',null),
    ('event','e0000000-0000-0000-0000-000000000001','mentions','person','b0000000-0000-0000-0000-000000000001',1.00,'{}',null),
    ('event','e0000000-0000-0000-0000-000000000002','mentions','company','c0000000-0000-0000-0000-000000000003',1.00,'{}',null),
    -- The cross-tenant edge: org A's node to org B's node. Its endpoints are
    -- never both visible to anybody, so it must be visible to nobody -- and
    -- it must not disclose, to either tenant, that the other's node exists.
    ('company','c0000000-0000-0000-0000-000000000009','partners_with','company','c0000000-0000-0000-0000-00000000000a',0.50,'{"source":"rumour"}',null)
) as v(src_type, src_entity, relation, dst_type, dst_entity, weight, provenance, org_id)
join aiq.nodes s on s.entity_type = v.src_type and s.entity_id = v.src_entity::uuid
join aiq.nodes d on d.entity_type = v.dst_type and d.entity_id = v.dst_entity::uuid
on conflict (src_id, dst_id, relation) do update
    set weight = excluded.weight, provenance = excluded.provenance;

-- ------------------------------------------------------------
-- 7. What the fixture is, in one query, so a reader can check it landed.
-- ------------------------------------------------------------
do $$
declare
    v_nodes int; v_keys int; v_edges int; v_excluded int;
begin
    select count(*) into v_nodes from aiq.nodes
     where entity_type in ('company','person','event');
    select count(*) into v_keys from aiq.node_keys k
     join aiq.nodes n on n.id = k.node_id
     where n.entity_type in ('company','person','event');
    select count(*) into v_edges from aiq.edges;
    select count(*) into v_excluded from demo.companies c
     where not exists (select 1 from aiq.nodes n
                        where n.entity_type = 'company' and n.entity_id = c.id);
    raise notice 'graph sample: % nodes, % keys, % edges, % company row(s) '
                 'correctly excluded, % filings that are not nodes',
        v_nodes, v_keys, v_edges, v_excluded,
        (select count(*) from demo.filings);
end $$;

-- ------------------------------------------------------------
-- 8. Grants.
--
-- The query functions are SECURITY INVOKER by design, so a caller reaching a
-- consumer's typed table needs real access to it -- integration-rbac.sql §3b
-- states explicitly that the aiq schema must NOT reach into a consumer schema
-- and decide who may read it. This file owns `demo`, so this is that
-- consumer's own call, made here.
--
-- RLS on the typed tables is deliberately NOT enabled: the sample's tenancy
-- assertions are about the REGISTRY's policies (aiq.nodes and what inherits
-- from it), and a second, independent policy on demo.companies would make a
-- failing assertion ambiguous about which layer filtered the row.
-- ------------------------------------------------------------
grant usage on schema demo to authenticated, api_viewer;
grant select on all tables in schema demo to authenticated, api_viewer;

reset role;
