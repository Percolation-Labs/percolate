-- ============================================================
-- SURFACE AUDIT
--
-- Declares the surface area the specs promise, then checks the database
-- actually provides it. Run after install.sh against any deployment.
--
--     psql "$DSN" -f surface.sql
--
-- This exists because the gaps in this collection have all been found the hard
-- way: a document telling readers to register `wm.resource_chunks`, a table
-- nobody shipped; `aiq.query()` needing an extension the installer did not
-- install; `workflow.p8ql()` making the engine depend on the query layer and
-- breaking a clean install. Every one of those was a promise made in prose
-- with nothing checking it.
--
-- The rule this encodes: a capability named in a spec is a row in the
-- expectations list below. If the spec says it, this file asserts it, and a
-- missing piece fails here rather than in someone's first hour.
--
-- ------------------------------------------------------------
-- TWO THINGS THIS FILE DOES NOT COVER, stated here so its final
-- "SURFACE COMPLETE" is not read as more than it means.
--
-- 1. SERVICE ROUTES. Every check below is a Postgres catalog lookup. The
--    database halves of the service contracts are covered -- register_upload,
--    resolve_file, claim_task, complete_task -- but no HTTP surface is:
--    not POST /files, not GET /files/{id}, not /health, not POST /chat,
--    not /internal/run, not the MCP transport. Those live in
--    percolate-core, which is a dependency consumed at a contract, and the
--    contract is currently kept honest by prose rather than by this file.
--    An audit run reported clean while `POST /files` claimed a scraper that
--    did not exist; that is the gap, precisely.
--
-- 2. WAS: "the agentic subsystem has no block below". It has one now, and
--    this note is kept rather than deleted because the debt only half
--    closed. The tables, functions and the sample binding are checked; the
--    turn itself is not, and cannot be from here -- an agent run is an LLM
--    call and a tool call, and neither is a catalog lookup. `docker compose
--    up` producing a registered agent is asserted below; that agent
--    answering anything is asserted nowhere in this repository.
--
-- 3. REACHABILITY. Every check below asks whether an object EXISTS. None asks
--    whether the role running the audit -- or any role -- may execute it, and
--    the two are different facts wherever a surface ships granted to nobody.
--    The graph algorithms do exactly that, deliberately: on a stock install
--    all nine entry points are present, this file reports SURFACE COMPLETE,
--    and `select * from aiq.graph_components(2, 30000)` as `authenticated` is
--    `permission denied for function graph_components` until somebody runs
--    `aiq.enable_graph_algorithms('authenticated')`.
--
--    `aiq.extension_boundary()` now answers the reachability question for the
--    compiled crossings and folds it into its own `ok`, so the instrument
--    exists; this file has not yet grown the equivalent column, and a consumer
--    reading a clean run here should not conclude their role can call what it
--    lists.
--
-- All three are debts, not decisions. `meta/skills/spec-driven-development`
-- says the audit should exist before the thing it describes.
-- ============================================================

\set ON_ERROR_STOP on
\pset pager off

-- ------------------------------------------------------------
-- EVERY FAILURE IN ONE RUN, not the first one.
--
-- This file had four `raise exception` sites and each aborted the script, so a
-- database with four surface defects reported one. `dev/tests/run.sh` decided
-- the opposite for itself and says so in its own header -- it carries `failed`
-- to the end "because one broken guarantee usually breaks several, and a run
-- that stops at the first tells you how many surfaces are red only after you
-- have fixed one and run it again" -- and names THIS FILE as its complement in
-- the next line. One rule, two homes, applied in one.
--
-- WHAT IT COST, measured rather than argued. `ff36b70` landed four defects and
-- they were found over three fix-and-re-run cycles, each invisible until the
-- one before it was fixed: an ownership transfer outside its grant window
-- aborted the install, which hid two columns outside the read contract, which
-- hid an undeclared reachable view. Two separate sessions were sent on that
-- chase four hours apart. Stopping after the first fix would have shipped
-- three of the four.
--
-- THE RULE, stated as a property rather than as this file's behaviour, because
-- that is why it did not travel the first time: *a gate that runs several
-- internal checks reports all of them, not the first*. It cannot be enforced
-- from outside -- `dev/check.sh` already runs every gate regardless of
-- failures, and a bash runner cannot see inside a psql script -- so each gate
-- has to carry it. dev/tests/README.md says so where a new gate's author will
-- meet it.
create temporary table surface_failures (
    seq     serial,
    check_name text not null,
    detail  text not null
);

create temporary table expected (
    subsystem text,
    -- Every value here has a branch in the CASE that computes `present`, and
    -- that CASE ends in `else false`. So a typo'd kind does not fail loudly --
    -- it reports the object as MISSING, and sends somebody looking for a
    -- schema object that is in fact present. The constraint moves that to the
    -- INSERT, where the row names itself.
    --
    -- Kept in step with the CASE by hand, which is the one place in this file
    -- that is true, and it is acceptable only because both are in this file,
    -- forty lines apart: adding a branch without adding the word here fails the
    -- next run that uses it.
    kind      text check (kind in (
                  'schema', 'table', 'view', 'column', 'function', 'extension',
                  'yaml_feature', 'registration', 'agent', 'skill',
                  'skill_binding', 'tool_server', 'entity_type',
                  'graph_example', 'property_graph', 'corpus',
                  'embedding_space', 'channel')),
    name      text,
    detail    text,
    why       text      -- the spec sentence this row exists to keep honest
);

insert into expected (subsystem, kind, name, detail, why) values

-- ---------- extensions -------------------------------------------------
('install','extension','pgcrypto',null,'INSTALL.md: required'),
('install','extension','pg_trgm',null,'INSTALL.md: required, FUZZY over node_keys'),
('install','extension','vector',null,'INSTALL.md: required, embeddings + HNSW'),
('install','extension','percolate_parser',null,'the C parsers: superuser-installed, no tables'),
('install','extension','percolate',null,'the schema, installed by app_owner so RLS is real'),

-- ---------- user-rbac --------------------------------------------------
('user-rbac','schema','rbac',null,'spec.md: identity lives in Postgres'),
-- ---------- identity and nullability -----------------------------------
('identity','schema','percolate',null,
 'spec.md: the cross-cutting namespace -- also created by contract/schema.sql, idempotently'),
('identity','function','percolate.uuidv5','uuid,text',
 'spec.md §3: a deterministic id, so a derived row has the same id every time. RFC 4122 v5, verified against the published vector for DNS/python.org'),
('identity','function','percolate.id_namespace','text',
 'spec.md §3: the namespace for a kind of derived id, itself a v5 under the RFC DNS namespace so it is reproducible rather than a magic constant'),
('identity','function','percolate.extension_schemas','',
 'schema.sql §0: every schema the extension owns, read from pg_depend -- what each gate reads instead of a typed list of schema names. Everybody''s: it reads nothing a caller could not read from pg_depend directly'),
('identity','table','percolate.null_means',null,
 'spec.md §4: whether a nullable column''s NULL is a VALUE or an ABSENCE. A unique index over an absence is correctly NULLS DISTINCT and over a value is not, and nothing else in the schema distinguishes them'),
('identity','table','percolate.table_kinds',null,
 'spec.md §7: what a table IS -- entity, vocabulary, junction, log, natural -- which decides what its primary key must be'),
('identity','view','percolate.table_kind_proposal',null,
 'spec.md §7: a proposal to make declaring cheap, which abstains rather than guessing on shapes it does not recognise'),

('user-rbac','table','rbac.users',null,'spec.md §1'),

-- DECLARED BECAUSE A CALLER CAN READ THEM, which the widened `reachable` view
-- above now asks about. Each line is the sentence surface.sql exists to force:
-- an exposed surface nobody can justify in a sentence is one that should not
-- be granted.
('user-rbac','table','rbac.roles',null,
 'spec.md §2: the role vocabulary is readable by a caller so a client can render what a role means; it holds no user data and has no RLS because there is nothing to scope'),
('user-rbac','table','rbac.role_permissions',null,
 'spec.md §2: the (role, resource, action) vocabulary, readable for the same reason as rbac.roles -- a client showing why an action is refused needs it'),
('user-rbac','table','rbac.user_roles',null,
 'spec.md §2: WHO holds a role, readable but RLS-scoped by user_roles_self_or_admin -- a caller sees their own assignments and an admin sees all; verified as returning zero rows to a stranger'),
('ai-query-layer','table','aiq.graph_vocabulary',null,
 'graph-index.md §5.3: the closed relation vocabulary, readable because SCHEMA mode publishes it deliberately -- an agent has to know which relations exist before it can walk one'),
('ai-query-layer','view','aiq.graph_accepted_relations',null,
 'graph-index.md §5.3: every spelling upsert_graph accepts, inverse labels included -- graph_vocabulary alone under-reports it, and a consumer pre-filtering on the narrower set drops the edges the flip exists to recover'),
('ai-query-layer','table','aiq.lexical_sources',null,
 'USAGE.md: the registered TEXT sources, readable so a caller can discover what FROM accepts rather than guessing'),
('ai-query-layer','table','aiq.semantic_sources',null,
 'USAGE.md: the registered SEMANTIC sources and their model, readable for the same reason -- and it is the pairing that makes a model mismatch refusable'),
('user-rbac','table','rbac.api_keys',null,'spec.md §4: agents authenticate without a password'),
('user-rbac','table','rbac.refresh_tokens',null,'spec.md §3: revocable credential'),
('user-rbac','table','rbac.auth_events',null,'spec.md §6: append-only audit'),
-- The closed permission vocabulary. Declared because role_permissions now
-- references it: without this table the grant path does not exist at all,
-- and its absence used to be expressible only as permissions that matched
-- nothing.
('user-rbac','table','rbac.permission_kinds',null,'schema §6: every (resource, action) the collection checks'),
('user-rbac','function','rbac.login','text,text,text,text','spec.md §4.2: atomic login'),
('user-rbac','function','rbac.create_user_with_password','text,text','spec.md §4.1: signup'),
('user-rbac','function','rbac.current_user_id','','spec.md §2: every RLS policy calls this'),
('user-rbac','function','rbac.has_permission','uuid,text,text','spec.md §2: one authz function'),
-- The first administrator. Audited because it is a promise the install
-- guide makes to a stranger -- and because the failure it replaced was
-- silent: a hand-copied grant list whose wrong verbs left every policy
-- returning false while the role looked populated.
('user-rbac','function','rbac.bootstrap_admin','text,text,text','install: the first administrator, granted what the policies actually check'),
('user-rbac','function','rbac.verify_api_key','text','spec.md §4.6: API-key path'),
-- Password reset, spec.md §5's deferred item. Declared because the whole
-- point of this audit is that a capability the specs promise is checked
-- against a live database rather than assumed from the file it was written in.
('user-rbac','table','rbac.password_reset_tokens',null,'spec.md §5: single-use, short-lived reset tokens'),
('user-rbac','function','rbac.request_password_reset','text,text,interval','spec.md §5: issue one, without revealing whether the address exists'),
('user-rbac','function','rbac.reset_password','text,text','spec.md §5: consume one, set the password, end every session'),

-- ---------- ai-query-layer: SCHEMA facets (schema.sql §13) --------------
('ai-query-layer','function','aiq.schema','text,text','§13: the mode answerable before you know anything'),
('ai-query-layer','function','aiq.embedding_space_name','text','the one home of a model''s embedding-space table name -- reachable because the SECURITY INVOKER read path asks it as the caller'),
('ai-query-layer','function','aiq.render_facet','text,text','§13b: one place a facet is produced'),
('ai-query-layer','function','aiq.verify_example','text,text','§13a: examples are run, not trusted'),
('ai-query-layer','function','aiq.capture_schema_revisions','','§13b: the version is a hash, a change is a row'),
('ai-query-layer','function','aiq.schema_drift','','§13b: a read-only gate on an uncaptured schema'),
('ai-query-layer','table','aiq.schema_facets',null,'§13: a facet is a registration, not a branch'),
('ai-query-layer','table','aiq.schema_examples',null,'§13a: the example corpus is data'),
('ai-query-layer','table','aiq.schema_revisions',null,'§13b: versioned and maintained with updates'),
('ai-query-layer','function','aiq.schema_p8ql','text','§13d: the dialect, from what parses it'),
('ai-query-layer','function','aiq.schema_workflow','text','§13e: enough to author a workflow unaided'),
('ai-query-layer','function','aiq.schema_sql','text','§13f: caller-scoped, deliberately'),
('ai-query-layer','function','aiq.schema_graph','text','§13g: the edge catalogue the trigger enforces'),

