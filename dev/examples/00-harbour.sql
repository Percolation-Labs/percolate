-- The fixture the ten worked examples run against.
--
-- One domain, built once, reused by all ten: a port-operations company with
-- two tenants, a fleet, a corpus of inspection reports and a graph tying them
-- together. Ten fixtures would have been ten domains for a reader to hold in
-- their head, and the interesting examples are the ones where a query written
-- for scenario 3 is answered by data scenario 1 put there.
--
-- Modelled on dev/init/04-graph-sample.sql and 05-corpus-sample.sql, and it
-- reuses their registrations rather than adding a second lexical source or a
-- third embedding space: `chunks` already names content.resource_chunks, and
-- `demo-quad-a` is already a registered 4-dimension space.
--
-- The vectors here are LITERALS, not model output, for the reason
-- 05-corpus-sample.sql states in capitals: a corpus that needs a live
-- embedding server is a corpus nobody can reproduce. Four dimensions is enough
-- to make the three retrieval modes disagree, which is the only thing the
-- examples ask of them.
--
--     docker exec -i p8-experiment-pg19 psql -U p8 -d p8experiment \
--         < dev/examples/00-harbour.sql

set role app_owner;

create schema if not exists harbour;

-- ------------------------------------------------------------
-- 1. The typed tables. Attributes live here; the node registry stores
--    identity only.
--
-- Two tenants and a shared tier, the same three states 04-graph-sample.sql
-- uses: a port is legitimately global, and duplicating Rotterdam per shipping
-- line would defeat the point of one identity registry.
-- ------------------------------------------------------------
create table if not exists harbour.operators (
    id        uuid primary key,
    name      text not null,
    code      text,
    parent_id uuid references harbour.operators(id),
    org_id    uuid
);

create table if not exists harbour.vessels (
    id          uuid primary key,
    name        text not null,
    imo         text not null,
    operator_id uuid references harbour.operators(id),
    status      text not null default 'in_service',
    org_id      uuid
);

create table if not exists harbour.ports (
    id      uuid primary key,
    name    text not null,
    country text not null,
    org_id  uuid
);

-- The data plane. Inspections are rows a query answers FROM; they are not
-- identities anyone looks up by name, so they are never registered as an
-- entity type. 04-graph-sample.sql makes the same point with demo.filings:
-- a table that must never become a node is part of the fixture.
create table if not exists harbour.inspections (
    id              uuid primary key,
    vessel_id       uuid not null references harbour.vessels(id),
    port_id         uuid not null references harbour.ports(id),
    inspected_at    date not null,
    outcome         text not null,
    deficiency_code text,
    org_id          uuid
);

-- ------------------------------------------------------------
-- 2. The data.
-- ------------------------------------------------------------
-- THE TWO TENANTS ARE ROWS, and they were not. This file names
-- `d0000000-...-a` and `-b` in nine places and registered neither, which was
-- harmless while `org_id` was a bare uuid on every table. It stopped being
-- harmless when identity/spec.md §4 made the shared tier a row: the org
-- columns became real references to rbac.orgs, so aiq.rebuild_entity_type()
-- raised `insert or update on table "nodes" violates foreign key constraint
-- "nodes_org_id_fkey"` and the whole fixture stopped loading. Every one of
-- the ten worked examples depends on it.
insert into rbac.orgs (id, slug, name) values
    ('d0000000-0000-0000-0000-00000000000a','meridian','Meridian Line'),
    ('d0000000-0000-0000-0000-00000000000b','kestrel','Kestrel Shipping')
on conflict (id) do nothing;

insert into harbour.operators (id, name, code, parent_id, org_id) values
    ('40000000-0000-0000-0000-000000000001','Meridian Line','MERI',null,'d0000000-0000-0000-0000-00000000000a'),
    ('40000000-0000-0000-0000-000000000002','Kestrel Shipping','KEST',null,'d0000000-0000-0000-0000-00000000000b'),
    ('40000000-0000-0000-0000-000000000003','Meridian Bulk','MERB','40000000-0000-0000-0000-000000000001','d0000000-0000-0000-0000-00000000000a'),
    -- Shared: a chartering house both lines use, owned by neither.
    ('40000000-0000-0000-0000-000000000004','Nordvik Chartering','NORD',null,null)
on conflict (id) do update set
    name = excluded.name, code = excluded.code,
    parent_id = excluded.parent_id, org_id = excluded.org_id;

