"""The conjunction control, measured (README.md has the protocol and the predictions).

    python measure.py sub        # questions.jsonl -> kept sub-questions and candidate sets
    python measure.py compounds  # compounds.jsonl -> retrieval and geometry, out/measure.json
    python measure.py jev        # Jev on each compound, out/jev.jsonl
    python measure.py report     # out/report.json and the tables for RESULTS.md

Retrieval is cosine over the Dracula passages with the model the store was
built with, so nothing here depends on the database: the question is about
the geometry of the question, not the plumbing.
"""
from __future__ import annotations

import asyncio
import itertools
import json
import math
import os
import random
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))
STORE = HERE.parent / "navigate" / "store"
# A second set runs through the same code from its own folder (CONJ_SET=fresh).
DATA = HERE / os.environ["CONJ_SET"] if os.environ.get("CONJ_SET") else HERE
OUT = DATA / "out"
MODEL = "BAAI/bge-small-en-v1.5"
K = 10
ORTHOGONAL_MAX = 0.66       # every pair of gold passages below this cosine (10th pct)
RELATED_MIN = 0.82          # pairs at or above it (90th pct)
STORE_LINE = ("Bram Stoker's Dracula (1897) as dated documents: journal entries, letters, "
              "telegrams, newspaper cuttings and the log of the ship Demeter.")


def read(p: Path) -> list[dict]:
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def store():
    P = read(STORE / "passages.jsonl")
    V = np.load(STORE / "vectors.npy")
    return P, V, {p["id"]: i for i, p in enumerate(P)}


_model = None


def embed(texts: list[str]) -> np.ndarray:
    global _model
    if _model is None:
        from fastembed import TextEmbedding
        _model = TextEmbedding(MODEL)
    v = np.array(list(_model.embed(texts)), dtype=np.float32)
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def topk(V: np.ndarray, q: np.ndarray, k: int) -> list[int]:
    return [int(i) for i in np.argsort(-(V @ q))[:k]]


def rank(V: np.ndarray, q: np.ndarray, i: int) -> int:
    s = V @ q
    return int((s > s[i]).sum()) + 1


def sub() -> None:
    P, V, idx = store()
    qs = read(DATA / "questions.jsonl")
    E = embed([q["question"] for q in qs])
    kept = []
    for q, e in zip(qs, E):
        r = rank(V, e, idx[q["id"]])
        q["rank_alone"] = r
        if r <= K:
            kept.append(q)
    print(f"{len(kept)} of {len(qs)} sub-questions find their passage alone in the top {K}")
    sample = json.loads((OUT / "sample.json").read_text()) if (OUT / "sample.json").exists() else None
    G = {q["id"]: V[idx[q["id"]]] for q in kept}
    ids = [q["id"] for q in kept]
    rng = random.Random(18)
    ortho2 = [c for c in itertools.combinations(ids, 2)
              if float(G[c[0]] @ G[c[1]]) < ORTHOGONAL_MAX]
    ortho3 = [c for c in itertools.combinations(ids, 3)
              if all(float(G[a] @ G[b]) < ORTHOGONAL_MAX for a, b in itertools.combinations(c, 2))]
    related = [c for c in itertools.combinations(ids, 2)
               if float(G[c[0]] @ G[c[1]]) >= RELATED_MIN]
    pick = lambda xs, n: rng.sample(xs, min(n, len(xs)))
    sets = ([{"group": "orthogonal", "parts": list(c)} for c in pick(ortho2, 30)]
            + [{"group": "orthogonal", "parts": list(c)} for c in pick(ortho3, 20)]
            + [{"group": "related", "parts": list(c)} for c in pick(related, 30)])
    byid = {q["id"]: q for q in kept}
    for i, s in enumerate(sets):
        s["set"] = f"c{i:03d}"
        s["questions"] = [byid[p]["question"] for p in s["parts"]]
        s["gold_cos"] = [round(float(G[a] @ G[b]), 3) for a, b in itertools.combinations(s["parts"], 2)]
    OUT.mkdir(exist_ok=True)
    (OUT / "kept.jsonl").write_text("".join(json.dumps(q) + "\n" for q in kept))
    (OUT / "sets.jsonl").write_text("".join(json.dumps(s) + "\n" for s in sets))
    print(f"orthogonal pairs {len(ortho2)} triples {len(ortho3)} related {len(related)}; "
          f"sampled {sum(s['group'] == 'orthogonal' for s in sets)} orthogonal, "
          f"{sum(s['group'] == 'related' for s in sets)} related")


