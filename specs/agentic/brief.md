# Agentic — Spec Brief v0.1

## 1. What this is

A **Postgres data model + REST/streaming contract** for multi-agent conversations:
sessions, messages, tool calls, and delegation between agents — plus, unlike
earlier drafts of this brief, a specified **agent runtime** that actually
fulfills that contract: a purely declarative process, deployed Postgres-adjacent
exactly like PostgREST, that reads
`agents` rows and executes them by wrapping pydantic-ai. Not a framework with
built-in tools, and not "an example client among several equally valid ones" —
see §5. The contract (the tables, the REST/streaming surface) stays the actual
source of truth and stays implementation-agnostic in principle; this spec now
also commits to the shape of the one runtime this collection actually builds and
deploys against it — see §10 for how that runtime is packaged (one subpackage of
`percolate-core`, shipped in one image alongside the Content Server and the task
worker) and what the implementation has already proved, and **§11 for the
requirements any implementation must satisfy**, which is the list a reviewer checks and the one
that behavioural tests do not cover.

## 2. What we're keeping from an earlier agentic system, and what we're not

An earlier, private implementation's agentic system and its `sessions`/`messages` schema get several things
right, which this spec keeps as ideas (re-expressed, not copied as code):

- **Agents as rows, not code.** An agent is config — name, system instructions, tools,
  model, structured-output schema — not a Python class. Adding an agent is an
  insert. This spec keeps that: an `agents` table, not an agent registry in code.
- **Two persistence granularities for a turn**, and the tension between them is
  real and worth deciding explicitly rather than inheriting by accident:
  - *Fast path*: one row for the user turn, one for the assistant turn, tool calls
    riding along as JSONB on the assistant row. Cheap, good default.
  - *Slow path*: every tool call and tool response is its own message row
    (`user → tool_call → tool_response → ... → assistant`), needed when a tool call
    **is** delegation to another agent — the sub-agent's run needs to be a first-class,
    independently-queryable thing, not a JSONB blob inside a message.
  This spec's schema (§7) supports both without forcing a choice per-agent.
  **The slow path is written *during* the turn, not at the end of it**, and that
  is a requirement rather than an optimisation: the `tool_call` row has to exist
  before the sub-run does, or `runs.delegated_by_message_id` has nothing to point
  at and the delegation tree is only walkable in one direction. A runtime that
  persists a whole turn atomically at the end cannot populate that column at all.
  The fast path keeps its cheap end-of-turn write — an ordinary tool call still
  rides along as JSONB on the assistant row — so "slow" now means what it says:
  a row and a round trip per call, taken only when the call is a delegation.

**The rule, stated positively, because "two granularities" undersells what is
deliberately *not* kept:**

- **Every user and assistant message is a row.** That is the conversation.
- **`tool_call`/`tool_response` rows exist only for delegations.** A sub-agent's
  run has to be independently queryable, and its `runs` row has to point back at
  the call that spawned it.
- **Retrieval results are not stored at all.** A RAG result is volatile scratch
  inside an agentic loop: it is re-fetched next turn against a moving index, it
  would dominate the table by volume, and replaying it as history would feed the
  model stale context it did not ask for. The assistant row keeps the *fact* of
  the call — name, and whether it failed — and nothing of its payload.
- **What survives a retrieval instead is its provenance**: `messages.citations`
  (§5.3), derived mechanically from the rows the tool actually returned.
  Citations without payloads is the whole design — the answer stays traceable to
  what informed it without the store becoming a copy of the index.

**Two rows that exist but are never replayed.** A `chained_action`'s
`tool_call`/`tool_response` pair (§4) records something the *runtime* did after
the model finished, so the persistence adapter keeps it out of the history it
reloads — the model never asked for that call, and a Postgres function name is
not even a legal tool name to a provider (`agentic.apply_summary` is rejected
outright by OpenAI's name pattern — found by running it). Likewise a *scheduled*
run's own rows (§3) share a session with a conversation but are not turns in it:
a summarizer's input and output must never come back as the next chat turn's
history. Audit and replay are different questions asked of the same table.
- **Structured output → automatic follow-on action.** the earlier system's "chained tool call"
  (structured output matching a schema triggers an automatic tool invocation, both
  the call and its result persisted as message rows, no second LLM round-trip) is a
  clean pattern. This spec reframes it as **data**, not a Python callable lookup: a
  `chained_action` reference on the agent row (naming a Postgres function or an
  external endpoint via PostgREST/webhook), not an in-process dict — see §4.
  *Firing condition, clarified*: "structured output **matching** the schema" is
  not a runtime test the way it reads. Under pydantic-ai the output either
  validates against the agent's `structured_output_schema` or the run fails, so
  the action fires whenever the agent has both a schema and a `chained_action` —
  there is no third state to check for, and implementing one would be a phantom
  branch.

What's not carried forward:

- **The in-process Python tool registry** (tool modules mapped by name in a
  dict). Tools are rows referencing MCP/OpenAPI endpoints, resolved and called via
  REST — consistent with `ai-query-layer` treating query execution the same way.
- **The earlier system's specific persistence functions** (`rem_persist_turn`, `rem_build_moment`)
  as implementations — but not the *idea* behind them. the earlier system's "dreaming" (background
  consolidation of raw content into higher-order insight, run periodically rather
  than per-turn) is explicitly **in scope for this system**, not deferred — see §3.
  Leaving it unowned was an earlier omission in this brief: consolidation is a
  background-processing pattern of *this* module, not a separate system, because it
  produces and consumes the exact same `runs`/`messages` shape an interactive
  conversation does — it's just triggered by a schedule instead of a user.

## 3. Agentic as a background/batch pattern, not only an interactive one

Not every `run` starts from a live AG-UI session. A `run` can also be started by
`workflow-engine` as a scheduled task — consolidation, periodic summarization,
re-embedding, cross-session synthesis, anything that needs an agent's reasoning but
not a human on the other end. This needs two small, explicit additions to the model
in §7 rather than a second system:

- **`runs.trigger_kind`**: `'interactive'` (has a `session_id`, streams via AG-UI) or
  `'scheduled'` (created by a `workflow-engine` task, no live client attached).
  A `'scheduled'` run's `session_id` is null — and that leaves it with no owner,
  which matters more than it first appears: every RLS policy here scopes through
  `sessions.user_id`, so a null session would put scheduled runs outside tenant
  isolation entirely. **Decided**: `runs` carries its own `owner_id` (the
  session's owner for interactive runs, the triggering task's owner for
  scheduled ones) and RLS scopes on that column directly rather than through a
  session join. A real hole found by writing the policies out, not a theoretical
  one — a `session_id is null` escape hatch in a `USING` clause is how a table
  ends up with rows nobody can see and everybody can read.
- **`runs.workflow_task_id`**: set only for `'scheduled'` runs, the FK back to the
  `workflow-engine` task that triggered it. This is how a background consolidation
  run is reliably retried, rate-limited, and observed using `workflow-engine`'s
  existing machinery (queues, `max_attempts`, `task_events`) instead of a second,
  bespoke scheduler living inside `agentic`.

  **How the trigger actually reaches the runtime**: a `mode: "async"`
  `http_call` task (`workflow-engine/spec.md` §14) dispatched at the runtime's
  internal trigger endpoint — not the public AG-UI surface — carrying the
  triggering task's id. The runtime creates the `runs` row
  (`workflow_task_id` = that task's id), executes, and calls
  `complete_task(task_id, output)` itself once the run and any
  `chained_action` it fires finish. No bespoke integration between the two
  systems: dispatch is an ordinary task, and completion is the same
  `complete_task` call a worker makes, on a `worker` login (`P8_WORKER_DSN`,
  §10.1).

  **Two things that only show up once it runs.** First, the trigger endpoint
  must *accept and return* — it cannot await the run. The dispatch request is
  bounded by the step's `timeout_ms` and a timed-out dispatch is retried, so an
  endpoint that ran the whole turn before responding would be sent the same run
  again. After a successful dispatch the worker holds the task's lease with
  heartbeats until the runtime's `complete_task` or `fail_task` moves it, up to
  the step's `wait_ms` (`workflow-engine/spec.md` §14). Parking the task in
  `waiting_external` instead, which this paragraph used to describe, is not
  built: the lease fence refuses completion of a parked task.
  Second, a scheduled run **reloads no history**: its context is the input it
  was dispatched with, not the conversation it happens to be about. Giving it
  the conversation duplicates its own prompt and makes a background job's
  behaviour depend on live chat.

**What a consolidation run does, concretely**: it's an ordinary agent run (same
`agents` config row, same `messages`/`tool_calls` shape) whose "input" is a query
against `ai-query-layer` (recent resources, events, or sessions since the last
consolidation) and whose structured output — via the same `chained_action`
mechanism §4 already defines — writes new `entity` (type `insight`) and `edge` rows
back through `ai-query-layer`'s generic entity/edge tables, typed the way the earlier system's
dreaming used `builds_on`/`dreamed_from`. No new persistence mechanism: consolidation
is a `chained_action` that happens to run on a schedule instead of after a chat
message. It is also how this collection provides the **memory systems** component
of a turn's context (§5.0): what one session established is written where the
next session's retrieval finds it, rather than carried in any session's history.

**Validated by more than one real need, not just consolidation**: a downstream
application needs the same scheduled-run shape twice more — a standing knowledge
base of narrative themes refreshed by periodic LLM synthesis, and a retrospective
accuracy audit run once an event resolves. Neither needs a new mechanism beyond `trigger_kind` /
`workflow_task_id` above — both are just scheduled runs with a different query and a
different `chained_action` target.

**A fourth real need, and this brief's sample workflow: context-window
summarization** — compaction, in the context-engineering vocabulary, applied to
the conversation state and history component (§5.0). The summary stays inside
that component: it belongs to one session and is never carried to another.
§5.1's context-reload policy default is **windowing**: the
persistence adapter reloads only the most recent bounded window (by message
count or token estimate — configurable, not hardcoded) into `message_history`,
never the full session unconditionally. The window reserves one fixed logical
slot — a `role = 'summary'` message, injected at the *tail* of the reloaded
history (the oldest position in what's actually sent to the model, immediately
before the windowed recent messages) — for a running summary of everything the
window has already pushed out. Empty/absent until the window has ever needed
one.

