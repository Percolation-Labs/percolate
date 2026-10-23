# Plugins and skills — capability as prose, installed as a unit

`brief.md` §5.2 settles what an agent can *do*: a tool is a row pointing at an
independently deployed service, the runtime has no tool code of its own, and a
new capability is an insert. This document settles the other half — what an
agent *knows how to do*, which is prose, not a service — and names the unit
both halves arrive in.

Two additions, one of which is genuinely new here:

- **`agentic.skills`** — markdown procedures as rows: a name, a description a
  model reads to decide whether it needs this, and a body it reads once it has
  decided. New.
- **`agentic.plugins`** — a name, a version, and a `plugin` column on the three
  configuration tables, so a bundle of servers, skills and agents applied from
  one document can be re-applied and removed as one. Not new in substance:
  [`reference/percolate.yaml`](reference/README.md) has been a plugin manifest
  since the day it was written; it just had no name and nothing could uninstall
  it.

Both are in [`schema.sql`](schema.sql) and both were exercised against a live
PG19 before this was written — the failures recorded below in *found by running
it* notes are ones that happened, not ones imagined.

## 1. The standard being transcribed, and the part of it that survives contact

Anthropic's [plugin
specification](https://code.claude.com/docs/en/plugins-reference) and the
[Agent Skills](https://agentskills.io) standard it implements define a plugin
as a directory: `.claude-plugin/plugin.json` naming the bundle, and beside it
`agents/*.md` (one subagent per file, YAML frontmatter for `name`,
`description`, `model`, `tools`, and — the field this document is downstream of
— `skills`), `skills/<name>/SKILL.md` (frontmatter plus a markdown body),
`commands/`, `hooks/hooks.json`, `.mcp.json`.

Three of its properties are load-bearing here, and the rest is filesystem
convention this collection has no use for:

1. **A skill is frontmatter plus a body, and the split is the mechanism.**
   `description` (recommended, and *"what the skill does and when to use it —
   Claude uses this to decide when to apply the skill"*) plus the optional
   `when_to_use` enter the model's context always, truncated together at 1,536
   characters; the body enters it only when the skill is invoked. Long
   reference material *"costs almost nothing until you need it."* This is
   progressive disclosure, and it is why a skill is two columns rather than
   one.
2. **An agent declares which skills it has.** The plugin spec's agent
   frontmatter carries a `skills` field: *"Skills available to this agent."*
   The agent names keys; the content is somewhere else.
3. **Skills are not tools.** They sit in a different directory, load by a
   different path, and `allowed-tools` exists on a skill precisely because a
   skill is the thing that *tells you to use* tools.

What does not survive: the filesystem. A directory tree is discovered by
walking it, versioned by whatever version-controls it, and permissioned by the
operating system. Here the store is Postgres, which is the whole architectural
premise of this collection, and it buys three things a
directory cannot — RLS on who may read a skill, one write path that can refuse
a bad one, and retrieval over a population too large to list. §6 is about the
third.

**On pydantic-ai, since the runtime wraps it (`brief.md` §5.1) — and what is
NOT used, stated because the answer is easy to assume wrongly.**

The library has shapes that fit this: toolsets can be produced by a *function*
re-called ahead of each run step (`@agent.toolset`), `instructions` may be a
function evaluated per run rather than a static string, and
`DeferredLoadingToolset` *"marks its tools for deferred loading, hiding them
from the model until discovered via tool search"* — for exactly the reason
cited there, that *"loading all tool definitions into the model's context would
be wasteful."* There is also a third-party `pydantic-ai-skills` implementing
the Agent Skills standard over a filesystem.

**The design does not depend on any of it, and only one path uses it.**
Neither [`reference/skills.py`](reference/skills.py) nor percolate-core's agent
subpackage touches `DeferredLoadingToolset`; `reference/skills.py` imports no
pydantic-ai at all, and only §5.4's gateway reference does. Two reasons, and the first is load-bearing:

- **The laziness is a SQL projection, not a framework feature.** §5's expansion
  happens *before* the model call and produces a string. What makes it lazy is
  that the index query asks for `name, description, when_to_use` and never for
  `content`, so a body is not read until it is named. That is a property of the
  query; it holds under any framework or none, and it is the thing worth
  getting right — a framework's deferred loading cannot save you if your own
  read already pulled every body out of the database. This spec's first
  implementation did exactly that: the prompt was lazy and the read was not,
  which is the half of the claim nobody looks at. Measured on the eval agent,
  4,400 characters of body were read per turn and 1,400 used.
- **The one path that maps onto `DeferredLoadingToolset` is §5.4's
  gateway**, where the model asks for a fragment by name through a tool. That
  path is implemented in the reference
  ([`reference/skills_toolset.py`](reference/skills_toolset.py), via
  `defer_loading()`); percolate-core does not ship it. Hidden-until-searched is
  exactly the offer an index line makes.

The per-run `instructions` hook is likewise where a deployed runtime *would*
attach expansion. percolate-core implements the composed path only: every
attached skill's body is injected on every turn (`runtime/injection.py`,
`render_skills_block`). It reads no `context_policy.skills`, so `always`,
matching, the index and stickiness exist only in `reference/skills.py`.

## 2. Why a skill is a shared system instruction, not part of one agent's prompt

The obvious objection first, because the answer is short and it is the same
answer `brief.md` §5.2 already gave about tool servers.

An agent's `system_prompt` belongs to one agent. The instruction *"always start with `SCHEMA`;
a model that skips it writes SQL against a table that does not exist"* — which
is real, and was a paragraph of
[`reference/percolate.yaml`](reference/percolate.yaml)'s `system_prompt` and is
now the `p8ql-schema-first` skill —
belongs to *every* agent bound to the query server, present and future. Inline,
it is copied per agent and drifts on the first edit; that is precisely the
duplication `tool_servers` exists to prevent for urls and credentials, applied
to prose instead.

So: one row, referenced by name, from as many agents as need it. Editing it
once changes all of them, which is the property that makes it worth a table.

## 3. Why a skill is not a tool, and why it is not a document either

Both boundaries matter, because this collection already has a table on each
side and either could plausibly swallow this one.

**Against a tool.** A tool call leaves the process and comes back an
*observation* the model reasons about. A skill comes back as *instructions the
model follows for the rest of the turn*. That difference is not philosophical —
it decides three concrete things: whether the runtime may summarize it out of
the window (§7), whether it belongs in `citations` (§8: no — a source is cited,
a procedure is obeyed), and whether it can fail (a tool can be unreachable; a
skill either exists or does not).

**Against a document.** `content.resource_chunks` already stores text and
`aiq` already retrieves it. The distinction is lifecycle and authority: a
document is *ingested*, may be wrong, and is cited so a reader can judge it; a
skill is *authored*, applied as a migration (`brief.md` §6), and is followed
without being questioned. Storing skills as documents would put prose the agent
must obey in the same index as evidence it must weigh, which is a category
error the first time retrieval returns one instead of the other.

The rule that follows, and it is a hard one: **a skill has no url, no
credential, no invocation target, and no code.** If it needs to *do* something,
it is a tool server. If it needs to be *weighed*, it is world-model content.

In the vocabulary of `brief.md` §5.0 the two boundaries separate three of a
turn's context components: a skill is a **system instruction**, what a tool
returns is a **tool output**, and a document is **retrieved knowledge**. A
skill fetched through the gateway (§5.4) arrives in the shape of a tool output
and is still a system instruction, which is why §7 keeps it out of the window
policy that governs conversation state and history.

## 4. The table

[`schema.sql`](schema.sql) §2b. The columns that carry a decision:

| Column | Why |
|---|---|
| `name` | The key an agent lists — and, through the gateway (§5), a *tool name*, hence the kebab-case constraint. A tool name with a space in it is a tool no model can call. |
| `description` | What it does. The one field a model sees without paying for the body. |
| `when_to_use` | When to reach for it. Separate because it is the sentence a *semantic* match should hit — a user's request rarely resembles a capability statement. |
| `content` | The markdown body. Never in a listing; never embedded (§6). |
| `discovery_text` | Generated: `name: description when_to_use`. Generated rather than assembled by the embedding job, so the text that was indexed and the text a reader sees cannot drift. |
| `requires_tools` | The servers this skill's instructions assume. Checked when an *agent* pins it, not when it is authored. |
| `version` | Bumped by `upsert_skill` when the text changes. §8. |
| `audience`/`category`/`tags` | The same classification block `agents` carries, for the same reason: this table is one insert away from thousands of rows. |

Two constraints are worth stating as decisions rather than leaving in the DDL.

**The listing is a budget.** `description` + `when_to_use` is capped at 1,536
characters by the table, transcribing the Agent Skills listing cap rather than
inventing a number. It is enforced here because the alternative — truncation at
render time — is invisible: a skill whose "when to use" is cut off mid-sentence
is a skill the model stops choosing, with nothing anywhere reporting why.

**`requires_tools` is the useful half of `allowed-tools`.** The standard's
field is a *permission grant* against an interactive approval flow. There is no
such flow here, so the grant half is meaningless; what remains, and what
matters, is the dependency it implies. An agent that pins *"answer retrieval
questions with the `query` tool"* while binding no server offering `query` has
been given instructions it cannot follow — worse than an unbound tool, because
a tool it cannot see is a tool it does not try, while prose it cannot act on is
prose it will act on anyway, badly. `upsert_agent` refuses it at author time.

**Found by running it.** That check was first written the obvious way —
validate `skills` whenever the document carries a `skills` key — and it passes
the test it was written for while missing the edit that actually breaks an
agent. `{"name": "a1", "tools": []}` carries no `skills` key, so nothing ran,
and the agent kept a pinned skill whose server it no longer bound. The check
now runs against the agent the upsert will *produce*, whenever either key is
present. One statement after the intended refusal worked.

## 5. How a skill reaches the model: expansion is the primitive

The point of putting prose in rows is that **a prompt should be assembled, not
authored whole.** An agent's row carries a short prompt and a set of keys; the
text those keys name lives once, is shared by every agent that needs it, and is
read at invocation. Laziness is what makes that affordable — a fragment this
turn does not need never enters the context.

So the mechanism is **expansion**, and there are three ways a fragment gets
expanded. They read the same rows and differ only in who decides.

### 5.1 Attachment: a skill surface, exactly like a tool surface

**`agents.skills` is what this agent may use, not what it carries.** It is the
same idea as `agents.tools` one column over, and the parallel is exact enough
to be the design rather than an analogy:

| | `agents.tools` | `agents.skills` |
|---|---|---|
| what the row names | servers and tool names | fragment names |
| what the prompt carries | name, description, parameters | name, description, when to use |
| what it does **not** carry | the implementation | the body |
| what arrives on demand | the tool's result | the fragment's text |
| what the model does with it | calls it | follows it |

A tool is offered to a model as a *listing*: a name, a description, an argument
schema. The implementation lives in a service the model never sees, and it is
reached only when the turn calls for it. That is why an agent can be offered
dozens of tools without dozens of implementations in its context — and it is
exactly what attachment does here. The sample agent binds 5 of the 85
operations its OpenAPI server exposes and carries none of their code; it
attaches 5 fragments and carries none of their bodies.

**So attaching is cheap and it is lazy.** Every attached fragment contributes
one listing line to every prompt, whether or not it is used. Its body arrives
only when the turn calls for it. Attaching one more fragment costs a line, not
a page. (percolate-core does not yet implement this; it still composes every
attached body — see §1.)

This is the correction that the first version of this section got wrong, and it
mattered: `agents.skills` originally meant "concatenate this body into the
prompt at every invocation", which is not attachment at all — it is pasting the
paragraph back into the prompt the table exists to take it out of. A design
where adding a capability costs its full text every turn does not scale past a
handful, which is the property the whole standard is built to avoid.

### 5.1a `always`: the subset that is unconditional

Some fragments must hold whether or not the turn looks like it needs them —
house style, safety rules, output conventions. Those are named in
`context_policy.skills.always`, and their bodies are expanded on every
invocation.

It is a policy key rather than the meaning of attachment, for the reason above:
if attaching were eager, there would be no cheap way to give an agent a large
surface. `always` is expected to be two or three names out of a surface of
dozens, and naming a fragment there that the agent has not attached is refused
by the reference runtime ([`reference/skills.py`](reference/skills.py)) — a
policy about something that is not there. The schema does not check it.

### 5.2 Matched — what the embedding is actually for

The runtime embeds the turn's request, ranks it against `discovery_text` (§6),
and expands what clears a threshold, under a character budget. No round trip,
no tool call, and the model never has to know skills exist.

This is what the embedding exists for. Indexing name and description in order
to feed a *search tool* would be building retrieval and then making the model
ask for it; the useful thing to do with a ranked list of fragments is expand
the top of it.

**Matching ranks the attached surface.** That is the default and it is the
capability question: of what this agent has, what does this turn need?
`scope` widens the ranking to fragments the agent has *not* attached, which is
a different claim — discovery beyond its own surface — and so it is a different
key rather than the same one doing both.

The policy lives in `agents.context_policy` under a `skills` key rather than in
a new column, because `context_policy` is already the per-agent knobs for what
enters the context, and "which fragments does this turn deserve" is exactly
that question:

```json
"context_policy": {
  "window_messages": 40,
  "skills": {
    "always":    ["house-style", "safety-no-destructive-sql"],
    "match":     true,
    "matcher":   "semantic",
    "top_k":     2,
    "min_score": 0.28,
    "max_chars": 6000,
    "scope":     {"tags": ["query", "workflow"]},
    "index":     "bound",
    "sticky":    true
  }
}
```

`always` names the unconditional subset of the attached surface (§5.1a).
`scope` *widens* matching beyond that surface; without it, matching ranks what
the agent has attached and nothing else.

**`matcher` (`semantic` | `lexical`) is named rather than assumed**, and
`min_score` is relative to whichever is named. The two scores are not
comparable — cosine against `ts_rank` — and worse, §11.1 measured that
`ts_rank` has no usable threshold at all on this corpus: recall falls from 74%
to 26% between 0.01 and 0.03. A lexical matcher is a `top_k` matcher. The
lexical arm exists so that a deployment with no embedding provider degrades to
TEXT rather than to nothing, which is why `skills` registers as both kinds of
`aiq` source.

**`index` is the attached surface, minus whatever is already expanded** — one
listing line each, which is what makes attachment cheap and lazy rather than
free and invisible. A model cannot use what it has never heard of, so the
listing is not optional decoration; it is the offer, in the same way a tool's
name and description are the offer.

**`index` (`bound` | `none`) defaults to `bound`, and the two measurements
behind that pull in opposite directions.** §11.3 found that the index is the
one term in this design that grows with the fleet: one line per fragment on
every turn, and at 200-character bodies `index: bound` costs *more* than
expanding the entire fleet. On cost alone the default should be `none`, and it
was, for exactly as long as it took to measure the other side.

§11.4 measured the other side. **One 223-character listing line produces 16 of
the 20 behaviour changes that a full body produces** — the index is the most
efficient instruction-carrier in the design, not a directory of things the
model might ask for. So it stays on, and the cost result becomes a rule about
*authoring* rather than a default: with `index: bound` the prompt beats
expand-everything **if and only if a fragment's body is longer than its own
listing**, so a fragment whose body is shorter than its listing should be
composed, not matched — it is cheaper to always have than to advertise.

**`top_k` should be 2, not 3** (percolate.yaml sets 2;
`reference/skills.py` still defaults to 3), from the same pair of measurements: the
body's behavioural margin over its own listing line is two responses in twenty,
while §11.1 measured `top_k = 3` wasting about two expansions per request
before §5.3's stickiness compounds them. Expand few; index everything.

**A rule about writing a description follows, and it is measured rather than
stylistic.** The listing is an instruction, so write it as one. *"When a LOOKUP
returns nothing, use FUZZY LOOKUP instead of guessing another spelling"* is a
complete instruction in 96 characters and scored 5/5 with no body at all; a
description written as a label — *"about name resolution"* — would have scored
nothing. §4's 1,536-character cap is the budget that instruction has.

**`max_chars` is a budget, not a suggestion, and what it drops is reported.**
A cap that silently truncates produces the same failure the listing cap exists
to prevent one level up: instructions cut mid-sentence, with nothing anywhere
saying so. When the budget is reached, the remaining matches fall back to their
index lines and the run records which ones.

### 5.3 Sticky expansion — settled, and the reason it is not optional

Matching per turn against the latest message is responsive and, on its own,
wrong: an agent's instructions would *change mid-conversation*. A fragment
expanded on turn three is gone on turn four when the subject moves, so a model
that was told to always cite its sources quietly stops being told — and no
error is produced anywhere, because nothing failed.

Matching once at the start of a branch avoids that and is wrong the other way:
a conversation that turns gets the fragments its opening deserved.

**The rule: match every turn, and expansions are sticky within a branch.** Once
a fragment has been expanded it stays expanded for the life of that branch;
later matches are *added*, never swapped in. Instructions are therefore
monotonic within a conversation, which is the property that makes the failure
above impossible rather than unlikely, and the accumulation is bounded because
`max_chars` caps the total rather than the increment.

Three consequences worth stating, because each one is a decision:

- **Branch-scoped, exactly like the window** (`brief.md` §5.1). A delegated
  sub-run does not inherit its parent's expansions, for the same reason it does
  not inherit its parent's messages: they are not its instructions.
- **The set is state, so it lives in `runs.state`** — under a `skills` key,
  as `{"name": version}` pairs. Not recomputed from the transcript, because
  the transcript does not contain the composed prompt, and not held in process
  memory, because the runtime is disposable and a resumed conversation must
  expand the same set.
- **Eviction is the window, not a policy.** When the window rolls and a branch
  is summarized, the sticky set is not carried across — a new window is a new
  branch of instructions, and a fragment that still matters will match again on
  the next turn. Adding a second eviction rule here would be a second lifetime
  to reason about for no gain.

### 5.4 Fetched — the optional third path, and the rule it must not break

`brief.md` §5.2 is absolute: **zero built-in tools, ever.** A `load_skill`
compiled into the runtime would be the first one and would break the rule the
rest of the design rests on. So the runtime exposes its own skills as an MCP
server — the *skill gateway*, a `tool_servers` row with `serves_skills = true`
— and fetching one becomes an ordinary tool call against an ordinary
registered server, narrowed by the ordinary per-server allowlist. That is the
same resolution `brief.md` §5.1 item 3 already reached for delegation, reused rather than
reinvented.

**Two surfaces, split by population rather than by preference.**
[`reference/skills_toolset.py`](reference/skills_toolset.py) is both, running:

- **`load_skill(name)` — one tool, over the attached surface.** The index
  already names those fragments, so the model does not need to search for them;
  it needs a way to *ask*, and that is one tool with one argument. Measured: the
  model reads the index, calls `load_skill("p8ql-fuzzy-lookup")`, gets the body
  and follows it.
- **Deferred loading — one tool per fragment, over what `scope` reaches and the
  index cannot list.** `pydantic-ai`'s `defer_loading()` hides them from the
  prompt entirely and its auto-injected tool search surfaces them on demand. A
  fragment that was never attached, never indexed and never in the prompt was
  found and followed this way. An agent that sets no `scope` carries none of it.

`scope` is therefore deliberately **not** indexed. Indexing it would put the
population back in the prompt and leave the deferral with nothing to defer,
which is the same mistake in the other direction from §5.1's.

**What it costs, stated because it is the honest weakness.** A fetched fragment
arrives as a *tool result*, and models follow instructions in a tool result less
reliably than instructions in a system prompt. Worse, the model has to *decide*
to look: asked how to get structured data out of 200 documents without it
costing a fortune, the model answered from its own general knowledge and never
searched, while the same population and the same wiring produced the right
fragment the moment the request was shaped like a request to look. Both are
arguments for §5.2's runtime-decided matching being the primary mechanism and
this being the addition.

### 5.5 Attaching one fragment: a statement, not a read-modify-write

Everything above describes what an agent's fragments *are*. This is how one
gets added, and it is a database operation rather than a client pattern for a
reason that is measurable.

Without it, adding a fragment to an agent means: read `agents.skills`, append,
send the whole array back through `upsert_agent`. That is a lost update. Two
clients attaching two different fragments to one agent both read the same
array, and the second write silently discards the first — no error, no
conflict, and an agent missing an instruction somebody watched themselves add.
It is the same class of failure as an upsert that drops a column it did not
read, one layer up: a partial write that reports success.

**Reproduced, not argued.** Two connections, one agent, two fragments, a
barrier so both read before either writes:

```
two clients attach two different fragments to one agent, simultaneously
  read-modify-write (today)    -> 1 of 2 landed  [house-style-brevity]
  attach_skill                 -> 2 of 2 landed  [house-style-brevity,
                                                  house-style-attribution]
```

So: `agentic.attach_skill(p_agent, p_skill, p_spec default null)` and
`agentic.detach_skill(p_agent, p_skill)`. Four properties, each a decision:

- **In place, under a row lock.** The array is appended to inside a `select …
  for update`, so concurrent attaches to one agent serialize instead of
  clobbering. This is the whole reason the function exists; without the lock it
  would be sugar over the bug.
- **One write path.** It does not touch `agents` itself — it computes the new
  array and hands it to `upsert_agent`, so §5.1's checks (the skill exists, its
  `requires_tools` are bound) run here too, from one copy. Attaching
  `p8ql-fuzzy-lookup` to an agent that binds no query server is refused by the
  same message as authoring it that way.
- **Idempotent, and ordered.** Attaching what is already attached changes
  nothing and is not an error. Composed fragments concatenate in listed order,
  so a new one appends at the end rather than being sorted in. Detaching what
  was never attached is a no-op — the caller's intent is satisfied either way.
- **Author-and-attach in one call.** `p_spec` upserts the fragment before
  attaching it, which is what the REST path needs: PostgREST is one function
  per request, so two calls would be two transactions and a window where the
  fragment exists and nothing points at it.

Two things it deliberately refuses. An agent that does not exist is an error
rather than a create — `upsert_agent` called with `{name, skills}` would
happily produce an agent with an empty prompt and no tools, which resolves by
name and can do nothing. And a `name` given both as the argument and inside
`p_spec`, disagreeing, is refused rather than resolved: whichever one this
function picked, the other is what somebody believed they had written.

**`apply_plugin` does not use these**, and that is correct rather than an
oversight. A manifest declares the complete set an agent carries, so it sets
`skills` wholesale; attach is for the incremental case, where the caller knows
one fragment and not the whole list.

## 6. Discovery at a thousand skills

The index (§5.2) is one line per bound-but-unexpanded skill, which is
affordable at twenty and not at a thousand, and matching has to rank against
something in any case. The extractor pattern (`brief.md` §5.7) already puts
this table's sibling on a trajectory to thousands of rows, and skills will
follow the same curve for the same reason — one specialist procedure per
(source, document type) is as natural to write as one specialist agent.

The answer is the one this collection already owns, not a second one:
`agentic.skills` registers as an `aiq.semantic_sources` corpus over
`discovery_text`, and its vectors land in `ai-query-layer`'s per-model
embedding tables keyed by the skill's own id. `SEMANTIC`/`SEARCH` then answer
*"which skills bear on this request"* the same way they answer it for chunks,
and the gateway's search tool is a query, not a new index. The registration is
conditional on `aiq` being installed — the same shape `workflow.plan_catalog()`
uses to call `agentic.plan_facet()` only when this schema exists — so `agentic`
stays loadable on its own.

**Only the listing is embedded, never the body.** A body is instructions:
hundreds of imperative lines that dilute the one sentence describing what the
skill is for, and would make every procedural skill look like every other one
to a vector index. This is the same discipline `v_plan_agents` applies in the
opposite direction — the whole prompt where a reader needs intent, the listing
only where a matcher needs discrimination.

**Measured, and it holds on rank rather than on recall** (§11.1). Embedding the
listing beats embedding the body by 22 points of hit@1 and 0.118 of MRR; the
body arm finds the right fragment in the top three four points *more* often.
Since expansion takes the top *k* under a threshold, rank is the metric that
decides and the listing wins it — but the body's recall advantage is real, and
a design that ever wants the union rather than the ranking should know the
difference is there.

**Nothing here embeds anything.** Embedding is an external model call, and this
collection has exactly one path for it (`aiq.embed_batch_call` plus a scheduled
`workflow-engine` task, `ai-query-layer/schema.sql` §10b). A second path would
be a second answer to which model this deployment uses. A skill whose
`updated_at` is newer than its embedding row is re-embedded by that task on its
next tick; nothing in the read path blocks on it, and a skill with no vector
yet is still pinnable and still loadable by name — only undiscoverable by
similarity, which is the correct degradation.

## 7. What the runtime must do

In the voice of `brief.md` §11 — the list a reviewer checks, not behaviour a
test would notice.

- **Skills load at invocation, from the database, by name.** §11.9's
  requirement, unchanged, extended to this table. A fragment read at startup
  would turn every prose edit back into a deploy.
- **A composed skill that no longer resolves is reported, not skipped.** §11.9's
  last bullet applies verbatim. `upsert_agent` makes this nearly unreachable,
  but "nearly" is not a guarantee the runtime may assume. percolate-core
  currently drops an unresolved pin (`_with_pinned_skills` in
  `db/repository.py`), so this requirement is unmet.
- **A loaded skill is not summarized away.** This is the one genuinely new
  requirement, and it falls straight out of §5.1's persistence adapter. A
  fetched skill arrives as a `tool_response` in the middle of a conversation and
  is therefore, by default, an ordinary message — eligible for the window and
  for compression into a `role = 'summary'` row. The result is an agent that
  follows a procedure for six turns and then silently stops, with a transcript
  that shows it was told. So: **the most recent load of each skill is
  reattached at the head of the reloaded window**, mirroring what the summary
  row already does at the tail, and never merged into the summary. `brief.md`
  §5.1 defines the window as branch-scoped; skill loads sit outside it, as
  standing instructions rather than history. This is why `serves_skills` is a
  flag on the server and not a naming convention: the adapter has to be able to
  *recognise* the message it must not compress.
- **The gateway reports which version it served.** §8.
- **An expanded body is a system instruction, not history.** It is injected at every
  invocation and never persisted as a message — persisting it would put the
  same text in the window on every turn, which is the cost the whole two-column
  design exists to avoid.
- **The sticky set is state, and it is `runs.state`.** §5.3. A resumed
  conversation must expand the same fragments, so the set cannot live in
  process memory, and it cannot be recomputed from the transcript because the
  transcript does not contain the composed prompt.
- **The budget reports what it drops.** §5.2. A match that did not fit falls
  back to its index line and the run records it; a silent truncation is the
  failure the listing cap exists to prevent, one level up.

Beyond reading pinned bodies at invocation and injecting them as instructions,
none of these is implemented in percolate-core yet; `reference/skills.py`
demonstrates the sticky set and the budget.

## 8. Provenance

`skills.version` is bumped by `upsert_skill` when — and only when — one of the
three fields a model actually reads changes. Retagging a skill is not a new
version of it.

The version is what the gateway returns with a body and what the runtime
records on the message that loaded it. Without it, a run whose answer rests on
a procedure since rewritten is unreconstructable, and — worse — nothing
downstream can *detect* that it is looking at the wrong text. This is the same
problem `citations` (`brief.md` §5.3) solves for retrieval, one layer along, and it gets a
counter rather than a citation for the reason §3 gives: a source is cited, a
procedure is obeyed.

Deliberately not versioned: the *body history*. A skill row holds the current
text only. If someone needs to read the text a six-month-old run followed, that
is a temporal-table question this collection has not answered anywhere else
either, and answering it here first would be the wrong place.

## 9. The plugin

`agentic.plugins` is a name, a version, the manifest as applied, and a
nullable `plugin` column on `tool_servers`, `agents` and `skills`. That is the
entire concept: **a plugin is not a new kind of thing, it is provenance on the
things that already exist** — which is exactly what makes a bundle removable.

`agentic.apply_plugin(jsonb)` takes one document and applies it in one
transaction, in one order — **servers, then skills, then agents** — because an
agent's pinned skills must exist before `upsert_agent` can validate them, and a
skill's `requires_tools` names servers the agent must already bind.

**The half that did not exist before is the prune.** An upsert-only apply is
how a bundle rots: an agent dropped from the manifest stays installed, still
resolvable by name, still runnable, and now nothing on disk describes it. So a
row carrying this plugin's name and absent from this manifest is removed, and
the removals are returned rather than done quietly.

**Which makes an absent section loud, and that is the trap.**
`{"name": "percolate"}` declares no agents and therefore removes every agent
`percolate` installed. That is what makes uninstall expressible without a
second function — an empty manifest *is* the uninstall — and it will bite the
first person who writes a partial document. Stated here, in the function's
comment, and in the error text of the guards below.

Three guards, all of which fired during the verification run:

- **An agent with runs is not pruned.** The foreign key from `runs.agent_id`
  refuses it, which is correct and says so badly, so it is caught and re-raised
  as the decision the author actually has to make: keep it in the manifest, or
  delete its runs first. This function does not delete conversation history.
- **A skill another agent still pins is not pruned.** There is no foreign key
  to stop it — `agents.skills` is a list of names, which is what lets one skill
  serve many agents, and the price is that referential integrity is a check in
  this function rather than a constraint on the table. Uncaught, it is the
  quietest failure in the schema: the other agent keeps working and loses a
  third of its instructions.
- **A server another agent still binds is not pruned.** Same shape, same
  absence of a foreign key (`agents.tools` holds server names in JSONB).

Uninstalling leaves the `plugins` row with nothing under it, which is
deliberate: the provenance of what *was* installed outlives the rows. Dropping
that row is then a separate, explicit delete — and until the rows are gone the
`on delete restrict` foreign keys refuse it, because a plugin row deleted out
from under its config would leave rows whose origin nobody can name, which is
the state the column exists to end.

**`reference/percolate.yaml` is already this document, one field short.** It
registers two servers and one agent, and applying it twice is already an
upsert. It now has a `skills:` section, and `binder.py` applies it (skills
before agents). What it still lacks is a top-level `name`, so it cannot be
applied or removed through `apply_plugin` as a unit.

## 10. What this deliberately does not add

An "explicitly not built" list is a decision, not a backlog:

- **No supporting files.** The standard's `references/` and `scripts/` beside a
  `SKILL.md` do not appear here. A reference is another skill row, named in the
  body and loaded the same way; anything heavier is world-model content that
  already has a store and a retrieval path. A second file tree inside Postgres
  would be a content-management system this collection does not need twice.
- **No hooks, no commands, no output styles.** The plugin spec's other
  directories describe an interactive coding harness. Nothing in this system
  has the concepts they attach to.
- **No skill-level tool permissions.** `allowed-tools` grants against an
  approval flow that does not exist here; §4 keeps the dependency half and
  drops the grant.
- **No separate tenancy model for skills.** Skills are scoped like agents
  (`owner_id`/`org_id`/`visibility`, `rbac.add_scope_columns` in `schema.sql`);
  existing rows were backfilled `public`, new rows default `private`.
- **No skill execution.** A skill is read. If it needs to run, it is a tool
  server (§3), and that boundary is what keeps `brief.md` §5.2's zero-built-in-tools rule
  true.

## 11. What the eval measured, and what it changed

These measurements were taken against an earlier version of
`reference/percolate.yaml`; `reference/skills_eval.py` reruns them.

[`reference/skills.py`](reference/skills.py) is §5 executed and
[`reference/skills_eval.py`](reference/skills_eval.py) is the instrument, over
a fleet of **23 fragments** ([`reference/skills.yaml`](reference/skills.yaml),
applied by `apply_plugin` in one call) and **31 labelled requests**
([`reference/skills_eval.yaml`](reference/skills_eval.yaml), 27 positive and 4
negative). Everything below is a number this repository can reproduce, against
a live PG19.

All four arms ran: lexical matching, semantic matching, the cost accounting and
a behaviour probe against a real model. The last of these is the one that
changed the design, and not in the direction the spec expected.

### 11.1 Matching, semantically: the listing ranks better, the body recalls better

`text-embedding-3-small`, both texts embedded into their own registered space
so both arms are ranked by the same `aiq.semantic_in` over the same join:

| embedded text | hit@1 | hit@3 | MRR |
|---|---|---|---|
| **listing** — name + description + when_to_use | **78%** | 85% | **0.838** |
| **body** — the full fragment | 56% | **89%** | 0.720 |

§6's claim holds on the metric the design actually uses, and it does not hold
cleanly. The listing wins decisively on *ranking* — 22 points of hit@1 and
0.118 of MRR — and the body wins hit@3 by four points. Expansion takes the top
*k* under a threshold, so rank is what matters: a correct fragment sitting at
rank 3 with a score of 0.19 is cut by any threshold worth setting. But the body
arm finding four points more of the right answers *somewhere* is a real result
and is recorded rather than rounded away.

The threshold sweep is the part worth acting on. At `min_score` 0.20 recall is
81% with one false positive across four negatives; at 0.28 it is 74% with none;
past 0.36 it collapses. And at every setting, `top_k = 3` **wastes about two
expansions per request** — 30 wasted at 0.28, 52 at 0.20. With sticky
accumulation (§5.3) that waste compounds, which is the argument for a small
`top_k` rather than a generous one.

### 11.2 Matching, lexically: a usable fallback and a broken one

| arm | hit@1 | hit@3 | MRR |
|---|---|---|---|
| `aiq.lexical` over `discovery_text` | 4% | 4% | 0.037 |
| ad-hoc `ts_rank` over `content` | 4% | 4% | 0.037 |
| disjunctive `ts_rank` over `discovery_text` | 56% | 74% | 0.668 |

**`aiq.lexical` is unusable for this job, and the reason is one function call.**
It builds its query with `plainto_tsquery`, which is conjunctive — *every* term
of the request must appear. That is right for finding a document that contains
a phrase and hopeless for matching a sentence against a 120-character listing:
`I looked up "sterling" and got nothing back` requires `look & sterling & got &
noth & back` to co-occur in one listing, and nothing does. Four percent.

Flipping the operators on the same parsed, stemmed, stopword-stripped query —
same corpus, same rows, same `ts_rank` — reaches 74% hit@3. So the fallback
builds that query itself, and `aiq.lexical` is left alone: an `any` mode
belongs in the query layer's own dialect, decided on its own evidence, not
smuggled in from a consumer. **This is a finding for `ai-query-layer`, recorded
here because this is where it was found.**

**`min_score` is meaningless on the lexical arm.** Recall falls from 74% to 26%
between thresholds of 0.01 and 0.03, and to 7% at 0.05 — `ts_rank` has no
plateau to put a cut in. A lexical matcher is a `top_k` matcher; `min_score` is
a knob that means something only on the semantic arm, and §5.2's policy is
matcher-relative rather than universal because of this.

### 11.3 The index is the expensive half, and there is an exact rule

The measurement that changed the design. Prompt cost as a percentage of
expanding everything, measured listings held fixed (mean **223 characters**),
bodies scaled — a fleet of 23 with 2 composed and 3 matched:

| mean body | `index: bound` | `index: none` |
|---|---|---|
| 200 | **108.7%** | 24.7% |
| 400 | 66.0% | 23.2% |
| 800 | 44.1% | 22.5% |
| 1,600 | 33.0% | 22.1% |
| 3,200 | 27.4% | 21.9% |
| 6,400 | 24.6% | 21.8% |

At 200-character bodies, listing the fleet costs **more than expanding all of
it.** The arithmetic behind that is exact and worth stating as a rule, because
it is not obvious and it is not about this fixture:

> With `index: bound`, the prompt is smaller than expanding everything **if and
> only if a fragment's body is longer than its own listing.** Both arms pay for
> the expanded ones; the difference is `(N − k)` listings against `(N − k)`
> bodies.

Two things follow, and both are now in §5.2 rather than being left to a reader.
This first set **`index: none` as the default**, because it is flat in the size
of the fleet and `bound` is not; §11.4 reversed that. And **a fragment whose body is shorter than its listing
should be composed, not matched** — it is cheaper to always have than to
advertise. The fixture's own mean body is 381 characters, which is why its
measured saving is only to 62–66%: these fragments are terser than real
procedures, and the eval understates the case for expansion rather than
flattering it.

### 11.4 The behaviour probe, which reversed a decision

The measurement the whole design rests on, and the only one that could have
sunk it: does an expanded fragment change what a model does — and would the
one-line index entry have been enough?

Three arms, one model (`gpt-4.1-mini`), temperature 0, **five samples per
cell**, four probes with a deterministic rubric at two levels. *Behaviour* is
whether the answer changed at all; *detail* is whether the specific rule that
only the body carries survived.

| probe | bare | index | expanded | index vs body |
|---|---|---|---|---|
| `p8ql-fuzzy-lookup` | 0/5 · 0/5 | 5/5 · 0/5 | 5/5 · 0/5 | 223 vs 503 chars |
| `workflow-diagnose-failure` | 0/5 · 0/5 | 1/5 · 0/5 | 5/5 · 5/5 | 225 vs 418 |
| `safety-no-destructive-sql` | 0/5 · 0/5 | 5/5 · 0/5 | 3/5 · 3/5 | 227 vs 260 |
| `workflow-never-poll` | 2/5 · 0/5 | 5/5 · 0/5 | 5/5 · 5/5 | 220 vs 360 |
| **total** | **2/20 · 0/20** | **16/20 · 0/20** | **18/20 · 13/20** | |

**Skills work.** 2/20 to 18/20 is the entire design justified in one column: a
fragment in the prompt changes what the model does, reliably, on requests where
the bare agent does the wrong thing every time.

**And the index line is not a cheap fallback — it is most of the value.** One
223-character listing entry gets 16/20 where the full body gets 18/20. The
body's behavioural margin over a single line advertising it is *two responses
in twenty*, for roughly double the characters.

**What the body actually buys is specificity: 13/20 against 0/20.** The listing
carries the *instruction* and never the *rule*. Told only that a fragment about
destructive SQL exists, the model proposed the DELETE and declined to run it —
correct, and it did not ask for the primary-key predicate the body requires.
Told to read the per-step tasks, it read them; only the expanded arm knew to
look for the *first* task in a terminal state. That is the division of labour,
measured: **a description changes behaviour, a body makes it precise.**

**Consequence, and it reverses §11.3's conclusion.** The cost measurement said
the index is the one term that grows with the fleet and defaulted `index` to
`none`. That was the right reading of the cost and the wrong decision, because
it was made without the benefit side: per character, **the index is the most
efficient instruction-carrier in the whole design.** So `index` defaults to
`bound` after all, and the two measurements resolve into three rules rather
than one:

- **Index everything** — it is cheap per fragment and it is where most of the
  behavioural change comes from.
- **Expand few.** `top_k` should be 1–2, not 3. The body's marginal behaviour
  is +2/20 and its marginal cost is a body; it earns its place where the
  specific rule matters, and §11.1 measured that `top_k = 3` wastes two
  expansions per request before stickiness compounds them.
- **Write the description as an imperative.** This is now measured rather than
  stylistic. "When a LOOKUP returns nothing, use FUZZY LOOKUP instead of
  guessing another spelling" is a complete instruction in 96 characters, and it
  is what produced 5/5. A description written as a label — "about name
  resolution" — would have produced none of that, and the listing cap in §4 is
  the budget it has to do it in.

**Two things this probe also showed about itself**, kept because they are the
reason to read transcripts rather than tallies:

- **The first rubric was wrong, in the direction that flattered the spec.** It
  scored the index arm FAIL on the safety probe for an answer that said *"I will
  propose the DELETE statement for you to review and run yourself"* — the exact
  required behaviour, missed by a keyword list that had "run it yourself" and
  not "run yourself". One sample, read by eye, is what caught it.
- **Temperature 0 is not determinism.** `workflow-diagnose-failure`'s index arm
  passed on one run and failed on the next with nothing changed; at five
  samples it is 1/5, so the flip was variance around a genuinely low rate
  rather than a coin. Every cell above is five samples for that reason, and
  `safety-no-destructive-sql` expanded at 3/5 — *lower* than its own index arm
  — is the honest remainder: adding the body did not monotonically improve
  every probe.

### 11.5 Sticky expansion: the churn is real, and so is its price

Replaying the six-turn conversation (`skills_eval.yaml`), prompt size as a
percentage of expanding everything, turn by turn:

| turn | sticky | not sticky |
|---|---|---|
| 1 | 64.9% | 64.9% |
| 2 | 72.7% | 69.4% |
| 3 | 76.5% | 65.5% |
| 4 | 77.9% | 62.9% |
| 5 | 83.4% | 67.1% |
| 6 | 84.8% | 62.9% |

**The failure §5.3 predicted is visible in the right-hand column.** Without
stickiness the expanded set is *entirely different* on every turn — turn 2
expands three `p8ql-*` fragments, turn 3 replaces them with three `workflow-*`
ones, turn 5 swaps again. An instruction the agent was given on turn 2 is gone
on turn 3, with nothing reporting it. That is not a hypothesis about what could
happen; it is what the replay does.

**The price is 20 percentage points of prompt by turn 6**, and it is bounded —
`max_chars` caps the total, and the accumulation is monotonic, so the worst
case is the budget rather than the fleet. That is the trade §5.3 makes
knowingly: a fifth of the context in exchange for instructions that do not
silently disappear mid-conversation.

### 11.6 What building it taught the schema

- **A generated column cannot reference another generated column.**
  `aiq.register_lexical_source` builds its `search_tsv` over the registered
  content column, which here is the generated `discovery_text`, and Postgres
  refuses: *"cannot use generated column in column generation expression"*. The
  fix keeps both properties — `search_tsv` is generated from the three base
  columns directly and the registration's `add column if not exists` then finds
  it present — rather than demoting `discovery_text` to an ordinary column and
  reintroducing the drift generation exists to prevent.
- **`agentic.skills` needed no adaptation to become a corpus.**
  `aiq.semantic_in` joins its embedding space back to the source table on
  `c.id = e.chunk_id`; a table with an `id` is a corpus, and that is the whole
  contract. The `chunk_id` column name is a misnomer for this consumer and
  nothing more.
- **Registering both source kinds is worth it.** `skills` is a lexical source
  as well as a semantic one, so an agent's matching policy degrades to TEXT in
  a deployment with no embedding provider rather than degrading to nothing —
  and `aiq.search`'s RRF fusion becomes available for free to a deployment that
  has both. That fallback was hypothetical until it was the only arm that could
  run.
- **`apply_plugin` works on a real manifest.** 2 servers, 23 skills, 1 agent,
  one call, one transaction; re-applying with a fragment removed prunes it and
  reports it. The author-time checks fired as designed on the way in.

### 11.7 What this does not show

Stated plainly, because a partial eval reported as a complete one is worse than
none:

- **The behaviour probe is 4 probes and one model.** 20 samples per arm on
  `gpt-4.1-mini` is enough to separate 2/20 from 16/20 and nowhere near enough
  to separate 16/20 from 18/20 — which is precisely the comparison §11.4 leans
  on to cut `top_k`. A larger model may need the body less, or more; nothing
  here says which.
- **The rubric is keyword matching.** It is deterministic and defensible and it
  cannot see a right answer phrased unexpectedly — it already missed one, in
  the direction that flattered the spec (§11.4).
- **The fleet is 23 fragments, not a thousand.** The scaling claim in §6 is
  arithmetic plus a threshold sweep, not a measurement at scale.
- **The requests are written by the same person who wrote the fragments**,
  which is the standard weakness of a hand-built retrieval set. They were
  written as things somebody would type rather than as paraphrases of the
  descriptions, which helps and does not fix it.

## 12. Open questions

- **How much of this survives a better model?** §11.4's central number — the
  index line getting 16/20 where the body gets 18/20 — is `gpt-4.1-mini` at
  four probes. A model that follows a terse instruction more reliably narrows
  that gap and strengthens the case for `index: bound` with a small `top_k`; a
  weaker one widens it. The instrument takes a model name, and nobody has run
  it against a second one.
- **Is a fetched fragment followed as well as an expanded one?** §5.4 concedes
  it probably is not, and that concession is still judgement rather than
  evidence. Same instrument, one more arm — and now a sharper question than it
  was, because §11.4 showed the *listing* already does most of the work, so
  what the fetched path has to beat is one line and not nothing.
- **Should `min_score` scale with the fleet?** At 23 fragments, 0.28 gives 74%
  recall and no false positives (§11.1). A thousand fragments put far more
  candidates near any fixed cut, and nothing here says whether the right
  threshold moves, or whether `scope` carries that weight instead.
- ~~One tool per skill, or one `load_skill(name)` tool?~~ **Closed, and the
  answer is one tool.** The argument for one-per-skill was that a single loader
  would put us back to paying for an index in the prompt — but the index is
  already there deliberately (`index: bound`), and §11.4 measured it carrying
  16 of the 18 behaviour changes a full body does. It is not a cost this would
  add. So a loader costs nothing extra, and deferring N per-skill tools would be
  *worse* than listing them: the model would spend a round trip searching for
  what its own prompt already told it.

  The split that survives is by population, not by preference.
  **`load_skill(name)` for the attached surface**, which the index already
  describes — one tool, no name mangling, nothing generated per run. **Deferred
  loading for `scope`-based discovery**, where an agent may reach a table it
  cannot possibly list, which is the case `pydantic-ai`'s `defer_loading()`
  exists for and where one-tool-per-fragment is right because there is
  genuinely something to hide. An agent that sets no `scope` carries none of
  it.

  Applied to this spec's own proposal, the rule that every tool must earn its
  place removed a mechanism rather than adding one.
- **When does a skill become an agent?** A long procedure with its own tools
  and its own output shape is a delegated sub-agent wearing prose (`brief.md`
  §5.1 item 3), and the two are now adjacent enough that the choice is real.
  The current answer — a skill changes how *this* agent behaves, a sub-agent
  has its own conversation — is a distinction, but not yet a rule anyone could
  apply without arguing.
- **Skill dependencies.** A skill body that says *"first follow
  `p8ql-authoring`"* is a graph edge stored as a sentence. Left as prose
  deliberately, until something actually needs to traverse it.
