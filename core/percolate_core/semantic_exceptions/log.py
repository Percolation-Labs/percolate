"""The query log: one typed record per query, so the layer is measured on real traffic.

Synthetic fixtures said the layer raises the right exceptions. Whether that
helps a searcher can only be read from what searchers did next, so every query
through the common path is recorded as a ``QueryEvent``:

    who and where   session, run and user, from the runtime's X-P8-* headers
    what was asked  the p8ql string, the caller's question, the parsed plan
    what came back  result statistics (rows, scores, sources), or the error
    what was said   the exceptions raised and the receipt, and whether the
                    model was shown them (``shown``) or they were computed in
                    shadow, and whether the rows were withheld (``refused``)

The outcome is not recorded at query time. It is derived afterwards from the
same log: the next query in the same run is what the agent did next
(``followups``). A judged label on that pair -- was it a second try at the same
thing, did it go where the guidance pointed -- belongs to the experiment that
reads the log, not to the log.

Standard library only: the query server that writes it runs on the base install.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Protocol

SCHEMA_VERSION = 1


@dataclass
class QueryEvent:
    query: str
    question: str | None = None
    mode: str | None = None              # the plan's retrieval mode
    source: str | None = None
    limit: int | None = None
    session_id: str | None = None
    run_id: str | None = None
    user_id: str | None = None
    exceptions_mode: str = "off"         # off | shadow | on | strict
    shown: bool = False                  # the model read the exceptions
    shown_codes: list = field(default_factory=list)  # the ones it had not seen before
    refused: bool = False                # strict withheld the rows
    error: str | None = None             # the query's own failure, if any
    stats: dict = field(default_factory=dict)
    raised: list = field(default_factory=list)   # [{code, stage, severity, p}]
    receipt: dict = field(default_factory=dict)
    latency_ms: int | None = None
    at: float = field(default_factory=time.time)
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    v: int = SCHEMA_VERSION

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: Mapping[str, Any]) -> "QueryEvent":
        known = cls.__dataclass_fields__
        return cls(**{k: v for k, v in d.items() if k in known})

    @property
    def codes(self) -> list[str]:
        return [r["code"] for r in self.raised]


def stats_of(doc: Any) -> dict:
    """What the result looked like, from the envelope alone."""
    if not isinstance(doc, Mapping):
        return {}
    rows = [r for r in doc.get("rows") or () if isinstance(r, Mapping)]
    out: dict[str, Any] = {"rows": len(rows), "empty": not rows}
    dist = [float(r["distance"]) for r in rows if isinstance(r.get("distance"), (int, float))]
    rank = [float(r[k]) for r in rows for k in ("score", "rrf_score")
            if isinstance(r.get(k), (int, float))]
    if dist:
        out["distance_min"], out["distance_max"] = min(dist), max(dist)
    if rank:
        out["score_max"], out["score_min"] = max(rank), min(rank)
    sources = {str(r.get("source") or r.get("source_table") or "") for r in rows} - {""}
    if sources:
        out["sources"] = len(sources)
    out["with_content"] = sum(1 for r in rows if isinstance(r.get("content"), str))
    # Which records came back, so an outcome can be read as evidence gained (the
    # next query found records this session had not seen) rather than only as
    # "asked again", which in a task-sized session is nearly every follow-up.
    out["ids"] = [str(i) for i in (next((r[f] for f in ("chunk_id", "node_id", "key", "id")
                                        if r.get(f) is not None), None) for r in rows[:50])
                  if i is not None]
    return out


def event_of(query: str, doc: Any, *, question: str | None = None, headers: Mapping[str, str] = {},
             exceptions_mode: str = "off", report: Any = None, judge_error: str | None = None,
             shown: bool = False, shown_codes: list | None = None, refused: bool = False,
             error: str | None = None, latency_ms: int | None = None) -> QueryEvent:
    plan = (doc.get("plan") if isinstance(doc, Mapping) else None) or {}
    h = {k.lower(): v for k, v in headers.items()}
    raised, receipt = [], {}
    if report is not None:
        d = report.to_dict()
        raised = [{k: r[k] for k in ("code", "stage", "severity", "p")} for r in d["raised"]]
        receipt = {**d["receipt"], "ran": True}
    elif exceptions_mode != "off":
        receipt = {"ran": False, "error": judge_error}
    limit = plan.get("limit")
    return QueryEvent(
        query=query, question=question,
        mode=(doc.get("mode") if isinstance(doc, Mapping) else None) or plan.get("mode"),
        source=plan.get("source"),
        limit=int(limit) if isinstance(limit, int) or (isinstance(limit, str) and limit.isdigit()) else None,
        session_id=h.get("x-p8-session-id"), run_id=h.get("x-p8-run-id"),
        user_id=h.get("x-p8-user-id"), exceptions_mode=exceptions_mode, shown=shown,
        shown_codes=list(shown_codes or []), refused=refused, error=error, stats=stats_of(doc), raised=raised, receipt=receipt,
        latency_ms=latency_ms)


class QueryLog(Protocol):
    def append(self, event: QueryEvent) -> None: ...
    def __iter__(self) -> Iterator[QueryEvent]: ...


class JsonlLog:
    """Append-only, one event per line. Durable on disk; a database store reads
    the same records."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self._lock = threading.Lock()

    def append(self, event: QueryEvent) -> None:
        line = json.dumps(event.to_dict(), ensure_ascii=False) + "\n"
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a") as f:
                f.write(line)

    def __iter__(self) -> Iterator[QueryEvent]:
        if not self.path.exists():
            return iter(())
        return (QueryEvent.from_dict(json.loads(l)) for l in self.path.read_text().splitlines()
                if l.strip())


def followups(events: Iterable[QueryEvent]) -> list[tuple[QueryEvent, QueryEvent | None]]:
    """Each event with the next query in the same run (else session), or None.

    The outcome of a query is what its caller asked next. Events with neither a
    run nor a session cannot be paired and get None."""
    ordered = sorted(events, key=lambda e: e.at)
    by: dict[str, list[QueryEvent]] = {}
    for e in ordered:
        key = e.run_id or e.session_id
        if key:
            by.setdefault(key, []).append(e)
    nxt: dict[str, QueryEvent] = {}
    for seq in by.values():
        for a, b in zip(seq, seq[1:]):
            nxt[a.id] = b
    return [(e, nxt.get(e.id)) for e in ordered]


def digest(text: str) -> str:
    """A stable short id for a query string, for grouping repeats."""
    return hashlib.sha1(text.strip().lower().encode()).hexdigest()[:12]


def read_percolate(base: str, authorization: str, page: int = 1000) -> list[QueryEvent]:
    """The caller's own query log from a Percolate PostgREST: every metadata
    object on the query_log channel that row-level security lets them read."""
    import urllib.request

    def get(path: str):
        req = urllib.request.Request(f"{base.rstrip('/')}/{path}", headers={
            "Accept-Profile": "content", "Authorization": authorization})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())

    [chan] = get("channels?name=eq.query_log&select=id") or [None]
    if chan is None:
        return []
    out, offset = [], 0
    while True:
        rows = get(f"resources?channel_id=eq.{chan['id']}&select=metadata"
                   f"&order=id&limit={page}&offset={offset}")
        out += [QueryEvent.from_dict(r["metadata"]) for r in rows if r.get("metadata")]
        if len(rows) < page:
            return out
        offset += page
