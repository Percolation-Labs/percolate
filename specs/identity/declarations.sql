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

-- THE FIVE org_id DECLARATIONS ARE GONE, AND THEIR ABSENCE IS THE POINT.
--
-- They read `org_id NULL is a VALUE: the shared tier, visible to every
-- tenant`, and spec.md §4 called that an honest declaration of a dishonest
-- column: a value wearing an absence's clothes, which forced five unique
-- indexes to be NULLS NOT DISTINCT and caused all three of the duplicate bugs
-- §1 lists.
--
-- The column is NOT NULL now. The shared tier is rbac.shared_org_id(), a row
-- in rbac.orgs with a derived, deployment-independent uuid, and org_id cannot
-- be NULL on any of the sixteen tables that carry it. So there is no NULL left
-- to declare a meaning for, and a row here saying otherwise would be a
-- statement about the schema that the schema contradicts -- which is the
-- failure mode this whole registry exists to prevent, arriving inside the
-- registry.
--
-- DELETED RATHER THAN OMITTED. Dropping the five rows from the INSERT below
-- fixes a fresh install and does nothing to a database that already ran the
-- old version: this file is replayed on upgrade and an absent row is not a
-- retracted one. identity/spec.md §7's fourth lesson, applied to data instead
-- of to a default. A no-op on the fresh path.
delete from percolate.null_means where column_name = 'org_id';

-- external_id NULL is an ABSENCE: no external identity was supplied. Several
-- rows may legitimately have none, so `nulls distinct` is correct here and
-- `nulls not distinct` would be the bug -- two unrelated resources that merely
-- both lack an upstream id are not the same resource.
--
-- The trap this leaves is in spec.md §6: register_fetched's idempotence is
-- `on conflict (channel_id, external_id)`, which never fires for a null. The
-- constraint is right and the FUNCTION should refuse the call.
insert into percolate.null_means (schema_name, table_name, column_name, means, why) values
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
-- The proposal ABSTAINS on a shape it does not recognise, on purpose: the
-- view's own comment argues that a proposal confident about what it does not
-- understand is worse than one that says nothing. This statement then read
-- every row of it, so the first table nobody had classified -- content.
-- source_state, whose key is a single uuid FK to content.channels -- arrived
-- as a null `kind` and took the whole extension install down with a NOT NULL
-- violation. A fresh install of 0.2.0 failed outright.
--
-- Skipping the abstentions is the fix rather than defaulting them, and it
-- restores what the paragraph above claims: an unclassified table stays
-- UNDECLARED, and specs/identity/checks.sql already lists undeclared tables
-- for whoever owns them. A guess written here would be indistinguishable
-- from a decision, which is the failure the view was built to avoid.
where proposed_kind is not null
-- `do update` for the reason percolate.null_means twenty lines above already
-- does it (REM-68): the schema is replayed on every upgrade, so `do nothing`
-- means a re-reviewed kind reaches fresh installs only and every existing
-- database keeps the old one forever, invisibly -- dev/upgrade-converges.sh
-- compares objects, not rows. percolate.table_kinds is not on
-- specs/contract/schema.sql §4's `deployment_tables`, so these rows are the
-- extension's to correct.
--
-- Safe on a table whose rows have more than one author because the SELECT is
-- already scoped: percolate.table_kind_proposal reads only
-- percolate.extension_schemas(), so an application's own declaration is not a
-- row this statement can name.
on conflict (schema_name, table_name) do update
    set kind = excluded.kind, why = excluded.why;

-- The abstentions, declared one at a time, which is what the view asks for:
-- "Read it, disagree with it, then write the row."
--
-- content.source_state is a sidecar: one row per content.channels row, keyed
-- by that parent's id rather than by a surrogate of its own. `natural` is the
-- kind already carried by the three tables of that exact shape --
-- aiq.emb_text_embedding_3_small and the two emb_demo_quad tables -- whose key
-- is likewise the parent's id and not an `id` column. It is not `entity`: no
-- row references it, and its key cannot change because it is not its own.
insert into percolate.table_kinds (schema_name, table_name, kind, why) values
 ('content','source_state','natural',
  'a sidecar keyed by content.channels(id); same shape as the aiq.emb_* tables'),
 ('research','heads','natural',
  'a sidecar keyed by research.works(id): which revision is current for each work'),
 ('research','exposures','natural',
  'a sidecar keyed by research.revisions(id): which exact revisions anybody who may read the work may read'),
 ('research','endorsement_withdrawals','natural',
  'a sidecar keyed by research.endorsements(id): the one withdrawal event of an endorsement (REM-154)'),
 ('rbac','plan_assignments','natural',
  'a sidecar keyed by rbac.users(id): the plan one account is on')
-- `do update`, same reason as the statement above, and here it names one row.
on conflict (schema_name, table_name) do update
    set kind = excluded.kind, why = excluded.why;

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
