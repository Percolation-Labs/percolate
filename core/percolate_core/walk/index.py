"""`percolate walk index`: the links a walk travels, built from what is already stored.

A walk (REM-1199) starts from
search and then follows clues between documents: a word run two documents
share, the document said just after this one, the documents nearest in
meaning. This writes those clues as edges, once per source, BY CONSTRUCTION:
each one is a fact about the stored text or its vectors, never a model's
verdict, so the weight is 1 and the provenance says how it was derived. A
tagging strategy may run a fixed model over the text (spaCy's entities), but
it never sees a question, and the term says which strategy found it.

    walk_term     document -> document   both hold a term (terms.py); provenance
                                         {"terms": [{"term", "n", "rank", "by"}]},
                                         n documents hold it, rank is its place
                                         in the source's term list and by names
                                         the tagging strategies that found it
    walk_next     document -> document   the next one said in the same sitting;
                                         provenance {"sitting", "pos"}
    walk_nearest  document -> document   one of the source's k nearest by
                                         cosine; provenance {"rank", "sim"}

THE UNIT IS A DOCUMENT NODE, not a chunk. A document already projects into
aiq.nodes with its resource's owner and visibility, so an edge between two of
them is readable exactly when both ends are (aiq.edges' policy). A chunk is
not a node, and making it one would project every chunk of every tenant. A
term is not a node either: claims.tags is shared vocabulary, readable by
anyone signed in, and a term taken from a private document would publish its
words. So a term rides on the edge between two documents that hold it.

ONE ROW PER ORDERED PAIR. aiq.edges is unique on (src, dst, relation), so two
documents that share three terms get one walk_term edge listing all three, in
each direction, carrying the source's ranks.

A document's text is its chunks in order, unless its resource's metadata
names `terms_text`: the BEAM sample tags the user's words only, as the study
did, while its vectors cover the whole exchange. Its sitting and place come
from metadata {"sitting", "position"}; a document without them has no
walk_next edge. Its vector is the unit mean of its chunks' vectors in the
default embedding space -- the study's mean vectors.

WHAT IT READS FROM aiq.parameters (part `index`): which tagging strategies run
(index.strategies), each one's limits (terms.limits_from), and how many
nearest documents to link (index.nearest). The report names the strategies
that ran, so a walk's result can say which tagger built its store.

IDEMPOTENT, AND RETRACTS RATHER THAN DELETES. A second run upserts what it
derives and sets valid_to on any walk edge among these documents that it no
longer derives, as aiq.edges asks of a derivation.
"""

from __future__ import annotations

import json
import logging
from typing import Any

from . import terms as T

RELATIONS = [
    ("walk_term", "both documents hold the term; provenance terms[{term, n, rank}] (REM-1201)"),
    ("walk_next", "the next document said in the same sitting; provenance {sitting, pos} (REM-1201)"),
    ("walk_nearest", "one of the source document's nearest in meaning; provenance {rank, sim} (REM-1201)"),
]
NEAREST = 10

log = logging.getLogger(__name__)


async def documents(conn: Any, channel: str) -> list[dict[str, Any]]:
    """The channel's ingested documents with their node, text and metadata, in a stable order."""
    rows = await conn.fetch(
        """
        select n.id as node_id, r.id as resource_id, r.metadata,
               coalesce(r.metadata->>'terms_text',
                        (select string_agg(k.content, E'\n' order by k.ordinal)
                           from content.resource_chunks k where k.resource_id = r.id), '') as text
          from content.resources r
          join content.channels c on c.id = r.channel_id
          join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
         where c.name = $1 and r.status = 'ready'
         order by r.id
        """,
        channel,
    )
    out = []
    for r in rows:
        md = r["metadata"]
        out.append({"node": r["node_id"], "resource": r["resource_id"], "text": r["text"],
                    "metadata": json.loads(md) if isinstance(md, str) else (md or {})})
    return out


