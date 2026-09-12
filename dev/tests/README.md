# The surfaces

```bash
./run.sh              # all of them, in order
./run.sh query        # one
DSN="postgres://…" ./run.sh
```

**`run.sh` IS NOT THE GATE. `dev/check.sh` IS.** "All of them, in order" means
all of *these five surfaces*, and that sentence has been read as "everything"
more than once. `dev/check.sh` is what CI runs and what decides whether a change
is green; on top of this file it adds the eval journeys (111 scenarios in
`evals/scenarios.yaml`), the backup round trip, the contract re-check and four
upgrade paths. Measured cost of the confusion, 2026-09-12: a session ran
`run.sh`, got five green surfaces, pushed, and CI went red on eleven eval
fixtures. Run `dev/check.sh` before a PR. Run `run.sh` while iterating on a
surface, which is what it is for.

**AND IF YOUR CHANGE TOUCHES AN OBJECT THAT ALREADY EXISTS, NEITHER OF THEM CAN
SEE THE DEFECT.** Adding a column, a column default, a seed row or a grant to
something already installed produces a divergence that lives only in an
*upgraded* database, and every check in this directory — plus `surface.sql`,
plus all ten tree gates — asks its question of **one** database, so all of them
are green either way. `dev/upgrade-converges.sh` is the only thing in the
collection that compares an upgraded database against a fresh one object by
object:

```bash
CONTAINER=p8-mine DB=p8mine dev/upgrade-converges.sh
```

Measured, same day: REM-109 changed `workflow.queue_config`'s `stale_timeout`
default from a literal to `workflow.stale_timeout_default()`. `create table if
not exists` is a no-op on a database that already has the table, so the new
default reached fresh installs only and every upgraded deployment kept
`'00:02:00'::interval` — a fifth copy of the number, created by the commit that
deleted the other four. Ten tree gates, all 19 workflow files and `surface.sql`
were green with that live. `upgrade-converges.sh` reported it as one line.

The remedy for that shape is an explicit `alter table … alter column … set
default` after the create, which `rbac.users` has carried since user-rbac §1 and
which REM-68 is the open ticket for. **`dev/check.sh` runs this gate, so a PR is
covered; what is not covered is believing a local `--tree` run.**

Three of these are not one concern among many — they are **the** concern.
Everything else in the collection is composed out of them: ingestion is
workflows over content, the graph is queries over RBAC-scoped rows, an agent is
a workflow that calls a query. A defect in one of the three does not stay in
one of the three.

`content/` and `agentic/` are the fourth and fifth, and both are a different
kind of entry. `agentic/` was added when that subsystem stopped being
unexercised and gained a worked binding
(`specs/agentic/reference/`). It asserts nothing the three cover; it covers the
one thing composing them introduced — a **binding**, which is a row naming a
server by name and a tool by name, with no foreign key able to hold either.

| Directory | Surface | Its characteristic failure |
|---|---|---|
| `rbac/` | `user-rbac`, and the RLS it imposes on all four other subsystems | Returning **more** rows than it should. The only surface where a bug is a breach, and the only one whose failure no happy-path assertion will ever notice. |
| `query/` | `ai-query-layer` — nine modes over three index families | A **wrong answer**, not an error. Nothing crashes; the caller simply gets something other than what the spec promised. |
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

`workflow/` is the largest of the five, at 13 files; `query/` is next, at 12,
and grew there because the graph half of it was, until recently, the least
exercised: `04-graph-identity.sql`, `05-graph-traversal.sql`
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

`10-graph-index.sql` is the newest and is the same argument one layer up: it
tests the write path a *machine* takes into that graph
(`specs/world-model-ingestion/graph-index.md`), where the characteristic
failure is not an error but a graph that landed and is wrong in a way nothing
raises — an edge wired to the wrong endpoint because an ordinal moved, a
machine-invented row in a human's table, a promotion that deleted the edges it
existed to preserve. It builds its own fixture for the same reason `04` does.
Five of its assertions exist because the first implementation failed them, and
one of those was found by `06` rather than by itself: `06`'s rule that no
`aiq` SECURITY DEFINER function may be user-reachable caught a missing
`revoke ... from public`, and underneath it a resolver that was not
tenant-scoped. That is the argument for a suite over a per-feature test file —
the assertion that catches you is rarely the one you wrote.

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

**And prefer a test that walks the catalogue to one that walks a list.** The
difference is not tidiness, it is whether the test still holds next month.
`rbac/02` §3 asserts RLS is enabled on every table that *has a policy* — a
correct assertion with a hole exactly the shape of the thing it guards, because
a table with no policy never enters the loop. Two tables carrying extracted
entity names were readable across tenants for precisely that reason, and
`rbac/05` found them by enumerating every readable table instead and naming the
shared-config exceptions with the tier each belongs to. Same shape in `rbac/04`:
an earlier pass fixed eleven functions reachable by the wrong role by listing
them once, by hand, and the list is what let the twelfth through.

