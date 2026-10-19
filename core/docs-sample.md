# agentic-runtime — sample usage

One REST call, what streams back, and what the database holds afterwards.

**Everything below is captured output, not illustration.** Every frame, table
and error message was produced by running the commands as written against
Postgres 19, PostgREST, the agent gateway, and `openai:gpt-4.1-mini`. Ids and
wording differ per run; shapes do not.

```bash
. dev/env.sh          # DB url, test user, JWT, and the LLM key
./dev/db.sh up        # PG19 on :5500, loaded from specs/
./dev/stack.sh up     # PostgREST :3001 (CRUD) and :3002 (retrieval), gateway :8765
percolate agent serve                          # the HTTP surface on :8080
```

The same path, asserted rather than narrated:
`uv run --all-extras python dev/verify.py` — 38 checks against a live model.

The agent used here is data, applied with `percolate agent push` — and, like
every agent, it is a JSON Schema document (`description` is the system prompt;
see the authoring section below):

```yaml
# dev/researcher.yaml
type: object
name: researcher
description: |
  You answer questions about incidents.
  Always do this in order: (1) call post_rpc_search_chunks with a keyword to
  retrieve incident text, (2) call agent__analyst asking it to interpret what
  you retrieved, (3) answer the user in two sentences using only what you found.
tools:
  - server: p8-rag
    tools: [post_rpc_search_chunks]
  - server: p8-agents
    tools: [agent__analyst]
properties: {}
context_policy:
  window_messages: 20
  summarize_after_messages: 40
```

## The call

```bash
curl -N -X POST http://127.0.0.1:8080/chat \
  -H "Authorization: Bearer $P8_REST_TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-P8-Tenant: acme" \
  -H "X-P8-Locale: en-GB" \
  -H "X-P8-Case-Id: INC-42" \
  -H "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" \
  -d '{"model":"researcher",
       "messages":[{"role":"user","content":"What caused the outage?"}],
       "stream":true}'
```

`model` names an **agent**, not an LLM. That is what lets an off-the-shelf
OpenAI-shaped client drive this runtime with no bespoke fields.

Response headers:

```
HTTP/1.1 200 OK
content-type: text/event-stream; charset=utf-8
cache-control: no-cache
x-p8-session-id: fcccf751-d9e0-4c78-94b5-e76e39cccd35
```

The session id is in a header as well as in every event, so a client that loses
the stream can reconnect to `GET /sessions/{id}/events` without having to parse
what it just lost.

## What streams back

120 SSE frames. Collapsing the text deltas, in order:

```
researcher  RUN_STARTED                agent=researcher
researcher  MESSAGE_PERSISTED          role=user seq=295
researcher  TOOL_CALL_START            post_rpc_search_chunks id=call_dtYMZvv
researcher  TOOL_CALL_END              id=call_dtYMZvv
researcher  TOOL_CALL_START            agent__analyst id=call_mU1WXJ6
researcher  MESSAGE_PERSISTED          role=tool_call seq=296
analyst     RUN_STARTED                agent=analyst
analyst     MESSAGE_PERSISTED          role=user seq=297
analyst     TEXT_MESSAGE_START
analyst     TEXT_MESSAGE_CONTENT x44
analyst     MESSAGE_PERSISTED          role=assistant seq=298
analyst     TEXT_MESSAGE_END
analyst     RUN_FINISHED               succeeded
researcher  MESSAGE_PERSISTED          role=tool_response seq=299
researcher  TOOL_CALL_END              id=call_mU1WXJ6
researcher  TEXT_MESSAGE_START
researcher  TEXT_MESSAGE_CONTENT x58
researcher  MESSAGE_PERSISTED          role=assistant seq=300
researcher  TEXT_MESSAGE_END
researcher  RUN_FINISHED               succeeded
```

