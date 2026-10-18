"""The exceptions a result raises by its shape alone: no model, no cost.

A hit is a mapping, and every field but `id` is optional. A detector that
needs a field the repository did not return stays silent; it never guesses.

    id              anything hashable
    score           similarity, HIGHER IS BETTER (pass 1 - distance for pgvector)
    source          who or what it came from: a narrator, a document, an origin
    version_of      the document this is one version of (not merely a part of)
    content         the text, for exact duplicates
    time            when it happened (world time; anything orderable, a datetime
                    for RECORDING_LAG)
    recorded_at     when it was written down
    superseded_by   a later record replaces it
    retracted       true when withdrawn
    continues       true when the passage is one part of a longer record
    provenance      present and None means the source is known to be missing
    embedding_model the space its vector lives in

A walk is a list of rounds, oldest first, each a mapping:

    found       ids the round returned
    opened      question ids the round raised
    closed      question ids the round settled
    unanswered  open question ids that had no candidate at all
    spent       cost of the round, in the walk's budget units

ABSOLUTE SCORE THRESHOLDS HAVE NO DEFAULT. A cosine of 0.6 is strong in one
embedding space and noise in another, so `low_score`, `flat_spread` and
`min_gap` are off until the repository sets them for its model. `min_gap`
gates SCORE_CLIFF and STRONG_SINGLE_HIT as well as their ratios: in use, a
ratio alone called a 0.019 cosine gap "one result stands well above the rest",
because within one top-k list the median gap can be almost nothing.
"""

from __future__ import annotations

from dataclasses import dataclass
from statistics import median
from typing import Any, Mapping, Sequence

from .catalogue import by_code

__all__ = ["Limits", "Raised", "result_exceptions", "walk_exceptions"]


@dataclass(frozen=True)
class Raised:
    """One exception the store raised: its kind, the evidence, and P(yes) if judged."""

    code: str
    evidence: Mapping[str, Any]
    p: float | None = None

    @property
    def kind(self):
        return by_code(self.code)


@dataclass(frozen=True)
class Limits:
    low_score: float | None = None        # LOW_BEST_SCORE below this; off when None
    flat_spread: float | None = None      # FLAT_SCORES when top-`flat_n` span less; off when None
    flat_n: int = 5
    min_gap: float | None = None          # SCORE_CLIFF / STRONG_SINGLE_HIT need a gap this big; off when None
    cliff_ratio: float = 4.0              # a gap this many times the median gap is a cliff
    single_hit_ratio: float = 4.0         # 1st-2nd gap this many times the median of the rest
    too_broad: int = 1000                 # TOO_BROAD when `total` exceeds this
    skew_fraction: float = 0.1            # TIME_SKEW when hits span less of the store's range
    recording_lag: Any = None             # RECORDING_LAG when recorded_at - time exceeds; off when None
    budget_warn: float = 0.8              # BUDGET_NEARLY_SPENT at this fraction
    explosion_rounds: int = 3             # rounds of opened > closed for FRONTIER_EXPLOSION


def _gaps(scores: Sequence[float]) -> list[float]:
    return [a - b for a, b in zip(scores, scores[1:])]