So when writing one of these, ask what the `where` clause excludes and whether
the excluded set is the failure. A named exception list *inside* the test is
fine and is often the point — it turns "nobody thought about this" into
"somebody decided this", and the next person adding a table has to join that
decision.

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

`../examples/` is beside it and is neither. It is ten worked scenarios over one
fixture, executed against a live database, and it is the source of the output
quoted on the `Ten things, worked through` page in `get-percolate/docs/`. It is
not a test suite and must not become one: by the rule above, a test earns its
place by failing when a guarantee is quietly removed, and every one of those
ten exercises a path that already works. What it is for is that a cookbook has
to *state* what a function does, and stating it is what found two of the three
defects recorded in `world-model-ingestion/ingestion.md` §7 and the one in
`workflow-engine/YAML.md` — a `p8ql:` step of plain SQL that completes without
executing, and an upload retried without an `external_id` that ingests twice.
Writing the examples asked a fourth question the other three do not: not "is
this right?", not "has this ever run?", but **"is this what a reader would be
told it does?"**

## What each surface's newer files guard

The five directories are organised by subsystem; within them a few files are
organised by *failure class* instead, because the class outlived the subsystem
that produced it:

| file | the class |
|---|---|
| `rbac/04-definer-surface.sql` | Every SECURITY DEFINER function, enumerated: none may carry Postgres's PUBLIC default, none may be reachable by `web_anon` outside the five that *are* anonymous authentication. Written because a schema-wide `revoke ... from public` binds only what exists when it runs, and six functions were created after it. |
| `rbac/05-read-surface.sql` | Every readable table has a policy or is named shared config; every view is granted to a caller or named operator-only. Then the two reference tables are asserted by *reading them as a tenant*, because a policy that is present and wrong is invisible to a catalogue check. |
| `rbac/09-token-rotation.sql` | One credential, presented twice. The refresh-token chain end to end — rotation, the link `replaced_by` records, and what is true about the database after a rotated-away token comes back. Written because the theft-detection branch had never executed: it failed on an ambiguous column name and, had it not, its own `raise` would have rolled back the revocation it announced. |
| `rbac/10-permission-vocabulary.sql` | `permission_kinds` walked in both directions — every pair a live policy or function asks for by name is declared, and every declaration that names a policy names one that exists. Then the administrator: `bootstrap_admin` grants "everything" with a SELECT that runs once, so a pair declared afterwards was one nobody held. |
| `rbac/11-scope-two-homes.sql` | The scope rule is written twice on purpose — generated into every policy, and as `may_read`/`may_write` for the SECURITY DEFINER callers that bypass RLS — and nothing compared them. Same identity, same rows, two doors, as sets rather than spot checks. |
| `query/12-usage-examples.sql` | `USAGE.md`'s own surface, in the forms that document shows. Not a doc-sync mechanism — nothing here can read a Markdown file — but the coupling stated: change a signature and a test with that document's name on it breaks before a reader does. |
| `agentic/05-agent-document.sql` | One agent, two documented spellings, and the layer that decides which columns they become. Written because three loaders each carried their own copy of that mapping and each knew one dialect, so the same extractor installed differently depending on which tool applied it — and `upsert_agent` dropped the keys it did not read, which is what made it silent. Half the file is the translation; the rest is that a key nobody reads is now *refused*, because that is what stops the fourth loader (REM-70). |

## The one test that is not SQL

`content/e2e-ingest.py` uploads five real formats — markdown, PDF, DOCX, WAV
and CSV — through a running Content Server and asserts what came out the other
end: chunks with spans, a vector per chunk (in ONE batched request, not one
each), nodes and edges extracted from the same parse and attributed to the
window that named them, a Parquet dataset DuckDB reads from object storage, and
four questions answered from four different formats.
`run.sh` does not run it (it globs `*.sql`), because it needs a stack, an
object store and a real embedding key:

    cd dev && docker compose up -d db minio
    LLM_API_KEY=sk-… python3 tests/content/e2e-ingest.py

It exists because the thing it tests cannot be faked. `dev/init/05-corpus-sample.sql`
proves retrieval works over vectors that are literals in a fixture, and says so
in capitals; nothing anywhere had ever turned a PDF into a chunk or written a
vector into a space. Every fixture is *generated* (`content/fixtures.py`) rather
than committed, for the same reason those vectors are literals: a fixture you
cannot regenerate is a fixture nobody can check, and a PDF in git is 40KB of
bytes a reviewer has to take on trust.

The defects that came out of running it are recorded in
`../../specs/world-model-ingestion/ingestion.md` §7 — including a `rate_key`
that names a bucket with no row, which parks the task forever while the worker
beside it reports an empty queue.

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

## The fifth directory, which asks a different question

`evals/` is not a sixth surface. The five above test a **mechanism** against its
spec; `evals/` tests a **journey** — 111 of them, in `scenarios.yaml`, each
citing which of 28 named failure modes it would notice, run by `./evals/run.py`
against one committed fixture.

```bash
cd evals && ./run.py --fixture
```

