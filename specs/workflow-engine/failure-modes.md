# Failure modes — what goes wrong in a workflow engine

Every entry below was **produced**, not imagined: by running real pipelines
against live public APIs, or reported by someone building one. They are grouped
by the shape of the failure rather than by component, because the shape is what
transfers — the specific bug is fixed, and the class will come back somewhere
else.

The reason to keep this is that a workflow engine's characteristic failure is
not a crash. It is a run that reports success while being wrong, or a feature
that reads as configured and does nothing. Both are invisible to a test that
only asks "did it error".

Each entry: what it looks like, why it happens, and what closes it.
`spec.md` §15–16 has the narrative; `schema.sql` §20–23 has the code;
`dev/tests/workflow/04-matrix.sql`, `05-faults.sql` and `06-recovery.sql`
assert them.

**This document is the hardening surface.** It is not a post-mortem archive: an
entry earns its place by being a class somebody will meet again, and the test
that closes it is named so the class cannot quietly reopen. When a new failure
does not fit an existing shape, that is the signal to add a shape rather than
to file it under the nearest one.

---

## 1. Failures that report success

The worst class, and the one this collection is organised around.

**A silent template.** A `{{...}}` reference that resolves to nothing, in a
namespace the resolver does not know, or with a prefix its regex does not
admit. The step runs, the value is missing or literal, and the run completes.
*Seen:* `{{item.cik}}` sent unresolved to a worker that knew three namespaces;
`{{run.$session}}` threaded to an agent as the literal string, so two steps
"shared" a conversation named by an unresolved template.
*Closes it:* the engine binds any namespace the worker cannot know **before
dispatch**, and a template that resolves to nothing raises rather than
substituting empty.

**A clock the code assumes is a function of another clock.** A cron expression
describes a local wall clock, and two mornings a year local time is not a
function of the UTC minute — so a scheduler that matches on the UTC minute is
wrong twice, in opposite directions, and reports nothing either time.
*Seen:* asked of a live database. `30 1 * * *` in `America/New_York` matched at
both 05:30Z and 06:30Z on 2026-11-01 — both are 01:30 local — and started two
runs, because the fire's `external_id` carries the UTC minute and the engine's
own idempotency therefore did not collapse them. `30 2 * * *` matched nothing
at all on 2026-03-08, because 01:59 local is followed by 03:00 local. A nightly
job that runs twice a year twice, and a nightly job that skips a year's one
day, with no error, no `last_error`, and no test.
*Closes it:* Vixie cron's own distinction, as `workflow.cron_is_wall_clock()` —
a poll (`*` in the hour field) rides the transition, an appointment fires once
per local wall-clock minute and catches up a minute the clock jumped over.
Driven a minute at a time across both transitions in
`dev/tests/workflow/02-schedules.sql` §7b.
*The shape that transfers:* a derived clock is a second copy of a fact (one fact
held in two places), and the copies agree on 363 days. Test the two days.

**Row data reaching the SQL parser as syntax.** A `matrix:` template's
`{{item.*}}` was substituted as TEXT at expansion, so a row whose column held
`x' || current_user || '` expanded into a statement that RAN and returned the
current user. Arbitrary SQL out of ordinary tenant data, executing as the engine
owner.
*Seen:* once, running an evaluation journey over forty-two planning applications.
One row in forty-two carried an apostrophe (`o'brien-yard`) and failed with
`syntax error at or near "-"`, which reads like a data problem; the executable
payload was the same defect with the concatenation completed.
*Why it survived:* the guarantee held on the path somebody tested.
`{{run.*}}` in a top-level statement was quoted and asserted; `{{item.*}}` in a
matrix child was neither, and no test asked the second question.
*Closes it:* values are BOUND rather than quoted --
`workflow.resolve_statement_params` rewrites each reference to `$1->>'<ref>'`
and `run_sql` binds the values with `EXECUTE ... USING`, so the value never
becomes syntax rather than being escaped correctly. Asserted in
`dev/tests/workflow/13-open-sql.sql` §4b, which checks the payload returns as
data, an apostrophe is not a syntax error, AND the stored statement is still a
template -- the third being the one that fails first if interpolation returns.
*The shape that transfers:* a system that templates SQL is safe only under a
trust model where the template author is trusted. The moment a value comes from
a row rather than from the author, that model is gone and escaping is the wrong
tool -- which is why every driver binds values and refuses to bind identifiers.

