# The three surfaces

```bash
./run.sh              # all three, in order
./run.sh query        # one
DSN="postgres://…" ./run.sh
```

This repository has exactly three test surfaces, and they are not one concern
among many — they are **the** concern. Everything else in the collection is
composed out of them: ingestion is workflows over content, the graph is queries
over RBAC-scoped rows, an agent is a workflow that calls a query. A defect in
one of the three does not stay in one of the three.

| Directory | Surface | Its characteristic failure |
|---|---|---|
| `rbac/` | `user-rbac`, and the RLS it imposes on all four other subsystems | Returning **more** rows than it should. The only surface where a bug is a breach, and the only one whose failure no happy-path assertion will ever notice. |
| `query/` | `ai-query-layer` — seven modes over three index families | A **wrong answer**, not an error. Nothing crashes; the caller simply gets something other than what the spec promised. |
| `workflow/` | `workflow-engine` — retries, sagas, compensation, cancellation, crash recovery | A **partial** failure that reports success. Every interesting workflow bug found here has left every task marked `done`. |

RBAC runs first, deliberately: if row-level security is not actually switched
on, every later assertion about who-sees-what is meaningless.

## What belongs here, and what does not

These files are not a coverage exercise. Per
`meta/skills/spec-driven-development` §4, the suite is roughly a tenth of the
failure modes worth naming — the ones that protect **intent** against silent
erosion. Nearly every assertion in `rbac/02`, `query/02` and `workflow/01`
corresponds to a bug this repo actually shipped and found by executing a
scenario, not by imagining one.

The general rule for adding to it: **a test earns its place by failing when a
guarantee is quietly removed**, not by exercising a path that already works.
Before adding one, break the thing it protects and confirm the test notices —
an assertion that cannot fail is documentation wearing a test's clothes.

## The third question, which neither of these asks

`run.sh` asks whether the database still BEHAVES as the specs promise.
`../../surface.sql` asks whether every promised capability EXISTS. Both passed
clean against a stack whose `aiq.query()` had no `SCHEMA` route and whose
`percolate_parser.so` was missing six step kinds, because **existence is not
currency** and nothing was asking the third question:

```bash
../currency.sh          # is the database RUNNING what the specs SAY?
```

It builds a pristine database from the committed extension script and diffs
`pg_proc` against the target -- body hash, `prosecdef` and `search_path` -- so
Postgres does the dollar-quote parsing instead of a regex that would be wrong
about this schema's nested `$q$`/`$f$` tags. Its first run on the dev stack
found seven stale `aiq.*` bodies, one function that had silently lost
`SECURITY DEFINER`, and `content.connectors*` present in the database and
absent from the product.

`scenarios/` is upstream of this directory. Exploration happens there; what
turns out to be worth re-running forever gets pinned here.

## What is deliberately not tested here

**`percolate-core`, the Python services.** It is a dependency consumed at a
contract — the Content Server's and Agent Runtime's HTTP surfaces, plus a
worker that handles the generic step kinds. In a real deployment the worker
pool is typically owned by someone else entirely, so testing *our*
implementation of that contract proves nothing about theirs. What this repo
owes the boundary is a written contract, which lives in
`../../specs/workflow-engine/spec.md` (the worker's database seam),
`../../specs/agentic/brief.md` (the chat surface) and
`../../specs/world-model-ingestion/brief.md` §3.5 (the Content Server).

The database halves of those contracts *are* covered, both here and by
`../../surface.sql` — which is the right split: we guarantee the functions a
service calls, and the service guarantees its own routes.

## Relationship to `surface.sql`

Complementary, and neither replaces the other:

| | Asks |
|---|---|
| `../../surface.sql` | Does every capability the specs promise **exist**? |
| `run.sh` | Does it still **behave** the way the spec promised? |

Both exit nonzero, so both work as CI gates. Run `surface.sql` first: a missing
function makes a behavioural test fail for an uninteresting reason.

## Notes

Suites wrap themselves in a transaction and roll back. `rbac/01` cannot — it
uses real `BEGIN`/`COMMIT` blocks because it is simulating PostgREST's
one-transaction-per-request — so it opens with an idempotent teardown instead.
Every file here can be run twice in a row.