-- ---------- workflow-engine --------------------------------------------
('workflow-engine','schema','workflow',null,'spec.md: Postgres owns orchestration state'),
('workflow-engine','table','workflow.definitions',null,'spec.md §2'),
-- The lifecycle vocabulary, declared because three tables now reference it
-- and a missing one would take every status write with it.
('workflow-engine','table','workflow.lifecycle_states',null,'schema.sql: one home for the words every status column references'),
-- Readable to anyone who can read a status, because the alternative is what
-- every caller did instead: write the terminal set down again. A client polling
-- a run asks the database whether it has finished (REM-52).
('workflow-engine','function','workflow.is_terminal','text',
     'schema.sql: has this run, task or step finished -- asked of the vocabulary rather than of a list beside it'),
('workflow-engine','function','workflow.is_success','text',
     'schema.sql: ...and did it do what it was asked. A failed run also completed'),
('workflow-engine','table','workflow.runs',null,'spec.md §2'),
('workflow-engine','table','workflow.tasks',null,'spec.md §2'),
('workflow-engine','table','workflow.step_functions',null,'schema.sql §17: the operations a deployment blesses -- a timeout and a description each, and the whole surface under sql_policy = registered'),
('workflow-engine','function','workflow.start_workflow','text,jsonb,text,text','spec.md §4'),
-- The two halves of "whose run does this idempotency key resolve to" (REM-77).
-- Granted to nobody -- both are called only from SECURITY DEFINER functions
-- that own their own check -- so they are here because they must EXIST: the
-- engine standalone ships reusable_run as a stub and integration-rbac.sql
-- replaces it, and a database carrying only the stub is one where naming
-- somebody else's external_id hands back their run.
('workflow-engine','function','workflow.reusable_run','text','spec.md §4: an external_id matches only among the runs its caller may see'),
('workflow-engine','function','workflow.may_start','workflow.definitions','spec.md §17(a): whether this caller may use this definition. Callable by `authenticated` because current_definition() -- which asks it -- is SECURITY INVOKER, and a USING-clause-style predicate has no definer indirection to hide behind. Reading it tells a caller only about a row they already hold'),
('workflow-engine','function','workflow.may_access_run','uuid,text','integration-rbac.sql (e): the run row rule as a boolean, shared by assert_run_access and reusable_run'),
('workflow-engine','function','workflow.claim_task','text,text','spec.md: SKIP LOCKED claiming'),
('workflow-engine','function','workflow.get_task_context','uuid,text','§16: a worker must see its run input'),
('workflow-engine','function','workflow.complete_task','uuid,jsonb,text','spec.md §4'),
('workflow-engine','function','workflow.lease_violation','uuid,text,text','§23: the lease fence'),
('workflow-engine','view','workflow.v_lease_violations','','§23: refusals are visible'),
('workflow-engine','function','workflow.fail_task','uuid,jsonb,boolean,text','§16: terminal vs retryable'),
('workflow-engine','function','workflow.begin_compensation','uuid,text','spec.md: saga'),
('workflow-engine','function','workflow.reap_stale_tasks','integer','spec.md: crash recovery -- bounded per pass, the next tick takes the rest (REM-109)'),
('workflow-engine','function','workflow.queue_stale_timeout','text','scale.md: what a worker on this queue is bound by, so it paces its heartbeat from the database'),
('workflow-engine','function','workflow.define_yaml','text','YAML.md: workflows are authored as YAML'),
('workflow-engine','function','workflow.execute_sql_step','uuid','§17: sql steps run with no process'),
('workflow-engine','function','workflow.resolve_args','jsonb,uuid','§17: sql steps consume prior output'),

-- ---------- workflow-engine: matrix fan-out (schema.sql §20) -----------
('workflow-engine','function','workflow.expand_matrix','uuid','§20: fan-out is a SELECT, expanded with no process'),
('workflow-engine','function','workflow.matrix_rows','uuid','§20: the children ARE the recorded row set'),
('workflow-engine','function','workflow.matrix_outputs','uuid','§20: a successor must be able to reach its siblings'),
('workflow-engine','function','workflow.substitute_item','jsonb,jsonb,jsonb,text,text','§20a-bis: {{item.*}} and {{items}} are bound at expansion, not at dispatch; §20a-ter: row text escaped'),
('workflow-engine','function','workflow.brace_sentinel','jsonb,jsonb','§20a-ter: a per-child sentinel absent from template and rows'),
('workflow-engine','function','workflow.brace_escape','jsonb,text','§20a-ter: row text cannot open a template'),
('workflow-engine','function','workflow.brace_restore','jsonb,text','§20a-ter: resolvers put `{` back after their single pass'),
('workflow-engine','function','workflow.normalize_output','uuid,jsonb','§21a: the output contract is enforced, not just written down'),
('workflow-engine','function','workflow.encoding_drift','','§21a: a contract violation is a number, not a rumour'),
('workflow-engine','function','workflow.validate_shape','jsonb,jsonb','§21f: agent results combine because their shape is declared'),
('workflow-engine','function','workflow.matrix_gate_passes','uuid','§21e: min_success is checked before the aggregate is released'),
('workflow-engine','function','workflow.compensation_keys','jsonb','§21d: compensations are not part of the forward graph'),
('workflow-engine','column','workflow.tasks.tolerate_failure',null,'§21e: a fan-out survives an ordinary 404'),
-- integration-rbac.sql §c2. The read surface a caller needs to do anything
-- with a workflow beyond starting one and polling it: what workflows exist,
-- what a run actually did, the shape of its task graph, and the four
-- aggregates PostgREST will not compute because aggregates are off (PGRST123).
-- Each is owned by api_viewer so RLS on the base table still applies; the two
-- that touch no per-tenant row say so in their own line.
('workflow-engine','view','workflow.definitions_api','','§c2: nothing could list the workflows -- names, versions and derived shape, never the body'),
('workflow-engine','view','workflow.task_events_api','','§c2: the run timeline; scoped by joining the run whose policy decides what this caller sees'),
('workflow-engine','view','workflow.task_dependencies_api','','§c2: the edges of the task graph, same scoping -- tasks_api is the nodes'),
('workflow-engine','view','workflow.runs_by_status_api','','§c2: the group-by a browser may not run; counts what THIS caller may see'),
('workflow-engine','view','workflow.tasks_by_status_api','','§c2: the same per queue and kind'),
('workflow-engine','view','workflow.queues_api','','§c2: the configured queues and the TRUE depth of each, which is what a worker pool scales on'),
('workflow-engine','view','workflow.rate_limits_api','','§c2: token buckets minus the login and reset keys, whose keys are email addresses'),
('workflow-engine','table','workflow.queue_config',null,'§c2: three knobs per queue, no tenant column; plan_catalog() reads it to say which queues a step may name'),
('workflow-engine','function','workflow.queue_depth','text','§c2: the true backlog regardless of who asks -- SECURITY DEFINER on purpose, and it returns one integer'),
('workflow-engine','function','workflow.run_meta','uuid','§22a: a run can see itself'),
('workflow-engine','function','workflow.run_session','uuid,text','§22a: the engine mints the session a workflow could not'),
('workflow-engine','function','workflow.substitute_meta','jsonb,jsonb','§22d: {{run.$*}} is bound before the worker sees it'),
('workflow-engine','function','workflow.compiler_capabilities','','§22c: version skew reads as skew, not as bad syntax'),
('workflow-engine','registration','step:matrix_outputs',null,'§20: a fan-in needs no user code'),
('workflow-engine','function','workflow.call_step_function','text,jsonb,uuid,jsonb','§20b: one allow-list dispatcher, two callers'),
('workflow-engine','function','workflow.validate_matrix_steps','jsonb','§20f: a matrix without a ceiling is refused at registration'),
('workflow-engine','function','workflow.resolve_args','jsonb,uuid,jsonb','§20a: {{item.*}} is a third namespace'),
('workflow-engine','function','workflow.resolve_template_ref','text,uuid,jsonb','§20a: one reference resolved, so a query argument can carry text AROUND its templates'),
('workflow-engine','column','workflow.tasks.matrix_parent_id',null,'§20: a child points at the matrix that produced it'),
('workflow-engine','yaml_feature','batching',null,'§20j: batch_size and partition_by are AUTHORABLE, not just executable'),
('workflow-engine','yaml_feature','matrix',null,'§20: the compiler half of fan-out is installed too'),
('workflow-engine','yaml_feature','continue_on',null,'§21e: partial-failure tolerance is authorable'),

-- ---------- workflow-engine: artifacts, output class 4 (outputs.md) ----
-- The registration and read halves live in world-model-ingestion's
-- integration file (content loads after the engine), but the capability is
-- the engine's, so it is asserted with the engine.
('workflow-engine','function','workflow.artifact_ref','jsonb','outputs.md §4: one definition of "is this an artifact ref"'),
('workflow-engine','function','workflow.register_artifact','uuid,text,text,text,bigint,text,text,uuid','outputs.md §4: bytes become a resource id, never an s3:// URI'),
('workflow-engine','function','workflow.artifact','uuid','outputs.md §4: a ref resolves in-database, so class 4 needs no worker to read'),
('workflow-engine','view','workflow.v_artifacts','','outputs.md §4: which step produced which file, from either end'),
('workflow-engine','registration','step:artifact',null,'outputs.md §4: {{steps.x.$artifact}} is an ordinary step argument'),

