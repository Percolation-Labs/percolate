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
VERSION = "0.1.0"

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
    ("world-model-ingestion/schema.sql",        "the content plane: channels, files, resources, chunks"),
    ("world-model-ingestion/integration.sql",   "registers the corpus, projects documents into the graph"),
]

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


def main() -> int:
    parts = [HEADER]
    for rel, why in ORDER:
        src = ROOT / "specs" / rel
        if not src.exists():
            print(f"missing: {src}", file=sys.stderr)
            return 1
        # Required extensions are declared in percolate.control, so the schema
        # files no longer create them and cannot disagree about versions.
        body = re.sub(r"^create extension if not exists [a-z_]+;.*$", "",
                      src.read_text(), flags=re.M)
        parts.append(
            f"\n-- ============================================================\n"
            f"-- {rel}\n--   {why}\n"
            f"-- ============================================================\n")
        parts.append(body)

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
