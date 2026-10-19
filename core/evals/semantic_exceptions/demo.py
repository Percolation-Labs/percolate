"""The guard end to end against live Jev, over a toy in-memory search.

    JEV_API_KEY=... python evals/semantic_exceptions/demo.py

The search is a stand-in for a repository: it returns the fixture passages
whose words overlap the question, scored by overlap. What is under test is
what the model would be handed, not the search.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1]))

from percolate_core.decide import Jev  # noqa: E402
from percolate_core.semantic_exceptions import (SemanticExceptionError,  # noqa: E402
                                                SemanticExceptions)

PASSAGES = [r for r in map(json.loads, (HERE / "fixtures/items_values.jsonl").read_text().splitlines())
            if r["domain"] == "dracula"]


async def search(question: str, limit: int = 5) -> list[dict]:
    words = set(question.lower().split())
    scored = [(len(words & set(r["passage"].lower().split())) / len(words), r) for r in PASSAGES]
    top = sorted(scored, key=lambda x: -x[0])[:limit]
    return [{"id": r["id"], "score": s, "content": r["passage"]} for s, r in top if s > 0]


QUESTIONS = [
    "How many letters did Mina write, and what did Van Helsing think of the bat?",
    "Which entries never mention Lucy?",
    "What did Harker see from the castle window?",
]


async def main() -> None:
    async with Jev(api_key=os.environ["JEV_API_KEY"]) as jev:
        sx = SemanticExceptions(jev, store="Bram Stoker's Dracula as dated journals, letters, "
                                           "telegrams, cuttings and a ship's log.")
        strict = sx.guard(search, strict=True, values=True)
        for q in QUESTIONS:
            print(f"\n### {q}")
            try:
                hits, report = await strict(q, limit=5)
                print(f"{len(hits)} hits, {report.jev_requests} Jev requests, "
                      f"{report.input_tokens} input tokens")
                print(report.to_prompt() or "(no exceptions)")
            except SemanticExceptionError as e:
                print("REFUSED before searching:")
                print(e)


if __name__ == "__main__":
    asyncio.run(main())
