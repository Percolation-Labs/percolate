"""The clue walk: read in waves, and between waves let a decider choose where to look next.

A walk answers one question over one store. Search supplies the first reads. Every read can raise CLUES: a term it
shares with a few unread documents, the documents just before and after it in its sitting, or the documents closest
to it in meaning. A clue is a lead, not a fact: it names the unread documents it would reach and says, in one line,
why they might matter. The decider gives each clue a P, and P >= 0.5 accepts it (Sirsh, 25 Oct: the model says yes
or no, the graph orders). Each step travels the K best accepted clues, and what they reach is read next.

THE DECIDER ACTS BEFORE THE READ. A judgement made after a row is read has already paid for the row (part three,
experiment 3). Clues are judged on their one-line description; the documents behind them are read only if the walk
travels there.

THE RECORD IS THE OUTPUT. Everything `walk why` says about an incomplete answer comes from what is written here:
every clue raised, with its targets, P and fate; every travel; the reads of each wave; and the leads still open at
the stop. Nothing is recomputed from the store afterwards, because the store may have changed since.

Ported read for read from the BEAM study's `beam_waves2.walk` (p8-lme ff1c6d94); `tests/test_walk.py` holds the
two to the same reads on a fixture.
"""

from __future__ import annotations

import random
from collections import Counter
from dataclasses import asdict, dataclass
from typing import Any, Awaitable, Callable, Hashable, Mapping, Protocol, Sequence

RECORD_VERSION = 1

# The decider's task, as the study worded it from 25 Oct. A verdict belongs to its wording, so the wording is
# written into every record and verdict file, and a replay refuses verdicts given under another one.
TASK = ("For each option, a lead into the user's earlier messages that has not been read yet: a term the messages "
        "share, or the messages beside or close in meaning to one already read. Would following it likely reach "
        "information needed to answer `question`, or part of it?")
SNIP = 160


class Store(Protocol):
    """What a walk reads. `PgStore` reads Percolate's aiq graph; `MemoryStore` holds a fixture in memory."""

    def search(self, question: Mapping[str, Any]) -> Sequence[Hashable]: ...
    def text(self, doc: Hashable) -> str: ...
    def terms(self, doc: Hashable) -> Sequence[str]: ...
    def postings(self, term: str) -> Sequence[Hashable]: ...
    def beside(self, doc: Hashable, span: int) -> Sequence[Hashable]: ...
    def nearest(self, doc: Hashable) -> Sequence[Hashable]: ...


# question, {clue key: one-line description} -> {clue key: P}. A key missing from the answer is unjudged.
Decide = Callable[[Mapping[str, Any], Mapping[str, str]], Awaitable[Mapping[str, float]]]


@dataclass(frozen=True)
class Settings:
    """The study's settings. The defaults are its test arm, explore10_all (M-20261026-133335-9832)."""

    waves: int = 10
    wave: int = 50          # reads per wave
    k: int = 3              # clues travelled per step
    seeds: int = 10         # search reads in the first wave that raise clues
    per_wave: int = 10      # search reads at the start of every later wave
    span: int = 2           # `next` clues reach this many documents either side in the sitting
    cap: int = 10           # a term clue only for a term at most this many documents share
    gate: float = 0.5
    policy: str = "explore"  # best: the K best accepted; explore: K-1 best, and one drawn from every judged clue by P
    expand_all: bool = True  # every read raises clues; False: only search's seeds and what clues reach

    def __post_init__(self) -> None:
        if self.policy not in ("best", "explore"):
            raise ValueError(f"policy is best or explore, not {self.policy!r}")


