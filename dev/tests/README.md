# The surfaces

```bash
./run.sh              # all of them, in order
./run.sh query        # one
DSN="postgres://…" ./run.sh
```

Three of these are not one concern among many — they are **the** concern.
Everything else in the collection is composed out of them: ingestion is
workflows over content, the graph is queries over RBAC-scoped rows, an agent is
a workflow that calls a query. A defect in one of the three does not stay in
one of the three.

`agentic/` is the fourth and it is a different kind of entry, added when that
subsystem stopped being unexercised and gained a worked binding
(`specs/agentic/reference/`). It asserts nothing the three cover; it covers the
one thing composing them introduced — a **binding**, which is a row naming a
server by name and a tool by name, with no foreign key able to hold either.

| Directory | Surface | Its characteristic failure |
|---|---|---|
| `rbac/` | `user-rbac`, and the RLS it imposes on all four other subsystems | Returning **more** rows than it should. The only surface where a bug is a breach, and the only one whose failure no happy-path assertion will ever notice. |
| `query/` | `ai-query-layer` — seven modes over three index families | A **wrong answer**, not an error. Nothing crashes; the caller simply gets something other than what the spec promised. |
| `workflow/` | `workflow-engine` — retries, sagas, compensation, cancellation, crash recovery | A **partial** failure that reports success. Every interesting workflow bug found here has left every task marked `done`. |
| `content/` | `world-model-ingestion` — channels, files, resources, chunks, and the drift check over them | A **write** nobody checked. The read path was scoped from the start, so every question anyone asked got the right answer; the first test to ask what a tenant could WRITE found it could rewrite another tenant's chunks. |
| `agentic/` | the tool binding — servers, discovered tools, and who may author an agent | A registration that **looks complete and is missing what it bound**. Every assertion here corresponds to a column or a tool list silently dropped on the way into a row that came back looking correct. |

RBAC runs first, deliberately: if row-level security is not actually switched
on, every later assertion about who-sees-what is meaningless.

`content/` and `rbac/03-auth-path.sql` are newer than the rest and were written
by asking a different question: not "is this right?" but **"has this ever
run?"**. `world-model-ingestion` was marked *Built* and had no test directory at
all; the first transaction to exercise its write path found that any logged-in
user could rewrite any other tenant's chunks with nothing but a resource uuid —
into the corpus `SEMANTIC` and `SEARCH` read. A
cross-reference of every capability `surface.sql` declares against every name
these tests mention found the whole auth path — signup, login, throttling,
API keys — declared, shipped, and never once executed. The first transaction to
call `create_user_with_password` and `login` in sequence found that the account
signup creates cannot log in, and the first to call `login` twelve times with a
wrong password found that the rate limiter and the audit log were both being
rolled back by the failure they existed to record. Neither is subtle. Both
survived because existing is not running.

`query/` is the largest of the four because the graph half of it was, until
recently, the least exercised: `04-graph-identity.sql`, `05-graph-traversal.sql`
and `06-graph-tenancy.sql` execute the eight criteria
`specs/ai-query-layer/graph-identity.md` lists under "Verification" — a section
that opens "A design is correct if all of these hold" and which nothing had ever
run. Two of the eight passed unchanged. The rest failed, or passed for the wrong
reason, and the corrections are recorded next to the criteria they belong to.

`05` and `06` read a committed fixture (`../init/04-graph-sample.sql`) rather
than building their own, because a walk is only interesting over a graph with a
cycle, a hub, a node reachable two ways and a node reachable no way. `04` builds
its own, because it tests the write path and a write path has to be exercised
with writes.

`workflow/09` is the other end of those same two registries, from the authoring
side: it asserts that a `SEARCH` query compiles to the embed task plus the
search, that the shorthand and the hand-written pair produce **byte-identical
stored specs** (the diff test `YAML.md` sets for promoting any shorthand), and
that a workflow embedding with one model while searching another space is
refused — a wrong answer with no run-time symptom, since two 768-dimension
models are the same width and only the width was ever checked. It also pins the
two places a step can hide: a marker inside a `matrix` template is expanded and,
unexpanded, refused, which the first version of both the expander and the lint
missed by checking the step kind they expected rather than where the shape can
occur. §11-§14 are the second pass over the same surface, and every one of them
was found by attacking it rather than by reading it: a registered name spliced
into a grammar that takes one token, a resolved value re-read as a template
because the interpolator re-scanned its own output, a model registered as a
call but never as a space, and a compensation whose dependency runs on every
run. Nothing in it touches the network: the failures it pins are all
authoring-time.

`07`–`09` are the other half of the same debt. `07` is the escape hatch:
`aiq.sql_passthrough` runs SQL the caller wrote, `brief.md` §3 calls the wrong
design for it "an RLS bypass and privilege escalation primitive", and nothing
had ever tried to write through it — so every assertion there is an attempt and
the pass condition is a refusal, with four of the nine shapes deliberately
written to walk past the leading-keyword check the function itself calls "a
courtesy, NOT the security boundary". `08` and `09` execute `TEXT`, `SEMANTIC`
and `SEARCH`, which had never returned a row under assertion: `surface.sql`
reported them present on the strength of two registration rows, behind which
the corpus held zero chunks and the model registry zero models. They read
`../init/05-corpus-sample.sql`, whose vectors are literals rather than model
output — a corpus needing a live embedding server to be reproducible is the
same failure as a fixture living in somebody's psql session.

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
