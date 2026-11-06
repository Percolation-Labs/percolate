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
through Graphiti's EmbedderClient interface. The LLM is gpt-4o-mini unless LLM_MODEL
names another (LLM_MODEL=default keeps the release's own); the other systems write
without one.

    NEO4J_URI=bolt://localhost:57687 NEO4J_USER=neo4j NEO4J_PASSWORD=... \
    OPENAI_API_KEY=... python -I graphiti_run.py fixture.json > graphiti.jsonl
"""
import asyncio
import json
import os
import sys
from datetime import datetime, timezone
from importlib.metadata import version

from fastembed import TextEmbedding
from graphiti_core import Graphiti
from graphiti_core.embedder.client import EmbedderClient
from graphiti_core.llm_client import LLMConfig, OpenAIClient
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
    # The extraction model, named rather than left to the default, which moves between releases (0.31.2's is
    # gpt-6-luna). LLM_MODEL=default keeps whatever the installed release defaults to.
    model = os.environ.get("LLM_MODEL", "gpt-4o-mini")
    if model != "default":
        kw["llm_client"] = OpenAIClient(config=LLMConfig(model=model, small_model=model))
    print(f"graphiti: graphiti-core {version('graphiti-core')}, LLM {model}", flush=True)
    # A Neo4j container started a moment ago takes a while to accept a login: wait for it, up to five minutes.
    from neo4j import GraphDatabase
    for _ in range(150):
        try:
            with GraphDatabase.driver(os.environ["NEO4J_URI"],
                                      auth=(os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"])) as d:
                d.verify_connectivity()
            break
        except Exception:
            await asyncio.sleep(2)
    else:
        sys.exit(f"no Neo4j at {os.environ['NEO4J_URI']} after five minutes")
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

    # What the graph holds after the load, and which replaced facts Graphiti ended itself: an edge drawn from a
    # replaced fact's episode with invalid_at (or expired_at) set. Printed as plain lines, which score.py skips.
    records, _, _ = await g.driver.execute_query(
        "MATCH ()-[r:RELATES_TO]->() RETURN r.episodes AS episodes, r.fact AS fact, "
        "r.invalid_at IS NOT NULL OR r.expired_at IS NOT NULL AS ended")
    by_fact = {}
    for r in records:
        for ep in r["episodes"] or []:
            if ep in episode_fact:
                by_fact.setdefault(episode_fact[ep], []).append((r["fact"], r["ended"]))
    replaced = [f["supersedes"] for f in fixture["facts"] if f.get("supersedes")]
    ended = [x for x in replaced if any(e for _, e in by_fact.get(x, []))]
    print(f"graphiti: {len(records)} facts written from {len(fixture['facts'])} episodes", flush=True)
    print(f"graphiti: {len(ended)} of the {len(replaced)} replaced facts ended", flush=True)
    for fid in replaced:
        if fid not in ended:
            text = next(f["text"] for f in fixture["facts"] if f["id"] == fid)
            state = "still current" if by_fact.get(fid) else "never written as a fact"
            print(f"graphiti: {state}: {fid} {text}", flush=True)

    usage = g.llm_client.token_tracker.get_total_usage()
    print(f"graphiti: LLM tokens for the load: {usage.input_tokens} in, {usage.output_tokens} out", flush=True)

    await ask(g, fixture, episode_fact, SUFFIX, episodes=True)
    if os.environ.get("TOLD") == "1":
        # TOLD=1 gives Graphiti what the Percolate runner is given: the fixture's answer key. Every edge drawn from
        # a replaced fact's episode is invalidated at the moment the replacing fact was said, as Graphiti's own
        # invalidation would stamp it, and the questions are asked again as graphiti-*-told.
        said = {f["id"]: when(f["said_at"]) for f in fixture["facts"]}
        uuid_of = {v: k for k, v in episode_fact.items()}
        n = 0
        for f in fixture["facts"]:
            if f.get("supersedes") and f["supersedes"] in uuid_of:
                records, _, _ = await g.driver.execute_query(
                    "MATCH ()-[r:RELATES_TO]->() WHERE $ep IN r.episodes "
                    "SET r.invalid_at = $t RETURN count(r) AS n",
                    ep=uuid_of[f["supersedes"]], t=said[f["id"]])
                n += records[0]["n"]
        print(f"graphiti: told: {n} edges invalidated from the answer key", flush=True)
        await ask(g, fixture, episode_fact, SUFFIX + "-told", episodes=False)
    await g.close()


async def ask(g, fixture, episode_fact, suffix, episodes):
    now = datetime.now(timezone.utc)
    for q in fixture["questions"]:
        t = when(q["as_of"]) if q.get("as_of") else now
        # As percolate_run.py does: a change question asks about both sides of a change, so no time filter applies.
        valid = None if q["kind"] == "change" else held_at(t)
        for system, flt in (("graphiti-search", None), ("graphiti-valid", valid)):
            edges = await g.search(q["ask"], group_ids=[q["user"]], num_results=10, search_filter=flt)
            ranked = []
            for e in edges:
                for ep in e.episodes:
                    fid = episode_fact.get(ep)
                    if fid and fid not in ranked:
                        ranked.append(fid)
            print(json.dumps({"system": system + suffix, "q": q["id"], "ranked": ranked[:10]}), flush=True)
        if not episodes:
            continue
        cfg = COMBINED_HYBRID_SEARCH_RRF.model_copy(deep=True)
        cfg.limit = 10
        res = await g.search_(q["ask"], config=cfg, group_ids=[q["user"]])
        ranked = [episode_fact[e.uuid] for e in res.episodes if e.uuid in episode_fact][:10]
        print(json.dumps({"system": "graphiti-episodes" + suffix, "q": q["id"], "ranked": ranked}), flush=True)


asyncio.run(main(sys.argv[1]))
