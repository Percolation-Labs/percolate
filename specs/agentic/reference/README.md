# The Percolate agent, and the two tool servers it binds

The worked sample for `brief.md` §5.2. One agent, one MCP server, one OpenAPI
server, and the claim they exist to make checkable:

> A tool server is a **name and a url**. What its tools are called, what
> arguments they take and what they are for is **discovered from the server**,
> not written down here. Adding an agent, or a tool provider, is zero lines of
> code.

| | |
|---|---|
| [`percolate.yaml`](percolate.yaml) | the whole use case — two servers, one agent |
| [`binder.py`](binder.py) | register → discover → invoke. No branch on which service. |
| [`query_mcp.py`](query_mcp.py) | the one MCP tool this collection ships: `query`, over p8ql |
| [`runtime.py`](runtime.py) | one agent turn — load the row, run it, persist what happened |
| [`../../../dev/init/03-sample-agent.sql`](../../../dev/init/03-sample-agent.sql) | generated from the YAML; what `docker compose up` installs |

Nothing here is a runtime. The agent runtime is
percolate-core
(`brief.md` §10); these files are the reference for the *binding*, which is the
half that lives in this repository because it is the half the schema defines.

---

## The three stages, and why they are separate

```
register    an upsert into agentic.tool_servers -- name, kind, url, flags.
            No network. A migration does this, and it is all a fresh
            `docker compose up` needs.

discover    fetch the OpenAPI document, or connect and call tools/list, and
            adapt whatever comes back into ONE canonical tool shape. Cached
            onto the row. Re-run whenever the upstream changes.

invoke      read a canonical tool, make the call. By this point nothing knows
            or asks whether the tool came from MCP or OpenAPI.
```

Registration and discovery are separate calls because discovery is an HTTP
fetch, and this collection's first rule is that the database never blocks on
HTTP. A migration at initdb registers rows for servers that are not listening
yet; the descriptions arrive when something can reach them. An agent whose
server has not synced is **unsynced, not broken**.

## Run it

```bash
cd dev && docker compose up -d          # brings up query-mcp too

# discovery runs where the runtime runs -- the urls in the YAML are the ones
# services use, so this runs inside the compose network rather than on the host
docker run --rm --network dev_default -v "$PWD/../specs/agentic/reference:/ref:ro" \
    -e P8_TOKEN="<a JWT for someone holding agents:update>" \
    python:3.12-alpine sh -c \
    'pip install -q pyyaml && python /ref/binder.py \
        --postgrest http://postgrest:3000 apply /ref/percolate.yaml'
```

```
registered  p8-query         mcp      http://query-mcp:8090
  discovered 1 tools: query
registered  p8-workflow      openapi  http://postgrest:3000
  discovered 84 tools: get_rpc_cancel_run, post_rpc_cancel_run, ...
agent       percolate        tools[p8-query:1, p8-workflow:5]
```

## What the agent ends up holding

Neither description below was written in `percolate.yaml`. Both were generated
by the database at the moment the tool was discovered.

**From the MCP server** — `query_mcp.py` builds its own tool description by
asking the database `SCHEMA "p8ql"`, the dialect facet whose examples the
parser re-verifies on every read:

```
$ binder.py tools p8-query
p8-query  (mcp)  http://query-mcp:8090  synced=2026-09-01T16:05:32Z

  query(query)
    Ask this database a question in p8ql, its query dialect. One string, one
    endpoint, every retrieval mode: ...
```

**From the OpenAPI server** — PostgREST turns `COMMENT ON` into the
operation's documentation, first line into `summary` and the rest into
`description`, and the adapter copies it:

```
  post_rpc_start_workflow(p_external_id, p_input, p_name, p_trace_id)
    Start a run of a workflow that has already been defined.

    Takes the workflow NAME (not an id) and a JSON input object, and returns
    the new run's id immediately -- it does not wait for the run to finish.
```

Which is the useful consequence of a mechanical adapter: **how usable a bound
tool is, is a property of the database.** `workflow-engine/schema.sql` §24 is
where those sentences live, and it exists because before it these five
operations bound as tools with a generated name, an argument list, and nothing
saying what they did.

## One call each

```bash
$ binder.py call p8-query query '{"query": "LOOKUP \"usd/gbp\""}'
{
  "mode": "LOOKUP",
  "plan": {"ok": true, "arg": "usd/gbp", "mode": "LOOKUP", "fuzzy": false, ...},
  "rows": [{"key": "usd/gbp", "score": 1, "entity_type": "fx_pair",
            "node_id": "90b7fa06-...", "match_kind": "canonical"}]
}

$ binder.py call p8-workflow post_rpc_start_workflow \
      '{"p_name": "content_reconcile", "p_input": {}}'
"1bee5c6b-e298-456f-92b4-dcbd791ee004"

$ binder.py call p8-workflow get_runs_api \
      '{"id": "eq.1bee5c6b-...", "select": "id,status,completed_at"}'
[{"id": "1bee5c6b-...", "status": "completed", "completed_at": "..."}]
```