**The delegated agent's whole turn arrives inside the parent's tool call**, and
needs no event types of its own: `agent__analyst` opens a `TOOL_CALL_START`, the
sub-agent's own `RUN_STARTED` / text deltas / `RUN_FINISHED` stream through
tagged with *its* `run_id`, then `TOOL_CALL_END` closes the call. A client
renders it as an in-progress tool call whose contents are the sub-agent's
output, without the protocol knowing delegation exists.

Raw frames — the delegation opening, the child run starting, one delta:

```
event: TOOL_CALL_START
data: {"type": "TOOL_CALL_START", "run_id": "86662ba3-4ce0-4d08-aada-153465dee986",
       "thread_id": "fcccf751-d9e0-4c78-94b5-e76e39cccd35",
       "tool_call_id": "call_mU1WXJ6M2CGae88RRWlx5QXk",
       "tool_name": "agent__analyst", "child_run_id": null}

event: RUN_STARTED
data: {"type": "RUN_STARTED", "run_id": "a6689102-e1fd-4fef-8e7e-21b128aebc6f",
       "thread_id": "fcccf751-d9e0-4c78-94b5-e76e39cccd35", "agent_name": "analyst",
       "parent_run_id": "86662ba3-4ce0-4d08-aada-153465dee986"}

event: TEXT_MESSAGE_CONTENT
data: {"type": "TEXT_MESSAGE_CONTENT", "run_id": "a6689102-e1fd-4fef-8e7e-21b128aebc6f",
       "thread_id": "fcccf751-d9e0-4c78-94b5-e76e39cccd35",
       "message_id": "fe3dcca1-cb22-4f76-9804-a495c988ace5", "delta": "The"}
```

Two event kinds share the stream on purpose:

- **AG-UI events** — what is happening, as it happens.
- **`MESSAGE_PERSISTED`** — a checkpoint from a trigger on `messages`, carrying
  ids only. It is what a client that reconnected, joined late, or missed a delta
  resumes from, and it is how a row written by *any* other client (PostgREST, a
  migration, a chained action) still shows up in the stream.

`message_id` in the deltas **is** the row's primary key — the runtime mints it
before the turn and the insert honours it — so a client can match what it
rendered to what it later reads. (Verified: every `TEXT_MESSAGE_START`
`message_id` across a two-turn conversation resolves to a row in
`agentic.messages`.) Likewise `tool_call_id` in `TOOL_CALL_START`
is the model's own call id, which is what lands in the persisted record.

`child_run_id` is reserved and currently always null: at the moment the parent
opens the call the sub-run does not exist yet. Correlate on the child's
`RUN_STARTED.parent_run_id` instead.

## What the database looks like afterwards

```sql
select m.seq, a.name as agent, r.depth, m.role, left(m.content, 28) as content,
       jsonb_array_length(m.tool_calls) as tool_calls,
       jsonb_array_length(m.citations)  as cites
  from agentic.messages m
  join agentic.runs   r on r.id = m.run_id
  join agentic.agents a on a.id = r.agent_id
 where m.session_id = 'fcccf751-...' order by m.seq;
```

```
 seq |   agent    | depth |     role      |           content            | tool_calls | cites
-----+------------+-------+---------------+------------------------------+------------+-------
 295 | researcher |     0 | user          | What caused the outage?      |          0 |     0
 296 | researcher |     0 | tool_call     | agent__analyst               |          1 |     0
 297 | analyst    |     1 | user          | Analyze the retrieved incide |          0 |     0
 298 | analyst    |     1 | assistant     | The outage was caused by a m |          0 |     0
 299 | researcher |     0 | tool_response | The outage was caused by a m |          0 |     0
 300 | researcher |     0 | assistant     | The outage was caused by a m |          1 |     2
```

Six rows for a turn that made two tool calls and one delegation. What is *not*
there is the point:

| Happened | Stored as |
|---|---|
| user asked a question | a `user` row |
| retrieval (`post_rpc_search_chunks`) | **no row** — one entry in the assistant row's `tool_calls`, and 2 citations |
| delegation to `analyst` | a `tool_call` row, the child's own `user`+`assistant` rows at depth 1, and a `tool_response` row |
| the answer | an `assistant` row |

