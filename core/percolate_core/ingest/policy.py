"""What to do with a file, and who gets to decide.

Three layers, in this order, later winning key by key at every depth:

    1. the FAMILY DEFAULT     -- here, in code, because it is a fact about a
                                 file format and the library that reads it
    2. the CHANNEL            -- content.channels.config.ingest_policy
    3. the UPLOAD             -- content.resources.metadata.ingest_policy

Layers 2 and 3 are merged in the database (``content.merge_policy``) and
arrive here as one patch; this module owns layer 1 and the validation of all
three.

WHY THE DEFAULTS ARE NOT IN A TABLE. They are statements about libraries --
"a PDF is read by pymupdf4llm", "a transcript has no paragraph breaks so its
chunks overlap more" -- and they change when the library does, in the same
commit. A table of them is a second place to be wrong, kept in step by hand,
by a person who has just changed the code.

WHY THE OVERRIDES ARE NOT IN CODE. They are statements about a deployment's
content -- "our contracts chunk small", "this channel's CSVs are one table" --
and they are made by the person uploading, who is not the person deploying
this worker.

The model is pydantic and it is STRICT (``extra='forbid'``): a policy with a
misspelled key is refused by name rather than silently ignored, because a
silently-ignored override is a chunking strategy that the uploader believes is
in force and is not.
"""

from __future__ import annotations

import posixpath
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

__all__ = [
    "ChunkPolicy",
    "IngestPolicy",
    "PolicyError",
    "TablePolicy",
    "TranscribePolicy",
    "family_of",
    "resolve",
]


class PolicyError(ValueError):
    """A policy that cannot be honoured. Terminal: it fails the same on retry."""


class ChunkPolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # GENEROUS BY DEFAULT -- roughly two to three paragraphs of prose.
    #
    # The instinct in most RAG code is 200-400 tokens, and it is wrong for the
    # thing this collection actually does with a chunk: it is retrieved, put in
    # front of a model, and cited. A 250-token chunk retrieves the sentence
    # that matched and loses the sentence that explains it, so the model is
    # asked to answer from a fragment and the citation points at one. Bigger
    # chunks cost more per embedding call and fewer of them; the ranking gets
    # blunter only when a chunk holds several unrelated things, which at ~700
    # tokens of ordinary prose it does not.
    target_tokens: int = Field(default=700, ge=32, le=8000)

    # A fraction of the chunk (or, at >= 1, a token count) -- semchunk's own
    # parameter, passed through rather than reimplemented. Overlap exists for
    # the sentence that straddles a boundary; 8% of 700 is ~56 tokens, about
    # two sentences, which is what a straddle costs.
    overlap: float = Field(default=0.08, ge=0.0)

    # HOW A TOKEN IS COUNTED, and the default is deliberately not a tokenizer.
    #
    # `estimate` is characters/4, offline and exact in the only sense that
    # matters here: it is the same on every machine, needs no model file, and
    # never reaches the network. tiktoken is a better count and it DOWNLOADS
    # its encoding on first use -- a container that boots without egress then
    # fails inside the chunker, which is a bad place to discover a network
    # policy. Ask for it explicitly when the exactness is worth that:
    #     tokenizer: "tiktoken:cl100k_base"
    tokenizer: str = "estimate"

    # Chunks shorter than this are folded into their predecessor. A four-word
    # tail chunk embeds to a vector that ranks against nothing and shows up in
    # citations as a fragment.
    min_chars: int = Field(default=120, ge=0)


class TranscribePolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # An OpenAI-shaped /audio/transcriptions endpoint. Point it anywhere that
    # speaks that shape -- a local whisper.cpp server, vLLM, a provider.
    endpoint: str = "https://api.openai.com/v1/audio/transcriptions"
    model: str = "whisper-1"
    # A NAME, resolved from this worker's environment, exactly as an
    # http_call step's credential_ref is. No secret is stored in the database
    # and none is written in a policy.
    credential: str = "LLM_API_KEY"
    language: str | None = None
    # A hint given to the model, not to us: it improves proper nouns.
    prompt: str | None = None


class TablePolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # The logical table this upload belongs to. Defaults to the file's stem, so
    # `sales-2026-08.csv` and `sales-2026-09.csv` are two files of `sales`
    # only if the uploader says so -- guessing that from a name would silently
    # merge two tenants' unrelated exports.
    name: str | None = None
    mode: Literal["append", "replace"] = "append"
    partition_by: list[str] = Field(default_factory=list)
    # Passed to the CSV reader. Null delimiter means "sniff it".
    delimiter: str | None = None
    header: bool = True