insert into harbour.vessels (id, name, imo, operator_id, status, org_id) values
    ('50000000-0000-0000-0000-000000000001','Meridian Dawn','9331802','40000000-0000-0000-0000-000000000001','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000002','Meridian Star','9331803','40000000-0000-0000-0000-000000000001','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000003','Bulk Harmony','9407711','40000000-0000-0000-0000-000000000003','in_service','d0000000-0000-0000-0000-00000000000a'),
    ('50000000-0000-0000-0000-000000000004','Aurora Kestrel','9214578','40000000-0000-0000-0000-000000000002','in_service','d0000000-0000-0000-0000-00000000000b'),
    -- Scrapped, and therefore excluded by the registration's include_where.
    -- An inclusion predicate that never excludes anything proves nothing.
    ('50000000-0000-0000-0000-000000000005','Old Pelican','8811234','40000000-0000-0000-0000-000000000004','scrapped',null)
on conflict (id) do update set
    name = excluded.name, imo = excluded.imo,
    operator_id = excluded.operator_id, status = excluded.status,
    org_id = excluded.org_id;

insert into harbour.ports (id, name, country, org_id) values
    ('60000000-0000-0000-0000-000000000001','Rotterdam','Netherlands',null),
    ('60000000-0000-0000-0000-000000000002','Felixstowe','United Kingdom',null),
    ('60000000-0000-0000-0000-000000000003','Gothenburg','Sweden',null)
on conflict (id) do update set name = excluded.name, country = excluded.country;

insert into harbour.inspections (id, vessel_id, port_id, inspected_at, outcome, deficiency_code, org_id) values
    ('70000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000001','2026-06-14','deficiency','PSC-441','d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000002','2026-07-02','clear',null,'d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000003','50000000-0000-0000-0000-000000000003','60000000-0000-0000-0000-000000000001','2026-03-19','deficiency','PSC-441','d0000000-0000-0000-0000-00000000000a'),
    ('70000000-0000-0000-0000-000000000004','50000000-0000-0000-0000-000000000004','60000000-0000-0000-0000-000000000003','2026-07-11','clear',null,'d0000000-0000-0000-0000-00000000000b')
on conflict (id) do update set
    outcome = excluded.outcome, deficiency_code = excluded.deficiency_code;

-- ------------------------------------------------------------
-- 3. Registration. Three entity types, three different key expressions.
-- ------------------------------------------------------------
select aiq.register_entity_table(
    p_entity_type   => 'operator',
    -- Code first: it is the short stable string a person types. Falling back
    -- to the name keeps an operator with no code addressable.
    p_key_expr      => 'coalesce(n.code, n.name)',
    p_source_table  => 'harbour.operators',
    p_summary_expr  => 'n.name',
    p_org_expr      => 'n.org_id');

select aiq.register_entity_table(
    p_entity_type   => 'vessel',
    p_source_table  => 'harbour.vessels',
    p_key_expr      => 'n.name',
    p_summary_expr  => $x$n.name || ' (IMO ' || n.imo || ')'$x$,
    p_org_expr      => 'n.org_id',
    p_include_where => $x$n.status <> 'scrapped'$x$);

select aiq.register_entity_table(
    p_entity_type   => 'port',
    p_source_table  => 'harbour.ports',
    p_key_expr      => 'n.name',
    p_summary_expr  => $x$n.name || ', ' || n.country$x$,
    p_org_expr      => 'n.org_id');

select aiq.rebuild_entity_type('operator');
select aiq.rebuild_entity_type('vessel');
select aiq.rebuild_entity_type('port');

-- Short keys and aliases: editorial, so nothing projects them.
select aiq.add_node_key('MERI', 'meridian', 'short');
select aiq.add_node_key('MERB', 'meridian bulk', 'alias');
select aiq.add_node_key('Meridian Dawn', 'dawn', 'short');

-- ------------------------------------------------------------
-- 4. The relation catalogue, then the edges.
-- ------------------------------------------------------------
insert into aiq.relation_types (src_type, relation, dst_type, inverse_label, description) values
    ('vessel','operated_by','operator','operates','who runs the ship'),
    ('operator','subsidiary_of','operator','parent_of','ownership as an authored claim'),
    ('vessel','last_called','port','received','most recent port of call'),
    ('operator','competes_with','operator','competes_with','symmetric; stored once, walked both ways')