**A step that succeeds and answers nothing.** `p8ql: "select ..."` compiled,
ran, and marked its task `done` — with a result that was a *note*:
`execute via the SECURITY INVOKER read-only passthrough, not here`.
`aiq.query()` deliberately does not execute SQL mode, so that its own security
mode stays irrelevant to caller-supplied SQL, and nothing downstream honoured
the instruction it returned instead.
*Seen:* twice. Once writing `dev/examples/06-no-worker.sql`, whose first draft
was two `p8ql:` steps of ordinary SQL and whose run completed green with both
outputs the note. Once as the "ask the data" step of a real SEC pipeline, which
reported success and returned no rows for as long as it took to read the output
rather than the status.
*Closes it:* `workflow.p8ql` honours the note rather than returning it — the
statement goes through `aiq.sql_passthrough`, which is SECURITY INVOKER and
read-only-enforced — and `sql:` takes a statement directly, so the spelling that
looked like it should work now does. Asserted in `dev/tests/workflow/13-open-sql.sql` §6.
*The shape that transfers:* a function that returns INSTRUCTIONS to its caller
has invented a protocol, and a protocol nobody implements is indistinguishable
from a result. Return the answer or raise; never return a note about who should
have done the work.

**A template that is never looked at, which is why the line above did not close
this class.** The clause above covers a reference that *resolves* to nothing.
The in-database resolver substituted whole-string arguments only, so a
reference embedded in a longer string was never a reference at all — it was
literal text, passed through, resolving to nothing because nothing tried.
*Seen:* the documented hybrid pipeline, in this repo, for the life of the
feature. `p8ql_vec` takes the query as its first argument and the example
passed `'SEARCH "{{run.question}}" FROM chunks LIMIT 3'`. `SEARCH` feeds that
text to the lexical half, so full-text search ran for the literal string
`{{run.question}}`, matched nothing, returned every `lexical_rank` as null, and
the fusion degraded to semantic-only — on a query written *because* both halves
were wanted. It returned rows. Nothing anywhere was null. The run completed.
*Closes it:* whole-string references keep their native type and embedded ones
interpolate as text, which is the rule the worker and `{{item.*}}` already
used; the database half was the exception, silently.
*Generalises to:* a rule stated as "X raises rather than being silent" is only
as good as the set of things that reach the check. Ask what the check never
sees before trusting what it refuses.

**And then the fix for it re-read its own output.** Interpolation was
implemented as one `replace()` per reference, which re-scans the whole string —
so a resolved **value** containing `{{...}}` was substituted on a later pass.
*Seen:* run input `{"a": "{{run.b}}", "b": "SECRET"}` and the argument
`'{{run.a}} then {{run.b}}'` resolving to `SECRET then SECRET`. Run input is
caller-supplied, so this is caller data being re-read as an instruction — the
oldest injection shape there is, arriving through a template resolver written
to close a different silence.
*Closes it:* one pass over the original string, appending resolved values to an
output buffer that is never re-scanned. Values are data.

**A name spliced into a grammar.** A registered identifier is free text; the
place it gets written into is not.
*Seen:* pinning the model into the query wrote `USING weird model` for a model
row named `weird model`, so the author's own correct query stopped parsing and
the lint reported `unexpected token 'model'` — an error describing the wrong
problem, about a step whose text the author had not written.
*Closes it:* quote where the grammar needs it (the tokenizer treats a quoted
run as one token), only where it is needed, so the ordinary case still emits
what the hand-written form would have.

**A message that formats itself wrong.** `RAISE` in plpgsql knows exactly one
placeholder, `%`, and prints anything after it literally — so `%L`, borrowed
from `format()` out of habit, emits the value and then the letter L.
*Seen:* `Create it with aiq.register_embedding_space(no-space4L).`, in a
message written to make a missing registration clear. Twice in one session, by
the same author, which is the argument for not relying on remembering it. A
sweep of every `RAISE` in every schema found no others, and two stray `%s` in
test failure paths nobody had ever triggered.
*Closes it:* `extension/percolate/build-sql.py` refuses to build a spec file
whose `RAISE` uses a `format()`-only specifier, next to the check that refuses
a function defined twice — same file, same reason.

