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

One, and it is not a defect: `coll-13` records that `content.connectors` is
deliberately outside the product, because a missing thing and an excluded thing
are the same absence and without somewhere to write the reason nobody
re-examines either.

The five findings this suite was written to pin are closed, and each scenario
now asserts the fixed behaviour rather than the defect:

| Scenario | Was | Fix |
|---|---|---|
| `hitl-04` | A `signal:` task's output never reached `runs.context`, so `{{steps.<signal>.result}}` resolved to nothing and the second half of every human-in-the-loop workflow was unreachable from the document. | `workflow.merge_step_context()`, called by all three paths that mark a task done — **before** the transition, because a `sql` successor auto-runs inside the statement that marks it ready. The payload is nested under `result` like every other kind. |
| `hitl-08` | A `timer:` that was a root step ignored its delay, because `delay_seconds` was applied by an `after update of status` trigger and a root timer is *inserted* ready. | `workflow.apply_timer_delay()` with an AFTER INSERT trigger beside the existing update path; the update stamp is unconditional so a non-root timer is still measured from readiness. |
| `upload-13` | `record_chunks` silently dropped an unrecognised span key, and two published pages passed the spelling it does not read. | The key set is checked **before** the DELETE, and the refusal names `start_offset`. Docs corrected in get-percolate. |
| `recov-13` | `claim_task` returned one row of NULLs on an empty queue, being `returns workflow.tasks`. | `returns setof workflow.tasks`. Callers using `select * from` are unaffected. |
| `qs-19` | A quoted JSON literal reached a `jsonb` step function as a scalar and failed at dispatch with a message naming neither the argument nor the remedy. | `lint_spec` refuses it at authoring time — and `qs-19` asserts that a **template** in the same position is *not* refused, because the first version of that rule rejected the shipped `ask_uploads` workflow at install time. |

All four defects were one shape: a rule applied at the site that hurt and not at
the other paths performing the same transition. Each fix is therefore a function
with N callers rather than a statement with one, so the enumeration is a grep.

**And one correction that came from reading, not running.** The
`iterated-query` category originally asserted the *width* of a walk at each
depth — `is: "18"` — which is fixture arithmetic, not a specified guarantee: an
extra edge in the fixture turns it red for no reason anyone cares about. Those
scenarios now assert what the spec actually promises (one row per node at its
shortest depth, `path_weight` as the product along the path, the refusals) and,
in `iter-01` and `iter-02`, that the **property graph** and the recursive walk
answer the same question the same way. PG19 rejects a path *quantifier* but
accepts a fixed-length chain — so "GRAPH_TABLE cannot do depth n" was too
strong, and `schema.sql` now says the narrower true thing.

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
