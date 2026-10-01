"""Typed decisions from Jev: the semantic join and decision component.

Jev (TypeSafe's System One model) takes a STATE and a map of typed questions
and answers each from one forward pass. Nothing is generated, so nothing is
parsed: a Noul returns P(yes), a Choice a distribution over options you named,
a Score a distribution over ordered levels. That is the shape entity
resolution, knowledge-graph linking and recommendation all reduce to once code
has done the part code is good at -- candidate generation, blocking, dates,
arithmetic, transitivity. Jev judges the local semantic question left over;
it does not make a set of pairwise answers jointly coherent, and nothing here
pretends it does.

PIN THE VERSION. `jev-latest` moves; a decision recorded against an alias
cannot be compared with a later one. The default here is the exact version, and
every Result carries the version the service says answered it.

A THRESHOLD BELONGS TO ITS QUESTION, as much as to the version. Measured on
2,747 company-name pairs (p8-subsystems meta/spikes/2026-09-30-jev-decisions):
one rewording of the same question moved 114 accept decisions at P >= 0.8 while
the ranking (AUC 0.9994 vs 0.9997) did not move. Wording shifts the
calibration, not the judgement, so re-measure the threshold whenever the
wording changes. Batching is not a factor: a pair asked alone or among its
siblings differs by 0.003 on average.

THE CREDENTIAL IS BOUND, LIKE EVERY OTHER. `JEV_API_KEY` is resolved through
`credential_for`, so it goes nowhere until the operator binds it:
``P8_CREDENTIAL_ORIGINS='{"JEV_API_KEY": ["https://api.typesafe.ai"]}'``.
Passing `api_key=` directly skips that check, for callers that already hold
the secret.

    jev = Jev()
    r = await jev.ask({"a": rec_a, "b": rec_b},
                      {"same": Noul("Do `a` and `b` name the same entity?")})
    r["same"].p  # 0.98
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

import httpx

from .core.config import TerminalError
from .core.credentials import credential_for
from .core.provider_errors import classify, raise_for

__all__ = ["Answer", "Choice", "Jev", "Noul", "Result", "Score", "ENDPOINT", "MODEL"]

ENDPOINT = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-1.13.0"
CREDENTIAL = "JEV_API_KEY"


@dataclass(frozen=True)
class Noul:
    """A yes/no question; the answer is P(yes). `yes`/`no` say what each means."""

    instructions: Any
    yes: Any = None
    no: Any = None

    def wire(self) -> dict:
        q: dict = {"type": "noul", "instructions": self.instructions}
        if self.yes is not None or self.no is not None:
            q["criteria"] = {k: v for k, v in (("true", self.yes), ("false", self.no))
                             if v is not None}
        return q


@dataclass(frozen=True)
class Choice:
    """One of a closed set: option key -> description (None for none). At most 255.

    THE KEY IS READ, NOT JUST THE DESCRIPTION. Measured on our 276-pair claim
    corpus (jev-1.13.0, 30 Sept): the same four descriptions under their
    names (`same_claim`, `undecidable`, ...) and under `opt_a`..`opt_d` gave
    different argmaxes on 114 of 276 pairs, and `undecidable` was chosen 0
    times named against 108 times neutral. Binary gates moved on 2 of 186.
    So name an option what its description says, and when a comparison has to
    hold across wordings, run both and compare.
    """

    instructions: Any
    options: Mapping[str, Any]

    def wire(self) -> dict:
        return {"type": "choice", "instructions": self.instructions,
                "criteria": dict(self.options)}


@dataclass(frozen=True)
class Score:
    """A position on ordered levels, lowest first. Two to ten."""

    instructions: Any
    levels: Sequence[Any]

    def wire(self) -> dict:
        return {"type": "score", "instructions": self.instructions,
                "criteria": list(self.levels)}


Question = Noul | Choice | Score


@dataclass(frozen=True)
class Answer:
    """One answer, kept as the service sent it, with the reading every type shares.

    `value` is the decision: P(yes) for a Noul, the option key for a Choice,
    the probability-weighted level (0-based, fractional) for a Score.
    `probabilities` is keyed by option for a Choice and by level index for a
    Score. A Noul has no confidence field; its `confidence` is None rather than
    one invented here.
    """

    type: str
    value: Any
    probabilities: dict[str, float] = field(default_factory=dict)
    confidence: float | None = None
    raw: dict = field(default_factory=dict, repr=False)

    @property
    def p(self) -> float:
        """P(yes) for a Noul; the winner's mass for a Choice or a Score."""
        if self.type == "noul":
            return float(self.value)
        if self.type == "choice":
            return self.probabilities[self.value]
        return max(self.probabilities.values())

    @classmethod
    def from_wire(cls, a: dict) -> "Answer":
        kind = a["type"]
        value = a["noul"] if kind == "noul" else a["choice"] if kind == "choice" else a["score"]
        return cls(kind, value, dict(a.get("probabilities") or {}), a.get("confidence"), a)


@dataclass(frozen=True)
class Result:
    """Every answer to one request, and the exact model version that gave them."""

    model: str
    answers: dict[str, Answer]
    input_tokens: int = 0
    output_tokens: int = 0

    def __getitem__(self, question_id: str) -> Answer:
        return self.answers[question_id]


