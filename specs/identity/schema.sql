-- Identity and nullability: the mechanism. See spec.md for the reasoning.
--
-- Two objects and nothing else. The policy is mostly a set of assertions
-- (checks.sql); what has to SHIP is the deterministic id function and the
-- registry that makes a NULL's meaning declarable.

-- This file is FIRST in the extension, so it creates the schema it lives in.
-- contract/schema.sql does the same, idempotently, for whichever of the two
-- someone reads first.
create schema if not exists percolate;

-- NOTHING THIS ROLE CREATES IS EVERYBODY'S BY DEFAULT. Postgres grants EXECUTE
-- to PUBLIC on every new function, and every function here that is SECURITY
-- DEFINER runs as the owner of every table, past RLS. The collection used to
-- take that default away one schema at a time -- `revoke ... on all functions
-- in schema X` -- which covers only the functions that already exist when it
-- runs and only the schemas someone listed. Three holes came through that gap:
-- percolate.apply_package, and every function of the pgvector-watch package,
-- which a signed-in person could call through aiq.sql_passthrough to read any
-- org's issues (2026-09-11). So the default is changed once, here, FIRST, for
-- everything the installing role creates afterwards -- the rest of this script,
-- every later upgrade, and every package applied as app_owner. A function a
-- caller may use says so with a grant naming them. dev/tests/rbac/04 asserts it
-- across every schema.
alter default privileges revoke execute on functions from public;

-- ------------------------------------------------------------
-- 0. Which schemas are this extension's, read from the catalog.
--
-- Every gate that asks a question "across the extension" used to answer this
-- with a list typed at the point of use: 25 to 40 copies in about seven
-- spellings. rbac/04 and rbac/05 named `wm`, which does not exist, and not
-- `percolate`; surface.sql's function arm left out `percolate` while its
-- relation arm had it; upgrade-converges.sh had eight copies and none had
-- `percolate`, so no percolate.* object or grant had ever been compared; the
-- PUBLIC-EXECUTE invariant at the end of the install named five schemas and
-- missed the sixth (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md
-- §4, REM-45). A schema added next year would have been missing from all of
-- them, and none of them would have said so.
--
-- Postgres already records the answer. CREATE EXTENSION and ALTER EXTENSION
-- UPDATE write an 'e' dependency from every object the script creates to the
-- extension, schemas included, so this reads pg_depend and restates nothing.
--
-- IT REFUSES RATHER THAN ANSWER EMPTY. A script loaded with `psql -f` is not
-- an install and records no membership, and every gate that reads this would
-- then walk no schemas and pass having looked at nothing. One refusal here
-- covers every caller, instead of a guard in front of each of them.
--
-- A gate that must also cover something the extension does not own -- `public`,
-- a package's schema, a hand-loaded NOT_SHIPPED file -- adds it beside this
-- call with its reason, so the exception is visible where it is made.
--
-- SECURITY INVOKER and everybody's: it reads nothing a caller could not read
-- from pg_depend directly, and the gates run as p8, app_owner and the roles a
-- person becomes. dev/lib/extension-schemas.sh carries the same query for a
-- database older than this function, and compares the two wherever both exist.
create or replace function percolate.extension_schemas()
returns setof name
language plpgsql stable parallel safe as $$
begin
    return query
    select n.nspname
      from pg_catalog.pg_depend d
      join pg_catalog.pg_namespace n on n.oid = d.objid
     where d.classid = 'pg_catalog.pg_namespace'::pg_catalog.regclass
       and d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
       and d.refobjid = (select x.oid from pg_catalog.pg_extension x
                          where x.extname = 'percolate')
       and d.deptype = 'e'
     order by 1;
    if not found then
        raise exception 'no schema belongs to the percolate extension in this database'
            using detail = 'Membership is recorded by CREATE EXTENSION and ALTER EXTENSION '
                           'UPDATE. A script run with psql -f records none, and a gate '
                           'reading an empty set of schemas checks nothing.',
                  hint   = 'Install with CREATE EXTENSION percolate.';
    end if;
end;
$$;

comment on function percolate.extension_schemas() is
    'Every schema the percolate extension owns, from pg_depend. What a gate '
    'reads instead of a list of schema names.';

grant execute on function percolate.extension_schemas() to public;

