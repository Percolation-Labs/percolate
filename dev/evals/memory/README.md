# Memory baselines: one fixture, several memory systems

What a memory system returns for questions whose answers changed over time, measured on one fixture with the same
embedding model on every side and no LLM in the retrieval. Started for "Percolate for Mem0 folks" (B1-mem0,
REM-959); the fixture and scorer are shared with the Graphiti comparison (REM-1018).

## The fixture

`fixture.json` was written by an agent that never saw any of the systems. It holds 48 facts: 40 about Maya and 8
about a second user, Leo. They come from two agents (`planner`, `coach`) across 12 runs, January to September
2026, and 11 of them supersede an earlier fact. There are 46 questions with gold fact ids:

| kind | n | what it asks |
|---|---|---|
| current | 14 | what holds now |
| historical | 8 | what held at a stated time (`as_of`) |
| stable | 12 | a fact nothing replaced (6 of them Leo's) |
| change | 5 | what changed |
| scoped_agent | 7 | what one agent was told |

Scoring is retrieval against the gold ids, so there is no judge:

- **hit@1** the top result is gold
- **rec@5** every gold fact is in the top five
- **stale>gold** a superseded fact outranks the best gold one
- **leak@5** another user's fact is in the top five

## Results

From `scores.txt`, which `python3 -I score.py fixture.json ranked.jsonl` reproduces. Same embedder on every side,
fastembed 0.9.0 `BAAI/bge-small-en-v1.5` (384 dimensions), and no LLM.

| system | hit@1 | rec@5 | stale>gold | leak@5 |
|---|---|---|---|---|
| mem0-add (`infer=False`, nothing superseded) | 52% | 83% | 26% | 0% |
| mem0-expire (the replaced memory expires the day it was replaced) | 57% | 89% | 11% | 0% |
| mem0-update (`update` in place; what `infer=True` does when its LLM chooses UPDATE correctly) | 50% | 65% | 17% | 0% |
| percolate-search (`aiq.search`, lexical and vector by rank fusion) | 52% | 80% | 28% | 0% |
| **percolate-valid** (the same candidates, kept if their fact held at the question's time) | **76%** | **87%** | **0%** | 0% |

hit@1 by kind:

| kind (n) | mem0-add | mem0-expire | mem0-update | percolate-search | percolate-valid |
|---|---|---|---|---|---|
| current (14) | 7% | 21% | 21% | 21% | 57% |
| historical (8) | 12% | 12% | 0% | 12% | **75%** |
| stable (12) | 92% | 92% | 92% | 92% | 92% |
| change (5) | 80% | 80% | 40% | 80% | 80% |
| scoped_agent (7) | 100% | 100% | 100% | 71% | 86% |

What it says, and what it does not:

- **With no notion of time the two systems tie,** 52% and 52%.
- **The structural difference is the historical row.** Mem0's open-source package cannot ask "as of"
  (`search(reference_date=)` and `add(timestamp=)` are platform-only, and expiry compares against today), so its
  best setup answers 1 of 8 and the update path none. Percolate answers 6 of 8.
- **The current row is mostly ranking.** mem0-expire and percolate-valid both drop replaced facts; what separates
  them is how lexical and vector scores combine (Mem0 adds a normalised BM25 score, Percolate fuses ranks). The
  same difference runs the other way on agent-scoped questions, where Mem0 gets 7 of 7 and Percolate 6.
- **Small numbers.** One fixture, 46 questions, deterministic runs: one question is about 2 points overall.
- **No leaks** on either side. `orgless-*` in `scores.txt` is Percolate with every memory registered with no org,
  the path REM-962 was about; it scores the same, and each user's graph reach stays their own.

## Graphiti (REM-1018)

`graphiti_run.py` loads the same facts into Graphiti 0.31.1, the open-source engine behind Zep, on Neo4j 5.26,
each fact one episode with its `said_at` as the reference time. Graphiti's own LLM (gpt-4o-mini, its default)
extracts the facts and decides which earlier ones a new episode invalidates. Unlike the rows above, nothing tells
it what supersedes what. From `scores-graphiti.txt` (`python3 -I score.py fixture.json ranked-graphiti.jsonl`):

| system | hit@1 | rec@5 | stale>gold | historical hit@1 |
|---|---|---|---|---|
| graphiti-search (fact search) | 24% | 35% | 15% | 25% |
| graphiti-valid (facts that held at the question's time) | 30% | 37% | 9% | 62% |
| graphiti-episodes (episode search, BM25) | 35% | 59% | 9% | 50% |
| graphiti-valid-oai (Graphiti's default embedder, text-embedding-3-small) | 33% | 46% | 15% | 62% |
| graphiti-valid-oai-msg (each fact written as a chat message, "Maya: ...") | 22% | 33% | 11% | 75% |

- **The graph holds less than it was given.** From 48 episodes Graphiti wrote about 21 facts and folded the rest
  into entity summaries, which a fact search does not reach.
- **It invalidated 2 of the 11 supersessions** from one-sentence facts and 5 from chat messages. "Maya lives in
  Manchester" still held after she moved to Lisbon.
- **The embedder is not the cause:** its own embedder, which its 0.6 similarity floor was tuned for, moved the
  best path by three points. Episode search is BM25 only, so it scores the same with either.
- Only gpt-4o-mini has been run. A larger extraction model has not.

## Rerun

```bash
uv venv -p 3.12 env && uv pip install -p env mem0ai==2.2.1 fastembed==0.9.0 'psycopg[binary]'
env/bin/python -I mem0_run.py fixture.json > mem0.jsonl

docker run -d --name memory-bench -e POSTGRES_USER=p8 -e POSTGRES_PASSWORD=p8 -e POSTGRES_DB=p8 \
  -p 47959:5432 percolationlabs/percolate-postgres:19-0.2.23
DSN=postgresql://p8:p8@localhost:47959/p8 env/bin/python -I percolate_run.py fixture.json > percolate.jsonl

python3 -I score.py fixture.json mem0.jsonl percolate.jsonl
```

`percolate_run.py` prints each user's graph reach as it goes (`maya reads 40 of Maya's facts and 0 of Leo's`).
`ORGLESS=1` registers every memory with no org. A fresh reader reproduced the Percolate rows exactly on the
published `19-0.2.23` image, 19 October 2026.

Graphiti, with the OpenAI key in the environment (this sends the fixture's text to OpenAI):

```bash
uv pip install -p env graphiti-core==0.31.1
docker run -d --name memory-bench-neo4j -e NEO4J_AUTH=neo4j/<password> -p 57687:7687 neo4j:5.26
NEO4J_URI=bolt://localhost:57687 NEO4J_USER=neo4j NEO4J_PASSWORD=<password> \
  env/bin/python -I graphiti_run.py fixture.json > graphiti.jsonl
```

`EMBEDDER=openai` keeps Graphiti's default embedder, `EPISODES=message` writes each fact as a chat message, and
`QUERY_ONLY=1` asks the questions again of a graph already built (clear it between loads).