def compounds() -> None:
    P, V, idx = store()
    sets = {s["set"]: s for s in read(OUT / "sets.jsonl")}
    comps = read(DATA / "compounds.jsonl")
    C = embed([c["compound"] for c in comps])
    rows = []
    for c, e in zip(comps, C):
        s = sets[c["set"]]
        gold = [idx[p] for p in s["parts"]]
        n = len(gold)
        PE = embed(s["questions"])
        comp_top = set(topk(V, e, K))
        budget = math.ceil(K / n)
        dec_budget = set().union(*(topk(V, pe, budget) for pe in PE))
        dec_full = set().union(*(topk(V, pe, K) for pe in PE))
        rec = lambda got: sum(g in got for g in gold) / n
        rows.append({
            "set": c["set"], "group": s["group"], "parts": n, "compound": c["compound"],
            "gold_cos": s["gold_cos"],
            "recall_compound": rec(comp_top), "recall_decomposed": rec(dec_budget),
            "recall_decomposed_full": rec(dec_full),
            "gain": rec(dec_budget) - rec(comp_top),
            "rank_compound": [rank(V, e, g) for g in gold],
            "rank_alone": [rank(V, pe, g) for pe, g in zip(PE, gold)],
            "cos_compound": [round(float(V[g] @ e), 3) for g in gold],
            "cos_alone": [round(float(V[g] @ pe), 3) for pe, g in zip(PE, gold)],
        })
    (OUT / "measure.json").write_text(json.dumps(rows, indent=1) + "\n")
    print(f"{len(rows)} compounds measured")


async def jev() -> None:
    from percolate_core.decide import Jev
    from percolate_core.semantic_exceptions import SemanticExceptions
    comps = read(DATA / "compounds.jsonl")
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as j:
        sx = SemanticExceptions(j, store=STORE_LINE)

        async def one(c):
            p, _ = await sx.probabilities(c["compound"])
            return {"set": c["set"], "p": {k: round(v, 3) for k, v in p.items()}}
        rows = await asyncio.gather(*(one(c) for c in comps))
    (OUT / "jev.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{len(rows)} compounds judged")




async def detect() -> None:
    """Jev on the two properties the README names, read from the question alone:
    how many independent parts it asks, and whether they are about unrelated
    subjects. Each asked of every compound; scored in report()."""
    from percolate_core.decide import Choice, Jev, Noul
    parts = Choice("How many separate things does `question` ask to be found, each of which "
                   "could be searched for on its own?",
                   {"one": "a single thing, however detailed", "two": "two separate things",
                    "three_or_more": "three or more separate things"})
    unrelated = Noul("Are the things `question` asks about unrelated to each other, so that "
                     "no single passage of `store` would be likely to answer them together?",
                     yes="its parts concern different people, places, times or events",
                     no="its parts concern the same person, place, time or event, or one "
                        "part depends on another")
    comps = read(DATA / "compounds.jsonl")
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as j:
        async def one(c):
            r = await j.ask({"question": c["compound"], "store": STORE_LINE},
                            {"parts": parts, "unrelated": unrelated})
            return {"set": c["set"], "parts": r["parts"].value,
                    "parts_p": r["parts"].probabilities, "unrelated": round(r["unrelated"].p, 3)}
        rows = await asyncio.gather(*(one(c) for c in comps))
    (OUT / "detect.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{len(rows)} compounds read for parts and relatedness")


