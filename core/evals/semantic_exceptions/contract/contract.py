"""Run the layer as a black box against its contract.

    python contract.py [--cases cases.jsonl] [--variant variant.json] [--out out.json] [--offline]

Each case is one input and the codes that must, must not, or alone may come out
(README.md). Judged cases call Jev; `--offline` runs the structural and walk
cases only, which is what CI can always run. `--variant` overrides kinds by
code -- {"SUPERLATIVE": {"instruction": ..., "yes": ..., "no": ..., "threshold": ...}}
-- which is how a calibration is tried before it is written into the catalogue.

For a case that raises something, the guidance the layer renders is checked
against the case's `i_would` by Jev: "Would a reader who follows `guidance`
make `move`?" That is the claim worth testing: not that a code fired, but that
what the store said points where a good researcher would go.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
from dataclasses import replace
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2]))

from percolate_core.decide import Jev, Noul  # noqa: E402
from percolate_core.semantic_exceptions import KINDS, Limits, SemanticExceptions  # noqa: E402

GUIDANCE_THRESHOLD = 0.5


def kinds_with(variant: dict) -> list:
    return [replace(k, **{f: v for f, v in variant.get(k.code, {}).items()}) for k in KINDS]


def verdict(case: dict, codes: set) -> list[str]:
    why = [f"missing {c}" for c in case.get("raise", []) if c not in codes]
    why += [f"raised {c}" for c in case.get("not_raise", []) if c in codes]
    if "exact" in case:
        why += [f"extra {c}" for c in sorted(codes - set(case["exact"]))]
    return why


async def run_case(case: dict, kinds: list, jev) -> dict:
    stage, inp = case["stage"], case["input"]
    if stage in ("result", "walk"):
        sx = SemanticExceptions(kinds=kinds, limits=Limits(**case.get("limits", {})))
        rep = sx.after(**inp) if stage == "result" else sx.walk(**inp)
    else:
        sx = SemanticExceptions(jev, kinds=kinds, store=case.get("store"))
        rep = (await sx.before(inp["question"]) if stage == "question"
               else await sx.values(inp["question"], inp["hits"]))
    codes = {r.code for r in rep.raised}
    out = {"case": case.get("name") or inp.get("question"), "stage": stage,
           "codes": sorted(codes), "p": {r.code: r.p for r in rep.raised if r.p is not None},
           "fail": verdict(case, codes), "receipt": rep.to_dict()["receipt"]}
    if jev is not None and rep.raised and case.get("i_would"):
        r = await jev.ask({"guidance": rep.to_prompt(show=6), "move": case["i_would"]},
                          {"g": Noul("Would a reader who follows `guidance` make `move`, or a "
                                     "move that serves the same purpose?")})
        out["guidance_p"] = round(r["g"].p, 3)
    return out


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=str(HERE / "cases.jsonl"))
    ap.add_argument("--variant")
    ap.add_argument("--out")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--no-store", action="store_true",
                    help="judge without the store description, as the query tool does by default")
    a = ap.parse_args()
    cases = [json.loads(l) for l in open(a.cases) if l.strip()]
    if a.no_store:
        # OUT_OF_DOMAIN is only asked with a store described; its cases cannot hold.
        cases = [{k: v for k, v in c.items() if k != "store"} for c in cases
                 if "OUT_OF_DOMAIN" not in c.get("raise", [])]
    if a.offline:
        cases = [c for c in cases if c["stage"] in ("result", "walk")]
    kinds = kinds_with(json.load(open(a.variant)) if a.variant else {})
    jev = None if a.offline else Jev(api_key=os.environ["JEV_API_KEY"], concurrency=8)
    try:
        results = await asyncio.gather(*(run_case(c, kinds, jev) for c in cases))
    finally:
        if jev is not None:
            await jev.aclose()
    passed = [r for r in results if not r["fail"]]
    raising = [r for r in results if "guidance_p" in r]
    guided = [r for r in raising if r["guidance_p"] >= GUIDANCE_THRESHOLD]
    errors = {k.code for k in kinds if k.severity == "error"}
    wrong_refusals = [r for r in results for f in r["fail"]
                      if f.startswith(("raised ", "extra ")) and f.split()[1] in errors]
    for r in results:
        if r["fail"] or r.get("guidance_p", 1) < GUIDANCE_THRESHOLD:
            print(f"FAIL [{r['stage']}] {r['case'][:70]!r}: {', '.join(r['fail']) or 'guidance'}"
                  f"  got={r['codes']} guidance={r.get('guidance_p')}")
    summary = {"cases": len(results), "passed": len(passed),
               "pass_rate": round(len(passed) / len(results), 3),
               "wrong_refusals": len(wrong_refusals),
               "guidance": f"{len(guided)}/{len(raising)}"}
    print(json.dumps(summary))
    if a.out:
        Path(a.out).write_text(json.dumps({"summary": summary, "results": results}, indent=1))


if __name__ == "__main__":
    asyncio.run(main())
