"""Where a walk reads from: Percolate's own tables, or a fixture held in memory.

A DOCUMENT IS A RESOURCE. On Percolate a walk reads the `document` nodes of one channel as the caller: one
resource is one message, registered with a single chunk, and its metadata says where it sits:
`{"sitting": ..., "position": n}`. A document is named by its resource's uri (`beam:1M:22/151`), so a walk's
output names the message rather than a uuid, and a questions file gives its search and gold in the same form. Search is `aiq.search` over the chunks, each hit standing for its resource. The links a
walk follows that are not in the documents themselves are built by construction by `percolate walk index` (REM-1201)
as `aiq.edges` between document nodes:

    walk_term      document -> document  they share terms; provenance {"terms": [{term, n, rank}]}, rank the
                                         term's place in the source's term list. A term's postings are a document
                                         and the targets of its edges carrying the term.
    walk_nearest   document -> document  one of the source's nearest in meaning; provenance {rank, sim}. The walk
                                         reads the first three.

`next` clues need no edge: they are the documents either side in the same sitting, by position.

No verdict is stored anywhere in the graph. What the decider thought of a clue lives in the walk's record and its
verdict file, so the next walk, or the next model, judges for itself.

A FIXTURE IS THE SAME SHAPES IN FILES, for tests and for the study's reference walks: `docs.jsonl` holds
`{"id", "sitting", "pos", "text", "terms": [...], "nearest": [...]}` and `questions.jsonl` holds
`{"id", "text", "search": [...]}`, with search the order a hybrid search returned.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from typing import Any, Hashable, Mapping, Sequence

EDGE_TERM = "walk_term"
EDGE_NEAREST = "walk_nearest"


class MemoryStore:
    """A fixture directory, held in memory."""

    def __init__(self, directory: str | Path):
        d = Path(directory)
        self.docs = {r["id"]: r for r in map(json.loads, (d / "docs.jsonl").read_text().splitlines()) if r}
        self.questions = {str(q["id"]): q for q in
                          map(json.loads, (d / "questions.jsonl").read_text().splitlines()) if q}
        self._post: dict[str, list] = defaultdict(list)
        self._rev: dict[Hashable, list] = defaultdict(list)
        self._at: dict[tuple, Hashable] = {}
        for i, r in self.docs.items():
            for t in r.get("terms", ()):
                self._post[t].append(i)
            for j in r.get("nearest", ()):
                self._rev[j].append(i)
            self._at[r["sitting"], r["pos"]] = i

    def search(self, question: Mapping[str, Any]) -> Sequence[Hashable]:
        return self.questions[str(question["id"])]["search"]

    def text(self, doc: Hashable) -> str:
        return self.docs[doc]["text"]

    def terms(self, doc: Hashable) -> Sequence[str]:
        return self.docs[doc].get("terms", ())

    def postings(self, term: str) -> Sequence[Hashable]:
        return self._post.get(term, ())

    def beside(self, doc: Hashable, span: int) -> Sequence[Hashable]:
        r = self.docs[doc]
        return [self._at[r["sitting"], r["pos"] + k] for k in range(-span, span + 1)
                if k and (r["sitting"], r["pos"] + k) in self._at]

    def nearest(self, doc: Hashable) -> Sequence[Hashable]:
        return list(self.docs[doc].get("nearest", ())) + self._rev.get(doc, [])


class PgStore:
    """A channel's documents in Percolate, loaded once through asyncpg: `await PgStore.load(conn, channel)`.

    Everything the walk can ask is read up front. A walk asks the same few questions of thousands of documents,
    and one query per question per document would spend its time on round trips; a channel of a few thousand chunks
    is a few megabytes. The walk then runs on what was read, so a store that changes mid-walk cannot make one walk
    read two corpora. The connection's role decides what is visible: connect as the caller, and RLS applies.
    """

    def __init__(self) -> None:
        self._text: dict[str, str] = {}
        self._at: dict[tuple, str] = {}
        self._place: dict[str, tuple] = {}
        self._terms: dict[str, list[str]] = defaultdict(list)
        self._post: dict[str, list[str]] = defaultdict(list)
        self._near: dict[str, list[str]] = defaultdict(list)
        self._rev: dict[str, list[str]] = defaultdict(list)
        self._orders: dict[str, list[str]] = {}
        self._chunk: dict[str, str] = {}

    @classmethod
    async def load(cls, conn: Any, channel: str, near: int = 3) -> "PgStore":
        self = cls()
        rows = await conn.fetch("""
            select n.id::text as node, coalesce(r.uri, r.external_id, r.id::text) as id,
                   r.metadata->>'sitting' as sitting, (r.metadata->>'position')::int as pos,
                   (select string_agg(c.content, ' ' order by c.ordinal)
                      from content.resource_chunks c where c.resource_id = r.id) as content,
                   (select array_agg(c.id::text) from content.resource_chunks c where c.resource_id = r.id) as chunks
              from content.resources r
              join content.channels ch on ch.id = r.channel_id
              join aiq.nodes n on n.entity_type = 'document' and n.entity_id = r.id
             where ch.name = $1 and r.status = 'ready'""", channel)
        if not rows:
            raise LookupError(f"no documents in channel {channel!r}: load the sample first")
        by_node = {}
        for r in rows:
            self._text[r["id"]] = r["content"] or ""
            if r["sitting"] is not None and r["pos"] is not None:
                self._at[r["sitting"], r["pos"]] = r["id"]
                self._place[r["id"]] = (r["sitting"], r["pos"])
            for c in r["chunks"] or ():
                self._chunk[c] = r["id"]
            by_node[r["node"]] = r["id"]
        nodes = list(by_node)
        for r in await conn.fetch("""
                select e.src_id::text as a, e.dst_id::text as b, t->>'term' as term
                  from aiq.edges_current e, jsonb_array_elements(e.provenance->'terms') t
                 where e.relation = $1 and e.src_id = any($2::uuid[])
                 order by e.src_id, (t->>'rank')::int, e.dst_id""", EDGE_TERM, nodes):
            a, b, t = by_node.get(r["a"]), by_node.get(r["b"]), r["term"]
            if a is None or b is None:
                continue
            if t not in self._terms[a]:
                self._terms[a].append(t)
            for x in (a, b):
                if x not in self._post[t]:
                    self._post[t].append(x)
        for r in await conn.fetch("""
                select e.src_id::text as a, e.dst_id::text as b
                  from aiq.edges_current e
                 where e.relation = $1 and e.src_id = any($2::uuid[]) and (e.provenance->>'rank')::int < $3
                 order by e.src_id, (e.provenance->>'rank')::int""", EDGE_NEAREST, nodes, near):
            a, b = by_node.get(r["a"]), by_node.get(r["b"])
            if a is not None and b is not None:
                self._near[a].append(b)
                self._rev[b].append(a)
        if not self._post:
            raise LookupError(f"channel {channel!r} has no walk links: run `percolate walk index` first")
        return self

    async def order(self, conn: Any, question: Mapping[str, Any], vector: Sequence[float], limit: int = 2000) -> None:
        """Search's order for the question, from `aiq.search` over the chunks, kept for `search`."""
        rows = await conn.fetch("select chunk_id::text as id from aiq.search('chunks', $1, $2::vector, null, $3)",
                                question["text"], "[" + ",".join(map(str, vector)) + "]", limit)
        order: list[str] = []
        for r in rows:  # a hit stands for its document, at the rank of its best chunk
            doc = self._chunk.get(r["id"])
            if doc is not None and doc not in order:
                order.append(doc)
        self._orders[str(question["id"])] = order

    def search(self, question: Mapping[str, Any]) -> Sequence[Hashable]:
        if question.get("search"):
            return question["search"]
        try:
            return self._orders[str(question["id"])]
        except KeyError:
            raise LookupError(f"no search order for {question['id']!r}: call order() first") from None

    def text(self, doc: Hashable) -> str:
        return self._text[doc]

    def terms(self, doc: Hashable) -> Sequence[str]:
        return self._terms.get(doc, ())

    def postings(self, term: str) -> Sequence[Hashable]:
        return self._post.get(term, ())

    def beside(self, doc: Hashable, span: int) -> Sequence[Hashable]:
        if doc not in self._place:
            return []
        s, o = self._place[doc]
        return [self._at[s, o + k] for k in range(-span, span + 1) if k and (s, o + k) in self._at]

    def nearest(self, doc: Hashable) -> Sequence[Hashable]:
        return self._near.get(doc, []) + self._rev.get(doc, [])