**A contract between two steps that neither step can state.** Two steps agree
about something the engine has no field for, so nothing compares them, and the
disagreement is not an error at any layer — just an answer that is wrong.
*Seen:* a `rest:` step embedding with one model and a `p8ql_vec` step searching
the space of another. `aiq.semantic_in` checks the vector's *width*, and two
768-dimension models are the same width, so cosine distance between two
unrelated spaces is computed, ranked and returned. `schema.sql` §10 calls this
"meaningless, not merely imprecise" and the workflow author was left holding
both ends of it by hand.
*Closes it:* resolve the shared fact ONCE, at definition time, and write it
into both halves — the model is pinned into the query as `USING <model>` and
refused when it disagrees. A contract two documents must keep is a contract one
of them should own.

**A defence undone by the thing it defends against.** The write that records
or throttles a failure happens in the transaction the failure then aborts, so
the protection exists in the source, is exercised on every attempt, and
persists nothing.
*Seen:* `rbac.attempt_login()` seeded a rate-limit bucket, consumed a token and
wrote an `auth_events` row, then raised `invalid credentials` — and PostgREST
gives each RPC its own transaction, so all three writes were rolled back by the
failure that caused them. Measured: **twelve wrong passwords produced no
throttle, zero `login_failed` rows, and no bucket row at all**. The token
bucket only ever decremented on SUCCESS. The audit table had an event type it
could never hold. Both were written, wired, commented — and inert, in the one
subsystem where a defect is a breach.
*Closes it:* a failed login is a **result**, not an error — `login()` returns
no row, so nothing aborts and both writes commit. Throttling still raises,
because by then the bucket is empty and already committed and a caller needs to
tell 429 from 401.
*Generalises to:* anything you write on the failure path — an audit row, a
counter, a lockout, a strike — dies with the transaction if that path also
raises. Postgres has no autonomous transaction, so on the failure path you get
to keep the write **or** the exception, not both. Decide which, deliberately.

**An assertion that cannot fail.** A test compares a scalar subquery to an
expected value with `<>`. When the row does not exist the comparison is NULL,
`if NULL` is false, and the assertion passes — for exactly the case it was
written to catch, the thing under test never happening.
*Seen:* found while writing a new assertion that passed against a defect that
was definitely present. A sweep of the suite turned up 56 comparisons written
that way; converting them all to `is distinct from` broke none, so none was
hiding a live bug — but every one of them was a check that could only fail
half the time.
*Closes it:* `is distinct from` for the positive form and `is not distinct
from` for the negative, so a missing row is a failing test rather than a
passing one.

**An unenforced output contract.** A producer returns a shape nothing checks —
a JSON document serialised into a string, say — and every downstream template
against it silently resolves to nothing.
*Seen:* a completed run returning `{"latest": [], "restatements": []}` with
`series: 6`. Six fetches, no answer, status `completed`.
*Closes it:* normalise at the boundary **and record the repair**, so the
violation is a number someone can watch rather than a rumour.

**A configured feature that does nothing.** Schema, compiler support and
storage all present; consumption absent.
*Seen:* `rate_key` compiled, stored on 30 tasks, consumed by nobody — measured
12.9 req/s against a published 10/s ceiling.
*Closes it:* enforce where the property lives (the queue, not the client), and
assert the *effect* in a test, never the presence of the config.

**A capability document describing the wrong layer.** Derived from the catalog,
therefore drift-proof, therefore trusted — and answering a different question
than the reader's.
*Seen:* `SCHEMA "workflow"` reporting all eight engine step kinds as legal while
the compiler accepted five.
*Closes it:* derive from the layer the reader will **act through**, and report
the difference explicitly.