**Retrieval results are never stored.** They are volatile scratch inside an
agentic loop: re-fetched next turn against a moving index, they would dominate
the table by volume, and replaying them would feed the model stale context it
did not ask for. The assistant row keeps the *fact* of the call and nothing of
its payload:

```json
[{"call_id": "call_dtYMZvvPFlgx4a4d84fU6VT4",
  "tool_name": "post_rpc_search_chunks", "is_error": false, "error_kind": null}]
```

What survives a retrieval instead is its **provenance**, derived by the runtime
from the rows the tool actually returned — never authored by the model:

```json
[{"kind": "chunk", "resource_type": "document",
  "resource_id": "11111111-2222-3333-4444-555555555555",
  "chunk_id": "5a11cfd4-2f20-40ac-8a56-7ef0489f9954"},
 {"kind": "chunk", "resource_type": "document",
  "resource_id": "11111111-2222-3333-4444-555555555555",
  "chunk_id": "c91ad88a-8db3-4b87-a90b-46b76480bb88"}]
```

Citations without payloads. A tool server opts in with
`tool_servers.emits_citations`; a ticketing API does not set it, a retrieval
service does.

And the runs, which are also the trace:

```
   agent    | depth |  status   | trigger_kind |             trace_id             |     span_id      |  parent_span_id
------------+-------+-----------+--------------+----------------------------------+------------------+------------------
 researcher |     0 | succeeded | interactive  | 4bf92f3577b34da6a3ce929d0e0e4736 | e3d0ff0595f2d9d9 |
 analyst    |     1 | succeeded | interactive  | 4bf92f3577b34da6a3ce929d0e0e4736 | a8b0dc7040b1974c | e3d0ff0595f2d9d9
```

The `traceparent` sent with the request supplied that `trace_id` — its trace-id
field, not the whole header — and the child inherited it. `parent_span_id` is
simply the parent run's `span_id`: the delegation tree and the span tree are
the same tree, not two things kept in sync.

## Headers

Ambient context is deliberately separate from `messages`: it is not
conversation, so it is never replayed, summarized, or dropped by the context
window.

| Header | Effect | Verified by |
|---|---|---|
| `Authorization: Bearer <jwt>` | **Required.** Identity. HS256, verified with the same secret PostgREST uses; `sub` becomes the session/run owner and the RLS subject | omitting it → `401`; a spoofed `X-P8-User-Id` did **not** change the owner |
| `X-P8-Tenant` | injected into the system prompt's `<context>` block | agent echoed `tenant=acme` |
| `X-P8-Locale` | same; defaults to `en-US` when absent | agent echoed `locale=en-GB` |
| `X-P8-<anything>` | forwarded verbatim into the context block and the agent's typed `deps` — adding one is never a code change | `X-P8-Case-Id: INC-42` → agent echoed `case=INC-42` |
| `traceparent` | W3C; its trace-id field becomes `runs.trace_id` for the whole delegation tree | `runs.trace_id = 4bf92f35…` |
| `X-P8-Session-Id` | resume that conversation — the same name the response returns it under. Unknown or not yours → `404`, before the stream opens | a second request carrying only this header was answered from the first turn's content |
| `X-P8-User-Id` | **ignored on this endpoint.** Identity comes from the verified token, never a header a caller can set | owner stayed the token's user |

What the agent actually sees, for the request above:

```
You answer questions about incidents.
...

<context>
current_time: 2026-08-31T16:58:00.530170+00:00
locale: en-GB
tenant: acme
case-id: INC-42
</context>
```

## Body options

