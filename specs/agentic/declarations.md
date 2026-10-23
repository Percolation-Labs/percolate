# Declarations — tools an agent uses to say what it is doing

**Status: specified, not built.** Nothing in this document is in
[`schema.sql`](schema.sql) or in `core/percolate_core`. The DDL fragments below are
sketches of shape, not the territory.

`brief.md` §5.2 says an agent reaches the world through tools, and that every
tool is a row pointing at an independently deployed service. This document
covers one class of tool whose only effect is a row in Postgres: the agent calls
it to **declare state** — its plan, what it is waiting for, what it decided, what
it cannot resolve. Three readers need that state and none of them should have to
parse a transcript to get it:

- **the agent itself, next turn**, because a model is stateless, and a plan it
  wrote four turns ago is gone once the window pushes it out;
- **a person**, watching a checklist tick over beside the conversation, or
  answering an approval from somewhere other than the chat;
- **another system**: a workflow that fires when an approval lands, a UI, or a
  second agent picking up where the first left off.

Five declarations are specified: the two that prompted this document and three
more.

| Declaration | Tools | What it says | §   |
|---|---|---|---|
| **Checklist** | `declare_checklist`, `set_item` | here is my plan, and this is where I am in it | 4 |
| **Approval** | `request_approval` | I want to do *X*; may I? | 5 |
| **Follow-up** | `schedule_followup`, `cancel_followup` | wake me at *T*, or when *R* is answered | 6 |
| **Decision** | `record_decision` | I chose *A* over *B* and *C*, for this reason, on this evidence | 7 |
| **Question** | `ask` | I cannot resolve *Q* at this locus; meanwhile I am assuming *A* | 8 |

In the vocabulary of `brief.md` §5.0, what these write is **conversation state**.
The user-facing name for it is *session memory*. It belongs to one session's
branch, a newer declaration supersedes an older one, and it is never carried to
another session as history. The decision and question declarations have a second
life outside that component (§7, §8), and it is stated where it happens.

## 1. What makes a tool a declaration

A tool belongs in this set if and only if all five hold. The list is the
admission test for a sixth declaration, and §10 records the candidates it
turned away.

1. **Its only effect is a row in Postgres.** No outbound call, no computation,
   no side effect in another system. A tool that sends an email is a tool
   server, not a declaration. An observer of the row sends the email.
2. **It states a value; it does not issue a command.** `set_item(3, 'done')`,
   never `toggle(3)`. Every declaration has a key, and calling it twice with the
   same arguments leaves the same rows. A retried tool call, a replayed turn and
   a model that forgot it already did something all come out correct.
3. **It is addressed to the substrate, not to a recipient.** The agent does not
   name who reads it. Whoever can act reads it: a UI, a workflow, a person, the
   next run.
4. **It comes back into the agent's own context without being asked for** (§3).
   An agent that declares a plan and then has to call a tool to recall it has
   been given a database, not a memory.
5. **It can only write to the branch the calling run is in** (§2). No
   declaration takes a session, run, user or owner argument.

Test 2 is what separates these from ordinary tools. An ordinary tool call is an
event: it happened, and the transcript records that it happened. A declaration is
a state. Its current value is what matters, and the history of values is
kept as an append-only record beside it (§9, requirement 7).

## 2. How they are served without a built-in tool

`brief.md` §5.2 says **zero built-in tools, ever**, and this set does not bend
it. A `declare_checklist` inside the runtime would be the first built-in tool,
for the same reason a `delegate` tool would have been (`brief.md` §5.1 item 3)
and a `load_skill` tool would have been (`plugins.md` §5.4). The same move that
resolved those two resolves this one: the tools are served by something the
collection already runs.

**The tools are Postgres functions in a `declare` schema, served by PostgREST,
bound as one `tool_servers` row.**

```yaml
tool_servers:
  - name: p8-declare
    kind: openapi
    url: ${POSTGREST_URL}
    default_headers: {Accept-Profile: declare}
    receives_run_context: true        # the one new column, below
```

