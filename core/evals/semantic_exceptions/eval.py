"""The semantic-exceptions eval: assemble fixtures, ask Jev, score against two labellers.

    python evals/semantic_exceptions/eval.py assemble   # fixtures/gen_*.jsonl -> items + label batches
    python evals/semantic_exceptions/eval.py run        # Jev, cached in out/probs.jsonl
    python evals/semantic_exceptions/eval.py score      # out/scores.json and the RESULTS.md tables

README.md is the protocol, and its bars were committed before any fixture
existed. JEV_API_KEY comes from the environment.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))

from dataclasses import replace  # noqa: E402

from percolate_core.semantic_exceptions import KINDS, SemanticExceptions  # noqa: E402

FIX = HERE / "fixtures"
# A variant (contract/variant-*.json) overrides kinds by code, and gets its own
# out/<tag>/ so a calibration is measured beside the shipped wording, not over it.
VARIANT = json.loads(Path(os.environ["SX_VARIANT"]).read_text()) if os.environ.get("SX_VARIANT") else {}
OUT = HERE / "out" / os.environ["SX_TAG"] if os.environ.get("SX_TAG") else HERE / "out"
KINDS = tuple(replace(k, **VARIANT.get(k.code, {})) for k in KINDS)
STORES = {
    "dracula": "Bram Stoker's Dracula (1897) as dated documents: journal entries (Jonathan "
               "Harker, Mina Murray/Harker, Dr John Seward's phonograph diary), letters (Lucy "
               "Westenra, Arthur Holmwood, Quincey Morris, Van Helsing), telegrams, newspaper "
               "cuttings and the log of the ship Demeter.",
    "eng": "A mid-size software company's engineering records: tickets, incident postmortems, "
           "design documents, commit messages and on-call notes, written by its engineers over "
           "several years.",
}
Q_KINDS = [k.code for k in KINDS if k.judged and k.stage == "question"]
V_KINDS = [k.code for k in KINDS if k.judged and k.stage == "values"]
BATCHES = 2          # label batches per stage; each labelled by two independent labellers
GRID = [round(0.05 * i, 2) for i in range(1, 20)]


def read(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def write(path: Path, rows) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))


def ident(prefix: str, *parts: str) -> str:
    return prefix + hashlib.sha1("\x1f".join(parts).encode()).hexdigest()[:10]


def assemble() -> None:
    qs, vs = [], []
    for f in sorted(FIX.glob("gen_*.jsonl")):
        for r in read(f):
            if "passage" in r:
                r["id"] = ident("v-", r["question"], r["passage"], r.get("other", ""))
                vs.append(r)
            else:
                r["id"] = ident("q-", r["question"])
                qs.append(r)
    for name, items in (("question", qs), ("values", vs)):
        seen = {}
        for r in items:
            seen.setdefault(r["id"], r)
        items = sorted(seen.values(), key=lambda r: r["id"])
        write(FIX / f"items_{name}.jsonl", items)
        blind = [{k: r[k] for k in ("id", "domain", "question", "passage", "other") if k in r}
                 for r in items]
        random.Random(18).shuffle(blind)
        for b in range(BATCHES):
            write(FIX / f"label_{name}_{b}.jsonl", blind[b::BATCHES])
        print(name, len(items), "items")


async def run() -> None:
    from percolate_core.decide import Jev
    OUT.mkdir(parents=True, exist_ok=True)
    cache = OUT / "probs.jsonl"
    done = {r["id"] for r in read(cache)} if cache.exists() else set()
    qs = [r for r in read(FIX / "items_question.jsonl") if r["id"] not in done]
    vs = [r for r in read(FIX / "items_values.jsonl") if r["id"] not in done]
    every = [k.code for k in KINDS]
    async with Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8) as jev:
        sx = {d: SemanticExceptions(jev, kinds=KINDS, enable=every, store=s)
              for d, s in STORES.items()}

        async def one_q(r):
            ps, rep = await sx[r["domain"]].probabilities(r["question"])
            return {"id": r["id"], "model": rep.model, "p": ps}

        async def one_v(r):
            hits = [{"id": 0, "content": r["passage"]}]
            if r.get("other"):
                hits.append({"id": 1, "content": r["other"]})
            s = SemanticExceptions(jev, kinds=KINDS, enable=every, values_top=len(hits),
                                   conflict_top=2)
            probs, _, rep = await s.value_probabilities(r["question"], hits)
            p = {k.partition(":")[0]: v for k, v in probs[0].items()}
            return {"id": r["id"], "model": rep.model, "p": p}

        rows = await asyncio.gather(*([one_q(r) for r in qs] + [one_v(r) for r in vs]))
        with cache.open("a") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
        print(f"{len(rows)} items asked, {jev.requests} requests, {jev.input_tokens} input tokens")


def prf(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    return p, r, (2 * p * r / (p + r) if p + r else 0.0)


def score() -> None:
    probs = {r["id"]: r for r in read(OUT / "probs.jsonl")}
    models = {r["model"] for r in probs.values()}
    out = {"models": sorted(models), "stages": {}}
    for stage, codes in (("question", Q_KINDS), ("values", V_KINDS)):
        items = {r["id"]: r for r in read(FIX / f"items_{stage}.jsonl")}
        labels: dict[str, list[set]] = {}
        for f in sorted(FIX.glob(f"labels_{stage}_*_L*.jsonl")):
            for r in read(f):
                labels.setdefault(r["id"], []).append(set(r["kinds"]))
        two = {i: ls for i, ls in labels.items() if len(ls) >= 2 and i in items and i in probs}
        test = lambda i: int(hashlib.sha1(i.encode()).hexdigest(), 16) % 2  # noqa: E731
        per = {}
        for c in codes:
            if c == "CONFLICT":
                pool = {i: ls for i, ls in two.items() if items[i].get("other")}
            elif c == "OUT_OF_DOMAIN" or stage == "values":
                pool = two
            else:
                pool = two
            agree = {i: c in ls[0] for i, ls in pool.items() if (c in ls[0]) == (c in ls[1])}
            agreement = len(agree) / len(pool) if pool else 0.0
            target_hit = [c in ls[0] and c in ls[1] for i, ls in pool.items()
                          if items[i]["target"] == c]

            def counts(ids, t):
                tp = sum(1 for i in ids if agree[i] and probs[i]["p"][c] >= t)
                fp = sum(1 for i in ids if not agree[i] and probs[i]["p"][c] >= t)
                fn = sum(1 for i in ids if agree[i] and probs[i]["p"][c] < t)
                return tp, fp, fn
            train = [i for i in agree if not test(i)]
            held = [i for i in agree if test(i)]
            best = max(GRID, key=lambda t: (prf(*counts(train, t))[2], t))
            p, r, f1 = prf(*counts(held, best))
            pos = sum(1 for i in held if agree[i])
            status = ("unmeasured" if pos < 5 else "on" if f1 >= 0.6 else "off")
            per[c] = {"threshold": best, "test_precision": round(p, 3), "test_recall": round(r, 3),
                      "test_f1": round(f1, 3), "test_positives": pos, "test_items": len(held),
                      "train_f1": round(prf(*counts(train, best))[2], 3),
                      "label_agreement": round(agreement, 3),
                      "target_in_gold": round(sum(target_hit) / len(target_hit), 3) if target_hit else None,
                      "status": status}
        out["stages"][stage] = {"items_with_two_labels": len(two), "kinds": per}
        if stage == "question":
            errors = [k.code for k in KINDS if k.stage == "question" and k.severity == "error"]
            plain = [i for i in two if items[i]["target"] == "NONE" and test(i)]
            on = [c for c in errors if per[c]["status"] == "on"]
            raised = [sum(probs[i]["p"][c] >= per[c]["threshold"] for c in on) for i in plain]
            all_raised = [sum(probs[i]["p"][c] >= per[c]["threshold"] for c in codes
                              if per[c]["status"] == "on") for i in plain]
            out["noise"] = {"plain_test_questions": len(plain),
                            "errors_per_plain_question": round(sum(raised) / len(plain), 3) if plain else None,
                            "kinds_per_plain_question": round(sum(all_raised) / len(plain), 3) if plain else None,
                            "bar": 0.2}
    write_json = json.dumps(out, indent=1)
    (OUT / "scores.json").write_text(write_json + "\n")
    for stage, s in out["stages"].items():
        print(f"\n{stage}: {s['items_with_two_labels']} items with two labels")
        print(f"{'kind':24} {'thr':>5} {'P':>6} {'R':>6} {'F1':>6} {'pos':>4} {'agree':>6} {'tgt':>5}  status")
        for c, k in sorted(s["kinds"].items(), key=lambda x: -x[1]["test_f1"]):
            print(f"{c:24} {k['threshold']:5.2f} {k['test_precision']:6.3f} {k['test_recall']:6.3f} "
                  f"{k['test_f1']:6.3f} {k['test_positives']:4d} {k['label_agreement']:6.3f} "
                  f"{(k['target_in_gold'] if k['target_in_gold'] is not None else float('nan')):5.2f}  {k['status']}")
    print("\nnoise", out.get("noise"), "models", out["models"])


if __name__ == "__main__":
    {"assemble": assemble, "run": lambda: asyncio.run(run()), "score": score}[sys.argv[1]]()