on conflict (src_type, relation, dst_type) do update
    set inverse_label = excluded.inverse_label, description = excluded.description;

-- `rbac.org_or_shared`, because one row below is deliberately null -- the
-- rivalry both tenants can see -- and org_id is NOT NULL since
-- identity/spec.md §4. That function is the collection's one spelling of "an
-- omitted org means the shared tier", so the fixture below still reads as it
-- did and the column gets the row the sentinel names.
insert into aiq.edges (src_id, dst_id, relation, weight, provenance, org_id)
select s.id, d.id, v.relation, v.weight::real, v.provenance::jsonb,
       rbac.org_or_shared(v.org_id::uuid)
from (values
    ('vessel','50000000-0000-0000-0000-000000000001','operated_by','operator','40000000-0000-0000-0000-000000000001',1.00,'{"source":"registry"}','d0000000-0000-0000-0000-00000000000a'),
    ('vessel','50000000-0000-0000-0000-000000000002','operated_by','operator','40000000-0000-0000-0000-000000000001',1.00,'{"source":"registry"}','d0000000-0000-0000-0000-00000000000a'),
    ('vessel','50000000-0000-0000-0000-000000000003','operated_by','operator','40000000-0000-0000-0000-000000000003',1.00,'{"source":"registry"}','d0000000-0000-0000-0000-00000000000a'),
    ('vessel','50000000-0000-0000-0000-000000000004','operated_by','operator','40000000-0000-0000-0000-000000000002',1.00,'{"source":"registry"}','d0000000-0000-0000-0000-00000000000b'),
    -- The ownership chain the GRAPH example walks: Bulk Harmony -> Meridian
    -- Bulk -> Meridian Line is a two-hop answer to "who ultimately runs it".
    ('operator','40000000-0000-0000-0000-000000000003','subsidiary_of','operator','40000000-0000-0000-0000-000000000001',0.95,'{"source":"registry"}','d0000000-0000-0000-0000-00000000000a'),
    -- Weights are not decoration: a rivalry asserted by one trade paper sits
    -- at 0.4 next to a filing-backed 1.0, so an ordering assertion has
    -- something to order.
    ('operator','40000000-0000-0000-0000-000000000001','competes_with','operator','40000000-0000-0000-0000-000000000002',0.40,'{"source":"trade press"}',null),
    ('vessel','50000000-0000-0000-0000-000000000001','last_called','port','60000000-0000-0000-0000-000000000001',1.00,'{"source":"ais"}','d0000000-0000-0000-0000-00000000000a'),
    ('vessel','50000000-0000-0000-0000-000000000003','last_called','port','60000000-0000-0000-0000-000000000001',1.00,'{"source":"ais"}','d0000000-0000-0000-0000-00000000000a'),
    ('vessel','50000000-0000-0000-0000-000000000004','last_called','port','60000000-0000-0000-0000-000000000003',1.00,'{"source":"ais"}','d0000000-0000-0000-0000-00000000000b')
) as v(src_type, src_key, relation, dst_type, dst_key, weight, provenance, org_id)
join aiq.nodes s on s.entity_type = v.src_type and s.entity_id = v.src_key::uuid
join aiq.nodes d on d.entity_type = v.dst_type and d.entity_id = v.dst_key::uuid
on conflict (src_id, dst_id, relation) do update set weight = excluded.weight;

-- ------------------------------------------------------------
-- 5. The corpus: five inspection reports.
--
-- Written so the three retrieval modes DISAGREE, because a corpus where they
-- agree cannot show why there are three:
--
--   h1  the rare code, verbatim            -- TEXT finds it, SEMANTIC need not
--   h2  the same meaning, no shared words  -- SEMANTIC finds it, TEXT cannot
--   h3  a distractor sharing neither
--   h4  the rare code again, in tenant A
--   h5  tenant B, and it must never answer a tenant A query
-- ------------------------------------------------------------
-- `rbac.shared_org_id()` and `public`, not `null` and the default. org_id is
-- NOT NULL since identity/spec.md §4 -- a literal null raises before the
-- fixture reaches its first example -- and a channel left at the default pair
-- (private, no owner) is one rbac.may_read grants to nobody.
insert into content.channels (id, name, kind, org_id, visibility) values
    ('11110000-0000-0000-0000-000000000002','harbour-reports','manual',
     rbac.shared_org_id(),'public')