The binding is the mechanical OpenAPI adapter `brief.md` §5.2 already specifies,
pointed at PostgREST's own document. The adapter handles Swagger 2.0 and uses
`default_headers` to select the schema, which is the case §5.2 was written
against. The description a model reads for each tool is the function's
`comment on function`, which PostgREST publishes as the operation's description.
The tool's prose is therefore versioned in the schema with the function it
describes. An agent opts in the usual way: `agents.tools` names `p8-declare` and,
optionally, the subset it may use. An extractor gets none; a planning agent gets
the checklist and follow-ups.

The runtime needs one addition, and it is data, not tool logic.

**`tool_servers.receives_run_context boolean`.** A declaration has to know which
run called it, and the model must not be the one to say. So when the runtime
calls a tool on a server with this column set, it adds one header,
**`X-P8-Run-Id`**: the id of the run making the call. The function reads it
from `current_setting('request.headers')`, loads that run under the caller's
RLS, and derives everything else from the row: session, branch, owner, agent.
It also refuses unless the run is `running`. One header, and the database
computes the rest, which follows the rule delegation already uses: *"a caller
cannot assert a shallower depth or a different parent span than the database will
compute"* (`core/percolate_core/agentic/runtime/delegation.py`).

This is a column rather than a check on the server's name for the reason
`serves_agents` is a column (`brief.md` §11.2, third bullet). Whether a server
receives a header that scopes writes is a security property, and a naming
convention would let any registered server claim it. It is also not
`serves_agents` reused: that column decides persistence granularity and
delegation headers, and a declaration is neither.

`X-P8-Run-Id` is inside the reserved `X-P8-*` space, so `brief.md` §11.2's first
rule already stops a model-supplied argument from setting it. A person calling
the same RPC directly through PostgREST can set it, and that is permitted. It
lets them write to a run they own, which RLS allows anyway. The person ticking
off an item in the agent's checklist is a feature (§4), and the row records that
a person, not a run, wrote it.

## 3. How they reach the model

Declarations are rendered into the context of every turn in the branch. The
render belongs to Postgres: `declare.render(p_run_id) returns text`, one call
per turn, returning a short block or null. A sketch of the unbuilt render:

```
<declarations>
checklist r3 (revised 2 turns ago)
  1. [x] Pull the Q2 filings for the three issuers
  2. [~] Reconcile share counts against the register
  3. [ ] Draft the variance note
  4. [-] Check the 2019 restatement  (dropped: out of scope per user)
awaiting approval  a7: "Email the variance note to finance@"  (asked 40m ago)
follow-up  recheck-register: at 2026-09-12 09:00
decisions  d2: use the register over the filing where they disagree
</declarations>
```

Four rules, each taken from where the text sits among the five components.

- **It is placed after the windowed history and before the newest message.**
  Not in the system instructions. A system-instruction block that changes
  whenever an item is ticked invalidates every cached prefix after it. Near the
  tail it changes only the tail.
- **It is derived, never stored as a message.** A declaration is a row in its
  own table; the rendered block is a projection of those rows. Persisting it
  would put a second, stale copy into history.
- **It is not subject to the window or the summarizer.** It is re-rendered
  from rows each turn, so a window policy cannot drop it and a summary cannot
  paraphrase it. `plugins.md` §7 has the same requirement for a loaded skill,
  and for the same reason: an agent that followed a plan for six turns and then
  lost it, with a transcript showing it made one, is the failure to avoid.
- **Within a turn, the tool response carries the current state.** Every
  declaration function returns the rendered block for its kind after the write.
  A model that ticks three items in one turn therefore sees the board after each
  tick without a second read, and `declare.render` runs once per turn, not once
  per call.

**The render has a budget, enforced by the function.** It returns at most a
fixed number of characters. Anything past the budget is summarized by count
(`+4 earlier decisions`), never truncated mid-line. A block that grows without
bound turns every long conversation into a context problem.

## 4. Checklist

The two tools, and nothing else changes a checklist:

```
declare_checklist(items: [{text, state?}], title?)   -- replaces the plan
set_item(ordinal: int, state: todo|doing|done|dropped, note?)  -- moves one item
```

**The ordinal is an item's identity within a revision.** `declare_checklist`
creates a new revision and numbers its items 1..n by position. `set_item` refers
to an ordinal in the current revision. Inserting a step between 2 and 3 is a
replan, and a replan is `declare_checklist` again, which is a new revision with
new ordinals. The alternative is stable ids that survive reordering, which makes
the model track identifiers across turns. An ordinal is what it already sees in
the rendered list.