**A capability that has never been executed.** The strongest form of this
class, because every instrument says it is fine. The function exists, the spec
describes it in the present tense, the surface audit reports it present, and —
in the worst case — a `pg_cron` job has been calling it every minute for hours.
None of that is evidence it works, and a reader has no way to tell it apart
from a capability that does.
*Seen:* a coverage pass with `track_functions='all'` over a clean install plus
the whole suite found **15 of 62 engine functions had never been invoked by
anything**. Three of them were `reap_stale_tasks`, `heartbeat_task` and
`complete_decision_task` — between them the entire crash-recovery and replay
story. Executing them for the first time found two defects immediately and a
third by inspection.
*Closes it:* measure invocation, not coverage — `track_functions='all'`,
`pg_stat_reset()`, run everything, list what has zero calls. Then treat the
list as a defect queue rather than a to-do list. **The measured base rate is
the argument:** of the never-executed capabilities run for the first time in
this collection, nearly all were broken. A capability that has never been
executed should be assumed broken.

**A health signal the failure itself resets.** A view exists precisely to
notice a condition, and the condition's own mechanics keep it out of the view.
Worse than having no view, because someone is watching it.
*Seen:* a task whose worker dies every time was reaped and re-claimed without
limit — and every claim refreshes `heartbeat_at`, so `v_stuck_tasks`, whose
entire job is to notice stuck tasks, never showed it. A task consuming a worker
slot forever while the dashboard reads green.
*Closes it:* ask what resets the signal, and check the invariant that does not
move instead — here, the attempt count against its budget. A staleness view
should be paired with a *progress* view: "not moving" and "moving and getting
nowhere" are different failures and one column makes them identical.

**An aggregate over a partial set.** A gate checked after release rather than
before, or a threshold measured on the wrong thing.
*Seen:* a `sql` successor auto-runs inside the statement that marks it ready, so
releasing-then-cancelling produces output from a task that was cancelled.
*Closes it:* evaluate the gate before the release, and give the aggregate the
per-child status so it can report what is missing.

---

## 2. Ordinary reality, treated as an outage

A pipeline over real sources meets these on essentially every run. Designing as
if they are exceptional is the mistake.

**The record that does not exist.** Amazon does not tag `us-gaap:Revenues`. A
404 from a registry is not a failure of the pipeline; it is what registries look
like. Under pure AND-join it cancelled the aggregate — on the *first* six-wide
run, twice.
*Closes it:* `continue_on: failed` with a declared `min_success` floor.

**A success carrying nothing.** HTTP 200 with an empty body. `min_success` is a
**transport** floor and counts it; the content question belongs to the
aggregate.

**A response larger than the payload cap.** An ordinary single-company XBRL
concept came back at 69,248 bytes against 65,536. Retrying it is pure waste —
it is byte-identical every time — and the worker cannot classify it, because
the HTTP call succeeded.
*Closes it:* the engine classifies it terminal and names the remedy.

**A published rate ceiling.** Every real source has one, and exceeding it gets
you blocked rather than throttled.

**An account with no credit, answered as a rate limit.** OpenAI-shaped APIs
send an exhausted account's refusal as HTTP 429, the status a rate limit uses,
and only the body's `error.code` (`insufficient_quota`) tells them apart.
Waiting fixes a rate limit and does nothing for an empty account.
*Seen:* a backfill whose extraction tasks each queued five attempts against an
account that could not succeed. The http_call handler was
taught the difference; embedding, transcription and API ingestion each decided
for themselves and were not, and transcription also retried a revoked key.
*Closes it:* one classifier, percolate-core `core/provider_errors.py`, that
every call to a provider raises through. 401/403, 402 and a no-credit 429 are
terminal after one attempt; 408, any other 429 and 5xx are retried (REM-53).

**A worker that is slow, not dead.** From the database's side these are the
same observation: heartbeats stopped. The difference only appears afterwards,
when the "dead" worker comes back holding a result and an opinion about a task
somebody else now owns. Any recovery mechanism that reclaims work has to assume
the original holder is still alive and about to report.
*Closes it:* §5's lease fence. Recovery is not complete when the task is
reassigned; it is complete when the previous holder can no longer act on it.

**Two independent time limits nobody reconciles.** The engine has a
`stale_timeout` for declaring a worker dead. The worker has an HTTP client
timeout for declaring an upstream dead. Nothing relates them, and a step whose
upstream is slower than the client timeout can never succeed — it burns its
whole attempt budget discovering that, once per attempt.
*Seen:* a `/slow/45000` step against a worker whose client gave up first,
reported as `retryable: connection failed` — which names neither the timeout
nor which side hit it.
*Closes it:* nothing yet, and it is listed because it is currently a real trap.
The minimum is that a client-side timeout says so, rather than describing
itself as a connection failure.

