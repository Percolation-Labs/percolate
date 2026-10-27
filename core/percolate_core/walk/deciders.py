"""Who gives a clue its P: Jev, live, or a verdict file from an earlier walk.

A VERDICT FILE MAKES A WALK FREE TO REPEAT. Every live walk can write the verdicts it was given (`Recorder`), and a
replay (`Replay`) answers from them with no model call, so a walkthrough step costs a few cents once and nothing
after. A verdict belongs to the question, the clue and the wording of the task; a file says which model and task
gave it, and a replay under another task is refused rather than quietly mixed.

A CLUE THE FILE NEVER SAW goes to the fallback decider when there is one, and is left unjudged when there is not
(`--offline`). An unjudged clue is never accepted, and the record counts it, so an offline replay that drifted from
its file says so instead of walking somewhere else silently.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping

from ..decide import MODEL, Jev, Noul
from .engine import TASK, Decide

CHUNK = 60  # clues per Jev request, as the study asked them


class Refused(RuntimeError):
    """The verdict file cannot answer for this walk."""


def jev(client: Jev | None = None, task: str = TASK) -> Decide:
    """Ask Jev, CHUNK clues a request, in key order so a request is the same whoever asks it."""
    client = client or Jev()

    async def decide(question: Mapping[str, Any], clues: Mapping[str, str]) -> dict[str, float]:
        keys = sorted(clues)
        out: dict[str, float] = {}
        for i in range(0, len(keys), CHUNK):
            part = keys[i:i + CHUNK]
            got = await client.ask({"question": question["text"], "task": task},
                                   {f"c{x}": Noul(clues[k]) for x, k in enumerate(part)})
            for x, k in enumerate(part):
                out[k] = float(got[f"c{x}"].p)
        return out

    decide.model = client.model  # type: ignore[attr-defined]
    return decide


class Recorder:
    """Wraps a decider and keeps every verdict it gave, per question, to write as a verdict file."""

    def __init__(self, inner: Decide, model: str | None = None, task: str = TASK):
        self.inner, self.task = inner, task
        self.model = model or getattr(inner, "model", MODEL)
        self.verdicts: dict[str, dict[str, float]] = {}

    async def __call__(self, question: Mapping[str, Any], clues: Mapping[str, str]) -> Mapping[str, float]:
        got = await self.inner(question, clues)
        self.verdicts.setdefault(str(question["id"]), {}).update({k: round(v, 6) for k, v in got.items()})
        return got

    def save(self, path: str | Path, merge: bool = True) -> None:
        p = Path(path)
        doc = {"model": self.model, "task": self.task, "verdicts": {}}
        if merge and p.exists():
            doc = load(p, self.task)
        for qid, v in self.verdicts.items():
            doc["verdicts"].setdefault(qid, {}).update(v)
        p.write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n")


def load(path: str | Path, task: str = TASK) -> dict[str, Any]:
    doc = json.loads(Path(path).read_text())
    if doc.get("task") != task:
        raise Refused(f"{path} holds verdicts given under another task wording; they cannot answer this walk")
    return doc


class Replay:
    """Answers from a verdict file; a clue it lacks goes to `fallback`, or stays unjudged without one."""

    def __init__(self, path: str | Path, fallback: Decide | None = None, task: str = TASK):
        doc = load(path, task)
        self.model, self.verdicts, self.fallback = doc.get("model"), doc["verdicts"], fallback
        self.asked = 0      # clues that went to the fallback
        self.missing = 0    # clues left unjudged

    async def __call__(self, question: Mapping[str, Any], clues: Mapping[str, str]) -> dict[str, float]:
        have = self.verdicts.get(str(question["id"]), {})
        out = {k: have[k] for k in clues if k in have}
        rest = {k: v for k, v in clues.items() if k not in have}
        if rest and self.fallback:
            self.asked += len(rest)
            out.update(await self.fallback(question, rest))
        else:
            self.missing += len(rest)
        return out