**Revisions are kept.** A replan is information: the agent dropped two items
at turn 4 after the user narrowed the scope. The current revision is what
renders; the earlier ones are what an observer or a reviewer reads.

**Four states, and `dropped` is not deletion.** An item removed from the plan
stays visible as dropped, with its note, because *"I was going to check the
restatement and decided not to"* is part of what the agent did. `doing` is
limited to one item per checklist by a partial unique index. A second `doing`
is refused, and the error is an observation naming the item already in
progress, the same as any tool failure (`brief.md` §11.2). A checklist with
three items in progress tells an observer nothing about what is happening now.

**Caps belong to the table**: at most 50 items per revision, 200 characters per
item, as CHECK constraints. `brief.md` §11.3's structural limits belong in the
database.

**Nothing changes a checklist when a run ends.** A run that finishes with an
item `doing` leaves it `doing`. Declarations are the agent's claims, and a
runtime that tidied them at run end would be making claims of its own. The
render shows the age of the last write, which is enough for a reader to see a
stale board.

Sketch:

```sql
declare.checklists (id, session_id, branch_key, revision, title,
                    written_by_run uuid null, written_by uuid, created_at)
declare.checklist_items (checklist_id, ordinal, text, state, note,
                         written_by_run uuid null, written_by uuid, updated_at,
                         primary key (checklist_id, ordinal))
create unique index one_doing on declare.checklist_items (checklist_id)
    where state = 'doing';
```

`written_by_run` is null when a person wrote it through PostgREST directly.
`branch_key` is §9's scope rule, materialized so the render reads one index.

## 5. Approval

```
request_approval(key, action, detail?, expires_in?) -> {request_id, status}
```

**It returns immediately.** The status is `pending` on the first call, and the
run keeps its process only as long as it has other work. Nothing waits on a
person: *no task waits on a human*,
and a run held open for an answer that arrives in six hours is that invariant
broken inside the agent runtime instead of the engine. The agent either does
other work or ends its turn and says what it is waiting for.

**The key makes it declarative.** Calling `request_approval` again with the
same key returns the existing request and its current status. The agent checks
whether it was approved by asking again, and it cannot open two requests for
one action by forgetting it asked. The next turn's render also shows the
status, so the agent usually does not need to ask.

**The answer is a row written by a person**, through an RPC in a separate
schema, `declare_answer`:

```
answer_request(request_id, approve boolean, note?)
```

Four states: `pending → approved | denied | expired`. `expires_in` defaults to
a value the deployment sets; expiry runs on the per-minute pg_cron job beside
`workflow.promote_due_timers()`. The session owner may answer by default.
A deployment can widen that with an `rbac` pair (`approvals:answer`) scoped the
usual way. An approval names no individual approver, but a named approver is
still a legitimate case, and the workflow engine's `signal:` step covers it.

**Answering wakes the run that asked.** An approval is a follow-up with a
condition (§6). `request_approval` registers `on_answer` for its own key, so the
answer starts a continuation run in the same branch. The continuation reloads
history, and the render shows `approved` or `denied` with the note. Approval
cannot be built before follow-ups, which sets the build order (§11).

**The part a reviewer has to carry: the agent must not be able to answer its
own request.** `brief.md` §11.2 says every tool call executes as the caller, so
an agent bound to a server that exposes `answer_request` would approve its own
request with the user's identity. It is the confused-deputy class again, and
the database cannot see it: the agent's call and the person's call arrive as
the same principal. What this spec requires:

- `answer_request` lives in `declare_answer`, and `upsert_tool_server` refuses
  any row whose `default_headers` select that profile. The check runs on shape
  and existence, per `brief.md` §11.3's third rule.
- `answer_request` refuses a request carrying `X-P8-Run-Id`, since that header
  exists only on calls the runtime makes on a run's behalf.

Both are conventions a determined configuration can route around, for example a
second PostgREST exposing the schema under another name. The substrate-level fix
is for the token the runtime forwards to carry an actor claim (RFC 8693 `act`)
that the database can refuse on. That is open (§12), and it is the same fix
§11.2's deputy needs everywhere else.