That summary doesn't get computed inline, synchronously, inside a request —
it's the same scheduled-run pattern as consolidation, just event-triggered
instead of clock-triggered: once a session's message count or token estimate
crosses a configurable threshold, `start_workflow('summarize_session_window',
...)` fires (most naturally from a trigger on `messages` insert, checking the
running count for that session — "Postgres owns orchestration state" applies
here the same as everywhere else in this collection, not just in
`workflow-engine`'s own tables). The dispatched run is an ordinary scheduled
agent run over the messages about to fall out of the window, and its
structured output — via `chained_action`, same as consolidation — upserts the
`role = 'summary'` row, superseding whatever summary was there before.

**Who summarizes, and how, is extensible in data, not hardcoded logic.** The
summarizer is itself just an `agents` row — a cheap-model agent whose system
prompt says how to compress a conversation segment — referenced by a new
`agents.summarizer_agent_id` (nullable; null falls back to one system-wide
default summarizer agent). Changing what "summarize" means for a given agent,
or swapping in a different model for it, is an update to that reference, never
a code change to the persistence adapter or the runtime. `summarize_session_window`
is a genuinely minimal `workflow.definitions` row (one `http_call` step, `mode:
"async"`, dispatched exactly like consolidation) — small enough to document
directly as this brief's reference example of the whole background/batch
pattern, not just described abstractly.

**An install without that row is not summarized, and no turn fails for it.**
Nothing the extension or get-percolate installs provides either half: the
`summarize_session_window` row, or the default summarizer agent, whose model is
a provider choice each install makes. Both are seeded only in development
(`core/dev/seed.sql`). So summarization is a side effect of a turn that has already answered,
and a dispatch that cannot happen (no definition, a refusal, a dropped
connection) leaves the run's status as it was. The runtime records why on the
run's trace and logs it. At startup it names what is missing as a warning. It
does not refuse to start, as §10.4's probe does, because a missing session stops
every turn and a missing summary stops none: past the threshold the oldest
messages leave the window with nothing in the summary slot. Before this was
written down, the dispatch ran inside the turn's failure handling, and on a
stock install every run in a session past `summarize_after_messages` was marked
`failed` after it had answered, delegated children included.

Shipping both rows with every install is how summarization becomes the default
the paragraphs above describe. The definition's step posts to
`{{env.P8_AGENT_URL}}/internal/run`, which both `percolate agent serve` and
`percolate agent gateway` serve; what it waits on is a summarizer agent with a
model the install has credentials for.

## 4. The interface: AG-UI over Postgres

The earlier system already spoke **AG-UI** on `POST /chat/{sessionId}` — `threadId`, `runId`,
`messages[]`, `tools`, `context`, `forwardedProps`, `state`. This
spec adopts AG-UI as the wire protocol
rather than inventing a new streaming shape, and defines how AG-UI concepts map onto
Postgres rows:

| AG-UI concept | Postgres shape |
|---|---|
| `threadId` | `sessions.id` |
| `runId` | `runs.id` — one row per agent invocation, **including delegated sub-agent runs** |
| `messages[]` | `messages` rows for that session, ordered |
| a delegation (agent A calls agent B) | a `runs` row with `parent_run_id` set, `delegated_by` = the tool_call message that spawned it — this is how a "multi-agent tree" becomes queryable (`ai-query-layer`'s `GRAPH` mode can walk it) rather than living only in application memory |
| streaming deltas | Postgres `NOTIFY` on the session's channel, relayed to the client as AG-UI `TextMessageContent`/`ToolCallStart` etc. events — same NOTIFY-relay pattern as `workflow-engine` and `user-rbac`, not a new mechanism |
| `state` | a `runs.state` JSONB column, so a resumed/observed run doesn't need in-memory server affinity |

The REST surface is PostgREST over `sessions`/`runs`/`messages`/`agents` (CRUD,
RLS-scoped to `user-rbac`'s `current_user_id()`) plus one FastAPI-fronted streaming
endpoint per session for the SSE/WebSocket bridge — streaming is the one piece that
structurally can't be plain PostgREST.

**Built, and the chat surface is two endpoints, not one.** `POST /chat` (also
served as `POST /v1/chat/completions`) runs a turn; `GET /sessions/{id}/events` relays the same stream to a client that
did not start the run. The second is not a convenience — it is the proof that
the stream is a *relay* rather than a side effect of the request: a client that
drops mid-turn reconnects and keeps receiving, and a second client can watch a
conversation it did not start, delegated sub-runs included. Both read the same
`NOTIFY` channel, which is why neither needs to know delegation exists.
`stream` defaults to `false`, as in the OpenAI shape, and returns the finished
turn; `stream: true` returns the AG-UI event stream. Refusing `false` once broke
every stock OpenAI client and every compiled `agent:` step.

**Resuming a thread is a header, not a body field.** `threadId` maps to
`sessions.id`, and a client sends it back as **`X-P8-Session-Id`** — the same
name the response returns it under, so resuming is echoing what you were given.
The header, rather than only a body field, is the load-bearing part: the inbound
contract is the OpenAI chat shape (§5.1 item 2), which has nowhere to put a
thread id, so a client using an off-the-shelf SDK can *only* reach for a header.
An unknown or unowned id fails with a status code before the stream opens, never
as an event inside it — once the response has begun the status is already sent,
and "your session id was wrong" is not something a client should have to parse
out of a stream. Resume needs nothing else: history is reloaded from rows by the
persistence adapter (§5.1), so a client carries an id and nothing more, and a
conversation survives the client, the connection, and the process.

**Why the NOTIFY channel is per *session*, not per run — and what that buys.**
Every run in a session, delegated sub-runs several levels deep included,
publishes to the same `agui_<session_id>` channel tagged with its own `runId`.
Multiplexing a delegation tree into one client stream is therefore *structural*
rather than something the runtime arranges: one listener on one channel sees
parent and children interleaved in real time, already correlated by the run tree
the rows describe. This is worth contrasting with the earlier system explicitly, because
it solved the same problem the only way an in-process SSE generator can — a
`ContextVar`-held `asyncio.Queue` that child agents push into and the parent's
stream races against with `asyncio.wait(FIRST_COMPLETED)`, forwarding child
output as bespoke `child_content`/`child_tool_*` events. All of that machinery
exists to fan child output back into a parent generator that owns the socket.
With Postgres as the bus there is no parent generator to fan into and no bespoke
event kind is needed: the child writes to the same channel, the relay is a dumb
`LISTEN`, and a client that reconnects mid-delegation resumes from rows instead
of losing whatever an in-memory queue was holding.

**Two kinds of message share that one channel, deliberately.** The runtime
publishes AG-UI events as they happen (`TEXT_MESSAGE_CONTENT` deltas,
`TOOL_CALL_START`/`END`), and a trigger on `messages` publishes a
`MESSAGE_PERSISTED` checkpoint carrying ids only — never content, because
NOTIFY's payload limit is 8000 bytes and the relay can read the row. Live deltas
are the fast path for a client that is watching; the checkpoint is what a client
that reconnected, joined late, or missed a delta resumes from, and it is also
what makes a row written by *any* other client (PostgREST, a migration, a
chained action) show up in the stream at all. The assistant message's id is
minted before the turn runs and reused when the row is written, so both kinds of
message are talking about the same message rather than two ids for one answer.
That in turn requires `persist_turn` to **honour a caller-supplied `id`**: if
the database mints its own, the stream refers to a message id that never
existed, and nothing fails loudly — the deltas simply describe a message no
client can ever match to a row.

## 5. The agent runtime — declarative, tool-free, Postgres-adjacent

Deployed as its own service, the same pattern as PostgREST: one process (or a KEDA-scaled pool for
background/scheduled runs, per §3) that connects to Postgres — reading
`agents`/`sessions`/`runs`, writing `messages`/`state` through the same
functions and RLS any other client would go through, no privileged backdoor —
and makes the two kinds of outbound call Postgres structurally can't make
itself: the LLM API call, and calls to whatever microservices an agent's tools
are bound to. Same "one process owns the calls Postgres can't make" pattern as
`user-rbac`'s FastAPI owning OAuth exchange, just for agents.

### 5.0a What one process costs a database, which is not one connection

**A turn needs two connections at the same time, and a stream needs one that is
not in the pool at all.** Both follow from decisions made elsewhere in this
document, and neither is visible from outside the process, so they are stated
here rather than rediscovered:

- **Two per turn.** §4's streaming needs a connection held for the whole turn —
  otherwise a sixty-word answer is sixty transactions, an acquire and a `BEGIN`
  per token delta. Every query the turn makes *inside* that takes a second
  connection, because the held one is session-scoped at the caller's role and a
  query wants its own transaction. So a pool of N serves N/2 concurrent turns,
  not N. Getting that wrong is not a slowdown: the second acquire waits on a
  pool the first halves are holding, which is a deadlock at exactly the
  concurrency the pool size looks like it allows.
- **One per stream, outside the pool.** A `LISTEN` connection that went back to
  the pool would stop listening, so it is dedicated for the life of the stream
  and bounded by its own limit.

The consequence is a sum an operator has to do before choosing
`max_connections`: *listeners + pool*, per process, times replicas. The numbers
live with the settings that set them — `percolate_core/agentic/settings.py`,
`pool_max` and `max_listeners` — and not here, because a number restated in
prose beside the thing that holds it drifts from it. What belongs here is the shape, and the reason the shape is not
one connection per request.

`../workflow-engine/scale.md` ("The connection budget is the ceiling on worker
count") is the same arithmetic already having gone
wrong at cluster scale: 30 pods × 4 connections exhausted a default
`max_connections` and locked the operator out of their own database, because
`superuser_reserved_connections` is 3 and nobody had added it up.

### 5.0 Context engineering — the five components a turn assembles

What the runtime sends a model on a turn is described in the vocabulary of
context engineering: *"the set of strategies for curating and maintaining the
optimal set of tokens (information) during LLM inference"*
([Anthropic, *Effective context engineering for AI
agents*](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).
The context has five components, and `specs/` and the docs name them the same
way everywhere. They are not §5.1's four runtime components: those are the code,
and these are what the code assembles.

| Component | What it is | Where it comes from here | State |
|---|---|---|---|
| **System instructions** | The rules that set the model's behaviour, role and tone | `agents.system_prompt`, which is the agent document's `description` (§6); the skills composed or matched into it (§5.4, `plugins.md` §5); the `<context>` block rendered from `X-P8-*` request headers (§5.1 item 4) | Built: `system_prompt`, pinned `agents.skills` and the context block are sent |
| **Conversation state and history** | What has been said in this conversation | The `messages` of the run's branch, windowed by `context_policy.window_messages`, with the `role = 'summary'` row at the tail (§3, §5.1 item 1) | Built. The summarizer workflow and agent are seeded only in development, so an install without them windows with no summary (§3) |
| **Retrieved knowledge** | External data pulled in when the turn needs it | `ai-query-layer` over the world model — `content.resource_chunks`, the `aiq` graph — through a tool server flagged `emits_citations`, with `messages.citations` derived from what came back (§5.3) | Built |
| **Tool definitions and outputs** | What the agent may call, and what the calls returned | `tool_servers.cached_tools` narrowed by `agents.tools` (§5.2), including the agent gateway for delegation; results as `tool_calls` JSONB on the assistant row, or as `tool_call`/`tool_response` rows for a delegation | Built |
| **Memory systems** | Facts carried from one session to the next | The world model written back from use: consolidation runs (§3) writing `insight` entities and edges through `chained_action`, and moments. Read back by the same retrieval as knowledge | The tables are built. No shipped workflow writes memory from a session yet |

Five rules follow from where each component lives.

- **A component is decided by how the model treats the text, not by the table
  it came from.** A matched skill is found by the same `SEMANTIC`/`TEXT`
  machinery as a document and is still a system instruction, because a skill is
  obeyed and a document is weighed (`plugins.md` §3). A session summary is a
  model's interpretation and is still conversation state, because it belongs to
  one session and is superseded rather than carried to the next.
- **Retrieved knowledge and memory share tables and differ in provenance.**
  `content.resources`, `aiq.nodes` and `content.moments` hold both. Knowledge
  was ingested from a source outside the system; memory was written from the
  system's own use. A reader weighing an answer needs to know which one it
  rests on, so the row has to say.
- **Retrieval is just in time, and it arrives as a tool output.** No retrieval
  step runs before the model call. The agent issues the query through a tool,
  the result is in context for that turn, and only its citation survives into
  history, because the payload is never persisted (§5.3). Next turn it is
  fetched again against the current index.
- **Request context is a system instruction, never history.** The date, the
  tenant and the locale arrive as headers and are rendered into the
  instructions, so no window policy can drop them (§5.1 item 4).
- **A sub-agent starts with a clean conversation.** The window is scoped to the
  run's branch (§5.1 item 1), so a delegated agent sees its own turns and none
  of its caller's, and the caller sees the delegation only as a tool call and
  its result. A scheduled run has no history component at all: its context is
  the input it was dispatched with (§3).

In prose these five names are used as written. `system_prompt` is the column
holding the agent's own share of the system instructions, and is spelled as a
column when the column is meant.

### 5.1 Four components, wrapping and inheriting pydantic-ai, not replacing it

The runtime is a thin, opinionated layer around pydantic-ai's own `Agent` —
the LLM-calling, tool-invoking, structured-output engine stays pydantic-ai's;
this layer's job is everything around that engine that pydantic-ai itself is
naturally silent on:

1. **The Postgres persistence adapter**, which supplies the conversation state
   and history component (§5.0) — pydantic-ai's own conversation model
   (a `message_history` list passed into `Agent.run()`) mapped onto
   `sessions`/`runs`/`messages`, in both directions: persist a turn the way §2
   already specifies (fast path / slow path), and — the part that needs an
   actual opinion, not just a mapping — **reload** a bounded, defined subset
   of history into `message_history` for the next turn, not unconditionally
   "everything ever said in this session." **Default: windowing, with a
   reserved slot for a data-extensible rolling summary** — §3's
   `summarize_session_window` sample workflow is the concrete design, not
   deferred further here. Long-running, deeply-delegated conversations under a
   sensible persistence policy are the explicit goal this whole component list
   is in service of (closing paragraph below).

   **What "the window" is scoped to — settled by running a delegated turn.**
   Not the session: a session-scoped window hands a delegated sub-agent the
   *parent's* rows, including the `tool_call` row representing its own
   invocation, which is both wrong and confusing to the model. The rule is
   **branch-scoped**: a run reloads the messages of the runs that share its
   parent — `null` for a top-level run, so successive turns of the conversation
   are one continuous history; the parent's run id for a delegated one, so a
   sub-agent sees its own turns and nothing of the conversation that called it.
   The parent still sees the delegation, because the `tool_call`/`tool_response`
   pair lives on the *parent's* run (§2's slow path) — that is what those rows
   are for. This closes §9's "where is the line between this session's history
   and this run's history for a delegation tree" outright; it stopped being a
   question the first time a sub-run was actually executed.
2. **Protocol adapters, both directions, deliberately asymmetric.** Inbound:
   the runtime accepts an OpenAI-chat-completions-*shaped* request (`messages`,
   `model` — which names an **agent**, not an LLM, so an off-the-shelf client
   drives this runtime with no bespoke fields — plus `tools`, `stream`) as its
   default request contract — not because
   this system is calling OpenAI specifically, but because that shape is the
   de facto common denominator most existing clients and SDKs already speak,
   so nothing upstream needs a bespoke client just to talk to this runtime.
   A client's `tools` are accepted by the shape and **ignored**: an agent's
   tool surface is whatever `tool_servers` its row points at (§5.2), and
   honouring caller-supplied tools would reintroduce exactly the in-process,
   per-request tool binding this design removed. Stated rather than left to be
   inferred, since the field exists in the shape and silently dropping it is
   otherwise indistinguishable from a bug.
   A caller may narrow a turn with `tool_choice: "none"`: the resolved copy
   has no tool bindings or chained action, so an authoring proposal cannot
   execute through either path. This leaves the stored agent unchanged and
   does not permit caller-supplied capabilities. `response_format` can request
   a structured answer for that turn. The workflow composer supplies schema
   and catalogue data itself and checks support through the runtime OpenAPI
   contract before sending this option.
   Outbound: streamed responses are AG-UI events (§4), not OpenAI's own
   streaming format — this system's richer wire protocol on the way out,
   the common one on the way in. **Nested delegation maps onto AG-UI's
   existing tool-call event shape directly**, and needs no new event types:
   a delegation is already represented as a `tool_call` message (§2's slow
   path) whose "tool" happens to be another agent, so the sub-agent's entire
   streamed turn is naturally exactly the payload of a
   `ToolCallStart`/`ToolCallEnd` pair in the parent's own AG-UI stream,
   correlated by the sub-run's own `runId` — a client renders "delegating to
   agent B" as an in-progress tool call and B's streamed output as that
   call's contents, without the protocol needing to know delegation is
   happening at all.
3. **The declarative multi-agent delegation pattern itself** — `agents` rows
   plus `parent_run_id` (§7), already speced, restated here as a named
   component because it needs to be a *tested* reference implementation, not
   only a schema: a multi-level delegation tree has to round-trip correctly
   before anything else builds on top of it.

   **How an agent declares who it may delegate to — resolved by building it.**
   The earlier draft left a hole: `agents.tools` references `tool_servers`
   rows and nothing else, and §5.2 forbids the runtime having built-in tools,
   so there was no legal way to express "agent A may delegate to agent B" — a
   hardcoded `delegate(agent)` tool would have been the first built-in tool
   and would have broken the rule the rest of this design rests on. The
   resolution keeps the rule intact: **the runtime exposes its own agents as
   an MCP server** — the *agent gateway* — one tool per agent, and delegation
   becomes an ordinary `tool_servers` reference like any other. Same insert,
   same per-agent allowlist (`agents.tools[].tools` is now also how you narrow
   *which* agents A may delegate to), same invocation path; the runtime
   discovers `agent__<name>` tools by calling `list_tools` on that server
   exactly as it would any third-party one, and a delegated call leaves the
   process and comes back like any other tool call. The gateway is the same
   deployed runtime, so this is not a second service — it is the one service
   already specified here, also speaking MCP.
4. **Request context in the system instructions, sourced from the request,
   not the conversation.** Ambient context an agent needs but that isn't part of the
   conversation history — current date/time, tenant, other request-scoped
   metadata — arrives as HTTP headers on the inbound request (kept separate
   from `messages` on purpose, so it never has to be replayed, summarized, or
   accidentally dropped by the persistence adapter's context policy above,
   since it was never conversation content to begin with) and gets injected
   into the system instructions or passed as pydantic-ai's own typed `deps` at
   invocation time. **The header contract, now defined rather than deferred**:
   every injected header shares one `X-P8-*` prefix (`X-P8-Tenant`,
   `X-P8-User-Id`, `X-P8-Locale`, alongside W3C `traceparent`, which is not
   P8-specific and keeps its standard name); an unknown `X-P8-*` header is
   forwarded verbatim into the agent's typed `deps` rather than rejected, so
   adding one is never a runtime code change; and an absent header takes a
   documented default (`now()`, `en-US`) rather than failing, with identity
   fields simply absent when the caller is anonymous. One prefix, one parse,
   one place any future "what else needs injecting" answer lands. This is also
   what propagates a delegation's context to the agent gateway (item 3): the
   sub-run's session, parent run and trace ride as `X-P8-*` headers on the MCP
   call, which is why delegation needs no bespoke plumbing to stay inside one
   session and one trace.

   **On the way out, the context stops where the caller's token stops.** The
   paragraph above is about context arriving, and for a long time that was all
   this section said — so the runtime forwarded the whole `X-P8-*` block to
   every tool destination, and a registered third-party tool server was found
   echoing back a live `X-P8-User-Id` and `X-P8-Session-Id` while `outbound_headers`
   was correctly refusing that same request the caller's token. Half of an
   identity boundary is not one, so: **`X-P8-*` crosses only to an origin in
   `P8_TOOL_AUTH_ORIGINS`**, which is the list that already decides whether the
   token goes. One list, both questions. `traceparent` is exempt because it is
   not ours and names nobody — propagating a trace across a third party is what
   the W3C standard is for.

   The rejected alternative was a per-server column declaring what context that
   server may receive. It is a shipped extension change, and it would stand a
   second list beside `P8_TOOL_AUTH_ORIGINS` for one boundary; an operator who
   wants a tool server to know the tenant binds its origin, which is a sentence
   this design already has. The delegation case above is unaffected and is the
   reason the rule is origin-bound rather than a blanket strip: the gateway is
   first-party, and the shipped compose file puts its origin in that list.

Together, these four are what "stream multi-agent requests with long context
under a sensible persistence policy" actually requires — none of the four is
optional if that's the goal, and none of them is pydantic-ai's job to solve on
its own.

**Quota enforcement is per-LLM-call, not just per-run-start.** `user-rbac`'s
`rbac.has_quota_remaining()` (`specs/user-rbac/schema.sql`) is called by the persistence
adapter (component 1) before *every* LLM call the runtime makes, not only
once when a `run` begins — a long, deeply-delegated run can burn through a
user's remaining quota partway through, and checking only at the start would
let the rest of that run proceed unmetered. When a call is denied, the run
doesn't hard-error: it transitions to a terminal `runs.status =
'quota_exceeded'`, the same way any other terminal status is reached, so
whatever partial answer/state already exists (`runs.state`, prior `messages`
rows) is preserved and inspectable rather than lost — a quota cutoff is an
expected outcome this system plans for, not a crash. **Ordering, learned by
building it**: the user's turn is persisted *before* the quota gate, not after.
Check-then-persist reads as the natural order — don't write anything if the call
won't happen — but it silently loses the user's message on the first turn of a
session, contradicting this paragraph's own promise. The rule is: persist what
the user said, then decide whether the model may be called.

**A refusal from the database crosses the HTTP boundary as 403.** Every
authorization rule lives in Postgres (§10.2), so "you may not" arrives here as
SQLSTATE 42501 — `insufficient_privilege`, which this collection's own `not
authorized` raises carry — and the runtime answers it with 403 and the message
and hint the database gave ("needs agents:invoke"), which is what PostgREST
already answers for the same SQLSTATE on the CRUD half of the API; a streamed
turn is refused *before* its stream begins, because once the first frame is out
the status line is spent and a refusal can only be a `RUN_ERROR` event.

### 5.2 Tool binding architecture — tools are rows, OpenAPI extends the MCP shape, tools are always external

**Zero built-in tools, ever.** The runtime has no tool code of its own — not
even a trivial one like "web search" or "read a file." Every tool an agent can
call is a reference to an independently deployed, independently versioned
microservice — this is absolute, not a default: there is no code path in this
runtime that implements tool logic itself, for any agent, ever.

**Tool providers are their own rows, not embedded config.** An `agentic.tool_servers`
table registers each MCP server or OpenAPI service
*once* — url, `kind` (`mcp` | `openapi`), `credential_ref` (§9 on credential
resolution — same "never a literal secret in a Postgres row" boundary as
`http_call`'s), and a cached list of the tools/operations it currently exposes.
`agents.tools` becomes a list of *references* into `tool_servers` (optionally
scoped to a subset of that server's tools), not raw URLs and auth config
duplicated inline per agent. Registering a new tool provider is an insert —
same "agents as rows, adding one is an insert" pattern this brief already
applies everywhere else, now applied to tool providers too. Without this, the
same OpenAPI service used by ten agents would mean its URL and credentials
copied into `agents.tools` ten times, exactly the kind of duplication
this design avoids.

**Registration is a sync step, not just a stored URL.** Inserting a
`tool_servers` row triggers fetching the OpenAPI spec (or connecting to the
MCP server and calling its `list_tools`) and caching the resulting tool/
operation list on that row — so the runtime isn't re-fetching a spec on every
single agent invocation, and so `agents.tools`' per-agent allowlist has
something concrete to reference. Staleness (the upstream spec changing) is the
same class of problem as any other cache — a scheduled `workflow-engine` task
re-syncs it periodically, reusing that system rather than inventing a second
scheduler here, the same pattern §3 already uses for consolidation.

**OpenAPI binding extends the MCP shape, doesn't duplicate it.** MCP already
defines the canonical shape a tool needs to be usable — name, description,
input schema, an invocation target `call_tool` can reach. An OpenAPI binding
is an *adapter*, not a second, parallel mechanism: it turns each selected
OpenAPI operation into that same canonical shape (operation → name/description/
schema, the endpoint URL + HTTP method → the invocation target) before handing
anything to pydantic-ai. Downstream of registration, the runtime resolves a
toolset from one or more `tool_servers` rows into one list of canonically-
shaped tools — it never needs to know, once resolved, whether a given tool
came from an MCP server or an OpenAPI spec.

**What a tool server usually is, and why the adapter stays mechanical.** In
practice the services agents bind to are CRUD — PostgREST over some schema, or a
small OpenAPI service in front of one. That is not a limitation to design
around; it is the reason the OpenAPI adapter can be purely mechanical, with no
per-service knowledge anywhere in it: `operationId` → tool name (falling back to
`method_path` when absent, since `operationId` is optional in OpenAPI and one
missing id must not make a whole server unusable), `summary`/`description` →
description, path/query/body parameters merged into one input schema and
re-split at call time by consulting each parameter's own `in`, and method + path
template → the invocation target. If binding a service ever seems to need a
hand-written adapter, that service is not the shape this system binds to.

**Two things the first real binding taught, both cheap and both non-obvious.**
First, the document is frequently **Swagger 2.0, not OpenAPI 3** — PostgREST 12,
this collection's own REST surface and the most likely first tool server anyone
registers, emits 2.0 with `$ref`s into a shared `#/parameters` block. An adapter
that only reads 3.x cannot bind the thing this collection already runs, so
handling both is the baseline, not gold-plating. Second, the base URL for calls
is **where the document was fetched from, not what the document claims**:
`host`/`basePath` (2.0) and `servers` (3.x) routinely lie behind a proxy, and we
already hold an address that demonstrably works — preferring the document's would
be trading a fact for a claim.

**`credential_ref` belongs in the read view, not hidden from it.** It is a
*reference* (`env:X`, `vault://path`), never the secret — this section already
forbids literal secrets in rows, so there is nothing there to hide. Excluding it
from `tool_servers_api` was tried first and is worse than useless: the runtime
reads its tool servers through that view like every other client, so hiding the
ref silently produced *unauthenticated* tool syncs — a cached tool list that
looks correct and is missing every operation the caller's role would have been
allowed to see.

**A second column the earlier draft was missing: `default_headers`.** A base
url does not always identify an OpenAPI document. One PostgREST serves every
schema in the database from a single url and selects between them with
`Accept-Profile`, so registering this collection's own REST surface without
that header fetches whichever schema happens to be first and caches a tool list
that is complete, plausible and about something else. The adapter is forbidden
per-service knowledge, so it cannot be taught the header; the row carries it.
Non-secret only — a check constraint refuses `Authorization` and `Cookie`,
because a credential in a header is the same credential in a row that
`credential_ref` exists to keep out.

**Agents are loaded per turn, and §11.9 makes that a requirement rather than
an implementation detail.** "Adding an agent is an insert" is only true if
nothing has to be restarted for the insert to take effect, which is a property
of the runtime, not of the schema — so it is stated where an implementation is
checked against it.

**Worked, and the findings written down.** [`reference/`](reference/README.md)
is this section executed: `percolate.yaml` registers one MCP server and one
OpenAPI server and binds one agent to five tools across both; `binder.py` is
the register/discover/invoke path with no branch anywhere on which service is
being bound; `query_mcp.py` is the one MCP tool this collection ships. Its
README lists what building it found, including the two failures this section
predicted in prose and had never reproduced — an anonymous sync returning a
plausible subset, and a base url resolving to the wrong document.

**One column the earlier draft was missing: `emits_citations`.** §5.3 derives
citations from tool responses, which requires knowing *which* responses are
retrieval results. Recognising them by tool name (`query_*`, `search_*`) is a
convention that breaks the first time someone names a tool differently, so the
flag lives on the `tool_servers` row instead — `ai-query-layer`'s server sets
it, a ticketing API does not. Data, like everything else here.

**Why this is the point, not just a constraint.** This is the
core-plus-extensions discipline taken to its logical end: the runtime is core, and it never changes
to accommodate a new use case — every use case is 100% data (an `agents` row,
`tool_servers` rows, and whichever independently-deployed microservices they
point at), never a code change to the runtime itself.

**Measured, now that a runtime exists.** The runtime is one Python subpackage
(`core/percolate_core/agentic`) over the tables, views and functions in
`schema.sql`.
Adding an agent or a tool provider is **zero lines of code** — an insert, or a
migration that produces one. Grep the runtime for a domain noun and there is
nothing to find: the only place any use case appears is fixtures. That was the
claim this section made; it is now a property that can be checked rather than
argued. The system stays
*isolated from* use cases while staying *battle-tested*, because the execution
engine underneath the declarative layer is pydantic-ai's own — a real,
maintained library, not something hand-rolled here — and the thin binding
layer around it has no use-case-specific logic to accumulate bugs in over
time. A new agent, or a new tool provider, is always a row (or, per §6, a
migration that produces one); neither is ever a reason to touch, test, or
redeploy the runtime.

**Tool-call failure semantics.** A bound tool can fail two structurally
different ways, and the runtime keeps them distinguishable rather than
collapsing both into one generic error: (1) the tool server responded, but the
call itself failed (an MCP `tool_result` with `isError: true`, or an OpenAPI
call that returned a non-2xx) — persisted as an ordinary `tool_response`
message with `is_error = true`, so the LLM sees the failure as a normal
observation and decides what to do next (retry with different arguments, try
another tool, surface the failure to the user); (2) the tool server couldn't
be reached at all (timeout, connection refused, DNS failure) — persisted the
same way but with `error_kind = 'dispatch_error'` instead of `'tool_error'`,
since "the tool ran and said no" and "the tool was unreachable" are different
facts an agent (or a human reading the run afterward) needs to tell apart.
**No retry is automatic at the runtime level** — an automatic-retry policy is
exactly the kind of use-case-specific logic the runtime is designed to never
accumulate; retrying is something the agent does by calling the tool again,
same as any other decision it makes from an observation. The one exception is
transport-level retry (connection reset, momentary DNS failure) for tool calls
the runtime dispatches through `workflow-engine`'s `http_call`
(`workflow-engine/spec.md` §14) under the hood — those get that primitive's
existing retry/backoff for free, the same "one retry mechanism, reused, not
reinvented" rule this collection applies everywhere else, not a second policy
grafted onto the agent runtime.

### 5.3 Citations — provenance on generated answers

An agent's final answer, when it was informed by retrieved knowledge (§5.0) —
`ai-query-layer`'s `SEMANTIC`/`GRAPH`/`LOOKUP` results fed back as tool
responses during the run — should be traceable back to *which* resources actually informed it —
"which chunks/entities does this answer rest on" is a real, recurring question
(surfaced by a deep-research stress scenario), not a
nice-to-have.

**Design: derived from tool responses, not hand-curated by the LLM.** Asking
the model to remember and correctly emit a citation list as part of its own
structured output is unreliable — models drop citations, invent ones that
don't match what was actually retrieved, or cite generically instead of
per-chunk. Instead, `messages.citations` (a JSONB array, on the assistant
message only) is populated by the **runtime**, mechanically, from the
`tool_response` messages between the previous assistant message and this one:
for every response from a tool server flagged `emits_citations` (§5.2), the
runtime extracts the `resource_type`/`resource_id` (and `chunk_id`, when the
result was a `resource_chunk` row) of every row that query actually returned,
and writes the union as this message's `citations`. This is provenance by
construction — "what did the agent's context actually contain when it
answered," not "what does the agent claim it used" — and needs no cooperation
from the model or the agent's `structured_output_schema` to work.

**Citations point at resources, not at graph nodes.** This is a deliberate
consistency point with [`../ai-query-layer/graph-identity.md`](../ai-query-layer/graph-identity.md)'s inclusion policy: `resource_chunk`
rows are explicitly machine-generated data-plane rows, not `nodes` — so a
citation is `{resource_type, resource_id, chunk_id}` referencing
`world-model-ingestion`'s own tables directly, never a `node_id`. When a
`GRAPH`-mode result contributed (an `entities`/`events` row that *is* a node),
the citation carries `node_id` instead — the shape is a tagged union
(`{kind: 'chunk', resource_id, chunk_id}` vs. `{kind: 'node', node_id}`), not
one column trying to mean both things.

**Scope: per-answer, not per-run.** Citations reset at each assistant message,
not accumulated across the whole `run` — an agent's tenth answer in a long
session cites what informed *that* answer, not everything ever retrieved
earlier in the conversation. A citation referencing content from three turns
ago is legitimate only if that content is still in the current context window
(§3's windowing policy) and gets re-retrieved or re-referenced by a tool call
in this turn; citations are not a substitute for, or a workaround around,
context-window truth.

**Not built here: rendering.** How a client displays `citations` (inline
markers, a footnote list, hover cards) is a client concern, same as AG-UI
event rendering generally (§4) — this section only specifies that the data
exists on the message row, shaped consistently, so any client can build that
UI without a bespoke extraction step.

> **When an extractor cannot resolve, it has nowhere to say so.** Its options
> today are to fail the task, to guess, or to sit in a `signal:` step holding a
> task open until a person answers — and human latency is measured in days.
> A fourth option is proposed and unbuilt:
> record the question at the locus and **complete successfully**, so ten
> extractors stuck on one ambiguity produce one ranked question rather than ten
> held tasks, and the answer changes what every future extractor sees rather
> than unblocking the one that asked. Engine-tier and unbuilt.
>
> The same proposal offers a different route to what §5.7 achieves by
> declaration. One specialist per (source, doctype) assigns roles explicitly and
> enforces the assignment with a unique index, which is right when the
> partition is known. **Heterogeneous activation thresholds over one shared
> signal partition the work without anybody assigning it** — the
> response-threshold model — and re-tuning the division of labour is an
> `UPDATE`. The two are complements rather than rivals: declared where the
> doctype is known, emergent where it is not.

### 5.4 Skills, and agents as plugins — [`plugins.md`](plugins.md)

§5.2 settles what an agent can *do*. The other half is what it knows *how* to
do, which is prose rather than a service, and it had nowhere to live: an
instruction every agent bound to the query server needs ("always start with
`SCHEMA`") could only be copied into each one's `system_prompt`, which is
exactly the duplication `tool_servers` exists to prevent for urls, applied to
text.

So: **`agentic.skills`** — one row per markdown procedure, a `description` a
model reads to decide whether it needs this and a `content` body it reads once
it has, transcribing the [Agent Skills](https://agentskills.io) split rather
than inventing one. Two columns, because that split *is* the mechanism:
offering a thousand skills costs a thousand description lines and the bodies
cost nothing until one is named.

Two ways in, and they are different mechanisms rather than two settings of one.
`agents.skills` names the skills concatenated into the system instructions at
invocation — the row holds keys, never text, so one edit reaches every agent
that pins it. A `tool_servers` row with `serves_skills` is the **skill
gateway**: one tool per skill, so the model can load one itself. That second
tier is what keeps §5.2's zero-built-in-tools rule intact — a `load_skill`
built into the runtime would have been the first built-in tool — and it is the
same resolution §5.1 item 3 reached for delegation, reused rather than
reinvented.

And **`agentic.plugins`**, which names something that already existed:
[`reference/percolate.yaml`](reference/percolate.yaml) has been a plugin
manifest since it was written — two servers and an agent in one document,
applied as an upsert. What it lacked was a name to remove it by. A plugin here
is provenance on the three config tables plus `apply_plugin`, which prunes what
a re-applied manifest no longer declares and refuses to remove anything another
agent still pins, binds, or has runs against.

[`plugins.md`](plugins.md) is the whole of it, including the requirement §5.1's
persistence adapter acquires from it: a loaded skill is standing instructions,
so it is reattached at the head of the reloaded window and never summarized
away — otherwise an agent follows a procedure for six turns and then silently
stops, with a transcript showing it was told.

## 5.7 Extractor agents — the population this table is actually sized for

The agents in §5 are the ones a person talks to. **They will be a rounding error
in this table.**

`world-model-ingestion/extraction.md` establishes that turning prose into
datapoints and motifs is a cost-ordered cascade, and that its last tier is not
"a model reads the document" but **a specialist extractor per `(source, document
type)` pair, with a declared output schema.** The unit was measured: a template
scoped to one source scores 44% slot fill over a mixture of document types and
66% over the right one, and the Gazette alone publishes eighteen categories.

So the extractor population is `sources × doctypes`, and the design consequence
is immediate: **`agentic.agents` is expected to hold thousands of rows, of which
a handful are user-facing.** That is the same shape as `content.connectors`
holding hundreds of sources — an extractor is a row, not code, and adding one is
an `INSERT`.

### Why a specialist beats one general extractor

- Its system instructions carry **that source's gotchas** — the ones `sources.md`
  §14 already collects as data. The knowledge that a Gazette petition names its
  petitioner *after* the presentation date belongs with the extractor, not in
  somebody's head.
- **Its `structured_output_schema` is the motif slot list**, so a tier-3
  extraction lands in the same staging table, in the same closed vocabulary, as
  tiers 0–2. Nothing downstream knows which tier produced a row except by
  reading a column.
- Yield is measurable per agent, exactly as a template's fill rate is, so a
  specialist that degrades when a source changes format is **detectable rather
  than merely disappointing**.

### The output schema is not optional here

`schema.sql` enforces it: `category = 'extractor'` requires
`structured_output_schema is not null`. An extractor without a declared shape is
a model call with extra steps — the shape is what makes N extractions
combinable, and what makes a bad answer **retryable** rather than silently
wrong.

Verified against the live instance: an extractor row with no schema is rejected
at `INSERT`.

### Classification, because a thousand rows need a filter

Three columns, and the split between them is deliberate:

| column | closed? | role |
|---|---|---|
| `audience` | `user` / `internal` / `system` | **which agents a human is offered** — not an access control |
| `category` | 8 values | what the agent is *for* |
| `tags` | free text | search only, never load-bearing |

`audience` is not derived from tags on purpose: whether a human is offered an
agent is worth deciding explicitly, and inferring it from free text would make it
a decision a typo can change. `agentic.agents_pickable` selects
`audience = 'user'`, so an interactive UI shows a thousand extractors to nobody
without anyone having to remember to filter — verified with one extractor and one
assistant registered, the view returns the assistant only.

**It is a filter, not a boundary, and this table used to say otherwise.**
`audience` said "an access decision" here, and it is not one: marking an agent
`internal` hides it from a picker, not from a caller who asks for it by name.
Access is decided by the agent's scope columns (`owner_id`/`org_id`/`visibility`,
schema.sql §7); a `public` agent's full `system_prompt` is readable by every
authenticated caller whatever its audience.

`agents_pickable` also had no grant until this was written down, so the only
role that could read "the view an interactive UI reads" was its owner — the
verification above was run in a privilege context no UI has.

`category` is closed for the same reason the motif vocabulary is: an open list
becomes a synonym pile within a month, and filtering was the whole point.

A partial unique index on `(extracts_source, extracts_doctype) where category =
'extractor'` means **two specialists cannot silently claim one source** — a
second registration is a conflict to resolve, not a runtime coin-flip.

`agentic.v_extractors` is the operations surface, mirroring
`content.v_connectors`: what exists, what it covers, whether it is contracted,
and how many slots it promises.

### Enforcement

The workflow compiler emits a step's `output_schema`, and
`workflow.compiler_capabilities()` reports it under `accepts.output_schema`, so
an extractor contract here is enforced at task completion — except inside a
`matrix` template, which refuses the key.

## 6. Migrations for agents — authored in code, deployed as data

An agent can be authored as a real, type-checked model in Python — full IDE
support, unit-testable in isolation, whatever the author's normal development
loop already looks like. Because §5's only constraint on that definition is
"no inline tool code, only OpenAPI/MCP references," the authored agent is fully
serializable the moment it's finished — there is nothing imperative or opaque
left in it once tools are bound that way.

**And there is no export step, because the authored form and the deployed form
are the same document.** An agent is a **JSON Schema document** — the shape
`model_json_schema()` emits, flat, with agent config sitting beside the schema
fields exactly where `json_schema_extra` puts it. The convention comes from an
earlier Percolate agent runtime and is kept deliberately; it is worth stating
what it rules out: **there is no `prompt` key.** The agent's own system instructions
are the schema's `description` — which is to say the *docstring of the model class* — and the
structured output is its `properties`. So:

```python
class Support(BaseModel):
    """You triage incident questions for the support desk."""
    model_config = ConfigDict(json_schema_extra={
        "name": "support",
        "model": "openai:gpt-4.1-mini",
        "tools": [{"server": "p8-rag", "tools": ["post_rpc_search_chunks"]}],
    })
    claim: str
```

`Support.model_json_schema()` is the content of `support.yaml`. "Authored in
code, deployed as data" stops being a pipeline and becomes an identity: the
build step is `model_json_schema()`, which pydantic already wrote. It is a
format like any other, but one that carries more meaning — every tool that
reads JSON Schema reads an agent, and the description a human writes is the
description a model receives.

One divergence from that earlier runtime, named rather than silently inherited: it distinguishes
`structured_output: true` (properties are the output contract) from `false`
(properties are "thinking aides" that shape the model's reasoning without being
returned). This spec gives `properties` one meaning — the output contract, which
is what makes `chained_action` reachable (§2). Thinking aides are a real idea and
are simply not in this system.

Applying it is a **migration, not a deploy**: a versioned spec file, going
through the same git flow as everything else in this collection
(a spec change, a reviewed PR, a merge, with staging checks catching what review
misses), that upserts one row into `agents`.
The runtime (§5) never needs redeploying to add, change, or retire an agent —
only a data migration, the exact same *shape* of change as a schema migration,
reviewed and rolled out the same way.

### 6.1 Which component turns the document into the row

The document and the row are two spellings of one agent, so something has to map
`description` onto `system_prompt` and `properties` onto
`structured_output_schema`. **That something is `agentic.agent_document_to_row`,
in the extension, called by `agentic.upsert_agent` as its first statement. No
loader, client or CLI translates.** Both documented forms therefore install the
same row through every write path there is — PostgREST, `apply_plugin`,
`percolate.apply_package`, `percolate package apply`, `percolate sample load`,
`percolate agent push`, psql — and "the authored form and the deployed form are
the same document" is a property of the system rather than of each tool
separately.

**A key `agents` does not read is refused, never dropped** (SQLSTATE is an
ordinary `raise`, not 42501 — a malformed document is not a forbidden one). This
is the half that keeps the rule true. It is stated as a requirement because the
alternative shipped: until the translation moved into the database it lived in
each loader, the package loader knew only a package's file-path `output_schema` and
percolate-core's `core/samples.py` and `percolate agent push` knew only
`description`/`properties`, and `upsert_agent` accepted any document and ignored
the keys it did not recognise. So a package manifest written the way this section
writes an agent installed, reported success, and left an agent with an empty
system prompt and no output contract — one that exists, resolves by name and can
do nothing. A loader that forgets to translate now fails in its own test run
instead of installing that agent in production.

Two consequences worth naming, because each is a thing somebody will reasonably
try:

- **Resolving a file reference is not translating.** A package manifest's
  `output_schema: schemas/motif.json` names a file in the package directory,
  which the database cannot see — the same situation as a skill's body. The
  loader reads it and sends the schema; that is the only part of an agent
  document any loader touches, and `output_schema` reaching the database is a
  loader that forgot to resolve it, which is refused with that sentence.
- **A client may still parse a document for its own use.** percolate-core's
  `agentic/authoring.from_json_schema` turns a document into a typed `AgentSpec`
  in process, with no database, which is what makes `from_model_class` and the
  in-memory repository work. What it may not do is produce the *row*: anything
  destined for `agents` goes to the database as the document.

A client cannot tell a database that translates from one that drops, which is why
`agent_document_to_row` is reachable (`authenticated`) rather than private to
`upsert_agent`: a loader asks for it once and refuses to install against an
extension older than 0.2.0, instead of writing the empty agent that version
would accept.

## 7. Core schema shape

**`schema.sql` in this directory is now the territory** — the DDL exists,
loads into the PG19 stack alongside `rbac` and `workflow`, and is what the
runtime is built against. This section stays as the map.

`agents` (config row — plus `summarizer_agent_id`, §3, a nullable
self-reference naming which `agents` row summarizes this agent's windowed-out
history, and `skills`, §5.4, a list of `skills` names pinned into its prompt)
→ `sessions` (a conversation, optional for scheduled runs) →
`runs` (one agent invocation; self-referencing `parent_run_id` for delegation;
`trigger_kind` + `workflow_task_id` per §3 for background/batch runs) → `messages`
(turn content, `tool_calls` JSONB for the fast path, individual `tool_call`/
`tool_response` rows for the slow path, or a `role = 'summary'` row per §3's
windowing policy — all point at a `run_id`). `tool_response` rows additionally
carry `is_error boolean` and `error_kind text` (§5.2); assistant `messages`
additionally carry `citations jsonb` (§5.3).

Two columns this brief's earlier draft did not have, both added because
building the runtime made their absence concrete rather than theoretical:
`runs.owner_id` (§3 — scheduled runs have no session to scope RLS through) and
`tool_servers.emits_citations` (§5.2 — §5.3's derivation needs to know which
responses are retrieval results, and a tool-name convention is not an answer).

**`agents.model` has one grammar: `provider:model_id`**, split at the first
colon, which is the string pydantic-ai parses (`openai:gpt-4.1-mini`,
`moonshotai:kimi-k2.6`, `ollama:llama3:8b`). A bare id is accepted on write and
means `openai`. The column is stored canonical — a trigger rewrites
`gpt-4.1-mini` to `openai:gpt-4.1-mini` on insert or update, and a CHECK
(`agents_model_is_canonical`) holds it there — so the runtime passes it to
pydantic-ai unchanged. A builder that sends a request itself asks
`agentic.parse_model(model)` for `(provider, model_id)` and sends `model_id`:
`agentic.agent_call` does, and so does anything that builds a chat-completions
body from a row. Before this was written down there were two grammars, and a
row worked on the runtime or on `agent_call` but not both.

Two tables the map above does not name because they carry no conversation
state: `skills` and `plugins` (§5.4, [`plugins.md`](plugins.md)), sitting
beside `agents` and `tool_servers` as the third and fourth kinds of shared
configuration — prose an agent follows, and the bundle all four arrive in.

**`agentic.agent_versions` holds each earlier version of an `agents` row**.
An agent is a row, so changing its prompt is an `UPDATE`, and the runtime reads
the row on every turn: the next turn uses the new prompt with no redeploy. What
the `UPDATE` replaced is kept, whole, with when it held and who replaced it, and
is readable through `agent_versions_api` by whoever can read the agent.

**`runs` also carries `trace_id`/`span_id`/`parent_span_id`**, per
the collection's rule that every service propagates OpenTelemetry trace context
— and this system gets that almost for free,
because `parent_run_id`'s delegation tree *is already structurally a span tree*:
`span_id` is this run's own W3C span id, `parent_span_id` is simply the parent
run's `span_id` (not a separate concept to maintain), and `trace_id` is shared
across an entire delegation tree — one trace per top-level session or scheduled
trigger, propagated to every delegated sub-run the same way
`workflow-engine`'s `start_workflow(..., p_trace_id)` propagates one across a
run's tasks. A `workflow_task_id`-triggered scheduled run (§3) should inherit
the *task's* `trace_id`, not start a disconnected one — the same "continue, don't
restart, the trace whenever an upstream one exists" rule as everywhere else in
this collection.

## 8. What's pushed to Postgres vs. what isn't

Pushed: session/run/message CRUD, RLS-based access control, delegation tree
structure, chained-action dispatch (a `SECURITY DEFINER` function call, if the
`chained_action` targets one). Not pushed, structurally: the LLM API call itself
and every call to a bound OpenAPI/MCP tool microservice — both made by the agent
runtime (§5), the one process in this system holding LLM credentials and
outbound HTTP access — and the SSE/WebSocket fan-out (FastAPI, relaying Postgres
`NOTIFY`). The contract stays implementation-agnostic in principle — nothing
stops a different runtime existing later — but this spec commits to §5/§6's
shape as the one actually built.

## 9. Open questions for the full spec

- ~~Exact `chained_action` reference shape~~ — **closed**: both kinds exist,
  distinguished by `kind`, and the contract is now concrete. A `pg_function`
  target has the signature **`(jsonb) -> jsonb`** — the result is persisted as
  an ordinary `tool_response` row, so it has to be JSON (a function returning a
  composite type cannot even be decoded by the client). The payload is the
  structured output *plus the run context that produced it* —
  `{"run_id", "session_id", "agent", "output": {...}}` — because an action that
  receives only the model's output cannot write anything scoped to the
  conversation it came from, which is exactly what both the summarizer and §3's
  consolidation run need. `agentic.apply_summary` in `schema.sql` is the
  reference implementation.
- Whether `runs.state` needs a size cap / TTL-eviction policy given it's meant to
  hold enough for a resumed run without server affinity.
- How deep a delegation tree is allowed to go before it's treated as a bug rather
  than a feature — needs a hard limit, decided alongside `workflow-engine`'s own
  cascading-cancellation limits since the failure mode rhymes.
- **What a second consumer does to `tool_servers`.** Everything above is
  validated by one runtime with one gateway. The rule "promote shared logic on
  the *second* independent consumer" applies squarely here: the moment something other than this runtime resolves a
  toolset from these rows, the resolution logic (allowlists, name-collision
  prefixing, cache staleness) becomes a shared concern and should move, not be
  copied.
- Consolidation cadence and idempotency — how often a scheduled run fires per
  tenant/domain, and how it avoids re-deriving the same `insight` entity twice when
  re-run over overlapping data (a dedup/watermark column on the query it issues to
  `ai-query-layer`, most likely — needs the full spec, not this brief).
- **Now closed at the column level too**: `tool_servers` is
  `url`/`kind`/`credential_ref`/`cached_tools`/`synced_at` plus
  `emits_citations` (§5.2). Still genuinely open, and only this: how a binding
  handles the upstream spec changing out from under it beyond "a scheduled
  re-sync task" — does a breaking change to a cached tool's schema fail loudly
  at resolution time, or silently use a stale cache? Leaning loud (compare on
  re-sync, refuse to resolve a drifted tool), unproven.
- **Resolved at the policy level, still open at the parameter level**: §3's
  `summarize_session_window` settles windowing-plus-rolling-summary as the
  default context-reload policy, `agents.summarizer_agent_id` settles that the
  summarizer is data, not code, and §5.1 now settles that a window is
  **branch-scoped**, not session-scoped (running a delegated turn answered that
  one immediately). Still open: the actual threshold (message count vs. token
  estimate, and what number), and whether the crossing-check lives in a
  `messages` trigger or the persistence adapter's own code.
- ~~Exact **header contract** for instruction/context injection~~ — **closed**
  in §5.1 item 4: one `X-P8-*` prefix, unknown headers forwarded into typed
  `deps`, documented defaults for absent ones, `traceparent` kept standard.
  Closed because delegation needed it (§5.1 item 3) — the sub-run's session,
  parent run and trace propagate through exactly this mechanism, so leaving it
  undefined would have meant inventing a second one for delegation alone.
- How the agent runtime gets **credentials** for the microservices it binds to
  (an API key an OpenAPI service expects, an MCP server's own auth). This is
  exactly where the delegated-credential/secrets-vault gap the collection
  leaves out of scope would bite first — worth resolving alongside that, not inventing a second,
  narrower credential mechanism just for this runtime.
- The migration file format/tooling itself (§6) — plain versioned YAML files
  applied by a small script, or something more structured. Checked: no
  subsystem in this collection has a documented schema/data migration
  convention yet (`workflow-engine` doesn't either) — this is a real,
  repo-wide gap, not something to invent a narrow answer for just here. Worth
  resolving once, repo-wide, the first time any subsystem actually
  needs to ship a migration, rather than each subsystem inventing its own.
- Whether the runtime is one persistent service handling both interactive
  (streaming) and background (§3 scheduled) runs, or split into a persistent
  gateway plus a separate KEDA-scaled pool for background runs — leaning
  toward the split, since a live AG-UI session needs a held connection in a
  way a scheduled consolidation run doesn't, but not decided here. Note this
  is now a *third* surface question, not a second: the agent gateway (§5.1
  item 3) is MCP, the chat surface is AG-UI/SSE, and both are the same
  deployed runtime today.
- **Whether a sub-agent should ever see anything of its caller's conversation.**
  §5.1's branch-scoped window says no, and that is right as a default — the
  parent decides what to pass in the delegation prompt. But a "continue this
  conversation with more capability" delegation genuinely wants the opposite,
  and expressing that today means the parent copying history into the prompt.
  Possibly an `agents` column (`inherits_context`), possibly out of scope; not
  guessed at here.
- **How a chained action reaches a scheduled run's `complete_task`.** §3 says
  the runtime calls `complete_task(task_id, output)` once the run *and any
  chained action* finish. With the chained action firing after the assistant
  row is written, an action that fails leaves a succeeded run and an
  uncompleted task — the failure has no home. Probably a terminal run status
  (`action_failed`), probably reusing `workflow-engine`'s retry rather than
  inventing one; unresolved.
- What a delegated call costs in latency now that it is a real MCP round-trip
  into the same process rather than an in-process call. The design is right —
  it is what keeps "zero built-in tools" true — but "the runtime calls itself
  over HTTP" deserves a measurement before a delegation-heavy agent is built on
  it, and possibly a documented loopback shortcut that preserves the semantics
  (same discovery, same allowlist, same rows) while skipping the socket.
- Whether `messages.citations` should also record *which run* produced the
  tool response it derives from. Today a citation is `{kind, ...}` only; in a
  delegation tree the retrieval that informed an answer frequently happened in
  a sub-run, and "which agent actually fetched this" is a question a client
  will eventually ask.

## 10. Packaging, deployment, and the implementation

The sections above describe a runtime. This one says how it is shipped, because
the answer changes two things about its design and settles one of §9's open
questions into a narrower one.

### 10.1 A subpackage of `percolate-core`, in its own repository

The agent runtime is not a distribution of its own. It is one subpackage of
**`percolate-core`** (mirrored read-only in this repository's `core/`), the single
Python distribution that carries every service in this collection:

| Subpackage | What it is | Spec |
|---|---|---|
| `core` | connecting to Postgres *as the caller*, and configuration | this §10.2, `user-rbac` |
| `worker` | the task loop, with `http_call` built in | `workflow-engine` §14 |
| `content` | the Content Server | `world-model-ingestion` §3.5 |
| `agentic` | this runtime | this document |

**The spec is the artifact, and an implementation is answerable to it.** The dev
harness loads `specs/*/schema.sql` directly — never a copy — so a schema that
only works because a harness did something extra fails in the harness.

**Extras, not distributions.** The base install is `asyncpg`, `httpx`, `typer`
and nothing else; `content` and `agent` extras add what those services need.
Someone writing their own worker should not pull boto3 and pydantic-ai to do it,
and "should not" has to mean the dependency resolver, not a README. `all` is the
image's install.

**One console script, `percolate`, grouped by subpackage.** Each subpackage
declares its own group and the parent mounts it (`core/percolate_core/cli.py`):
`percolate agent push harbourmaster.yaml`, `percolate agent list`, `percolate
agent tools register`, `percolate agent chat`, and the long-running services
`percolate agent serve`, `percolate agent gateway`, `percolate content serve`,
`percolate worker`, `percolate pool run`. Hand-forwarding a subset was tried instead
and is exactly as durable as it sounds: the forwarded `serve` imported an
application object that did not exist, and the whole operator surface behind it
was unreachable from the installed script.

**Mountable, not merely runnable** (the collection-wide module-composition
convention this settled). The HTTP surface is a `router()`, the
connection pool is a `lifespan()`, and the CLI is the groups and commands above;
running this subsystem alone is a thin *caller* of those three, never a second
implementation. A host process includes the router under a prefix it chooses,
composes the lifespan into its own, and mounts the groups it is given; the
agent gateway mounts as a sub-application the same way. Two details make the
difference between mountable and mountable-in-name: anything this module puts on
shared state is namespaced (`state.percolate_agent_client`, not `state.client` —
in a mounted deployment that state belongs to the host), and nothing is owned at
import time, because a pool opened on import gives the host no seam to compose.
Both are verified rather than asserted: a host app that mounts this runtime is
driven in-process by the same suite that tests it standalone, and must produce
the same identity rule, the same stream and the same rows under a different
prefix.

**One image, several entrypoints.** One `Dockerfile`, installing `[all]`, with
`ENTRYPOINT ["percolate"]` — so the deployed artifact is identical and the *command*
selects the service:

| Command | Surface | Wanted where |
|---|---|---|
| `percolate agent serve` | `POST /chat` and `POST /v1/chat/completions` (SSE) + `GET /sessions/{id}/events`, `POST /internal/run`, and MCP at `/mcp`: this runtime's agents as tools | wherever live conversations are held, and wherever `P8_AGENT_URL` points |
| `percolate agent gateway` | the same MCP surface and `/internal/run`, without the chat routes | a deployment that puts delegation on replicas of its own |
| `percolate content serve` | uploads, scraping, ingestion | wherever content arrives |
| `percolate worker --queue …` | the task loop | wherever tasks are executed |
| `percolate agent push` / `percolate agent tools register` | operator and migration surface | CI, and a maintenance shell |

A Kubernetes `command` replaces the ENTRYPOINT rather than extending it, so a
pool row's `command` is the whole command line (default `array['worker']`,
`specs/workflow-engine/pools.sql`).

**`/internal/run` and MCP are answered by both commands, from one
implementation.** No shipped deployment runs the gateway: get-percolate's
compose file and chart run `agent serve` alone. While only the gateway served
these routes, a scheduled run's dispatch to `{{env.P8_AGENT_URL}}/internal/run`
answered 404, and so did a delegation server registered at
`http://agent:8080/mcp`. `agent serve` now answers `/internal/run` through
`gateway.accept_run`, the gateway's own handler, and MCP at
`/mcp` through the MCP SDK's `streamable_http_app()` route.
`agent gateway` is unchanged.

`P8_AGENT_URL` names `agent serve` in every deployment, and the scheduled step
cannot name a gateway instead. The worker mints the run owner's token only for
`P8_AGENT_URL`'s origin, and treats `/v1/chat/completions` and `/internal/run`
as endpoints of one service (`core/percolate_core/worker/agent_auth.py`). A
gateway on another origin serves delegation, not the scheduled step.

Before `/internal/run` answers 202 it refuses a body that names no task or no
agent (400), a caller without a verified token (401), a task that caller cannot
see through `workflow.tasks_api` (404), and a process that cannot complete tasks
(503, rather than a 202 that waits out the step's `wait_ms`).

**The runtime completes and fails a scheduled run's task on `P8_WORKER_DSN`,**
a login that is a member of `worker`, the only role `complete_task` and
`fail_task` are granted to (`workflow-engine/schema.sql`). It does not
`set role worker` from `P8_DSN`: that login is `authenticator`, which
`user-rbac/roles.sql` §3 makes `noinherit` so that it holds only the switch
into `web_anon` and `authenticated`, and Postgres refuses the switch. Granting
`worker` to `authenticator` was rejected, because every PostgREST request
arrives on that login. With the variable unset the runtime tries the switch on
its own login, and the refusal names the variable.

That reshapes §9's "one persistent service, or a persistent gateway plus a
KEDA-scaled pool for background runs" — it is no longer a question about *what
to build*, because the artifact is the same either way. It is a deployment
question: which command each replica set runs, answerable per environment
without a second build. A live AG-UI session needs a held connection; a
consolidation run does not; both are the same image.

Note that the extras split therefore buys nothing *at deploy time* — the image
takes everything. It is for the other consumer: someone `pip install`ing this to
write a worker, or to import the contracts.

### 10.2 One implementation of "whose RLS applies"

`core` exists because the connection-with-identity seam had been written three
times, on two drivers, and three implementations of one security boundary is two
too many. Every service now goes through `as_caller(claims, role=…)` /
`as_service()`, this runtime included: its `PgClient` is a thin adapter over
them, not a second implementation.

The requirement that extraction surfaced, stated because it is invisible until
it is wrong: **the helper sets the role, it does not inherit one.** Claims alone
decide nothing if the connection's login role bypasses RLS before any policy is
consulted — which is precisely the bypass the collection's RLS ground rule forbids,
and which would make this seam's safety a property of somebody's connection
string.

**One pool per process, and therefore one DSN per process.** Services that share
an image share a database; a second DSN in one process would mean two
identities' worth of RLS in one pool. But one pool with several mounted owners
needs ownership to be explicit: holds are reference-counted, a service's
lifespan *owns* the pool, and every short-lived helper *borrows* it. Both halves
were learned the hard way — a mounted host's shutdown closed the pool the outer
client was still using, and a per-call helper tore the pool out from under a turn
that was still streaming.

### 10.3 A library boundary is not a second write path

Being importable is the part that needs a rule, not just a note. Another service
in the distribution — the Content Server, a worker, a migration script — *can*
import this subpackage and write `runs`/`messages` rows. It must do so through
the same seam every other client uses: the `SECURITY DEFINER` functions and
`*_api` views, under the caller's own identity, with RLS applied.

So the package exposes its contracts and its repository, and deliberately
exposes **no privileged mode** — no owner-role connection helper, no "internal"
write path, no bypass for callers that "already know" who they are. This is not
merely convention: `schema.sql`'s load-time invariant check fails if a
base-table write grant is ever added for a PostgREST-facing role, so an
importing service that tried to reach around the functions would find nothing to
reach for.

The distinction to hold onto: **the library boundary and the service boundary
are different, and only the service boundary is a trust boundary.** Importing
this package buys you the contracts and the correct SQL; it never buys you
authority you did not already have.

### 10.4 The package and the schema version together

A distribution and a `schema.sql` deployed separately can drift, and the failure
is ugly: a runtime that expects a column the database does not have fails on
first query, in production, per request. The requirement is that the package
**declares the minimum schema it needs and checks it at startup**, failing to
boot rather than failing per request.

The mechanism is no longer open, and the answer is **not** the one this
paragraph used to name. It said "a version marker the runtime can read"; what
is built reads no version at all.

**The probe asks what it needs, not what version is installed.** The runtime
runs the thing it is about to depend on and sees whether it works —
`core.identity.verify_can_open_a_session()` runs the two statements
`as_caller` runs, in its order, and throws the transaction away. Three reasons,
and the first is why the version marker was the wrong answer rather than a
slower one:

1. **`pg_extension.extversion` has been known to lag what is installed** on a
   database upgraded in place, so the marker can say a capability is absent
   while it is there, and the reverse. `percolate_core/core/agent_document.py`
   settled this for the same reason and is the precedent this follows.
2. **A version comparison needs a table of which pairs work**, maintained by
   hand, and that is a second home for a fact the database already enforces in
   its own preflight. One of the two would go stale, and nothing would say
   which.
3. A capability probe answers **the question actually being asked** — would a
   turn get a session — where a version answers a question that correlates
   with it.

**Partly built.** One probe exists, for the capability whose absence stops
everything: opening a session as the caller role at all. Whether the runtime
needs others — a function, a column, a grant — is not enumerated, and
nothing yet demands enumerating them: the failure that motivated this
was the session-open one, and a list written before it is needed is a list
written from imagination. Each further probe is a line beside the first when
something needs it.

**And it cannot help a runtime already published without it.** A check that
ships in version N does not run in version N−1, so the pairing that produced
this — a pre-0.1.9 runtime against a 0.2.0 database — is not caught by it and
never will be. That case is a known-bad pairing in the release notes
(`core/CHANGELOG.md`), which is the only instrument that reaches backwards. The probe makes the next such
pairing loud at startup instead of silent behind an HTTP 200.

### 10.5 What the implementation proved, and what it still owes

`percolate-core`'s `agentic` subpackage — grown from an experimental runtime —
is the implementation of this spec: several thousand lines of Python against a real Postgres 19, a real PostgREST, a real MCP gateway and a
real model. It is not the deliverable — this spec is — but it is the reason
several sections above changed.

Proved end to end, and worth keeping as the acceptance list:

- a turn's rows land through RLS as an ordinary `authenticated` caller
- the persistence rule of §2 holds exactly: user/assistant rows always,
  `tool_call`/`tool_response` rows only for delegations, retrieval results not
  at all, provenance instead
- a three-level delegation tree, its span tree, and its back-references agree
- the AG-UI stream and the rows describe the same turn, down to message ids
- a second client relays a conversation it did not start, sub-runs included
- a client resumes with `X-P8-Session-Id` alone and is remembered; the
  conversation is recoverable from rows by a process that was not there
- a scheduled run summarizes a session and completes its own workflow task
- another tenant sees none of it
- the whole surface behaves identically mounted inside a host app

Still owed at the time of writing: the rest of §10.4's startup probe — its
first capability is built and no further one is enumerated; consolidation
into `ai-query-layer`'s node/edge tables; and credential resolution beyond an
environment variable.

**One cross-spec note.** `workflow-engine/spec.md` §14 says the generic
`http_call` executor is that module's to build and explicitly not each
consumer's. It now exists, as `percolate-core`'s `worker` subpackage — so that
section's open item is closed, by a package this spec does not own. Worth
recording in both places rather than leaving each to assume the other did it.

## 11. Requirements an implementation must satisfy

Sections 1–10 describe what to build. This one is what a reviewer checks, and it
exists because a first implementation of §§1–10 passed every behavioural test in
its acceptance sequence while getting all of the following wrong. None of these was
discoverable by reading the spec, which is the argument for writing them down:
each is an invariant a plausible implementation violates by omission, and each
was found by auditing a running one.

Framed as requirements on *any* implementation, not as a changelog of one.

### 11.1 Identity

- **A signature is not a token.** Verifying the HMAC and reading `sub` is not
  verification: `exp` and `nbf` must be checked, and the algorithm pinned by the
  verifier rather than read from the token's own header. *Failure it prevents:*
  the runtime accepted a token 24 hours past expiry that the PostgREST beside it
  rejected — a subsystem that is strictly weaker than the one it claims parity
  with, which is worse than one that is obviously unprotected.
- **Identity comes only from the verified token.** No header, body field or tool
  argument may name the acting user. `X-P8-*` carries *context*, never authority.
- **The same verifier serves every surface.** The chat endpoint, the agent
  gateway and the scheduled-run trigger authenticate identically; a second
  implementation for the "internal" one is how an internal endpoint becomes a
  bypass.
- **Invoking an agent is a permission, and it is checked in `start_run()`.**
  `agents:invoke` (`agentic.may_invoke`), which is both halves: the agent must
  be visible to the caller under its own scope columns, *and* the caller's roles
  must grant the pair. Reading an agent row and running one are different
  authorities, and for a while only the first had a pair — so any authenticated
  account could spend model budget, reach tools and delegate.
  *Why in the function rather than on `POST /chat`:* an interactive turn, a
  delegated sub-agent through the gateway, a scheduled run and a
  workflow-triggered run all begin by calling `agentic.start_run()`. A check on
  the HTTP route gates one of the four, and delegation is the one that matters —
  a chain begun by somebody permitted must not become a way to invoke an agent
  they are not.

### 11.2 The boundary around tool calls

- **A tool argument may never set a reserved header.** `Authorization`,
  `Cookie`, `Proxy-Authorization` and the whole `X-P8-*` space belong to the
  runtime. *Failure it prevents:* an OpenAPI document may legally declare a
  header *parameter*, which becomes an ordinary input-schema property — so
  without this rule the model can overwrite the credential the `tool_servers`
  row resolved. Confirmed against a live service: a model-supplied
  `Authorization` displaced the runtime's own. Reserved parameters must be
  dropped at binding time, and refused again at call time.
- **Every tool failure is an observation, never an exception.** §5.2 already
  says this about the two error kinds; it must hold for *every* path that can
  fail, including credential resolution, argument marshalling and URL
  construction. *Failure it prevents:* an unresolvable `credential_ref` — the
  single most likely failure in a fresh deployment — raised through the agent
  library's retry logic and killed the whole run instead of becoming a
  `dispatch_error` the agent could react to.
- **Delegation is identified by data, not by naming.** Which tools *are* agents
  must be a column on the tool-server row. *Failure it prevents:* detecting
  delegation by an `agent__` prefix let any registered MCP server claim the
  namespace — and it decides persistence granularity and who receives a
  delegated-by header — while a server merely *named* `agent` fell into it by
  accident through collision-prefixing.

- **Every tool call executes as the caller, never as the runtime.** The
  transaction a tool runs in must carry the caller's claims and the
  `authenticated` role — one implementation of "whose RLS applies", borrowed,
  not re-stated. The runtime's own identity (`as_service`) is for its own
  bookkeeping and for nothing a prompt can reach.
  *Failure it prevents:* the textbook confused deputy. A runtime holding a
  privileged credential turns prompt injection into privilege escalation, and
  nothing about the tables looks wrong afterwards.
  *And the part a reviewer has to carry:* **the database cannot check this.**
  Postgres sees a connection that set a role and some claims; it cannot tell
  whether they were the right ones. Every other guarantee in this collection is
  enforced by the substrate — this one is a convention, so the question to ask
  of any new tool is whether it borrows the caller's identity. Measured on a
  live stack: two users over the same corpus, one sees six resources and the
  other five, and neither sees the other's `private` rows — through the agent as
  much as through PostgREST, because it is the same predicate either way.
- **An agent is exactly as privileged as its caller — never more, and never
  less.** There is no step-down role. A deployment wanting chat available to
  someone on *narrower* data than they already have cannot express it this way,
  and should not try: it would need a distinct role the runtime assumes, which
  is a different design and reintroduces the deputy this rule removes.

### 11.3 Structural limits belong in the database

- **The delegation-depth ceiling is enforced in the database**, not only in the
  runtime. *Failure it prevents:* the run-creation RPC is granted to every
  authenticated caller, so an app-side limit protects only callers who go
  through the app. A runtime may set a lower policy limit; the schema must carry
  a hard one.
- **One live interactive turn per session.** Two concurrent turns both reload
  the same window and both append to it, so the history each one saw is not the
  history that ends up stored — silent corruption, not an error. The check
  belongs in the same function that creates the run, must exempt delegated runs
  (they happen *inside* a turn), and must be bounded by age so a runtime that
  dies mid-turn does not wedge the conversation forever.
- **Every state-mutating name that reaches SQL is validated twice** — shape and
  existence — even when it comes from a configuration table this system owns. A
  config table is not a trust boundary.

### 11.4 The stream

- **Close the stream after draining it, not when the work finishes.** A
  notification is published on the runtime's connection and delivered on the
  listener's; "the turn returned" does not mean "the events arrived". *Failure
  it prevents:* terminating on *work done and queue empty* dropped whatever was
  still in flight — most often `RUN_FINISHED`, because it is emitted last.
- **Publishing an event must not cost a transaction.** A per-event identity
  round trip (acquire, `BEGIN`, set role, set claims, notify, `COMMIT`) is four
  statements and a transaction *per token*. Hold one connection for the turn and
  publish autocommit. The opposite mistake is equally wrong: batching events
  into one long transaction delays every one of them to `COMMIT` and destroys
  the streaming it was meant to make cheap.
- **A stream holds a connection outside the pool, so streams must be capped.**
  Unbounded listeners exhaust the database's connection slots under exactly the
  load the system is for. Refuse the 65th stream; do not queue it behind a
  connection that will never arrive.
- **A disconnected client does not cancel the run.** Rows are the record, so the
  turn completes and lands; the implementation must simply not leak the
  abandoned task.

### 11.5 Bounded means bounded at the query

- **The context window bounds the read, not just the send.** Fetching a whole
  branch and slicing it in memory satisfies the model-facing promise of §5.1
  while paying an ever-growing read on every turn. The limit belongs in the
  query, as a superset of the policy bound — tool rows interleave with turns, so
  asking for exactly *N* rows can return a window with no turns in it.

### 11.6 Configuration posture must be stated, not defaulted

- **Every table declares its access posture explicitly**, including the ones
  that are deliberately world-readable: an `ENABLE ROW LEVEL SECURITY` with a
  permissive policy and a comment reads as a decision, while no policy at all
  reads as an oversight — and it is the seam a future scoping change attaches
  to. *Now closed:* `agents` and `tool_servers` carry scope columns, existing
  rows were backfilled `public` and new rows default `private`, and running one
  is a separate `agents:invoke` check (§11.1).

### 11.7 Shared process state has an owner

- **A pool shared by several mounted services is reference-counted, and every
  short-lived helper borrows rather than owns.** *Failure it prevents:* two
  different ones. A mounted host's shutdown closed the pool the outer client was
  still using (`InterfaceError: pool is closed`), and a per-call helper written
  when each caller made its own pool tore the pool out from under a turn that
  was still streaming (`pool is closing`) — both surfacing from code that had
  done nothing wrong.
- **A connection-with-identity helper sets the role; it never inherits one from
  the connection string.** Claims decide nothing if the login role bypasses RLS
  before any policy is consulted. A seam whose safety depends on somebody's DSN
  is not a seam.
- **A subpackage owns its command group and its router; the parent mounts
  them.** *Failure it prevents:* a hand-forwarded subset goes stale silently —
  the forwarded command imported an object that did not exist, and everything
  behind it was unreachable from the installed entry point while still passing
  every test that imported the module directly.

### 11.8 Making the system honest about itself

- **Every long-running surface reports which build it is running.** Three
  separate debugging sessions in this system's history began with a confusing
  failure — a tool "returning an unexpected keyword argument", runs stuck in
  `running` — whose actual cause was a process started before the fix. A stale
  process fails in the shape of a bug; a `/_build` fingerprint turns that into a
  one-line answer, and a test suite should refuse to run against a mismatch.
- **A fix applied to a running system is not a fix.** One correction here was
  made directly in the database and not in the fixture that creates it, so the
  next reload silently reverted it and emptied every citation while every tool
  call still reported success. Whatever provisions an environment must be the
  only thing that provisions it.

### 11.9 Agents load at invocation, never at startup, and so do their skills

- **The agent row is read on every turn, from the database, by name.** Not at
  import, not at deploy, not from a registry compiled into the process, and not
  from a cache warmed at startup. Its prompt, model, tool allowlist, output
  schema and classification are all read at the moment it is invoked. This is
  the requirement that makes every other "agents are rows" claim in this brief
  mean anything: a runtime that loaded agents at startup would turn every
  prompt edit back into a deploy, which is precisely the coupling §2 and §6
  exist to remove.
- **The observable form of the requirement**, and the way to test it: a running
  process must be able to serve an agent that *did not exist when it started*,
  and must reflect an edit to an agent on the very next turn. Both hold in
  [`reference/runtime.py`](reference/runtime.py) — an agent is inserted over
  REST and run by the same process on the following line, then edited and
  observed to change — and neither is a property a reviewer can confirm by
  reading code that merely *looks* stateless.
- **The tool binding resolves at invocation too, but from the cache, not the
  upstream.** The agent's allowlist is resolved against `tool_servers`'
  `cached_tools` on every turn — so re-registering a server changes what the
  next turn is offered — while the *discovery* that fills that cache is a
  separate, scheduled step (§5.2). Those two must not be collapsed: resolving
  from rows on every turn is what keeps agents live, and re-fetching an OpenAPI
  document on every turn would put a network round trip and an upstream
  outage in the path of every message.
- **A bound tool that no longer resolves is reported, not passed through.** A
  name in an agent's allowlist that discovery no longer knows about must be
  dropped from what the model is offered and surfaced, rather than handed over
  to fail at dispatch a round trip later with a worse error.
- **A pinned skill is read on every turn too, and the same two rules apply**
  (§5.4): its body comes from the row at invocation — a skill read at startup
  would turn every prose edit back into a deploy — and a pinned name that
  resolves to nothing is reported rather than skipped, because instructions an
  agent silently never receives are the one failure that produces no error
  anywhere. [`plugins.md`](plugins.md) §7 is the full list, including the one
  requirement that is genuinely new: a loaded skill must not be summarized
  away.

## 12. What a summary is allowed to do to the next turn

**Built.** `core/percolate_core/agentic/runtime/persistence.py`, and
`core/tests/test_summary_authority.py` holds it.

A `role='summary'` row is replayed as a **user** part inside an explicit
`<conversation-summary>` delimiter. It used to be replayed as a
`SystemPromptPart`, and the argument for that was reasonable: a summary stands
in for a window, so it should carry the weight the window carried.

The argument fails on what produces the summary. `agentic.apply_summary` is an
ordinary agent run over the messages about to fall out of the window (§3), so
the summary is *derived text* — and the window it summarises routinely holds
content nobody here wrote: a retrieved chunk, a tool result, a delegated
answer, an uploaded document. Anything an attacker put in one of those was
restated by our own summarizer and then replayed with system authority on every
subsequent turn, **outliving the window that would otherwise have aged it out**.
That is OWASP ASI06, Memory & Context Poisoning, with the poisoning step
performed by us.

So the rule, which is the general form and not a fact about summaries:

> **Authority follows provenance.** Text acquires no authority by being
> processed. A summary of untrusted content is untrusted content; a summary of
> a system prompt is not a system prompt.

Three consequences worth stating, because each is a thing somebody could
reasonably get wrong:

- **A configured `role='system'` message keeps system authority.** It was
  written by whoever configured the agent, not derived from a conversation.
  Demoting it too would be over-correction, and the test asserts it is not
  demoted — the point is that authority tracks where text came from, not that
  nothing may be a system part.
- **The delimiter is load-bearing.** A user part with no marker is
  indistinguishable from something the user actually said, which is a different
  confusion with the same root. `<conversation-summary>` is what lets the model
  treat it as background rather than as an instruction it was just given.
- **The summary's text still reaches the model**, and the test has a control
  for it. Dropping summaries entirely would satisfy the security property by
  breaking the feature, and nothing else in the suite would have noticed.

### What was considered and not done

- **Structured fields instead of prose.** Have the summarizer emit
  `{topics, decisions, open_questions}` rather than a paragraph. Stronger —
  a field is harder to write an instruction into than a sentence — and a bigger
  change: it alters what the summarizer is asked for, and every agent's
  behaviour on long conversations with it. Worth doing if injection through
  summaries is ever observed rather than reasoned about.
- **A quarantined summarizer** — the Dual-LLM pattern, an agent with no tool
  access whose output is data by construction. This is the right end state and
  it needs the runtime to support a tool-less agent role, which it does not
  today. Neither is needed for the property in this section: a summary that
  arrives as delimited user text cannot issue an instruction the model treats
  as authoritative, whoever wrote it.