-- ---------- ai-query-layer ---------------------------------------------
('ai-query-layer','schema','aiq',null,'brief.md: one query dialect'),
('ai-query-layer','table','aiq.nodes',null,'graph-identity.md: write-time node registry'),
('ai-query-layer','table','aiq.node_keys',null,'graph-identity.md: lookup index'),
('ai-query-layer','table','aiq.edges',null,'graph-identity.md: authored soft links'),
('ai-query-layer','function','aiq.note_recall','uuid[]','schema.sql: a read path records the edges it traversed to answer a real question, so consolidation can tell a stale edge from a stale load-bearing one'),
('ai-query-layer','function','aiq.note_probe','uuid[]','schema.sql: the same, for the system testing itself -- counted separately and never merged, or usage-based consolidation consolidates around its own monitoring'),
('ai-query-layer','view','aiq.edges_current',null,'schema.sql: edges that hold NOW -- valid_to null or future. Read this rather than aiq.edges unless you want retracted history, because a derivation retracts by setting valid_to and never deletes'),
('ai-query-layer','function','aiq.edge_is_current','timestamptz, timestamptz, timestamptz','schema.sql: the ONE currency rule. Every read of "edges that hold" goes through it -- the view, the property graph over it, both traversals, the catalogue, reliability and standing. It was four spellings and three read paths applying none (REM-51)'),
('ai-query-layer','table','aiq.edge_retractions',null,'schema.sql: retractions that were later undone -- while [retracted_at, revived_at) the edge did not hold. Written by a trigger on every path that revives an edge, because each writer spells the revival in its own words (REM-65)'),
('ai-query-layer','view','aiq.edge_periods',null,'schema.sql: one row per interval an edge was believed -- the row with its undone retractions cut out. An as-of read is aiq.edge_is_current over this; the compiled snapshot is built from it'),
('ai-query-layer','function','aiq.retract_derived','text, uuid, text[], text','schema.sql: withdraw ONE agent''s derived edges -- its entries leave an edge others also assert, and an edge it alone asserts is retracted with its provenance intact. Scoped by provenance rather than by relation name, which is how one package''s refresh retracted another''s (REM-60)'),
('ai-query-layer','function','aiq.projection_statements','aiq.entity_registry, text','schema.sql: the four projection statements, generated once from a registry row and run by both the live trigger and aiq.rebuild_entity_type -- the two carried copies, and the rebuild''s was missing the superseded-key delete (REM-51)'),
('ai-query-layer','function','aiq.resolve_mention','text, text, real, text[]','resolution.sql: a loose textual mention to a node -- exact, an entropy gate, a dropped qualification, then trigram. Returns the METHOD, so a caller can tell an answer from an escalation and ambiguity from absence'),
('ai-query-layer','function','aiq.name_entropy','text','resolution.sql: Shannon entropy per character -- whether a string carries enough evidence for similarity to mean anything'),
('ai-query-layer','function','aiq.has_high_entropy','text, real, integer','resolution.sql: the gate over the two guessing steps. Thresholds are parameters because they were tuned against somebody else''s corpus'),
('ai-query-layer','table','aiq.db_objects',null,'catalogue.sql: this database''s own catalogue as rows -- functions, tables, views, columns, indexes and roles. Empty until aiq.refresh_catalogue() is called; opt-in on purpose, because a deployment that does not want its schema in its graph should pay nothing for it'),
('ai-query-layer','function','aiq.refresh_catalogue','text[], text[]','catalogue.sql: populate the catalogue and derive exact dependency edges from pg_depend and pg_constraint. Schemas and reader roles are parameters -- a hardcoded list is silently wrong on a deployment that installed elsewhere'),
('ai-query-layer','function','aiq.reliability','bigint, bigint, real, real','reliability.sql: the posterior mean of a Beta prior over a source''s confirmations and corrections. Laplace by default; the prior is a parameter because it is a choice and not a law'),
('ai-query-layer','view','aiq.source_reliability',null,'reliability.sql: how often each extractor''s edges have been retracted -- a retraction is a correction. Materialise it before reading it during a derivation that uses it, or it scores every source as wrong every time'),
('ai-query-layer','function','aiq.neighbours','text, boolean','edge-standing.sql: a node''s depth-one neighbourhood, recording that the edges were read. Depth one on purpose -- a deeper walk would credit edges the caller never looked at'),
('ai-query-layer','function','aiq.is_probe',null,'edge-standing.sql: is this session declaring itself monitoring rather than use'),
('ai-query-layer','view','aiq.edge_standing',null,'edge-standing.sql: per edge -- load-bearing, never used, only ever probed, or retracted. SECURITY INVOKER, so a caller sees only their own edges'),
('ai-query-layer','view','aiq.edge_disparity',null,'edge-standing.sql: Serrano backbone extraction, alpha per endpoint under a uniform-partition null. Reports and never filters -- the significance level is the caller''s'),
('ai-query-layer','table','aiq.embedding_models',null,'schema.sql §10: one space per MODEL'),
('ai-query-layer','table','aiq.embedding_providers',null,'schema.sql §10a: what an embedding CALL looks like is data, not code'),
('ai-query-layer','column','aiq.embedding_models.credential_ref',null,'schema.sql §10: the env var name, never the token'),
('ai-query-layer','function','aiq.expand_embed_steps','jsonb','integration-workflow.sql: an embed step names a model, never a url -- and the model is pinned into both halves'),
('ai-query-layer','function','aiq.query','text,vector','§9: one RPC for the whole dialect'),
('ai-query-layer','function','aiq.lookup','text,boolean,integer','§7: LOOKUP / FUZZY'),
('ai-query-layer','function','aiq.extension_boundary','','§9b: every place the SQL half calls the compiled half, and whether it is there'),
('ai-query-layer','table','aiq.node_resolutions',null,
 'graph-identity.md D11: merges as records -- neither constituent deleted, tier says what kind of assertion it was, unresolve supported'),
('ai-query-layer','view','aiq.node_current',null,
 'graph-identity.md D11: every node and what it currently resolves to, following chains; an unmerged node maps to itself so it joins unconditionally'),
('ai-query-layer','function','aiq.resolve_nodes','uuid,uuid,text,text,jsonb','graph-identity.md D11: record a merge and move the merged node''s canonical keys onto the survivor as aliases'),
('ai-query-layer','function','aiq.unresolve_node','uuid,text','graph-identity.md D11: reverse a merge -- mechanical rather than reconstructive, because nothing was destroyed'),
('ai-query-layer','function','aiq.graph_neighbors','uuid,text,integer','§7: GRAPH depth 1'),
('ai-query-layer','function','aiq.graph_walk','uuid,integer,text,integer','§7: GRAPH depth n>1'),
-- The compiled algorithms, and ONLY the ones graph-algorithms.md marks SAFE.
-- Two of the five index proposals and one of the query ones are parked on a
-- measurement; they are deliberately absent here, because a row in this list
-- is a promise and a parked proposal is not one.
('ai-query-layer','function','aiq.related','text[],integer,text,integer,timestamptz,boolean','graph-algorithms.md §5.1: ranked relatedness, which a depth cap cannot express'),
('ai-query-layer','function','aiq.graph_paths','text,text,integer,integer,integer,text,timestamptz','graph-algorithms.md §5.2: k cheapest routes -- the one read path that honours valid_to'),
('ai-query-layer','function','aiq.graph_connect','text[],integer,text','graph-algorithms.md §5.5: the smallest subgraph joining a result set'),
('ai-query-layer','function','aiq.graph_dense','text,integer,integer,integer,text','graph-algorithms.md §5.3: k-core and cliques, bounded before the exponential part runs'),
('ai-query-layer','function','aiq.graph_trust','text[],double precision,integer,integer,text,timestamptz','graph-algorithms.md §5.4: how much of this rests on a model guess'),
('ai-query-layer','function','aiq.graph_frontier','text,integer,boolean,integer','graph-algorithms.md §4.2: how big is the neighbourhood, before walking it'),
('ai-query-layer','function','aiq.graph_snapshot','boolean,text[],double precision,timestamptz','graph-algorithms.md §4.1: what adjacency THIS backend is holding, and over which subset of the edge table'),
('ai-query-layer','function','aiq.graph_snapshot_drop','','graph-algorithms.md §2.3: give the snapshot and its admission slot back -- the remedy the slot-exhaustion error names'),
('ai-query-layer','function','aiq.graph_components','integer,integer','graph-algorithms.md §5.6: connected components -- the hardening primitive'),
('ai-query-layer','function','aiq.graph_induced','uuid[],text,timestamptz','graph-algorithms.md §5.7: the internal edges of a node set, in one round trip'),
('ai-query-layer','function','aiq.graph_reach_build','integer,integer','graph-algorithms.md §4.2: the sketch build, a scheduled task not a query'),
('ai-query-layer','function','aiq.enable_graph_algorithms','name,boolean','graph-algorithms.md §11: shipped experimental means present, inert, and openable in one call'),
('ai-query-layer','function','aiq.semantic_in','text,vector,text,integer','§10: SEMANTIC, model-scoped -- source-qualified, per schema.sql'),
('ai-query-layer','function','aiq.set_scan_order','text','§10: the one setting semantic_in changes (hnsw.iterative_scan), set as the owner because a caller no longer holds set_config -- user-rbac/roles.sql §6'),
('ai-query-layer','function','aiq.lexical','text,text,integer','§11: TEXT'),
('ai-query-layer','function','aiq.search','text,text,vector,text,integer,integer','§11: SEARCH / RRF'),
('ai-query-layer','function','aiq.lookup_many','text[],boolean,integer','§7: LOOKUP takes a list of keys'),
('ai-query-layer','function','aiq.sql_passthrough','text','§12: the escape hatch'),
('ai-query-layer','function','aiq.check_drift','text','graph-identity.md D7'),
('ai-query-layer','function','aiq.rebuild_entity_type','text','graph-identity.md: rebuild'),
('ai-query-layer','function','aiq.register_entity_table','text,text,text,text,text,text,text','graph-identity.md D6: a consumer gets projection by registering, not by hand-writing three triggers'),
('ai-query-layer','table','aiq.entity_registry',null,'graph-identity.md "Inclusion policy": rebuild and live projection read ONE predicate'),
('ai-query-layer','table','aiq.relation_types',null,'graph-identity.md "Catalogue": an unlisted triple is refused at write'),
-- Aliases and short keys are two thirds of LOOKUP's cascade and invariant 5
-- forbids writing node_keys directly, so the absence of this function meant
-- those branches could only be reached by breaking the rule the schema states.
('ai-query-layer','function','aiq.add_node_key','text,text,text','graph-identity.md "Keys": the named exception to invariant 5'),
-- The graph itself is a catalog object with its own privilege, separate from
-- the tables it reads. An audit that checks the tables and not this one passes
-- clean against a deployment where GRAPH mode returns "permission denied".
('ai-query-layer','property_graph','aiq.knowledge_graph',null,'graph-identity.md D8: SQL/PGQ is the read-only overlay'),

-- Embedding a CORPUS, which is a different function from embedding a query and
-- was missing until the pipeline was run. A deployment with expand_embed_steps
-- and no record_embeddings can answer a question and cannot index a document.
('ai-query-layer','function','aiq.embed_batch_call','text,jsonb','ingestion.md §1: the worker asks for the endpoint and request shape, so the model still lives in one place'),
('ai-query-layer','function','aiq.record_embeddings','text,jsonb','ingestion.md §4: a whole batch at once, because two vectors do not fit in one task output'),
('ai-query-layer','function','aiq.land_embeddings','uuid','ingestion.md §4: the fan-in for a declarative matrix of embed children'),

-- The graph writer. Its reference tables are checked because the machine path's
-- whole claim is that it writes THESE and never a human's typed table.
('ai-query-layer','table','aiq.soft_nodes',null,'graph-index.md §4.4: an unresolved mention is a candidate, never an invented company'),
('ai-query-layer','table','aiq.lake_nodes',null,'graph-index.md §4.4: identity is always in Postgres, payload need not be'),
('ai-query-layer','function','aiq.upsert_graph','jsonb,jsonb','graph-index.md §5: one writer for an extracted graph, holding invariants 1-5'),
('ai-query-layer','function','aiq.land_graph','jsonb,uuid','graph-index.md §6.1: the whole-document shape, no fan-in'),
('ai-query-layer','function','aiq.land_graph_fanout','uuid','graph-index.md §6.2: the windowed shape''s fan-in'),
('ai-query-layer','function','aiq.register_graph_vocabulary','jsonb','graph-index.md §5.3: the closed relation vocabulary, and the symmetry and inverses of each'),
('ai-query-layer','function','aiq.install_structure_null','text','graph-index.md §1: the null extractor is a row, installed like the ingest workflow'),
('ai-query-layer','function','aiq.extractor_call','text,text,text,text,text','graph-index.md §6: the model half -- an OpenAI-shaped chat call, built as a row'),
('world-model-ingestion','function','aiq.quote_occurs','text,text','extraction.md §4.2: whether a model''s quote is in its source, by the one rule every extractor uses'),
('agentic','function','agentic.agent_call','text,text,text,text,text','the general form of the above: the chat-completions request ANY agent row describes, so a consumer with its own agent does not hand-assemble a body'),
('agentic','function','agentic.parse_model','text','brief §7: agents.model is provider:model_id; one parse for every path that runs a row'),
('ai-query-layer','function','aiq.plan_facet','','plan-graph.md §4: the sources and models half of the plan catalog'),
('ai-query-layer','function','aiq.space_populated','text,text','plan-graph.md §4: which models a corpus is ACTUALLY embedded in, as opposed to registered'),
('ai-query-layer','view','aiq.v_plan_sources','','plan-graph.md §4: one row per source name, with the columns and spaces a plan expands'),

-- ---------- world-model-ingestion --------------------------------------
('world-model-ingestion','schema','content',null,'brief.md §2-§3: the content plane'),
('world-model-ingestion','table','content.channels',null,'brief.md §2: a source is a row'),
('world-model-ingestion','table','content.files',null,'brief.md §3: pointers, never bytes'),
('world-model-ingestion','table','content.resources',null,'brief.md §2: unit of ingested content'),
('world-model-ingestion','table','content.resource_chunks',null,'brief.md §3: what SEMANTIC searches'),
('world-model-ingestion','function','content.register_upload',
     'text,text,text,text,bigint,text,text,text,uuid,jsonb,text,text,text','brief.md §3.5: upload registers AND starts ingestion'),