**An approval the agent asks for is a courtesy, not a control.** An agent that
never asks is not stopped. The control version makes the runtime refuse to
dispatch a named bound tool until an approved request for that call exists, and
it is not in this set: it changes what a tool call does rather than declaring
anything (§12).

## 6. Follow-up — suggested

```
schedule_followup(key, at? | after_seconds? | on_answer?, instruction)
cancel_followup(key)
```

The agent declares that it wants to run again in this branch at a time, after
an interval, or when a named approval or question is answered, with an
instruction to itself for when it wakes. Re-declaring the same key replaces the
follow-up; `cancel_followup` withdraws it.

**Why this is the most valuable of the three.** It lets an agent keep working
after the person has left without anything waiting. *Check the register again
tomorrow at nine*, *if finance has not answered by Friday, draft the reminder*,
*when the approval lands, send it*: each is one row, not a sleeping process, a
held connection or a cron entry. It is the continuation that §5 needs anyway,
exposed to the agent directly. It also covers the background half of `brief.md`
§3 for conversations: a scheduled run today has no history and belongs to no
session, and a follow-up is a scheduled run that does both.

**Mechanism: no new scheduler.** `declare.followups` is promoted by
`promote_due_followups()`, scheduled per minute beside
`workflow.promote_due_timers()` and approval expiry, the same way
`workflow.promote_due_gradients()` sits beside timers
(`../trace-field/schema.sql`). A due follow-up calls `start_workflow('continue_branch', …)`, one
`http_call` step in `mode: "async"` against the runtime's internal trigger.
That is the dispatch `brief.md` §3 already specifies for scheduled runs, so
retry, rate limits and `task_events` come from `workflow-engine`. It does not
use the `timer:` step kind, which a compiler build may not accept
(`workflow-engine/YAML.md`, *When the compiler is older than the schema*); a row
the tick scans has no such dependency.

**What it needs from the runs table:** a third `trigger_kind`,
`'continuation'`. A continuation is a run in a session with no user message.
Unlike `'scheduled'` it reloads its branch's history; unlike `'interactive'` its
input is the follow-up's instruction, persisted as a `role = 'system'` message on
the run. The transcript then shows why the agent spoke without being spoken to.
`brief.md` §11.3's rule of one live interactive turn per session covers it: a
continuation that falls due while a person is mid-turn is deferred to the next
tick, not run beside them.

**Limits, in the database:** a cap on pending follow-ups per session, and a cap
on continuations per branch per day. An agent that schedules a follow-up on
every run otherwise wakes itself forever, and the owner pays for it, since a
continuation is metered against the session owner like any other run. Whoever
pays has to be able to see what is pending, so `followups_api` lists them and
the owner can cancel any of them.

## 7. Decision — suggested

```
record_decision(key, decision, rationale, alternatives: [text], evidence: [ref])
```

The agent records a choice it made: what it chose, what it did not choose, why,
and what it read that bore on it. Re-recording a key supersedes the earlier
decision, which stays in the record as superseded.

**Why it is high value:**

- **A summary compresses away the reasons first.** The rolling summary
  (`brief.md` §3) keeps *"reconciled share counts using the register"* and loses
  *"because the filing and the register disagree for two issuers, and the
  register is the legal record"*. The next turn then relitigates it, or worse,
  reverses it without knowing it was settled. A decision renders every turn
  (§3) and does not pass through the summarizer.
- **It is what an approver reads.** `request_approval` shows *the action*; the
  decisions in the branch show *why the agent arrived at it*. An approval with
  no rationale beside it gets approved by habit.
- **It is the structured input consolidation wants.** Consolidation needs
  memory written from use, and `brief.md` §5.0 records that no shipped workflow
  writes it yet. A decision row is a claim with provenance, already typed. That
  is cheaper to consolidate than a transcript, and it carries the provenance
  `brief.md` §5.0's second rule requires: this was written from use, not
  ingested.