def result_exceptions(hits: Sequence[Mapping[str, Any]], *, limit: int | None = None,
                      total: int | None = None, filtered: bool = False,
                      time_range: tuple[Any, Any] | None = None,
                      embedding_model: str | None = None,
                      parts: Mapping[str, Sequence[Mapping[str, Any]]] | None = None,
                      limits: Limits = Limits()) -> list[Raised]:
    """Every structural exception `hits` raises. `parts` is a decomposed search's
    sub-results by sub-question; `time_range` the store's (earliest, latest)."""
    out: list[Raised] = []
    raise_ = lambda code, **ev: out.append(Raised(code, ev))  # noqa: E731
    n = len(hits)

    for name, sub in (parts or {}).items():
        if not sub:
            raise_("FACET_UNANSWERED", part=name)

    if n == 0:
        if not parts:
            raise_("EMPTY")
        return out

    if total is not None and total > limits.too_broad:
        raise_("TOO_BROAD", total=total)
    # Only when the store KNOWS more matched. A ranked search always fills its
    # limit, so without `total` this would fire on every search and mean nothing.
    if limit is not None and total is not None and n >= limit and total > n:
        raise_("TRUNCATED_AT_LIMIT", returned=n, limit=limit)
    if limit is not None and filtered and n < limit:
        raise_("STARVED_BY_FILTER", returned=n, limit=limit)

    scored = sorted((h for h in hits if h.get("score") is not None),
                    key=lambda h: float(h["score"]), reverse=True)
    scores = [float(h["score"]) for h in scored]
    if scores:
        if limits.low_score is not None and scores[0] < limits.low_score:
            raise_("LOW_BEST_SCORE", best=scores[0], below=limits.low_score)
        top = scores[:limits.flat_n]
        if (limits.flat_spread is not None and len(top) >= 3
                and top[0] - top[-1] < limits.flat_spread):
            raise_("FLAT_SCORES", spread=round(top[0] - top[-1], 6), over=len(top))
        gaps = _gaps(scores)
        # Three gaps at least, so a median of the others means something.
        if len(gaps) >= 3 and limits.min_gap is not None:
            rest = median(gaps[1:]) or 1e-9
            if gaps[0] >= max(limits.min_gap, limits.single_hit_ratio * rest):
                raise_("STRONG_SINGLE_HIT", id=scored[0].get("id"), gap=round(gaps[0], 6),
                       median_gap=round(rest, 6))
            else:
                mid = median(gaps) or 1e-9
                i = max(range(1, len(gaps)), key=gaps.__getitem__)
                if gaps[i] >= max(limits.min_gap, limits.cliff_ratio * mid):
                    raise_("SCORE_CLIFF", keep=i + 1, of=len(scores), gap=round(gaps[i], 6),
                           ids=[h.get("id") for h in scored[:i + 1]])

    sources = [h["source"] for h in hits if h.get("source") is not None]
    if len(sources) == n and len(set(sources)) == 1:
        raise_("SINGLE_SOURCE", source=sources[0], hits=n)

    times = [h["time"] for h in hits if h.get("time") is not None]
    if time_range is not None and len(times) >= 2:
        lo, hi = time_range
        span, store = max(times) - min(times), hi - lo
        if store and span < store * limits.skew_fraction:
            raise_("TIME_SKEW", earliest=str(min(times)), latest=str(max(times)))

    seen: dict[Any, list] = {}
    for h in hits:
        if h.get("content") is not None:
            seen.setdefault(h["content"], []).append(h.get("id"))
    dup = [ids for ids in seen.values() if len(ids) > 1]
    if dup:
        raise_("DUPLICATES", groups=dup)

    docs: dict[Any, list] = {}
    for h in hits:
        if h.get("version_of") is not None:
            docs.setdefault(h["version_of"], []).append(h.get("id"))
    piled = {str(d): ids for d, ids in docs.items() if len(ids) > 1}
    if piled:
        raise_("VERSION_PILE_UP", documents=piled)

    for h in hits:
        hid = h.get("id")
        if h.get("continues"):
            raise_("CONTINUES", id=hid)
        if h.get("retracted"):
            raise_("RETRACTED", id=hid)
        if h.get("superseded_by") is not None:
            raise_("SUPERSEDED", id=hid, by=h["superseded_by"])
        if "provenance" in h and h["provenance"] is None:
            raise_("MISSING_PROVENANCE", id=hid)
        t, r = h.get("time"), h.get("recorded_at")
        if t is not None and r is not None:
            if t > r:
                raise_("FUTURE_DATED", id=hid, time=str(t), recorded_at=str(r))
            elif limits.recording_lag is not None and r - t > limits.recording_lag:
                raise_("RECORDING_LAG", id=hid, lag=str(r - t))
        m = h.get("embedding_model")
        if embedding_model is not None and m is not None and m != embedding_model:
            raise_("EMBEDDING_MISMATCH", id=hid, hit_model=m, query_model=embedding_model)
    return out


def walk_exceptions(rounds: Sequence[Mapping[str, Any]], *, budget: float | None = None,
                    stopped: bool = False, limits: Limits = Limits()) -> list[Raised]:
    """Every structural exception the walk so far raises. `stopped` says the walk
    has ended, which is when an open question becomes an orphan."""
    out: list[Raised] = []
    raise_ = lambda code, **ev: out.append(Raised(code, ev))  # noqa: E731
    if not rounds:
        return out

    found: set = set()
    new_per_round: list[int] = []
    open_q: set = set()
    for r in rounds:
        got = set(r.get("found") or ())
        new_per_round.append(len(got - found))
        found |= got
        open_q |= set(r.get("opened") or ())
        open_q -= set(r.get("closed") or ())
    last = rounds[-1]
    i = len(rounds)

    # Nothing new found: a round that still opened questions is going round in
    # circles; one that opened none has run out of things to ask.
    if new_per_round[-1] == 0 and i > 1:
        raise_("LOOP" if last.get("opened") else "CONVERGED", round=i)

    k = limits.explosion_rounds
    if len(rounds) >= k and all(len(r.get("opened") or ()) > len(r.get("closed") or ())
                                for r in rounds[-k:]):
        raise_("FRONTIER_EXPLOSION", open=len(open_q), rounds=k)

    dead = [q for q in (last.get("unanswered") or ()) if q in open_q]
    if dead:
        raise_("DEAD_END", questions=dead)

    if len(new_per_round) >= 3:
        a, b, c = new_per_round[-3:]
        if a > b > c and c * 2 < a:
            raise_("DIMINISHING_RETURNS", new_per_round=new_per_round[-3:])

    if budget:
        spent = sum(float(r.get("spent") or 0) for r in rounds)
        if spent >= limits.budget_warn * budget:
            raise_("BUDGET_NEARLY_SPENT", spent=spent, budget=budget)

    if stopped and open_q:
        raise_("ORPHANED_QUESTIONS", questions=sorted(map(str, open_q)))
    return out