on conflict (id) do update set name = excluded.name;

insert into content.resources (id, channel_id, external_id, uri, title, status, org_id, visibility) values
    ('24240000-0000-0000-0000-000000000001','11110000-0000-0000-0000-000000000002','psc-rot','memo://psc/rotterdam','Rotterdam PSC report','ready',rbac.shared_org_id(),'public'),
    ('24240000-0000-0000-0000-000000000002','11110000-0000-0000-0000-000000000002','eng-boiler','memo://engineering/boiler','Auxiliary machinery note','ready',rbac.shared_org_id(),'public'),
    ('24240000-0000-0000-0000-000000000003','11110000-0000-0000-0000-000000000002','crew-hyg','memo://crew/hygiene','Accommodation inspection','ready',rbac.shared_org_id(),'public'),
    -- `org`, which is what naming a tenant means, and what makes h4/h5 the
    -- tenancy probe the header above describes.
    ('24240000-0000-0000-0000-000000000004','11110000-0000-0000-0000-000000000002','meri-exp','memo://meridian/exposure','Meridian fleet exposure','ready','d0000000-0000-0000-0000-00000000000a','org'),
    ('24240000-0000-0000-0000-000000000005','11110000-0000-0000-0000-000000000002','kest-pos','memo://kestrel/position','Kestrel fleet position','ready','d0000000-0000-0000-0000-00000000000b','org')
on conflict (id) do update set title = excluded.title, org_id = excluded.org_id;

insert into content.resource_chunks (id, resource_id, ordinal, content) values
    ('34340000-0000-0000-0000-000000000001','24240000-0000-0000-0000-000000000001',0,
     'Port state control at Rotterdam raised deficiency PSC-441 against the auxiliary boiler.'),
    ('34340000-0000-0000-0000-000000000002','24240000-0000-0000-0000-000000000002',0,
     'The secondary steam generator was found unserviceable and requires survey before sailing.'),
    ('34340000-0000-0000-0000-000000000003','24240000-0000-0000-0000-000000000003',0,
     'Crew accommodation and galley hygiene were satisfactory throughout the visit.'),
    ('34340000-0000-0000-0000-000000000004','24240000-0000-0000-0000-000000000004',0,
     'Meridian internal: PSC-441 exposure now covers two vessels in the bulk fleet.'),
    ('34340000-0000-0000-0000-000000000005','24240000-0000-0000-0000-000000000005',0,
     'Kestrel reports no boiler deficiencies across the fleet this quarter.')
on conflict (id) do update set content = excluded.content;

-- Space demo-quad-a, already registered. The query vector the examples use is
-- [0,0,0.707,0.707] -- "a boiler fault" -- and h2 sits exactly on it while
-- sharing not one word with the question, which is the disagreement between
-- TEXT and SEMANTIC made reproducible.
--
-- The third and fourth dimensions are not arbitrary. `chunks` is ONE
-- registered source over all of content.resource_chunks, so this corpus shares
-- it with dev/init/05-corpus-sample.sql, whose six vectors all lie in the
-- first two dimensions or on a bare third/fourth axis. Placing these here
-- keeps the two sample corpora from answering each other's questions: under
-- this query the nearest 05 chunk is 0.29 away and every harbour chunk that
-- should rank is nearer. Four dimensions is a small room and two fixtures have
-- to agree on where they stand in it.
insert into aiq.emb_demo_quad_a (chunk_id, embedding) values
    ('34340000-0000-0000-0000-000000000001','[0,0,0.9,0.436]'),
    ('34340000-0000-0000-0000-000000000002','[0,0,0.707,0.707]'),
    ('34340000-0000-0000-0000-000000000003','[0.707,0.707,0,0]'),
    ('34340000-0000-0000-0000-000000000004','[0,0,0.6,0.8]'),
    ('34340000-0000-0000-0000-000000000005','[0,1,0,0]')
on conflict (chunk_id) do update set embedding = excluded.embedding;