Two transports, one code path. `invoke()` never receives the server's kind —
it reads `invoke.transport` off the tool that discovery produced, which is the
whole architecture reduced to one dispatch.

---

## Running an agent

`runtime.py` is the turn, with everything the deployed runtime adds (streaming,
delegation, windowing, summarization) removed, so the contract fits on a screen:

```
1. read the agent row                        agentic.agents_api
2. resolve its allowlist to real tools       tool_servers_api.cached_tools
3. open a session and a run                  create_session, start_run
4. ask the model, with those tools
5. it asked for a tool -> dispatch and go to 4        binder.invoke
6. it answered -> persist the turn and close  persist_turn, finish_run
```

```
$ runtime.py percolate "Which pairs moved with sterling?"
  agent   percolate  (anthropic:claude-sonnet-5, tool_user)
  tools   query, post_rpc_define_yaml, post_rpc_schedule_workflow,
          post_rpc_start_workflow, get_runs_api, get_tasks_api
  call    query({"query": "GRAPH \"usd/gbp\" TYPE same_band"})

  the turn, as persisted:
    user           Which pairs moved with sterling?
    tool_call      [{"id": "call_...", "function": {"name": "query", ...}}]
    tool_response  {"mode": "GRAPH", "plan": {...}, "rows": [{"key": "usd/aud", ...
    assistant      ...
                   [{"kind": "node", "node_id": "1f11256e-..."}, ...]
```

The citations on the assistant row were derived by the runtime from the tool
responses, because `p8-query` is flagged `emits_citations` — never asked of the
model (§5.3).

**Grep this file for `percolate` and there is nothing to find.** No agent, no
tool, no prompt: the agent's name appears only in argv. That is §5.2's claim
stated as a property of a file you can check rather than an argument.

### Agents load at invocation — the thing that makes "agents are rows" true

`brief.md` §11.9 requires that a running process serve an agent that did not
exist when it started, and reflect an edit on the next turn. Both, in one
process:

```
1. this process has been running since before this agent existed
   load_agent('fx-analyst') -> no agent named 'fx-analyst'.

2. insert it. A REST call. Nothing is restarted.
   upsert_agent -> ok

3. the same process runs it, on the next line
   loaded  fx-analyst | general | tools=[{'server': 'p8-query', 'tools': ['query']}]
   ran     52752928-... -> {"answered_from": "tool_result", ...}

4. edit the agent. Same process. Next turn sees it.
   prompt  CHANGED: you now refuse to discuss the euro.
   offered to the model this turn: nothing
```

### Against a real model

The transcripts above used the stub. Here is `gpt-4.1-mini`, with no scripting,
asked the question cold:

```
$ runtime.py --model-url https://api.openai.com/v1/chat/completions \
             --model-credential env:OPENAI_API_KEY \
             percolate 'Which currency pairs moved in the same band as sterling?'

  agent   percolate  (openai:gpt-4.1-mini, tool_user)
  call    query({"query": "SCHEMA"})
  call    query({"query": "SCHEMA \"graph\""})
  call    query({"query": "LOOKUP \"sterling\""})        -> unresolved
  call    query({"query": "FUZZY LOOKUP \"gbp\""})       -> usd/gbp
  call    query({"query": "GRAPH \"usd/gbp\" TYPE same_band"})

  answer  The currency pairs that moved in the same band as sterling (usd/gbp)
          are: usd/aud, usd/jpy, usd/cad, usd/nzd
```

The model was switched from Claude to GPT by **one upsert** — `{"name":
"percolate", "model": "openai:gpt-4.1-mini"}` — with nothing redeployed. That
is §11.9 in one call.

**It did not work the first three times, and each failure was the system's, not
the model's.** Every fix was a row or a query-layer defect; none was a change to
this runtime.

1. It wrote `select * from forex_weekly_bands` — a table that does not exist in
   a store that is not tables — got nothing, and reported there was no data. The
   agent had never been told to look before querying. Fixed in the **prompt**:
   always start with `SCHEMA`.
2. It then read both schema facets correctly and still could not start, because
   `SCHEMA "graph"` named the entity types and not one key. It guessed
   `sterling`, `gbp`, `gbp_usd`, `gbpusd` and gave up; the keys were `usd/gbp`.
   Fixed in the **query layer**: the graph facet now carries `sample_keys`.