**Heterogeneous shapes from one endpoint.** The same API returns an array for
nineteen callers and an object for the twentieth. An aggregate that assumes
homogeneity crashes on the twentieth or, worse, quietly skips it.

---

## 3. Analysis that is confidently wrong

The engine can be perfect and the answer still nonsense. Worth stating because a
green run invites trust.

**The wrong grouping key.** A 10-K carries the annual figure *and* the
fourth-quarter figure, sharing a year-end date. Keying a restatement check on
`end` alone reported every Q4 as a revision of its own year: **54 findings, of
which 11 were real.** The run was green both times.
*Closes it:* nothing in the engine. Only looking at the data.

**The rule:** a completed run is evidence the machinery worked, and no evidence
at all that the answer is right. Check a result you can verify independently
before trusting the ones you cannot.

---

## 4. Authority and provenance

**The engine acting on its own behalf.** A `SECURITY DEFINER` function called by
the engine has no user identity, so an ownership check written for a human
refuses the engine.
*Seen three times in one session:* a fan-in reading its own run's results, a
scheduled run that could never be signalled, a step function reading sibling
tasks.
*Closes it:* authority follows **provenance** — a scheduled run belongs to
whoever created the schedule; a step may read the fan-out of the run it is
executing — rather than being granted around the check.

**A guard that only fails for the population it protects.** The happy path
short-circuits before reaching the check, so every test written by someone
with access passes, and the failure is reserved for exactly the callers the
guard exists to constrain.
*Seen:* `rbac.has_permission` reads `user_roles`, and `user_roles`' own RLS
policy calls `has_permission` — a cycle Postgres cannot detect, because its
"infinite recursion detected in policy" check only catches a policy naming its
own table directly and here the self-reference is laundered through a function.
The backend blows its stack instead, from inside the function, with nothing in
the error naming RLS. It needs a caller who neither owns the row being scanned
nor holds the permission; anyone reading their own rows satisfies the first
disjunct and never evaluates the second.
*Closes it:* the function every policy calls must not itself be subject to
those policies — `SECURITY DEFINER` with a pinned `search_path`, owned by the
table owner. And the test has to be written from the *constrained* caller's
seat, never the owner's.

**An unowned resource is not everyone's.** Treating `owner_id is null` as
public is a leak; treating it as nobody's without a path in is a weld. Both are
wrong; the fix is to give it a provenance.

**A privilege checked against the wrong role.** `to_regprocedure` resolves with
the *caller's* privileges, while the function will run as the *definer's*.
Registering as a superuser therefore always succeeded and told you nothing.
*Closes it:* check the role that will actually execute, and say what to grant.

**A step naming another tenant's data.** Any step function taking an id from a
spec is an exfiltration path with a YAML front end.
*Closes it:* scope it to the executing run, published transaction-locally.

---

## 5. State machine hazards

**Double-decrement.** `pending_deps` is decremented on the transition *into* a
terminal state and never re-incremented, so any second decrement releases a
dependent early. Reachable by re-completing a task.

**A cached count that disagrees with the rows it counts.** The other end of the
same column. `pending_deps` is the number of this task's rows in
`workflow.task_dependencies`, and it was *counted from the caller's list* by
three functions while the rows themselves went in with `on conflict do
nothing`. Those two operations differ the moment a caller names the same
dependency twice — one row, a count of two — so the cascade decrements once,
the count stops at 1, and the step waits in `pending` for ever under a run that
stays `running` for ever.
*Seen:* `needs: [a, a]` in YAML through `start_workflow`, and `array[t, t]`
through `add_task`; `complete_decision_task` carried the third copy. All three
found by executing them. Nothing raised, nothing failed, and the reaper has no
opinion — it collects expired leases on `running` tasks, and a task that never
became ready never ran. The only symptom is a run that does not end.
*Closes it:* one function decides the count, from `distinct` ids, holding the
same `for update` locks the three copies each took —
`workflow.outstanding_deps()`. Asserted through both writers in
`dev/tests/workflow/01-quiet-failures.sql` §8.
*The shape that transfers:* wherever a counter caches the cardinality of a set,
the write that maintains the counter and the write that maintains the set must
be derived from **one** expression. `ON CONFLICT DO NOTHING` beside a
hand-incremented counter is that pair, spelled so it looks like bookkeeping.

