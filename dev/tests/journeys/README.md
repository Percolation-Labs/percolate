# Journey materials

The fixture half of `../../../scenarios/evals/`. What a journey eval's cast
acts **on** — file bodies, the chunks a parser would have produced, the graph an
extractor would have proposed, the workflow definitions they author.

**What is deliberately not here: orgs, users, memberships, agents, sessions,
runs.** Every one of those is something a user *does*, and the journey is an
agent doing them. A fixture that pre-created them would have already performed
the half of the journey most likely to be broken — which is not a hypothetical
here. `../../../meta/postmortems/2026-09-04-user-rbac-review.md` records the signup
path and the refresh-token theft branch both shipped, both declared in the spec,
and neither ever executed; the first transaction to run them found the account
signup creates cannot log in, and found a revocation that revoked nothing.
Nothing in this directory calls a percolate function, so loading it cannot make
a journey pass.

## Build a journey database

```bash
dev/reload.sh p8journey
docker exec -i p8-experiment-pg19 psql -U p8 -d p8journey -v ON_ERROR_STOP=1 \
    < dev/tests/journeys/materials.sql
```

`reload.sh` also loads `dev/init/` files 02 through 09, so a journey database arrives with the
sample graph, the sample corpus and the `demo-quad-a` embedding space already
in it — under a dev org that belongs to none of the cast. That is a feature: it
is another tenant's data sitting in the same tables, which makes Act 8's tenancy
questions worth asking instead of being satisfied by an empty database.

## Re-running a journey

**Rebuild.** The two commands above, in order. There is no teardown script here
on purpose: a journey's whole point is that it does not roll back, so a partial
teardown is a second description of everything the journey touches, and it would
start falling behind the first time an act was added. `challenge-the-process` §3
— deleting a step beats automating one.

## Never load this into the suite's database

`materials.sql` grants nothing to `authenticated` or `web_anon` and asserts that
at the end of its own load, because a table granted to an application role and
carrying no policy is precisely the defect `../rbac/05-read-surface.sql`
enumerates for. The grant discipline means loading it elsewhere would not break
that gate — but the journey *writes*, and the suite's fixtures assert counts.
Use a database of your own. `../../../meta/postmortems/` records four sessions
sharing `p8reload` and the hour of verification it cost.

## What is in it

| Table | Rows | Is |
|---|---|---|
| `journey.documents` | 5 | File bodies, with `size_bytes` and `checksum` generated, so a re-upload of the same bytes is recognisable as the same file |
| `journey.chunks` | 10 | Spans with `start_offset`/`end_offset` and a 4-dimension literal vector in the `demo-quad-a` space |
| `journey.probes` | 4 | Named query vectors, each with the document it **should** rank first and why |
| `journey.graphs` | 2 | `aiq.land_graph`-shaped payloads; the chain is three hops deep on purpose |
| `journey.workflows` | 2 | Unparsed YAML, because `define_yaml` is the thing under test |

Two of those carry a design decision worth not flattening:

**`probes` writes the expected winner down beside the vector.** A step whose
expectation is formed after the answer is seen is a step that cannot fail — the
class `../../../meta/postmortems/README.md` names as the largest recurring one here.
The vectors are near-unit along one axis each (1 scour, 2 bearings, 3 consent,
4 cost), so which chunk wins is arithmetic a reader checks by eye rather than a
property of whichever model happened to be installed.

**`workflows.mill_lane_triage` names one of its dependencies twice.** That is
the shape that deadlocked a run in silence in `cc0fc91`, fixed by
`workflow.outstanding_deps` counting `distinct` ids. If a run from that
definition never completes, the fix has come undone — and a run that never ends
looks exactly like a run that is merely slow, which is why the act that starts
it says how long to wait before calling it.