3. It kept guessing spellings instead of using `FUZZY LOOKUP`, which resolves
   `gbp` to `usd/gbp` on the first call. Fixed in the **prompt**.

Two of the three were data. That is the design working: the agent got better
without a deploy, and the one code change was closing a dead end in the query
layer that no agent could have reasoned around.

### The model, and the one honest substitution

The model endpoint is configuration, not agent data: the row says
`anthropic:claude-sonnet-5`, which names a model; where to reach one belongs to
the deployment. Point `--model-url` at a vendor with a key.

Without a key, point it at `dev/faultsrv`'s scripted stub, which is what the
transcripts above used. The stub decides nothing — a `#tool <name> <args>` line
in the message tells it which call to emit, and on the next turn it answers,
quoting what the tool returned so the caller can prove the result reached the
model's context rather than being persisted and dropped. Everything else in
those transcripts is real: the agent is a real row, the tools are really
discovered, the tool call really executes against Postgres, and the turn is
really persisted. A test double that decided things would be the one part worth
distrusting.

---

## What building it actually found

Five things, each of which had been asserted somewhere and was wrong or
missing. They are listed here rather than quietly fixed because that is this
repository's rule.

**1. One url is not one OpenAPI document.** PostgREST serves five schemas from
`http://postgrest:3000` and selects between them with `Accept-Profile`. The
first registration fetched the `content` document, succeeded, cached 30-odd
tools, and did not contain a single workflow operation. Fixed with
`tool_servers.default_headers` — non-secret headers sent on the fetch and on
every call, with a check constraint refusing `Authorization` and `Cookie`,
since secrets stay in `credential_ref`.

**2. An anonymous sync loses most of the surface, silently.** With no
`credential_ref`, discovery fetched the document as `web_anon` and got **61
operations instead of 84** — missing `start_workflow`, `runs_api` and
`tasks_api`, three of the five tools the agent is bound to. The row looked
correct. `brief.md` §5.2 predicted exactly this when arguing `credential_ref`
belongs in the read view; here it is, reproduced. What caught it was
`binder.py apply` checking every agent's binding against what discovery
actually found, which it now always does.

**3. Discovery and invocation are different identities.** `credential_ref` is
what the server is *registered* as — a call must run as the person talking to
the agent, or the tool server hands every user the same maximal result set.
The caller's token wins at call time; `query_mcp.py` holds no credential at
all and forwards the header it was given.

**4. Header parameters are not arguments.** The document lists `Prefer`,
`Range` and `Range-Unit` as parameters, so the first adapter faithfully put
three HTTP-framing arguments into the input schema of all 84 tools. Headers a
service genuinely needs are a property of the *server*, one layer up.

**5. The documented write path could not install the sample.** `upsert_agent`
checks a permission against the JWT identity — and the first agent in any
deployment is registered by a migration, where there is no JWT and a null
identity holds no permissions. Every seeded agent failed with "not
authorized". `agentic.may_author` adds a deliberately narrow bootstrap branch:
no end-user identity at all, *and* a session that could have written the row
with a plain INSERT anyway. That second half is what keeps it closed — over
REST the login role is `authenticator`, which holds no table grant by design,
so the branch is unreachable from outside. Verified in both directions.

**6. A partial upsert wiped the agent, and returned 200.** `{"name":
"percolate", "model": "openai:gpt-4.1-mini"}` is how anyone changes an agent's
model. Written the obvious way, `set x = excluded.x` for every column, and
`excluded` carries the column DEFAULT for every key the caller did not send --
so that call left the sample agent with an empty system prompt and no tools. It
still existed, still resolved by name, and could do nothing. The same mistake as
the `cached_tools` erasure, fixed one function away and not here; both tables
now decide on the presence of the KEY, never the emptiness of the value. And on
`tool_servers` that needed fixing on both arms: `kind` and `url` are NOT NULL,
so a partial registration could not even form a valid insert tuple to reach the
ON CONFLICT clause.

**7. `agents_api` did not expose what an agent is FOR.** `audience`,
`category` and `tags` were added to the table and never to the view the
runtime reads through — so a client could see every agent and sort them by
nothing, which is the state the classification block was added to end, undone
one layer along.

Two smaller ones, fixed in place: `upsert_tool_server` erased `cached_tools`
whenever a registration omitted them (so re-registering a server to correct
its url emptied its tool list), and `upsert_agent` silently ignored
`audience`, `category` and `tags` — accepting an agent authored as
user-facing, reporting success, and leaving it invisible in `agents_pickable`.

---

## Skills: prompt expansion, and what measuring it changed

The second worked sample in this directory, for [`../plugins.md`](../plugins.md)
rather than for §5.2 of the brief. Same discipline: build the thing the spec
describes, run it against a live database, and write down what it did rather
than what it was supposed to do.