class Jev:
    """An async client for the System One endpoint.

    `ask` is one request. `ask_many` is many, bounded by `concurrency`, with
    results in input order. `join` is the semantic join: each left record is
    the state, and every candidate for it is one Noul in the same request, so
    a row with forty candidates is one call, not forty.

    Retries: a 429, 408 or 5xx is retried up to `retries` times with backoff,
    honouring Retry-After; anything `provider_errors` calls terminal (a bad
    key, a malformed question) raises TerminalError on the first response.
    """

    def __init__(self, model: str = MODEL, *, api_key: str | None = None,
                 endpoint: str = ENDPOINT, concurrency: int = 16, retries: int = 3,
                 timeout: float = 60.0, client: httpx.AsyncClient | None = None):
        self.model, self.endpoint, self.retries = model, endpoint, retries
        self._key = api_key
        self._gate = asyncio.Semaphore(concurrency)
        self._client = client
        self._timeout = timeout
        # Running totals across every call on this client, for metering: Jev
        # bills input tokens, and a join's cost is its candidate count.
        self.requests = self.input_tokens = self.output_tokens = 0

    async def __aenter__(self) -> "Jev":
        return self

    async def __aexit__(self, *exc) -> None:
        await self.aclose()

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    def _http(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=self._timeout)
        return self._client

    async def ask(self, state: Any, questions: Mapping[str, Question]) -> Result:
        if not questions:
            raise ValueError("ask needs at least one question")
        key = self._key or credential_for(CREDENTIAL, self.endpoint)
        body = {"model": self.model, "state": state,
                "questions": {qid: q.wire() for qid, q in questions.items()}}
        async with self._gate:
            for attempt in range(self.retries + 1):
                try:
                    resp = await self._http().post(
                        self.endpoint, json=body, headers={"Authorization": f"Bearer {key}"})
                except (httpx.TimeoutException, httpx.TransportError):
                    if attempt == self.retries:
                        raise
                    await asyncio.sleep(2 ** attempt)
                    continue
                failure = classify(resp.status_code, resp.content)
                if failure is None:
                    break
                if failure.terminal or attempt == self.retries:
                    # The body is the service's own error detail, not user data,
                    # and it is what says which question was malformed.
                    raise_for(resp.status_code, resp.content, "Jev", resp.text[:500])
                wait = resp.headers.get("retry-after")
                await asyncio.sleep(float(wait) if wait and wait.isdigit() else 2 ** attempt)
        data = resp.json()
        missing = set(questions) - set(data.get("answers") or {})
        if missing:
            raise TerminalError(f"Jev answered without {sorted(missing)}")
        usage = data.get("usage") or {}
        self.requests += 1
        self.input_tokens += usage.get("input_tokens", 0)
        self.output_tokens += usage.get("output_tokens", 0)
        return Result(data["model"],
                      {qid: Answer.from_wire(a) for qid, a in data["answers"].items()},
                      usage.get("input_tokens", 0), usage.get("output_tokens", 0))

    async def ask_many(self, requests: Sequence[tuple[Any, Mapping[str, Question]]]
                       ) -> list[Result]:
        return list(await asyncio.gather(*(self.ask(s, q) for s, q in requests)))

    async def join(self, left: Sequence[Any], candidates: Sequence[Mapping[str, Any]],
                   question: str, *, yes: Any = None, no: Any = None
                   ) -> list[dict[str, float]]:
        """P(match) for every (left row, candidate) pair that code proposed.

        `candidates[i]` maps a candidate key to its record, for `left[i]`.
        `question` names both sides in backticks, `record` and `candidate`:
        "Do `record` and `candidate` refer to the same real-world entity?".
        Returns, per left row, candidate key -> P(yes). Thresholding, one-to-one
        assignment and transitive closure are the caller's, in code.

        THE LEFT ROW IS SENT AS ``{"record": row}``, NOT AS THE BARE STATE.
        Measured on jev-1.13.0, 30 Sept: Apple Inc. against an AAPL record
        scored 0.44 and 0.52 on two identical calls when the question said
        "the state", and 0.96 and 0.97 when it said `record`; the Beatles'
        Apple Corps stayed at 0.03-0.06 either way. Indirection is a documented
        Jev weakness, so the join names its side rather than trusting callers to.
        """
        if len(left) != len(candidates):
            raise ValueError("join needs one candidate map per left row")
        # Question ids are positional, not the caller's keys: ids are not sent
        # to the model, but they must be unique and any string the caller uses
        # as a key has to survive the round trip unchanged.
        requests, keys = [], []
        for row, cands in zip(left, candidates):
            ks = list(cands)
            keys.append(ks)
            requests.append(({"record": row}, {f"c{j}": Noul({"candidate": cands[k], "question": question},
                                                 yes, no)
                                   for j, k in enumerate(ks)}))
        out: list[dict[str, float]] = [{} for _ in left]
        todo = [i for i, (_, qs) in enumerate(requests) if qs]
        results = await self.ask_many([requests[i] for i in todo])
        for i, r in zip(todo, results):
            out[i] = {k: r[f"c{j}"].p for j, k in enumerate(keys[i])}
        return out
