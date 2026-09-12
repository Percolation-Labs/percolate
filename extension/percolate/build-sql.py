#!/usr/bin/env python3
"""Assemble specs/*/*.sql into percolate--<version>.sql.

The specs are the source of truth; this is the only place their ORDER lives.

    python3 extension/percolate/build-sql.py

Generated rather than hand-maintained because the schema files are what get
reviewed, tested and reasoned about, and a hand-copied extension script would
be a second copy to drift. This collection has already been bitten by exactly
that: the dev harness reimplemented the installer and fell three files behind.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def check_single_definition(path, text):
    """Refuse to build a spec file that defines the same function twice.

    schema.sql grew by appending: each fix was written next to the failure that
    produced it, as `create or replace`, which meant the file accumulated
    superseded bodies that never executed -- 1,013 dead lines and seventeen
    functions with two to five definitions each. Behaviour stayed correct
    because the last definition wins, and that is exactly what made it
    dangerous: a maintainer fixing a bug has no way to tell which copy is live,
    and a fix applied to a superseded one is silently a no-op.

    Signature-aware, because two arities of one name are two functions.
    """
    sigs = {}
    for m in re.finditer(
            r'^create or replace function\s+([a-z_]+\.[a-z_]+)\s*\(([^)]*)\)',
            text, re.M | re.S):
        name, args = m.group(1), m.group(2)
        types = []
        for a in args.split(','):
            a = re.sub(r'\s+default\s+.*$', '', a.strip(), flags=re.I)
            if a:
                parts = a.split()
                types.append(parts[-1] if len(parts) > 1 else a)
        sig = f"{name}({','.join(types)})"
        sigs.setdefault(sig, []).append(text[:m.start()].count('\n') + 1)
    dupes = {k: v for k, v in sigs.items() if len(v) > 1}
    if dupes:
        detail = "; ".join(f"{k} at lines {v}" for k, v in sorted(dupes.items()))
        raise SystemExit(
            f"{path}: a function is defined more than once -- {detail}.\n"
            "Only the last definition runs. Keep one body, at the point it is first "
            "needed, and let the later section explain why it has that shape.")
    return set(sigs)

def _live_spans(text):
    """Offsets of text that is NOT a comment, a dollar-quoted body or a string.

    Every check below reads DDL, and these files are two-thirds prose: the
    phrase `create table` appears in comments explaining tables, and inside
    plpgsql bodies that build DDL dynamically. A check that cannot tell those
    apart reports failures nobody can act on, and gets switched off.
    """
    i, n, out, seg = 0, len(text), [], 0
    while i < n:
        if text.startswith('--', i):
            j = text.find('\n', i); j = n if j < 0 else j
            out.append((seg, i)); seg = j; i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i); j = n if j < 0 else j + 2
            out.append((seg, i)); seg = j; i = j
        elif text[i] == '$':
            m = re.match(r'\$[A-Za-z_]*\$', text[i:])
            if m:
                tag = m.group(0)
                j = text.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                out.append((seg, i)); seg = j; i = j
            else:
                i += 1
        elif text[i] == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2; continue
                    j += 1; break
                j += 1
            i = j
        else:
            i += 1
    out.append((seg, n))
    return out


_IDEMPOTENCY_RULES = [
    (re.compile(r'^[ \t]*create[ \t]+table[ \t]+(?!if[ \t]+not[ \t]+exists)', re.I | re.M),
     "create table -> create table if not exists"),
    (re.compile(r'^[ \t]*create[ \t]+(unique[ \t]+)?index[ \t]+if[ \t]+not[ \t]+exists[ \t]+on[ \t]', re.I | re.M),
     "an anonymous index cannot take IF NOT EXISTS -- give it the name Postgres "
     "would have generated (<table>_<cols>_idx), so an existing database adopts "
     "the index it already has instead of growing a second one"),
    (re.compile(r'^[ \t]*create[ \t]+(unique[ \t]+)?index[ \t]+(?!if[ \t]+not[ \t]+exists|concurrently)', re.I | re.M),
     "create index -> create index if not exists <name>"),
    (re.compile(r'^[ \t]*create[ \t]+view[ \t]', re.I | re.M),
     "create view -> create or replace view"),
    (re.compile(r'^[ \t]*create[ \t]+trigger[ \t]', re.I | re.M),
     "create trigger -> create or replace trigger (PG14+)"),
    (re.compile(r'^[ \t]*create[ \t]+schema[ \t]+(?!if[ \t]+not[ \t]+exists)', re.I | re.M),
     "create schema -> create schema if not exists"),
]


def check_idempotent(path, text):
    """Refuse a statement that would fail on a database that already has it.

    THE UPGRADE SCRIPT IS THIS BODY, REPLAYED. `percolate--<old>--<new>.sql` is
    generated as a copy of the whole schema, so `ALTER EXTENSION percolate
    UPDATE` converges an older database to this one -- which works only while
    every statement here can run twice. That property is worth more than it
    looks: the update runs as `app_owner`, so ownership and every RLS policy
    survive it, where the dump-and-restore it replaces is exactly where a
    superuser-owned restore leaves every policy inert.

    Enforced rather than remembered, because the failure is invisible until
    somebody upgrades. Verified once by diffing an upgraded database against a
    fresh install of the same version: 629 objects, identical.
    """
    spans = _live_spans(text)

    def live(i):
        return any(a <= i < b for a, b in spans)

    bad = []
    for pat, remedy in _IDEMPOTENCY_RULES:
        for m in pat.finditer(text):
            if live(m.start()):
                bad.append((text[:m.start()].count("\n") + 1, remedy))

    # A policy and a constraint have neither OR REPLACE nor IF NOT EXISTS, so
    # each has to be preceded by a drop of its own name.
    for pat, kind, drop in [
        (re.compile(r'^[ \t]*create[ \t]+policy[ \t]+([\w]+)', re.I | re.M),
         "policy", "drop policy if exists {} "),
        (re.compile(r'add[ \t]+constraint[ \t]+([\w]+)', re.I),
         "constraint", "drop constraint if exists {}"),
        # PG19 accepts `drop property graph if exists` and has no
        # `create ... if not exists`, so this is the only idempotent spelling.
        (re.compile(r'^[ \t]*create[ \t]+property[ \t]+graph[ \t]+([\w.]+)', re.I | re.M),
         "property graph", "drop property graph if exists {};"),
    ]:
        for m in pat.finditer(text):
            if not live(m.start()):
                continue
            name = m.group(1)
            if not re.search(drop.format(re.escape(name)), text, re.I):
                bad.append((text[:m.start()].count("\n") + 1,
                            kind + " " + name + " is created without being dropped "
                            "first -- add `" + drop.format(name).strip() + "` before it"))

    if bad:
        detail = "\n".join("  " + str(path) + ":" + str(ln) + "  " + why
                           for ln, why in sorted(bad))
        raise SystemExit(
            str(path) + ": " + str(len(bad)) + " statement(s) cannot be applied "
            "twice, so the generated upgrade script would fail on any existing "
            "database:\n" + detail +
            "\nThe schema is replayed to upgrade it -- see write_upgrades().")


def check_raise_format(path, text):
    """Refuse a RAISE whose message uses a specifier only format() understands.

    plpgsql's RAISE knows exactly one placeholder -- `%` -- and prints anything
    after it literally. `%L` therefore emits the value followed by the letter L,
    which is how `register_embedding_space(no-space4L)` reached a user-facing
    error message. Twice, in one session, by the same author, which is the
    argument for checking it here rather than remembering it.

    `%s` and `%d` are checked for the same reason, and were added after this
    check watched one go past: a message telling the reader to run
    `enable_graph_algorithms(''%s'')` printed `enable_graph_algorithms
    ('authenticateds')`. The C-shaped spelling is the one a writer reaches for
    without thinking, so it is the one most worth refusing.

    Only inside RAISE: all four are correct and necessary in format().
    """
    bad = []
    for m in re.finditer(r'raise\s+(?:exception|warning|notice)\b(.*?);', text,
                         re.S | re.I):
        body = re.sub(r'format\s*\(.*?\)', '', m.group(1), flags=re.S)
        hit = re.search(r'%[LIsd]\b', body)
        if hit:
            bad.append((text[:m.start()].count('\n') + 1, hit.group(0)))
    if bad:
        detail = "; ".join(f"{spec} at line {line}" for line, spec in bad)
        raise SystemExit(
            f"{path}: a RAISE message uses a format()-only specifier -- {detail}.\n"
            "RAISE has one placeholder, `%`; anything after it is literal text, so "
            "`%L` prints the value and then an L, and `%s` prints it and then an s. "
            "Drop the letter, and quote it yourself if you need quotes: ''%''.")


# The version is NOT declared here. `percolate.control` is where Postgres
# itself looks to answer "what version is this extension", so a second copy in
# this file would be a second answer -- and the one that loses is whichever the
# release tooling forgot. Read it, do not restate it.
def _version() -> str:
    control = ROOT / "extension/percolate/percolate.control"
    m = re.search(r"^default_version\s*=\s*'([^']+)'", control.read_text(), re.M)
    if not m:
        raise SystemExit(f"{control}: no default_version to build against")
    return m.group(1)


VERSION = _version()

# Not arbitrary: the two cores are MUTUALLY dependent (rbac.attempt_login needs
# workflow.rate_limits; workflow.runs' RLS needs rbac.current_user_id), a real
# cycle -- so the acyclic cores come first in either order, and everything
# crossing a boundary follows.
ORDER = [
    ("identity/schema.sql",                     "percolate.uuidv5() and the two registries (what a NULL means, what kind of thing a table is). FIRST, because shipped code calls uuidv5 -- workflow.run_meta derives a session id and a `language sql` body resolves its references at create time. It creates the `percolate` schema itself; contract/schema.sql's `create schema if not exists` is idempotent behind it. An earlier draft put this last, on a rationale about vocabularies that was invented rather than checked, and the install died on `schema percolate does not exist`"),
    ("workflow-engine/schema.sql",              "the engine: definitions, runs, tasks, saga, sql steps, YAML"),
    ("user-rbac/schema.sql",                    "identity: users, roles, API keys, sessions, the role model"),
    ("workflow-engine/integration-rbac.sql",    "ownership and authorization on run-scoped entry points"),
    ("ai-query-layer/schema.sql",               "nodes, keys, edges, the nine query modes, embedding spaces"),
    ("ai-query-layer/integration-rbac.sql",     "org scoping, api views, the SECURITY INVOKER read path"),
    ("ai-query-layer/integration-workflow.sql", "p8ql as a workflow step"),
    ("ai-query-layer/graph-algorithms.sql",     "the compiled graph algorithms, wrapped -- after integration-rbac, because it resolves names through aiq.lookup and must inherit whatever authorization that carries"),
    ("ai-query-layer/resolution.sql",           "resolving a loose textual mention to a node: exact, an entropy gate, a dropped qualification, then trigram. After integration-rbac for the same reason graph-algorithms is -- it reads through the registry and must inherit whatever authorization that carries"),
    ("ai-query-layer/catalogue.sql",            "this database's own catalogue as nodes plus exact pg_depend edges, opt-in behind aiq.refresh_catalogue(). After integration-rbac, because it registers an entity type and the projection it builds inherits that authorization"),
    ("ai-query-layer/reliability.sql",          "how often each extractor's edges have been retracted, and the Beta estimator over any two counts. Reads only aiq.edges, which has been recording the corrections since it was written"),
    ("ai-query-layer/edge-standing.sql",        "which edges answer real questions, which weights survive a uniform-partition null, and the depth-one read that records it happened. Reads the recall counters schema.sql already writes"),
    ("world-model-ingestion/schema.sql",        "the content plane: channels, files, resources, chunks"),
    ("world-model-ingestion/integration.sql",   "registers the corpus, projects documents into the graph"),
    ("agentic/schema.sql",                      "agents, sessions, runs, messages -- the conversation plane"),
    ("world-model-ingestion/graph.sql",         "graph indexing: the soft/lake reference tables and upsert_graph -- after agentic, because it registers an extractor agent"),
    ("world-model-ingestion/ingestion.sql",     "the default ingestion pipeline -- LAST: it installs a workflow, so it needs the lint (agentic), the embedding registry and the graph indexer to already exist"),
    ("world-model-ingestion/sources.sql",       "private data sources and workflow package authoring"),
    ("world-model-ingestion/api-sources.sql",   "incremental API sources, records and durable checkpoints"),
    ("world-model-ingestion/lake.sql",          "the lake: resolving, registering and landing what a DuckDB refine step read and wrote. After api-sources and the rest of the content plane, and after workflow-engine's integration-rbac, because every function here starts from workflow.task_owner()"),
    ("contract/schema.sql",                     "the published contract: percolate.enums() reads what every schema above enforces, so it goes after all of them"),
    ("packages/schema.sql",                     "percolate.apply_package(): a domain installed as one document. AFTER agentic (it delegates the servers/skills/agents half to agentic.apply_plugin), after world-model-ingestion (it inserts channels) and after workflow-engine (it defines and schedules workflows) -- it names all three and a `language plpgsql` body is not checked at create time, so the ordering is about the RUNTIME dependency rather than the parse"),
    ("identity/declarations.sql",               "what each table IS and what each nullable column's NULL MEANS -- statements about every schema above, so they can only be made after those tables exist. The mechanism they use ships first; see identity/schema.sql"),
]

# THE LAST THING IN THE SCRIPT, and not an ORDER entry. It holds
# the PUBLIC-EXECUTE revoke and its invariant, which are true only if nothing
# is defined after them. That block used to end world-model-ingestion/
# ingestion.sql, "the last file in ORDER", and six files were then added after
# it (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §4). A
# position in a list is a position somebody can append past; main() emits this
# after the compiled types, so there is no later.
CLOSING = ("identity/closing.sql", "the PUBLIC-EXECUTE revoke and its invariant over every schema the extension owns -- emitted after everything, so nothing can be defined after it")

# Every specs/*/*.sql file is either in ORDER above or named here, with the
# reason. Nothing may be in neither -- main() asserts it.
#
# This list exists because the audit that found the omission was not the build:
# `dev/currency.sh` diffed the live stack against a pristine install and
# reported content.connectors* as ORPHAN -- present in the database, absent
# from the specs' own extension script. It had been loaded by hand and was not
# in the product at all. A file being missing from ORDER looked identical to a
# file being deliberately excluded, so neither was a decision.
NOT_SHIPPED = {
    "identity/checks.sql":
        "a gate, not a schema: four catalogue assertions over whatever "
        "database it is pointed at, in the same shape as surface.sql. It "
        "exits nonzero and ships with the repository rather than with the "
        "extension -- a deployment does not need the checker, it needs to "
        "pass it.",
    "world-model-ingestion/graph-demo.sql":
        "a demonstration, not a schema: it uploads two contracts, lands their "
        "extracted graphs and runs the traversal, inside a transaction it rolls "
        "back. It ships nothing and must not run at install time -- an earlier "
        "version committed and broke dev/tests/query/06-graph-tenancy.sql, whose "
        "assertion is true only of the untouched fixture.",
    "user-rbac/roles.sql":
        "cluster-level CREATE ROLE; a non-superuser extension script cannot run it. "
        "Applied once by a DBA -- see the HEADER below.",
    "ai-query-layer/dev-helpers.sql":
        "dev conveniences, deliberately not part of what anyone installs.",
    "workflow-engine/pools.sql":
        "pools.md \u00a713 is explicit that the data model is verified and the control "
        "loop is a proposal. Shipping the schema for a manager that does not exist "
        "would put a table in the product with nothing on the other end of it.",
    "world-model-ingestion/connectors.sql":
        "UNDECIDED, and the only entry here that is a real question. sources.md "
        "\u00a717 demonstrates registering 304 sources through it over PostgREST "
        "against a live stack, so it behaves like a shipped surface -- but its rows "
        "reach nothing: \u00a717.4 records that connectors and channels are two "
        "descriptions of a source with no join between them, and the runner writes "
        "to a filesystem rather than to content.resources. Ship it once it lands "
        "bytes in the content plane, not before.",
    "trace-field/schema.sql":
        "not a sixth subsystem -- specs/README.md's scope test records that "
        "removing it leaves all five doing their jobs, and its proposals compile "
        "to ordinary workflow.tasks rows. The additions it wants are carried, "
        "with the trigger that would promote each, in workflow-engine/roadmap.md "
        "\u00a75; they get built there or deleted there. Shipping the schema now "
        "would put tables in the product ahead of that decision.",
    "world-model-ingestion/tradecraft.sql":
        "grading and corroboration over evidence classes. Core-eligible under "
        "SKILL.md \u00a75's transcribed-standard rule (Admiralty, ICD 203, Bellingcat "
        "are citable), but nothing consumes it yet and the second consumer is the "
        "promotion test. Held out until something calls it.",
}

HEADER = f"""-- ============================================================
-- percolate {VERSION} -- the whole schema, as one extension script.
--
-- GENERATED from specs/ by extension/percolate/build-sql.py. Do not edit.
--
-- Install:
--     CREATE EXTENSION vector;            -- superuser, not trusted
--     CREATE EXTENSION percolate_parser;  -- superuser, carries C functions
--     SET ROLE app_owner;
--     CREATE EXTENSION percolate;         -- non-superuser: owns what it makes
--
-- That last line is the load-bearing one. Extension objects are owned by
-- whoever runs the script, and superusers bypass RLS unconditionally -- so
-- installing this as a superuser would leave every policy below inert.
-- The preflight below refuses that case instead of installing it.
--
-- Roles are NOT created here: they are cluster-level, and a non-superuser
-- cannot CREATE ROLE. get-percolate's bootstrap.sql creates them (and
-- specs/user-rbac/roles.sql is this repository's copy of the same step).
-- ============================================================