class IngestPolicy(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # WHAT THE BYTES ARE FOR, which is the one decision everything else hangs
    # off:
    #   text     -- parse to markdown, chunk it, embed the chunks
    #   tabular  -- convert to Parquet, register a dataset, chunk NOTHING
    #   store    -- keep the bytes, produce no chunks (an image, an archive)
    #   skip     -- do not even fetch them
    mode: Literal["text", "tabular", "store", "skip"] = "text"

    # Which reader. Null takes the family's default; naming one that cannot
    # read this family is refused rather than ignored.
    parser: str | None = None

    chunking: ChunkPolicy = Field(default_factory=ChunkPolicy)
    transcribe: TranscribePolicy = Field(default_factory=TranscribePolicy)
    table: TablePolicy = Field(default_factory=TablePolicy)

    # Keep the intermediate markdown in object storage. It is the answer to
    # "why does this chunk read like that", which is nearly always the
    # parser's doing and not the chunker's, and it costs one PUT of text you
    # already have in memory.
    keep_markdown: bool = True

    # The embedding model is NOT here, and that is a boundary rather than an
    # omission: which space a corpus is embedded into is the workflow's
    # decision, resolved once by aiq.embed_call from the registry and recorded
    # on every child task. A policy field for it would be a second place to
    # say it, and the two would disagree.


# ---------------------------------------------------------------------------
# Families: what kind of thing is this, given a content type and a name
# ---------------------------------------------------------------------------

# Content types first, extensions second. Neither alone is enough: browsers
# send `application/octet-stream` for anything they do not recognise, and curl
# sends whatever the caller typed -- while an extension is absent from half the
# uploads that arrive as a stream.
_TYPE_FAMILY: dict[str, str] = {
    "text/markdown": "markdown",
    "text/x-markdown": "markdown",
    "text/plain": "text",
    "text/html": "html",
    "application/xhtml+xml": "html",
    "application/pdf": "pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
    "text/csv": "tabular",
    "text/tab-separated-values": "tabular",
    "application/vnd.ms-excel": "tabular",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "tabular",
    "application/vnd.apache.parquet": "tabular",
    "application/x-parquet": "tabular",
    "application/json": "text",
}

_EXT_FAMILY: dict[str, str] = {
    ".md": "markdown", ".markdown": "markdown", ".mdx": "markdown",
    ".txt": "text", ".log": "text", ".json": "text", ".yaml": "text", ".yml": "text",
    ".html": "html", ".htm": "html",
    ".pdf": "pdf",
    ".docx": "docx",
    ".csv": "tabular", ".tsv": "tabular", ".parquet": "tabular",
    ".xlsx": "tabular", ".xls": "tabular",
    ".wav": "audio", ".mp3": "audio", ".m4a": "audio", ".flac": "audio",
    ".ogg": "audio", ".oga": "audio", ".webm": "audio", ".mp4": "audio",
}


def family_of(content_type: str | None, name: str | None = None) -> str:
    """The family, from the content type when it says something, else the name.

    `application/octet-stream` is treated as SILENCE rather than as a family:
    it is what every uploader sends when it does not know, and taking it at
    face value would send a PDF down the `store` path and produce a resource
    that is registered, unreadable, and reports success.
    """
    ct = (content_type or "").split(";")[0].strip().lower()
    if ct.startswith(("audio/", "video/")):
        return "audio"
    if ct.startswith("image/"):
        return "image"
    if ct in _TYPE_FAMILY:
        return _TYPE_FAMILY[ct]
    ext = posixpath.splitext((name or "").lower())[1]
    if ext in _EXT_FAMILY:
        return _EXT_FAMILY[ext]
    if ct.startswith("text/"):
        return "text"
    return "unknown"


# The defaults, per family. Everything not named here inherits IngestPolicy's
# own field defaults, so this table says only what actually differs.
_DEFAULTS: dict[str, dict[str, Any]] = {
    "markdown": {"mode": "text", "parser": "markdown"},
    "text":     {"mode": "text", "parser": "text"},
    "html":     {"mode": "text", "parser": "html"},
    "pdf":      {"mode": "text", "parser": "pymupdf4llm"},
    "docx":     {"mode": "text", "parser": "docx"},
    # A transcript arrives as one wall of text: no headings, no blank lines,
    # and often no punctuation the chunker can trust. Smaller chunks with more
    # overlap is the honest response to having no structure to cut on.
    "audio":    {"mode": "text", "parser": "transcribe",
                 "chunking": {"target_tokens": 450, "overlap": 0.15}},
    "tabular":  {"mode": "tabular", "parser": "arrow"},
    # Bytes we keep and do not pretend to read. An image COULD go to a vision
    # model and be described; that is a real feature and it is not this one,
    # and defaulting to it would put a model call behind every avatar upload.
    "image":    {"mode": "store", "parser": None},
    "unknown":  {"mode": "store", "parser": None},
}


def _merge(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    """Deep merge, matching content.merge_policy() on the database side.

    The same rule in two languages is a duplication, and the alternative is
    worse: doing it only in SQL would mean the family default could not be
    patched at all, and only in Python would mean a channel policy and an
    upload policy could not be combined before they got here.
    """
    out = dict(base)
    for k, v in (patch or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def resolve(content_type: str | None,
            name: str | None = None,
            overrides: dict[str, Any] | None = None) -> tuple[str, IngestPolicy]:
    """(family, policy) for one file. Raises PolicyError on a policy we cannot honour."""
    family = family_of(content_type, name)
    merged = _merge(_DEFAULTS.get(family, _DEFAULTS["unknown"]), overrides or {})
    try:
        return family, IngestPolicy(**merged)
    except ValidationError as e:
        # The uploader's own words back to them. A policy is a thing a person
        # typed, so the error names the field they typed wrong -- and it is a
        # PolicyError, which the handler turns into a TERMINAL failure, because
        # a misspelled key spells the same on every retry.
        detail = "; ".join(
            ".".join(str(part) for part in err["loc"]) + ": " + err["msg"]
            for err in e.errors())
        raise PolicyError(
            "ingest policy for this " + family + " upload is not valid: " + detail
        ) from None
