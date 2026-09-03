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
    ("workflow-engine/schema.sql",              "the engine: definitions, runs, tasks, saga, sql steps, YAML"),
    ("user-rbac/schema.sql",                    "identity: users, roles, API keys, sessions, the role model"),
    ("workflow-engine/integration-rbac.sql",    "ownership and authorization on run-scoped entry points"),
    ("ai-query-layer/schema.sql",               "nodes, keys, edges, the seven query modes, embedding spaces"),
    ("ai-query-layer/integration-rbac.sql",     "org scoping, api views, the SECURITY INVOKER read path"),
    ("ai-query-layer/integration-workflow.sql", "p8ql as a workflow step"),
    ("ai-query-layer/graph-algorithms.sql",     "the compiled graph algorithms, wrapped -- after integration-rbac, because it resolves names through aiq.lookup and must inherit whatever authorization that carries"),
    ("world-model-ingestion/schema.sql",        "the content plane: channels, files, resources, chunks"),
    ("world-model-ingestion/integration.sql",   "registers the corpus, projects documents into the graph"),
    ("agentic/schema.sql",                      "agents, sessions, runs, messages -- the conversation plane"),
    ("world-model-ingestion/graph.sql",         "graph indexing: the soft/lake reference tables and upsert_graph -- after agentic, because it registers an extractor agent"),
    ("world-model-ingestion/ingestion.sql",     "the default ingestion pipeline -- LAST: it installs a workflow, so it needs the lint (agentic), the embedding registry and the graph indexer to already exist"),
]

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
-- user-rbac's own guard refuses that case rather than allowing it silently.
--
-- Roles are NOT created here: they are cluster-level, and a non-superuser
-- cannot CREATE ROLE. See specs/user-rbac/roles.sql, applied once by a DBA.
-- ============================================================
"""


def report_cross_file_redefinitions(sigs_by_file) -> None:
    """Name every function defined in more than one shipped file.

    check_single_definition() guards WITHIN a file. Across files the same
    shadowing is legitimate and deliberate -- integration-rbac.sql replaces
    several engine entry points to add authorization -- so this reports rather
    than refuses. It reports because the trap is real and was walked into: a
    fix to signal_task's completed_at was applied to schema.sql's copy, which
    every deployment loads and then immediately overwrites, so the change had
    no effect and nothing said so. Knowing which definition is live is the
    difference between editing the function and editing a comment.
    """
    seen = {}
    for rel, sigs in sigs_by_file:
        for sig in sigs:
            seen.setdefault(sig, []).append(rel)
    shadowed = {s: f for s, f in seen.items() if len(f) > 1}
    if shadowed:
        print("note: defined in more than one shipped file -- the LAST one wins:")
        for sig, files in sorted(shadowed.items()):
            print(f"  {sig}\n      {' -> '.join(files)}   (live: {files[-1]})")


def check_every_spec_is_accounted_for() -> None:
    """Refuse to build while a spec schema is in neither ORDER nor NOT_SHIPPED.

    The failure this prevents: a new specs/<system>/schema.sql is written,
    reviewed, tested against a hand-loaded dev database, and never added to
    ORDER -- so `CREATE EXTENSION percolate` does not contain it and nothing
    says so. That is not hypothetical; it is what happened to
    world-model-ingestion/connectors.sql.
    """
    shipped = {rel for rel, _ in ORDER}
    known = shipped | set(NOT_SHIPPED)
    found = {
        str(p.relative_to(ROOT / "specs"))
        for p in sorted((ROOT / "specs").glob("*/*.sql"))
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


def main() -> int:
    check_every_spec_is_accounted_for()
    parts = [HEADER]
    sigs_by_file = []
    for rel, why in ORDER:
        src = ROOT / "specs" / rel
        if not src.exists():
            print(f"missing: {src}", file=sys.stderr)
            return 1
        # Required extensions are declared in percolate.control, so the schema
        # files no longer create them and cannot disagree about versions.
        raw = src.read_text()
        check_raise_format(rel, raw)
        sigs_by_file.append((rel, check_single_definition(rel, raw)))
        body = re.sub(r"^create extension if not exists [a-z_]+;.*$", "",
                      raw, flags=re.M)
        parts.append(
            f"\n-- ============================================================\n"
            f"-- {rel}\n--   {why}\n"
            f"-- ============================================================\n")
        parts.append(body)

    report_cross_file_redefinitions(sigs_by_file)

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
        print(f"{out.relative_to(ROOT)} is current")
        return 0

    out.write_text(body)
    print(f"wrote {out.relative_to(ROOT)} "
          f"({len(body.splitlines())} lines from {len(ORDER)} spec files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
