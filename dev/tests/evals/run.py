#!/usr/bin/env python3
"""Run the scenario evals in `scenarios.yaml` against a live database.

    ./run.py                       # every scenario
    ./run.py --fixture             # (re)load fixtures.sql first, then run
    ./run.py -k upload             # only ids/titles matching a substring
    ./run.py -c recovery           # only one category
    ./run.py --list                # what is in the file, without running it
    ./run.py -v                    # print the SQL of every failure
    DSN="postgres://…" ./run.py    # against something other than the stack

Exit code is nonzero if any scenario fails, so this works as a CI gate beside
`../run.sh` and `../../../surface.sql`.

WHY EACH SCENARIO IS ITS OWN psql INVOCATION. One big script would be faster
and would interleave stderr with stdout under buffering, which makes "which
scenario produced this ERROR" a guess. A process per scenario costs ~70ms and
makes the answer a fact. A hundred scenarios is under ten seconds.

WHY EVERY SCENARIO ROLLS BACK. A scenario that leaves rows behind makes the
next one's result depend on the order they ran in, and an eval suite whose
results depend on order is one nobody can bisect. The fixture is the only
persistent state, and `--fixture` rebuilds it.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

try:
    import yaml
except ImportError:                                          # pragma: no cover
    sys.exit("this needs PyYAML: pip3 install pyyaml")

HERE = os.path.dirname(os.path.abspath(__file__))
SCENARIOS = os.path.join(HERE, "scenarios.yaml")
FIXTURES = os.path.join(HERE, "fixtures.sql")

CONTAINER = os.environ.get("CONTAINER", "p8-dev-db")
DB = os.environ.get("DB", "p8dev")
DSN = os.environ.get("DSN", "")

# The dollar-quote tags the generated SQL uses. A scenario containing one of
# these would terminate the block early and produce a syntax error about SQL
# nobody wrote, so the loader refuses it by name instead.
TAG_BLOCK = "$evalblk$"
TAG_QUERY = "$evalq$"
TAG_TEXT = "$evaltxt$"

COMPARATORS = ("is", "isnt", "matches", "unmatches", "raises", "gt", "gte", "lt", "lte")

GRANT_TEMP = """-- as the session user, which owns nothing and may grant on everything here
reset role;
do $evalgrant$
declare t record;
begin
    for t in select c.relname, n.nspname
               from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname like 'pg\\_temp%' and c.relkind in ('r','v','m')
    loop
        execute format('grant select on %I.%I to public', t.nspname, t.relname);
    end loop;
end $evalgrant$;"""


# ---------------------------------------------------------------------------
# Running SQL
# ---------------------------------------------------------------------------
def psql(sql):
    """Run one script. Returns (ok, combined output)."""
    if DSN:
        cmd = ["psql", DSN, "-v", "ON_ERROR_STOP=1", "-q", "-f", "-"]
    else:
        cmd = ["docker", "exec", "-i", CONTAINER, "psql", "-U", "p8",
               "-d", DB, "-v", "ON_ERROR_STOP=1", "-q"]
    p = subprocess.run(cmd, input=sql, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    return p.returncode == 0, p.stdout


def sql_literal(s):
    return "'" + str(s).replace("'", "''") + "'"


# ---------------------------------------------------------------------------
# Compiling a scenario into SQL
# ---------------------------------------------------------------------------
def seat(role, claims):
    """The `set local role` + claims pair that puts a statement in one seat.

    Emitted before EVERY check rather than once per scenario, because a journey
    crosses seats -- the officer opens a run, a stranger tries to close it, and
    the assertion about what the stranger's attempt did has to be read from a
    seat that can see the row. Making the seat explicit per statement is what
    stops that from being an ordering trick nobody can see.
    """
    # A SET statement, not set_config(): the seat is usually authenticated,
    # and the roles a person can become no longer hold set_config
    # (specs/user-rbac/roles.sql §6).
    out = ["set local role %s;" % role]
    if claims is not None:
        if not isinstance(claims, str):
            claims = json.dumps(claims)
        out.append("set local request.jwt.claims = %s;" % sql_literal(claims))
    return out


def compile_check(scenario_id, index, check):
    """One check becomes one anonymous block that raises when it does not hold.

    The comparison is `is distinct from`, never `<>`. failure-modes.md §1 has
    the reason under "An assertion that cannot fail": against a missing row `<>`
    is NULL, `if NULL` is false, and the assertion passes for exactly the case
    it was written to catch.
    """
    sql = check["sql"].strip().rstrip(";")
    label = check.get("name") or "check %d" % (index + 1)
    because = check.get("because", "")

    ops = [o for o in COMPARATORS if o in check]
    if len(ops) != 1:
        raise ValueError("%s: check %d needs exactly one of %s, found %s"
                         % (scenario_id, index + 1, "/".join(COMPARATORS), ops or "none"))
    op = ops[0]
    want = check[op]

    head = """do %s
