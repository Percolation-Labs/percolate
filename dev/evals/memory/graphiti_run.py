"""Graphiti (Zep's open-source engine) on the memory fixture.

Each fact becomes one episode, in time order, with its said_at as the
reference time and its user as the group. Graphiti's own LLM extracts the
facts and decides which earlier ones a new episode invalidates: nothing here
tells it what supersedes what, unlike the Mem0 and Percolate runners, which
take supersession from the fixture.

Three read paths, all Graphiti's own search (hybrid: BM25 and cosine, fused):
  graphiti-search    search(question, group_ids=[user]): the facts (edges)
  graphiti-valid     the same, filtered to edges that held at the question's
                     time (now, or as_of): valid_at <= t or unknown, and
                     invalid_at > t or never
  graphiti-episodes  the episodes COMBINED_HYBRID_SEARCH_RRF returns: the
                     memories themselves, as Mem0 and Percolate's search
                     return memories. No time filter applies to an episode.

QUERY_ONLY=1 skips the load and reads episode names from the graph, so the
questions can be asked again of a graph already built.

Each returned edge names the episodes it came from, and each episode is one
fixture fact, so a ranked list of edges becomes a ranked list of fact ids,
which score.py grades against gold with no judge.

The embedder is the one every other runner uses, fastembed BAAI/bge-small-en-v1.5,
through Graphiti's EmbedderClient interface. The LLM is gpt-4o-mini, Graphiti's
default; the other systems write without one.

    NEO4J_URI=bolt://localhost:57687 NEO4J_USER=neo4j NEO4J_PASSWORD=... \
    OPENAI_API_KEY=... python -I graphiti_run.py fixture.json > graphiti.jsonl
"""
import asyncio
import json
import os
import sys
from datetime import datetime, timezone

from fastembed import TextEmbedding
from graphiti_core import Graphiti
from graphiti_core.embedder.client import EmbedderClient
from graphiti_core.nodes import EpisodeType
from graphiti_core.search.search_config_recipes import COMBINED_HYBRID_SEARCH_RRF
from graphiti_core.search.search_filters import ComparisonOperator, DateFilter, SearchFilters

MODEL = TextEmbedding("BAAI/bge-small-en-v1.5")
SUFFIX = ("-oai" if os.environ.get("EMBEDDER") == "openai" else "") + ("-msg" if os.environ.get("EPISODES") == "message" else "")
# EPISODES=message writes each fact as the person said it, a chat message
# ("Maya Okafor: I'm up in Leeds..."), which is the shape Zep's add_messages takes.


class FastEmbed(EmbedderClient):
    async def create(self, input_data):
        text = input_data if isinstance(input_data, str) else " ".join(map(str, input_data))
        return [float(x) for x in next(iter(MODEL.embed([text])))]

    async def create_batch(self, input_data_list):
        return [[float(x) for x in v] for v in MODEL.embed(list(input_data_list))]


def when(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def held_at(t):
    return SearchFilters(
        valid_at=[[DateFilter(date=t, comparison_operator=ComparisonOperator.less_than_equal)],
                  [DateFilter(comparison_operator=ComparisonOperator.is_null)]],
        invalid_at=[[DateFilter(date=t, comparison_operator=ComparisonOperator.greater_than)],
                    [DateFilter(comparison_operator=ComparisonOperator.is_null)]])


async def main(path):
    fixture = json.load(open(path))
    # EMBEDDER=openai keeps Graphiti's own default embedder (text-embedding-3-small),
    # whose scores its 0.6 similarity floor was tuned for: Graphiti's best case.
    kw = {} if os.environ.get("EMBEDDER") == "openai" else {"embedder": FastEmbed()}
    g = Graphiti(os.environ["NEO4J_URI"], os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"], **kw)
    await g.build_indices_and_constraints()

    episode_fact = {}
    if os.environ.get("QUERY_ONLY") == "1":
        records, _, _ = await g.driver.execute_query("MATCH (e:Episodic) RETURN e.uuid AS uuid, e.name AS name")
        episode_fact = {r["uuid"]: r["name"] for r in records}
    for f in ([] if episode_fact else sorted(fixture["facts"], key=lambda f: f["said_at"])):
        if os.environ.get("EPISODES") == "message":
            who = f["user"].capitalize()
            body, kind = f"{who}: {f.get('quote') or f['text']}", EpisodeType.message
        else:
            body, kind = f["text"], EpisodeType.text
        r = await g.add_episode(name=f["id"], episode_body=body,
                                source_description=f"{f['agent']} run {f['run']}",
                                reference_time=when(f["said_at"]), source=kind,
                                group_id=f["user"])
        episode_fact[r.episode.uuid] = f["id"]
        print(f"# added {f['id']}: {len(r.edges)} edges", file=sys.stderr)

    now = datetime.now(timezone.utc)
    for q in fixture["questions"]:
        t = when(q["as_of"]) if q.get("as_of") else now
        for system, flt in (("graphiti-search", None), ("graphiti-valid", held_at(t))):
            edges = await g.search(q["ask"], group_ids=[q["user"]], num_results=10, search_filter=flt)
            ranked = []
            for e in edges:
                for ep in e.episodes:
                    fid = episode_fact.get(ep)
                    if fid and fid not in ranked:
                        ranked.append(fid)
            print(json.dumps({"system": system + SUFFIX, "q": q["id"], "ranked": ranked[:10]}), flush=True)
        cfg = COMBINED_HYBRID_SEARCH_RRF.model_copy(deep=True)
        cfg.limit = 10
        res = await g.search_(q["ask"], config=cfg, group_ids=[q["user"]])
        ranked = [episode_fact[e.uuid] for e in res.episodes if e.uuid in episode_fact][:10]
        print(json.dumps({"system": "graphiti-episodes" + SUFFIX, "q": q["id"], "ranked": ranked}), flush=True)
    await g.close()


asyncio.run(main(sys.argv[1]))