**Idempotency over a dead run.** Matching on an external key alone returns a
cancelled run as "already started" — the caller records a fire for work that
never happened.
*Closes it:* match only states that mean the work happened.

**Work landing under a cancelled run.** A worker finishing in-flight work
resurrects a cancelled graph one step at a time, unless every completion path
checks.

**Two workers, one task.** The lease is a string in a column and nothing
compares it to the caller. A worker whose lease was reaped can still complete,
fail, or heartbeat the task — so a stale answer is published, the successor
consumes it, and the live holder's real answer then overwrites the same key
*after* the read. One template resolves to two different values over the life
of one run, both workers did the work, and nothing is logged.
*Closes it:* a fence on every path that mutates a task's outcome. Test the
*lease*, not the identity: a reaped task spends its backoff `ready` and
unclaimed, so an identity comparison passes vacuously exactly there, and
whether the zombie wins comes down to whether a replacement has claimed yet.
`attempts > 0 and status <> 'running'` means "somebody held this and nobody
holds it now", which is the actual question. Record every refusal — a
completion that vanishes silently is indistinguishable from a worker that
never ran.

**A second mechanism for a solved problem.** Two code paths that must agree
about a policy, agreeing only by coincidence. The second one is usually written
because it is *nearby*, not because the first was insufficient.
*Seen:* the reaper requeued stale tasks itself instead of calling `fail_task`,
so `max_attempts` was a budget for errors and not for crashes — a task whose
worker dies every time was reaped and re-claimed without limit, at claim speed,
with no backoff.
*Closes it:* delete the second policy rather than repair it. `fail_task`
already owned the attempt budget, the backoff, the terminal transition, run
failure and compensation; the reaper's only remaining decision is *which tasks
are dead*.

**`now()` where an ordering is meant.** `now()` is the *transaction* timestamp,
so every step completing in one transaction shares it — and LIFO ordering
degrades to arbitrary. This is the normal case for in-database steps.
*Closes it:* `clock_timestamp()`, with a stable tie-break.
**And this one came back three times after being "closed."** The fix landed in
`complete_task` and not in the three other paths that mark a task done: the
decision task kept `now()`, and the timer and signal paths stamped nothing at
all — a NULL, which sorts first under `order by completed_at desc`. The lesson
is about the shape of the fix, not the bug: when a correction applies to *a
property of a state transition*, enumerate every path that performs that
transition and assert the property across all of them. One edit at the site
that hurt is how a closed class reopens somewhere quieter.

**A trigger that fires only on the transition you did not take.** An
`ON UPDATE INTO ready` autorun never fires for a task **inserted** ready, so
matrix children and compensation tasks silently never start.

**Compensations in the forward graph.** A compensation step declared like any
other, with no dependencies, becomes a root and runs immediately — refunding
the customer during a successful booking.

---

## 6. Version skew, and the audits that miss it

A compiled extension and a SQL schema that ship independently will eventually
disagree, and the error will describe the wrong problem: a syntax complaint
about a document whose syntax is correct.

*Closes it:* probe the installed compiler with a canary per feature and report
what it *actually* accepts — and note that "it compiled" is not evidence a
feature exists, because a deserialiser silently drops keys it does not know.
The emitted output is the evidence.

**And the third case: a feature with no key to probe.** The two above are "the
kind is missing" (loud) and "the key was dropped" (silent, probe the emitted
spec). A *desugaring* is neither. A compiler that predates it accepts the
document — the document was always correct — and emits a different number of
steps.
*Seen:* `p8ql: 'SEARCH ...'` on an old build compiles to one task calling the
one-argument `p8ql`, which fails at dispatch with `SEARCH ... needs
p_embedding`. There is no key to match on and no compile error to catch.
*Closes it:* the canary **counts the emitted rows**, because that is the only
place the difference exists — and the same skew is refused on the way in by a
lint rule, so the two mechanisms cover the person reading capabilities and the
spec arriving through a door that never reads them.