-- ------------------------------------------------------------
-- 6. A person, and the one role authoring takes.
--
-- The human-in-the-loop example needs somebody, because `signal_task` refuses
-- a run nobody owns: a run with owner_id null is not "owned by everyone", it
-- takes an explicit permission. The owner is set from the `sub` claim when
-- the run starts, so the examples that signal must run as somebody.
--
-- THE ROLE IS NOT DECORATION. `workflow.may_define()` has two branches: a
-- caller with no `sub` falls through to "does session_user hold insert on
-- workflow.definitions", which app_owner does -- so 06 and 07, which set orgs
-- and no sub, define workflows without a role. The moment a claim carries a
-- `sub` the other branch runs, and asks whether THAT USER holds
-- workflows:update. Naming a person therefore makes authoring stricter, not
-- looser, and 08 and 09 broke on exactly that: they set a sub so the run has
-- an owner to signal, and the user they named held nothing.
--
-- admin, because it is the only role that carries workflows:update -- a step
-- may carry its own SQL that runs as the engine owner, so defining one is an
-- authoring privilege rather than a read, which is what the refusal says.
-- ------------------------------------------------------------
insert into rbac.users (id, email, status) values
    ('80000000-0000-0000-0000-000000000001','harbourmaster@meridian.example','active'),
    -- A SECOND PERSON, and the tenancy examples are why. 04 and 03 show the
    -- same query answered differently for two tenants; with one user they
    -- could only ever change the `orgs` array, and an array is no longer what
    -- decides (below).
    ('80000000-0000-0000-0000-000000000002','harbourmaster@kestrel.example','active')
on conflict (id) do update set email = excluded.email;

insert into rbac.user_roles (user_id, role) values
    ('80000000-0000-0000-0000-000000000001','admin'),
    ('80000000-0000-0000-0000-000000000002','admin')
on conflict do nothing;

-- ------------------------------------------------------------
-- AND THEY ARE MEMBERS OF SOMETHING, which is the fact every example in this
-- directory silently assumed and none of them established.
--
-- user-rbac §"Tenancy is now a table, not a claim": rbac.current_org_ids()
-- reads rbac.org_members for current_user_id() and INTERSECTS that with the
-- token's `orgs` array. A token may narrow its holder's reach and can never
-- widen it. So a claim carrying `orgs` and no `sub` resolves to no orgs at
-- all -- not to the orgs it names.
--
-- Every example here sent exactly that claim, and 04 is what it cost.
-- Its own echoes read "Meridian sees its own fleet" and "Kestrel, same query,
-- DIFFERENT answer"; both tenants got the identical one shared row, and the
-- file passed. A tenancy demonstration that demonstrates the opposite of its
-- claim is worse than one that fails, and dev/examples/run.sh's header says
-- the docs pages are written from this transcript.
insert into rbac.org_members (org_id, user_id, role) values
    ('d0000000-0000-0000-0000-00000000000a','80000000-0000-0000-0000-000000000001','admin'),
    ('d0000000-0000-0000-0000-00000000000b','80000000-0000-0000-0000-000000000002','admin')
on conflict do nothing;

-- ------------------------------------------------------------
-- 7. One step function, for the fan-out example.
--
-- `matrix: rows:` names a function in the workflow.step_functions allow-list
-- rather than taking an inline SELECT, so a workflow document cannot smuggle
-- arbitrary SQL past the compiler. Registering one is the price, and it is
-- also where the query that decides the fan-out width lives.
-- ------------------------------------------------------------
create or replace function harbour.deficient_vessels()
returns jsonb language sql stable as $f$
    select coalesce(jsonb_agg(jsonb_build_object(
               'vessel', v.name, 'imo', v.imo, 'code', i.deficiency_code)
               order by v.name), '[]'::jsonb)
    from harbour.inspections i
    join harbour.vessels v on v.id = i.vessel_id
    where i.outcome = 'deficiency';
$f$;

select workflow.register_step_function(
    'deficient_vessels', 'harbour.deficient_vessels', '{}',
    p_description => 'vessels with an open PSC deficiency, one row each');

do $$
begin
    raise notice 'harbour fixture: % operators, % vessels, % ports, % inspections, % nodes, % edges, % chunks',
        (select count(*) from harbour.operators),
        (select count(*) from harbour.vessels),
        (select count(*) from harbour.ports),
        (select count(*) from harbour.inspections),
        (select count(*) from aiq.nodes where entity_type in ('vessel','operator','port')),
        (select count(*) from aiq.edges e join aiq.nodes n on n.id = e.src_id
          where n.entity_type in ('vessel','operator')),
        (select count(*) from content.resource_chunks where resource_id::text like '2424%');
end $$;