def report() -> None:
    from percolate_core.semantic_exceptions import KINDS
    thr = {k.code: k.threshold for k in KINDS if k.judged}
    m = json.loads((OUT / "measure.json").read_text())
    jv = {r["set"]: r["p"] for r in read(OUT / "jev.jsonl")} if (OUT / "jev.jsonl").exists() else {}
    mean = lambda xs: round(sum(xs) / len(xs), 3) if xs else None
    out: dict = {"k": K, "groups": {}}
    for g, n in [("orthogonal", 2), ("orthogonal", 3), ("related", 2)]:
        rs = [r for r in m if r["group"] == g and r["parts"] == n]
        out["groups"][f"{g}-{n}"] = {
            "compounds": len(rs),
            "recall_compound": mean([r["recall_compound"] for r in rs]),
            "recall_decomposed": mean([r["recall_decomposed"] for r in rs]),
            "recall_decomposed_full": mean([r["recall_decomposed_full"] for r in rs]),
            "gain": mean([r["gain"] for r in rs]),
            "splitting_helps": sum(r["gain"] > 0 for r in rs),
            "median_rank_compound": float(np.median([x for r in rs for x in r["rank_compound"]])) if rs else None,
            "median_rank_alone": float(np.median([x for r in rs for x in r["rank_alone"]])) if rs else None,
        }
    if jv:
        for code in ("DECOMPOSITION_REQUIRED", "TWO_QUESTIONS", "CONJUNCTION"):
            fires = lambda r: jv[r["set"]].get(code, 0) >= thr[code]
            helps = [r for r in m if r["group"] == "orthogonal" and r["gain"] > 0]
            ortho = [r for r in m if r["group"] == "orthogonal"]
            rel = [r for r in m if r["group"] == "related"]
            fired = [r for r in m if fires(r)]
            out.setdefault("jev", {})[code] = {
                "threshold": thr[code],
                "fires_where_splitting_helps": f"{sum(fires(r) for r in helps)}/{len(helps)}",
                "fires_on_orthogonal": f"{sum(fires(r) for r in ortho)}/{len(ortho)}",
                "false_alarms_on_related": f"{sum(fires(r) for r in rel)}/{len(rel)}",
                "mean_gain_where_it_fires": mean([r["gain"] for r in fired]),
                "mean_gain_where_silent": mean([r["gain"] for r in m if not fires(r)]),
            }
    if (OUT / "detect.jsonl").exists():
        dt = {r["set"]: r for r in read(OUT / "detect.jsonl")}
        word = {"one": 1, "two": 2, "three_or_more": 3}
        right = sum(word.get(dt[r["set"]]["parts"], 0) == r["parts"] for r in m)
        out["detect"] = {"parts_counted_right": f"{right}/{len(m)}"}
        for t in (0.5, 0.7, 0.9):
            hit = lambda r: dt[r["set"]]["unrelated"] >= t
            out["detect"][f"unrelated>={t}"] = {
                "orthogonal": f"{sum(hit(r) for r in m if r['group'] == 'orthogonal')}"
                              f"/{sum(r['group'] == 'orthogonal' for r in m)}",
                "related": f"{sum(hit(r) for r in m if r['group'] == 'related')}"
                           f"/{sum(r['group'] == 'related' for r in m)}",
                "mean_gain_flagged": mean([r["gain"] for r in m if hit(r)]),
                "mean_gain_not_flagged": mean([r["gain"] for r in m if not hit(r)])}
    (OUT / "report.json").write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    step = sys.argv[1]
    if step == "jev":
        asyncio.run(jev())
    elif step == "detect":
        asyncio.run(detect())
    else:
        {"sub": sub, "compounds": compounds, "report": report}[step]()