-- ------------------------------------------------------------
-- PREFLIGHT: the roles this script grants to, and who is running it.
--
-- The first statement, because it has to come before anything that names a
-- role. On a cluster with no Percolate roles, `CREATE EXTENSION percolate
-- CASCADE` as postgres stopped at the first GRANT with `role "authenticated"
-- does not exist` -- measured at line 194 of the 0.1.6 script and line 374 of
-- 0.2.0 before this block -- and the superuser refusal that would have
-- explained the situation was in user-rbac/schema.sql, ten thousand lines
-- further down, where a clean cluster never got to.
--
-- Roles first, then the superuser: told only "not as a superuser", a reader on
-- a clean cluster runs SET ROLE app_owner and gets `role "app_owner" does not
-- exist`. Both messages name get-percolate's bootstrap.sql, which is the file a
-- reader has; roles.sql and the spec files are in this private repository.
--
-- The list is bootstrap.sql's. `authenticator` is granted nothing below and is
-- checked anyway: it is the role PostgREST logs in as, and an install that
-- succeeds without it is an API that cannot start.
-- ------------------------------------------------------------
do $preflight$
declare
    v_missing text;
begin
    select string_agg(t.r, ', ' order by t.ord) into v_missing
      from unnest(array['app_owner', 'api_viewer', 'web_anon', 'authenticated',
                        'authenticator', 'worker', 'scheduler'])
           with ordinality as t(r, ord)
     where not exists (select 1 from pg_roles where rolname = t.r);
    if v_missing is not null then
        raise exception
            'percolate needs cluster roles this cluster does not have: %. Roles '
            'belong to the cluster, so an extension cannot create them. Run '
            'bootstrap.sql once as a superuser -- it creates the roles and then '
            'installs percolate as app_owner: '
            'https://github.com/Percolation-Labs/get-percolate/blob/main/bootstrap.sql',
            v_missing;
    end if;

    -- A workflow step acting for a person runs as api_viewer with their claims
    -- (workflow-engine integration-rbac.sql, execute_for), so api_viewer needs
    -- what a signed-in person holds. A cluster bootstrapped before 0.2.0 does
    -- not have that grant, and without it a person's workflow fails on its
    -- first read with "permission denied" -- so say so here, with the line.
    if not pg_has_role('api_viewer', 'authenticated', 'member') then
        raise exception
            'percolate needs api_viewer to be a member of authenticated, and on this '
            'cluster it is not. Run once as a superuser: grant authenticated to '
            'api_viewer; -- a workflow step runs as the person who started its run, through '
            'api_viewer, and needs their grants to do it. bootstrap.sql does this '
            'from 0.2.0: '
            'https://github.com/Percolation-Labs/get-percolate/blob/main/bootstrap.sql';
    end if;

    -- Nobody a person can become may rewrite who they are. Every row rule in
    -- this script reads the caller from `request.jwt.claims`, and a role that
    -- can call set_config can put anybody's id there: through
    -- aiq.sql_passthrough it took one SELECT (user-rbac/roles.sql §6,
    -- meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md). The revoke
    -- needs a superuser and a function's ACL lives in each database, so this
    -- script can only refuse where it has not been done -- including on the
    -- upgrade of a database that predates the rule, which would otherwise
    -- complete with the door open.
    select string_agg(t.r, ', ' order by t.r) into v_missing
      from unnest(array['authenticated', 'web_anon', 'api_viewer']) as t(r)
     where has_function_privilege(t.r, 'pg_catalog.set_config(text, text, boolean)', 'execute');
    if v_missing is not null then
        raise exception
            'percolate refuses to install where % can call set_config: a signed-in '
            'caller could rewrite request.jwt.claims and act as anyone. Run once as a '
            'superuser, in this database: revoke execute on function '
            'pg_catalog.set_config(text, text, boolean) from public; grant execute on '
            'function pg_catalog.set_config(text, text, boolean) to authenticator, '
            'app_owner, worker, scheduler; -- bootstrap.sql does this from 0.2.0: '
            'https://github.com/Percolation-Labs/get-percolate/blob/main/bootstrap.sql',
            v_missing;
    end if;
    -- The other half of the same two statements: a revoke without the grant
    -- takes set_config from the owner too, and every function that sets a
    -- step's run or a step's caller would then fail at run time, not here.
    if not has_function_privilege(current_user, 'pg_catalog.set_config(text, text, boolean)', 'execute') then
        raise exception
            'percolate refuses to install: % cannot call set_config, and the functions '
            'that set a workflow step''s run and caller need it. Run once as a '
            'superuser: grant execute on function pg_catalog.set_config(text, text, '
            'boolean) to authenticator, app_owner, worker, scheduler;',
            current_user;
    end if;

    if (select rolsuper from pg_roles where rolname = current_user) then
        raise exception
            'REFUSING TO LOAD: current_user (%) is a cluster superuser. '
            'Superusers bypass RLS unconditionally, so the owner-privileged views '
            'below would return ALL rows to every caller. Install it as app_owner '
            '(SET ROLE app_owner; CREATE EXTENSION percolate CASCADE;), which is '
            'what bootstrap.sql does: '
            'https://github.com/Percolation-Labs/get-percolate/blob/main/bootstrap.sql',
            current_user;
    end if;