| | |
|---|---|
| [`skills.yaml`](skills.yaml) | the fleet — 23 prompt fragments, 2 servers, 1 agent, as one plugin manifest |
| [`skills_eval.yaml`](skills_eval.yaml) | 31 labelled requests (27 positive, 4 negative) and a six-turn conversation |
| [`skills.py`](skills.py) | the reference implementation of expansion: `plugins.md` §5, executed |
| [`skills_eval.py`](skills_eval.py) | the instrument: `apply`, `embed`, `retrieval`, `efficiency`, `behaviour` |
| [`skills_race.py`](skills_race.py) | two clients, one agent: why attaching a fragment is a database operation |
| [`skills_toolset.py`](skills_toolset.py) | the fetched path on pydantic-ai: one `load_skill` tool, plus deferred loading for what the index cannot list |

`skills.py` has the same property `runtime.py` has, and for the same reason:
grep it for `p8ql` or `workflow` and there is nothing to find. The fleet is
rows. This is the assembly.

### Run it

```bash
DSN="postgresql://p8:p8@localhost:5499/p8skills"

python3 skills_eval.py --dsn "$DSN" apply skills.yaml          # one call, one transaction
python3 skills_eval.py --dsn "$DSN" --matcher lexical retrieval  skills_eval.yaml
python3 skills_eval.py --dsn "$DSN" --matcher lexical --min-score 0 efficiency skills_eval.yaml

# the two arms that need a provider
export OPENAI_API_KEY=...          # or --env-file, which is never printed
python3 skills_eval.py --dsn "$DSN" embed
python3 skills_eval.py --dsn "$DSN" retrieval skills_eval.yaml
python3 skills_eval.py --dsn "$DSN" behaviour skills_eval.yaml --transcripts out.json
```

Needs `psycopg2` and `pyyaml`, and a database with this branch's `agentic`
schema loaded — `plugins.md` §11 has the numbers the first three produced.

### What it found

All four arms ran. Two findings changed the spec, and one of them reversed a
decision the other had just produced.

1. **Skills work, and the index line is most of why.** Behaviour probe, three
   arms, 5 samples per cell: a bare agent gets 2/20, a one-line listing entry
   gets **16/20**, the full body gets 18/20. What the body buys is not
   behaviour but *specificity* — 13/20 against 0/20 on the rule only the body
   carries. A description changes what the model does; a body makes it precise.
2. **So `index` defaults to `bound` and `top_k` drops to 2.** The cost
   measurement had said the opposite: the index is the one term that grows with
   the fleet, and at 200-character bodies listing everything costs more than
   expanding everything. That was the right reading of cost and the wrong
   default, made before the benefit side existed.
3. **Embedding the listing beats embedding the body on rank** — 78% vs 56%
   hit@1, 0.838 vs 0.720 MRR — and loses on recall@3 by four points. Rank is
   what expansion uses, so §6 holds; the recall result is recorded rather than
   rounded away.
4. **`aiq.lexical` cannot do this job: 4% hit@1.** It builds its query with
   `plainto_tsquery`, which is conjunctive, so every term of a request must
   appear in a 120-character listing. The same query made disjunctive reaches
   74% hit@3. The fallback in `skills.py` builds that query itself; an `any`
   mode belongs in `ai-query-layer`'s own dialect, on its own evidence.
5. **Sticky expansion is worth its 20 percentage points.** Replaying the
   six-turn conversation without it, the expanded set is entirely different on
   every turn — three `p8ql-*` fragments on turn 2, three `workflow-*` on turn
   3, another swap on turn 5. The instructions churn, silently.
6. **A generated column cannot reference another generated column**, which is
   why `agentic.skills` declares `search_tsv` itself instead of letting
   `aiq.register_lexical_source` build it over the generated `discovery_text`.

Two things the harness learned about itself, kept because they are the argument
for `--transcripts` and `--repeats`:

- **The first rubric was wrong in the direction that flattered the spec.** It
  scored the index arm FAIL for an answer that said *"I will propose the DELETE
  statement for you to review and run yourself"* — the exact required
  behaviour, missed by a keyword list holding "run it yourself" and not "run
  yourself". Caught by reading one transcript.
- **Temperature 0 is not determinism.** One probe's index arm passed on one run
  and failed on the next with nothing changed. Every cell is five samples now,
  and one of them (`safety-no-destructive-sql`, expanded) sits at 3/5 — lower
  than its own index arm, which is the honest remainder rather than a rounding
  error.

`plugins.md` §11 carries all of it at length, including §11.7 on what 4 probes
and one model cannot settle.