def snippet(text: str, around: str | None = None) -> str:
    t = " ".join(text.split())
    if around:
        i = t.lower().find(around.lower())
        if i > SNIP // 2:
            t = "…" + t[i - SNIP // 2:]
    return t[:SNIP]


def key(kind: str, x: Any) -> str:
    return f"{kind}:{x}"


def _clues(store: Store, s: Settings, sources: Sequence[Hashable], reached: set, judged: set
           ) -> dict[tuple, tuple[str, list]]:
    """{(kind, x): (description, unread targets)} for clues out of `sources` that lead somewhere new and were never
    judged. The order of `sources` decides only which description a term keeps."""
    out: dict[tuple, tuple[str, list]] = {}
    for src in sources:
        for t in store.terms(src):
            post = store.postings(t)
            if len(post) <= s.cap and ("term", t) not in judged:
                tg = [x for x in post if x not in reached]
                if tg:
                    old = out.get(("term", t))
                    out[("term", t)] = (
                        old[0] if old else f"the term '{t}', which {len(tg)} unread message(s) share with this read "
                                           f"one: \"{snippet(store.text(src), t)}\"",
                        sorted(set(tg) | set(old[1] if old else ())))
        for kind, nb, label in (
                ("next", store.beside(src, s.span), "the messages just before and after this read one, in the same sitting"),
                ("near", store.nearest(src), "the messages closest in meaning to this read one")):
            tg = sorted({x for x in nb if x not in reached and x != src})
            if tg and (kind, src) not in judged:
                out[(kind, src)] = (f"{label}: \"{snippet(store.text(src))}\"", tg)
    return out


async def walk(store: Store, question: Mapping[str, Any], decide: Decide, settings: Settings = Settings()
               ) -> dict[str, Any]:
    """Walk `question` ({"id", "text"}) and return its record."""
    s = settings
    order = list(store.search(question))
    readset: set = set()
    reached: set = set()
    judged: set = set()
    open_: dict[tuple, tuple] = {}
    rejected: dict[tuple, tuple] = {}
    pending: list = []
    expand: list = []
    travelled: list[dict] = []
    clues_log: list[dict] = []
    out_waves: list[dict] = []
    sighted: Counter = Counter()
    si = step = unjudged = 0
    rng = random.Random(question["id"])
    stop = {"reason": "waves", "detail": f"all {s.waves} waves walked"}

    def from_search(n: int) -> list[tuple[Hashable, bool]]:
        nonlocal si
        got = []
        while len(got) < n and si < len(order):
            if order[si] not in readset:
                got.append((order[si], s.expand_all or si < s.seeds))
            si += 1
        return got

    for w in range(s.waves):
        reads: list = []
        expanded: list = []
        n_judged = n_acc = n_src = n_fresh = 0

        def add(doc: Hashable, follow: bool) -> None:
            readset.add(doc)
            reached.add(doc)
            reads.append(doc)
            if follow:
                expand.append(doc)

        for doc, seed in from_search(max(s.per_wave, s.seeds) if w == 0 else s.per_wave):
            add(doc, seed)
        dry = False
        while len(reads) < s.wave:
            while pending and len(reads) < s.wave:
                add(pending.pop(0), True)
            if len(reads) >= s.wave:
                break
            step += 1
            cl = _clues(store, s, expand, reached, judged)
            srcs, expand = expand, []
            P = dict(await decide(question, {key(*c): v[0] for c, v in cl.items()})) if cl else {}
            judged |= set(cl)
            fresh: set = set()
            for c, (text, tg) in sorted(cl.items(), key=lambda kv: key(*kv[0])):
                p = P.get(key(*c))
                fate = "unjudged" if p is None else "accepted" if p >= s.gate else "rejected"
                clues_log.append({"key": key(*c), "kind": c[0], "wave": w + 1, "step": step, "text": text,
                                  "targets": list(tg), "P": None if p is None else round(p, 3), "decision": fate})
                if p is None:
                    unjudged += 1
                    continue
                n_judged += 1
                if p >= s.gate:
                    open_[c] = (p, tg, step, w + 1)
                    n_acc += 1
                    sighted.update(tg)
                    fresh |= {c[1]} if c[0] != "term" else {x for x in srcs if c[1] in store.terms(x)}
                elif s.policy == "explore":
                    rejected[c] = (p, tg, step, w + 1)
            n_src += len(srcs)
            expanded += srcs
            n_fresh += len(fresh & set(srcs))
            picked: list = []
            while len(picked) < s.k:
                for c in [c for c in open_ if all(x in reached for x in open_[c][1])]:
                    del open_[c]
                for c in [c for c in rejected if all(x in reached for x in rejected[c][1])]:
                    del rejected[c]
                if s.policy == "explore" and (len(picked) == s.k - 1 or not open_) and (open_ or rejected):
                    pool = sorted(set(open_) | set(rejected), key=lambda c: key(*c))
                    c = rng.choices(pool, weights=[(open_.get(c) or rejected[c])[0] for c in pool])[0]
                    p, tg, born, born_w = open_.pop(c) if c in open_ else rejected.pop(c)
                    rank: Any = "drawn"
                elif not open_:
                    break
                else:
                    c = min(open_, key=lambda c: (-open_[c][0], key(*c)))
                    p, tg, born, born_w = open_.pop(c)
                    rank = 1 + sum(v[0] > p for v in open_.values()) + len(picked)
                land = [x for x in tg if x not in reached]
                reached |= set(land)
                pending += land
                travelled.append({"key": key(*c), "kind": c[0], "wave": w + 1, "step": step, "P": round(p, 3),
                                  "born_wave": born_w, "born_step": born, "rank": rank, "land": land})
                picked.append(c)
            if not picked and not pending:
                for doc, _ in from_search(s.wave - len(reads)):
                    add(doc, s.expand_all)
                if len(reads) < s.wave:
                    dry = True
                    break
        still = {c: v for c, v in open_.items() if any(x not in reached for x in v[1])}
        out_waves.append({
            "wave": w + 1, "reads": reads, "expanded_reads": expanded, "judged": n_judged, "accepted": n_acc, "expanded": n_src,
            # getting warmer: the share of this wave's expanded reads that raised a newly accepted clue
            "fresh": round(n_fresh / n_src, 4) if n_src else None,
            "singletons": round(sum(v == 1 for v in sighted.values()) / max(1, sum(sighted.values())), 4),
            # the certificate: accepted clues still open, with how many unread documents each leads to
            "open": sorted(([key(*c), round(v[0], 3), sum(x not in reached for x in v[1])] for c, v in still.items()),
                           key=lambda r: (-r[1], r[0])),
        })
        if dry:
            stop = {"reason": "dry", "detail": f"nothing left to read after wave {w + 1}"}
            break
    return {
        "version": RECORD_VERSION,
        "question": {"id": question["id"], "text": question["text"]},
        "settings": asdict(s),
        "task": TASK,
        "search": order[:si],
        "waves": out_waves,
        "clues": clues_log,
        "travelled": travelled,
        "pending": pending,
        "open": {key(*c): {"P": round(v[0], 3), "wave": v[3], "targets": list(v[1])} for c, v in open_.items()},
        "rejected_open": {key(*c): {"P": round(v[0], 3), "wave": v[3], "targets": list(v[1])}
                          for c, v in rejected.items()},
        "unjudged": unjudged,
        "reads": sum(len(w["reads"]) for w in out_waves),
        "stop": stop,
    }