-- ------------------------------------------------------------
-- 1. A deterministic UUID, so a derived row has the same id every time.
--
-- RFC 4122 §4.3 v5: SHA-1 over (namespace || name), first 16 octets, version
-- nibble set to 5, variant bits to RFC 4122. Verified against the published
-- vector: uuidv5(DNS, 'python.org') = 886313e1-3b8a-5372-9b90-0c9aee199e5d.
--
-- In the extension rather than in a client, because a worker written in
-- another language must be able to compute the same id -- that is
-- challenge-the-process §9's test: can a client that has never heard of
-- percolate-core discover it.
--
-- NOT uuid-ossp. pgcrypto is already required and postgres-manifest.md's rule
-- is that an extension is named when something needs it; one function is not
-- something.
-- ------------------------------------------------------------
-- `set search_path` IS LOAD-BEARING HERE, NOT HYGIENE, and the case that
-- proves it is a restore. `pg_dump` writes `select pg_catalog.set_config(
-- 'search_path', '', false)` at the top of every dump -- that is what makes a
-- restore hermetic -- and every trigger on a dumped table then fires with an
-- empty path during COPY. `digest()` is pgcrypto's, which lives in `public`,
-- so an unqualified call could not resolve and the load failed:
--
--     ERROR:  function digest(bytea, unknown) does not exist
--
-- Measured on a live 0.2.0 by dumping a seeded database and loading it one
-- table at a time: three of four sampled tables errored -- content.resources,
-- workflow.runs and aiq.nodes -- and only rbac.users came back. The rows were
-- in the file; they would not go back in. dev/backup-carries-the-data.sh
-- proves the write half of that round trip and never proved the read half,
-- which is the class meta/postmortems/2026-09-11-fixed-at-the-copy-that-
-- failed.md keeps naming. dev/restore-is-possible.sh now does the round trip.
create or replace function percolate.uuidv5(p_namespace uuid, p_name text)
returns uuid language sql immutable strict parallel safe
set search_path = pg_catalog, public as $$
    with h as (
        select substring(
                   digest(decode(replace(p_namespace::text, '-', ''), 'hex')
                          || convert_to(p_name, 'UTF8'), 'sha1')
                   from 1 for 16) as b)
    select encode(set_byte(set_byte(b, 6, (get_byte(b, 6) & 15) | 80),
                           8, (get_byte(b, 8) & 63) | 128), 'hex')::uuid
    from h;
$$;

comment on function percolate.uuidv5(uuid, text) is
    'RFC 4122 v5. Use for the id of a row derived from something that already '
    'has an identity, so re-deriving converges. Never md5(x)::uuid -- that '
    'produces version 0, which is not a UUID and compares unequal to a '
    'correctly generated one.';

-- Namespaces for the kinds of thing this collection derives ids for. A
-- namespace is itself a v5 under the RFC's DNS namespace, so it is
-- reproducible by anyone rather than a magic constant somebody invented.
create or replace function percolate.id_namespace(p_kind text)
returns uuid language sql immutable strict parallel safe as $$
    select percolate.uuidv5('6ba7b810-9dad-11d1-80b4-00c04fd430c8'::uuid,
                            'percolationlabs.ai/' || p_kind);
$$;

-- Everybody's, by design: pure arithmetic over their arguments, and a client
-- that has never heard of percolate-core must be able to compute the same id.
-- Said with a grant now that nothing is everybody's by default.
grant execute on function percolate.uuidv5(uuid, text) to public;
grant execute on function percolate.id_namespace(text) to public;

-- ------------------------------------------------------------
-- 2. What a NULL means, declared rather than guessed.
--
-- This collection uses NULL two incompatible ways inside unique constraints:
-- `org_id is null` means SHARED ACROSS EVERY TENANT (a value), and
-- `external_id is null` means NO EXTERNAL IDENTITY WAS SUPPLIED (an absence).
-- A unique index does not constrain rows whose key is NULL, which is correct
-- for an absence and catastrophic for a value -- and nothing in the schema
-- distinguishes them, so every reader and every agent has to guess.
--
-- This table is the declaration. checks.sql refuses a unique index over a
-- nullable column that has not made one.
-- ------------------------------------------------------------
create table if not exists percolate.null_means (
    schema_name text not null,
    table_name  text not null,
    column_name text not null,
    means       text not null check (means in ('value', 'absence')),
    why         text not null,
    primary key (schema_name, table_name, column_name)
);
comment on table percolate.null_means is
    'What a NULL is allowed to mean in a given column: a value or an absence. A column that will not say is refused.';

comment on table percolate.null_means is
    'Declares whether a nullable column''s NULL is a VALUE (a real state, so a '
    'unique index over it must be NULLS NOT DISTINCT) or an ABSENCE (unknown '
    'or not applicable, so NULLS DISTINCT is correct). Shipped vocabulary: '
    'the meaning of a column is a property of the schema, not of a deployment.';