**Existence is not currency, and only existence was audited.** A capability
audit asks whether a promised object is present. A stale object is present. So
a database running a function body several revisions behind its spec passes
every check, and answers — with the old answer.
*Seen:* `aiq.query()` had no route for a mode the rebuilt parser had just
learned to parse, so a legal query raised `unhandled mode SCHEMA` from the
executor while the surface audit read 112/112. Seven more function bodies on
the same stack were behind their specs, and one had silently lost
`SECURITY DEFINER` and its pinned `search_path` — a privilege change no
body-only comparison would have caught either.
*Closes it:* a third audit that asks whether the database is running *what the
specs say*. Build a pristine database from the committed script and diff
`pg_proc` — body hash, `prosecdef`, `proconfig` — so Postgres does the parsing
and nothing has to re-implement dollar-quoting. `dev/currency.sh`.

**The copy that is not the one running.** One function, defined in two files
that both load. The later definition wins, the earlier one is dead, and nothing
at the edit site says which is which — so a fix applied to the dead copy is a
no-op that reads as done.
*Seen:* `signal_task` is defined in `schema.sql` and replaced in
`integration-rbac.sql` to add an authorization check. A `completed_at` fix went
to the first, had no effect, and was caught only because `currency.sh` compared
the live body against a pristine build.
*Closes it:* the shadowing is legitimate here — `schema.sql` alone is meant to
be a complete identity-free engine — so the build **reports** cross-file
redefinitions with the winner named rather than refusing them. Within a file it
still refuses: one definition per function, at the point it is first needed.

---

## 7. Omissions that look like decisions

A missing thing and a deliberately-excluded thing are the same absence, and
without somewhere to write the reason they stay indistinguishable — so nobody
re-examines either.

**An engine capability with no way to reach it.** The schema supports it, the
executor consumes it, and the layer the author writes in never offered it — so
it reads as "not supported" and gets designed around.
*Seen:* twice. `signal`, `timer` and `sub_workflow` were legal engine kinds and
unauthorable in YAML until someone tried to write a human-in-the-loop workflow.
Then `rate_key`: `start_workflow` had always read it off a step and
`claim_task` had always consumed it, but the compiler accepted the key only
inside a `matrix:` template — so the one call in this system that is always
rate-limited, an embedding endpoint, could be throttled only if it happened to
be a fan-out child.
*Closes it:* derive the capability document from **the layer the reader acts
through** (`SCHEMA "workflow"` splits `step_kinds` from `authorable_in_yaml`
for exactly this), and probe the installed compiler per feature so the gap is
reported rather than inferred.

**A rule the collection states and does not check.** A convention written into
one subsystem's comments, obeyed there, and never applied to the next subsystem
that needed it -- because nothing enumerates the places it applies.
*Seen:* `workflow-engine/integration-rbac.sql` says it in those words: "every
SECURITY DEFINER function reachable by an end user MUST do its own
authorization check. Worker-facing functions are exempt because EXECUTE on them
is granted only to `worker`." Three of `content`'s writers are SECURITY
DEFINER, granted to `authenticated`, and checked nothing at all -- so an
ordinary logged-in user of one org, holding only another org's resource uuid
and unable to see the resource, could rewrite its chunks and plant resources in
its channel. `record_chunks` DELETEs before it inserts, so that is destruction
and content injection in one call, into the corpus `SEMANTIC` and `SEARCH`
read.
*Closes it:* the check, and the test that asks it -- but the durable version is
the enumeration: a query over `pg_proc` for SECURITY DEFINER functions granted
to a user-facing role is a check a schema can run on itself. `user-rbac` has
exactly that shape of invariant for view ownership and base-table grants
already; this class needs the same and does not have it yet.
*Generalises to:* the read path being right is not evidence about the write
path, and every question anyone had asked here was a read.

**One predicate in two places becomes two predicates.** The same rule written
twice, once as a policy and once as SQL inside a function, because one of the
tables cannot carry a policy.
*Seen:* `content.resolve_file()` carried the org check inline while the new
write check was a function, and they disagreed about a caller with no request
context: a service connection could WRITE an org's content and not READ it, so
a worker could record chunks for a document whose file it could not resolve.
*Closes it:* one boolean function, called by the policy's twin and by every
writer, and a test that asserts all three still name it.

