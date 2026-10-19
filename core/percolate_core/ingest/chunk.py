"""Markdown to chunks, with semchunk.

WHY SEMCHUNK AND NOT A RECURSIVE SPLITTER. The recursive character splitter
that most pipelines use (LangChain's, and its many copies) splits on a fixed
separator list and takes whatever length falls out. semchunk splits on the
most semantically significant boundary that keeps a chunk under the budget --
sections before paragraphs, paragraphs before sentences, sentences before
clauses -- so a chunk ends where the text ended a thought, not where a
character count ran out. On Isaacus's own legal-RAG measurement that is worth
~8% correctness over recursive splitting and ~12% over fixed-size, and it is
pure Python with no model behind it.

It also returns OFFSETS, which is why `content.resource_chunks` has had
`start_offset` and `end_offset` columns since the day it was written and
nothing had ever filled them: a citation can point at a span in the parsed
document rather than at a chunk id.

WHAT IS DELIBERATELY NOT ON BY DEFAULT. semchunk 3+ can call Isaacus's
enrichment API to chunk with a model (`chunking_model=`), worth another ~6%
on that same benchmark. It is a paid network call per document, it is a second
vendor in the ingest path, and this is the step that runs on every upload. A
deployment that wants it has an obvious place to say so; a default that
silently bills per document is not something to ship.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .policy import ChunkPolicy

__all__ = ["chunk_markdown", "token_counter"]


def _estimate(text: str) -> int:
    """Characters over four, floored at one.

    Not a tokenizer and not pretending to be. It is within ~10% of BPE counts
    for English prose, it is identical on every machine, and it never reaches
    the network -- which is what a container needs from a token counter.
    """
    return max(1, len(text) // 4)


def token_counter(spec: str) -> Callable[[str], int]:
    if spec == "estimate":
        return _estimate
    if spec.startswith("tiktoken:"):
        try:
            import tiktoken
        except ModuleNotFoundError:
            raise RuntimeError(
                "chunking policy asks for " + spec + " but tiktoken is not installed. "
                "pip install tiktoken, or use tokenizer: estimate") from None
        enc = tiktoken.get_encoding(spec.split(":", 1)[1])
        return lambda s: len(enc.encode(s, disallowed_special=()))
    raise RuntimeError(
        "unknown tokenizer " + repr(spec) + " -- use 'estimate' or 'tiktoken:<encoding>'")


def chunk_markdown(markdown: str, policy: ChunkPolicy) -> list[dict[str, Any]]:
    """Chunks, in order, each with its span in `markdown`.

    Returns the shape content.record_ingest expects, so nothing between here
    and the database reshapes it.
    """
    try:
        import semchunk
    except ModuleNotFoundError as e:
        raise RuntimeError(
            "chunking needs semchunk: pip install 'percolate-core[ingest]' "
            f"(missing {e.name})") from None

    count = token_counter(policy.tokenizer)
    chunks, offsets = semchunk.chunk(
        markdown, policy.target_tokens, count,
        offsets=True,
        # semchunk treats 0 and None differently: None is "no overlap", 0 is a
        # zero-token overlap it still tries to compute. Pass None.
        overlap=policy.overlap or None)

    out: list[dict[str, Any]] = []
    for text, (start, end) in zip(chunks, offsets):
        text = text.strip()
        if not text:
            continue
        # A tail too short to mean anything is folded backwards rather than
        # embedded on its own: a 30-character chunk produces a vector that is
        # mostly noise and a citation that shows a fragment. Folding keeps the
        # span honest by extending the previous chunk's end offset.
        if out and len(text) < policy.min_chars:
            out[-1]["content"] += "\n\n" + text
            out[-1]["end_offset"] = end
            out[-1]["token_count"] = count(out[-1]["content"])
            continue
        out.append({"content": text, "token_count": count(text),
                    "start_offset": start, "end_offset": end})
    return out
