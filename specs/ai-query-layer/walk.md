# The durable iterative walk, V0 (REM-1244)

**Status: draft for agreement.** It merges the outline Sirsh agreed (M-20261029-105923-b725) with a review of the
walk's history (REM-1199 to REM-1240, part three of *Muddling Through*). Where the two disagree, §14 flags it rather
than choosing. Built today: §2's graph, §5's walk and §10's evaluation, in `walk.sql` and `walk-why.sql`. To build:
§3's edge information, §6's board, §7's judging, §9's structure and §11's oracle mode. Owner: mike. §3 is co-written
by cory and §10–§11 by sally.

## 1. Purpose

A query layer with a decision model inside it, and no LLM in the loop. The walk's only decider is Jev. It asks the
right questions of the data it reads, and so finds the data search alone does not.

An LLM is a client, outside the loop. It talks to the walk in exactly the two ways of §12: the walk raises a
semantic exception telling it to do something, or the walk returns a result it can interrogate.

## 2. The graph

**Nodes.** Documents (a history's exchanges, one `document` node per resource of a channel), terms (tag nodes),
claims, and questions (the walk's root and its sub-questions, §6).

**Links.** The walk follows four kinds, stored at index time by construction, never by a model (REM-1201):

| link | from a read d to | stored as |
|---|---|---|
| term | the documents that share one of d's terms, if at most `walk.cap` hold it | `walk_term`, `walk_tagged` |
| next | the documents within `walk.span` of d in its sitting | `walk_next` |
| near | d's `walk.near` nearest documents by meaning, and those that have d among theirs | `walk_nearest` |
| seed | search's order for a question | `walk_seed` |

**Bitemporal, closed and never deleted.** Every edge carries `valid_from`/`valid_to` and the time it was recorded.
A retracted edge is closed, never deleted (`aiq.edges_as_of`). `aiq.walk_graph(input, at)` loads the links as they
stood at a time. A walk reads the graph as of its own start, so any past walk can be replayed against the graph as it
was (REM-1199).

**What we know about it, measured not assumed** (REM-1204, BEAM 100K to 10M tokens):
- Every answer piece search misses lies within 2 lead hops of search's top 10.
- No piece hangs on a single hub.
- The first choice is about 90 leads, about 5 of them right (the offline study at cap 100). On the test database at
  cap 10 it is about 66, with 4 right.

V0 walks documents. Claims are nodes of the graph, but no lead runs through them yet (§14, F4: decided, out of V0).

## 3. Edges that say where they go (with cory)

A decider judges only what it is shown. Under `walk.describe = source`, a lead is described by the read it comes out
of. Every lead out of one read then shows the same text, and Jev is blind within a read: within-source AUC 0.549
(REM-1240). Shown the targets' own text, Jev's AUC rises from 0.644 to 0.768. That is the mean per-question AUC, waves 1–3, over
2,464 clues of 156 buried questions, each re-judged by Jev under several descriptions (REM-1204's recorded re-judge,
re-scored in REM-1240). REM-1240's step 3, the paired within-source re-judge of `lines`, is not yet in.

So a lead's description is assembled from information attached **at graph construction**, never computed per walk:

- **Each target's own line:** what the user said, the document node's summary, which ingest already stores.
- **Where each target sits:** same sitting and N exchanges away (`walk_next` provenance), or another sitting and D
  days away (`said_at`).
- **For a term, its specificity:** its posting count, from the graph's own postings.

**The open question** (outline item 3) is how much is cheap enough and still useful. It is answered on evidence.
Listing every target's terms biased the walk toward broad leads: under `targets`, P rose with bundle size, and the walk
spent its reads on wide bundles (REM-1240). So `walk.describe = lines` shows at most 3 targets, chosen by a hash of
the lead key, and `lines_nocount` drops the counts that cue width. REM-1240's step 3 settled which one V0 keeps: **`lines`**. On 300 mixed
sources its within-source AUC is 0.657 [0.611, 0.703] against `source`'s 0.548, which passes the registered bar. On
600 sources drawn from all of them it is +0.083 [+0.033, +0.128] over `source`, pooled and paired. `lines_nocount`
scores the same (−0.004 [−0.013, +0.006]), because the width cue is not the count: P rises with bundle size under
both, since a wide bundle shows three lines and a narrow one shows one. That is why opening by P per unread target
(§4) stays. The cost is $0 at ingest, because all of it is
stored, and about 40 tokens a target at judge time.

**What was weighed and left out, and why** (cory, REM-1240):
- **The target's search rank.** Free, but it is per walk, not ingest. On 1M:35 the six evidence exchanges only the
  walk found sat at search ranks 642–765, so rank argues against exactly the leads the walk exists for.
- **Place in its sitting.** Free, and on BEAM it separates evidence (AUC 0.74 / 0.70, inverted), but it measures
  BEAM's generator. BEAM's chunks keep a plan index (sitting n, step m), which tracks position at r = 0.86–0.99, and
  evidence falls in plan steps 1–12 (21–27%) against 6–8% after. No unplanned conversation has that schedule.
- **A model-written gist per exchange.** About $0.19 per 1M conversation. Not needed for V0: on 1M:35 eo:0, 27 of 27
  evidence exchanges name their aspect in the user's own line, none only in the reply.
- **The term in its target's context.** The term is already in the targets' lines for 46 of 49 term leads toward
  evidence and 879 of 929 away.

**What the information cannot fix.** On a question that names no aspect (event_ordering, probably summarization), the
high-P misses are as on-topic as the evidence: 143 of 1,031 non-evidence user lines name a rubric aspect. That limit is
in the question, not the edge. §7, Jev judging against the open questions, is what addresses it.

**Judging is not reach.** Better judging alone need not add evidence per read. Under `targets`, within-source AUC rose
to 0.643, and the walk landed no more fresh evidence (bill, REM-1240). The reach side is §4's opening by P per unread
target, and per-target opening (§14, F8).

**Built:** `walk.describe = lines` and `lines_nocount`, and `aiq.walk_clue_text(run, key, describe)`, which returns a
lead's text under any description (REM-1240, 39 of 39 database gates).

## 4. The walk

Seeded by search: the first `walk.seeds` of search's order are wave 0. It then moves in waves: each wave judges the
leads the last wave's reads raised, opens the best, and reads where they go, up to `walk.wave` reads, within a
budget of `walk.waves` waves. **The decider acts before the read**: a judgement after a read has already paid for it.
A lead is one link kind out of one read, toward the unread documents it reaches: `term:<t>`, `next:<d>`, `near:<d>`.

**Opening** is by P per unread target, not P alone, where a lead's P is its maximum over open questions (§7). With P
alone, a wide lead outranks a narrow one at the same P. In a one-step, matched-budget replay of the recorded queue,
ordering by P per unread read landed +1.04 fresh evidence per walk [+0.23, +1.98], +28% in aggregate (REM-1240). The
replay matched the walk's own picks only 36–46%, so this is direction and rough size. The width bias (under `targets`,
P rose with bundle size) is checked again under `lines`, which still states counts, in REM-1240's step 3.

## 5. Durable, keyless, append-only

- **Durable.** A walk is a workflow run, and every step is a task row (REM-1210). A crashed walk resumes where it
  stopped and redoes nothing (REM-1236).
- **Keyless.** A walk is started with `{"question": {"node_id", "text"}}` and nothing else; `walk_start` refuses
  more (REM-1231). Every move is a decider's judgement, recorded in the run's rows. The answer key enters only in
  §10–§11. The key is never **stored** in the database either: not as labels, not as a question node's
  answer or rubric, not in any metadata. A loader that copies a question's fields must leave the key out (cory's
  REM-1238 fix: `gold`, `answer` and `rubric` stay in the sample's file). A database is checked with
  `select count(*) from content.resources where uri like 'question:%' and (metadata ? 'answer' or metadata ? 'rubric')`,
  which must be 0.
- **Append-only.** A completed task row is never rewritten. A kept walk's verdicts and board are new resources
  (`aiq.walk_keep`), dated. What a walk did is recomputed from its rows and from the graph as of its start
  (`aiq.walk_state`), so it is exact, not a model's second opinion.
- **Replayable.** A run given `replay` takes its P values from a kept verdict document and asks Jev only for the rest,
  and `offline` asks nobody. A rerun costs nothing.
- **Every number and wording is a row of `aiq.parameters`**, with what it controls and why, never a literal.
  The table is bitemporal and append-only: a change closes the old row (`valid_to`) and adds a new one, and
  `aiq.walk_settings` reads the defaults as of the run's start. So an old run replays under the defaults it started
  with, and a query test proves it (REM-1245).

## 6. The question stack: the investigation's board

The user's question, which the decider splits, answers and adds to as evidence comes in. Evidence is linked to the
questions it answers, as a bipartite graph built from existing nodes, edges and runs. It needs no new table.

- **Questions.** The root is the walk's question node. A sub-question is a node of entity type `walk_question`
  (summary: its text), with a `walk_part_of` edge to its parent. Each question is `open`, or closed for one of three reasons, each recorded as its own: `answered`, `stale` or
  `displaced` (move 4). Only `answered` counts as an answer, on the board and in any report.
- **Evidence.** A read the decider judged to bear on a question gets a `walk_answers` edge, read → question, with
  provenance `{run, wave, P}`.
- **Ids.** Questions are named `root`, `part:<term>` (an in-loop split) or `client:<n>` (a split returned by a
  client, §12).
- **Verdict keys**, in the run's answers and in `aiq.walk_verdicts`: `L|<q>|<lead>` (a lead for a question),
  `A|<q>|<read>` (an assessment), `S|<parent>|<term>` (a split candidate), `C|<q>|<count>` (a close judgement, keyed
  by its evidence count). So a replay replays the board as well as the leads (§14, F2).
- **Moves.** Each wave's moves are the output of that wave's `stack` task: `split`, `answered`, `added`, and `open`
  after them, each with Jev's P. Nothing else writes them. `aiq.walk_keep` materialises the nodes and edges when a
  walk is kept. A walk in flight writes only its task rows.

Each wave, after its reads:

1. **Assess.** For each new read and each open question, Jev gives P that the read answers it or part of it, shown
   the read's own line. A read gets a `walk_answers` edge to the question only if it is among the top
   max(`stack.close_min_links`, ⌈`stack.link_share` × reads assessed so far⌉) reads by P for that question **and**
   its P is at least `stack.link_floor` (0.5) (F10, F14). The max fixes a rule, not a value. With `link_share` alone, fewer
   than 100 assessed reads keep one link while close needs two, so close could never be asked early (REM-1245: three
   of five test walks linked exactly one read, and two read their whole answer by 50 reads yet walked to 500). Rank, not a fixed gate, because Jev's P sits on a
   different scale per question. Measured on recorded walks, Jev picks out
   the labelled evidence among reads at AUC 0.745 [0.690, 0.799] (oracle-scored, REM-1240). It is loose at 0.5:
   83% of evidence reads clear it, and so do 56% of others.
2. **Split and add, in the loop.** In V0 a part is opened only under the root, so parts never nest. The candidates are
   the root plus an aspect, "the part about '<term>'", for the terms the most reads linked to the root share (at least
   two), ties broken by specificity, among terms no open part names. The rarest term of each linked read is not used:
   on a live walk (1M:22 msr:1, REM-1245) it filled every slot with variants of one aspect ('200 budget', 'afford',
   '100 budget') by wave 3, and the question's other aspects never got a slot. Jev gives P that the candidate is a part
   of the root a complete answer needs. Open at most `stack.max_open`. When the slots are full, a candidate with higher P replaces the weakest
   open part that has no links of its own yet, at most `stack.max_displace` (1) a wave. The replaced part closes
   `displaced`, recorded with its P, not deleted, and its leads are kept (F11).
3. **Split, outside the loop.** When Jev judges the root a blend of separate questions (semantic exception `DECOMPOSITION_REQUIRED`,
   §12), the walk *raises* it to the client with the prompt "split your question up". An LLM client's sub-questions
   come back as `added` moves with `by: client`, recorded like any other. The walk never calls the LLM.
4. **Close, by structure, never by a holistic judgement** (Sirsh, 13:15Z). Jev is never asked whether a set of
   messages together answers a question. That is not its job.
   - **A leaf question closes on one line.** A leaf is a question with no open parts. Once it has at least
     `stack.close_min_links` (2) links, its candidate lines are judged one at a time, each with its date: its links plus
     every assessed line above `stack.link_floor`, either direction of time, capped at `stack.evidence_lines` (12),
     highest P first (F13). For each, Jev gives P that "this line answers this question" (`decider.task_state`, one
     row). The leaf closes `answered` when a line clears `stack.state_gate`. When clearing lines conflict in value,
     **the newest is the answer** and the older ones are kept as its history, so a contradiction keeps both sides.
     **Newest wins after closing too:** reads go on being assessed against answered leaves (no leads are judged for
     them), and a later-dated line that clears the gate replaces the answer. Leads toward an answered leaf still fall away, so a
     later update is caught only if it is read for another reason. That is a stated limit: on a knowledge_update
     question, an old value read first can close the leaf in wave 1, and the update may never be read (class 4).
     Reason: supersession is a property of the record, not of when the walk closed (bill, 13:19Z).
   - **A parent closes by structure, with no Jev call.** When every child is closed, it closes `answered` if all of
     them are answered, and `partly answered` if some are stale, with the answered and the stale parts listed. A
     partly answered close is never reported as an answer. If every child closed stale and none answered, the parent closes `stale`. The root is a parent once it has parts. A root with no parts is a
     leaf.
   - **Narrowness is the board's job.** A question is narrow enough when one message can answer it. Whether the root
     is broad is **structural and keyless**: if no line clears the root by wave `stack.broad_after` (2), the walk
     raises `DECOMPOSITION_REQUIRED` (§12) to the client, once, and keeps splitting in the loop from the aspects its
     reads name (move 2). There is no Jev call on the root's words. The catalogue's check asks whether a question
     *combines distinct parts*, which a set question such as "how did my focus evolve" does not. Its measurement is
     thin (threshold 0.95, F1 0.76 on 12 positives), and a new wording would be an unmeasured judgement with its own
     gate to calibrate (bill, 13:19Z). Until it has
     parts, a broad root is not closed by any line.
   - **When a sub-question cannot be made narrow enough.** A question whose answer is a set or a count over an
     unknown number of messages ("how did my focus evolve…", "how many different activities…", a summary) has no
     single message that answers it. Splitting gives one part per aspect found, and each part can close on one line.
     But the walk cannot know the set is complete, so such a parent never closes `answered`. It ends `partly
     answered`, `stale` or at the budget, and the board reports the parts it has answered. That is a stated limit, not
     a failure. Set or count questions are detected only by Jev's cardinality decision on the question's words (§14), never by
     BEAM's type, which the walk must not know; until its gate is set the walk does not detect them. It reports what it has (answered, partly answered, stale, budget), and the evaluation, outside the walk,
     reports results by BEAM's type (bill, 13:19Z).
   - Stale (`stack.stale_waves`, 2) and displaced parts free their slot, never count as answered, and **their leads do
     not fall away**; otherwise a stale close would be a new source of §10's class 4. Every close keeps its edges. Each
     threshold is an `aiq.parameters` row with its reason.

   **Why the earlier step asked the holistic question (postmortem).** Three causes:
   1. **There were no narrow questions to close.** In-loop splits are templates that open only once aspects appear in
      reads, and on many walks none opened. The holiday walk stayed root-only. So close had to judge the root itself,
      and the only question available was the holistic one.
   2. **Close was modelled on an answer-checker, not the board.** The design asked "is q answered by these lines?",
      borrowing an LLM's habit of checking an answer, where the board already holds the structure that answers it:
      parts and their evidence.
   3. **The whole-or-part fix kept the root's holistic judgement** ("Jev says the root is answered"). It narrowed the
      lines and left the question broad.

   The measured cost: close P separated asks holding labelled evidence at only AUC 0.622, and closed once in ten,
   wrongly (§14).

Why: a memoryless walk judges every lead against the original question alone and fixes each P when the lead is raised
(REM-1240, `aiq.walk_requests`).
- **What it misses most is which reads were evidence.** A term lead out of a read that is itself evidence is about
  12 times as likely to lead to more (odds ratio, oracle-scored), yet Jev gives it about 0.04 more P.
- **A list of reads does not carry it.** Closeness to the reads so far predicts rightness at only 0.54–0.60. What
  carries it is the reads the decider judged as answering a question.

## 7. Jev judges each lead against the open questions only

For each live lead and each open question, Jev gives P that following the lead serves that question. It is shown:
- the lead's description (§3);
- one line of board state: "It comes out of a message found to answer: '<q>'". It is fixed once the source read is
  assessed, so a (lead, question) verdict is never asked twice. A lead out of a read that answered nothing carries
  no state line.

The lead's P is the maximum over open questions, and the question it serves is recorded. A lead is judged once,
when it is raised, against the questions open then, and its P stays fixed (Sirsh, F3: re-judging open leads is
measured later, not in V0). A question raised later is served by the leads raised after it. Leads raised
only for questions since answered fall away, which is what cuts the noise Jev has to consider.

**Cost** (under F3, each judgement asked once). A wave judges (new leads × questions open when they are raised) +
(new reads × open questions) + split candidates + one close judgement per open question with new evidence. A
500-read walk raises about 2,000 leads (REM-1240). With at most `stack.max_open` = 4 open questions, that is at most
about 8,000 lead judgements and 2,000 read assessments, at about 150 input tokens an option in batches of 60: about
1.5M tokens, about $0.06 of Jev a walk at $0.042 per million. Today's memoryless walk is about $0.015.

## 8. When a walk stops

The first of these, recorded by the run's `stop` (Sirsh, F1):

- **stack empty:** the root is closed, `answered`, `partly answered`, or `stale` when every part closed stale and none
  answered (move 4), and the stop records which;
- **budget:** `walk.waves` waves, or the read budget, are spent;
- **dry:** no lead points at anything unread, and search is exhausted;
- **cold:** the last wave accepted none of the leads it raised **and** no accepted lead is still open: `walk_audit`'s
  certificate (REM-1211) as a stop. A walk with accepted leads still unopened keeps going.

**As built, two limits** (REM-1244, from the code, 29 Oct):
- **Cold stops only a stack walk.** The code applies it only under `walk.stack`. A plain walk has no cold stop and
  reads on to its budget, through its open leads and search's order. In the pilot that is where S − P comes from.
  Past S's own stop, P found 16 more labelled pieces, 14 of them through its leads.
- **A root with no parts never closes in V0.** It is a leaf, and with `stack.state_gate` unset no line closes it.
  So "stack empty" cannot stop a walk that opened no part, and such a walk ends at the budget, dry, or cold.
- `stack.close_gate` (0.7) is **unused in V0**. It belongs to the holistic close this section retired. `walk_stack_next` fetches it and no
  code reads it. Its row is marked unused, or removed, in the first percolate change after tonight's release.

## 9. The walk structure: a first-class queryable object

Everything a person, a UI or an LLM sees of a walk comes from these functions over the run's rows, through the query
layer. A UI assembles nothing of its own.

| query | returns |
|---|---|
| `aiq.walk_structure(run)` | the whole object below, one jsonb |
| `aiq.walk_graph_stats(run)` | documents; links by kind; leads per read (median, max); term postings against `walk.cap`; the share of the scope within 1 and 2 hops of the seeds |
| `aiq.walk_stack(run)` | the board after each wave: questions (text, parent, state, opened and closed at), `walk_answers` edges (read → question, P, wave) |
| `aiq.walk_waves(run)` | per wave: reads, judged, accepted, open, total reads (exists) |
| `aiq.walk_clues(run)` | every lead: kind, source, targets, P, decision, state, the question it serves (exists; gains the question) |
| `aiq.walk_reads(run)` | every read: wave, document, the lead or search that brought it (exists) |
| `aiq.walk_summary(run)` / `aiq.walk_audit(run)` | the stop and its reason, keyless (exist) |
| `aiq.walk_runs` | how walks relate: the question node, the replay it reads, the run it controls (exists) |

`walk_structure` is these, plus counts: questions open and answered, evidence edges, reads by source, Jev calls and
tokens.

**Cost is an observable of the walk structure** (Sirsh, 14:43Z). `walk_structure(run)` reports, from the run's own
task rows (each decider task records the model and its input and output tokens as Jev returned them), no new table:
- Jev requests, input tokens, output tokens and dollars, for the walk, per wave, per move (judge, assess, split,
  close; a move with no Jev call, such as V0's structural close, reports zero) and per open question;
- the price per input and output token as an `aiq.parameters` row (`decider.price_in`, `decider.price_out`, dollars per million
  tokens, with their source and date; under the existing `decider` part, so no live table changes), read as of the run's start like every default, so an old run keeps the price it
  ran at;
- with oracle labels (§11): evidence found per dollar, and coverage against cost at 50, 100 and 500 reads beside
  search (no Jev cost) and the oracle ceiling. Budgets nest, so the cost at 100 reads is that of the run's first 100
  reads, not a separate walk.

## 10. Evaluation, outside the walk (with sally)

There is no answer key in the walk. The key enters only here, and every figure it colours says *oracle-scored*:

- `aiq.walk_coverage(run, nodes, budgets)`: a generic coverage measure, the evidence read by each budget, beside
  search's own order at the same budget;
- the **oracle ceiling**: the oracle decider (§11) on the walk's own graph, seeds and budget;
- `aiq.walk_why(run, nodes)`: for each missed piece, why.

**A miss is attributed to the data if an omniscient reader on the same graph would have missed it too; otherwise to
the implementation** (sally's revision). Each miss is shown with the real lead. A miss is a piece the walk did not
read, or read but did not link to a question.

**The omniscient reader** is the oracle (§11). It has the same graph, seeds and read budget as the walk and knows the
answer key, and nothing else. Its reads at each budget are the **ceiling**. The ceiling is a perfect opener with no
board: a reader who knows the key needs no stack to open the right lead. Stack failures are located piece by piece by
classes 4 and 8, not by a second ceiling (§14, F7).

For each piece, the first class that holds is its class:

| # | class | holds when | means | fix lies in |
|---|---|---|---|---|
| 1 | data: unreachable | no lead path from the seeds reaches it | the graph does not connect it | ingest, links |
| 2 | data: beyond the ceiling | the oracle does not read it within this budget either | the budget, not the walk | budget |
| 3 | data: indistinguishable | shown everything the page holds (§3's fullest description: the target's whole text), the decider rejects it as often as the look-alikes around it, and the look-alikes outnumber the evidence | a reader without the key could not tell it from the messages around it; only the benchmark's rubric does | nothing in the walk: a stated limit of the question |
| 4 | implementation: closed early or on superseded evidence | the question it answers was closed (§6, move 4) before a lead toward it was opened, and that lead then fell away; or it was closed on an earlier statement while a later one that supersedes it was read and not linked, or linked and ignored | the board closed too soon, or on the wrong value | `stack.state_gate` (unset in V0), the link rule, the one-line close judgement |
| 5 | implementation: never offered | the oracle reaches it, but no lead the walk raised pointed at it | the walk's reads went elsewhere earlier | opening order, seeds |
| 6 | implementation: rejected | a lead toward it was judged under the gate | judging | §3's description, or the decider |
| 7 | implementation: open, not read | a lead toward it was accepted but never opened | queue | opening order (§4), budget |
| 8 | implementation: not linked | it was read, but the decider linked it to no question | assessment | §6, move 1 |

- **Where the classes come from.** Classes 5–8 are `walk_why`'s reasons (REM-1211). Class 4 needs a new `walk_why`
  reason, read from the board's close moves. All are computed per piece beside the oracle's reads.
- **Rejected (6) splits by what the decider was shown.** The lead is re-judged with the fullest description. Accepted
  then means the description was missing what was needed: an edge-information failure (§3). Still rejected, and not
  class 3, means the decider could not tell even shown everything: a decider failure.
- **Class 3's test is keyless on the page side.** The key says which piece is evidence. Whether a reader could tell
  uses only what is on the page: the decider's P under the fullest description, for the piece against the k messages
  nearest the question. On BEAM look-alikes are common. A median event_ordering question has about 345 non-evidence
  messages at least as close to the question as the median evidence piece, against about 28 evidence pieces
  (REM-1240). So class 3 is expected to be large there, and small on questions that name their subject.
- **Reporting.** Every walk result is reported as these eight counts, oracle-scored. A result is not "the walk missed
  12%". It is how much of the 12% was data and how much was implementation, and of the implementation, which part.
  Oracle mode shows the same eight classes and nothing else.
- **The label set over-labels.** "Complete" means every labelled piece read, but BEAM labels some pieces the answer
  does not need. On 1M:35 tr:0 a walk closed correctly after 10 reads with the answer (10 days) fully in its links,
  while one labelled piece, 574 ("tips for managing a team of helpers"), holds no date. So beside every coverage and
  close figure, each walk lists its unread labelled pieces that carry no part of the reference answer, judged from
  their lines and quoted, so a reader can check. That separates "stopped early" from "the key over-labels". It is a
  data-side note, not a ninth class.
- **The key can be superseded, or not state its own answer.** These are two more named data-side reasons, reported
  the same way. Sally classified all 19 BEAM knowledge_update keys available (REM-1247, $0, quoted line by line):
  - **consistent:** 11.
  - **(B) no labelled user line states the answer:** 4 (1M:11 ku:0 and ku:1, 1M:6 ku:1, 1M:35 ku:1), plus 1 unclear
    (1M:24 ku:0).
  - **(C) superseded after the key, a later line giving a different value:** 1 clear (1M:35 ku:0: "December 17th" said
    November 15th, then "December 10th" on December 7th and "by December 20th" on December 14th), 1 likely (1M:21
    ku:1), 1 arguable (1M:30 ku:1).

  That is 7–8 of 19. It is not one rule of BEAM's: 11 keys label the update as well. The check reads user lines
  only, so (B) means no labelled *user* line states the answer; the assistant's half may hold it. Every
  knowledge_update result is reported beside its key's class. **A walk result without this breakdown is not
  reported as a result.**

Measured so far: on BEAM 1M:22 and 1M:35, the oracle reaches 94/100/100% of the evidence by 50/100/500 reads, and
search's own order 52/67/88% (REM-1204).

### How V0 is judged: statistically, against search

V0 is judged against search, statistically, across many questions of varied difficulty and across data-set sizes.
A handful of walks is never the verdict.

- **Questions:** every type, many of each. Difficulty is stratified by where search leaves the evidence (all in its
  top 10; within its top 50; beyond it) and by how many lead hops the evidence lies from the seeds.
- **Sizes:** BEAM's 100K, 500K, 1M and 10M histories, so the claim is how the gap over search grows with the
  history, not one point.
- **The measure:** §10's coverage at matched budgets (50/100/500 reads), as the paired per-question difference from
  search's own order. That is reported with a bootstrap interval over questions, beside the oracle ceiling and §10's
  eight-class breakdown. For questions search already answers (§15), it also reports close and stop.
- **The sweep, registered before it runs** (REM-1244, bill's 12:36Z). The sample is drawn from BEAM's own question
  ids, every type except abstention, which has no evidence to walk to:
  - at 100K, 500K and 1M, 10 questions per type, from that size's ids sorted, by
    `random.Random(f'1246:{size}:{type}').sample(ids, 10)`;
  - at 10M, every non-abstention question (180).
  - The data is pinned: 100K, 500K and 1M from `Mohammadta/BEAM` at revision 3205395e; 10M from the separate
    `Mohammadta/BEAM-10M` at revision 9b209619 (two shards); each file by its sha256 (james, REM-1245).

  That was 450 walks; the 270 at 100K, 500K and 1M are **on hold** (Sirsh, 14:40Z: about 6¢ a walk is too much for
  what it would show). 10M is out of V0, a stated limit and a follow-up. What runs instead is the pilot below.
- **The two-arm pilot, registered before it runs** (REM-1244; bill, M-20261029-144111-9155 and -144330-5a51, after
  sally's review).
  - *Questions:* 40 of the registered 1M draw, by `random.Random(1252).sample`, disjoint from every question walked
    so far and from the 18 calibration questions. They are, fixed now: 1M:12 tr:1, 1M:13 pf:1, 1M:13 summ:0, 1M:19 msr:1, 1M:19 summ:1, 1M:20 cr:0, 1M:20 if:1, 1M:20 tr:0, 1M:21 cr:1, 1M:21 msr:1, 1M:23 eo:0, 1M:25 eo:0, 1M:25 ku:0, 1M:26 cr:1, 1M:26 if:1, 1M:26 pf:0, 1M:26 tr:1, 1M:27 summ:0, 1M:28 eo:0, 1M:2 if:0, 1M:2 msr:1, 1M:2 tr:0, 1M:30 pf:1, 1M:31 msr:1, 1M:31 tr:1, 1M:32 eo:1, 1M:32 ie:1, 1M:34 cr:1, 1M:34 summ:0, 1M:34 summ:1, 1M:35 ie:0, 1M:3 msr:0, 1M:4 ie:1, 1M:4 msr:0, 1M:5 eo:0, 1M:5 eo:1, 1M:7 msr:1, 1M:7 tr:0, 1M:9 ie:1, 1M:9 msr:1.
  - *Arms:* **S**, V0 as designed (`walk.stack` on, committed defaults, `lines`, `per_target`, `stack.state_gate`
    unset); **P**, the plain walk (`walk.stack` off, `lines`, `per_target`). F8, clusters and cardinality are off in
    both. Search's own order and the oracle ceiling are free and shared.
  - *Pairing:* both arms run each question on the same seeds, the same graph and the same commit, named before the
    first walk. So the per-question difference S − P is the stack alone, and S − search is V0 against search.
  - *Probe before the batch* (bill, 15:36Z): one walk of each arm runs alone first. The first probe ran arm S only,
    and arm P then failed every walk on the 64 KB request cap. The run of record is image 42d61547 with the walk SQL
    from 34f7c80a applied, both arms from scratch on that build. The 6 S walks from before the fix are kept and not
    scored, so both arms are scored only on the build they share.
  - *Endpoint:* coverage of the labelled evidence at 100 reads, oracle-scored, as a paired per-question difference
    with a 95% bootstrap over questions (2,000 draws, seed 1251). 50 and 500 reads, and the burial strata by best
    search rank (top 10, 11–50, 51–200, beyond), are descriptive.
  - *S against search:* GO to 100K and 500K if the interval's lower end is above 0; stop, and report the walk as not
    beating search at 1M, if its upper end is below +5; otherwise extend to 80 questions once and apply the same two
    rules, and if neither holds, report "no difference detectable at 10 points" and stop.
    The two rules overlap on an interval wholly inside (0, +5), settled before any data (mike, 15:58Z): the walk
    read more of the evidence than search at 1M, by between the interval's lower and upper ends, in points at 100
    reads (95% interval, 40 questions); the document says that, never 'beats search' alone, which claims more
    than the interval allows (sally, 15:57Z). It does not go to 100K and 500K,
    since that stage is powered for 10 points and would not resolve a gain under 5, and the document says so: no claim
    about 100K or 500K, which were not run.
  - *S against P, all three outcomes stated now:* (i) the interval lies wholly below +5: V0 ships with the stack off
    by default, recorded as measured; (ii) its lower end is above 0: the stack stays on; (iii) it spans both: the
    stack is **off** by default, as an opt-in the board still shows, since it costs more Jev with nothing measured for
    it. (ii) and (i) can both hold (an interval inside (0, +5)); then (ii) wins (bill and sally, 14:50Z): an interval wholly inside (0, +5) is a measured gain, if smaller than
    5 points, and keeping it costs about $0.006 a walk (about 40% more Jev), so the stack stays on by default.
  - *Before scoring, not before running:* 1M:25 ku:0 is a knowledge-update question whose key was not among the 19
    checked. Its key is checked against its conversation first (§10's key groups), and if it falls in group B or C it
    is scored both ways.
  - *Cost:* about 40 × ($0.020 + $0.014) = $1.40 at 500 reads, restated from the rows (§9's cost) before it starts.
    The 100K and 500K stage runs only the arm or arms the pilot keeps. At most 10 walks at once.
  - *Expectation, said up front:* on what is measured (walk − search from −8 to +7 points, sd 22–31), a null at 10
    points is the likely outcome for S against search, and outcome (iii) for S against P.
- **The pilot's result** (REM-1244, 29 Oct, 80 of 80 walks, image 42d61547 with 34f7c80a's walk SQL, the oracle and
  walk_why read after 42a1a5ee and ed0caa58; oracle-scored; Jev $1.44: S $0.854, P $0.584). Coverage of the labelled
  evidence, mean over 40 questions, with paired differences in points and 95% bootstraps:

  | reads | S | P | search | oracle | S − search | S − P | P − search |
  |---|---|---|---|---|---|---|---|
  | 50 | 55.0% | 55.0% | 54.9% | 69.7% | +0.2 [−5.4, +6.0] | −0.0 [−0.2, +0.2] | +0.2 [−5.4, +6.1] |
  | **100** | 65.2% | 66.2% | 60.8% | 93.6% | **+4.4 [−1.7, +11.7]** | **−1.1 [−3.1, +0.2]** | +5.5 [−0.1, +12.7] |
  | 500 | 83.0% | 85.3% | 80.3% | 97.5% | +2.7 [−2.3, +7.0] | −2.3 [−5.3, +0.1] | +5.0 [+1.6, +8.7] |

  - *S against P: outcome (i), registered.* The interval lies wholly below +5, so **V0 ships with `walk.stack` off by
    default**, as an opt-in the board still shows, recorded as measured. Why the stack loses ground: it stops on its
    own (7 of 40 S walks before 100 reads; 306 reads on average against P's 500), and on 1M:3 msr:0 it stopped at 50
    reads with 2 of 3 pieces, where P and search held all 3. What the stop bought: at S's own stop, S holds 83.0% and
    P at the same read count 82.4% (+0.6 [−0.2, +1.4]), for $0.0028 per labelled piece read against P's $0.0012. The
    stack judges each lead against its open questions, so it costs more per read, and its stop saves less than that.
  - *S against search: "extend to 80", registered.* The interval spans both rules. Where the gain sits, by burial
    stratum at 100 reads (descriptive): top 10, n = 30, +3.3; 11–50, n = 4, −11.1; 51–200, n = 3, +29.7; beyond 200,
    n = 3, +11.1. On 30 of the 40 questions search already holds the evidence in its top 10, and the walk ties
    there. The walk's gains come from the buried few. S beats search on 8 questions, loses on 8 and ties on 24.
  - *Room left:* the oracle reads 93.6% by 100 reads on the walk's own schedule, against the walk's 65%. On the
    failures, the leading reason a labelled piece stays unread is `open`: a lead that cleared the gate and was
    never opened within the budget (class 7). The gate accepts more than the budget opens, and P does not rank
    among the accepted.
  - *1M:25 ku:0's key, checked before this result was used:* group A. Exchange 488 states the key's 48 beta sign-ups
    by 19 May, updating 386's 45. The later counts (518: 75 new beta users in the week after launch; 120 and 350
    active users) count other things. It is scored once, and dropping it moves S − search by +0.4.
- **The extension, registered before any of its walks runs** (bill, M-20261029-173346-4c41, amended after sally's
  review). After outcome (i) the walk V0 ships is P, so the extension runs P only.
  - *The confirmatory result is P against search on the new questions alone,* at 100 reads, under the same three
    rules: GO (to 100K and 500K) if the 95% interval's lower end is above 0; NO-GO if its upper end is below +5; an
    interval inside (0, +5) is reported in the small-gain wording; otherwise "no difference detectable at 10 points",
    and it stops there. P's first 40 were seen before P was chosen, so choosing P and then pooling them would be a
    forking path. The pooled 79 questions are **descriptive only**.
  - *S against search is reported as stopped at n = 40,* with its interval: +4.4 [−1.7, +11.7].
  - *Questions:* `random.Random(1253).sample(sorted(rest), 40)`, where `rest` is the 50 of the sweep's 1M draw of 90
    left after the pilot's 40 (the pilot's 40 reproduce exactly from the same code). One drawn question, 1M:8 summ:1,
    has no labelled evidence in BEAM, so it cannot be oracle-scored. It is dropped and not redrawn, which leaves 39. The drop selects on whether a question has labels at all, never
    on an outcome (sally, 17:43Z). The 39 are:
    1M:10 cr:0, 1M:10 eo:0, 1M:11 ku:1, 1M:11 tr:0, 1M:12 ie:1, 1M:12 if:1, 1M:13 msr:0, 1M:14 pf:0, 1M:15 ku:0, 1M:15 ku:1, 1M:16 cr:0, 1M:17 ie:0, 1M:18 ie:1, 1M:19 if:0, 1M:1 if:0, 1M:20 cr:1, 1M:20 eo:0, 1M:20 pf:1, 1M:21 if:0, 1M:21 tr:0, 1M:22 summ:1, 1M:26 ku:1, 1M:26 pf:1, 1M:27 eo:0, 1M:29 ku:1, 1M:2 ie:0, 1M:30 if:0, 1M:31 pf:1, 1M:32 pf:0, 1M:34 if:1, 1M:34 ku:0, 1M:34 ku:1, 1M:35 pf:1, 1M:35 summ:1, 1M:3 tr:1, 1M:5 ku:1, 1M:6 summ:1, 1M:7 ie:0, 1M:8 cr:0.
  - *Build and arm:* the pilot's database and commit (image 42d61547 with 34f7c80a's walk SQL), not 0.2.35. P is set
    explicitly: `walk.stack` false, `lines`, `per_target`, on the pilot's seeds. One walk runs alone as a probe, the
    batch stops on its first failure, and the spend is read from `walk_cost`, about $0.015 a walk (about $0.58).
  - *Conversations:* 16 of the 39 sit in 12 conversations the pilot did not load (1M:1, 6, 8, 10, 11, 14, 15, 16, 17,
    18, 22, 29). They hold about 12,500 exchanges, so the database grows by about 0.7–0.8 GB (by the pilot's own
    1,347 MB for 22,745 exchanges). Their pieces are embedded by the stack's worker, which costs no Jev.
  - *Reported beside the result, not part of its rule* (sally and bill, 17:56Z). About half of every walk's reads
    are search's order by design: from wave 2 each wave takes `walk.per_wave` of search's next documents first, and
    the walk falls back on search when its accepted leads run out. So P − search is partly search against itself.
    For each question at 100 reads: the labelled pieces P read through leads and through search's order (from
    `walk_reads`' via), the same split for the oracle, and P − search counting the walk's lead reads only. If P's
    lead over search comes mostly through the fill, the document says so. In the pilot's 40, P's labelled pieces by
    100 reads came 86 through leads and 83 through search.
  - *Keys:* 8 of the 39 are knowledge_update questions. Each key is checked against its conversation before
    scoring, and one in group B or C is scored both ways.
- **Walks of one question each** are diagnoses. The five walks the board's rules were found on, and the fresh
  registered set, exist to catch faults and to explain them with real leads. They are never evidence that V0 beats
  search.

## 11. Oracle mode

A mode of the structure in §9, not of a UI. `aiq.walk_oracle(run, nodes)` computes it, and
`aiq.walk_structure(run, oracle => nodes)` returns §9's object plus
what a normal walker cannot see, every part marked `"oracle": true`:
- the labelled answer set;
- which reads were evidence;
- the ceiling's reads at each budget;
- §10's class for each miss.

**Per labelled piece, when the walk could have had it** (cory, from Sirsh's 12:27Z note):
`aiq.walk_structure(run, oracle).oracle.timeline`, one entry per labelled piece (built, REM-1245):
- `first_offered_wave` and `first_offered_lead`: the first wave a lead whose targets held the piece, still unread, was
  judged;
- `first_accepted_wave`, `first_accepted_lead` and `first_accepted_p`: the first wave such a lead cleared the gate;
- `read_wave`, `read_ord` and `read_via`: when the walk read it, and by which lead or by search; null if never;
- `wait` = `read_wave` − `first_offered_wave`, null if never read.

On the ladder retest, 266 was offered and accepted at wave 2 (`next:261`, P 0.79) and never read: class 7.

A late read after an early offer is a judging or opening miss: offered but never accepted names the P that kept it
shut. A late offer is distance. This refines §10's classes 5–7, and the UI draws it without arithmetic of its own.

Without `oracle`, the object is exactly what the walk knew. **The oracle decider:** same graph, seeds and budget; from
the live leads it opens the one with the most unread evidence per target, else the one nearest unread evidence by
reverse distance. It knows the key and nothing else. It reads wave by wave as the walk does (REM-1245): reads
reach wave × `walk.per_wave`, from wave 2 it takes `walk.per_wave` of search's next unread documents first, and a
lead is live only from the wave after the read that raised it. So it is a ceiling for this walk's schedule, not for
any order of reads. Built as `aiq.walk_oracle(run, nodes)` (REM-1245, about 5 s a walk); `walk_structure(run, oracle).oracle.ceiling.evidence_by` gives oracle, walk and search side by side at 50/100/500.

## 12. The LLM interface

Percolate talks to an LLM in exactly two ways:

- **(a) Semantic exceptions.** The walk tells the model to do something. Each exception is a code, its evidence, and a
  prompt the model reads (percolate-core `semantic_exceptions`):
  - `DECOMPOSITION_REQUIRED`: the question blends separate parts; split it into sub-questions, which come back
    as §6.3 moves;
  - `LOOP`: rounds keep opening questions and find nothing new;
  - `CONVERGED`: nothing new to find;
  - `FACET_UNANSWERED`: an open question the walk could not find evidence for, at the stop.

  Detection is Jev's or structural, never an LLM's.
- **(b) Query results that carry the means to interrogate.** A walk's answer is its evidence plus the handle to §9's
  structure: the run id and the named queries above. A client can ask why a piece was read, which question it
  answered, what is still open, and what was rejected.

## 13. Kept from the walk's history

Each of these exists, is used by part three, and stays in V0 unchanged:
- **The certificate** (cold, REM-1211).
- **Near misses** (`walk.near_miss`, off by default, REM-1207).
- **Verdict memory** (`walk.memory`, `walk.memory_as_of`, REM-1232).
- **Replay and offline** (REM-1199).
- **Blind controls** (`control_of`, part three's blind walks).
- **The two clocks:** valid time and known time, the walk as of a past start (part three's time step).
- **Search scoped to the walk's channel.**
- **The graph kept as a document** per scope and version (`walk_index`).

## 14. Decided, and still open (Sirsh, M-20261029-111419-ebca: keep V0 minimal, change one thing at a time)

Decided:
- **F1, stops.** Keep dry and cold as recorded stop reasons, beside stack-empty and budget (§8).
- **F2, memory.** Key kept verdicts by lead and question node, so a verdict made against an old question is never
  reused (§6's verdict keys).
- **F3, re-judging.** No re-judging of open leads in V0. A lead's P is fixed when it is raised (§7). Measured later.
- **F4, claims.** Claims stay out of V0.
- **F5, splits.** Ship the template splits as they are; improve them only if they fail.
- **F6, near-miss travel.** Off, and measured.

- **F9, stale** (confirmed by Sirsh, 12:01Z: 'they give the stack decay and refresh'). A part with no new link for
  `stack.stale_waves` (2) waves closes `stale`: its own state, frees its slot, never counts as an answer, and its
  leads are kept. On a live walk no part closed (close P 0.33–0.69 against 0.7, REM-1245), so the slots stayed full
  from wave 3.
- **F10, link by rank and a floor** (Sirsh, 11:49Z: "keep the tolerance strict"). A read links only if its assess P is
  in the walk's top `stack.link_share` (2%) so far and at least `stack.link_floor` (0.5 since F14). Close needs at least
  `stack.close_min_links` (2) links. On the recognition run (oracle-scored, REM-1240), no fixed gate alone made links
  clean (5.7% evidence at 0.5, 6.6% at 0.7, on a 3.9% base). The top 2% are 19% evidence. Adding the 0.7 floor keeps
  that at 19.0% and stops all links in 4 of the 58 walks. The floor's job is to refuse to link where nothing scores high, not
  to raise precision.
- **F11, slot rule** (confirmed by Sirsh, 12:01Z). A higher-P candidate displaces the weakest open part with no links of its own, at most
  `stack.max_displace` (1) a wave. It closes `displaced` with its P, and its leads are kept. On the ladder retest, the
  question's own aspects 'ladder' (P 0.78) and 'money' (0.84) never got a slot.
- **Fixed before the five-walk rerun, never retuned on it.** `stack.link_share` 0.02, `stack.link_floor` 0.7 (0.5 since F14),
  `stack.close_min_links` 2, `stack.close_gate` 0.7 (unused in V0: nothing reads it since the holistic close was retired, §8), `stack.stale_waves` 2, `stack.max_open` 4, `stack.max_displace` 1.
  Each is an `aiq.parameters` row with its reason, set from the recognition run (REM-1240) and the ladder retest
  (REM-1245), where these rules were found. The five-walk rerun (the ladder walk and the four registered walks) is
  their test. The four registered walks started at 11:38–11:42Z, before F9–F11, are the pre-change baseline.
  `stack.link_floor` is 0.7, not 0.5, on Sirsh's 'keep the tolerance strict'. On the recognition run the two give
  the same precision (19.0%), and 0.7 also refuses to link on walks where nothing scores high.
  **Its measured cost, one walk** (james, 12:01Z, oracle-scored). On 1M:35 tr:0 the pre-change build linked 4 reads
  at P ≥ 0.5, 3 of them labelled. Their lines hold the whole answer (December 13th and December 23rd: 10 days), and the
  root closed correctly after 10 reads at close P 0.91. Under the 0.7 floor the highest assess P is 0.67, so nothing
  links, close is never asked, and the walk reads to budget. The floor turns a right 10-read stop into a 50-read one
  (james predicted 500; the walk stopped cold at wave 2). Whether it stays is decided once the five test walks are in.

- **After the five test walks** (REM-1245, 12:07Z, n=1 each, oracle-scored, diagnoses). F9–F11 cut links from
  53–858 a walk to 1–7, and judgements by 60–99%. Coverage moved on none of the five: the walk equals search at 500
  reads on all five, and equals its pre-change baseline on four. Two rule fixes follow, decided in this spec before any
  rerun, with no value retuned:
  - **The link rule keeps at least `stack.close_min_links`** (move 1's max), so close can be asked early.
  - **Close sees each linked line's date, and any later line above the floor, and judges as of the latest** (move 4,
    from sally's and bill's 12:11Z review). It was registered on a case that turned out to be data (below), so it
    stands on its reasoning alone. The fresh knowledge_update walks are its only evidence. One of them, 1M:35 ku:1, has
    a key that misses its own answer (§10), so its coverage is read beside that note.
  - **1M:35 ku:0 is not the case it looked like** (checked on the walk's own rows, 12:20Z). The root closed at P 0.70
    on 386, "finalize all gift purchases by December 10th", and 632, the December 23rd deadline. The read that looked
    like the update, 218, "the new gift buying deadline of December 17th", ranked third at assess P 0.88, behind 632
    (0.94) and 386 (0.90). So the max(close_min_links) rule would not have linked it. And by the record's own dates,
    218 was said on November 15th, three weeks *before* 386 (December 7th). As of the latest statement the deadline is
    December 10th, which is what the board closed on. BEAM's answer is "December 17th", with 218 as its evidence.
    The key contradicts the conversation's chronology, so this is data-side, not class 4. A dated close picks December 10th,
    because it is the later statement. The regression check reports it that way.
  - **The floor's cost, corrected:** on 1M:35 tr:0 it is 10 reads to 50, not to 500. The walk stopped cold at wave 2
    with all 4 pieces read.

- **The two fixes are tested on a fresh set, registered before running** (sally's review, 12:10Z). The five walks
  they were found on are not their test; they are rerun only as a regression check, reported as such: does 1M:35
  ku:0's December 17th update now link, and does close pick it? The registered set was drawn with seed 1244 from the
  BEAM questions on the test database, excluding every question walked so far: **1M:35 ku:1** and **1M:22 ku:1**
  (knowledge update), **1M:22 tr:1** (temporal), **1M:35 cr:1** (contradiction), **1M:35 msr:1** (multi-session
  reasoning). 1M:22 ku:1 was walked once before, memoryless, in part three; it is not one of the five.
  1M:35 msr:1 stays in, drawn by seed, as the case where recognition is marginal: multi_session_reasoning's lower end
  is 0.649, against the 0.65 bar, and the walk is reported as such.
- **The five walks' misses, classed** (§10, oracle-scored):
  - Ladder's 266 ("how can I thank Don for helping me on May 15?") and 271 ("... moving heavy objects like the
    bathroom vanity") are **class 7, open, not read**. `aiq.walk_why` on the test walk shows an accepted lead toward
    each, never opened: `next:261` (P 0.66, rank 154 of 588 open leads) and `term:safety precautions` (P 0.75, rank 35).
    The oracle on the same graph reads all 9 pieces by 50 reads (REM-1237's measurement on the test database). So
    this is opening order, not reach. The query layer's own ceiling agrees: `aiq.walk_oracle` reads 9 of 9 by 50 reads on this walk, against the walk's 2 and search's 2 (REM-1245, f635acc2).
  - 1M:35 ku:0's unread 158 ("how much did the supplies from Daiso cost her again?") and 163 ("she only spent $30 on
    supplies from Daiso") carry no part of the reference answer, a deadline. They are over-labelled in the data, not
    misses.

- **The ten walks on the fixed rules** (REM-1245, 12:58Z, n=1 each, oracle-scored, diagnoses). Five regression walks
  and the fresh five, on committed parameters, none changed after reading.
  - **Coverage:** equal to search at 500 reads on all ten. 1M:35 msr:1 leads search at 100 and 200 reads (3 against
    1).
  - **Closing:** 1 of 10 closed, and wrongly by BEAM's answer. 1M:35 cr:1 closed after 10 reads on one side of a
    contradiction. The other side (220, "I've never actually asked Patricia or Steven to help") was read, assessed at
    0.84, rank 4 of 10, and cut by the two-link rank. The later-line rule does not reach it, because it was said
    earlier.
  - **Held the answer but did not close:** 4 of 10 linked the answer, but close P stayed at 0.42–0.68, under the 0.70
    gate, and each read 450 more messages.
  - **Links:** 47 across the ten, 8 of them labelled (17%), plus 1M:35 ku:1's unlabelled answer.
  - **The 1M:35 ku:0 regression:** the max rule now links all three deadline statements, and the dated close said no
    three times (0.42–0.48). The walk read to 500, where the pre-change build had stopped at 50 on December 10th.

  **The result, before any proposal (sally):** on these ten the board adds no reach, and its one close was wrong. No
  close-and-stop result exists on V0 yet. 1M:35 msr:1, ahead of search at 100 and 200 reads, is n=1, and it is not an
  example until the sweep shows the pattern.

  **Why, three mechanisms, none tuned:**
  - **(a) The close gate is unmeasured.** Close says no when the answer is linked beside an older or neighbouring
    statement. A close that never says yes turns every walk into a 500-read walk.
  - **(b) A contradiction is not a supersession.** The later-line rule covers a later statement replacing an earlier
    one. A contradiction question needs the opposing statement whatever its date.
  - **(c) The 0.7 floor cuts dated evidence on temporal questions.** On 1M:35 tr:0, 571 assessed 0.65 and 577 0.53,
    so close is never asked. This is the floor's second measured cost, on the same question as the first.

  **Decided (Sirsh, 13:05Z, M-20261029-130520-7c94: 'calls like these are ours when principle or measurement settles
  them, with the reason recorded'), in this order:**
  - **F14, `stack.link_floor` 0.5.** Reason: strictness comes from the rank cut (`stack.link_share`), not the floor. On
    the recognition run, 0.5 and 0.7 give the same precision (19.0%), and 0.7 only cost answers: 1M:35 tr:0 twice,
    once its correct 10-read close, then close never asked. It reverses 'keep the tolerance strict', which the rank
    cut already keeps.
  - **F13, close sees both sides, for every question.** Every assessed line above the floor, in either direction of
    time, dated, capped at `stack.evidence_lines` (12), highest P first (move 4). Reasons: a contradiction needs the
    opposing statement whatever its date (1M:35 cr:1 closed on one side, with the other side read). And the rule is
    never keyed on a question's type, because BEAM's types are label metadata and the walk must not know them (bill,
    REM-1231).
  - **F12, close by structure: a leaf on one line, a parent on its children, never a holistic ask** (move 4, reworked
    on Sirsh's 13:15Z principle; `stack.state_gate` calibrated under F14). Reason: on the ten walks' 34
    recorded close asks, the set judgement separated asks holding labelled evidence at only AUC 0.622. That is the
    baseline, and the calibration set is the test. A leaf closes on one line; a parent closes only on its children,
    so one partial line cannot close a multi-part question. When clearing lines conflict, the newest is the answer and the rest are history,
    so the board never reports one of two answers at random (sally's three changes, decided by principle, bill
    13:08Z). Calibration, registered before drawing:
    - *Set:* questions on 5841 other than the fifteen walked so far, disjoint from the sweep.
    - *The unit is the (line, leaf) judgement, not the close* (sally): under the structural close, set and count
      questions cannot close by design, so closes would under-count. A root with no parts counts as a leaf.
    - *Correct:* the line states the leaf's answer, checked against BEAM's reference answer with quotes, not that it is
      a labelled piece.
    - *Gate rule, stated beforehand:* `stack.state_gate` is the lowest P at which at least 90% of the lines clearing
      it state their leaf's answer, over the 18 walks' leaves.
    - *Labelling, registered before anyone labels* (sally, 14:11Z). The 18 walks recorded 649 (line, leaf)
      judgements; the 111 at P ≥ 0.5 are labelled, over 13 questions (5 never had a leaf with two links). 32 of the
      111 come from one question, 1M:6 cr:0.
      - *Labellers:* two, sally and a fresh blind subagent (bill's merged plan, 14:12Z; james keeps building). Each labels
        all 111 independently, from the same copy with P removed and the order shuffled (seed 1248). Jev never labels,
        since that would be circular.
        The blind file was re-cut with BEAM's rubrics (same seed and order) before either labeller finished: the 30
        lines of 1M:14 if:1, 1M:4 pf:1 and 1M:8 pf:0 have an empty reference answer, and rule (c) reads their rubric.
      - *Agreement:* reported as a count and Cohen's kappa. Every disagreement is settled by quoting the line and BEAM's
        answer side by side.
      - *A line states its leaf's answer (yes or no, with a quote) when:*
        - (a) single fact (information extraction, knowledge update, temporal, msr leaf): the line states the value
          BEAM's answer gives, or a value the answer depends on, such as one of the two dates of a 'days between'
          question;
        - (b) contradiction root: the line is one of the two statements BEAM's answer says conflict;
        - (c) preference or instruction: the line states the preference or instruction BEAM's answer relies on; a line
          that only asks for advice is no;
        - (d) a part's leaf: its answer is the clause or clauses of BEAM's answer that name the part's term or a plain
          synonym. If no clause does, the part is off-answer, its lines are no, and they are counted separately.
      - *The gate:* computed pooled over lines and with each question weighted equally. If the two disagree, the
        line-pooled gate is the registered one and the other is stated beside it. The gate is reported with a
        bootstrap interval over questions, because 111 lines, 32 of them from one question, is a small sample.
      - **Result: no gate exists** (REM-1244, 14:20Z, oracle-scored).
        - *Agreement:* 107 of 111 lines (96%), kappa 0.84. All four disagreements were settled for the subagent by the registered wording
          (sally, 14:19Z). id 40 is yes under (b): the full line contains "I've never actually solved any partial
          derivative problems", one of the two named statements; it was missed by reading lines cut at 260 characters.
          ids 76, 93 and 98 are no under (d), since only the reference's Docker clause names "components". Labellers
          read full lines.
        - *Settled labels:* 13 of 111 lines state their leaf's answer. Precision rises with P but never nears 90%: 12% of
          lines at P ≥ 0.5, 18% at 0.7, 35% at 0.9 (20 lines), 43% at 0.95 (7 lines, 3 questions). In 1,832 of 2,000
          bootstrap draws over questions, no gate exists at all; the other 168 find one only at 0.97, the single top
          line. Line-pooled and question-weighted agree.
        - *Parts:* 1 of 55 part lines states its answer, and 12 parts are off-answer entirely. Template parts mostly do
          not match the reference answer's clauses.
        - **Why:** look-alikes, the same limit as §10's class 3. Judged one line at a time, Jev's "this line answers this
          question" still tracks topical relevance. On 1M:6 cr:0, "I just solved 4 out of 5 partial derivative
          problems" gets P 0.96, but the answer is the specific statement "completed 6 practice problems… 5 correct".
        - **F12 is tested and failed at the registered 90% bar** (bill, 14:21Z, on principle and per Sirsh's 13:42Z
          "stopping is a bonus"). james's `harness/state_gate.py` gives the same result: no gate, line-pooled or
          question-weighted.
        - **V0 closes by structure only:** stale, displaced, and a parent whose children closed. Walks stop at the
          budget, on cold, or on a structural close. The board, its links and its parts still run, because the board is
          the memory Jev judges leads against. The UI shows them as "judged to bear on".
        - **Follow-on, REM-1250:** a different close, registered before it is tested, held to the same 90% bar on a fresh
          calibration set.
        - **What the registered procedure yields:** `stack.state_gate` stays unset, so in V0 no line closes a leaf
          `answered`. A walk ends by stale, dry, cold or budget, and the board shows each leaf's highest-P lines as
          "judged to bear on", unscored. It never says "judged to answer", the claim this calibration measured false. This is a stated limit. The 90% bar is not lowered after seeing the data; a
          lower bar would be a new rule, registered and tested on a fresh draw.
      - *Set aside:* a first, single-labeller pass (mike's subagent, under a simpler rule, before this protocol) is not
        used for the gate. Its counts were yes 16, no 79, off-answer 16.
    - *Test:* once, on a fresh draw. **Registered before that draw:** every knowledge_update question in it has its key
      checked first ($0, from the record's dates and user lines, as in §10). One whose key is group B (no labelled line
      states the answer) or C (superseded after the key) stays in, and is scored twice, by BEAM's answer and by the
      conversation's latest stated value, both quoted. It is not excluded: excluding it would select questions by how
      good their key is. Both calibration-set knowledge_update questions (1M:5 ku:0, 1M:21 ku:0) are group A (sally).
    - *The set, drawn by this procedure (REM-1244):* 5841's 1M question ids, minus the fifteen walked so far, minus the
      sweep's 1M draw (90, recomputed exactly as above), 2 per type by `random.Random(f'1247:{type}').sample(ids, 2)`
      from each type's sorted ids. That gives 18: 1M:13 cr:1, 1M:6 cr:0, 1M:2 eo:1, 1M:6 eo:1, 1M:8 ie:0, 1M:29 ie:0, 1M:14
      if:1, 1M:5 if:1, 1M:5 ku:0, 1M:21 ku:0, 1M:4 msr:1, 1M:8 msr:1, 1M:4 pf:1, 1M:8 pf:0, 1M:19 summ:0, 1M:14 summ:1,
      1M:21 tr:1, 1M:23 tr:1. They are walked on V0's committed build, on a new project loaded with their 11 conversations (1M:2, 4, 5, 6, 8, 13, 14, 19, 21, 23, 29), never on 5841: that database is the frozen record that its walks' replays reproduce on (bill, 13:13Z).

- **Splitting without generated text: three proxies, tested in order** (Sirsh, 13:35Z). Jev cannot write a
  sub-question, so a split is built from what already exists. The client split through `DECOMPOSITION_REQUIRED` stays
  as specced. Each proxy is first measured at $0 on recorded walks and BEAM's labels (oracle-scored), then the survivor
  is tested live against the oracle on a fresh draw, with no LLM in the loop. Any that fails gets its postmortem.
  1. **Evidence clusters** (first). Each read judged to bear on the question defines an aspect: its region of the
     graph (sitting and next-chain) and of vector space. Separate clusters are separate parts found, and a new cluster
     is a part discovered, so sub-questions come from discovery rather than being presupposed. A
     cluster need not match a "true" part of the question: any reasonable partition serves to divide and conquer
     (Sirsh, 13:37Z). **The risk is bias.** A cluster can steer the walk away from evidence it would otherwise have
     found. So the clusters are always joined by an **"everything else" part that stays open**: it holds the leads
     that belong to no cluster, it never goes stale, and stale and displaced give the refresh. *Test:* the clustered
     walk paired against the unpartitioned walk and the oracle on the same fresh questions. The bias loss is evidence
     the unpartitioned walk or the oracle reaches that the clustered walk misses, by §10's classes. A remaining loss is
     a stated limit. **The rule to build** (`walk.split = clusters`, a
     setting, off until it passes):
     - *Clusters:* the reads linked to the root are clustered keylessly. Two linked reads share a cluster when they
       sit within `walk.span` of each other in one sitting (the `walk_next` chain), or their vectors' cosine is at
       least the history's own `stack.cluster_quantile` (0.9) quantile of random-pair cosines, computed per scope at
       index time and kept with the graph. Keyless, and from the data. A fixed cosine would not do: on BEAM 1M, bge-small
       puts same-sitting neighbours at a median cosine of 0.790 and random pairs at 0.741, and the 0.9 quantile ranges
       0.757–0.896 across the 35 histories (median 0.822), clearing 41% of neighbour pairs (REM-1244, $0). The
       calibration walks do not set it, because they do not cluster. The sample is min(2,000, one per message) random
       pairs in a fixed hash order, so it is reproducible. On the test database it is 0.799 (1M:22) and 0.819 (1M:35)
       (james, 837afde8). A graph kept before this has no quantile until re-indexed, and its clusters join by sitting
       only.
     - *Parts:* each new cluster proposes one part, "the part about '<term>'", named by the most specific term its
       reads share. Jev gives P that it is a part the answer needs, as move 2 already asks.
     - *Slots and refresh:* parts open under `stack.max_open`, with displacement (F11) and stale (F9).
     - *Everything else:* the root stays open as the "everything else" part and judges every lead no cluster claims.

     A cluster is a part found, never presupposed.
     *Test, registered before it runs:* the clustered walk against the unpartitioned walk and the oracle, paired, on
     the same fresh draw, with bias loss by §10's classes.
  2. **The leftover vector** (second). Subtract from the question's embedding the part the found evidence explains, and
     judge leads against what is left. Progress is the leftover shrinking; the walk stops when it stalls. *$0 test:* on
     the recorded walks, does the leftover rank leads toward still-unread evidence better than the question itself? The
     known risk is that embeddings measure topical closeness, not whether something is answered.
     **Result: fails** ($0, 156 recorded buried walks, oracle-scored, REM-1244). Mean per-question AUC for leads toward
     unread evidence, against the question itself (0.66 at wave 1, 0.61 at wave 5, 0.60 at wave 10): the leftover
     after removing the labelled evidence read so far is 0.57 / 0.49 / 0.48, below chance by wave 5; after removing
     the 5 reads closest to the question (keyless) it is 0.61 / 0.58 / 0.56. It is worse in every wave. **Why:** on
     these questions the unread evidence lies in the same directions as the evidence already found, because evidence
     restates itself. Closeness to read evidence predicted rightness at AUC 0.74–0.80 (REM-1240, the walks postmortem
     §4). Subtracting those directions removes the very signal that points to more evidence. The known risk is
     confirmed: a residual measures what is topically new, not what is still unanswered. Not taken further.
  3. **Term hubs** (third). The question's own terms, as term nodes, act as sub-questions: is there evidence near this
     term? *$0 test:* how much of each question's evidence lies within one lead of a node for one of its terms?
     **Result: fails on set questions** ($0, the 156 buried questions, event_ordering and summarization, oracle-scored,
     REM-1244). A median question has 5 of its history's terms in its words, but only 5% (eo) and 7% (summ) of its
     evidence holds one, and evidence is only 1.6–1.8 times as common among those messages as overall. **Why:** these
     questions are phrased abstractly, so their terms are meta-words: "development", "items", "order", "phases",
     "summarize". The evidence uses the specific aspects ("baklava", "secret santa"), which the question never names.
     A set question's parts are not in its words, which is the case for discovering them (proxy 1). Scope: set
     questions only. A single-fact question likely names its subject, but there a split is not needed.
  4. **Expected cardinality, a Jev decision, not generation.** Jev judges from the question's words whether its answer
     is a single fact or a set. *Test:* every 1M question, about $0.01 of Jev, scored against BEAM's types outside the
     walk. If it separates them, the walk can know when to expect parts without knowing the benchmark's type.
     **Result: it separates them** (REM-1244, jev-1.13.0, all 700 BEAM 1M questions, about $0.001, scored by BEAM's
     types outside the walk). Jev's P that answering "needs several separate items across many messages" separates the
     set types (event_ordering, summarization, multi_session_reasoning) from the single-fact types (information
     extraction, knowledge update, temporal, contradiction) at AUC 0.936. Medians: summarization 0.91, event_ordering
     0.82, msr 0.78; temporal 0.64, information extraction 0.60, knowledge update 0.59, contradiction 0.34. A 0.5 gate
     would not do: 90% of temporal questions clear it, fairly, since they need two dates. The types counted as set are event_ordering,
     summarization and multi_session_reasoning; as single, information_extraction, knowledge_update and
     contradiction_resolution. Temporal is counted both ways, since a two-date question is a set by its words: AUC 0.936
     with temporal as single, 0.89 as set, 0.942 left out (sally).

     **Decided on this test** (sally's review, adopted by bill 13:43Z; this reverses bill's 13:19Z "(4) the walk does
     not detect set questions"):
     - *The gate:* `stack.set_gate` is set on a held-out half of the 1M questions, excluding the 18 calibration
       questions and every fresh-test question. The rule, stated before the split: the P that best separates set from
       single types on that half by Youden's J, temporal left out.
     - *The use:* at the start, Jev judges the root once on its words, recorded as a decider move (`N|root`). At P ≥
       `stack.set_gate` the root is a set question. It closes only by structure over its parts, never on one line, and
       it ends `answered` only if every part is answered. Below the gate, the root is a leaf and may close on one line.
     - *Until then:* until the gate is set and committed, the built walk does no set detection.
     - *The wording is the tested one, verbatim* (`decider.task_set`): task "For each option, a question a user asked
       about their own earlier conversations. Does answering it need several separate items found across many messages
       (a list, a count, a sequence of events, or a summary), rather than one fact that a single message could state?",
       with state question "What kind of answer does each question need?" and the question's own text as the option.
       A reworded prompt invalidates the 0.936 and its gate, as the semantic exceptions' thresholds are tied to their
       exact instructions. BEAM's types are only a proxy for cardinality: a temporal
     question needs two facts, which is why it scores
     0.64.

Still open:
- **F7. One ceiling, not two** (sally's question). The ceiling is a perfect opener with no board. A second ceiling
  with a perfect board as well (assessments taken from the key) would separate a stack failure from a judging one in
  aggregate. Proposed: V0 reports classes 4 and 8 per piece instead, and adds the second ceiling only if those
  classes turn out large.
- **F8 (decided). Bundles or targets, and the opening-order fault (class 7).** Measured on the holiday stack walk (01a18760,
  `lines`, `per_target`, oracle-scored, $0):
  - **The gate accepts more than the budget can open.** 1,035 of 1,927 judged leads were accepted; 305 were opened in
    500 reads. 51 of the 89 accepted leads toward evidence were never opened.
  - **P cannot choose among the accepted.** Opened leads have median P 0.59, and accepted-but-unopened ones 0.58. So
    ordering by P alone would not save them.
  - **Ordering by P per target pushes out wide leads.** The opened leads have 3 targets (median) and P per target
    0.207. The never-opened evidence leads have 7 targets and 0.086. They rank 4th to 349th of 1,035 by P per target.
    cory's timeline shows the same: five evidence messages on that walk were accepted at waves 2–3 and read 6–8 waves
    later, and four were never read.

  So class 7 is not an order a cleverer sort would fix. It is a wide lead that is worth opening in part. **Proposed
  change, registered before any run:** a lead with more than `walk.open_whole` (3) unread targets is opened target by
  target. Each of its unread targets is judged once by Jev, shown that target's own line (§3), and the targets clearing
  `walk.gate` are queued as single-target leads. The cost is one judgement per target of a wide lead when it is opened:
  on this walk about 730 leads × 6 targets, about 4,400 more judgements, about $0.03. It is tested on a fresh draw,
  not on this walk. **Decided yes, on principle** (bill, 13:42Z, under Sirsh's rule): a wide lead's weak targets
  should not spend reads. It is registered for a fresh draw, and bundles stay the default until it passes there.

## 15. V0 limits, stated

- **Recognition is capped by look-alikes** on questions whose evidence is the conversation's whole topic (§10).
- **The board-state line, as built, adds nothing.** Re-judged on the same 3,215 leads, `lines` plus the state line
  scores −0.018 [−0.048, +0.016] against `lines` alone (REM-1240). The mark is loose: it lands on 344 of 600 sources,
  15 of the 18 that are evidence among them. Jev's `lines` P already separates marked from unmarked sources (median
  0.57 against 0.31), so the line repeats Jev's own judgement. It ships only with a mark that is right about evidence
  (F10's rank-linking), measured again.
- **The cost of a strict floor, resolved.** `stack.link_floor` 0.7 turned a correct 10-read stop into a 50-read one
  on 1M:35 tr:0, and then left close never asked. F14 set it to 0.5 (§14).
- **Rank is relative.** A walk with no evidence in reach still links its top 2% of reads above the floor: 4 of the 5 such walks on the recognition run did. The close judgement must be
  able to say no, and a walk's links mean 'judged to bear on', never 'evidence', until they are scored.
- **Recognition is loose.** At 0.5, 83% of evidence reads clear the assessment gate, and so do 56% of other reads
  (REM-1240). So `walk_answers` edges are noisy, and §7's state line is diluted: a lead out of a non-evidence read
  is often marked as out of an answering one. F10 replaces the fixed gate with rank within the walk.
- **BEAM's layout leaks.** Place in a sitting predicts BEAM's evidence only because its generator draws questions from
  each sitting's first plan steps, so V0 uses no such signal. A next or near lead out of evidence partly carries the
  same artifact; a term lead does not (REM-1240).
- **BEAM's plan index leaked into descriptions.** BEAM's chunks keep the generator's plan index ('->-> sitting,step'),
  and the plan step predicts evidence. Under `source` the lead text is cut from the chunk, and on the holiday walk
  1,251 of 1,946 lead texts carried it (cory, REM-1240). Every past `source`-arm number on BEAM therefore ran with a
  benchmark artifact in the decider's view. On that walk Jev showed no sign of using it: mean P 0.397 when the shown
  step is 1–12, where the evidence sits, against 0.401 for 13+ (diff −0.005 [−0.015, +0.006], one walk). The step
  predicts whether the *source* is evidence, not its targets. V0 strips the index at ingest (cory's loader fix), and no
  lead text may contain it. **Its effect on search, measured** (REM-1244, $0, read-only, oracle-scored). Three builds of 1M:22 and
  1M:35 were each queried with the same question vector: A, marker in text and vectors; B, stripped text with the old
  vectors; C, marked text with the new vectors.
  - *Across the 36 questions:* stripping the text changes nothing (B − A: +0.0 points at 50 and 100, +0.1 at 500). The
    new vectors change little (C − A: −1.8 [−8.3, +2.7] at 50, −0.5 [−1.3, +0.1] at 500). Evidence in plan steps 1–12
    lost no more rank than the rest (median change 0 for both).
  - *On the step-1 question (1M:35 eo:0):* search's top 500 holds 15 of 27 under A and under B, and 12 under C. So
    part three's 15 → 12 comes from the vector half, re-embedding the changed pieces, on that one question. It does not
    generalise across the 36.
  - *Caveat:* the local question vector does not reproduce the stacks' own search order exactly, so these are
    controlled deltas, not the article's numbers. Some stored user lines carry it too: 141 of 10,446 on one test database. Recognition
  without them is unchanged, 0.746 [0.691, 0.800].
- **Where the board can be judged.** Recognition clears 0.65 at the lower end only on questions that name their
  subject (temporal_reasoning, knowledge_update, contradiction_resolution). It is at the edge on multi_session_reasoning
  and below on event_ordering and summarization (REM-1240, oracle-scored). Live walks that show the board are chosen
  from the first group beforehand, and say they were chosen that way.
- **On questions search already answers, the board's value is in closing and stopping, not reach.** On
  knowledge_update and contradiction questions, walk and search both read the newest statement for 14 of 15 by 50
  reads (part three). There a walk is reported with two more figures: the read at which the root closes, and whether
  it stops `stack empty` before the budget with the evidence complete (oracle-scored). A flat coverage curve there is
  not the board doing nothing.
- **Sequential only, built so that map-reduce can follow** (Sirsh, 13:16Z; future direction, not V0). Narrow
  sub-questions are what make the walk a map: several Jev instances can each work their own part of the walk
  independently, and the holistic integration happens afterwards, done by the caller (an LLM or anything else), which
  is the reduce. Jev never needs the whole picture. V0 keeps that possible:
  - each sub-question's judgements are self-contained, keyed by the question (`L|<q>|<lead>`, `A|<q>|<read>`,
    `C|<q>|…`);
  - no judgement reads holistic state;
  - a parent's close is structure over its children, not a Jev call.

## 16. Proposals (not V0)

**Nothing in this section ships as V0 behaviour.** V0 is the plain walk with the original question (§10, outcome
(i)). Each entry says what it is meant to solve, its status and evidence, and the test that would promote it into
the decided spec (Sirsh, 29 Oct 18:29Z).

### 16.1 Decomposition: a question stack with real sub-questions

**Meant to solve:** a lead judged against the whole question cannot tell progress on one part from an echo of
another. The V0 stack's parts did not help, because they are the root's own words plus a keyword
(`stack.part_wording`): S − P was −1.1 [−3.1, +0.2] at 100 reads (§10).

- **(a) The caller-supplied stack.** The asking agent supplies its own sub-questions, opened as `client:<n>` parts
  (§6, move 3) from the start, with everything else as built.
  - *Keyless:* sub-questions are the caller's words about what to find, never an answer. They would enter as
    `question.parts`, which is not built (today `walk_start` takes only the question), and would be refused if they
    carried an answer, evidence or rubric.
  - *Who writes them, in any test or example* (sally, 18:09Z): on BEAM the rubric's items are the answer key, and a
    refusal at `walk_start` cannot catch a part copied from one. So a fresh client given only the question's words
    writes the parts, its prompt is kept, and afterwards each part is checked against the rubric for repeated
    distinctive words, with any repeat quoted.
  - *Status: tested, no direction* (bill, 18:14Z, REM-1244). Jev re-judged recorded leads on 4 questions, against
    blind sub-questions written under that rule and against the original. Best sub-question minus original, in AUC:
    house sale −0.170 [−0.264, −0.077]; Japan trip −0.020 [−0.068, +0.029]; GPU issues +0.005 [−0.014, +0.027];
    days between −0.098 [−0.159, −0.038]. Judging the original twice moves its AUC by at most 0.010. An earlier
    hand-written set (written from the question text only) gave −0.036, +0.005, −0.030 and −0.068; its null held all
    the more, since copying the rubric could only have helped (sally). Both checks cost $0.052.
  - *Why no direction:* Jev already reads a multi-part question's parts in the question itself (sally), and taking
    the best score over several parts adds false positives (bill's write-up).
  - *The test that would promote it:* leads scoring better against blind parts than against the root on a
    registered set of questions. On tonight's evidence it is not built for part three.
- **(b) The slot-structured stack** (Sirsh, M-20261029-180634-2357; a project and a follow-up article, not part
  three). Each open question is a slot built from closed lists: *subject* (an entity in the graph), *aspect* (a tag
  or a relationship type), *time* (past, now, later, or before or after an event) and *ask* (a fact, a change, a
  count or a list item; the ask also says when the slot is filled). Jev picks slots, judges leads against the open
  ones, and closes a slot when evidence fills it.
  - *Status:* untested.
  - *The test that would promote it:* the closed lists cover most questions as they are evolved, and leads judged
    against filled-in slots separate evidence better than against the root.

### 16.2 Progress: telling new evidence from an echo of what was found

**Meant to solve:** late in a walk the unread leads are mostly echoes of what has been read, and Jev cannot tell them
from new information (AUC fell to 0.27–0.36 in later waves, REM-1240). The free replay tests (29 Oct, REM-1244) put
the headroom here. Of the 194 labelled pieces the oracle read by 100 and P did not, 80% were behind leads P had
accepted and not opened, 10% behind rejected leads only, and 10% had no lead pointing at them. Within the accepted
set Jev's P separates leads toward evidence at AUC 0.607. Adding "the source read is evidence", the 12x relation,
raises it to 0.671 (an oracle ceiling, not deployable), and a keyless proxy ("the source read came by a lead") lowers
it to 0.554. Cutting search's per-wave share changes nothing at 100 reads.

- **Stack A: the walk's retrieval, kept out of Jev's context** (Sirsh, 18:26Z). After each read Jev judges "does
  this message hold information needed to answer `question`?", and if yes the read's node id goes on A. A holds ids
  only. It never enters Jev's context, and it is returned to the caller as the walk's retrieval. B, below, is the
  separate working memory.
  - *Evidence* (bill, step 2's first judgement, the same run as B's): relevance AUC is 0.686, 0.923, 0.517 and 0.564
    on the four questions. At relevance ≥ 0.5, A holds 50, 35, 51 and 71 of 100 reads, and catches 1 of 2, 14 of 15,
    2 of 3 and 4 of 5 of the labelled pieces read. High recall and low precision, so as a retrieval list it is
    mostly cost to the caller.
  - *The test that would promote it:* A at a top-k-per-wave cut against the walk's current evidence list on the
    extension's questions, comparing the returned list's labelled recall and precision at equal list size. Under V0
    the stack is off, so the walk keeps no `walk_answers` links. The comparison there is against the walk's reads in
    order, or against S's links on the pilot.
- **Stack B: the found evidence in Jev's state, the question unchanged** (bill).
  - *Step 1, tested:* on 400 leads out of evidence reads (80 progress, 320 echo, four questions), adding the exact
    found evidence to the decider's state lifts progress-against-echo AUC from 0.653 to 0.701, +0.047 [+0.004,
    +0.094]. Nearly all of it is one question, 1M:13, where the question alone ranked below chance
    (0.464 → 0.687). A task worded as "not already in what was found" hurts (−0.07 to −0.17).
  - *Step 2, tested* (bill, 18:36Z): when Jev builds B itself, by admitting reads it judges as found evidence, B
    balloons to 42–72% of the reads, with precision 0.03–0.29 against the labels, and no gate fixes it. So step 1's
    gain needs a small, exact B that Jev cannot yet build.
  - *Stages 1 and 2 of Sirsh's design* (19:50Z; bill, 19:56Z).
    - *Stage 1, a small exact B:* B holding only 3 exact pieces of found evidence works like the full one: +0.254 on
      1M:13, and pooled +0.036 [−0.004, +0.080].
    - *Stage 2, B admitted by Jev:* when B takes Jev's own top relevance per wave, it stays small (9–11 pieces), but
      only about 9% of it is evidence. Judging with it pools −0.041 [−0.083, −0.001].
    - *What is missing:* an admission signal that separates evidence from reads that are merely on topic.
  - *The test that would promote it:* a keyless admission signal whose B is small and exact enough to keep stage 1's
    gain, then replayed coverage at 100 above P's on the registered set.
