#!/usr/bin/env python3
"""Export a live database's published contract as a tracked artifact.

    dev/contract-export.py --psql '<cmd>'            # write it
    dev/contract-export.py --psql '<cmd>' --check    # non-zero if it is stale

WHY THIS IS A FILE AND NOT JUST A FUNCTION CALL.

`percolate.contract()` is the contract, and a client with a connection should ask it
directly. But three kinds of client cannot:

  * A client being BUILT. percolate-core's tests assert that its pydantic
    Literals match this collection's vocabularies; requiring a live Postgres to
    run them would make the cheap check the expensive one, and a check that
    needs infrastructure is a check that gets skipped.
  * A client in ANOTHER REPOSITORY. percolate-core is a separate, gitignored
    repo -- this repo's CI cannot see it and its CI cannot see these specs. A
    committed artifact is the only thing both can read.
  * A client in another LANGUAGE, or written by somebody who does not have a
    database yet and is deciding whether to.

So the contract is published twice, and deliberately: `percolate.contract()` is the
live answer, and this file is that answer frozen at a version, tracked, and
reviewable in a diff. The same shape as `extension/percolate/sql/percolate--<v>.sql`
-- generated, committed, and guarded by a --check so it cannot go stale.

WHAT IT IS EXPORTED FROM MATTERS. This reads a DATABASE, not the tree, because
the tree is what we believe and the catalog is what is enforced. Generating it
by parsing specs/*.sql would reproduce the class of bug the contract exists to
end: three of four local databases in this workspace still admit the
pre-lifecycle_states status words, and no reader of the tree can tell.

WHAT IS FROZEN HERE IS NARROWER THAN WHAT THE DATABASE PUBLISHES, and the
narrowing is the point. Every entry carries `members`, which says whose rows
they are:

  * `shipped`     the extension puts them there (workflow.lifecycle_states,
                  rbac.visibilities, ...). Frozen verbatim -- this is the part a
                  client compiles against.
  * `deployment`  the members are whatever THIS database created (rbac.roles,
                  agentic.plugins). `percolate.contract()` reports them live,
                  because a caller with a connection is asking what it may write
                  right now. This file blanks them, because freezing them
                  publishes one deployment's data as everybody's contract -- and
                  a client that generated `Literal["admin"]` from a dev seed
                  would be wrong on the first deployment that adds a second role.
  * `unreadable`  the exporting role could not select the vocabulary's rows.
                  Export as a role that can see what a client should see; the
                  header records which role was used, so a thin export is
                  visible rather than mistaken for a small contract.

`admits: null` therefore has three causes and `members` is what tells them
apart. Before it existed there was only the null, and the collapse cost three
red CI runs: contract.json had been exported from a database dev/tests/rbac/01
had run against and froze `member` -- a test fixture -- into rbac.roles'
published set, so the file matched the generating database perfectly and matched
a fresh install never.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "extension" / "percolate" / "contract.json"


def fetch(psql: str) -> dict:
    # `-A -t` and a single jsonb value: psql renders it on one line, and the
    # round trip through json.loads/json.dumps is what makes the committed file
    # stably formatted rather than dependent on how Postgres chose to print it.
    proc = subprocess.run(
        shlex.split(psql) + ["-At", "-c", "select percolate.contract()::text"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        err = proc.stderr.strip()
        if "p8" in err and ("does not exist" in err or "schema" in err):
            raise SystemExit(
                "this database publishes no contract -- it has no percolate schema.\n"
                "Install a build that includes specs/contract/schema.sql:\n"
                "    dev/reload.sh <db>")
        raise SystemExit(f"psql failed: {err}")
    doc = json.loads(proc.stdout.strip())

    who = subprocess.run(
        shlex.split(psql) + ["-At", "-c", "select current_user"],
        capture_output=True, text=True).stdout.strip()

    # `generated_at` is dropped deliberately: it changes on every call, which
    # would make the committed artifact differ on every export and defeat
    # --check entirely. The version and the exporting role are what a reader
    # actually needs, and neither moves on its own.
    doc.pop("generated_at", None)
    doc["exported_by_role"] = who

    # AND ONLY THE TABLES THE EXTENSION ITSELF CREATED.
    #
    # `percolate.contract()` answers "what does THIS DATABASE admit", which for
    # a live caller correctly includes the application's own tables -- somebody
    # writing into `calder.signals` wants to know its `severity` is closed.
    # This file answers a narrower question: what a client compiles against
    # BEFORE it has a database. An application's constraints are not that, and
    # they are not this repository's to publish.
    #
    # Without the narrowing the gate goes red on any database with an
    # application in it. Measured on the CI database with dev/tests/evals'
    # fixture loaded: 8 `calder.*` tables, 6 lines of "enforced by this
    # database, absent from the committed contract", and the remedy the failure
    # prints would have frozen one fixture's schema into everybody's contract
    # -- the exact accident `members` was added to prevent, one axis over. It
    # is also the state every real deployment is in, so the gate was answering
    # wrongly there and nobody had asked it.
    #
    # READ FROM pg_depend, not from a roster of schemas. A roster needs editing
    # for every schema a release adds; the catalog already knows, because
    # `create extension` records a dependency for each object it creates. Same
    # reasoning percolate.enums() gives for reading `deployment` out of
    # pg_extension.extconfig rather than listing it.
    owned = subprocess.run(
        shlex.split(psql) + ["-At", "-c", """
        select n.nspname || '.' || c.relname
          from pg_catalog.pg_depend d
          join pg_catalog.pg_extension x on x.oid = d.refobjid
          join pg_catalog.pg_class c on c.oid = d.objid
          join pg_catalog.pg_namespace n on n.oid = c.relnamespace
         where d.refclassid = 'pg_catalog.pg_extension'::regclass
           and d.classid    = 'pg_catalog.pg_class'::regclass
           and x.extname    = 'percolate'"""],
        capture_output=True, text=True)
    if owned.returncode != 0:
        raise SystemExit("psql failed reading extension ownership: "
                         + owned.stderr.strip())
    ours = {line for line in owned.stdout.split() if line}
    # An empty set would freeze an EMPTY contract, and --check would then report
    # every entry as having vanished from the database -- a diagnosis pointing
    # at the schema when the cause is this query. Raise instead.
    if not ours:
        raise SystemExit(
            "the percolate extension owns no tables in this database -- "
            "pg_depend has no pg_class entries for it, so this export cannot "
            "tell the extension's contract from an application's")
    #
    # `check` and `reference` ONLY. A `type` entry's `table` is not a table --
    # it is a declared percolate.types name (`content.api_source`), enforced by
    # a trigger or by the reader and invisible to the catalog, which is the
    # whole reason percolate.enums() reports it. Filtering those against
    # pg_class dropped all eight of them on the first run of this narrowing,
    # and every one is the extension's own.
    doc["enums"] = [e for e in doc.get("enums", [])
                    if e["enforced_by"] not in ("check", "reference")
                    or f"{e['schema']}.{e['table']}" in ours]
    return doc


def freeze(doc: dict) -> dict:
    """The live contract, reduced to the part that is stable enough to commit.

    Only `deployment` members are dropped, and only their MEMBERS: the column,
    the fact that it is constrained, and the name of the vocabulary constraining
    it all stay, because those are schema and do not move when somebody creates
    a role. A client reading this file learns that `rbac.user_roles.role` is
    closed over `rbac.roles` and that it has to ask a live database which rows
    are in it -- which is true, and is better than a frozen list that is wrong
    everywhere except the machine it was generated on.
    """
    # `e["members"]`, NOT `e.get("members")`, and the difference is a whole
    # class of wrong answer.
    #
    # Against a database whose percolate.enums() predates the members column --
    # any database installed before this axis existed, which is the state a
    # developer with a stale scratch database is most likely to be in -- .get()
    # returns None, nothing is blanked, and --check reports five admits
    # differences with the message "null means the exporting role could not read
    # it". That diagnosis is wrong: the cause is the database's SHAPE, not a
    # privilege. And the remedy the failure prints is the write command, which on
    # that database would regenerate exactly the frozen-fixture contract this
    # whole mechanism exists to prevent.
    #
    # A KeyError naming `members` is the honest answer to "this database cannot
    # answer the question I am asking". Tolerating the absence turns a stale
    # database into a wrong contract, silently, which is the failure the file
    # is about. Found by a review session running --check against p8reload.
    for e in doc.get("enums", []):
        if e["members"] == "deployment":
            e["admits"] = None
    return doc


def render(doc: dict) -> str:
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


# WHAT MOVED, NAMED RATHER THAN DIFFED.
#
# MEASURED, so that the cost of not having this is on the record: without it the
# check reported exactly one word -- STALE -- and main stayed red across three
# runs and 2h39m (e71d018 11:39Z to cc0fc91 14:18Z), with one session's whole
# investigation spent on pg_cron because the message gave it nothing else to
# look at. The actual difference was one row. It then handed the reader the
# command to OVERWRITE the file. That is the wrong reflex
# to train and it is the only one the message left available: with no statement
# of what differs, regenerating is the sole way to find out, and regenerating is
# precisely what must not be done before the difference is understood.
#
# The difference that cost the day was ONE ROW in one vocabulary. Printed, it is
# a line. Unprinted, it needs a reproduction of the CI database to see at all.
def differences(committed: dict, live: dict) -> list[str]:
    out: list[str] = []

    for field in ("extension", "exported_by_role"):
        if committed.get(field) != live.get(field):
            out.append(f"{field}: committed {committed.get(field)!r}, "
                       f"this database {live.get(field)!r}")

    def by_key(doc, section, key):
        return {key(e): e for e in doc.get(section, [])}

    ekey = lambda e: (e["schema"], e["table"], e["column"], e["enforced_by"])
    cen, len_ = by_key(committed, "enums", ekey), by_key(live, "enums", ekey)
    for k in sorted(set(cen) - set(len_)):
        out.append(f"{k[0]}.{k[1]}.{k[2]} ({k[3]}): in the committed contract, "
                   f"NOT enforced by this database")
    for k in sorted(set(len_) - set(cen)):
        out.append(f"{k[0]}.{k[1]}.{k[2]} ({k[3]}): enforced by this database, "
                   f"absent from the committed contract")
    for k in sorted(set(cen) & set(len_)):
        c, l = cen[k], len_[k]
        if c == l:
            continue
        where = f"{k[0]}.{k[1]}.{k[2]} ({k[3]})"
        if c["admits"] != l["admits"]:
            # `admits: null` is "the exporting role may not read this
            # vocabulary", not "it is empty" -- so say which happened rather
            # than printing a set difference over None.
            if c["admits"] is None or l["admits"] is None:
                out.append(f"{where}: committed {c['admits']!r}, "
                           f"this database {l['admits']!r} "
                           f"(null means the exporting role could not read it)")
            else:
                gone = sorted(set(c["admits"]) - set(l["admits"]))
                new = sorted(set(l["admits"]) - set(c["admits"]))
                out.append(f"{where} -> {c['vocabulary'] or 'check constraint'}: "
                           + ", ".join(filter(None, [
                               f"committed has {gone} and this database does not" if gone else "",
                               f"this database has {new} and the committed file does not" if new else "",
                           ])))
        if c["vocabulary"] != l["vocabulary"]:
            out.append(f"{where}: vocabulary moved from {c['vocabulary']!r} "
                       f"to {l['vocabulary']!r}")
        # Compared and printed, because it is the field that decides whether
        # `admits` is frozen at all. Without this a vocabulary moving between
        # `shipped` and `deployment` -- the exact thing pg_extension_config_dump
        # controls -- could change the artifact with nothing naming the cause.
        if c.get("members") != l.get("members"):
            out.append(f"{where}: members moved from {c.get('members')!r} "
                       f"to {l.get('members')!r} -- whose rows these are has "
                       f"changed, which decides whether they are frozen at all")

    tkey = lambda t: t["name"]
    ct, lt = by_key(committed, "types", tkey), by_key(live, "types", tkey)
    for k in sorted(set(ct) - set(lt)):
        out.append(f"type {k}: declared in the committed contract, not by this database")
    for k in sorted(set(lt) - set(ct)):
        out.append(f"type {k}: declared by this database, not in the committed contract")
    for k in sorted(set(ct) & set(lt)):
        if ct[k] != lt[k]:
            fields = sorted(f for f in set(ct[k]) | set(lt[k]) if ct[k].get(f) != lt[k].get(f))
            out.append(f"type {k}: {', '.join(fields)} differ(s)")

    return out or ["the documents differ but no field comparison caught it -- "
                   "compare the file with the export by hand"]


# READ THE LINES ABOVE BEFORE RUNNING THIS, and the order is the point.
#
# A `shipped` vocabulary moving is a real change to what clients may write, and
# regenerating without reading it is how a release silently narrows or widens a
# contract. The one class that used to force a regeneration -- a deployment
# vocabulary's rows drifting between the machine that exported and the machine
# that checks -- can no longer reach this file at all; freeze() blanks those.
REMEDY = """
Regenerate ONLY once the lines above are explained -- every line names a
capability a client compiles against:

    dev/contract-export.py --psql '{psql}'
"""

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--psql", required=True,
                    help="a psql command, e.g. "
                         "'docker exec p8-dev-db psql -U p8 -d p8dev'")
    ap.add_argument("--check", action="store_true",
                    help="do not write; exit non-zero if the committed file is stale")
    a = ap.parse_args()

    body = render(freeze(fetch(a.psql)))

    if a.check:
        if not OUT.exists():
            print(f"MISSING: {OUT.relative_to(ROOT)} -- run "
                  f"dev/contract-export.py --psql '<cmd>'", file=sys.stderr)
            return 1
        if OUT.read_text() != body:
            print(f"STALE: {OUT.relative_to(ROOT)} does not match what this "
                  f"database publishes.", file=sys.stderr)
            print("", file=sys.stderr)
            for line in differences(json.loads(OUT.read_text()), json.loads(body)):
                print(f"  {line}", file=sys.stderr)
            print(REMEDY.format(psql=a.psql), file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} is current")
        return 0

    OUT.write_text(body)
    doc = json.loads(body)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(doc['enums'])} enums, "
          f"{len(doc['types'])} types, extension {doc.get('extension')}, "
          f"as {doc['exported_by_role']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