| Field | Meaning |
|---|---|
| `model` | **the agent's name**, not an LLM. The LLM comes from the `agents` row |
| `messages` | OpenAI shape. Only the latest `user` message is used as the turn's input — history comes from Postgres, so a client cannot rewrite a session's past by sending a different array |
| `stream` | must be `true` (below) |
| `session_id` | continue an existing conversation you own — or send `X-P8-Session-Id`, which is the route an OpenAI-shaped client has. Omit both for a new one; the id comes back in `X-P8-Session-Id`, and an unknown one is a `404` |
| `tools` | accepted by the shape and **ignored** — an agent's tool surface is whatever `tool_servers` its row points at |

## Register your own agent

An agent is a row, so adding one is data — no code, no restart, no redeploy. And
an agent **is a JSON Schema document**: `description` is the system prompt,
`properties` are the structured output, agent config sits beside them. There is
deliberately no `prompt` key.

```yaml
# dev/support.yaml
type: object
name: support
description: |
  You triage incident questions for the support desk.
  Search the incident record before answering, and say plainly when it
  does not cover the question.
model: openai:gpt-4.1-mini
tools:
  - server: p8-rag                     # a registered tool_servers row
    tools: [post_rpc_search_chunks]    # optional: narrow it to these operations
properties: {}                         # structured output, when there is one
context_policy:
  window_messages: 12
  summarize_after_messages: 30
```

That file is not *like* a model dump — it **is** one. The same agent in Python:

```python
class Support(BaseModel):
    """You triage incident questions for the support desk.
    Search the incident record before answering, and say plainly when it
    does not cover the question."""

    model_config = ConfigDict(json_schema_extra={
        "name": "support",
        "model": "openai:gpt-4.1-mini",
        "tools": [{"server": "p8-rag", "tools": ["post_rpc_search_chunks"]}],
    })
```

`Support.model_json_schema()` produces that YAML. There is no export step,
because there is nothing to convert — which is what `brief.md` §6's "authored in
code, deployed as data" means when it is taken literally.

```bash
$ percolate agent push dev/support.yaml
upserted support (29b8f106-ec3f-4f6c-9dac-79cd176fdb49)
```

The upsert is authorized **in the database**, not in the CLI:
`agentic.upsert_agent()` checks `rbac.has_permission(uid, 'agents', 'update')`,
so a push by a user without that permission fails in Postgres.

Read it back — one format, the same one `agent push` accepts, so pulling an
agent, editing it and pushing it back is a round trip rather than a translation:

```bash
$ percolate agent show support
type: object
name: support
description: |
  You triage incident questions for the support desk.
  Search the incident record before answering, and say plainly when it
  does not cover the question.
model: openai:gpt-4.1-mini
tools:
- server: p8-rag
  tools:
  - post_rpc_search_chunks
properties: {}
context_policy:
  window_messages: 12
  summarize_after_messages: 30
```

It is live immediately — same process, no restart:

```bash
curl -N -X POST http://127.0.0.1:8080/chat \
  -H "Authorization: Bearer $P8_REST_TOKEN" -H "Content-Type: application/json" \
  -d '{"model":"support",
       "messages":[{"role":"user","content":"Was the outage caused by a lock?"}],
       "stream":true}'
```

71 frames, and the answer assembled from the deltas:

> Yes, the outage was related to a lock. The root cause involved a migration
> that held an ACCESS EXCLUSIVE lock while a batch job opened 200 new
> connections. Additionally, there was no connection limit…

Two rows, because this agent retrieves but does not delegate — and the
citations are there without the retrieval payload:

```
 seq |  name   |   role    | tool_calls | citations
-----+---------+-----------+------------+-----------
 407 | support | user      |          0 |         0
 408 | support | assistant |          1 |         2
```

A tool provider is registered the same way — `percolate agent tools register p8-rag
http://localhost:3002/ --kind openapi --credential-ref env:P8_REST_TOKEN
--emits-citations` — which fetches the OpenAPI document once and caches the
operations on the row. The agent gateway is registered the same way, with
`--kind mcp --serves-agents`: that flag is what makes its tools *delegations*
(slow-path rows, a delegated-by header) rather than ordinary tool calls, and it
is a column rather than a name prefix so no other server can claim it. Neither adding an agent nor adding a tool provider
touches the runtime.

