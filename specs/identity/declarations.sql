-- Identity and nullability: the declarations.
--
-- SEPARATE FROM schema.sql, and the split is a dependency rather than taste.
-- The mechanism (percolate.uuidv5, the two registries) ships FIRST, because
-- shipped code in workflow-engine calls uuidv5 and a `language sql` body
-- resolves its references when it is created. The declarations are statements
-- ABOUT other modules' tables, so they can only be made once those tables
-- exist -- which is last.
--
-- The first version had both halves in one file at the front, and seeded
-- nothing: the proposal view it reads from was querying a catalogue in which
-- none of the 53 tables had been created yet. It reported 54 undeclared
-- tables and looked exactly like a policy nobody had applied.

-- ------------------------------------------------------------
-- 4. The declarations. Each one is a decision, so each carries its reason --
--    the sentence is the product, the same way a surface.sql row's `why` is.
-- ------------------------------------------------------------

-- org_id NULL is a VALUE: the shared tier, visible to every tenant. A publicly
-- listed company is legitimately global and duplicating it per tenant defeats
-- the point of one registry (integration-rbac.sql §1). Because it is a value,
-- a unique index over it MUST be `nulls not distinct` or it constrains
-- everything except the shared tier -- which is the one thing more than one
-- writer touches.
--
-- spec.md §4 argues this should stop being a NULL at all. Until it does, this
-- is the honest declaration of what it currently means.
insert into percolate.null_means (schema_name, table_name, column_name, means, why) values
 ('aiq','lake_nodes','org_id','value','the shared tier -- a lake row visible to every tenant'),
 ('aiq','node_keys','org_id','value','the shared tier -- a key resolvable by every tenant'),
 ('aiq','soft_nodes','org_id','value','the shared tier -- an unpromoted candidate visible to all'),
 ('content','channels','org_id','value','a shared source, e.g. a public feed every tenant reads'),
 ('content','datasets','org_id','value','a shared dataset; the same argument as channels'),

-- external_id NULL is an ABSENCE: no external identity was supplied. Several
-- rows may legitimately have none, so `nulls distinct` is correct here and
-- `nulls not distinct` would be the bug -- two unrelated resources that merely
-- both lack an upstream id are not the same resource.
--
-- The trap this leaves is in spec.md §6: register_fetched's idempotence is
-- `on conflict (channel_id, external_id)`, which never fires for a null. The
-- constraint is right and the FUNCTION should refuse the call.
 ('content','resources','external_id','absence','no upstream identity; many resources legitimately have none'),
 ('workflow','runs','external_id','absence','no idempotency key was supplied by the caller'),

-- Two partial indexes on agentic, both absences, and both worth a second look
-- by whoever owns that subsystem: a null here reads as "not configured yet"
-- rather than as a state, which is the definition of an absence, but the
-- indexes are partial and the interaction is subtle.
 ('agentic','agents','extracts_source','absence','an extractor with no source configured yet'),
 ('agentic','agents','extracts_doctype','absence','an extractor with no doctype configured yet'),
 ('agentic','messages','session_id','absence','a summary not attached to a session')
on conflict (schema_name, table_name, column_name) do update
  set means = excluded.means, why = excluded.why;

-- Table kinds, taken from the proposal after reading all 53. The proposal was
-- right everywhere; it is still written down rather than trusted, because the
-- kind is a design decision and the next table's proposal may not be.
insert into percolate.table_kinds (schema_name, table_name, kind, why)
select schema_name, table_name, proposed_kind,
       'reviewed against percolate.table_kind_proposal, 2026-09-06'
from percolate.table_kind_proposal
on conflict (schema_name, table_name) do nothing;

-- ------------------------------------------------------------
-- 5. ENFORCE THE KEY DEFAULT, on upgrades as well as fresh installs.
--
-- Writing `default uuidv7()` in the CREATE TABLE fixes a fresh install and
-- does NOTHING to a database that already exists: the generated upgrade is
-- idempotent DDL, and `create table if not exists` does not alter an existing
-- column's default. `dev/upgrade-converges.sh` caught it -- a fresh install
-- and an upgraded one disagreed on 25 column defaults, which is precisely the
-- class of defect that gate exists for and precisely the class the specs
-- alone cannot see.
--
-- So the fact is stated once, as a rule over the catalogue, rather than as 25
-- ALTER statements that a 26th table would silently not join. Runs on both
-- paths; a no-op on the one that was already right.
do $$
declare r record;
begin
    for r in
        select k.schema_name, k.table_name
        from percolate.table_kinds k
        join pg_class c on c.relname = k.table_name
        join pg_namespace n on n.oid = c.relnamespace and n.nspname = k.schema_name
        join pg_index x on x.indrelid = c.oid and x.indisprimary
        join pg_attribute a on a.attrelid = c.oid and a.attnum = any(x.indkey::int[])
                           and a.attname = 'id' and a.atttypid = 'uuid'::regtype
        join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
        where k.kind = 'entity'
          and pg_get_expr(d.adbin, d.adrelid) ~ 'gen_random_uuid|uuidv4'
    loop
        execute format('alter table %I.%I alter column id set default uuidv7()',
                       r.schema_name, r.table_name);
        raise notice 'identity: % .% id default moved to uuidv7()',
                     r.schema_name, r.table_name;
    end loop;
end $$;