end $preflight$;

-- ------------------------------------------------------------
-- WHAT THIS BUILD WAS MADE FROM.
--
-- Provenance, because its absence cost a day. Two parser fixes were committed
-- -- an error naming a mode the caller had not written, and one caller's build
-- filter narrowing the next caller's answers -- and the test suite went on
-- failing against a .so compiled before them. The failures pointed at source
-- that was already correct, and nothing in the running database could say
-- which of "this is a bug" and "this binary is old" was true.
--
-- `compiler_capabilities()` does not answer it either, deliberately: it probes
-- FEATURES, one canary each, which detects the parser and the schema drifting
-- apart from EACH OTHER. Both halves can agree perfectly and both be six
-- commits behind the tree that produced them. This table is the other axis.
--
-- Not a constant baked into this file: the commit is not knowable when the
-- file is generated (it would have to name the commit that contains it), and a
-- SHA here would make the generated artifact differ on every build and defeat
-- build-sql.py --check. It is written at PACKAGE time instead, by whatever
-- assembles the release, through the function below.
-- ------------------------------------------------------------
create table if not exists public.percolate_build (
    component  text primary key,         -- 'schema' or 'parser'
    version    text not null,
    commit_sha text,
    built_at   timestamptz
);
grant select on public.percolate_build to public;

