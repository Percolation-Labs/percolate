-- Identity and nullability: the mechanism. See spec.md for the reasoning.
--
-- Two objects and nothing else. The policy is mostly a set of assertions
-- (checks.sql); what has to SHIP is the deterministic id function and the
-- registry that makes a NULL's meaning declarable.

-- This file is FIRST in the extension, so it creates the schema it lives in.
-- contract/schema.sql does the same, idempotently, for whichever of the two
-- someone reads first.
create schema if not exists percolate;

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
create or replace function percolate.uuidv5(p_namespace uuid, p_name text)
returns uuid language sql immutable strict parallel safe as $$
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
      and n.nspname in ('aiq','rbac','workflow','content','agentic','percolate')),
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
