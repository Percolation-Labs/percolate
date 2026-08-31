"""Provenance on generated answers (``brief.md`` §5.3).

The design decision this module exists to hold: citations are **derived from
tool responses by the runtime**, mechanically — not emitted by the model.
"Asking the model to remember and correctly emit a citation list as part of its
own structured output is unreliable — models drop citations, invent ones that
don't match what was actually retrieved, or cite generically instead of
per-chunk."

So this is provenance *by construction*: "what did the agent's context actually
contain when it answered," not "what does the agent claim it used."
"""

from __future__ import annotations

from typing import Any

from ..contracts import ChunkCitation, Citation, NodeCitation, ToolResult

# Which responses count as retrieval is data, not a naming convention: the
# provider stamps ``ToolResult.citable`` from its server's ``emits_citations``
# column (``brief.md`` §5.2, added after prototyping showed a tool-name prefix
# was the only alternative and would break on the first rename).


def derive(tool_results: list[ToolResult]) -> list[Citation]:
    """Extract the union of citations from this turn's tool responses.

    Scope is **per-answer, not per-run** (``brief.md`` §5.3): citations reset at
    each assistant message. "An agent's tenth answer in a long session cites what
    informed *that* answer, not everything ever retrieved earlier."

    The tagged union is preserved: a ``resource_chunk`` result becomes a
    ``ChunkCitation``; a GRAPH-mode result that is genuinely a node becomes a
    ``NodeCitation``. Never one field trying to mean both.

    Shell: real over the documented row shapes; unknown shapes are skipped
    rather than guessed at, because a wrong citation is worse than none.
    """
    citations: list[Citation] = []
    seen: set[tuple[Any, ...]] = set()

    for result in tool_results:
        if result.is_error or not result.citable:
            continue
        for row in _rows(result.content):
            citation = _row_to_citation(row)
            if citation is None:
                continue
            key = tuple(sorted(citation.model_dump(mode="json").items()))
            if key not in seen:
                seen.add(key)
                citations.append(citation)
    return citations


def _rows(content: Any) -> list[dict[str, Any]]:
    if isinstance(content, dict):
        rows = content.get("rows", content.get("results"))
        return rows if isinstance(rows, list) else [content]
    if isinstance(content, list):
        return [r for r in content if isinstance(r, dict)]
    return []


def _row_to_citation(row: dict[str, Any]) -> Citation | None:
    if "node_id" in row:
        return NodeCitation(node_id=row["node_id"])
    if "resource_id" in row:
        return ChunkCitation(
            resource_type=row.get("resource_type", "resource"),
            resource_id=row["resource_id"],
            chunk_id=row.get("chunk_id"),
        )
    return None