**Evidence is checked, not trusted.** `evidence` takes the same tagged refs as
`messages.citations` (`{"kind":"chunk",…}` / `{"kind":"node",…}`), and the
function refuses any ref that does not appear in the citations of the branch's
own assistant messages. `brief.md` §5.3 derives citations mechanically from what
tools returned, never from what the model says, and a decision citing a chunk
the agent never retrieved would reintroduce model-authored provenance. The rule
is exact: set membership, not a judgement about whether the evidence supports
the decision.

**A person can endorse or veto a decision**, and that is a `trace-field` human
anchor (a `workflow.anchors` row, `../trace-field/schema.sql`) on the decision's run, not a new
table. An endorsed decision becomes durable ground for consolidation. A vetoed
one renders as vetoed, and the agent sees that on its next turn.

## 8. Question — suggested

```
ask(locus, question, assumption, options?: [text], same_as?: question_id)
```

The agent cannot resolve something, and the answer is not specific to this
conversation. *Is "Harbour Holdings" the same issuer as "Harbour Holdings
(Cayman)"?* is a question about two entities, and every run that meets them
needs the answer. `ask` deposits the question **at a locus** (an entity, a
source, a document type, a workflow definition) and returns immediately. The
agent must also state an `assumption`: what it will proceed on until someone
answers.

**How it differs from approval, and why it is a separate declaration.** An
approval is bound to *this run* and *one action*, and it resolves once. A
question is bound to *a locus*, outlives the run that asked it, and its answer
applies to every future run that reaches that locus. A question channel needs
three properties a blocking request cannot have: questions
**accumulate and rank**, **decay** when nobody answers or re-asks, and answers
**broadcast**. Folding questions into the approval table would give them
approval's lifecycle, which is the wrong one.

**It is built from trace-field's tables, not new ones**, though their
`locus_kind` CHECK must first widen to admit entity, source and document-type
loci (§11). The question text
lives in `declare.questions`. `ask` also inserts a `workflow.deposits` row of
kind `question` at the locus, with `origin_key` set to the asking agent's name.
Ten runs of one agent asking the same question therefore compound as one origin,
and ten different agents compound as ten. The answer is a `workflow.anchors`
row with act `resolution`, so it settles the question permanently at that locus.

**Deduplication is the model's job, with a citation.** `ask` returns the open
questions already deposited at that locus before it deposits a new one. If one
of them is the same question, the agent calls `ask` again with `same_as`, which
reinforces the existing question instead of adding a near-duplicate. Two
questions are the same if the model says so and names which one; the database
does not guess from the wording.

**The elicitation budget is enforced in the function.** Each agent gets a
number of questions per period. Once it is spent, `ask` refuses, and the
refusal tells the agent to proceed on its assumption. A question channel
without a budget becomes a ticket backlog. Here the tool function *is* the enforcement
point: the agent cannot reach `workflow.deposits` except through it.

## 9. Scope, and who may write

**A declaration belongs to a branch, and a branch is what the window is scoped
to** (`brief.md` §5.1 item 1). For an interactive or continuation run that is
its session plus its `parent_run_id`. The conversation's successive top-level
turns share one checklist; a delegated sub-agent has its own and does not see
its caller's. For a scheduled run the branch is its `workflow_task_id`, so a
retried run finds the checklist the failed attempt left, and resumes a plan
instead of starting over.

A caller that wants a sub-agent to work from its plan passes the relevant items
in the delegation prompt, which is the existing answer to *should a sub-agent
see its caller's conversation* (`brief.md` §9). §12 carries it as an open
question.

**Observers read across branches.** `declarations_api` is RLS-scoped by
`owner_id` like every other view here. A UI shows a delegation tree's
checklists together, and a workflow reads any declaration its caller could read.
Scope decides which rows a run renders and writes; it does not hide anything from
the person who owns them.

**Writers:** the calling run, identified by `X-P8-Run-Id` and verified against
RLS (§2), or a person through PostgREST directly on their own session. Every row
records `written_by_run` and `written_by`, so an item a person ticked off never
looks like one the agent did.

## 10. What is left out, and which test each fails

- **A free key-value `set_state(key, value)`** — AG-UI's shared-state bag.
  It passes tests 1–5 and still fails the purpose of the set: an untyped value
  has no observer that can act on it without knowing the agent that wrote it.
  Each declaration here is typed so a UI or a workflow can act on it with no
  per-agent knowledge. `agents.category` is closed for the same reason
  (`brief.md` §5.7).