**IT IS ONE OF THE GATES.** `dev/check.sh` runs it, under the question *a
journey somebody could complete last month still completes*, straight after the
mechanism suite and before the contract re-check. A non-zero exit is red
locally and red in Actions, which runs this same script and keeps no second
list.

Nothing here said that until 2026-09-12, and the silence was not a
documentation gap — it was the reason the suite could stop working in four
separate ways, over weeks, with nothing going red anywhere: its defaults named
a container that no longer existed on any machine, its fixture would not load,
two whole categories were refused by a permission model it predated, and
sixteen assertions described a schema that had moved (REM-75). A suite nothing
runs is not a weak suite, it is prose. `dev/check.sh` is now what decides
whether a scenario added here was worth adding.

The gate reloads the fixture on every run (`--fixture`), which makes the
fixture's idempotence a thing the gate proves rather than a thing somebody
remembers: every scope column added to `content.*`, `aiq.*` or a fixture table
since it was written has broken a second load at least once.

The distinction is not coverage, and it earns its own directory because it finds
a different class. A mechanism can be correct at every step of a journey that
cannot be completed. `signal:` parks a run, refuses a stranger, cancels cleanly
and stamps `completed_at`; every one of those is asserted somewhere above. What
nothing had ever done was **read what the person said from the step that acts on
it**, which is one function call past the end of all of them and on the other
side of a wall: `signal_task` never merges its output into `runs.context`, so
`{{steps.<signal>.result}}` resolves to nothing and the second half of every
human-in-the-loop workflow is unreachable from the document.

Three of the six findings open in that file were found the same way, by walking
a journey rather than testing its parts — including a `timer: 3600` that waits
zero seconds when it is the first step, and a published example that records no
spans because it spells the key the writer does not read.

A scenario there carries `status: pass` or an open verdict, and the runner
reports loudly when a declared-open finding starts passing — a fix nobody
recorded and a check that stopped checking look identical otherwise.
`meta/skills/dogfooding` is the method that generates them; `../../scenarios/`
is where the prose verdicts live.

## `journeys/`, which is a fixture and not a suite

`journeys/` holds no tests. It is the material half of
`../../scenarios/evals/` — file bodies, chunks with literal vectors, graph
payloads and unparsed workflow YAML — for journeys an agent performs **as the
user**, by hand, against a database of its own. `run.sh` never sees it: the
surface list above is explicit, so nothing there is globbed.

It is separate from `evals/` next door for one reason, and it is the reason that
directory earns its own place. `evals/run.py` rolls every scenario back, which
is right for every one of them and structurally cannot find anything that only goes
wrong on the *fourth* thing a user does — the class two of the five postmortems
are about and `../../meta/postmortems/README.md` still lists as the largest open
shape. A journey does not roll back. Re-running one means rebuilding the
database, which is why there is no teardown script in there.

## Relationship to `surface.sql`

Complementary, and neither replaces the other:

| | Asks |
|---|---|
| `../../surface.sql` | Does every capability the specs promise **exist**? |
| `run.sh` | Does it still **behave** the way the spec promised? |
| `../currency.sh` | Is the database running **what the specs say**? |
| `evals/run.py` | Can somebody who was not in the room **get the job done**? |

Both exit nonzero, so both work as CI gates. Run `surface.sql` first: a missing
function makes a behavioural test fail for an uninteresting reason.

## If you add a gate: it reports everything red, not the first thing

**A gate that runs several internal checks reports all of them.** Not the first
one to fail — all of them, in one run, and then exits non-zero once.

This is a property of how a gate is *written*, and it cannot be given to one
from outside. `dev/check.sh` already runs every gate regardless of which ones
failed (`set -uo pipefail`, no `-e`; `run_gate` handles a failure as an `else`
branch), and a bash runner cannot see inside a `psql` script or a Python one
anyway. So each gate carries the rule or does not have it.

`run.sh` carries it — it collects `failed` and exits at the end, and its header
explains why: *one broken guarantee usually breaks several*. `surface.sql` did
not, for a long time, and the cost is measured. `ff36b70` landed four defects;
they were found over three fix-and-re-run cycles, each invisible until the one
before it was fixed, because the first aborted the install and the script
stopped there. Two sessions were sent on that chase four hours apart, and
stopping after the first fix would have shipped three of the four.

The shape, if you are writing one:

```sql
create temporary table <gate>_failures (seq serial, check_name text, detail text);
-- every check INSERTs instead of raising
-- one block at the end: RAISE WARNING per row, then RAISE EXCEPTION once
```

The thing to get right is the ending. A gate that reports beautifully and exits
0 is not a gate — `run_gate` reads the exit code, so the final block must still
raise.

## Notes

Suites wrap themselves in a transaction and roll back. `rbac/01` cannot — it
uses real `BEGIN`/`COMMIT` blocks because it is simulating PostgREST's
one-transaction-per-request — so it opens with an idempotent teardown instead.
Every file here can be run twice in a row.
