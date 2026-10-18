"""Semantic exceptions: the store notices what the model should do, and says so.

A repository answers a search with rows. This module lets it answer with rows
AND the exceptions those rows, or the question that asked for them, raise: a
blended question that needs splitting, a negation similarity cannot express,
a result that filled its limit, a passage that points elsewhere, a walk going
round in circles. Each exception carries a prompt the model reads, so nobody
has to have prompted the model to look for it. The intelligence is in the
store's layer, and any agent that searches through it gets it.

    sx = SemanticExceptions(Jev())
    search = sx.guard(repo.search)          # any async (question, **kw) -> hits
    hits, report = await search("Which entries don't mention Lucy?", limit=10)
    report.to_prompt()                       # text for the model, worst first

or stage by stage:

    await sx.before(question)                # one Jev call: the question's shape
    sx.after(hits, limit=10)                 # free: the result's statistics and fields
    await sx.values(question, hits)          # one Jev call per hit read: pointers, hearsay...
    sx.walk(rounds, budget=40)               # free: loops, explosion, convergence

COST. `before` is ONE Jev request however many kinds it asks: Jev answers a map
of questions about one state in a forward pass (40 kinds, ~1,300 input tokens,
0.3-0.5 s measured 18 Oct). `values` is one request per hit inspected, run
concurrently. `after` and `walk` cost nothing.

AN ERROR IS A REFUSAL ONLY IF THE CALLER ASKS. `guard(strict=True)` raises
SemanticExceptionError before searching when the question raises an
error-severity kind, and the error's message is the prompt: a tool that
returns it to the model has forced the split or the anti-join without anyone
writing that rule into a system prompt. Without strict the search runs and
the report rides along.

NOISE HAS A BUDGET. A report renders at most `show` exceptions, errors first,
then by probability; the rest are counted, never silently dropped.

Not yet in the database. The first version lives here so any repository can
embed it; pushing the catalogue and the decisions into Postgres is a later step.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Mapping, Sequence

from ..decide import Noul
from .catalogue import KINDS, Kind, by_code
from .structural import Limits, Raised, result_exceptions, walk_exceptions

__all__ = ["KINDS", "Kind", "Limits", "Raised", "Report", "SemanticExceptionError",
           "SemanticExceptions", "by_code"]

_ORDER = {"error": 0, "warning": 1, "positive": 2}


@dataclass
class Report:
    raised: list[Raised] = field(default_factory=list)
    model: str | None = None
    jev_requests: int = 0
    input_tokens: int = 0

    def __iadd__(self, other: "Report") -> "Report":
        self.raised += other.raised
        self.model = other.model or self.model
        self.jev_requests += other.jev_requests
        self.input_tokens += other.input_tokens
        return self

    def ordered(self) -> list[Raised]:
        return sorted(self.raised, key=lambda r: (_ORDER[r.kind.severity], -(r.p or 1.0)))

    @property
    def codes(self) -> set[str]:
        return {r.code for r in self.raised}

    @property
    def errors(self) -> list[Raised]:
        return [r for r in self.ordered() if r.kind.severity == "error"]

    def to_prompt(self, show: int = 5) -> str:
        """The exceptions as the model reads them, worst first, at most `show`."""
        if not self.raised:
            return ""
        lines = ["SEMANTIC EXCEPTIONS raised by the store. Act on these before answering:"]
        seen: set[str] = set()
        shown = 0
        for r in self.ordered():
            if r.code in seen:   # one line per kind; the evidence lists every instance
                continue
            if shown == show:
                break
            seen.add(r.code)
            shown += 1
            same = [x for x in self.raised if x.code == r.code]
            where = f" ({len(same)} results)" if len(same) > 1 else ""
            lines.append(f"- {r.kind.severity.upper()} {r.code}{where}: {r.kind.prompt}")
        rest = len({r.code for r in self.raised}) - shown
        if rest > 0:
            lines.append(f"- and {rest} more of lower severity.")
        return "\n".join(lines)


class SemanticExceptionError(Exception):
    """The question raised an error-severity kind and the caller asked for refusal."""

    def __init__(self, report: Report):
        self.report = report
        super().__init__(report.to_prompt())


class SemanticExceptions:
    """The inspector a repository embeds. `jev` is any object with
    `ask(state, questions)` returning answers with `.p` (percolate_core.decide.Jev);
    without one, only the structural stages run.

    `thresholds` overrides a judged kind's measured threshold by code; `disable`
    turns kinds off by code and `enable` turns on one the eval left off; `store`
    is a sentence describing what the store holds, which switches on
    OUT_OF_DOMAIN."""

    def __init__(self, jev: Any = None, *, kinds: Sequence[Kind] = KINDS,
                 limits: Limits = Limits(), thresholds: Mapping[str, float] | None = None,
                 disable: Sequence[str] = (), enable: Sequence[str] = (),
                 store: str | None = None,
                 text_key: str = "content", values_top: int = 5, conflict_top: int = 3):
        self.jev, self.limits, self.store = jev, limits, store
        self.text_key, self.values_top, self.conflict_top = text_key, values_top, conflict_top
        off, extra = set(disable), set(enable)
        self.kinds = {k.code: k for k in kinds
                      if (k.on or k.code in extra) and k.code not in off}
        self.thresholds = {c: k.threshold for c, k in self.kinds.items() if k.judged}
        self.thresholds.update(thresholds or {})

    # ---- judged ---------------------------------------------------------------
    def _judged(self, stage: str, state: Mapping[str, Any]) -> list[Kind]:
        return [k for k in self.kinds.values()
                if k.stage == stage and k.judged and (k.needs is None or k.needs in state)]

    def _need_jev(self):
        if self.jev is None:
            raise ValueError("a judged stage needs a Jev client: SemanticExceptions(Jev())")

    async def probabilities(self, question: str) -> tuple[dict[str, float], Report]:
        """P(yes) for every question-stage kind, unthresholded. The eval reads this."""
        self._need_jev()
        state: dict[str, Any] = {"question": question}
        if self.store:
            state["store"] = self.store
        kinds = self._judged("question", state)
        res = await self.jev.ask(state, {k.code: Noul(k.instruction) for k in kinds})
        rep = Report(model=getattr(res, "model", None), jev_requests=1,
                     input_tokens=getattr(res, "input_tokens", 0))
        return {k.code: res[k.code].p for k in kinds}, rep

    async def before(self, question: str) -> Report:
        """The question's own exceptions, from one Jev request."""
        ps, rep = await self.probabilities(question)
        rep.raised = [Raised(c, {"question": question}, round(p, 4))
                      for c, p in ps.items() if p >= self.thresholds[c]]
        return rep

    async def value_probabilities(self, question: str, hits: Sequence[Mapping[str, Any]]
                                  ) -> tuple[list[dict[str, float]], list, Report]:
        """P(yes) per kind for each of the top hits, unthresholded, with the hits
        read. A conflict is keyed `CONFLICT:<j>`, j the other hit's index."""
        self._need_jev()
        top = [h for h in hits if h.get(self.text_key)][: self.values_top]
        kinds = self._judged("values", {"question": 1, "passage": 1})
        conflict = self.kinds.get("CONFLICT")
        per_hit = [k for k in kinds if k.code != "CONFLICT"]
        requests = []
        for i, h in enumerate(top):
            qs = {k.code: Noul(k.instruction) for k in per_hit}
            if conflict is not None:
                for j in range(i + 1, min(len(top), self.conflict_top)):
                    qs[f"CONFLICT:{j}"] = Noul({"other": top[j][self.text_key],
                                                "question": conflict.instruction})
            requests.append(({"question": question, "passage": h[self.text_key]}, qs))
        results = await asyncio.gather(*(self.jev.ask(s, q) for s, q in requests))
        rep = Report(jev_requests=len(results))
        probs = []
        for (_, qs), res in zip(requests, results):
            rep.model = getattr(res, "model", rep.model)
            rep.input_tokens += getattr(res, "input_tokens", 0)
            probs.append({qid: res[qid].p for qid in qs})
        return probs, top, rep

    async def values(self, question: str, hits: Sequence[Mapping[str, Any]]) -> Report:
        """Exceptions in what the top hits say: one Jev request per hit, concurrently.
        Each request also asks whether this hit and each of the next
        `conflict_top` hits answer the question differently."""
        probs, top, rep = await self.value_probabilities(question, hits)
        for h, ps in zip(top, probs):
            for qid, p in ps.items():
                code, _, j = qid.partition(":")
                if p >= self.thresholds[code]:
                    ev = {"id": h.get("id")}
                    if j:
                        ev["other"] = top[int(j)].get("id")
                    rep.raised.append(Raised(code, ev, round(p, 4)))
        return rep

    # ---- structural -----------------------------------------------------------
    def _keep(self, raised: list[Raised]) -> list[Raised]:
        return [r for r in raised if r.code in self.kinds]

    def after(self, hits: Sequence[Mapping[str, Any]], **ctx: Any) -> Report:
        """The result's own exceptions, from its statistics and fields. Free."""
        return Report(self._keep(result_exceptions(hits, limits=self.limits, **ctx)))

    def walk(self, rounds: Sequence[Mapping[str, Any]], **ctx: Any) -> Report:
        """The walk's exceptions so far. Free."""
        return Report(self._keep(walk_exceptions(rounds, limits=self.limits, **ctx)))

    # ---- together -------------------------------------------------------------
    def guard(self, search: Callable[..., Awaitable[Sequence[Mapping[str, Any]]]], *,
              strict: bool = False, values: bool = False,
              limit_arg: str = "limit") -> Callable[..., Awaitable[tuple[list, Report]]]:
        """Wrap `search(question, **kw)` so it returns `(hits, report)`.

        The question is judged first. Under `strict`, an error-severity kind
        raises SemanticExceptionError and the search does not run. `values`
        also reads the top hits (one Jev request each)."""

        async def guarded(question: str, **kw: Any) -> tuple[list, Report]:
            report = Report()
            if self.jev is not None:
                report += await self.before(question)
                if strict and report.errors:
                    raise SemanticExceptionError(report)
            hits = list(await search(question, **kw))
            report += self.after(hits, limit=kw.get(limit_arg))
            if values and self.jev is not None and hits:
                report += await self.values(question, hits)
            return hits, report

        return guarded