def term_edges(docs: list[dict[str, Any]], df_floor: int = T.DF_FLOOR, df_share: float = T.DF_SHARE,
               strategies: tuple[str, ...] = ("frequency",), limits: dict[str, dict[str, Any]] | None = None
               ) -> dict[tuple, dict]:
    """walk_term edges from the strategies named. df_floor and df_share are the frequency strategy's cap; `limits`
    (terms.limits_from) carries every strategy's, and wins."""
    lim = {"frequency": {"df_floor": df_floor, "df_share": df_share}}
    for s, v in (limits or {}).items():
        lim[s] = {**lim.get(s, {}), **v}
    tags = T.tag([d["text"] for d in docs], strategies, lim)
    postings = {t: v["docs"] for t, v in tags.items()}
    rank = {i: {t: r for r, t in enumerate(ts)} for i, ts in T.terms_of(postings).items()}
    out: dict[tuple, dict] = {}
    for t, ix in postings.items():
        for a in ix:
            for b in ix:
                if a != b:
                    e = out.setdefault((docs[a]["node"], docs[b]["node"]), {"terms": []})
                    e["terms"].append({"term": t, "n": len(ix), "rank": rank[a][t], "by": tags[t]["by"]})
    for e in out.values():
        e["terms"].sort(key=lambda x: x["rank"])
    return out


def next_edges(docs: list[dict[str, Any]]) -> dict[tuple, dict]:
    sittings: dict[str, list[tuple[int, Any]]] = {}
    for d in docs:
        md = d["metadata"]
        if md.get("sitting") is None or md.get("position") is None:
            continue
        sittings.setdefault(str(md["sitting"]), []).append((int(md["position"]), d["node"]))
    out = {}
    for s, xs in sittings.items():
        xs.sort()
        for (p, a), (_, b) in zip(xs, xs[1:]):
            out[(a, b)] = {"sitting": s, "pos": p}
    return out


async def nearest_edges(conn: Any, docs: list[dict[str, Any]], k: int = NEAREST) -> dict[tuple, dict]:
    """Each document's k nearest by cosine over unit mean chunk vectors, computed in the database."""
    space = await conn.fetchval(
        "select format('aiq.%I', aiq.embedding_space_name(name)) from aiq.embedding_models where is_default")
    if space is None:
        raise RuntimeError("no default embedding model is registered, so documents have no vectors to be near")
    node_of = {d["resource"]: d["node"] for d in docs}
    # A document still embedding would be left out of every nearest list, and nothing would say so.
    unembedded = await conn.fetchval(
        f"""select count(distinct k.resource_id) from content.resource_chunks k
             where k.resource_id = any($1::uuid[])
               and not exists (select 1 from {space} e where e.chunk_id = k.id)""",
        list(node_of))
    if unembedded:
        raise RuntimeError(f"{unembedded} of {len(docs)} documents have a chunk with no vector in {space} yet "
                           "-- wait for ingestion to finish, then index")
    rows = await conn.fetch(
        f"""
        with v as (
            select k.resource_id, avg(e.embedding) as m
              from content.resource_chunks k join {space} e on e.chunk_id = k.id
             where k.resource_id = any($1::uuid[])
             group by k.resource_id),
        u as (select resource_id, l2_normalize(m) as m from v)
        select a.resource_id as src, n.resource_id as dst, n.rank, n.sim
          from u a
          cross join lateral (
              select b.resource_id, 1 - (b.m <=> a.m) as sim,
                     row_number() over (order by b.m <=> a.m, b.resource_id) - 1 as rank
                from u b where b.resource_id <> a.resource_id
               order by b.m <=> a.m, b.resource_id limit $2) n
        """,
        list(node_of), k,
    )
    return {(node_of[r["src"]], node_of[r["dst"]]): {"rank": int(r["rank"]), "sim": round(float(r["sim"]), 6)}
            for r in rows}