-- ------------------------------------------------------------
-- 3. What KIND of table this is, because "every table has a uuid id" is
--    wrong and the first draft of checks.sql proved it.
--
-- That check fired 28 times and every one of the first twenty was correct
-- design:
--
--   vocabulary  rbac.roles(name), workflow.lifecycle_states(state),
--               aiq.relation_types(src_type, relation, dst_type)
--               -- the term IS the identity. A surrogate here is ceremony,
--               and referencing the VALUE is the whole point of
--               challenge-the-process §9.
--   junction    rbac.org_members(org_id, user_id),
--               workflow.task_dependencies(task_id, depends_on_task_id)
--               -- a composite of two foreign keys. A surrogate adds a column
--               nothing will ever reference.
--   log         rbac.auth_events(id bigint), workflow.task_events(id bigint)
--               -- append-only. A monotonic bigint is smaller, ordered, and
--               strictly better than a uuid where nothing is generated
--               anywhere but here.
--
--   natural     aiq.node_keys(node_id, key, kind),
--               aiq.schema_revisions(facet, revision)
--               -- a composite that IS the identity and is not made only of
--               foreign keys. Nothing references it by surrogate, so adding
--               one would create a column with no readers. Distinct from
--               junction, which is all-FK, and from vocabulary, which is a
--               single term.
--
-- Only an ENTITY -- a thing other rows reference, created by the system,
-- whose natural key may change -- needs a surrogate uuid. So the policy is
-- per kind, and the kind is DECLARED.
--
-- Declared rather than derived, deliberately. The last time this collection
-- tried to derive a per-table property (which tables hold deployment data)
-- the derivation disagreed with a live install on nine of fifty-two, because
-- whose rows these are is a design decision rather than a property of the
-- text. So is this.
-- ------------------------------------------------------------
create table if not exists percolate.table_kinds (
    schema_name text not null,
    table_name  text not null,
    kind        text not null check (kind in ('entity','vocabulary','junction','log','natural')),
    why         text not null,
    primary key (schema_name, table_name)
);
comment on table percolate.table_kinds is
    'What each table IS — an entity, a vocabulary, a ledger — declared rather than guessed, with the reason.';

comment on table percolate.table_kinds is
    'What a table IS, which decides what its primary key must be. entity: a '
    'surrogate uuid id, because other rows reference it and its natural key '
    'may change. vocabulary: the term is the key, and referencing the value '
    'is the point. junction: a composite of foreign keys. log: append-only, '
    'a monotonic bigint. Declared, not derived -- the kind is a design '
    'decision and a text scan cannot see one.';

-- A PROPOSAL, to make declaring cheap rather than to replace it. Read it,
-- disagree with it, then write the row.
create or replace view percolate.table_kind_proposal as
with t as (
    select n.nspname as sch, c.relname as tbl, c.oid
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind in ('r','p')
      and n.nspname in (select percolate.extension_schemas())),
pk as (
    select t.sch, t.tbl, t.oid,
           -- ::text because array_agg over attname gives name[], and name[] has
           -- no equality operator against text[] -- the error names the operator
           -- rather than the column, which is a minute of confusion each time.
           array_agg(a.attname::text order by a.attnum) as cols,
           array_agg(format_type(a.atttypid, null) order by a.attnum) as types,
           bool_and(exists (select 1 from pg_constraint fk
                            where fk.conrelid = t.oid and fk.contype = 'f'
                              and a.attnum = any(fk.conkey))) as all_fk
    from t
    join pg_index x on x.indrelid = t.oid and x.indisprimary
    join pg_attribute a on a.attrelid = t.oid and a.attnum = any(x.indkey::int[])
    group by t.sch, t.tbl, t.oid)
select sch as schema_name, tbl as table_name, cols as pk_columns, types as pk_types,
       case
         when cols = array['id']::text[] and types = array['uuid']::text[] then 'entity'
         when cols = array['id']::text[] and types[1] like '%int%'  then 'log'
         when array_length(cols,1) > 1 and all_fk                   then 'junction'
         when types <@ array['text']::text[]                        then 'vocabulary'
         when array_length(cols,1) > 1                              then 'natural'
         -- NOT a fallthrough to 'entity'. The first version guessed 'entity'
         -- for anything it did not recognise and mis-proposed node_keys and
         -- schema_revisions, which a reviewer then accepted in bulk. A
         -- proposal that is confident about the cases it does not understand
         -- is worse than one that abstains.
         else null end as proposed_kind
from pk;