- **A progress percentage.** The checklist is the progress. A number the model
  invents is a number nobody can calibrate.
- **`notify(person, message)`.** Fails test 1: it acts outside Postgres. It is a
  tool server. Observers of declarations can notify, and that is where the
  notification code belongs.
- **`remember(fact)`.** Memory is written by consolidation from use
  (the consolidation workflow), not by an agent deciding mid-turn what deserves to
  outlast the session. `record_decision` gives consolidation its best input
  without letting the agent write memory directly.

## 11. What is new, and the order to build it

| Piece | Kind | Needed by |
|---|---|---|
| `declare` schema: tables, functions, `declare.render` | SQL | all |
| `tool_servers.receives_run_context` + the runtime sending `X-P8-Run-Id` | column + ~10 lines of runtime | all |
| the render slot after the window | runtime, in the persistence adapter | all |
| `STATE_SNAPSHOT` relay: a trigger on each declaration table publishes an ids-only checkpoint on `agui_<session>`, the relay reads the rows and emits AG-UI `STATE_SNAPSHOT` | trigger + relay | all |
| `runs.trigger_kind = 'continuation'` | CHECK widened | follow-up, approval |
| `promote_due_followups()` and approval expiry, per minute beside `workflow.promote_due_timers()` | SQL | follow-up, approval |
| `declare_answer` schema and the `upsert_tool_server` refusal | SQL | approval |
| `workflow.deposits`/`workflow.anchors` exist; their `locus_kind` CHECK must widen to admit entity/source/doctype loci | CHECK widened | question, decision veto |

The stream uses the pattern `brief.md` §4 already uses for `MESSAGE_PERSISTED`:
a trigger, an ids-only payload within NOTIFY's 8000 bytes, and a relay that
reads the row. No new event kind is invented. AG-UI's `STATE_SNAPSHOT` exists for
exactly this, and a client that renders one renders a checklist.

**Order.** The checklist first: it is the smallest declaration, and it exercises
every shared piece (the server row, the header, the render slot, the stream) on
its own. Follow-up and approval together next, since approval is a follow-up with
a condition. Then decision. Question last, because it is the only one whose
value depends on another subsystem, trace-field's anchors, being in use.

**Gate for each**, in the form of the agentic gates in `core/percolate_core/agentic/phases.py`: against a live stack with a
real model, an agent bound to `p8-declare` declares a plan, ticks it across
three turns, loses the early turns to the window, and still reports its plan
correctly on turn ten. A second client watching the session sees each tick as a
`STATE_SNAPSHOT`, and a second user sees none of it.

## 12. Open questions

- **An actor claim on forwarded tokens** (§5). The token the runtime forwards
  to a tool server is the caller's token, and nothing on it says *this call was
  made by an agent*. With an RFC 8693 `act` claim, `answer_request` could refuse
  at the substrate, and so could every other RPC that should only be reached by
  a person. This is the general fix for `brief.md` §11.2's deputy, and this set
  is its second concrete consumer after delegation.
- **Gated approval as a control.** Should `agents.tools[]` be able to name
  tools that the runtime refuses to dispatch without an approved request? That
  would make approval enforceable instead of voluntary. It adds a branch to the
  dispatch path, which `brief.md` §5.2 keeps free of per-use-case logic. It may
  still be generic enough to belong there.
- **Where the render sits relative to the cache.** §3 places the block near the
  tail on the argument that it keeps cached prefixes stable. That is a claim
  about provider caching behaviour and has not been measured here. Measure it
  before building, on the providers the runtime targets.
- **Whether a sub-agent should render its caller's checklist read-only.** §9
  says no, matching the window. A long delegated task that is one item of its
  caller's plan might do better seeing the whole plan. Decide it with `brief.md`
  §9's `inherits_context`, not separately.
- **Whether `continuation` is a new trigger kind or an interactive run with no
  user message.** §6 proposes a new kind because the input and the persistence
  differ. The alternative adds no value to the CHECK and makes every consumer of
  `trigger_kind = 'interactive'` handle a run nobody typed.