**Two registrations that look like one.** A capability needs registering in two
places by two different people, and each half fails differently — so having one
is indistinguishable from having both until the half you are missing is the one
you use.
*Seen:* an embedding model is a row in `aiq.embedding_models` (the **call**:
endpoint, provider, credential) and a generated table from
`aiq.register_embedding_space()` (the **space**: the vectors and their index).
Registering only the space gives a corpus you can search and nothing that can
ask it a question; registering only the call gave
`relation "aiq.emb_x" does not exist` from inside a generated query, naming an
internal table for a registration nobody made.
*Closes it:* each half refused by name — the call at authoring time, the space
at query time — and `SCHEMA "workflow"` reports `callable` and `space_exists`
as two fields, because they are two facts.

**A file in neither list.** A schema is written, reviewed, tested against a
hand-loaded database, and never added to the build's file list. The result
installs for whoever loaded it by hand and does not exist for anyone else.
*Seen:* `content.connectors` — the registry a spec demonstrates registering 304
sources through, over PostgREST, "against a live stack" — was not in the
extension script. `CREATE EXTENSION percolate` contained no such table. The
demonstration was real; the thing it demonstrated was not installable.
*Closes it:* an explicit not-shipped list carrying the reason for each entry,
and a build that refuses while any spec file is in neither list. An exclusion
with a reason attached is a decision; an absence is not.

---

## 8. Testing these on purpose

Most of the above are hard to reproduce against real sources: the API is
usually fine, and making it misbehave is slow and rude. A fault server (not yet
in this repository) returns
each of them on request — 401s, 429s, flaky 5xx, oversized payloads,
double-encoded bodies, empty 200s, recoverable shape violations, and an
OpenAI-shaped agent stub.

Every route reproduces a failure listed above and says which. A route earns its
place by having cost someone a debugging session — it is a reproduction of
observed reality, not a catalogue of everything HTTP can do.

The classes a fault server cannot reach are the ones about the engine's own state,
and they have their own file. `06-recovery.sql` drives a worker's death, a
revoked lease, a crash loop against its budget, a decision replayed with
different output, and the two ways a run stalls without failing — by ageing
`heartbeat_at` rather than waiting, because a test that takes two minutes is a
test nobody runs. The wall-clock version (`docker kill` on a worker holding a
task, then the live `pg_cron` reaper) is worth running by hand once per change
to the recovery path, and is not worth automating.

**Every assertion in that file was verified to fail when its guarantee is
removed.** That is the property that makes a suite worth keeping, and it is
cheap to check: revert the fix, watch the test go red, restore it. An assertion
nobody has seen fail is documentation wearing a test's clothes.

**And the assertion that could not have failed.** §1's *"an assertion that
cannot fail"* had ten live instances in this suite, all the same shape: a
scalar subquery compared with `<>`, `=` or `>=` against a literal. A subquery
over a row that is not there returns NULL, `NULL <> 'succeeded'` is NULL, and
`if NULL then` does not fire — so the check passes whenever its subject is
*missing*, which is the one state most of them were written to catch. The
sharpest was `05-faults.sql`'s
`(select tokens from workflow.rate_limits where key = 't_f_limit') >= 2`,
guarding "the bucket was never consumed": with no bucket row at all it read
green, and "no bucket row" is exactly the state that once made `attempt_login`
refuse every user in the collection. `13-open-sql.sql` had two more on a
step_key, guarding that a data-modifying CTE cannot escape a read-only step —
green if the step ever stopped being created.
*Closes it:* `is distinct from`, or an explicit `coalesce` naming the absent
case, everywhere a scalar subquery is the left-hand side. The suite's own
convention was already this; the ten were where it had lapsed, which is the
argument for checking the convention rather than trusting it.

---

## The one-sentence version

Assume the sources will be incomplete, the halves will drift, the engine will
need to act without an identity, the worker that looks dead is about to come
back, the capability nobody has run is broken, and the run will report success
— and write the assertion that would notice.
