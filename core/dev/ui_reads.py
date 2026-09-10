#!/usr/bin/env python3
"""Execute every screen's read against a deployment. No browser, no provider.

This is the Surface screen with the browser taken out, and it exists because
the browser was the only thing that ever ran these queries. Five screens
shipped asking PostgREST for columns no view has -- `structured_output`,
`transport`, `name`, `created_at`, `event` -- and the in-app audit reported
"31 of 31 reachable" throughout, because it probed each view with `limit=1`
and no projection. A read nobody executes is a read nobody checks.

So the projections live in `percolate_core/ui/static/reads.js` as data, and
both callers run the same string: the page through `read()`, this script
through `node`. It imports that module rather than parsing it, which is why
that module imports nothing itself.

    . dev/env.sh && python3 dev/ui_reads.py
    P8_REST_URL=http://localhost:5611 python3 dev/ui_reads.py

Exit status is the point: non-zero if any screen read fails, so it can gate a
deployment. A refused read (42501) counts as a failure here -- with the token
this script mints, a permission error means the grant is missing, which breaks
the screen just as thoroughly as a missing column.

What it deliberately does NOT do: call the runtime for a model turn. Transport
readiness and a real answer from a provider are different claims and only one
of them is free; `--runtime` asks the free half (`GET /_build`).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
READS_JS = HERE.parent / "percolate_core" / "ui" / "static" / "reads.js"

REST = os.environ.get("P8_REST_URL", "http://localhost:5611").rstrip("/")
CORE = os.environ.get("P8_CORE_URL", "").rstrip("/")


def contracts() -> tuple[list[dict], list[dict]]:
    """The contract table, read by the runtime that owns the syntax.

    `node` rather than a parser of our own: a regular expression that believes
    it understands a JavaScript object literal is a second implementation of
    JavaScript, and it will be wrong about a string containing a brace long
    before anybody notices.
    """
    script = (
        f"import({json.dumps(READS_JS.as_uri())}).then((m) => "
        "console.log(JSON.stringify({reads: m.READS, probes: m.PROBES})))"
    )
    try:
        out = subprocess.run(["node", "--input-type=module", "-e", script],
                             capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        sys.exit("node is not installed, and it is what reads reads.js. "
                 "brew install node, or run the Surface screen in a browser instead.")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"could not import {READS_JS}:\n{exc.stderr.strip()}")
    data = json.loads(out)
    reads = [dict(key=k, **v) for k, v in data["reads"].items()]
    return reads, data["probes"]


def get(url: str, headers: dict[str, str]) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as res:
            return res.status, ""
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(body)
            return exc.code, f"{parsed.get('code', '')} {parsed.get('message', '')}".strip()
        except ValueError:
            return exc.code, body[:120]
    except urllib.error.URLError as exc:
        return 0, f"{REST} unreachable: {exc.reason}"


def token() -> str:
    """The caller identity. A read audited as nobody is not the read a screen makes."""
    if os.environ.get("P8_REST_TOKEN"):
        return os.environ["P8_REST_TOKEN"]
    sys.path.insert(0, str(HERE))
    from mint_jwt import mint  # noqa: E402  -- dev-only, and only when unset

    # The default sub need not have a row in rbac.users, and does not have one
    # in dev: no read here follows a foreign key to a user, so what matters is
    # that PostgREST switches to `authenticated` and the policies evaluate a
    # real current_user_id(). Such a caller simply owns nothing, which exercises
    # every grant and every projection while returning the org-visible rows.
    # Set P8_USER_ID to audit as somebody with data.
    return mint(os.environ.get("P8_USER_ID", "aaaaaaaa-0000-0000-0000-000000000001"))


def run(contract: dict, auth: dict[str, str]) -> tuple[str, str]:
    """ok, absent or fail -- and `absent` is narrower than it looks.

    A contract carrying `absent` names a component this deployment may not have
    installed, and 42P01 on it is the expected answer rather than a broken
    screen. Nothing else is forgiven: a relation that EXISTS still has to serve
    the projection, because a wrong column is the exact defect this table was
    written to catch, and letting absence stand in for it would put the check
    back where it started.
    """
    query = "&".join(x for x in (contract.get("q") or "", "limit=1") if x)
    status, detail = get(f"{REST}/{contract['view']}?{query}",
                         {**auth, "Accept-Profile": contract["schema"]})
    if status == 200:
        return "ok", detail
    if contract.get("absent") and detail.startswith("42P01"):
        return "absent", contract["absent"]
    return "fail", detail


def main() -> int:
    reads, probes = contracts()
    auth = {"Authorization": f"Bearer {token()}", "Accept": "application/json"}
    print(f"{len(reads)} screen reads against {REST}\n")

    failed, absent = [], []
    for c in sorted(reads, key=lambda x: (x["screen"], x["view"])):
        verdict, detail = run(c, auth)
        if verdict == "fail":
            failed.append((c, detail))
        elif verdict == "absent":
            absent.append((c, detail))
        label = {"ok": "ok  ", "absent": "n/a ", "fail": "FAIL"}[verdict]
        print(f"  {label}  {c['screen']:<20} "
              f"{c['schema']}.{c['view']:<24} {detail}")

    print()
    for p in probes:
        verdict, _ = run({**p, "q": ""}, auth)
        label = {"ok": "ok  ", "absent": "n/a ", "fail": "warn"}[verdict]
        print(f"  {label}  {'(existence only)':<20} "
              f"{p['schema']}.{p['view']:<24} {p['why']}")

    if CORE:
        status, detail = get(f"{CORE}/_build", {})
        print(f"\n  runtime {CORE}/_build -> {status or 'unreachable'} {detail}")
        print("  (transport and build identity only; a model turn is not free "
              "and is not checked here)")

    if absent:
        print(f"\n{len(absent)} read(s) name a component this deployment "
              f"has not installed, which is not a defect:")
        for c, why in absent:
            print(f"  {c['screen']}: {c['schema']}.{c['view']} -- {why}")
        print("  The screen renders the refusal and names the file to apply. "
              "A projection\n  error on any of these would still fail above.")

    if failed:
        print(f"\n{len(failed)} screen read(s) failed:")
        for c, detail in failed:
            print(f"  {c['screen']}: {c['schema']}.{c['view']} -- {detail}")
            print(f"    contract `{c['key']}` in {READS_JS.name}: {c.get('q') or '(whole row)'}")
        return 1
    print(f"\nAll {len(reads) - len(absent)} installed screen reads returned 200.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
