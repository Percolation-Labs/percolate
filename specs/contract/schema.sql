-- ============================================================
-- p8 -- THE CONTRACT. What this database admits, published by the database.
--
-- WHY THIS EXISTS, AND WHY IT IS IN THE EXTENSION.
--
-- `percolate-core` is a service INSTANCE. A deployment may run several, may
-- run none, may run somebody else's worker written in another language against
-- the same Postgres. So the moment a closed vocabulary or a payload shape is
-- defined in that package, the answer to "what may I write here?" lives in one
-- client of the database rather than in the database -- and every other client
-- has to either import that package or guess. That is the trap: it makes an
-- optional service load-bearing for knowledge that is not its to own.
--
-- The rule is `challenge-the-process` §9: a fact belongs at the lowest layer
-- that can refuse a violation of it, and the extension is what every client
-- shares. So the contract ships HERE, and a client -- pydantic model,
-- TypeScript union, another language's struct -- is COMPILED AGAINST it. A
-- client may still rederive it by hand for now; what it may not be is the
-- source.
--
-- TWO HALVES, AND THEY ARE DIFFERENT KINDS OF FACT.
--
--   percolate.enums()   DERIVED. Read out of the catalog at call time -- CHECK
--                constraints, foreign keys onto text vocabularies, and the
--                enums inside declared type schemas. Nothing is restated, so
--                nothing can fall behind: whatever the database actually
--                refuses is what this reports. The same discipline
--                workflow.compiler_capabilities() uses, and for the same
--                reason -- "derived, not declared".
--
--   percolate.types     DECLARED, because it cannot be derived. A jsonb column has
--                no shape in the catalog; `workflow.tasks.input` is `jsonb`
--                and that is all Postgres knows. So the shapes are authored as
--                JSON Schema in `specs/contract/types/*.yaml` and compiled into
--                the rows below by build-sql.py. Authored in YAML because a
--                human writes and reviews them; stored as jsonb because a
--                machine reads them.
--
-- WHAT THIS IS NOT. It is not a generic `enums(name, value)` table, and that
-- was considered and rejected. Such a table cannot be the target of a
-- single-column foreign key, so it could not enforce anything; and it holds
-- labels while losing meaning -- workflow.lifecycle_states carries is_terminal
-- and is_success, which purge_completed reads, and tradecraft.evidence_classes
-- carries derives_from, which the corroboration algorithm computes over. One
-- table per vocabulary, and a derived view ACROSS them. There is no registry of
-- vocabularies to keep up to date, because a registry is a list and a list runs
-- one way: it asks "does everything I listed exist?" and never notices the
-- constraint added last week.
-- ============================================================

-- NAMED `percolate`, AND EMPHATICALLY NOT `p8`, WHICH IS WHAT IT WAS FIRST.
--
-- The default search_path is `"$user", public`. `p8` is the owner role in every
-- connection string in this repository, so a schema called `p8` made `"$user"`
-- resolve for the first time -- and every unqualified CREATE by that role
-- silently stopped landing in `public`. It was found by a test that creates a
-- toy `widgets` table and then reads it as `authenticated`: the table was
-- created, granted, and then did not exist, because it had gone into this
-- schema and the reader's search_path does not include it.
--
-- Nothing errors when this happens. An operator doing `create table foo (...)`
-- as the owner gets a table in the contract namespace and no indication of it.
--
-- The rule, since the next person will want a short name too: a schema must not
-- be named after any role that creates objects. `percolate` is the extension's
-- own name and is not a role here; if a deployment ever creates a role called
-- `percolate`, this comment is the thing that was warned about.
create schema if not exists percolate;
comment on schema percolate is
    'The published contract: what this database admits. Derived where it can be '
    '(percolate.enums), declared where it cannot (percolate.types). Clients compile against '
    'this; no client owns it.';


