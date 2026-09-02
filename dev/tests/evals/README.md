# The evals — journeys, run

```bash
./run.py --fixture        # load the fixture, then run everything
./run.py                  # run everything against the fixture already loaded
./run.py -c recovery      # one category
./run.py -k hitl-04       # one scenario
./run.py --list           # what is in here, without running it
./run.py -v               # print the generated SQL of every failure
DSN="postgres://…" ./run.py
```

Three files. `fixtures.sql` is one domain, loaded once. `scenarios.yaml` is the
catalogue — 109 scenarios over 8 categories, each citing which of 28 named
failure modes it would notice. `run.py` compiles each scenario to SQL, runs it
in a transaction, and rolls back.

## Why this is not `../run.sh`

The SQL suites next door test a **mechanism** against its spec: does
`expand_matrix` rewire its successors, does RLS filter a walk mid-traversal.
This tests a **journey**: somebody wants to know which corporate group is
behind a safety signal, or wants a run to stop until a person decides and then
act on what they decided.

They find different things, and the difference is not coverage. A mechanism can
be correct at every step of a journey that cannot be completed. `signal:`
works — it parks the run, it refuses a stranger, it cancels cleanly, it stamps
`completed_at` — and until `hitl-04` was written, nothing had ever tried to
*read what the person said* from the step that acts on it. That is one function
call away from every existing assertion and on the other side of a wall.

Three of the six open findings below were found the same way: by walking a
journey end to end rather than by testing the parts of it.

## The eval language

```yaml
  - id: hitl-04
    category: human-in-the-loop
    title: The officer's decision reaches the step that acts on it
    asks: "Record what they decided."
    mechanism: "YAML.md § Templates -- every step nests its payload under `result`"
    catches: [silent-success, never-executed, unreachable-capability]
    status: open-defect
    claims: '{"sub":"55000000-…","orgs":[]}'
    setup: |
      … SQL, run first, in the scenario's transaction …
    check:
      - name: and it reaches runs.context, where every template reads from
        sql: "select context ? 'officer' from workflow.runs where id=(…)"
        is: "true"
        because: "THIS IS THE FINDING. `complete_task` merges a task's output …"
```

| Field | Is |
|---|---|
| `asks` | the question **in the user's words**, not the schema's. A scenario that can only be stated in table names is a mechanism test in the wrong file. |
| `mechanism` | the spec section, table or function that is supposed to answer it. |
| `catches` | ids from this file's `failure_modes:` block. The loader refuses a scenario citing none, or citing one that does not exist. |
| `status` | `pass`, or an open finding — see below. |
| `role` / `claims` | the seat. Settable per **check**, because a journey crosses seats. |
| `check[].because` | which guarantee the check protects. Not a comment — it is what a red line says. |

Comparators: `is` `isnt` `matches` `unmatches` `gt` `gte` `lt` `lte` `raises`.
`sql` returns a single value. `is` compiles to `is distinct from`, never `<>`,
for the reason `failure-modes.md` §1 gives under *An assertion that cannot
fail*: against a missing row `<>` is NULL, `if NULL` is false, and the
assertion passes for exactly the case it was written to catch.

**The seat is on the statement, not on the scenario.** `hitl-05` starts a run as
the officer, attempts the signal as a stranger, and reads the untouched task as
the owner — three seats, three lines, no ordering trick. Asserting "the write
was refused" from the *stranger's* seat would pass whether or not the write
happened, because the stranger cannot see the row either way.

## Verdicts

`status: pass` means the journey completes. Anything else is an open finding:
run anyway, not counted as a suite failure, and **reported loudly if it starts
passing** — a finding that quietly goes green is either a fix nobody recorded
or a check that stopped checking.

| | |
|---|---|
| `pass` | the journey completes and every assertion holds |
| `open-defect` | the journey does not complete; the check pins the defect |
| `open-doc` | the behaviour is right and the document describing it is not |
| `not-shipped` | the mechanism is deliberately outside the product today |

## What is open right now

Six, and four of them are the same shape: a rule applied at the site that hurt
and not at the other sites that perform the same transition.