async def write(conn: Any, relation: str, edges: dict[tuple, dict], nodes: list[Any]) -> dict[str, int]:
    """Upsert one relation's edges among these nodes, and retract the ones no longer derived."""
    await conn.execute(
        "create temp table if not exists walk_index_edges (src uuid, dst uuid, provenance jsonb) on commit drop")
    await conn.execute("truncate walk_index_edges")
    await conn.copy_records_to_table(
        "walk_index_edges", records=[(a, b, json.dumps(p)) for (a, b), p in edges.items()])
    written = await conn.fetchval(
        """
        with up as (
            insert into aiq.edges (src_id, dst_id, relation, weight, provenance)
            select src, dst, $1, 1.0, provenance from walk_index_edges
            on conflict (src_id, dst_id, relation) do update
               set provenance = excluded.provenance, weight = 1.0, valid_to = null
             where aiq.edges.provenance is distinct from excluded.provenance
                or aiq.edges.valid_to is not null
            returning 1)
        select count(*) from up
        """,
        relation,
    )
    retracted = await conn.fetchval(
        """
        with gone as (
            update aiq.edges e set valid_to = now()
             where e.relation = $1 and e.valid_to is null
               and e.src_id = any($2::uuid[])
               and not exists (select 1 from walk_index_edges w where w.src = e.src_id and w.dst = e.dst_id)
            returning 1)
        select count(*) from gone
        """,
        relation, nodes,
    )
    return {"derived": len(edges), "written": written, "retracted": retracted}


async def parameters(conn: Any) -> dict[str, Any]:
    """The index's rows in aiq.parameters (name without 'index.'), or none on a database that predates the table."""
    if not await conn.fetchval("select to_regclass('aiq.parameters') is not null"):
        return {}
    p = await conn.fetchval("select aiq.parameters_of('index')")
    return json.loads(p) if isinstance(p, str) else (p or {})


async def keep_graph(conn: Any, channel: str) -> str | None:
    """Keep the channel's walk graph as a document (aiq.walk_index), so a walk started over these links records it and
    is read from it afterwards, whatever the links later become (percolate#316). Its uri, or None on a database that
    predates aiq.walk_index. The document is for the walk's default settings; a walk that sets its own span or near
    count reads a graph of its own."""
    if not await conn.fetchval("select to_regprocedure('aiq.walk_index(jsonb,text)') is not null"):
        return None
    try:
        return await conn.fetchval("select aiq.walk_index(jsonb_build_object('channel', $1::text))->>'uri'", channel)
    except Exception as e:  # an extension before percolate#316 has no walk-graphs channel; the links are written
        log.warning("walk index: the graph was not kept for %s: %s", channel, e)
        return None


async def index(conn: Any, channel: str, k: int | None = None) -> dict[str, Any]:
    """Build every walk relation for one channel's documents, in one transaction. k, the nearest count and the term
    fit's cap come from aiq.parameters' index rows; an explicit k wins over the table."""
    p = await parameters(conn)
    k = int(p.get("nearest", NEAREST)) if k is None else k
    df_floor, df_share = int(p.get("df_floor", T.DF_FLOOR)), float(p.get("df_share", T.DF_SHARE))
    strategies = T.strategies_from(p.get("strategies"))
    docs = await documents(conn, channel)
    if not docs:
        raise RuntimeError(f"channel {channel!r} has no ingested documents -- load them, wait for ingestion, then index")
    nodes = [d["node"] for d in docs]
    async with conn.transaction():
        for relation, description in RELATIONS:
            await conn.execute(
                "insert into aiq.relation_types (src_type, relation, dst_type, description, is_symmetric)"
                " values ('document', $1, 'document', $2, false)"
                " on conflict (src_type, relation, dst_type) do update set description = excluded.description",
                relation, description)
        built = {
            "walk_term": term_edges(docs, df_floor, df_share, strategies, limits := T.limits_from(p)),
            "walk_next": next_edges(docs),
            "walk_nearest": await nearest_edges(conn, docs, k),
        }
        report = {"documents": len(docs), "nearest": k, "strategies": list(strategies), "df_floor": df_floor,
                  "df_share": df_share}
        if (made_by := T.provenance(strategies, limits)) is not None:
            report["spacy"] = made_by
        for relation, edges in built.items():
            report[relation] = await write(conn, relation, edges, nodes)
    report["graph"] = await keep_graph(conn, channel)
    return report
