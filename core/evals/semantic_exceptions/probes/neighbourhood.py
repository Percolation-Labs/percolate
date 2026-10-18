"""P4: does the nearest passage say whether the store holds the answer? (README.md)

    python neighbourhood.py measure   # top-1 cosine and Jev's OUT_OF_DOMAIN, out/p4.jsonl
    python neighbourhood.py report    # AUCs and per-group hits, out/p4-report.json
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))
STORE = HERE.parent / "navigate" / "store"
CONJ = HERE.parent / "conjunction"
OUT = HERE / "out"
STORE_LINE = ("Bram Stoker's Dracula (1897) as dated documents: journal entries, letters, "
              "telegrams, newspaper cuttings and the log of the ship Demeter.")


def read(p: Path) -> list[dict]:
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def auc(pos: list[float], neg: list[float]) -> float:
    """P(a random positive scores above a random negative); ties count half."""
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return round(wins / (len(pos) * len(neg)), 3)


async def measure() -> None:
    from fastembed import TextEmbedding
    from percolate_core.decide import Jev
    from percolate_core.semantic_exceptions import SemanticExceptions
    V = np.load(STORE / "vectors.npy")
    items = ([{"set": "in", "group": 0, "question": q["question"]}
              for q in read(CONJ / "questions.jsonl") + read(CONJ / "fresh" / "questions.jsonl")]
             + [{"set": "out", "group": q["group"], "question": q["question"]}
                for q in read(HERE / "ood.jsonl")])
    m = TextEmbedding("BAAI/bge-small-en-v1.5")
    E = np.array(list(m.embed([i["question"] for i in items])), dtype=np.float32)
    E /= np.linalg.norm(E, axis=1, keepdims=True)
    for i, e in zip(items, E):
        s = np.sort(V @ e)[::-1]
        i["top1"], i["top5_mean"] = round(float(s[0]), 4), round(float(s[:5].mean()), 4)
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as j:
        sx = SemanticExceptions(j, store=STORE_LINE)

        async def one(i):
            p, _ = await sx.probabilities(i["question"])
            i["ood_p"] = round(p.get("OUT_OF_DOMAIN", 0.0), 3)
        await asyncio.gather(*(one(i) for i in items))
    OUT.mkdir(exist_ok=True)
    (OUT / "p4.jsonl").write_text("".join(json.dumps(i) + "\n" for i in items))
    print(len(items), "questions measured")


def report() -> None:
    rows = read(OUT / "p4.jsonl")
    inn = [r for r in rows if r["set"] == "in"]
    out = [r for r in rows if r["set"] == "out"]
    far = lambda r: -r["top1"]                       # higher = more out of domain
    comb = lambda r: r["ood_p"] - (r["top1"] - 0.75) * 4
    rep = {"in_domain": len(inn), "out_of_domain": len(out),
           "auc_top1": auc([far(r) for r in out], [far(r) for r in inn]),
           "auc_top5_mean": auc([-r["top5_mean"] for r in out], [-r["top5_mean"] for r in inn]),
           "auc_jev_question_only": auc([r["ood_p"] for r in out], [r["ood_p"] for r in inn]),
           "auc_combined": auc([comb(r) for r in out], [comb(r) for r in inn])}
    # The threshold that keeps 95% of in-domain questions in (5% false alarms).
    t = float(np.percentile([r["top1"] for r in inn], 5))
    rep["top1_threshold_at_5pct_false_alarms"] = round(t, 4)
    rep["out_of_domain_caught_by_group"] = {
        str(g): f"{sum(r['top1'] < t for r in out if r['group'] == g)}"
                f"/{sum(r['group'] == g for r in out)}" for g in range(1, 9)}
    rep["jev_at_0.92"] = {"in_domain_flagged": sum(r["ood_p"] >= 0.92 for r in inn),
                          "out_of_domain_flagged": sum(r["ood_p"] >= 0.92 for r in out)}
    rep["median_top1"] = {"in": round(float(np.median([r["top1"] for r in inn])), 3),
                          "out": round(float(np.median([r["top1"] for r in out])), 3)}
    (OUT / "p4-report.json").write_text(json.dumps(rep, indent=1) + "\n")
    print(json.dumps(rep, indent=1))


if __name__ == "__main__":
    asyncio.run(measure()) if sys.argv[1] == "measure" else report()