('world-model-ingestion','function','content.register_fetched','text,text,text,text,uuid,jsonb','brief.md §2: pulled sources'),
('world-model-ingestion','function','content.resolve_file','uuid','brief.md §3.5: proxied reads'),
('world-model-ingestion','function','content.record_chunks','uuid,jsonb','brief.md §3: chunking writes back'),
('world-model-ingestion','function','content.check_drift','','brief.md §3: reconciliation is definition-of-done'),
-- Ingestion. Every row here was named in a spec sentence for months and checked
-- by nothing: the audit reported clean against a database where an upload could
-- be stored and never chunked, which is the exact gap this file exists to close.
('world-model-ingestion','function','content.install_ingest_workflow','text,text,text,boolean,text,text','ingestion.md §1: the pipeline is two steps and a call that writes them'),
('world-model-ingestion','function','content.merge_policy','jsonb,jsonb','ingestion.md §3: a DEEP merge, so an upload setting one chunking field does not erase the channel''s others'),
('world-model-ingestion','function','content.record_ingest','uuid,jsonb','ingestion.md §5: ready means "in the corpus", stored means it is not'),
('world-model-ingestion','function','content.chunks_to_embed','uuid','ingestion.md §1: what both the batched and the fanned-out path read'),
-- The lake half. A table is not prose, and the alternative is 200 near-identical
-- embeddings of a price table that rank against each other and answer nothing.
('world-model-ingestion','table','content.datasets',null,'ingestion.md §6: a tabular upload becomes Parquet, registered under one name'),
('world-model-ingestion','table','content.dataset_files',null,'ingestion.md §6: append means this month''s export joins last month''s under one prefix'),
('world-model-ingestion','function','content.register_dataset','uuid,text,text,text,jsonb,bigint,text,text[]','ingestion.md §7.4: the upsert is the API, so the constraint is NULLS NOT DISTINCT'),
('world-model-ingestion','function','content.dataset_uri','text','ingestion.md §6: DuckDB reads the dataset by name, not by object key'),
-- The lake worker's four calls (lake.md). Each is where a boundary lives: what
-- the run owner may read, where an output may be written, what the registry may
-- claim a location is, and which functions a refined row may reach.
('world-model-ingestion','function','content.lake_resolve','uuid,text,text[]','lake.md §3: inputs resolve as the run owner, through rbac.may_read'),
('world-model-ingestion','function','content.lake_target','uuid,text,text,text','lake.md §3: the output layout has one definition, and it is here'),
('world-model-ingestion','function','content.register_lake_output','uuid,text,jsonb','lake.md §3: the registry refuses a location outside the writer''s org, because the sandbox trusts it'),
('world-model-ingestion','function','content.lake_land','uuid,text,text,jsonb','lake.md §5: a refined row reaches a table only through a registered step function'),
('world-model-ingestion','function','content.lake_datasets','text[]','lake.md §3: the one visibility rule lake_resolve applies, through rbac.may_read'),
('world-model-ingestion','function','content.lake_catalog','text,integer','lake.md §6: what an agent can find in the lake -- columns, sizes, vector spaces, CRS -- and not where the bytes are'),
('world-model-ingestion','function','content.lake_plan','jsonb','lake.md §6: p8ql LAKE is planned as the caller and run on the lake worker'),
('world-model-ingestion','function','content.schema_lake','text','lake.md §6: SCHEMA "lake" -- caller-scoped, so the global p8ql facet stays one document'),
('world-model-ingestion','channel','workflow_artifacts',null,'outputs.md §4: step output has a channel, with no ingest_workflow on it'),

-- The authoring surface the workbench writes through, and the two tables an
-- API pull fills. Every one of these was reachable by `authenticated` and
-- described nowhere here, which is the state this file exists to make
-- impossible -- they arrived with the API source editor and the audit found
-- them the same day.
--
-- The pull state is TWO tables on purpose. source_state is one row per source
-- and carries the watermark, so resuming is reading a row rather than scanning
-- what was already stored; source_records is what came back, keyed by the
-- API's own id so a re-pull upserts rather than duplicates.
('world-model-ingestion','table','content.source_state',null,'sources.md §4.1: the cursor is a closed taxonomy, and this is where its position lives'),
('world-model-ingestion','table','content.source_records',null,'sources.md §3: staging -- what we were told, before anything interprets it'),
('world-model-ingestion','function','content.save_source','uuid,text,jsonb,jsonb,timestamptz',
     'sources.md §4: the declaration is data, so authoring one is an upsert with the caller''s own permissions'),
('world-model-ingestion','function','content.save_api_source','uuid,text,jsonb,text,timestamptz',
     'sources.md §4: the same declaration for a pulled API, carrying its watermark and pagination'),
('world-model-ingestion','function','content.start_source_pull','uuid,text',
     'sources.md §8: a pull is queued work, so starting one is a row rather than a request the browser holds open'),
('world-model-ingestion','function','content.reset_source_progress','uuid',
     'sources.md §4.1: re-reading from the beginning is resetting the cursor, not deleting what it produced'),
-- A predicate rather than an action, and SECURITY DEFINER for the reason
-- has_permission is: the caller must not need a grant on the org tables to be
-- told no. It takes an org id the caller already holds, so it answers about
-- the caller and nobody else.
('world-model-ingestion','function','content.may_upload','uuid',
     'brief.md §3.5: an upload is checked before bytes move, not after'),

-- ---------- workflow-engine: schedules (schema.sql §19) ----------------
-- pg_cron is deliberately NOT asserted here. It is one caller of tick(), not
-- the mechanism -- an operator or a KEDA-scaled pod driving the same function
-- is a supported deployment -- so what the spec promises is the capability,
-- and that is what this checks.
('workflow-engine','table','workflow.schedules',null,'§19: a scheduled workflow is a row'),
('workflow-engine','function','workflow.tick','timestamptz','§19: the one clock'),
('workflow-engine','function','workflow.cron_matches','text,timestamptz,text','§19: 5-field cron, in the schedule''s timezone'),
('workflow-engine','function','workflow.schedule_workflow','text,text,text,jsonb,text,text','§19: POST /rpc/schedule_workflow'),
('workflow-engine','function','workflow.set_schedule_enabled','text,boolean','§19: disable without losing history'),
('workflow-engine','function','workflow.lint_spec','jsonb','§25: a p8ql string that cannot parse is refused at authoring time, not at 3am'),
('workflow-engine','function','workflow.unschedule_workflow','text','§19: the destructive one'),
-- A step may write its own SQL, and the allow-list is a policy rather than the
-- only door. Every one of these is a promise made in YAML.md and roadmap.md §6.
('workflow-engine','function','workflow.run_sql','text,boolean,integer,jsonb','a step carries its own statement, read-only unless it declares otherwise'),
('workflow-engine','function','workflow.sql_policy','','open or registered -- the lockdown is a setting, not a rebuild'),
('workflow-engine','function','workflow.resolve_statement','text,uuid,jsonb','the escaping form: a {{template}} becomes a quoted literal. Kept for the row-source statement'),
('workflow-engine','function','workflow.resolve_statement_params','text,uuid,jsonb','the binding form: a {{template}} becomes $1->>ref with the values bound, so row data never reaches the parser'),
-- The plan graph: a definition expanded along what it names (plan-graph.md).
('workflow-engine','function','workflow.plan_catalog','','what this deployment HAS, as one document the graph builder reads'),
('workflow-engine','function','workflow.plan_graph','text,integer','a definition expanded along the entities it reaches'),
('workflow-engine','function','workflow.plan_document','text,integer','the same resolution, projected into the pipeline a person reads'),
('workflow-engine','function','workflow.plan_defects','text','every current definition, defects only -- the deployment gate shape'),
('workflow-engine','function','workflow.plan_probe','text,integer','the cheap half of every step, executed: parses, relations, result columns, arity'),
('workflow-engine','function','workflow.plan_status','text,uuid','what YOUR last run returned, shape by shape -- the thing a plan cannot know'),
('workflow-engine','function','workflow.one_write_statement','text','the wrapping that makes a write step ONE statement -- reachable because plan_probe is SECURITY INVOKER and asks it as the caller'),

-- ---------- agentic ----------------------------------------------------
-- The fifth subsystem. It had a complete schema.sql and zero rows here, which
-- is the one gap this file cannot catch on its own: an unbuilt subsystem
-- declares no expectations, so the audit passes by not asking.
('agentic','schema','agentic',null,'brief.md: conversations and delegation live in Postgres'),
('agentic','table','agentic.agents',null,'brief.md §2: every agent is a row, never runtime code'),
('agentic','table','agentic.sessions',null,'brief.md §3: the conversation'),
('agentic','table','agentic.runs',null,'brief.md §3: interactive and scheduled runs are one primitive'),
('agentic','table','agentic.messages',null,'brief.md §4: the turn record'),
('agentic','table','agentic.tool_servers',null,'brief.md §5.2: a tool is an OpenAPI/MCP binding'),
('agentic','function','agentic.create_session','text','brief.md §3'),
('agentic','function','agentic.start_run','text,uuid,uuid,uuid,text,text,text,uuid','brief.md §3: delegation carries the span tree'),
-- The predicate start_run is gated on, reachable so a caller can be told no
-- without holding a grant on agentic.agents. `authenticated` only: the
-- anonymous grant it carried made it a probe for which agents exist, and
-- nothing needed it, since web_anon cannot execute start_run either.
('agentic','function','agentic.may_invoke','text','brief.md §5.1: chat costs money and reaches tools, so invoking is a permission'),
('agentic','function','agentic.finish_run','uuid,text,jsonb','brief.md §3'),
('agentic','function','agentic.persist_turn','jsonb','brief.md §4: one call per turn, not N inserts'),
('agentic','function','agentic.upsert_agent','jsonb','brief.md §2: agents are declared, not deployed'),
-- Reachable by `authenticated` and deliberately so: it reads no rows and writes
-- nothing, and it is how a client asks what a document becomes -- and whether
-- this database translates documents at all -- before installing one. REM-70.
('agentic','function','agentic.agent_document_to_row','jsonb','brief.md §6: the ONE translation from an agent document to the row shape, so that no loader carries its own and a key nobody reads is refused rather than dropped'),
('agentic','function','agentic.upsert_tool_server','jsonb','brief.md §5.2'),
('agentic','column','agentic.tool_servers.default_headers',null,'reference/README §1: one url is not one OpenAPI document'),
('agentic','function','agentic.may_author','text,regclass','reference/README §5: the first agent is registered by a migration, not a user'),
('agentic','function','agentic.plan_facet','','plan-graph.md §4: the agents and servers half of the plan catalog'),
('agentic','view','agentic.v_plan_agents','','plan-graph.md §6: an agent expanded -- the whole prompt, because the prompt IS the intent'),
('agentic','view','agentic.v_plan_servers','','plan-graph.md §6: a server and what each of its tools says it does'),
('agentic','view','agentic.agents_pickable',null,'schema.sql §9: a table sized for thousands needs the audience filter'),
-- Skills and plugins. The columns are listed alongside the tables on purpose:
-- every one of them is a place this schema has already been bitten once. A
-- column absent from a read view is a column the runtime does not have
-- (agents_api), and a flag the persistence adapter cannot see is instructions
-- it will summarize away (serves_skills).
('agentic','table','agentic.skills',null,'plugins.md §4: a procedure an agent follows is a row, not a copied paragraph'),
('agentic','table','agentic.plugins',null,'plugins.md §9: a bundle applied from one document is removable as one'),
('agentic','function','agentic.upsert_skill','jsonb','plugins.md §4: skills are declared, not edited in a running database'),
('agentic','function','agentic.apply_plugin','jsonb','plugins.md §9: apply upserts what the manifest declares and prunes what it does not'),
('agentic','function','agentic.attach_skill','text,text,jsonb','plugins.md §5.5: adding a fragment to an agent is one statement, not read-modify-write'),
('agentic','function','agentic.detach_skill','text,text','plugins.md §5.5: and so is removing one'),
('agentic','view','agentic.skills_api',null,'plugins.md §5: the runtime loads a pinned body over REST like every other client'),
('agentic','view','agentic.plugins_api',null,'plugins.md §9: what did this plugin install, answered from the document as applied'),
('agentic','column','agentic.agents.skills',null,'plugins.md §5: the pinned list, which is prompt content the runtime must be able to read'),
('agentic','column','agentic.tool_servers.serves_skills',null,'plugins.md §7: the adapter has to recognise a skill load to stop windowing it away'),
('agentic','column','agentic.skills.discovery_text',null,'plugins.md §6: only the listing is embedded, and it is generated so it cannot drift'),
-- The sample itself. A registered agent bound to servers that were never
-- registered is the failure this repository keeps finding one layer down --
-- a demo that lives only in a running container -- so the audit asserts the
-- rows, not just the tables they sit in.
('agentic','agent','percolate',null,'reference/percolate.yaml: the sample agent ships as data'),
-- The sample fleet. These five rows ARE the sample agent's old system prompt:
-- it went from 2,464 characters to 159 when they came out of it, and if they
-- are missing the agent ships with a prompt that no longer says what it used
-- to. That is the failure this block exists to catch -- a refactor whose
-- second half did not install is strictly worse than not having done it.
('agentic','skill','p8ql-schema-first',null,'reference/percolate.yaml: composed -- start with SCHEMA'),
('agentic','skill','house-style-attribution',null,'reference/percolate.yaml: composed -- say which tool told you'),
('agentic','skill','workflow-define-then-start',null,'reference/percolate.yaml: composed -- define work, do not poll'),
('agentic','skill','p8ql-fuzzy-lookup',null,'reference/percolate.yaml: matched -- FUZZY when a LOOKUP finds nothing'),
('agentic','skill','p8ql-read-the-plan',null,'reference/percolate.yaml: matched -- an empty result is not an answer'),
('agentic','skill_binding','percolate',null,'plugins.md §5.1: the agent composes the three that were always in its prompt'),
('agentic','tool_server','p8-query',null,'reference/query_mcp.py: the MCP binding'),
('agentic','tool_server','p8-workflow',null,'reference/percolate.yaml: the OpenAPI binding over PostgREST'),