## Coming back to a conversation

A client resumes by sending back the id it was given, as
**`X-P8-Session-Id`**. The header — rather than only the body's `session_id` —
is the load-bearing route: the inbound contract is the OpenAI chat shape, which
has nowhere to put a thread id, so an off-the-shelf SDK can only reach for a
header.

```bash
# turn 1 — no session id; the response header carries the new one
$ curl -sD - -X POST …/chat -d '{"model":"recall",
    "messages":[{"role":"user","content":"My incident reference is INC-9137. Acknowledge it."}]}'
x-p8-session-id: 59ca04eb-2b89-468b-948f-8398c34e8a6e

# turn 2 — a different request, resumed by header alone
$ curl -N -X POST …/chat \
    -H "X-P8-Session-Id: 59ca04eb-2b89-468b-948f-8398c34e8a6e" \
    -d '{"model":"recall","messages":[{"role":"user","content":"What is my incident reference?"}]}'
```

> Your incident reference is INC-9137.

Nothing was sent but the id. The history came from Postgres — the persistence
adapter reloads the branch's window before the turn — so a conversation
survives the client, the connection and the process. What that requires of the
database is exactly what is already there: four rows, in order, owned by the
caller.

```
user assistant user assistant        ← recovered by a process that was not there
```

An unknown or someone else's id fails **before** the stream opens, with a status
code rather than an event, because once the response has begun the status is
already sent:

```
404 {"detail":"no session 00000000-0000-0000-0000-000000000000 — it does not exist, or is not yours"}
```

## Other endpoints

**`GET /sessions/{id}/events`** — the same stream, for an observer or a
reconnect. Nothing is run. Verified: a second client that never made the POST
received all **73 of 73** events of another client's turn, delegated sub-run
included.

```bash
curl -N http://127.0.0.1:8080/sessions/$SESSION/events -H "Authorization: Bearer $P8_REST_TOKEN"
```

**CRUD is PostgREST's**, not this service's — `sessions_api`, `runs_api`,
`messages_api`, `agents_api`, `tool_servers_api`, all RLS-scoped:

```bash
curl "http://localhost:3001/messages_api?session_id=eq.$SESSION&select=seq,role,citations&order=seq" \
     -H "Authorization: Bearer $P8_REST_TOKEN"
```
```json
[{"seq":295,"role":"user","citations":[]}, {"seq":296,"role":"tool_call","citations":[]}]
```

**`POST http://127.0.0.1:8765/mcp`** — the agent gateway: this runtime's agents
as an MCP server, which is how delegation stays an ordinary `tool_servers`
reference instead of a built-in tool.

**`POST http://127.0.0.1:8765/internal/run`** — the scheduled-run trigger,
called by `workflow-engine`'s `http_call` executor and not by clients. Accepts
and returns `202`; the runtime completes the originating task itself when the
run is genuinely done.

## Errors

```
$ curl … (no Authorization)
401 {"detail":"a verified bearer token is required"}

$ curl … -d '{"…","stream":false}'
400 {"detail":"stream=false is not supported; read messages_api for the finished turn"}
```

`stream: false` is refused rather than silently buffered: this endpoint exists
*because* streaming is the one thing PostgREST cannot do, and a caller who wants
the finished answer should read `messages_api`.

Failures after the stream opens arrive as an event, because the HTTP status is
already sent:

```
event: RUN_ERROR
data: {"type":"RUN_ERROR","run_id":null,"thread_id":"59e888a4-…","status":"failed",
       "message":"LookupError: no agent row named 'nope'"}
```

A **tool** failing is not an error of this kind — it is an ordinary observation
the agent sees and reacts to. `TOOL_CALL_END` carries `is_error` and
`error_kind` (`tool_error` = the service answered and refused; `dispatch_error`
= it was never reached), and nothing is retried automatically.
