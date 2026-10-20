#!/usr/bin/env python3
"""Cost per call of every research-platform function a signed-in caller can reach (REM-500).

    python3 probe.py CONTAINER DB OUT.json [REPEATS]

Each probe runs as `authenticated` with a real person's claims, under row security, inside a transaction
that is rolled back, so a write probe leaves nothing behind. Cost is read from EXPLAIN (ANALYZE, BUFFERS):
shared buffers hit plus read, which counts every page the call touched including those touched by the
functions it calls, and does not depend on the machine the way milliseconds do. The median of REPEATS runs
after one warm-up.

The probe objects are the same logical objects at every size: work 2 (listed, public), work 3 (private),
their heads, and the owner of work 2 as the caller. So a number that grows between sizes grew because the
tables did, not because the probe changed.
"""
import json
import statistics
import subprocess
import sys
from pathlib import Path

C, DB, OUT = sys.argv[1:4]
REPEATS = int(sys.argv[4]) if len(sys.argv) > 4 else 5

def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", C, "psql", "-U", "postgres", "-d", DB, "-At", "-q", "-v", "ON_ERROR_STOP=1"],
                       input=sql, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[:1500])
    return [l for l in r.stdout.splitlines() if l.strip()]

# The caller, the probe objects, and a role that lets the caller write, created once per database.
setup = psql("""
insert into rbac.roles (name, description) values ('scale-writer', 'REM-500 probe') on conflict do nothing;
insert into rbac.role_permissions (role, resource, action)
select 'scale-writer', r, a from (values ('research','insert'), ('research','list'), ('research','publish'), ('research','endorse'),
                                          ('engagement','insert')) v(r, a) on conflict do nothing;
select w.owner_id, w.id, (select revision_id from research.heads where work_id = w.id),
       (select id from research.revisions where work_id = w.id and number = 1),
       w3.id, (select revision_id from research.heads where work_id = w3.id), w3.owner_id,
       (select count(*) from research.claims),
       (select h.revision_id from research.works o join research.heads h on h.work_id = o.id
         where o.visibility = 'public' and o.owner_id <> w.owner_id order by o.public_id limit 1)
  from research.works w, research.works w3 where w.public_id = 'scale-2' and w3.public_id = 'scale-3';
""")
me, work2, head2, rev2_1, work3, head3, owner3, claims, others_head = setup[-1].split("|")
psql(f"insert into rbac.user_roles (user_id, role) values ('{me}', 'scale-writer') on conflict do nothing;")

DOC = json.dumps({"schema_version": "0.1", "title": "A scale probe package", "summary": "Written by the REM-500 probe and rolled back.",
                  "claims": [{"id": f"C{k}", "kind": "Inference", "text": f"probe claim {k} w12 w7", "source_ids": ["S1"], "locator": ""} for k in range(1, 7)],
                  "sources": [{"id": "S1", "title": "S", "url": "https://example.test/1", "origin": "doi:10.500/1", "status": "read", "locator": "p1"}],
                  "edges": [{"source": "C1", "relation": "supports", "target": "C2"}]}).replace("'", "''")

PROBES = {
    # reads a person makes on every page
    "get_package head":            f"select research.get_package('scale-2', null)",
    "get_package draft-1":         f"select research.get_package('scale-2', 'draft-1')",
    "list_packages (all readable)": "select count(*) from research.list_packages(false)",
    "list_packages first 20":      "select * from research.list_packages(false) limit 20",
    "list_packages owned":         "select count(*) from research.list_packages(true)",
    "list_listed first 20 (fix)":  "select count(*) from research.list_listed(null, 20)",
    "search_claims common (fix)":  "select count(*) from research.search_claims('w7 w12', 20)",
    "search_claims rare (fix)":    "select count(*) from research.search_claims('w391 w399', 20)",
    "trust":                       f"select research.trust('{head2}')",
    "trust_state":                 "select research.trust_state('scale-2', now())",
    "readable":                    f"select research.readable('{work2}')",
    "revision_readable":           f"select research.revision_readable('{head2}')",
    "visible_head":                f"select research.visible_head('{work2}')",
    "work_readable_in_full":       f"select research.work_readable_in_full('{work2}')",
    "endorsements_affected_by":    f"select count(*) from research.endorsements_affected_by('{head2}')",
    "revision_signals":            f"select engagement.revision_signals('{head2}')",
    "my_saves":                    "select count(*) from engagement.my_saves()",
    # direct reads through row security, as an application or PostgREST makes them
    "claims of a revision":        f"select count(*) from research.claims where revision_id = '{head2}'",
    "claims matching a word":      "select id from research.claims where search_tsv @@ to_tsquery('simple', 'w7 & w12') limit 20",
    "claims matching a rare word": "select id from research.claims where search_tsv @@ to_tsquery('simple', 'w391 & w399') limit 20",
    # aiq.lexical refuses research_claims and research_sources since REM-519; results/ keeps what it cost
    "search_sources common":       "select count(*) from research.search_sources('source 3', 20)",
    "search_sources no match":     "select count(*) from research.search_sources('w391', 20)",
    "a source's other citations":  "select count(*) from research.sources where origin = 'doi:10.500/5'",
    "comments on a revision":      f"select count(*) from engagement.comments where revision_id = '{head2}'",
    "useful votes on a revision":  f"select count(*) from engagement.votes where revision_id = '{head2}' and withdrawn_at is null",
    # writes, rolled back
    "submit_package":              f"select research.submit_package('{DOC}'::jsonb, 'scale-probe', null)",
    "revise_package":              f"select research.revise_package('scale-2', '{DOC}'::jsonb, (select label from research.revisions where id = '{head2}'), 'probe')",
    "set_useful (another's work)": f"select engagement.set_useful('{others_head}', true)",
    "add_comment":                 f"select engagement.add_comment('{head2}', 'a probe comment', 'C1')",
    "endorse":                     f"select research.endorse('{head2}', 'the sources', 'each citation', array['C1'])",
    "set_saved":                   f"select engagement.set_saved('{work2}', true)",
}