-- ------------------------------------------------------------
-- 1. Declared payload shapes
-- ------------------------------------------------------------
create table if not exists percolate.types (
    name         text primary key,
    title        text not null,
    owner        text not null,          -- the subsystem whose spec defines it
    -- Where the shape is READ. The list of things that break if it changes,
    -- which before this table was answerable only by grep.
    consumed_by  text[] not null default '{}',
    -- JSON Schema. The same representation agentic.agents.structured_output_schema
    -- already uses, so a client that can read one can read the other.
    schema       jsonb not null,
    -- For a vocabulary the database admits but nothing in this collection can
    -- execute: {"basic": false, ...}. Kept separate from the schema's enum
    -- because "may be written" and "will actually run" are different facts, and
    -- collapsing them either narrows the contract to one runner's coverage or
    -- claims support that does not exist.
    implemented  jsonb,
    why          text,
    constraint schema_is_an_object check (jsonb_typeof(schema) = 'object')
);

comment on table percolate.types is
    'Payload shapes that cannot be derived from the catalog, because a jsonb '
    'column has no shape in it.';


-- ------------------------------------------------------------
-- 2. Every closed vocabulary this database enforces -- derived
--
-- A function rather than a view, because the reference half READS the rows of
-- whatever table each foreign key points at, and that needs dynamic SQL.
-- ------------------------------------------------------------
-- DROPPED FIRST, because `create or replace function` cannot change the return
-- type of an existing function and this one's return type is its output columns
-- -- so adding `members` below is a replace that fails with `cannot change
-- return type of existing function` on every database that already has the old
-- shape. That is the upgrade path, which is to say every database but a fresh
-- one. The grants at the foot of this file are what make the drop safe: they
-- run after the create, so the function comes back with them rather than
-- silently losing EXECUTE for web_anon. percolate.contract() does not pin this
-- function -- a `language sql` body given as a string creates no dependency --
-- so the drop does not cascade.
drop function if exists percolate.enums();

create or replace function percolate.enums()
returns table (
    schema_name  text,
    table_name   text,
    column_name  text,
    -- check     a CHECK constraint. Fixed at install; changing it is a migration.
    -- reference a foreign key onto a text key. The set is ROWS, so it may grow
    --           without a schema change -- which is the point of the pattern.
    -- type      an `enum` inside a declared percolate.types schema. Enforced by a
    --           trigger or by the reader, never by the catalog, which is
    --           exactly why it would otherwise be invisible here.
    enforced_by  text,
    vocabulary   text,
    -- WHOSE ROWS THESE ARE, and it is the difference between a contract and a
    -- census.
    --
    --   shipped     the extension itself puts these members there:
    --               workflow.lifecycle_states, rbac.visibilities,
    --               aiq.embedding_providers, aiq.schema_facets. The set moves
    --               only when a release moves it, so it is safe to freeze into
    --               extension/percolate/contract.json and compile against.
    --   deployment  the members are whatever THIS database created --
    --               rbac.roles, agentic.plugins. A fresh install ships none of
    --               them; dev/init/02-seed.sql adds `admin`; a deployment adds
    --               its own. Still a real closed set at any instant, so a live
    --               caller is told it, but freezing it publishes one
    --               deployment's data as everybody's contract.
    --   unreadable  the CALLER may not select the vocabulary's rows. Nothing is
    --               claimed about them.
    --
    -- This exists because `admits` alone could not say which of the three it
    -- was, and the collapse was not theoretical: contract.json was exported
    -- from a database dev/tests/rbac/01 had run against, so it published
    -- rbac.roles as admitting `member` -- a TEST FIXTURE -- and the CI gate was
    -- red on every push for three commits while the file agreed perfectly with
    -- the database in front of whoever generated it. `admits: null` meant
    -- `unreadable` and had no way to also mean "not ours to freeze".
    --
    -- DERIVED, not listed. `deployment` is read from pg_extension.extconfig --
    -- the array pg_extension_config_dump() writes -- so the fact lives in the
    -- catalog next to the table rather than in a roster here that a new
    -- vocabulary would have to be remembered into. It is also the SAME fact
    -- pg_dump already needs: a table registered there is one whose rows a dump
    -- must carry because the extension will not recreate them. A vocabulary
    -- whose rows are the deployment's and which is not registered is already a
    -- pg_dump bug; this makes it a contract bug too, which is the cheaper one
    -- to notice.
    members      text,
    -- `admits`, not `values`: VALUES is a reserved word in SQL and a column
    -- spelled that way has to be double-quoted at every use site forever. The
    -- same reasoning aiq.relation_types.is_symmetric records.
    admits       text[]
)
language plpgsql stable
set search_path = pg_catalog, public
as $fn$
declare
    r    record;
    vals text[];
