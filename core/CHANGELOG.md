# Changelog

**This file starts at 0.1.9.** Everything published before it shipped with no
notes, and saying so beats reconstructing nine releases from commit subjects
and presenting the guesses as a record. What *is*
known about the earlier tags is in [Released versions](#released-versions)
below, and every field there was read out of git or the GitHub API.

It exists because something depended on it and it did not:
`p8-subsystems/PACKAGING.md` made bumping the `percolate-core` pin conditional
on "the `percolate-core` release notes" — a precondition that had never been
met and could not be, so the bump happened without it. A condition nobody can
satisfy is not a safeguard; it is a sentence people learn to step over.

## 0.1.12 (unreleased)

**Not published.** `pyproject.toml` says `0.1.12` and there is no `v0.1.12`
tag. This entry describes `main` at `f2920b9`; nothing in it can be installed
yet, and the heading loses its "(unreleased)" when the tag exists.

**Pairing: extension 0.2.0, with one degraded heartbeat that extension 0.2.1
repairs.** Nothing in 0.1.12 needs an object 0.2.0 lacks. Each of these was run
on `percolate-postgres:19-0.2.0`, as the role 0.1.12 uses, and answered:

- at startup, what 0.1.9 asked: `core/identity.verify_can_open_a_session`
  writes the claims and then switches to `authenticated`, in that order, in a
  transaction it throws away, and the runtime refuses to start if the database
  says no;
- for `/internal/run`, `workflow.tasks_api` read as `authenticated`, and
  `workflow.complete_task` and `workflow.fail_task` called as `worker`, a login
  every install creates;
- for `percolate query mcp`, `aiq.query('SCHEMA "p8ql"')` as `authenticated`;
- for the startup warning about summaries, `workflow.definitions_api` and
  `agentic.agents_api` read as `authenticated` with no claims.

**The degraded part is the dispatching worker, not the runtime.** On 0.2.0
`worker` cannot call `workflow.queue_stale_timeout` (`permission denied for
function stale_timeout_default`), so a worker holding an async step heartbeats
every 40 seconds whatever its queue configures, and a queue whose
`stale_timeout` is under about 80 seconds has held tasks reaped. Extension
0.2.1 makes that function `security definer` (p8-subsystems `d888a57`); it is
not published. The live checks for #41, #46, #48, #49, #53 and #55 ran on
0.2.0. Those for #51, #52, #54, #56 and #57, and get-percolate's rehearsal of
#54, ran on 0.2.0 upgraded in place to 0.2.1, so a task completed on
`P8_WORKER_DSN` has not been run live on 0.2.0 itself.

`wait_ms` is a key in the step's input, and on 0.2.0 both `define_yaml` and a
JSON insert keep it; 0.2.0's exported `http_call` contract does not list it and
still describes `mode: async` as parking. 0.1.9 remains the minimum runtime for
a 0.2.0 database, and 0.1.11 the minimum for `percolate sample load` against
one.

Thirty-nine commits since `v0.1.11`, twenty-three of them not merges. The first
group is first because an operator has to change a deployment for it.

### The agent service serves scheduled runs and delegation

- **Give `agent serve` `P8_WORKER_DSN`, or no scheduled run can report back.**
  A scheduled run completes or fails the task that dispatched it, and
  `complete_task` and `fail_task` are granted to `worker` only. The runtime
  switched its own `authenticator` login to `worker`, and no install permits
  that (`permission denied to set role "worker"`), so a scheduled run never
  told its task and the step waited out `wait_ms`. `P8_WORKER_DSN` names the
  workers' own login, used for those two calls and nothing else. **Without it,
  `/internal/run` answers 503** before accepting the run. Unset, the runtime
  switches its own login as before, which works only where that login is a
  member of `worker`. get-percolate#40 sets it on the agent service in the
  compose file and the chart, and merges once 0.1.12 is published. (#54)
- **`agent serve` answers `POST /internal/run`.** Only `agent gateway` served
  it. A scheduled step posts to `{{env.P8_AGENT_URL}}`, every shipped
  deployment points that at `agent serve`, and the worker sends the run owner's
  token to that origin only. On get-percolate's compose file and chart every
  scheduled run was a 404. (#54)
- **The route checks a call before it answers 202**: a body naming a task and
  an agent (400), a verified caller (401), a task the caller can see through
  `workflow.tasks_api` (404), and a runtime able to complete tasks (503). On
  0.1.11 a request with no token was refused inside the background turn, which
  then failed the named task terminally. So anyone who could reach the gateway
  could fail any task whose id they knew. (#54)
- **`agent serve` answers MCP at `/mcp`.** get-percolate's agents page
  registers delegation at `http://agent:8080/mcp`, but only `agent gateway`
  served MCP, and neither the compose file nor the chart runs it, so that
  registration answered 404 and nothing could delegate. It is the gateway's
  route, stateless, as one route rather than a mount: a mount answers `/mcp`
  with a redirect that the MCP client does not follow. The delegating
  service's origin must be in `P8_TOOL_AUTH_ORIGINS` (`http://agent:8080` on
  compose), or the runtime sends no token and the call is refused with `a
  verified caller is required`. (#56)
- **So `agent gateway` is optional.** It is unchanged and still serves both
  routes, for a deployment that puts delegation on replicas of its own.

### The sample's agent can read the sample

- **`percolate query mcp` is a query tool server in the image.** Asked which
  vessels in the harbour sample have open deficiencies, `harbourmaster`
  answered that it had no access to live databases: the sample registers no
  tool server, because no install ran one. `percolate query mcp --port 8090
  --postgrest http://postgrest:3000` (or `P8_POSTGREST_URL`) serves one tool,
  `query`. It forwards the p8ql string to `aiq.query` unchanged, builds the
  tool's description from `SCHEMA "p8ql"`, and sends the MCP request's
  `Authorization` to PostgREST as it came, or none. Standard library only, so
  it needs no extra. (#52)
- **`percolate sample load` syncs the catalogue of every tool server its
  plugin registers**, through `POST /tools/{name}/sync` on the runtime (new
  `--agent-url`, default `http://localhost:8080`). A server with no catalogue
  fails the bound agent's first turn with `has no discovered tools`. If the
  runtime is not up, the load still succeeds and prints the `curl` that
  finishes the sync. (#52)
- **`percolate query mcp` runs SQL mode, and every failure is an error.**
  Asked the same question over REST, `harbourmaster` called `query` more than
  50 times and hit `request_limit`, twice in two runs. `aiq.query` does not
  execute SQL mode: it returns the statement and a note to run it through the
  passthrough, which is what the tool's description says happens. The server
  returned that note as a success, so the model asked again. It now runs the
  statement through `aiq.sql_passthrough` with the caller's `Authorization`,
  and returns the rows. An `error` field that `aiq.query` returns at HTTP 200
  (GRAPH on a key that matches no node, or several) is now `isError`, with the
  envelope's `did_you_mean` or `candidates`. A refusal from the passthrough is
  an error with the database's message. Extension 0.2.0 already grants
  `authenticated` EXECUTE on `aiq.sql_passthrough`.

### A tool call that failed reaches the model as a failure

- **A refused or failed tool call is an error to the model.** The toolset
  returned a tool result's content whatever its `is_error` said, so the model
  saw a success. A delegation the gateway refused was called 54 times in one
  turn, until `request_limit` (50) stopped it. It now raises pydantic-ai's
  `ToolFailed`: the model gets the text as a failed result, no retry budget is
  spent, and `TOOL_CALL_END` carries `is_error`. Measured on the same refusal:
  1 call, and the parent run `succeeded`. (#51)
- **`run_delegated` no longer returns a failed child's empty answer.** It
  returned the child's last assistant text without reading the child run's
  status, so a failed child reached the parent as a successful `None`; one
  workbench send made 42 failing children in a turn. It now raises, naming the
  child's status and recorded cause, and MCP returns that as `isError`. The
  same failure measured after: 1 child, `failed`, and the parent `succeeded`.
  (#51)

### A summary that cannot be dispatched no longer fails the turn

- **On a stock install, every turn in a session past
  `summarize_after_messages` was marked `failed` after it had answered.** The
  summary was dispatched inside the turn's `try`, after the answer was stored
  and streamed, and `summarize_session_window` is seeded only in
  `dev/seed.sql`: neither the extension nor get-percolate installs it, or the
  default `summarizer` agent. The dispatch raised, the run was marked `failed`,
  a `RUN_ERROR` followed the answer, and a scheduled turn failed its task. A
  failed dispatch now leaves the turn `succeeded`: it records
  `summarize_session_window not dispatched: <cause>` on the trace and logs a
  warning. Past the threshold the window still drops the oldest messages, and
  the summary slot stays empty. (#57)
- **`agent serve` warns at startup that sessions will not be summarized**,
  naming what no caller can see: the workflow definition, the agent
  `P8_DEFAULT_SUMMARIZER` names, or both. It checks both with no claims, so a
  row visible to one org counts as missing, and it warns rather than refusing
  to start. (#57)

### Who can hear a session, and what may be fetched

- **`GET /sessions/{id}/events` answers 404 to a caller who cannot see the
  session.** The route checked `session_messages(id) is None`, which never
  fires: that method returns a list, and RLS turns another user's session into
  `[]`. `relay` then LISTENed on a connection opened as the login role, where
  RLS does not apply, so any signed-in caller holding a session id heard every
  event of that session. The route now reads the session as the caller, the
  check a turn already makes before resuming one, so a session the caller owns
  with no messages in it stays observable. (#41)
- **The egress guard covers `POST /probe` and the API source puller, not only
  the worker.** Both fetched any address a caller chose, from the compose
  network beside Postgres, MinIO and PostgREST. The guard moved to
  `core/egress.py` and all three call it. An address that is private,
  loopback, link-local, a cloud metadata service, on the compose network, or
  otherwise not global is refused. The probe checks every redirect hop before
  requesting it, and a hop to another origin carries only `Accept` and
  `User-Agent`: on 0.1.11 an `auth_type: header` credential followed the
  redirect. The puller checks every page's URL. A refusal no longer quotes the
  address the name resolved to. (#42)
- **`P8_TEMPLATE_ENV` is how an operator sanctions an internal endpoint, for
  all three.** The origins of `P8_AGENT_URL`, `LLM_URL` and each variable
  `P8_TEMPLATE_ENV` names (comma-separated) are let through. **An API source on
  an internal address that 0.1.11 fetched is refused by 0.1.12** until the
  variable holding its URL is named there. Not covered: DNS rebinding (the name
  is resolved and then connected to without pinning the address), tool server
  rows, and chained-action webhooks, which a write permission gates instead.

### A scheduled run reaches the agent service, and reports back

- **`agent serve` answers `POST /internal/run`.** Only `agent gateway` served
  it. A scheduled step posts to `{{env.P8_AGENT_URL}}`, every shipped
  deployment points that at `agent serve`, and the worker sends the run owner's
  token to that origin only. On get-percolate's compose file and chart every
  scheduled run was a 404.
- **The route checks a call before it answers 202**: a verified caller (401), a
  task the caller can see through `workflow.tasks_api` (404), and a runtime
  able to complete tasks (503). On 0.1.11 a request with no token was refused
  inside the background turn, which then failed the named task terminally. So
  anyone who could reach the gateway could fail any task whose id they knew.
- **Completing and failing a task runs on `P8_WORKER_DSN`.** The runtime switched its
  `authenticator` login to `worker` to call `complete_task` and `fail_task`,
  and no install permits that (`permission denied to set role "worker"`). A
  scheduled run therefore never completed or failed its task, and the step
  waited out `wait_ms`. Give the agent runtime and the gateway the workers' own
  login in `P8_WORKER_DSN`. Unset, the runtime switches its own login as
  before, which works only where that login is a member of `worker`.

### An async `http_call` sends, then holds its task

- **On 0.1.11 an async step returned before sending**, and the worker completed
  the task with `{"dispatched": true}`. No scheduled agent run reached
  `/internal/run`, the seeded `summarize_session_window` included.
- **0.1.12 sends the request and holds the task** until the callee completes or
  fails it. The worker heartbeats while it holds, and writes nothing when the
  task is released. A new step key, **`wait_ms`**, bounds the hold; the default
  is 15 minutes. Past it the worker fails the task **terminally**, carrying its
  worker id so the lease fence refuses the write if the lease has moved; not
  retryable, because a retry would dispatch a turn that may still be running. A
  `wait_ms` that is not a positive whole number is refused before anything is
  sent. (#46)
- **The hold occupies the worker.** `percolate worker` runs one task at a time,
  so a worker holding an async step claims nothing else until the callee
  answers or `wait_ms` passes. Size the `http` queue's workers for the async
  steps you expect in flight at once.
- **Found and not fixed, on extension 0.2.0:** `worker` cannot call
  `workflow.queue_stale_timeout`, so every worker heartbeats every 40 seconds
  whatever the queue configures, and a queue whose `stale_timeout` is under
  about 80 seconds has held tasks reaped. Each completed dispatch also leaves one
  `lease_violation` row (op `heartbeat`, "task is already succeeded") in
  `v_lease_violations`: the holding worker's heartbeat after the callee
  finished, not a fault.

### A failed scheduled turn fails its task

A scheduled run completes its own triggering task. Every other ending was wrong
for the task, and with the hold above, a turn that said nothing cost the whole
`wait_ms`. (#49)

| how the turn ended | 0.1.11 | 0.1.12 |
|---|---|---|
| an exception inside the turn | task neither completed nor failed | failed, verdict by cause |
| a quota cutoff | task **completed**, so the next step ran on nothing | failed, terminal |
| a failed chained action | left for the reaper | failed, retryable |
| before the turn: no such agent, `start_run` refused, no verified caller | failed retryable whatever the cause | failed, verdict by cause |
| the background dispatch cancelled | nothing | failed, retryable; the cancellation is re-raised |

**Terminal:** the worker's permanent database errors (42501, integrity, data),
a model HTTP error `core.provider_errors.classify` calls terminal, a spent usage
limit, `TerminalError`, no agent by that name the caller can see, no verified
caller, and a quota cutoff. **Retryable:** a provider 5xx or plain 429, a
dropped connection, a failed chained action, a cancelled turn, and a `KeyError`
or `IndexError` from a bug inside the turn. Delegated runs carry no task and
are unchanged. The holding worker learns the task ended at its next heartbeat.

### Status codes from the agent runtime

- **An unknown agent, or one RLS hides, is 404** on both the streamed and the
  buffered path, with one sentence for both. It was a 500 buffered, and a 200
  carrying `RUN_ERROR` streamed.
- **A database refusal after the turn started is 403**, with the database's
  message and hint. It was a 502 blaming the thing the runtime called.
  Mid-stream it stays a `RUN_ERROR` event.
- **A quota cutoff is 429 with `error.code = insufficient_quota`.** It was a
  502. Streamed, it is `RUN_FINISHED`'s status.
- **What this does to a workflow:** the worker classifies a 404 as terminal, so
  an `agent:` step naming an agent that does not exist now fails on its first
  attempt; the 500 was retried to `max_attempts`. A 429 carrying
  `insufficient_quota` is terminal by the same rules, so an `agent:` step stops
  on the first quota cutoff. `/internal/run` is unchanged. (#47)

### U+0000 in a jsonb write

- **A NUL in any jsonb parameter bound through the runtime's pool is written as
  U+FFFD.** 0.1.10 did this at two call sites, and three more writes carried the
  byte: an `http_call` response into `complete_task`, an API source page into
  `content.commit_api_page`, and a tool server's catalogue into
  `agentic.upsert_tool_server`. On 0.1.11 a sync `http_call` whose response held
  a NUL failed its task terminally. The rule is now the jsonb encoder the pool
  installs on every connection. Outside it: the NOTIFY listener and the CLI's
  own connections, which the test names so a third fails it, and `json` (not
  `jsonb`) parameters. (#48)

### The workbench

- **A delegating turn keeps each run's text apart.** One session channel
  carries the parent and every delegated child, and the chat appended every
  token to the last bubble it opened, so a delegating turn merged two runs'
  text into one. Any run's end also set the turn's verdict, so a failed child
  marked the turn failed while the parent was still running. Text is now kept
  per run and message, only the root run ends the turn, and a child run renders
  as a closed block under the parent's steps, live and in the stored
  transcript. (#53)
- **The session panel counts runs after a turn that failed.** The re-read after
  a turn was skipped when the turn had failed, and a child's failure counted,
  so a session with 52 runs showed `RUNS 0`. A turn that wrote rows is re-read
  either way, and the rail's message and run counts update with it. (#53)
- **Three screens lead with words on a stock install.** Queues & pools, Load &
  limits, and Keys & sessions led with `42P01` tiles, spec paths and
  placeholder wording. Queues & pools reads the missing pool schema from the
  database and says worker pools are not installed; Load & limits leads with
  tasks and workflow runs by status; Keys & sessions says keys are listed and
  revoked here, not created. The SQLSTATEs, files and notes are behind an
  "Operator detail" toggle, not deleted. (#55)

### CI

- **Every test file runs, or says why not.** Eleven of thirty-nine were named in
  no CI step and never ran, including the tests two closed issues rested on.
  `dev/check-tests-run.sh` refuses a `tests/test_*.py` that no step runs and no
  `# not run here:` line declares. One is declared: `test_pool_render.py` needs
  a private repository, and no workflow in either repository runs it. (#45)
- **A markdown-only change runs CI.** `paths-ignore: ['**.md']` skipped
  `dev/check-releases.sh` on the one kind of change that can break it. (#40)

## 0.1.11

`v0.1.11` names `4d583e8`. One commit since `v0.1.10`.

**0.1.10 did not make `percolate sample load` work against extension 0.2.0,
and that is why 0.1.11 exists.** The command makes two inserts that 0.2.0's
tightened columns refuse. 0.1.10 fixed the first, the channel, and was verified
by probing that constraint with two SQL statements rather than by running the
command, so the second was still there.

- **An edge omits `org_id` instead of passing NULL.** `apply_graph` passed
  `e.get("org")` into the column, and the sample's `graph.yaml` declares no
  `org:` on any edge. On 0.2.0 the column is NOT NULL with the shared tier as
  its default, and an explicit NULL is refused rather than defaulted:
  `null value in column "org_id" of relation "edges" violates not-null
  constraint`. The column is now left out when the document leaves it out, as
  the channel branch already did. (#39)

Verified by running `ci/coldstart.sh`'s own invocation, `percolate sample load
samples/harbour --as-email … --skip-documents`, against a fresh
`percolate-postgres:19-0.2.0`, and reading the rows back through the database:
one `harbourmaster` agent, nine edges, `harbour-reports` public with no owner.

**Pairing: 0.1.11 is the minimum `percolate-core` for `percolate sample load`
against extension 0.2.0**, which is the command get-percolate's install guide
has a reader run. As a runtime it serves 0.2.0 as 0.1.9 did.

## 0.1.10

`v0.1.10` names `3612268`. Six commits since `v0.1.9`, cut the evening extension
0.2.0 published. It published as a **retry**, like 0.1.9.

**Against extension 0.2.0, `percolate sample load` still fails on this
version.** 0.1.10 fixed the channel insert and not the edge insert behind it;
0.1.11 is the fix.

- **`percolate sample load` writes a channel somebody can read.** The insert
  left owner and visibility to the column defaults, null and `private`, and
  0.2.0's `channels_readable_by_somebody` CHECK refuses that row, so step three
  of the install guide died on the constraint. The loader now asks the database
  for both, `rbac.current_user_id()` and `rbac.default_visibility()`: on the
  admin DSN that is `public` with no owner, and a signed-in installer gets
  `private` against their own id. An extension without those functions gets
  the old insert. (#38)
- **A NUL byte no longer aborts a turn's rows or a document's chunks.** Postgres
  `text` cannot hold U+0000, and both writes hand Postgres a jsonb argument read
  back as text. A live tool result took a turn that had already run to `failed`;
  one NUL in a 777-byte upload took the ingest task terminal, cancelled the
  three tasks after it and wrote no chunks. Both writes now carry U+FFFD, in
  keys as well as values, so a chunk still lines up with its `start_offset`.
  `core.text.without_nul`. (#36; every pool write in 0.1.12)
- **`X-P8-*` headers go only to an origin in `P8_TOOL_AUTH_ORIGINS`.** A tool
  server left out of that list received the caller's `X-P8-User-Id` and
  `X-P8-Session-Id` while being refused the caller's token. The context now
  goes where the token goes, and not across a redirect; `traceparent` still goes
  everywhere. **A tool server that read those headers without its origin in the
  list receives none of them.** (#37)
- **A scheduled run is authenticated as whoever scheduled it.** The worker
  minted a run-owner token only for `{{env.P8_AGENT_URL}}/v1/chat/completions`,
  so the documented `/internal/run` step went out with the shared `P8_API_KEY`
  and ran with that one identity's scope. Both runtime paths now mint. A step
  whose resolved origin is not the configured runtime raises instead of falling
  back to the shared key, and a run with no verified owner is refused. It takes
  effect with get-percolate#25, which mounts the key. (#30)
- **A failed connection reset keeps the reason the turn failed.** Terminating an
  already-released connection raised, and that exception replaced the one the
  handler was re-raising. (#35)
- **`dev/check-version.sh` refuses a percolate-core image pin that is not the
  latest tag.** The README's compose block pinned a yanked version. (#32)

## 0.1.9

`pyproject.toml` said `0.1.9` with no `v0.1.9` tag, so the release workflow ran
in **retry** mode and published the tree as it stood rather than bumping again.

**Read this first if you run the extension at 0.2.0 or later.** 0.1.8 and
earlier cannot serve such a database *at all*: they set the caller's role
before writing the claims, and 0.2.0 refuses `pg_catalog.set_config` to
`authenticated`, so no turn opens a session and every one of them fails after
the service has reported healthy. **0.1.9 is the minimum runtime for a 0.2.0
database.** The pairing is not a preference — a database is refused the upgrade
to 0.2.0 while that grant is still there, so there is no 0.2.0 database without
the revoke.

Seventy commits since `v0.1.8`, 45 of them not merges, and this list is what
changes behaviour rather than all of them. The identity group is first because
it is why the release exists.

### Identity, and who a statement runs as

- **Claims are written before the role switch.** `core/identity.as_caller` set
  `role` and then the claims; the second statement is refused on a 0.2.0
  database. The order is now claims-then-role, which is PostgREST's order and
  the only one that works — the revoke exists because while `authenticated`
  could call `set_config`, any signed-in user could write another user's `sub`
  into `request.jwt.claims` from inside `aiq.sql_passthrough` and read as them.
- **An org-scoped token is no longer widened to every org.** The agent runtime
  verified tokens with a second, hand-written HS256 path that kept only `sub`,
  so a token carrying `orgs: [A]` reached the database with no `orgs` claim —
  which `rbac.current_org_ids()` reads as *every* org the user belongs to.
  One verifier now, shared with the Content Server.
- **A streamed turn no longer hands its connection back still as
  `authenticated`.** A pooled connection left in a caller's role is the next
  caller's identity.
- **A missing secret, a path parameter and an uploaded file each decided
  authority, and none of them may.** The gateway accepted an unverified
  `X-P8-User-Id` when `P8_JWT_SECRET` was unset (it now refuses to start
  unless `P8_DEV_NO_AUTH=1`); an OpenAPI path parameter could escape its
  operation; an uploaded file was served with a content type it chose.
- **A credential goes only to the origin it is bound to.** A tool server
  registered at a host of your choosing was a credential oracle, and the worker
  sent credentials to whatever host the row or upload beside them named.
- **The worker refuses its own egress to internal addresses** — it argued the
  database should not have egress while having it itself, including to
  `169.254.169.254`.
- **Row text from a fan-out is not resolved as a template.**

### A turn that finishes, and a pool that holds

- **A pool of eight served four conversations.** A turn holds one connection
  for its life and takes a second per query, so `pool_max` of 8 deadlocked at
  eight concurrent turns. The default is 16, the budget is documented, and an
  acquire that cannot be satisfied now says so instead of hanging.
- **A task longer than the lease finishes once.** `heartbeat_task` shipped, was
  granted to `worker`, and was called by nothing, so a five-minute task was
  reaped and re-run.
- **A runtime that cannot serve its database refuses at startup**, naming the
  remedy, instead of failing inside every turn behind an HTTP 200 that
  `docker compose ps` calls healthy.
- **A database refusal reaches the caller as 403**, not as a server error, on
  every endpoint — and the worker no longer retries one four times.
- **A provider account out of credit is classified, not retried.** It looked
  like a rate limit on three of the four paths that call a provider.
- **A delegation tree has a budget**, and a run that stopped because it ran out
  says so rather than chipping as nothing in particular.
- **A scheduled step's namespace exists.** The documented form named one that
  did not.
- **A summary is replayed as delimited user text, not as a system prompt** — a
  summary is a record of a conversation, not an instruction from the operator.

### Contracts, configuration and screens

- **One translation from an agent document to a row.** `packages/apply.py`,
  `core/samples.py` and `percolate agent push` each knew one dialect, so an
  agent written the documented way installed through the wrong loader with an
  empty prompt and no output contract, reporting success. `agent push` was the
  worst of the three: it parsed the document into an `AgentSpec` and dropped
  `audience` and `category` **in the client**, so a documented extractor
  installed as a `general` agent. All three now send the document, and the
  extension holds the single translation (needs percolate 0.2.0).
- **`authoring.from_json_schema` keeps `$defs`.** A nested model's contract used
  to store a `$ref` pointing at definitions nobody kept, so `agent show | agent
  push` did not round-trip.
- **A provider account out of credit is classified, not retried.** It looked
  like a rate limit on three of the four paths that call a provider, so an
  exhausted account was retried until something else failed.
- **The agent runtime speaks OpenTelemetry.** `percolate_core/agentic/telemetry.py`
  is new; the published image has no telemetry module.
- **The workbench** (`percolate ui`, the `[ui]` extra) is new.
- **One database and one object store, whoever is asking** — which service you
  are does not change where the data is.
- **Six assistants implemented one suggestion contract six ways**, and one of
  them proposed tools it then called. One contract now, and four screens stopped
  doing the database's arithmetic in JavaScript.
- **A lake worker refines staged data in DuckDB** and runs `p8ql` LAKE steps.
- **A release tag names the commit that was released.** `v0.1.8` named a tree
  that said `0.1.7`, and nothing said so anywhere.

Two `get-percolate` pages describe telemetry and the workbench as not yet
shipped — `docs/src/ui.md` ("the workbench is not in a published release yet …
`percolate-core` `@@core@@` on PyPI has no `ui` command and no `[ui]` extra")
and `docs/src/operating.md` ("the agent runtime speaks OpenTelemetry **from the
next `percolate-core` release**"). Both ship here, and `@@core@@` renders
whatever `versions.toml` pins — so those sentences renumber themselves into
lies: the number stays true and the claim goes false. Rewritten in gp#27, which
lands **after** this release and after the pin moves, because until then
`@@core@@` still renders 0.1.8 and the corrected sentence would be false in the
other direction.

`docs/src/skills.md` is NOT in that set and is unchanged: the runtime still
does not read `agents.skills` or `context_policy.skills`, so its sentence
survives 0.1.9.

## Released versions

Read from git and the GitHub API on 2026-09-12, not from memory.

| tag | commit | `pyproject` at that commit | date | GitHub Release |
|---|---|---|---|---|
| `v0.1.8` | `8c03d2aa` | **0.1.7** ← wrong, see below | 2026-09-06 | yes |
| `v0.1.7` | `939a5be6` | 0.1.7 | 2026-09-04 | yes |
| `v0.1.6` | `d8ae1508` | 0.1.6 | 2026-09-02 | yes |
| `v0.1.5` | `6669bc49` | 0.1.5 | 2026-09-02 | **none** |
| `v0.1.4` | `db0a9440` | 0.1.4 | 2026-09-02 | **none** |

`0.1.0`–`0.1.3` were published to PyPI with **no tag at all**, so there is no
commit this repository can point at for any of them. `0.1.1` was **yanked**.

### `v0.1.8` points at the wrong commit, and is being left alone

The tag names `8c03d2aa`, whose tree says `version = "0.1.7"`. The commit that
actually carries 0.1.8 is `91ef61b` (*"0.1.8: bump"*), and it is **not an
ancestor of its own tag**:

```
$ git merge-base --is-ancestor 91ef61b v0.1.8
NO
```

**Cause.** The `tag` job in `.github/workflows/release.yml` checked out with no
`ref:`, so it took `github.sha` — `main` as it stood when the button was
pressed — while `build` and `image` both used `needs.version.outputs.sha`. Two
of three jobs had it right. `v0.1.8` was the first release under the tag-last
ordering and the only one affected. Fixed in #12, which also refuses to tag
when the checked-out tree disagrees with the version being tagged.

**The artifact is believed correct and the tag is not.** The wheel and image
were built by jobs that used the right ref, so what is on PyPI as 0.1.8 should
be `91ef61b`'s tree. That is an inference from reading the workflow rather than
something checked against the published wheel, and it is labelled as one so the
next reader does not inherit it as a measurement.

**Decision: annotate, do not re-point.** Moving a published tag is the thing
this project refuses to do elsewhere — `get-percolate` records `.so` digests on
every image precisely so that a re-pointed tag is *detectable* — and moving one
inside the fix for a mis-tagging bug, without saying so, would undercut that. The tag is
wrong, nothing downstream consumed it as a build input, and a moved tag is a
second and much harder-to-see kind of wrong. So: `v0.1.8` stays where it is and
this paragraph is the correction. Anyone reproducing 0.1.8 wants `91ef61b`.

Reviewable later, and this is the record to review.

### `v0.1.4` and `v0.1.5` have no GitHub Release

Both tags exist and both versions are on PyPI; neither has a Release object, so
neither appears in `gh release list`. Left as they are — a Release created now
would carry today's date and auto-generated notes for work done in September,
which is a worse record than a gap somebody can see. Noted here so the absence
is a recorded fact rather than a thing somebody re-discovers.
