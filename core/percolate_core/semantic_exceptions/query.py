"""Semantic exceptions on the common query path: an ``aiq.query`` envelope in, a report out.

``aiq.query`` answers every p8ql mode with one envelope -- ``{mode, plan, rows}``
-- so one adapter serves every caller of it: the ``query`` MCP tool here, and
any repository that runs p8ql. It reads what the envelope already says and
invents nothing:

    the question   the caller's own words when given, else the plan's text
                   argument for a text mode (SEARCH, SEMANTIC, TEXT): the
                   string a retrieval was actually run on
    the hits       each row's id (chunk_id, node_id, key or id), its content
                   if the row carries text, and a score only where the row
                   carries a cosine distance (SEMANTIC); an RRF score is a
                   rank fusion, not a similarity, and is not passed as one
    the limit      the plan's; TRUNCATED_AT_LIMIT also needs the total the
                   envelope does not carry, which a probe may supply

A mode with no text (LOOKUP, GRAPH, SQL) is judged only by its result, and an
envelope that is an error is not judged at all: the error is the answer.
"""

from __future__ import annotations

from typing import Any, Mapping

from . import Report, SemanticExceptions

TEXT_MODES = ("SEARCH", "SEMANTIC", "TEXT", "FUZZY")
_ID_FIELDS = ("chunk_id", "node_id", "key", "id")
_TEXT_FIELDS = ("content", "text", "summary")


def question_of(doc: Mapping[str, Any], question: str | None) -> str | None:
    if question and question.strip():
        return question.strip()
    plan = doc.get("plan") or {}
    if (doc.get("mode") or plan.get("mode")) in TEXT_MODES and isinstance(plan.get("arg"), str):
        return plan["arg"] or None
    return None


def hits_of(doc: Mapping[str, Any]) -> list[dict]:
    hits = []
    for row in doc.get("rows") or ():
        if not isinstance(row, Mapping):
            continue
        hit: dict = {"id": next((row[f] for f in _ID_FIELDS if row.get(f) is not None), None)}
        text = next((row[f] for f in _TEXT_FIELDS if isinstance(row.get(f), str)), None)
        if text:
            hit["content"] = text
        if isinstance(row.get("distance"), (int, float)):
            hit["score"] = 1.0 - float(row["distance"])
        hits.append(hit)
    return hits


async def inspect(sx: SemanticExceptions, doc: Mapping[str, Any], question: str | None = None,
                  *, values_top: int = 0, total: int | None = None) -> Report:
    """Every stage the envelope supports. `values_top` hits are read by Jev (0: none)."""
    report = Report(actions=sx.actions)
    if not isinstance(doc, Mapping) or doc.get("error"):
        return report
    q = question_of(doc, question)
    if q and sx.jev is not None:
        report += await sx.before(q)
    hits = hits_of(doc)
    limit = (doc.get("plan") or {}).get("limit")
    # `total` is how many rows match in all, when a probe counted them: the
    # envelope carries only the rows returned, so without it the truncation
    # kinds cannot tell "these are all" from "these are the first ten of 400".
    report += sx.after(hits, limit=int(limit) if isinstance(limit, (int, str)) and str(limit).isdigit() else None,
                       total=total)
    if q and values_top and sx.jev is not None and any("content" in h for h in hits):
        saved = sx.values_top
        sx.values_top = values_top
        try:
            report += await sx.values(q, hits)
        finally:
            sx.values_top = saved
    return report