def measure(sql, n):
    """n warm runs of one probe in ONE session: plans, catalog caches and the function's own prepared
    statements are warm after the first, which is how a pooled connection serves a person. Each run is
    its own rolled-back transaction."""
    one = f"""begin;
set local role authenticated;
explain (analyze, buffers, format json) {sql};
rollback;
select '---';"""
    out = psql(f"""select set_config('request.jwt.claims', '{{"sub": "{me}"}}', false) is not null;\n""" + one * (n + 1))
    blocks, cur = [], []
    for line in out[1:]:
        if line == "---":
            blocks.append(json.loads("".join(cur))[0]); cur = []
        else:
            cur.append(line)
    runs = [(b["Plan"].get("Shared Hit Blocks", 0) + b["Plan"].get("Shared Read Blocks", 0), b["Execution Time"]) for b in blocks]
    return runs[1:] if n > 0 else runs

def measure_operator(sql, n):
    """The same as measure(), as app_owner, which is who may call operator functions such as erase_work."""
    one = f"""begin;
set local role app_owner;
explain (analyze, buffers, format json) {sql};
rollback;
select '---';"""
    out = psql(one * (n + 1))
    blocks, cur = [], []
    for line in out:
        if line == "---":
            blocks.append(json.loads("".join(cur))[0]); cur = []
        else:
            cur.append(line)
    return [(b["Plan"].get("Shared Hit Blocks", 0) + b["Plan"].get("Shared Read Blocks", 0), b["Execution Time"]) for b in blocks[1:]]

OPERATOR = {
    # Erasure cascades from works into every table that references them; each cascaded row looks up
    # its children, so a child table without an index on its reference is scanned once per parent row.
    "erase_work (operator)": "select research.erase_work('scale-5', 'REM-500 probe, rolled back')",
}

# The generator skips foreign-key checks for speed; make sure nothing it wrote dangles.
INTEGRITY = psql("""
select (select count(*) from research.heads h where not exists (select 1 from research.revisions r where r.id = h.revision_id))
     + (select count(*) from research.citations c where not exists (select 1 from research.claims k where (k.revision_id, k.claim_key) = (c.revision_id, c.claim_key)))
     + (select count(*) from research.argument_edges e where not exists (select 1 from research.claims k where (k.revision_id, k.claim_key) = (e.revision_id, e.target_claim_key)))
     + (select count(*) from engagement.votes v where not exists (select 1 from research.revisions r where r.id = v.revision_id))""")[-1]
if INTEGRITY != "0":
    raise SystemExit(f"the corpus has {INTEGRITY} dangling references; the generator is wrong")

results = {"db": DB, "claims": int(claims), "probes": {}}
# Probes already shown to grow with the table at two smaller sizes can be skipped at the largest, where
# one call of each would take tens of minutes: SKIP="name|name" (probe names contain commas). A skipped probe is recorded as skipped.
import os
SKIP = {x.strip() for x in os.environ.get("SKIP", "").split("|") if x.strip()}
ONCE = {x.strip() for x in os.environ.get("ONCE", "").split("|") if x.strip()}
for name, sql in PROBES.items():
    if name in SKIP:
        results["probes"][name] = {"skipped": "grew with the table at the two smaller sizes"}
        print(f"{name:32} skipped", flush=True)
        continue
    try:
        # One warm call first. A call over 5 s is already an answer, and repeating it only costs minutes.
        runs = measure(sql, 0 if name in ONCE else 1)
        if name not in ONCE and runs[0][1] < 5000:
            runs = measure(sql, REPEATS)
        results["probes"][name] = {"buffers": statistics.median(b for b, _ in runs), "ms": round(statistics.median(t for _, t in runs), 3)}
    except RuntimeError as e:
        results["probes"][name] = {"error": str(e).splitlines()[0][:300]}
    print(f"{name:32} {results['probes'][name]}", flush=True)
for name, sql in OPERATOR.items():
    try:
        runs = measure_operator(sql, REPEATS)
        results["probes"][name] = {"buffers": statistics.median(b for b, _ in runs), "ms": round(statistics.median(t for _, t in runs), 3)}
    except RuntimeError as e:
        results["probes"][name] = {"error": str(e).splitlines()[0][:300]}
    print(f"{name:32} {results['probes'][name]}", flush=True)
Path(OUT).write_text(json.dumps(results, indent=1))