create or replace function public.percolate_record_build(
    p_component text, p_version text, p_commit text, p_built_at timestamptz)
returns void language sql volatile as $fn$
    insert into public.percolate_build (component, version, commit_sha, built_at)
    values (p_component, p_version, p_commit, p_built_at)
    on conflict (component) do update
       set version = excluded.version,
           commit_sha = excluded.commit_sha,
           built_at = excluded.built_at;
$fn$;

-- WHOEVER BUILDS THE IMAGE, AND NOBODY ELSE. Its two callers are
-- dev/build-image.sh and get-percolate's image-postgres.yml, both running as
-- the superuser at build time, so revoking from PUBLIC needs no grant to put
-- back.
--
-- It needs saying here rather than being left to identity/closing.sql, which
-- cannot see it: this function is created BEFORE the `alter default privileges`
-- in identity/schema.sql, and it lives in `public`, which is not one of
-- percolate.extension_schemas(). So it kept the PUBLIC default it was born
-- with, and `web_anon` could rewrite the table that answers which commit is
-- running -- the signal REM-79 is about, and the one whose absence the header
-- above says cost a day.
--
-- The READ stays everybody's, deliberately: percolate_build() and the table's
-- `grant select ... to public` above are the point of putting this in `public`
-- at all. A caller who cannot log in should still be able to ask what version
-- they are talking to. Writing is the half that is not a question.
--
-- Measured on a clean 0.2.0 install: this is the only function either percolate
-- extension ships into `public` that WRITES and carries EXECUTE for PUBLIC. The
-- parser's p8_* and aiq_parse are pure text-to-jsonb and public on purpose; the
-- p8_graph_* algorithms are already revoked. One instance is history, so this
-- fixes the instance -- teaching closing.sql to follow pg_depend into `public`
-- is the gate, and it is not owed until there is a second.
revoke execute on function public.percolate_record_build(
    text, text, text, timestamptz) from public;