declare
    v_got  text;
    v_err  text;
    v_ok   boolean := true;
    v_lbl  text := %s;
    v_why  text := %s;
begin
    begin
        execute %s %s into v_got;
    exception when others then
        v_ok := false; v_err := sqlerrm;
    end;
""" % (TAG_BLOCK, sql_literal(label), sql_literal(because), TAG_QUERY + "\n" + sql + "\n" + TAG_QUERY,
       "")

    if op == "raises":
        body = """
    if v_ok then
        raise exception E'%%\\n  expected a refusal matching: %%\\n  but it succeeded, returning: %%\\n  guards: %%',
            v_lbl, %s, coalesce(v_got, '(no value)'), v_why;
    end if;
    if v_err !~ %s then
        raise exception E'%%\\n  refused with: %%\\n  which does not match: %%\\n  guards: %%',
            v_lbl, v_err, %s, v_why;
    end if;
""" % (sql_literal(want), sql_literal(want), sql_literal(want))
    else:
        want_sql = "null" if want is None else sql_literal(want)
        cmp_by_op = {
            "is":        "v_got is distinct from %s" % want_sql,
            "isnt":      "v_got is not distinct from %s" % want_sql,
            "matches":   "v_got is null or v_got !~ %s" % want_sql,
            "unmatches": "v_got is not null and v_got ~ %s" % want_sql,
            "gt":        "v_got is null or v_got::numeric <= (%s)::numeric" % want_sql,
            "gte":       "v_got is null or v_got::numeric <  (%s)::numeric" % want_sql,
            "lt":        "v_got is null or v_got::numeric >= (%s)::numeric" % want_sql,
            "lte":       "v_got is null or v_got::numeric >  (%s)::numeric" % want_sql,
        }
        body = """
    if not v_ok then
        raise exception E'%%\\n  raised: %%\\n  expected (%s): %%\\n  guards: %%',
            v_lbl, v_err, %s, v_why;
    end if;
    if %s then
        raise exception E'%%\\n  got: %%\\n  expected (%s): %%\\n  guards: %%',
            v_lbl, coalesce(v_got, '(null)'), %s, v_why;
    end if;