-- ---------- the corpus, as data ----------------------------------------
-- `lexical:chunks` and `semantic:chunks` are checked below and were passing
-- against a corpus of ZERO chunks and a model registry of ZERO models: three
-- of the seven modes had never returned a row to anybody and the audit called
-- them present. A registration is not a corpus, and these rows are the
-- difference.
('ai-query-layer','corpus','chunks',null,'dev/init/05-corpus-sample.sql: TEXT, SEMANTIC and SEARCH need something to search'),
('ai-query-layer','embedding_space','demo-quad-a',null,'§10: a registered model is a TABLE, not just a row in the registry'),
('ai-query-layer','embedding_space','demo-quad-b',null,'§10: two models of one dimension are two spaces -- the claim needs two to be checkable'),

-- ---------- the worked graph, as data ----------------------------------
-- Same reasoning as the agentic sample above, and found the same way. Every
-- measured claim in ai-query-layer/schema.sql §8 and every worked result in
-- USAGE.md's GRAPH section was produced against a fixture that existed only in
-- a psql session -- `specs/agentic/reference/README.md` still quotes output
-- from an `fx_pair` entity type that appears in no file in this repository.
-- These rows assert that `docker compose up` produces the graph the documents
-- describe, not merely the tables it could live in.
('ai-query-layer','entity_type','company',null,'dev/init/04-graph-sample.sql: the sample graph ships as data'),
('ai-query-layer','entity_type','person',null,'dev/init/04-graph-sample.sql: a walk that crosses entity types'),
('ai-query-layer','entity_type','event',null,'dev/init/04-graph-sample.sql: the hard FK that is not an edge'),
('ai-query-layer','graph_example','graph',null,'§13a: the facet an agent reads before writing its first edge shipped with no examples'),

-- ---------- the REST-reachable views ----------------------------------
-- Thirteen of the fifteen *_api views were missing from this file until the
-- closing check at the foot of it went looking. They are the most external
-- thing the system has -- PostgREST turns each one into a URL -- and the
-- inventory that is supposed to describe the surface did not mention them.
-- That is the one-way-ratchet failure: everything listed here was checked to
-- exist, and nothing asked what existed and was not listed.
('agentic','view','agentic.agents_api',null,'schema.sql §9: the authoring view, system_prompt included -- an agent is its prompt'),
('agentic','view','agentic.sessions_api',null,'schema.sql: a caller lists their own conversations'),
('agentic','view','agentic.runs_api',null,'schema.sql: run state and trace ids, scoped to the owner'),
('agentic','view','agentic.messages_api',null,'agents.md: the transcript read path -- owner-only, proven in dev/tests/agentic/03'),
('agentic','view','agentic.tool_servers_api',null,'schema.sql: discovery reads default_headers from here, which is why the round trip covers it'),
('ai-query-layer','view','aiq.nodes_api',null,'plan-graph.md: entities a caller may read, org-filtered'),
('ai-query-layer','view','aiq.edges_api',null,'plan-graph.md: the relations between them, same filter'),
('user-rbac','view','rbac.users_api',null,'spec.md §5: a directory that carries no password_hash'),
('user-rbac','view','rbac.orgs_api',null,'spec.md §4: the orgs a caller can see, with how many people are in each -- the count is here so no screen computes it'),
('user-rbac','view','rbac.api_keys_api',null,'spec.md §5: a caller manages their own keys and sees no key_hash -- dev/tests/rbac/07'),
('user-rbac','view','rbac.refresh_tokens_api',null,'spec.md §5: sessions a caller may revoke, without the token_hash that would let anyone replay them'),
('workflow-engine','view','workflow.runs_api',null,'spec.md §4: run status over REST'),
('workflow-engine','view','workflow.tasks_api',null,'spec.md §4: per-task state, the read half of the worker protocol'),
('workflow-engine','view','workflow.schedules_api',null,'spec.md: what is scheduled, readable without the scheduler'),