begin
    -- (a) CHECK constraints of the form `col = ANY (ARRAY[...])`. Postgres
    -- normalises `col in ('a','b')` to exactly this, so both spellings arrive
    -- here identically and neither has to be parsed out of the source text.
    for r in
        select n.nspname as sch, t.relname as tbl, a.attname as col,
               pg_get_constraintdef(c.oid) as def
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
        join pg_attribute a on a.attrelid = t.oid and a.attnum = c.conkey[1]
        where c.contype = 'c'
          and array_length(c.conkey, 1) = 1
          and pg_get_constraintdef(c.oid) ~ '= ANY \(ARRAY\['
          and n.nspname not in ('pg_catalog', 'information_schema')
        order by 1, 2, 3
    loop
        select array_agg(m[1] order by ord) into vals
          from regexp_matches(r.def, '''([^'']*)''::text', 'g')
               with ordinality as x(m, ord);
        if array_length(vals, 1) >= 2 then
            schema_name := r.sch; table_name := r.tbl; column_name := r.col;
            enforced_by := 'check'; vocabulary := null; admits := vals;
            -- A CHECK is in the schema, so its members ship with the schema.
            members := 'shipped';
            return next;
        end if;
    end loop;

    -- (b) Single-column foreign keys onto a text key. The admissible set is
    -- rows rather than a constraint body, so it is READ rather than parsed.
    --
    -- Data references (agents.plugin -> plugins.name) come back alongside
    -- shipped vocabularies (runs.status -> lifecycle_states.state) and are NOT
    -- filtered out, because no honest test separates them: both are closed at
    -- any instant, and both answer a real question a caller has. `enforced_by`
    -- carries the difference instead, so a client that wants only the frozen
    -- vocabulary filters on it rather than trusting a list somebody maintained.
    --
    -- A column may appear under BOTH 'check' and 'reference', and that is
    -- information rather than duplication: workflow.tasks.status is CHECKed to
    -- the subset a task can reach and REFERENCES the vocabulary shared with
    -- every other status column.
    for r in
        select n.nspname as sch, t.relname as tbl, a.attname as col,
               fn.nspname as fsch, ft.relname as ftbl, fa.attname as fcol,
               -- Whether THIS caller may read the vocabulary's rows. Checked
               -- rather than assumed: see the NULL/{} distinction below.
               pg_catalog.has_table_privilege(ft.oid, 'select') as may_read,
               -- ...and whether they are the extension's rows or this
               -- deployment's. See `members` in the signature above.
               exists (select 1 from pg_catalog.pg_extension x
                        where ft.oid = any (x.extconfig)) as is_deployment_data
        from pg_constraint c
        join pg_class t on t.oid = c.conrelid
        join pg_namespace n on n.oid = t.relnamespace
        join pg_attribute a on a.attrelid = t.oid and a.attnum = c.conkey[1]
        join pg_class ft on ft.oid = c.confrelid
        join pg_namespace fn on fn.oid = ft.relnamespace
        join pg_attribute fa on fa.attrelid = ft.oid and fa.attnum = c.confkey[1]
        where c.contype = 'f'
          and array_length(c.conkey, 1) = 1
          and fa.atttypid = 'text'::regtype
          and n.nspname not in ('pg_catalog', 'information_schema')
        order by 1, 2, 3
    loop
        -- THE POINTER IS PUBLIC; THE CONTENTS ARE NOT, and that distinction is
        -- the reason this function is SECURITY INVOKER.
        --
        -- The obvious spelling -- read every referenced table and publish the
        -- rows -- made percolate.contract() raise `permission denied for table
        -- plugins` for web_anon, which is the one role that most needs to read
        -- a contract: an unauthenticated client discovering what it would have
        -- to send. Measured on a from-zero install, not reasoned about.
        --
        -- The fix is NOT to make this SECURITY DEFINER. A reference vocabulary
        -- is a real table, and reading its rows on behalf of a caller who
        -- cannot read them would turn a contract-publishing function into a
        -- read-anything side channel the moment somebody adds a foreign key
        -- onto a text column of something sensitive. The shape of the door is
        -- public; what is behind it is not.
        --
        -- So a caller always learns that the column is constrained and WHICH
        -- vocabulary constrains it, and learns the members only if it could
        -- have selected them itself. NULL and '{}' are deliberately different
        -- answers: NULL is "you may not see these", '{}' is "there are none".
        if r.may_read then
            execute format('select array_agg(%I::text order by %I::text) from %I.%I',
                           r.fcol, r.fcol, r.fsch, r.ftbl)
               into vals;
            admits  := coalesce(vals, '{}'::text[]);
            -- The rows are reported EITHER WAY, including for a deployment
            -- vocabulary, and that is deliberate: a caller holding a connection
            -- asked what it may write into this column right now, and the rows
            -- are that answer. What must not happen is freezing them into the
            -- tracked artifact, and `members` is how contract-export.py knows
            -- not to.
            members := case when r.is_deployment_data then 'deployment'
                            else 'shipped' end;
        else
            admits  := null;
            members := 'unreadable';
        end if;
        schema_name := r.sch; table_name := r.tbl; column_name := r.col;
        enforced_by := 'reference';
        vocabulary  := r.fsch || '.' || r.ftbl;
        return next;
    end loop;

    -- (c) Enums inside declared type schemas. content.connectors' auth and
    -- paging taxonomies ARE enforced -- connectors_validate() refuses an
    -- unknown type at the write -- but they are enforced inside a trigger BODY,
    -- which no catalog reader can see. Without this branch the published
    -- contract would omit two closed vocabularies that the database genuinely
    -- refuses, which is the worst kind of gap: silent, and on the permissive
    -- side.
    for r in
        select t.name,
               split_part(t.name, '.', 1) as sch,
               k.key   as prop,
               k.value as spec
        from percolate.types t,
             lateral jsonb_each(coalesce(t.schema->'properties', '{}'::jsonb)) k
        where k.value ? 'enum'
        order by 1, 3
    loop
        select array_agg(value order by value) into vals
          from jsonb_array_elements_text(r.spec->'enum');
        if array_length(vals, 1) >= 2 then
            schema_name := r.sch; table_name := r.name; column_name := r.prop;
            enforced_by := 'type'; vocabulary := r.name; admits := vals;
            -- Authored in specs/contract/types/*.yaml and compiled in, so these
            -- move with a release exactly like a CHECK does.
            members := 'shipped';
            return next;
        end if;
    end loop;
end;
$fn$;

comment on function percolate.enums() is
    'Every closed vocabulary this database enforces, read from the catalog at '
    'call time. Nothing here is restated, so nothing here can fall behind.';


-- ------------------------------------------------------------
-- 3. The whole contract, as one document
--
-- What a client actually fetches. One call rather than two, because a client
-- assembling a contract from two round trips can assemble half of one.
-- ------------------------------------------------------------
create or replace function percolate.contract()
returns jsonb
language sql stable
set search_path = pg_catalog, public
as $$
    select jsonb_build_object(
        'extension', (select extversion from pg_extension where extname = 'percolate'),
        'generated_at', now(),
        'enums', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'schema', schema_name, 'table', table_name,
                       'column', column_name, 'enforced_by', enforced_by,
                       'vocabulary', vocabulary, 'members', members,
                       'admits', admits)
                   order by schema_name, table_name, column_name, enforced_by)
            from percolate.enums()), '[]'::jsonb),
        'types', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'name', name, 'title', title, 'owner', owner,
                       'consumed_by', consumed_by, 'schema', schema,
                       'implemented', implemented)
                   order by name)
            from percolate.types), '[]'::jsonb));
$$;

comment on function percolate.contract() is
    'The published contract as one document: what this database admits. Clients '
    'compile against this rather than restating it.';


-- ------------------------------------------------------------
-- 4. WHOSE ROWS SURVIVE A BACKUP
--
-- `pg_dump` DOES NOT DUMP THE DATA OF AN EXTENSION'S TABLES. It dumps `CREATE
-- EXTENSION percolate` and stops, on the reasoning that an extension recreates
-- its own contents -- which is right for a vocabulary and catastrophic for a
-- table holding somebody's users. The escape hatch is
-- pg_extension_config_dump(), which marks a table whose CONTENTS are user data
-- so that pg_dump carries the rows.
--
-- MEASURED, on a database this repository builds, before any of these lines
-- existed. 52 tables belong to the extension; two were registered; `pg_dump`
-- emitted 14 COPY blocks, of which the only extension members were those two.
-- The database held 2 users, 5 workflow definitions, 2 agents, 21 graph nodes
-- and 5 content resources. The dump held none of them:
--
--     COPY rbac.users            0
--     COPY workflow.definitions  0
--     COPY agentic.agents        0
--     COPY aiq.nodes             0
--     COPY content.resources     0
--
-- So every backup taken of every database this collection has ever produced
-- contained the schema and nothing else, and a restore would have come up
-- empty and working. `specs/trace-field/brief.md` says supervision state
-- "survives a `pg_dump`"; it did not.
--
-- LISTED, NOT DERIVED, AND THE ATTEMPT TO DERIVE IT IS WHY. The obvious rule --
-- a table the install script never INSERTs into holds deployment data -- was
-- written and measured against a bare install, and disagreed on nine tables.
-- Seven have rows and no top-level insert, because they are seeded by function
-- calls and DO blocks the scan cannot see (aiq.graph_vocabulary,
-- aiq.entity_registry, workflow.step_functions...). Two have a top-level insert
-- and no rows, because the insert is a SELECT that matches nothing at install
-- (rbac.role_permissions, workflow.rate_limits). Whose rows these are is a
-- design decision per table, not a property of the text, and a derivation that
-- is wrong about nine of fifty-two would have registered vocabularies whose
-- shipped rows then collide on restore.
--
-- What IS derived is the check: `dev/check.sh` builds a bare install and
-- asserts that every extension table which is EMPTY there appears below. That
-- catches the fifty-third table on the day it is added, which is the only
-- moment anybody could reasonably be expected to notice.
--
-- FIXED, AND THE COUNT WAS WRONG. Read what follows as the account of a
-- defect that is closed, not an outstanding one -- the mechanism is at the
-- bottom of this comment and in `seeded_tables` below. There were EIGHT, not
-- seven: rbac.orgs is the same shape and was not on this list, and it was
-- found by dev/restore-is-possible.sh refusing a duplicate key on the run
-- that proved the other seven fixed, not by anybody re-reading this. Losing
-- that table's COPY loses every tenant in the backup.
--
-- Eight tables hold shipped rows
-- AND take deployment rows: workflow.definitions (ships `ingest_file`),
-- aiq.entity_registry (3 shipped, 6 after seeding), content.channels (2 and 3),
-- aiq.graph_vocabulary, aiq.lexical_sources, aiq.semantic_sources,
-- aiq.schema_examples. Registering one of those with an empty condition makes
-- `CREATE EXTENSION` insert the shipped rows and the restore COPY them again,
-- so the restore dies on a duplicate key. Each needs a WHERE excluding its own
-- shipped rows, and that is not done here.
--
-- IT IS WORSE THAN "those seven lose their deployment rows", which is what this
-- comment said until the round trip was actually run. Those tables are
-- REFERENCED by tables in the list above, so their missing rows take registered
-- data down with them. Restoring the dump of a seeded database into a fresh
-- install, measured:
--
--     ERROR: insert or update on "resources" violates foreign key
--            "resources_channel_id_fkey"
--     ERROR: relation (company, competes_with, company) is not in the catalogue
--
-- content.resources references content.channels, and the deployment's third
-- channel was not dumped; aiq.edges names a relation the deployment added to
-- the vocabulary. So `resources`, `resource_chunks` and `edges` restored EMPTY
-- despite being registered here -- 5, 6 and 15 rows lost to two absent parents.
--
-- THE FIX, AND THE PART OF IT THIS PARAGRAPH USED TO GET WRONG. It said: a
-- `shipped boolean not null default false` on each, "set true by the statement
-- that seeds them". Half of that is right. The column and the `WHERE NOT
-- shipped` registration are what shipped.
--
-- But FIVE OF THE EIGHT HAVE NO SEEDING STATEMENT. Their rows arrive through
-- aiq.register_entity_table, aiq.register_lexical_source,
-- workflow.define_yaml and two more -- the same functions a DEPLOYMENT calls
-- to register its own. Seeding and user registration are one code path, so
-- there is nothing to put a literal `true` on: doing it inside the function
-- marks the user's rows too, which is silent data loss from every future
-- backup and strictly worse than the duplicate key it replaces.
--
-- What distinguishes them is not the call site, it is WHO IS CALLING. The
-- generated script sets `percolate.seeding` for its own length (see the
-- HEADER in build-sql.py, and the reset in identity/closing.sql); each
-- table's `shipped` defaults to reading it; every one of the ~14 insert sites
-- is untouched. On an upgrade the script replays, the seeds hit their
-- `on conflict do update set shipped = excluded.shipped or <t>.shipped`, and
-- an existing database marks itself. Still derived, still no key list.
--
-- WHAT THE CHANGE WAS WORTH, in three states rather than two. Before any of
-- it: a backup held the schema and nothing else, and a restore came up empty
-- and working. After registering the tables: a backup held almost everything
-- and the restore failed loudly, naming the parents it could not find --
-- broken, but it told you. After the `shipped` column: measured on a live
-- 0.2.0, 26 registered tables, no duplicate keys, and a dump that carries the
-- deployment's orgs and not the shared one, its channels and not `uploads`.
--
-- The middle state was worth passing through, and that is the part worth
-- keeping: the loud failure is what dev/restore-is-possible.sh caught, and
-- catching it is what found the eighth table.
-- ------------------------------------------------------------
do $$
declare
    t text;
    -- THE SEVEN THAT HOLD BOTH KINDS OF ROW, and the reason this loop no
    -- longer passes '' to everything. Each ships rows from the install script
    -- AND takes rows from a deployment; an empty condition dumps both, the
    -- restore's CREATE EXTENSION re-seeds the shipped ones, and the COPY dies
    -- on a duplicate key with the whole restore -- the deployment's own rows
    -- included -- rolled back with it. Measured: 4 channels dumped, 2
    -- re-seeded, 0 restored.
    --
    -- The condition is on a COLUMN rather than a list of keys, so this array
    -- is the only place the seven are named and adding an eighth seed to any
    -- of them changes nothing here. See each table's `shipped` column and the
    -- generated script's `percolate.seeding` flag for how a row gets marked.
    seeded_tables text[] := array[
        'rbac.plan_limits',  -- research-platform: the default plan's limit is shipped, the rest the deployment's
        'aiq.entity_registry',
        'aiq.graph_vocabulary',
        'aiq.lexical_sources',
        'aiq.schema_examples',
        'aiq.semantic_sources',
        'content.channels',
        -- THE EIGHTH, and it is here because a gate found it rather than
        -- because this list was re-derived. The install seeds the shared org;
        -- every other row is a tenant. Losing this table's COPY loses all of
        -- them. See rbac.orgs' own `shipped` column for the measurement.
        'rbac.orgs',
        'workflow.definitions'
    ];
    -- Every table whose rows are the DEPLOYMENT's rather than the extension's,
    -- verified empty on a from-zero install -- plus the seven above, which are
    -- not empty there and are registered with a condition instead.
    deployment_tables text[] := array[
        'rbac.plan_limits',  -- research-platform: the default plan's limit is shipped, the rest the deployment's
        -- The research platform (research-platform/schema.sql): every row is the
        -- deployment's -- grants, plan assignments, usage, research and engagement.
        'engagement.comment_likes', 'engagement.comment_versions', 'engagement.comments',
        'engagement.follows', 'engagement.saves', 'engagement.valuations', 'engagement.votes',
        'rbac.applications', 'rbac.grants', 'rbac.plan_assignments', 'rbac.usage_ledger',
        'research.argument_edges', 'research.citations', 'research.claims', 'research.endorsements',
        'research.exposures', 'research.heads', 'research.operations', 'research.revisions', 'research.sources', 'research.works',
        'agentic.agents',
        'agentic.messages',
        'agentic.plugins',
        'agentic.runs',
        'agentic.sessions',
        'agentic.skills',
        'agentic.tool_servers',
        'aiq.db_objects',
        'aiq.edges',
        -- Which of an edge's retractions were later undone, so an as-of read
        -- knows the periods nobody believed it. Deployment data by the same
        -- argument as aiq.edges itself, and losing it in a restore does not
        -- lose an edge: it silently makes every past as-of answer about that
        -- edge wrong, in the confident direction.
        'aiq.edge_retractions',
        'aiq.entity_registry',
        'aiq.embedding_models',
        'aiq.graph_vocabulary',
        'aiq.lexical_sources',
        'aiq.lake_nodes',
        'aiq.node_keys',
        'aiq.node_resolutions',
        'aiq.nodes',
        'aiq.schema_revisions',
        'aiq.schema_examples',
        'aiq.semantic_sources',
        'aiq.soft_nodes',
        'content.dataset_files',
        'content.datasets',
        'content.files',
        'content.resource_chunks',
        'content.resources',
        -- The API-pull pair. Both hold a deployment's own rows: source_state is
        -- where a pull resumes from, and losing it silently re-pulls a source
        -- from the beginning after a restore; source_records is what came back.
        -- Neither is a vocabulary the extension can recreate.
        'content.source_records',
        'content.source_state',
        -- THE CHANNEL ITS RESOURCES POINT AT. Every other table in this schema
        -- was here and this one was not, so pg_dump carried every
        -- content.resources row and none of the channels they reference --
        -- measured: 6 channels in the database, 0 COPY lines, resources
        -- dumped. A restore either fails on channel_id or comes back without
        -- the sources somebody configured.
        --
        -- It has extension-seeded rows too (`uploads`, `workflow_artifacts`),
        -- which is exactly why it was missed: the gate's rule was "empty on a
        -- from-zero install and unregistered", and a table holding BOTH the
        -- extension's rows and the deployment's is never empty. Registering it
        -- is right anyway -- pg_extension_config_dump carries the rows that
        -- are there, and the two seeded ones are recreated by the install with
        -- `on conflict do nothing`, so they do not double.
        'content.channels',
        'public.percolate_build',
        'rbac.api_keys',
        'rbac.auth_events',
        'rbac.org_members',
        'rbac.orgs',
        'rbac.password_reset_tokens',
        'rbac.refresh_tokens',
        'rbac.role_permissions',
        'rbac.roles',
        'rbac.user_roles',
        'rbac.users',
        -- THE SAME DEFECT, AND THE WORSE HALF OF IT. workflow.runs below IS
        -- registered and carries a foreign key to workflow.definitions, which
        -- was not -- so a dump held every run and none of the definitions they
        -- name. Every workflow anybody authored with define_yaml was absent
        -- from every backup. Found by the sibling sweep this file's own header
        -- asks for, not by anybody noticing a restore.
        'workflow.definitions',
        'workflow.queue_config',
        'workflow.rate_limits',
        'workflow.runs',
        'workflow.schedules',
        'workflow.task_dependencies',
        'workflow.task_events',
        'workflow.tasks'
    ];
begin
    foreach t in array deployment_tables loop
        -- Guarded on extension membership: pg_extension_config_dump() raises
        -- outside CREATE EXTENSION / ALTER EXTENSION UPDATE. The guard was
        -- written for dev/upgrade-converges.sh, which loaded the script raw;
        -- it and dev/currency.sh install through CREATE EXTENSION now, so that
        -- percolate.extension_schemas() has membership to read, and a raw load
        -- is refused at the end by identity/closing.sql if it gets that far.
        -- The guard costs nothing on the real path: the 'e' dependency is
        -- recorded as each object is created, so by this point the table
        -- already belongs to the extension being installed.
        if exists (select 1 from pg_catalog.pg_depend d
                    where d.classid = 'pg_class'::regclass
                      and d.objid = t::regclass
                      and d.deptype = 'e') then
            perform pg_catalog.pg_extension_config_dump(
                t, case when t = any(seeded_tables) then 'WHERE NOT shipped'
                        else '' end);
        end if;
    end loop;
end $$;


-- Readable by anyone who can connect. A contract nobody may read is not a
-- contract -- and there is nothing sensitive in it: it is the shape of the
-- door, not what is behind it. Granted to web_anon too, so an unauthenticated
-- client can discover what it would have to send before it has credentials.
grant usage on schema percolate to web_anon, authenticated, api_viewer;
grant select on percolate.types to web_anon, authenticated, api_viewer;
grant execute on function percolate.enums() to web_anon, authenticated, api_viewer;
grant execute on function percolate.contract() to web_anon, authenticated, api_viewer;
-- The three roles above are the audience. A database installed before 0.2.0
-- also gave these to PUBLIC by default; this makes the two agree.
revoke execute on function percolate.enums() from public;
revoke execute on function percolate.contract() from public;