""" % (op, want_sql if want is not None else "'(null)'",
       cmp_by_op[op], op, want_sql if want is not None else "'(null)'")

    return head + body + "end " + TAG_BLOCK + ";\n"


def compile_scenario(sc):
    role = sc.get("role", "app_owner")
    claims = sc.get("claims")
    parts = ["\\set ON_ERROR_STOP on", "begin;"]
    parts += seat(role, claims)
    if sc.get("setup"):
        parts.append(sc["setup"].rstrip())
        # A scenario carries its journey between statements in temp tables, and
        # a journey crosses seats -- so a table created while setup held the
        # owner's role would be unreadable from the seat a later check runs in,
        # failing with `permission denied for table ctx` about scaffolding
        # rather than about the guarantee. The temp schema is session-local and
        # the whole transaction rolls back, so opening it costs nothing and
        # keeps every scenario from having to remember.
        parts.append(GRANT_TEMP)
    for i, check in enumerate(sc.get("check") or []):
        parts += seat(check.get("role", role), check.get("claims", claims))
        parts.append(compile_check(sc["id"], i, check))
    parts.append("rollback;")
    return "\n".join(parts) + "\n"


# ---------------------------------------------------------------------------
# Loading and validating the catalogue
# ---------------------------------------------------------------------------
def load(path):
    with open(path) as f:
        doc = yaml.safe_load(f)

    modes = {m["id"]: m for m in doc.get("failure_modes", [])}
    scenarios = doc.get("scenarios", [])

    seen, problems = set(), []
    for sc in scenarios:
        sid = sc.get("id")
        if not sid:
            problems.append("a scenario has no id")
            continue
        if sid in seen:
            problems.append("%s: duplicate id" % sid)
        seen.add(sid)
        for field in ("title", "category", "asks", "mechanism"):
            if not sc.get(field):
                problems.append("%s: missing `%s`" % (sid, field))
        if not sc.get("check"):
            problems.append("%s: no checks -- a scenario with nothing to "
                            "assert is prose" % sid)
        # A scenario that names no failure mode is a scenario nobody can say
        # what it protects. That is the whole discipline of this file.
        for fm in sc.get("catches") or []:
            if fm not in modes:
                problems.append("%s: cites unknown failure mode `%s`" % (sid, fm))
        if not sc.get("catches"):
            problems.append("%s: cites no failure mode -- say what breaking "
                            "this would look like" % sid)
        blob = json.dumps(sc)
        for tag in (TAG_BLOCK, TAG_QUERY, TAG_TEXT):
            if tag in blob:
                problems.append("%s: contains the generator's quote tag %s"
                                % (sid, tag))
    return doc, modes, scenarios, problems


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fixture", action="store_true",
                    help="(re)load fixtures.sql before running")
    ap.add_argument("-k", "--match", help="substring of id or title")
    ap.add_argument("-c", "--category", help="one category")
    ap.add_argument("--list", action="store_true", help="list, do not run")
    ap.add_argument("--json", action="store_true", help="machine-readable result")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="print the generated SQL of every failure")
    ap.add_argument("--only-status", help="only scenarios with this status")
    args = ap.parse_args()

    doc, modes, scenarios, problems = load(SCENARIOS)
    if problems:
        print("scenarios.yaml does not validate:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 2

    picked = scenarios
    if args.category:
        picked = [s for s in picked if s["category"] == args.category]
    if args.match:
        m = args.match.lower()
        picked = [s for s in picked
                  if m in s["id"].lower() or m in s["title"].lower()]
    if args.only_status:
        picked = [s for s in picked if s.get("status", "pass") == args.only_status]

    if args.list:
        by_cat = {}
        for s in scenarios:
            by_cat.setdefault(s["category"], []).append(s)
        for cat in sorted(by_cat):
            print("\n%s (%d)" % (cat, len(by_cat[cat])))
            for s in by_cat[cat]:
                flag = "" if s.get("status", "pass") == "pass" else \
                       "  [%s]" % s["status"]
                print("  %-14s %s%s" % (s["id"], s["title"], flag))
        print("\n%d scenarios, %d failure modes, %d categories"
              % (len(scenarios), len(modes), len(by_cat)))
        return 0

    if args.fixture:
        with open(FIXTURES) as f:
            ok, out = psql(f.read())
        if not ok:
            print("fixture load FAILED:\n" + out, file=sys.stderr)
            return 2
        for line in out.splitlines():
            if line.startswith("NOTICE:"):
                print("  " + line[9:])

    results, t0 = [], time.time()
    # Scenarios whose status is not `pass` are known-open findings: they are run
    # anyway, because a finding that quietly starts passing is as interesting as
    # one that starts failing, and they do not fail the suite.
    for sc in picked:
        sql = compile_scenario(sc)
        ok, out = psql(sql)
        status = sc.get("status", "pass")
        results.append({"id": sc["id"], "category": sc["category"],
                        "title": sc["title"], "declared": status,
                        "ok": ok, "output": out, "sql": sql})

    if args.json:
        print(json.dumps([{k: r[k] for k in ("id", "category", "title",
                                             "declared", "ok")}
                          for r in results], indent=2))

    hard_failures = 0
    surprises = []
    cat = None
    for r in results:
        if not args.json and r["category"] != cat:
            cat = r["category"]
            print("\n=== %s %s" % (cat, "=" * max(0, 56 - len(cat))))
        expected_ok = r["declared"] == "pass"
        if r["ok"] and expected_ok:
            mark = "ok"
        elif r["ok"] and not expected_ok:
            mark = "NOW PASSES (declared %s)" % r["declared"]
            surprises.append(r)
        elif not r["ok"] and not expected_ok:
            mark = "open (%s), as declared" % r["declared"]
        else:
            mark = "FAILED"
            hard_failures += 1
        if not args.json:
            print("  %-14s %-46s %s" % (r["id"], r["title"][:46], mark))
            if mark == "FAILED":
                for line in r["output"].splitlines():
                    if line.startswith(("ERROR:", "DETAIL:", "  ", "CONTEXT:")):
                        print("      " + line)
                if args.verbose:
                    print("      --- generated SQL ---")
                    for line in r["sql"].splitlines():
                        print("      " + line)

    if args.json:
        return 1 if hard_failures else 0

    dt = time.time() - t0
    print("\n%d scenarios in %.1fs -- %d failed, %d declared-open, %d newly passing"
          % (len(results), dt, hard_failures,
             sum(1 for r in results if r["declared"] != "pass"), len(surprises)))
    if surprises:
        print("\nA declared-open finding now passes. Either it was fixed -- "
              "update its `status` and say where -- or the check stopped "
              "checking:")
        for r in surprises:
            print("  %s  %s" % (r["id"], r["title"]))
    if hard_failures:
        print("\nFAILED -- a scenario the suite says holds no longer does.")
        return 1
    print("All scenarios behaved as declared.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