-- The one-line answer. Reports every component and says plainly whether they
-- came from the same commit, because "the halves disagree" is the condition
-- worth naming and the one a human would otherwise have to eyeball.
create or replace function public.percolate_build()
returns table (component text, version text, commit_sha text,
               built_at timestamptz, consistent boolean)
language sql stable as $fn$
    select b.component, b.version, b.commit_sha, b.built_at,
           (select count(distinct commit_sha) <= 1
              from public.percolate_build where commit_sha is not null)
      from public.percolate_build b
     order by b.component;
$fn$;
"""


# THE SHADOWS THE BUILD ALLOWS, and nothing else.
#
# One function may be defined in two shipped files on purpose: the engine
# declares a standalone body, and integration-rbac.sql replaces it with one
# that also authorizes. The pattern is deliberate and schema.sql:2495 argues
# for it -- standalone the engine has no people, so there is nobody for a step
# to act as, and a stub that raises is better than a silent wrong answer.
#
# It is also the trap that has been walked into THREE times: 942c90e, 1716727
# and 8be039c are each a fix applied to the copy that every deployment loads
# and then immediately overwrites, so the change had no effect and nothing said
# so. This used to print a note. A note in build output is read by whoever is
# already looking, which is not the person about to edit the wrong body.
#
# So the list is declared here and the build REFUSES an undeclared one. The
# ratchet is deliberately the weaker of the two obvious designs -- it does not
# stop a fix landing in the dead copy, which needs the bodies merged (REM-57's
# second bullet, not done here). What it does is make the TENTH shadow a
# decision somebody writes down, and give the person who added the ninth a
# place that already says which body is live.
#
# Each entry: signature -> why the standalone body exists at all. If you cannot
# write that sentence, the two bodies are one function and belong in one file.
DECLARED_SHADOWS = {
    "workflow.run_owner_of(uuid)":
        "standalone: no identity plane, so a run has no owner. Returns null, "
        "and every caller reads that as 'nobody to act for'.",
    "workflow.execute_for(uuid,text,boolean,jsonb)":
        "standalone: raises. There is nobody to run a statement for, and "
        "running it with the engine's own reach is the leak REM-38 found.",
    "workflow.may_define()":
        "standalone: table privilege stands in for a permission nobody has "
        "granted, because there are no roles to grant it to.",
    "workflow.reusable_run(text)":
        "standalone: an external_id is installation-wide, because there is no "
        "owner to scope it to. With identities it narrows to one run per "
        "owner per key (REM-77).",
    "workflow.signal_task(uuid,text,jsonb)":
        "standalone: signals any waiting task. The shadow adds "
        "assert_run_access so a signal cannot reach somebody else's run.",
    "workflow.cancel_run(uuid)":
        "standalone: cancels any run, same reason as signal_task.",
    "workflow.assert_schedule_access(text,text)":
        "standalone: passes. A schedule has no owner to check against.",
    "workflow.matrix_rows(uuid)":
        "standalone: reads the rows with the engine's reach. The shadow runs "
        "the row source as the run's owner.",
    "workflow.matrix_outputs(uuid)":
        "standalone: reads every child output. The shadow scopes to the run "
        "the caller may see.",
    "workflow.plan_status(text,uuid)":
        "standalone: reads every run with the engine's reach, because there is "
        "nobody to scope one to. The shadow is definer over may_access_run, so "
        "the run-less form means the CALLER's newest run -- the standalone body "
        "raised 'permission denied for table tasks' at every caller it was "
        "granted to (REM-81).",
}


def check_cross_file_redefinitions(sigs_by_file) -> None:
    """Refuse a function defined in more than one shipped file undeclared.

    Both directions, so the list cannot rot into a description of a build that
    has moved on: an undeclared shadow fails, and a declaration for a signature
    that is no longer shadowed fails too.
    """
    seen = {}
    for rel, sigs in sigs_by_file:
        for sig in sigs:
            seen.setdefault(sig, []).append(rel)
    shadowed = {s: f for s, f in seen.items() if len(f) > 1}

    undeclared = sorted(set(shadowed) - set(DECLARED_SHADOWS))
    if undeclared:
        lines = []
        for sig in undeclared:
            files = shadowed[sig]
            lines.append(f"  {sig}\n      {' -> '.join(files)}   (live: {files[-1]})")
        raise SystemExit(
            "these functions are defined in more than one shipped file and are not "
            "declared in DECLARED_SHADOWS:\n" + "\n".join(lines) + "\n\n"
            "The last definition wins and the earlier one is dead in every deployment "
            "that loads both -- which is how three fixes (942c90e, 1716727, 8be039c) "
            "landed in a body nothing runs. If the shadow is deliberate, add it to "
            "DECLARED_SHADOWS in extension/percolate/build-sql.py with one sentence "
            "saying why the standalone body exists. If you cannot write that "
            "sentence, the two bodies are one function and belong in one file.")

    stale = sorted(set(DECLARED_SHADOWS) - set(shadowed))
    if stale:
        raise SystemExit(
            "DECLARED_SHADOWS names functions that are no longer defined twice:\n  "
            + "\n  ".join(stale)
            + "\nRemove the entries. A declaration that describes nothing is a "
              "licence nobody asked for.")

    if shadowed:
        print(f"note: {len(shadowed)} declared shadow(s); the LAST definition wins:")
        for sig, files in sorted(shadowed.items()):
            print(f"  {sig}\n      live: {files[-1]}")


def check_every_spec_is_accounted_for() -> None:
    """Refuse to build while a spec schema is in neither ORDER nor NOT_SHIPPED.

    The failure this prevents: a new specs/<system>/schema.sql is written,
    reviewed, tested against a hand-loaded dev database, and never added to
    ORDER -- so `CREATE EXTENSION percolate` does not contain it and nothing
    says so. That is not hypothetical; it is what happened to
    world-model-ingestion/connectors.sql.
    """
    shipped = {rel for rel, _ in ORDER} | {CLOSING[0]}
    known = shipped | set(NOT_SHIPPED)
    # `specs/migrations/` is NOT a subsystem and has its own consumer:
    # write_upgrades() prepends every `<from>--<to>.sql` hop to the generated
    # upgrade scripts, for the part of a version change a replay cannot express,
    # and migration_hops() refuses one nothing would read. Left in
    # this glob, the first migration anybody wrote made the build refuse to run
    # -- "in neither ORDER nor NOT_SHIPPED" -- which is this check firing on a
    # file it was never about. Found by writing one.
    found = {
        str(p.relative_to(ROOT / "specs"))
        for p in sorted((ROOT / "specs").glob("*/*.sql"))
        if p.parent.name != "migrations"
    }
    unaccounted = sorted(found - known)
    if unaccounted:
        raise SystemExit(
            "these spec schemas are in neither ORDER nor NOT_SHIPPED: "
            + ", ".join(unaccounted)
            + ".\nAdd them to ORDER to ship them, or to NOT_SHIPPED with the reason. "
            "A file in neither is not a decision, it is an omission.")
    missing = sorted(known - found)
    if missing:
        raise SystemExit(
            "these are listed but do not exist: " + ", ".join(missing))


def released_versions() -> list[str]:
    """Every version already published, from the tags -- not from a list here.

    A list would be a second place to remember something, which is what this
    file exists to avoid. `git tag` already knows, and if there is no git (a
    tarball, a vendored copy) the answer is "none published", which produces no
    upgrade scripts and is the correct answer for that situation rather than a
    crash.
    """
    import subprocess
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "tag", "--list", "v*"],
                             capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    if out.returncode != 0:
        return []
    seen = []
    for line in out.stdout.split():
        v = line.lstrip("v")
        if re.fullmatch(r"\d+\.\d+\.\d+", v) and v != VERSION:
            seen.append(v)
    return sorted(seen, key=lambda x: [int(n) for n in x.split(".")])


def write_upgrades(body: str) -> None:
    """One `percolate--<old>--<VERSION>.sql` per already-released version.

    THE SAME BODY, and that is the whole design rather than a shortcut. Every
    statement in it is idempotent -- `create table if not exists`, `create or
    replace view/function/trigger`, a policy dropped before it is created, seed
    rows with `on conflict do nothing` -- so applying it to a database that is
    already at an older version converges it to this one. build-sql.py refuses
    a statement that breaks that property, so the guarantee is enforced rather
    than remembered.
    
    Written for EVERY prior version, not just the previous one, because only
    the current release's scripts ship: a database at 0.1.0 has no 0.1.1 script
    on disk to hop through, so it needs a direct path.

    What this cannot express is destructive change -- a dropped column, a
    renamed table, a backfill. Those go in `specs/migrations/<from>--<to>.sql`,
    one file per hop, and EVERY hop between the old version and this one is
    prepended, oldest first.

    Every hop, and not only the one named `<old>--<VERSION>`, which is what this
    used to look up: a database at 0.1.2 needs 0.1.2->0.1.3's status rename and
    0.1.3->0.1.4's policy and column renames as much as 0.1.6->0.2.0's, and
    looking up the exact pair gave it none of them. Five of the six 0.2.0
    upgrade scripts failed on a released database -- measured on 0.1.5 and
    0.1.2, `column "recall_count" does not exist` -- while both upgrade gates
    tested only the newest tag
    (meta/postmortems/2026-09-11-fixed-at-the-copy-that-failed.md §2.4).
    A hop is prepended when it starts at or after the old version, so a
    database that already took a hop on an earlier upgrade never replays it.
    """
    # Leftovers first, so the remedy --check prints actually converges. --check
    # refuses an upgrade path to a version this tree no longer ships, and the
    # message it prints says "run build-sql.py" -- which would have been a lie
    # if this only ever added files. A generator whose output is checked has to
    # be able to reach the state the checker demands.
    sql_dir = ROOT / "extension/percolate/sql"
    for p in sorted(sql_dir.glob("percolate--*--*.sql")):
        if not p.name.endswith(f"--{VERSION}.sql"):
            p.unlink()
            print(f"removed {p.name}: an upgrade path to a version this tree no longer ships")

    prior = released_versions()
    if not prior:
        print("no released versions in git tags -- no upgrade scripts written")
        return
    hops = migration_hops(prior)
    written = []
    for old in prior:
        dest = ROOT / f"extension/percolate/sql/percolate--{old}--{VERSION}.sql"
        dest.write_text(upgrade_script(old, body, hops))
        n = len(hops_from(old, hops))
        written.append(f"{old}->{VERSION}" + (f" (+{n} hop{'s' * (n != 1)})" if n else ""))
    print(f"wrote {len(written)} upgrade script(s): {', '.join(written)}")


def vkey(v: str) -> tuple:
    return tuple(int(x) for x in v.split("."))


def hops_from(old: str, hops: list) -> list:
    """The hops a database at `old` still has to take: those starting at or
    after it. One it took on an earlier upgrade starts before it."""
    return [h for h in hops if vkey(h[0]) >= vkey(old)]


def upgrade_script(old: str, body: str, hops: list) -> str:
    """The whole of percolate--<old>--<VERSION>.sql. ONE function, called by the
    writer and by --check, which used to carry its own copy of the exact-pair
    lookup -- so fixing the writer alone would have left --check approving the
    scripts the writer no longer makes."""
    head = "".join(
        f"-- from specs/migrations/{p.name}: the part of the {a} -> {b} hop\n"
        f"-- that a replay cannot express.\n" + p.read_text().rstrip() + "\n\n"
        for a, b, p in hops_from(old, hops))
    return head + body


def migration_hops(prior: list) -> list:
    """specs/migrations/<from>--<to>.sql, oldest hop first -- and a refusal for
    any file no upgrade script would read.

    A migration nobody reads is a fix that never runs, and it looks exactly like
    one that does: that is how 0.1.2->0.1.3 and 0.1.3->0.1.4 sat in the tree
    while every 0.2.0 upgrade script left them out. So a file that is not
    `X.Y.Z--X.Y.Z.sql`, runs backwards, or ends past this version stops the
    build rather than being skipped.
    """
    hops = []
    for p in sorted((ROOT / "specs" / "migrations").glob("*.sql")):
        m = re.fullmatch(r"(\d+\.\d+\.\d+)--(\d+\.\d+\.\d+)\.sql", p.name)
        if not m:
            raise SystemExit(f"specs/migrations/{p.name}: not named <from>--<to>.sql, "
                             "so no upgrade script would read it")
        a, b = m.groups()
        if vkey(a) >= vkey(b) or vkey(b) > vkey(VERSION):
            raise SystemExit(f"specs/migrations/{p.name}: a hop from {a} to {b} is not "
                             f"one an upgrade to {VERSION} can take, so nothing would read it")
        if prior and vkey(a) < min(vkey(v) for v in prior):
            raise SystemExit(f"specs/migrations/{p.name}: starts before the oldest released "
                             f"version this tree writes an upgrade from, so nothing would read it")
        hops.append((a, b, p))
    return sorted(hops, key=lambda h: vkey(h[0]))


def sql_str(s):
    """A SQL string literal, or NULL. Doubling is the whole escape rule."""
    if s is None:
        return "null"
    return "'" + str(s).replace("'", "''") + "'"


def compile_types():
    """specs/contract/types/*.yaml -> the inserts that populate percolate.types.

    Authored as YAML because a person writes and reviews these; stored as jsonb
    because a machine reads them. Compiled rather than loaded at runtime for the
    reason everything else here is compiled: the extension script is what a
    database installs, and a contract that needed a YAML parser at install time
    would be a contract only a Python deployment could have.

    Deterministic -- sorted files, sorted keys -- because build-sql.py --check
    compares the generated artifact byte for byte.
    """
    import json

    try:
        import yaml
    except ModuleNotFoundError:
        raise SystemExit(
            "specs/contract/types/*.yaml needs PyYAML to compile into percolate.types.\n"
            "  pip install pyyaml\n"
            "It is a build-time dependency only: the generated SQL carries the "
            "shapes as jsonb, so installing the extension needs no Python at all.")

    d = ROOT / "specs" / "contract" / "types"
    if not d.is_dir():
        return ""

    rows = []
    for path in sorted(d.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text())
        missing = {"name", "title", "owner", "schema"} - set(doc or {})
        if missing:
            raise SystemExit(
                f"{path.relative_to(ROOT)}: missing {', '.join(sorted(missing))}. "
                "A type contract has to say what it is called, what it is, who "
                "owns it, and what shape it has.")
        # The filename IS the name, so a reader finding a type in the database
        # can find the file without grepping, and two files cannot claim one
        # name while looking like two contracts.
        if doc["name"] != path.stem:
            raise SystemExit(
                f"{path.relative_to(ROOT)}: declares name {doc['name']!r} but is "
                f"filed as {path.stem!r}. The filename is the name.")
        consumed = doc.get("consumed_by") or []
        arr = "array[" + ", ".join(sql_str(c) for c in consumed) + "]::text[]" \
            if consumed else "'{}'::text[]"
        rows.append(
            f"    ({sql_str(doc['name'])}, {sql_str(doc['title'])}, "
            f"{sql_str(doc['owner'])}, {arr},\n"
            f"     {sql_str(json.dumps(doc['schema'], sort_keys=True))}::jsonb,\n"
            f"     {sql_str(json.dumps(doc['implemented'], sort_keys=True)) if doc.get('implemented') else 'null'}"
            f"{'::jsonb' if doc.get('implemented') else ''},\n"
            f"     {sql_str((doc.get('why') or '').strip() or None)})")

    if not rows:
        return ""

    return (
        "\n-- ============================================================\n"
        "-- contract/types/*.yaml\n"
        "--   the declared payload shapes, compiled from YAML into percolate.types\n"
        "-- ============================================================\n\n"
        "insert into percolate.types (name, title, owner, consumed_by, schema, implemented, why)\nvalues\n"
        + ",\n".join(rows)
        # A re-install and an upgrade both re-run this file, and a type whose
        # shape was corrected has to land rather than be skipped -- `do nothing`
        # here would make every edit to a YAML a no-op on every database that
        # already had the row, which is the silent-partial-write shape this
        # collection keeps finding.
        + "\non conflict (name) do update\n"
          "   set title = excluded.title,\n"
          "       owner = excluded.owner,\n"
          "       consumed_by = excluded.consumed_by,\n"
          "       schema = excluded.schema,\n"
          "       implemented = excluded.implemented,\n"
          "       why = excluded.why;\n")


def main() -> int:
    check_every_spec_is_accounted_for()
    parts = [HEADER]
    sigs_by_file = []

    def emit(rel: str, why: str) -> bool:
        src = ROOT / "specs" / rel
        if not src.exists():
            print(f"missing: {src}", file=sys.stderr)
            return False
        # Required extensions are declared in percolate.control, so the schema
        # files no longer create them and cannot disagree about versions.
        raw = src.read_text()
        check_raise_format(rel, raw)
        check_idempotent(rel, raw)
        sigs_by_file.append((rel, check_single_definition(rel, raw)))
        body = re.sub(r"^create extension if not exists [a-z_]+;.*$", "",
                      raw, flags=re.M)
        parts.append(
            f"\n-- ============================================================\n"
            f"-- {rel}\n--   {why}\n"
            f"-- ============================================================\n")
        parts.append(body)
        return True

    for rel, why in ORDER:
        if not emit(rel, why):
            return 1

    # After every schema file, because percolate.enums() reads percolate.types for the enums
    # that live inside declared shapes, and the table has to exist first.
    parts.append(compile_types())

    # And after THAT, the closing invariant -- see CLOSING.
    if not emit(*CLOSING):
        return 1

    check_cross_file_redefinitions(sigs_by_file)

    out = ROOT / f"extension/percolate/sql/percolate--{VERSION}.sql"
    body = "\n".join(parts)

    # --check asserts the committed artifact matches the specs. The generated
    # SQL is tracked (a clone must be able to install without a Python
    # toolchain), so the thing to guard against is it going stale after a
    # schema edit -- which is exactly the drift this collection keeps finding.
    if "--check" in sys.argv:
        if not out.exists() or out.read_text() != body:
            print(f"STALE: {out.relative_to(ROOT)} does not match specs/ -- "
                  f"run: python3 {pathlib.Path(__file__).relative_to(ROOT)}",
                  file=sys.stderr)
            return 1
        # The upgrade scripts are shipped artifacts too, and they go stale the
        # same way -- a specs/ edit regenerated into percolate--<v>.sql and not
        # into percolate--<old>--<v>.sql leaves existing databases upgrading to
        # something that is not this version. Checking only the file somebody
        # remembered to look at is how the parser stayed stale for a day.
        stale = []
        prior = released_versions()
        hops = migration_hops(prior)
        for old_v in prior:
            up = ROOT / f"extension/percolate/sql/percolate--{old_v}--{VERSION}.sql"
            if not up.exists():
                stale.append(f"{up.name} is missing")
            elif not up.read_text().endswith(body):
                stale.append(f"{up.name} does not end with the current schema")
            elif up.read_text() != upgrade_script(old_v, body, hops):
                stale.append(f"{up.name} does not carry the migration hops from {old_v}")
        # AND THE OPPOSITE FAILURE: a script that should no longer be there.
        #
        # Everything above asks whether the files that must exist do. Nothing
        # asked whether a file that must NOT exist still does, and that is a
        # real state rather than a hypothetical -- the version bump renames the
        # base script and used to leave `percolate--<old>--<previous>.sql`
        # behind. Postgres reads the sharedir to decide what an extension can
        # become, so a leftover is an offer: `ALTER EXTENSION percolate UPDATE
        # TO '<previous>'` still resolves, to a version whose base script the
        # same bump deleted. Two installable versions, one of which nobody
        # meant to ship, which is the exact sentence the bump script uses to
        # justify deleting the base script it does remember.
        #
        # Checked here as well as fixed there, because "the writer remembers"
        # is the property this file exists to stop relying on.
        sql_dir = ROOT / "extension/percolate/sql"
        orphans = sorted(
            p.name for p in sql_dir.glob("percolate--*--*.sql")
            if not p.name.endswith(f"--{VERSION}.sql"))
        if orphans:
            stale.append(
                "leftover upgrade path(s) to a version this tree no longer ships: "
                + ", ".join(orphans) + " -- delete them")
        if stale:
            print("STALE upgrade script(s): " + "; ".join(stale) +
                  f" -- run: python3 {pathlib.Path(__file__).relative_to(ROOT)}",
                  file=sys.stderr)
            return 1
        n = len(released_versions())
        print(f"{out.relative_to(ROOT)} is current"
              + (f", and {n} upgrade script(s) with it" if n else ""))
        return 0

    out.write_text(body)
    print(f"wrote {out.relative_to(ROOT)} "
          f"({len(body.splitlines())} lines from {len(ORDER)} spec files)")
    write_upgrades(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