-- ---------- functions a caller role may execute -------------------------
-- Same origin as the views above: these came back from asking the catalog
-- which functions `authenticated` or `web_anon` may actually EXECUTE. Each is
-- reachable from outside, so each is a promise whether or not anyone wrote it
-- down.
('agentic','function','agentic.upsert_summary','uuid,text','context compaction: a session''s rolling summary is written through one path'),
('agentic','function','agentic.apply_summary','jsonb','the runtime hands back a summary it generated; this is where it lands'),
('agentic','function','agentic.channel_for','uuid','a session''s notify channel, so a client can subscribe to its own run'),
('user-rbac','function','rbac.current_org_ids','','the orgs this caller belongs to, read from rbac.org_members and narrowed by the token -- moved here from aiq, which had no membership to read'),
('ai-query-layer','function','aiq.graph_schema','','plan-graph.md: what the graph contains, answered from the registry'),
('ai-query-layer','function','aiq.is_graph_schema','jsonb','the shape check upsert_graph applies, exposed so a caller can validate before sending'),
('ai-query-layer','function','aiq.facet_examples','text','worked examples per facet, which is what makes the schema legible to a model'),
('ai-query-layer','function','aiq.resolve_ref','text,text,boolean,real,uuid','name to node, fuzzily -- the entry point for turning prose into a graph reference'),
('ai-query-layer','function','aiq.embed_call','jsonb,text','the embedding marker a step leaves for the worker to fulfil'),
('user-rbac','function','rbac.may_access_org','uuid','may this caller act inside this org at all -- moved here from content, which owned it only by being first to need it'),
('world-model-ingestion','function','content.assert_org_write','uuid,text','the org WRITE check -- the half that raises rather than filtering'),
('world-model-ingestion','function','content.windows_to_index','uuid','ingest.md: the windows an indexing pass must cover for a resource'),
('user-rbac','table','rbac.orgs',null,'spec.md §2b: the tenant, which had no table at all until scope landed'),
('user-rbac','table','rbac.org_members',null,'spec.md §2b: who belongs to a tenant -- the fact the JWT orgs claim used to assert with nothing behind it'),
('user-rbac','table','rbac.visibilities',null,'spec.md §2b: private/org/public as rows, so p8.enums() publishes the vocabulary and a foreign key enforces it'),
('user-rbac','function','rbac.shared_org_id','','identity spec.md §4: the org_id of the shared tier, as a derived v5 uuid rather than a NULL -- the same value in every deployment'),
('user-rbac','function','rbac.org_or_shared','uuid','what an OMITTED org argument means: a null at an API boundary is the shared tier, coerced once so the NOT NULL column never sees one'),
('user-rbac','function','rbac.is_shared_org','uuid','the replacement for every `org_id is null` -- true for the shared tier and for an argument nobody supplied'),
('user-rbac','function','rbac.adopt_shared_org','regclass','makes one table''s org_id NOT NULL, defaulted and backfilled -- the one home for the migration, called by add_scope_columns and by the two tables that do not take it'),
('user-rbac','function','rbac.may_read','uuid,uuid,text','the scope rule as a function, for SECURITY DEFINER callers that check one row rather than filter a table'),
('user-rbac','function','rbac.may_write','uuid,uuid,text','the WITH CHECK half: own the row, belong to the org, and do not say org without one'),
('user-rbac','function','rbac.is_operator','','the one rule for "no person behind this call": no claims, on a login that is not a door a person arrives through. Every write policy evaluates it as the caller, so every caller role must be able to'),
('user-rbac','function','rbac.scope_predicate','','the single home of the read expression every scoped policy is generated from'),
('user-rbac','function','rbac.scope_write_predicate','','the same for the write half'),
('user-rbac','function','rbac.add_scope_columns','regclass,text','a module adopts scope with this and add_scope_policy, not with hand-written DDL'),
('user-rbac','function','rbac.add_scope_policy','regclass,text','generates the RLS policies, so sixteen tables cannot drift into sixteen predicates'),
('user-rbac','function','rbac.add_org_member','uuid,uuid,text','tenant self-administration, gated like grant_role and never on a caller-supplied actor'),
('user-rbac','function','rbac.create_org','text,text','a new tenant with its creator as admin, gated by orgs/admin'),
('user-rbac','function','rbac.remove_org_member','uuid,uuid','revoking membership, which takes effect on the next request rather than at token expiry'),
('user-rbac','function','rbac.change_password','text,text','spec.md §4: a caller rotates their own password, old one required'),
('user-rbac','function','rbac.grant_role','uuid,text','spec.md §4: role assignment, gated on users/admin -- the escalation guard dev/tests/rbac/07 pins'),
-- The research platform (specs/research-platform/schema.sql).
('research-platform','function','engagement.add_comment','uuid,text,text','architecture.md §5: a person comments on an exact revision, optionally one of its claims'),
('research-platform','function','engagement.edit_comment','uuid,text,integer','architecture.md §5: an edit from the version last read keeps every version'),
('research-platform','function','engagement.moderate_comment','uuid,text','architecture.md §5: moderation is its own capability, with actor and reason'),
('research-platform','function','engagement.revision_signals','uuid','architecture.md §5: counts only for a revision the caller can read'),
('research-platform','function','engagement.set_following','uuid,boolean','architecture.md §5: a follow targets a core org'),
('research-platform','function','engagement.set_like','uuid,boolean','architecture.md §5: one active like, never your own comment'),
('research-platform','function','engagement.set_saved','uuid,boolean','architecture.md §5: saved research follows the work across clients'),
('research-platform','function','engagement.set_useful','uuid,boolean','architecture.md §5: one active useful vote per revision, never on your own research'),
('research-platform','function','engagement.set_valuation','uuid,bigint,text','architecture.md §5: a private, nonbinding value estimate'),
('research-platform','function','engagement.withdraw_comment','uuid,text','architecture.md §5: a withdrawal keeps the comment and its reason'),
('research-platform','function','rbac.access_snapshot','text','architecture.md §2: the caller''s roles, decisions, plan and limits, explanatory only'),
('research-platform','function','rbac.consume_usage','text,text,bigint','architecture.md §3: settle a reservation at the amount actually used'),
('research-platform','function','rbac.current_actor','','architecture.md §2: person, agent or platform, from the trusted claims'),
('research-platform','function','rbac.current_credential_id','','architecture.md §2: the credential a call came through'),
('research-platform','function','rbac.decide','text,text','architecture.md §2: the one access decision, with its reason code'),
('research-platform','function','rbac.grant_with_basis','uuid,text,text,text,text,uuid','architecture.md §2: a grant records granter, basis and evidence'),
('research-platform','function','rbac.has_quota_remaining','uuid,text','architecture.md §3: the runtime''s existing quota check, now defined'),
('research-platform','function','rbac.limit_state','uuid,text','architecture.md §3: unset, unlimited, finite or exhausted, for the caller only'),
('research-platform','function','rbac.may','text,text','architecture.md §2: the decision as a boolean'),
('research-platform','function','rbac.plan_of','uuid','architecture.md §3: the plan an account is on'),
('research-platform','function','rbac.release_usage','text,text','architecture.md §3: return a reservation that was not used'),
('research-platform','function','rbac.is_app_provisioner','','architecture.md §2: is the login role a member of app_provisioner, or a superuser'),
('research-platform','function','rbac.require_app_provisioner','','architecture.md §2: refuse anyone but the application provisioner'),
('research-platform','function','rbac.provision_application_user','uuid','architecture.md §2: an application gives a person a core identity'),
('research-platform','function','rbac.provision_application_credential','uuid,uuid,text,text[]','architecture.md §2: an application registers a credential it verified, with its scopes'),
('research-platform','function','rbac.revoke_application_credential','uuid','architecture.md §2: an application revokes a credential it provisioned, and no other'),
('research-platform','function','rbac.grant_application_role','uuid,text,text,text,text,text','architecture.md §2: an application grants its own capabilities, never an administrator'),
('research-platform','function','rbac.grant_application_role','uuid,text,text,text,text,text,text,uuid','architecture.md §2: provisioning preserves application/org scope and revoked history'),
('research-platform','function','rbac.request_claims','','architecture.md §2: the request claims as jsonb, empty when absent'),
('research-platform','function','rbac.require','text,text','architecture.md §2: raise unless the decision allows'),
('research-platform','function','rbac.reserve_usage','text,bigint,text,interval','architecture.md §3: an atomic reservation one person and their agents share'),
('research-platform','function','rbac.revoke_grant','uuid,text','architecture.md §2: revocation is recorded with its reason and removes the role'),
('research-platform','function','research.endorse','uuid,text,text,text[]','architecture.md §6: a person says what they checked in an exact revision, and optionally which claims (specs/tables/schema.md §5, REM-154)'),
('research-platform','function','research.endorsements_affected_by','uuid','specs/tables/schema.md §5: the endorsements whose checked claims a correction removed or reworded (REM-154)'),
('research-platform','function','research.get_package','text,text','architecture.md §4: the head or a named revision, if the caller may read it'),
('research-platform','function','research.list_packages','boolean','architecture.md §4: owned and visible packages'),
('research-platform','function','research.readable','uuid','architecture.md §4: may the caller read this work'),
('research-platform','function','research.receipt','uuid,boolean','architecture.md §4: ids, label and hash for a revision the caller may read'),
('research-platform','function','research.revise_package','text,jsonb,text','architecture.md §4: append from the expected head; stale is 409'),
('research-platform','function','research.revise_working','text,jsonb,text','authoring-and-publication.md §4: a private working revision that exposes nothing, from the expected head'),
('research-platform','function','research.visible_head','uuid','authoring-and-publication.md §4: the head with full access, otherwise the latest exposed revision'),
('research-platform','function','research.work_readable_in_full','uuid','authoring-and-publication.md §4: owner or org access to every revision of a work'),
('research-platform','function','research.revision_readable','uuid','architecture.md §4: may the caller read this revision'),
('research-platform','function','research.submit_package','jsonb,text,text','architecture.md §4: create a work and draft-1, idempotent by key'),
('research-platform','function','research.trust','uuid','architecture.md §6: the structural trust read for an exact revision'),
('research-platform','function','content.capture_snapshot','uuid','specs/tables/schema.md §4: capture a readable resource''s current bytes and hash, taken from the locked resource row (REM-153)'),
('research-platform','function','content.resolve_snapshot','uuid','specs/tables/schema.md §4: pinned bytes resolved through the resource''s own read rule, nothing once removed (REM-153)'),
('research-platform','function','research.withdraw_endorsement','uuid,text','architecture.md §6: a withdrawal stays visible as inactive'),
('research-platform','table','engagement.comment_likes',null,'architecture.md §5'),
('research-platform','table','engagement.comment_versions',null,'architecture.md §5'),
('research-platform','table','engagement.comments',null,'architecture.md §5'),
('research-platform','table','engagement.follows',null,'architecture.md §5'),
('research-platform','table','engagement.saves',null,'architecture.md §5'),
('research-platform','table','engagement.valuations',null,'architecture.md §5'),
('research-platform','table','engagement.votes',null,'architecture.md §5'),
('research-platform','table','rbac.applications',null,'architecture.md §2'),
('research-platform','table','rbac.grants',null,'architecture.md §2'),
('research-platform','table','rbac.plan_assignments',null,'architecture.md §3'),
('research-platform','table','rbac.plan_limits',null,'architecture.md §3'),
('research-platform','table','rbac.plans',null,'architecture.md §3'),
('research-platform','table','rbac.resource_kinds',null,'architecture.md §3'),
('research-platform','table','rbac.scope_aliases',null,'architecture.md §2'),
('research-platform','table','rbac.usage_ledger',null,'architecture.md §3'),
('research-platform','table','research.argument_edges',null,'architecture.md §4'),
('research-platform','table','research.citations',null,'architecture.md §4'),
('research-platform','table','research.claims',null,'architecture.md §4'),
('research-platform','table','research.endorsements',null,'architecture.md §6'),
('research-platform','table','research.endorsement_claims',null,'specs/tables/schema.md §5: the exact claims an endorsement checked, readable with the revision (REM-154)'),
('research-platform','table','research.endorsement_withdrawals',null,'specs/tables/schema.md §5: each withdrawal as its own event, readable with the endorsement (REM-154)'),
('research-platform','table','research.heads',null,'architecture.md §4'),
('research-platform','table','research.exposures',null,'authoring-and-publication.md §4: the exact revisions anybody who may read the work may read'),
('research-platform','table','research.operations',null,'architecture.md §4'),
('research-platform','table','research.revisions',null,'architecture.md §4'),
('research-platform','table','research.sources',null,'architecture.md §4'),
('research-platform','table','content.resource_snapshots',null,'specs/tables/schema.md §4: an exact capture, readable exactly when its resource is (REM-153)'),
('research-platform','table','research.revision_files',null,'specs/tables/schema.md §2, §4: an artifact''s pinned capture, readable with its revision (REM-153)'),
('research-platform','table','research.works',null,'architecture.md §4'),
('user-rbac','function','rbac.refresh_session','text,text','spec.md §4.3: refresh token rotation'),
('user-rbac','function','rbac.revoke_session','uuid','spec.md §4.3: sign out one device'),
('user-rbac','function','rbac.revoke_all_sessions','','spec.md §4.3: sign out everywhere, the control that matters after a leak'),
('workflow-engine','function','workflow.cancel_run','uuid','spec.md §4: a caller stops their own run'),
('workflow-engine','function','workflow.signal_task','uuid,text,jsonb','§16: the human-in-the-loop path -- a task waits for a signal from outside'),
('workflow-engine','function','workflow.drain_sql_steps','uuid,integer','the in-database executor, so a pure-SQL workflow needs no worker at all'),
('workflow-engine','function','workflow.p8ql','text','USAGE.md: the query entry point'),
('workflow-engine','function','workflow.p8ql','text,jsonb','the same entry point with a caller-supplied embedding'),

-- ---------- registrations the docs depend on ---------------------------
('cross','registration','lexical:chunks',null,'USAGE.md tells readers TEXT searches "chunks"'),
('cross','registration','semantic:chunks',null,'USAGE.md tells readers SEMANTIC searches "chunks"'),
('cross','registration','step:p8ql',null,'YAML.md: p8ql: steps must resolve'),
('cross','registration','step:record_chunks',null,'ingestion pipeline is declarative'),
('cross','registration','entity:document',null,'integration.sql: resources become graph nodes'),

-- ---------- the published contract (specs/contract) ---------------------
-- What this database admits, published BY the database. Declared here because
-- the whole point of it is that a client does not need percolate-core -- or any
-- other service instance -- to learn what a column accepts, and a contract that
-- silently stopped shipping would return the collection to exactly the state
-- this schema was added to end.
('cross','schema','percolate',null,'contract/schema.sql: the contract namespace'),
('cross','table','percolate.types',null,'contract/schema.sql: payload shapes a jsonb column cannot carry in the catalog'),
('cross','function','percolate.enums','','contract/schema.sql: every closed vocabulary, derived from the catalog at call time'),
('cross','function','percolate.contract','','contract/schema.sql: enums and types as one document, which is what a client fetches');