| Scenario | Finding |
|---|---|
| `hitl-04` | **A `signal:` task's output never reaches `runs.context`.** `complete_task` merges it; `signal_task` and `promote_due_timers` set status, output and `completed_at` and merge nothing. So `{{steps.<signal>.result}}` resolves to nothing and the acting step fails with `template 'steps.officer.result' resolved to nothing`. The second half of every human-in-the-loop workflow — *act on what they said* — is unreachable from the document. `dev/examples/08-wait.sql` does not notice because it waits, resumes, and never reads the payload. |
| `hitl-08` | **A `timer:` that is a ROOT step ignores its delay.** `delay_seconds` is applied by `autorun_sql_steps`, which is `after update of status` and fires only on the transition *into* ready — and a root timer is INSERTED ready. `run_after` stays `now()`, the next tick fires it, and a `timer: 3600` waits zero seconds with every task `done`. This is `failure-modes.md` §5's own *trigger that fires only on the transition you did not take*, reopened at the timer branch of that same trigger. `hitl-08b` shows the non-root case working, which is why nothing noticed. |
| `upload-13` | **`record_chunks` silently drops a span key it does not recognise** — and `dev/examples/05-upload.sql`, whose output is quoted on the published *Ten things, worked through* page under the heading "what the parser produced, **with spans back into the source**", passes `start_char`/`end_char` where the writer reads `start_offset`/`end_offset`. Every span that example records is NULL and the call returns the chunk count. |
| `recov-13` | **`claim_task` returns one row of NULLs on an empty queue**, because it is declared `returns workflow.tasks` rather than `setof`. A worker written the obvious way treats an empty queue as a task arriving, on the most-called function in the worker contract, and `spec.md` §4 documents the signature with no note that emptiness is spelled this way. |
| `qs-19` | **A literal JSON argument written as a quoted string arrives as a jsonb scalar**, and the run fails with Postgres's `cannot extract elements from a scalar` — true, and about a value the author cannot see. `lint_spec` holds the registered argument types and could refuse it while the author is still looking at the document. |
| `coll-13` | `content.connectors` is deliberately **not shipped** — recorded as a scenario rather than left as an absence, because a missing thing and an excluded thing are the same absence, and without somewhere to write the reason nobody re-examines either. |

Each is pinned by a check that goes red today and will go green the moment it
is fixed, at which point `run.py` says so by name.

## The fixture

`calder`, a pharmacovigilance desk: sponsors, the products they make, the sites
and investigators running trials on them, the safety signals raised against
them, and sixty case reports that are rows nobody looks up by name.

It is one domain rather than a hundred because the interesting scenarios are
the ones where a query written for the retrieval category is answered by data
the graph category put there. `f2g-10` is the shape: a graph written by the
ingestion path, read by the query path, inside a workflow. Every bug this repo
has found has lived in a seam.

Four things in it are load-bearing and easy to flatten by accident:

- **A three-hop chain.** `SIG-114 → tolvaxen → ALTM → NVRA`. "Which corporate
  group is behind this signal" is unanswerable at depth 1, unanswerable at
  depth 2, and answered at depth 3 — and the walk widens 1 → 9 → 18 on the way.
  A fixture where the first width already contains the answer proves nothing
  about iteration, and hides that widening is expensive.
- **Decorrelated columns.** An earlier version keyed product, site and
  seriousness off the same modulus, so partitioning by product also partitioned
  by seriousness, no column varied inside a batch, and `coll-06` passed while
  testing nothing. `coll-06`'s first check now asserts the fixture's own
  precondition. `site` is left constant per product on purpose, so `coll-06b`
  can assert the leniency that refusal is the flip side of.
- **Its own corpus and its own space.** Nothing here writes into
  `content.resource_chunks` or the `chunks` source, because that corpus is what
  `../query/08-retrieval.sql` ranks against and a second corpus in it changes
  those rankings. The upload scenarios create their `content.*` rows inside
  their own transaction — which is also more honest about what an upload is.
- **RLS that the fixture had to add itself.** Registering a source grants
  nothing and imposes nothing (`USAGE.md` says so in the two things
  registration does *not* do). Without policies on `calder.*`, every tenancy
  scenario would pass for the wrong reason. Not `force`, though: the owner is
  who reloads the fixture, and the engine executes a `sql:` step as a
  `SECURITY DEFINER` function acting on its own behalf. The tenancy scenarios
  run as `authenticated` instead, which is the seat the guarantee is about.

The fixture asserts two invariants about itself on load (exactly one sponsor
excluded by the inclusion policy; sixty case reports), because a scenario suite
whose fixture drifted reports failures about the wrong thing.

## Adding one

Same rule as `../README.md`: **a scenario earns its place by failing when a
guarantee is quietly removed.** Break the thing it protects and watch it go red
before you keep it. An assertion nobody has seen fail is documentation wearing
a test's clothes.

Two failure modes specific to this file, both met while writing it:

- **A check that passes because the fixture is degenerate.** `coll-06` above.
  If a scenario depends on a property of the data, assert that property first.
- **A check written from the wrong seat.** Reading `workflow.tasks` as
  `authenticated` raises `permission denied` — which the runner reports as a
  failure of the guarantee rather than of the query. Read through the `*_api`
  views, or say `role: app_owner` on that check and say why in `because`.

`../../../scenarios/` is upstream of this directory: exploration and verdicts in
prose. This is where the ones worth re-running forever get pinned, executable.
`meta/skills/dogfooding` is the method that generates them.