-- ============================================================
-- Check each expectation against the catalog.
-- ============================================================
create temporary view surface as
select e.*,
  case e.kind
    when 'extension' then exists (select 1 from pg_extension where extname = e.name)
    when 'schema'    then exists (select 1 from pg_namespace where nspname = e.name)
    when 'table'     then to_regclass(e.name) is not null
    -- Views were not a kind until §23 declared one. to_regclass would have
    -- accepted a view under 'table', which is why the case is separate: an
    -- audit that cannot tell a view from a table cannot notice a view being
    -- replaced by a table, or the reverse.
    when 'view'      then exists (
        select 1 from pg_views
        where schemaname = split_part(e.name, '.', 1)
          and viewname   = split_part(e.name, '.', 2))
    when 'function'  then to_regprocedure(e.name || '(' || coalesce(e.detail,'') || ')') is not null
    -- schema.table.column. Added for workflow.tasks.matrix_parent_id: a
    -- capability can also be a column, and a table check passes happily on a
    -- table that is missing the one field the spec sentence is about.
    when 'column'    then exists (
        select 1 from information_schema.columns c
        where c.table_schema = split_part(e.name, '.', 1)
          and c.table_name   = split_part(e.name, '.', 2)
          and c.column_name  = split_part(e.name, '.', 3))
    -- Two kinds that check DATA, not catalog. Everything else in this file
    -- asks whether a capability exists; these ask whether the sample that
    -- demonstrates it was actually installed, because a subsystem whose only
    -- worked example lives in somebody's shell is the exact failure
    -- dev/init/02-seed.sql's header describes.
    -- A YAML feature is not a catalog object: it is a claim about the compiled
    -- PARSER, which ships as a separate .so and can be a release behind the
    -- SQL it is supposed to author. schema.sql §22c is that failure -- a
    -- `matrix:` step that YAML.md documented in full and the installed
    -- compiler refused as bad syntax -- and the fix for the class was to probe
    -- the compiler instead of guessing. This asks the probe.
    when 'yaml_feature' then coalesce(
        (workflow.compiler_capabilities() #>> array['accepts', e.name])::boolean, false)
    when 'agent'       then exists (select 1 from agentic.agents where name = e.name)
    -- A skill row, and -- the part that matters -- one with a BODY. An empty
    -- `content` is a fragment that installs, resolves, composes and says
    -- nothing, which no catalog check would notice.
    when 'skill'       then exists (select 1 from agentic.skills
                                     where name = e.name and length(content) > 0)
    -- The other half of the refactor: the rows exist AND the agent carries
    -- them. Either alone is the half-installed state.
    when 'skill_binding' then exists (select 1 from agentic.agents a
                                       where a.name = e.name
                                         and cardinality(a.skills) >= 3)
    when 'tool_server' then exists (select 1 from agentic.tool_servers where name = e.name)
    -- A registered entity type with no nodes is a registration nobody ran, so
    -- the check is on the projected rows, not on the registry row.
    when 'entity_type' then exists (select 1 from aiq.entity_registry r
                                     where r.entity_type = e.name)
                        and exists (select 1 from aiq.nodes n
                                     where n.entity_type = e.name)
    when 'graph_example' then exists (select 1 from aiq.schema_examples
                                       where facet = e.name)
    -- Registered AND populated. The registration alone is what passed while
    -- the corpus behind it was empty.
    when 'corpus' then exists (select 1 from aiq.lexical_sources where name = e.name)
                   and exists (select 1 from aiq.semantic_sources where name = e.name)
                   and (select count(*) from content.resource_chunks) > 0
    -- The registry row AND the generated storage table it promises.
    when 'embedding_space' then exists (select 1 from aiq.embedding_models where name = e.name)
                            and to_regclass('aiq.emb_' || replace(e.name,'-','_')) is not null
    -- PG19 puts property graphs in pg_class with their own relkind ('g'),
    -- which is why they cannot be found by the 'table' branch above.
    when 'property_graph' then exists (
        select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = split_part(e.name, '.', 1)
          and c.relname = split_part(e.name, '.', 2)
          and c.relkind = 'g')
    -- A channel is a row, and this one has to be both present and INERT: an
    -- ingest_workflow on the artifacts channel would start an ingestion run
    -- every time a step offloaded its output. Checking existence alone would
    -- pass on the configuration that breaks it.
    when 'channel' then exists (
        select 1 from content.channels
        where name = e.name and not (config ? 'ingest_workflow'))
    when 'registration' then case split_part(e.name, ':', 1)
        when 'lexical'  then exists (select 1 from aiq.lexical_sources  where name = split_part(e.name,':',2))
        when 'semantic' then exists (select 1 from aiq.semantic_sources where name = split_part(e.name,':',2))
        when 'step'     then exists (select 1 from workflow.step_functions where name = split_part(e.name,':',2))
        when 'entity'   then exists (select 1 from aiq.entity_registry where entity_type = split_part(e.name,':',2))
        else false end
    else false
  end as present
from expected e;

\echo
\echo '=== SURFACE BY SUBSYSTEM ==='
select subsystem,
       count(*) as declared,
       count(*) filter (where present) as present,
       count(*) filter (where not present) as missing
from surface group by subsystem order by subsystem;

\echo
\echo '=== MISSING (each one is a promise the specs make and the database does not keep) ==='
select subsystem, kind, name, coalesce(detail,'') as signature, why
from surface where not present order by subsystem, kind, name;

\echo
do $$
declare v_missing int;
begin
    select count(*) into v_missing from surface where not present;
    if v_missing > 0 then
        insert into surface_failures (check_name, detail) values (
            'SURFACE INCOMPLETE',
            format('%s of %s declared capabilities are missing. Each is a spec '
                   'promise with nothing behind it.',
                   v_missing, (select count(*) from surface)));
    else
        raise notice 'SURFACE COMPLETE: all % declared capabilities present',
            (select count(*) from surface);
    end if;
end $$;


-- ============================================================
-- THE ROUND TRIP
--
-- Everything above asks whether a capability EXISTS. This asks a different
-- question, and it is the one that would have caught the most defects per line
-- of any check in this repository: **can every column of a table be written
-- through the documented write path, and read back through the documented read
-- path?**
--
-- The failure it exists to prevent has happened four times, always the same way
-- and never noisily. A column is added to a table -- `audience`, `category`,
-- `tags`, `default_headers` -- and the `upsert_*` function that is the only
-- supported way to write that table is not updated, nor is the `*_api` view
-- that is the only supported way to read it. Nothing breaks. The column exists,
-- the tests pass, and the audit above is satisfied because the TABLE is
-- present. And then:
--
--   * an agent authored as user-facing is accepted, reported as created, and
--     silently stored as `internal` -- invisible in the one view a client picks
--     from, because upsert_agent could not express the column;
--   * a tool server is registered with the header that selects its OpenAPI
--     document, the runtime reading tool_servers_api cannot see it, and
--     discovery binds the wrong schema and looks correct.
--
-- Both were found by a person using the system, long after the column landed.
-- Both are decidable from the catalog in milliseconds.
--
-- The rule: every column is IN the contract, or is DECLARED as deliberately
-- outside it with a reason. There is no third state. Adding a column therefore
-- forces a decision about its contract, instead of defaulting to "invisible and
-- unwritable" -- which is the state that produced every one of these.
-- ============================================================

create temporary table api_exclusions (
    api_view    text,
    column_name text,
    -- CONSTRAINED, because the whole file below turns on this word matching.
    --
    -- The leak check is `where in_view and kind = 'secret'`, and it is the one
    -- assertion here that reports a breach rather than a gap. Spelled
    -- 'secrets', 'Secret' or 'credential', a genuinely leaked secret falls
    -- through to the `when in_view then 'STALE EXCLUSION'` arm, v_leak counts
    -- zero, and the SECRET EXPOSED exception never fires -- the run still
    -- fails, but as "ROUND TRIP INCOMPLETE ... declare it excluded with a
    -- reason", which reads as bookkeeping.
    --
    -- One character, downgrading this file's loudest security assertion into a
    -- housekeeping notice, in the file whose entire job is to stop a promise
    -- being made with nothing checking it. Found by dev/vocab-audit.py.
    kind        text check (kind in ('secret', 'internal')),
    why         text
);

-- `secret` is not a stronger `internal`. It is a different assertion, checked
-- in the opposite direction: an internal column merely MAY not appear, while a
-- secret column MUST NOT -- and the check below fails loudly if one ever does.
-- These four are the reason the distinction is worth carrying.
insert into api_exclusions (api_view, column_name, kind, why) values
-- BACKUP BOOKKEEPING, NOT CONTENT. `shipped` says whether the extension's own
-- install created this definition, so that pg_extension_config_dump can carry
-- a deployment's workflows into a dump and leave the shipped ones to be
-- re-seeded by CREATE EXTENSION on restore. It is set by a column default
-- reading `percolate.seeding` and by nothing a caller can reach; exposing it
-- through the API would invite somebody to set it, and a deployment row marked
-- shipped is a row that silently never gets backed up again.
('workflow.definitions_api', 'shipped', 'internal', 'backup bookkeeping: which rows CREATE EXTENSION re-seeds, set by the install, not content'),
('rbac.orgs_api',            'shipped', 'internal', 'backup bookkeeping: true for the shared org the install seeds, set by the install, not content'),
('rbac.users_api',          'password_hash', 'secret', 'a bcrypt hash still enables offline attack; verification stays server-side'),
('rbac.users_api',          'mfa_secret',    'secret', 'the TOTP seed IS the second factor'),
('rbac.api_keys_api',       'key_hash',      'secret', 'the stored half of a credential'),
('rbac.refresh_tokens_api', 'token_hash',    'secret', 'the stored half of a credential'),

('rbac.refresh_tokens_api', 'replaced_by', 'internal', 'rotation chain, internal to refresh'),
('aiq.edges_api',           'provenance',  'internal', 'authoring metadata, not part of the read contract'),
-- The usage counters. Excluded deliberately and for two reasons rather than
-- one. They are consolidation's input, not a fact about the relationship: a
-- caller asking what connects to what does not need to know how often anyone
-- else asked. And publishing them would publish a usage pattern, which is a
-- read nobody requested about the people doing the reading.
('aiq.edges_api', 'recall_count',     'internal', 'how often a real question traversed this edge; consolidation input, and publishing it publishes a usage pattern'),
('aiq.edges_api', 'probe_count',      'internal', 'the same for the system testing itself, counted separately so usage-based consolidation does not consolidate around its own monitoring'),
('aiq.edges_api', 'last_recalled_at', 'internal', 'recency of the above; same argument'),

-- updated_at is excluded everywhere it exists. Listed per view rather than
-- pattern-matched on the name: a rule with an unwritten exception is how the
-- next column gets excluded by accident, which is the whole subject here.
('agentic.agents_api',       'updated_at', 'internal', 'mutation timestamp, not contract'),
('agentic.runs_api',         'updated_at', 'internal', 'mutation timestamp, not contract'),
('agentic.sessions_api',     'updated_at', 'internal', 'mutation timestamp, not contract'),
('agentic.tool_servers_api', 'updated_at', 'internal', 'mutation timestamp, not contract'),
-- The lexical index itself, not a fact about the skill. A caller ranks by
-- calling aiq.lexical or aiq.search; handing them the tsvector would be
-- publishing the index and inviting somebody to rank in application code.
('agentic.skills_api', 'search_tsv', 'internal', 'the generated lexical index; TEXT mode is the read path, not the vector'),

-- definitions_api publishes the CATALOGUE and not the bodies, and the REASON
-- for excluding `spec` has changed even though the exclusion has not. It used
-- to be that workflow.definitions carried no owner_id, no org_id and no RLS,
-- so a column in this view was a column every tenant read. The table adopts
-- scope now (REM-91), and this view is owned by api_viewer rather than by the
-- table owner, so a policy decides what it returns -- the old reason is gone.
--
-- What is left is that nothing asks for the body, and that the two directions
-- do not cost the same: `create or replace view` may only APPEND, so a column
-- added here can be withdrawn only by dropping the view on every deployment.
-- Names, versions, the derived shape and now the scope columns are what
-- listing and labelling need. `spec` goes in the day a screen needs it.
('workflow.definitions_api', 'spec',       'internal', 'the workflow body; nothing reads it, and a view column is easier to add than to withdraw -- the derived step_count/step_kinds/queues are the published shape'),
('workflow.definitions_api', 'deleted_at', 'internal', 'the view IS where deleted_at is null; a soft-delete tombstone is not a fact about a live definition'),

-- task_events records the transition. input_snapshot is what the engine held
-- at the moment of it, kept for replay, and it is the same argument as
-- tasks_api.input above: an input may carry the target of a resolved
-- credential_ref, and the OUTPUT is the contract.
('workflow.task_events_api', 'input_snapshot', 'internal', 'replay state; may carry a resolved credential target, same as tasks_api.input'),

('workflow.runs_api', 'parent_task_id',   'internal', 'engine linkage; the parent/child relation is served by run_meta'),
('workflow.runs_api', 'cancel_requested', 'internal', 'engine flag; cancellation is an action, not a field to poll'),

-- tasks_api is the state a caller may see; everything else is the state machine.
('workflow.tasks_api', 'pending_deps',          'internal', 'scheduler bookkeeping'),
('workflow.tasks_api', 'claimed_by',            'internal', 'lease holder'),
('workflow.tasks_api', 'claimed_at',            'internal', 'lease start'),
('workflow.tasks_api', 'heartbeat_at',          'internal', 'lease liveness'),
('workflow.tasks_api', 'cancel_requested',      'internal', 'engine flag'),
('workflow.tasks_api', 'idempotency_key',       'internal', 'dedupe key'),
('workflow.tasks_api', 'rate_key',              'internal', 'rate-limit bucket'),
('workflow.tasks_api', 'input',                 'internal', 'may carry the target of a resolved credential_ref; the OUTPUT is the contract'),
('workflow.tasks_api', 'wait_signal',           'internal', 'the signal name a task blocks on'),
('workflow.tasks_api', 'child_run_id',          'internal', 'sub-workflow linkage'),
('workflow.tasks_api', 'saga_group',            'internal', 'compensation grouping'),
('workflow.tasks_api', 'compensation_task_key', 'internal', 'compensation target'),
('workflow.tasks_api', 'compensated_at',        'internal', 'compensation bookkeeping'),
('workflow.tasks_api', 'compensates_task_id',   'internal', 'compensation linkage'),
('workflow.tasks_api', 'decision_output_hash',  'internal', 'replay guard'),
('workflow.tasks_api', 'matrix_parent_id',      'internal', 'fan-out linkage'),
('workflow.tasks_api', 'tolerate_failure',      'internal', 'engine flag');

-- ------------------------------------------------------------
-- (a) READ: every table column is in its *_api view, or declared out of it.
-- ------------------------------------------------------------
create temporary view read_contract as
select v.schemaname || '.' || v.viewname as api_view,
       c.column_name,
       exists (select 1 from information_schema.columns vc
                where vc.table_schema = v.schemaname
                  and vc.table_name   = v.viewname
                  and vc.column_name  = c.column_name) as in_view,
       x.kind, x.why
  from pg_views v
  join information_schema.columns c
    on c.table_schema = v.schemaname
   and c.table_name   = left(v.viewname, length(v.viewname) - 4)
  left join api_exclusions x
    on x.api_view    = v.schemaname || '.' || v.viewname
   and x.column_name = c.column_name
 where v.viewname like '%\_api'
   and v.schemaname in (select percolate.extension_schemas());

\echo
\echo '=== ROUND TRIP: READ PATH ==='
select case when in_view and kind = 'secret'  then 'LEAKED SECRET'
            when in_view                      then 'STALE EXCLUSION'
            else 'UNDECLARED' end as problem,
       api_view, column_name,
       coalesce(why, '(no decision recorded -- add it to the view, or declare it out)') as note
from read_contract
where (not in_view and kind is null) or (in_view and kind is not null)
order by 1, 2, 3;

-- ------------------------------------------------------------
-- (b) WRITE: every table column is settable through its upsert_* function.
--
-- Checked by reading the function body for the jsonb key, which is crude and is
-- the honest amount of rigour available here: the documented write path IS
-- `p_spec->>'<column>'`, so the column name appearing as a key in the source is
-- the contract. A false PASS would take someone naming a column in a comment
-- and not implementing it; a false FAILURE cannot happen.
-- ------------------------------------------------------------
create temporary table write_paths (tbl text, fn text, unsettable text[], why text);
insert into write_paths values
('agentic.agents', 'agentic.upsert_agent',
 '{id,created_at,updated_at}',
 'identity and timestamps are the database''s to assign, never the author''s'),
('agentic.tool_servers', 'agentic.upsert_tool_server',
 '{id,created_at,updated_at,synced_at}',
 'synced_at is stamped BY the sync, from the presence of cached_tools -- an author setting it would be claiming a fetch that never happened'),
('agentic.skills', 'agentic.upsert_skill',
 '{id,created_at,updated_at,version,discovery_text,search_tsv}',
 'version is BUMPED by the function when the text changes, which is the point of having one -- an author setting it could claim an edit did not happen; discovery_text and search_tsv are generated from the three columns beside them, which is what stops the indexed text and the read text from drifting'),
('agentic.plugins', 'agentic.apply_plugin',
 '{installed_at,updated_at,manifest}',
 'the manifest is the document itself, not a key inside it -- apply_plugin stores what it was handed, which is what makes a later re-apply diffable');

create temporary view write_contract as
select w.fn, c.column_name,
       -- The parameter is `p_spec` on the upsert_* functions and `p_manifest`
       -- on apply_plugin, because a plugin document is not a row spec. The
       -- contract being checked is "the function names this column as a key",
       -- which the parameter's name has nothing to do with -- so the pattern
       -- accepts either rather than the write path being renamed to suit the
       -- audit.
       coalesce(p.prosrc ~ ('p_(spec|manifest)\s*->>?\s*''' || c.column_name || ''''), false) as settable,
       c.column_name = any(w.unsettable) as declared_out,
       w.why
  from write_paths w
  join information_schema.columns c
    on c.table_schema = split_part(w.tbl, '.', 1)
   and c.table_name   = split_part(w.tbl, '.', 2)
  join pg_proc p
    on p.proname     = split_part(w.fn, '.', 2)
   and p.pronamespace = split_part(w.fn, '.', 1)::regnamespace;

\echo
\echo '=== ROUND TRIP: WRITE PATH ==='
select case when settable then 'STALE EXCLUSION' else 'UNWRITABLE' end as problem,
       fn, column_name,
       case when settable then why
            else 'the only supported way to write this table cannot set this column' end as note
from write_contract
where (not settable and not declared_out) or (settable and declared_out)
order by 1, 2, 3;

\echo
do $$
declare v_read int; v_write int; v_leak int;
begin
    select count(*) into v_read from read_contract
     where (not in_view and kind is null) or (in_view and kind is not null);
    select count(*) into v_leak from read_contract where in_view and kind = 'secret';
    select count(*) into v_write from write_contract
     where (not settable and not declared_out) or (settable and declared_out);

    -- BOTH, not the first of the two. A leak and a gap are independent
    -- findings and a database can have one of each; raising on the leak used
    -- to mean the round trip was never counted.
    if v_leak > 0 then
        insert into surface_failures (check_name, detail) values (
            'SECRET EXPOSED',
            format('%s column(s) declared as secrets are readable through an *_api '
                   'view. This is the one failure in this file that is a breach '
                   'rather than a gap.', v_leak));
    end if;

    if v_read + v_write > 0 then
        insert into surface_failures (check_name, detail) values (
            'ROUND TRIP INCOMPLETE',
            format('%s column(s) sit outside the read contract and %s outside the '
                   'write contract with no decision recorded. Put the column in the '
                   'view or the function, or declare it excluded with a reason -- '
                   'silently unreachable is the state this check exists to end.',
                   v_read, v_write));
    end if;

    raise notice
        'ROUND TRIP COMPLETE: every column of every table with a documented read or '
        'write path is in that contract or declared out of it (% read exclusions, of '
        'which % are secrets; % write exclusions)',
        (select count(*) from api_exclusions),
        (select count(*) from api_exclusions where kind = 'secret'),
        (select sum(coalesce(array_length(unsettable, 1), 0)) from write_paths);
end $$;


-- ============================================================
-- THE CLOSING DIRECTION
--
-- Everything above runs one way: each capability this file DECLARES is checked
-- against the catalog. Nothing ran the other way, and a one-way ratchet on an
-- inventory is barely a ratchet at all -- it keeps the list from naming things
-- that do not exist, and says nothing about things that exist and are not
-- named. Adding a view is how a surface gets built; adding a line here is a
-- separate act somebody has to remember. Those two facts together are the
-- definition of drift.
--
-- It had drifted. Thirteen of the fifteen *_api views -- every URL PostgREST
-- publishes for agentic, aiq, and rbac, including the two over the tables
-- holding API keys and refresh tokens -- were absent, along with twenty-one
-- functions a logged-in caller may execute. The audit read as complete
-- throughout, because a list only ever answers the question you ask it.
--
-- So this asks the catalog what is REACHABLE and requires each answer to be
-- declared. Reachability is the right test rather than "every view" or "every
-- function": app_owner and worker are infrastructure identities whose
-- authorization IS the grant, and holding them to an external contract would
-- mean writing down the entire schema. What `authenticated` and `web_anon` can
-- touch is, exactly, what a stranger can touch.
--
-- Declaring one costs a line and a reason. That reason is the actual product
-- here -- a surface nobody can write a sentence justifying is a surface that
-- probably should not be granted.
-- ============================================================

create temporary view reachable as
with caller as (select unnest(array['authenticated','web_anon']) as r)
-- RELATIONS: every table, view and materialised view an application role can
-- SELECT, not only the ones named `%_api`.
--
-- That name filter was this check's own blind spot, and it is the recurring
-- class meta/postmortems/README.md calls "a check that walks only the
-- configured cases has a hole shaped like the thing it is for". Adding a view
-- called `<x>_api` is how a surface gets published, so the filter described
-- how surfaces were EXPECTED to appear rather than what a caller can reach --
-- and six tables sat outside it, among them rbac.roles and
-- rbac.role_permissions, readable by every authenticated user with no RLS.
-- None of them was a breach. The gate not being able to SEE them was, because
-- the next one might be.
--
-- The same hole was open one level up, in which SCHEMAS the two arms walked:
-- each typed its own list, the function arm's lacked `percolate` while the
-- relation arm's had it, and both named `trace`, which does not ship. Both read
-- percolate.extension_schemas() now (REM-45).
select case c.relkind when 'v' then 'view' when 'm' then 'view' else 'table' end as kind,
       n.nspname || '.' || c.relname as name
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r','p','v','m')
   and n.nspname in (select percolate.extension_schemas())
   and exists (select 1 from caller where has_table_privilege(caller.r, c.oid, 'select'))
union
select 'function', n.nspname || '.' || p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in (select percolate.extension_schemas())
   and exists (select 1 from caller where has_function_privilege(caller.r, p.oid, 'execute'));

\echo
\echo '=== REACHABLE BUT UNDECLARED (a stranger can call it and this file does not say why) ==='
-- A DECLARED FAMILY, for surfaces that are created at RUNTIME and therefore
-- cannot appear in a static list. `aiq.emb_<model>` is built by
-- register_embedding_space when somebody registers a model, so the set is not
-- knowable when this file is written -- and a static inventory that cannot
-- express that has a permanent blind spot rather than a gap.
--
-- A pattern still has to carry its reason, which is the whole discipline: the
-- sentence is the product. What it does NOT settle is whether the grant is
-- right, and for this family that is an open question worth asking out loud:
-- these tables hold raw vectors derived from content the caller may not be
-- entitled to read, and retrieval goes through aiq.semantic_in (SECURITY
-- DEFINER) rather than through the table. If nothing needs the direct grant,
-- the better fix is to revoke it and delete this row.
create temporary table reachable_families (pattern text, kind text, why text);
insert into reachable_families values
 ('^aiq\.emb_', 'table',
  'an embedding space, created per registered model by aiq.register_embedding_space -- a runtime surface a static list cannot name. OPEN: whether authenticated should hold SELECT on raw vectors at all, given retrieval goes through aiq.semantic_in');

select r.kind, r.name
  from reachable r
 where not exists (select 1 from expected e where lower(e.name) = r.name and e.kind = r.kind)
   and not exists (select 1 from reachable_families f
                    where f.kind = r.kind and r.name ~ f.pattern)
 order by r.kind, r.name;

do $$
declare v_undeclared int; v_reachable int;
begin
    select count(*) into v_undeclared
      from reachable r
     where not exists (select 1 from expected e where lower(e.name) = r.name and e.kind = r.kind)
       and not exists (select 1 from reachable_families f
                        where f.kind = r.kind and r.name ~ f.pattern);
    select count(*) into v_reachable from reachable;

    if v_undeclared > 0 then
        insert into surface_failures (check_name, detail) values (
            'SURFACE UNDECLARED',
            format('%s of %s reachable objects are callable by `authenticated` or '
                   '`web_anon` and appear nowhere in this file. Either declare each '
                   'one with the reason it is exposed, or revoke the grant -- an '
                   'external surface nobody wrote a sentence for is the shape every '
                   'drift defect starts as.', v_undeclared, v_reachable));
    else
        raise notice
            'SURFACE CLOSED: all % objects a caller role can reach are declared here',
            v_reachable;
    end if;
end $$;


-- ============================================================
-- THE ONE PLACE THIS FILE FAILS.
--
-- Everything above records; this raises. So a run reports every red surface,
-- and the exit code is still non-zero for `dev/check.sh` -- which is the half
-- that matters, because a gate that reports well and exits 0 is not a gate.
--
-- The detail lines are printed before the raise as well as named in it: RAISE
-- truncates nothing, but a five-line message inside a psql error block is
-- harder to read than five notices, and `run_gate` greps for the word FAILED.
-- ============================================================
do $$
declare
    r record;
    v_n int;
begin
    select count(*) into v_n from surface_failures;
    if v_n = 0 then
        raise notice 'SURFACE: every check in this file passed';
        return;
    end if;

    for r in select check_name, detail from surface_failures order by seq loop
        raise warning 'FAILED -- %: %', r.check_name, r.detail;
    end loop;

    raise exception
        'SURFACE AUDIT FAILED: % of this file''s checks are red (%). Every one is '
        'named in the warnings above -- fix them together rather than one per run.',
        v_n, (select string_agg(check_name, ', ' order by seq) from surface_failures);
end $$;
