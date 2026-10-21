"""An agent document, and the one place it becomes a row: not this process.

`brief.md` §6 gives an agent two documented spellings. The **document** is what
`model_json_schema()` emits -- there is no `prompt` key, the system prompt is the
schema's `description` and the output contract is its `properties` -- and the
**row** spells those two `system_prompt` and `structured_output_schema`. Every
worked example in the documentation authors the first one.

Until REM-70 each tool that read a document mapped it onto columns itself, and
each knew one dialect: `core/samples.py` and `percolate agent push` knew
`description`/`properties`, our package loader knew a package
manifest's file-path `output_schema`, and `agentic.upsert_agent` accepted any
document and dropped the keys it did not read. So a manifest written the way the
documentation writes an agent installed, reported success, and left an agent with
an empty prompt and no output contract -- one that exists, resolves by name and
can do nothing.

**The translation is now `agentic.agent_document_to_row`, in the extension,
called by `agentic.upsert_agent`.** This module holds no mapping, on purpose. It
holds the one thing a client still has to know: an extension that predates the
translation *accepts* a document and silently drops half of it, so a client
sending one has to ask first and refuse loudly rather than write that agent.

`agentic/authoring.py` still turns a document into a typed `AgentSpec` for
in-process use -- that is what makes `from_model_class` and the in-memory
repository work with no database anywhere. What it may not do is produce the row:
anything destined for `agents` travels to the database as the document.
"""

from __future__ import annotations

from typing import Any

# `to_regprocedure` rather than a catalogue join or a version comparison: it
# answers the question actually being asked -- can this database translate a
# document -- and it answers it for a database upgraded in place, where
# `pg_extension.extversion` has been known to lag what is installed.
SUPPORTS_SQL = (
    "select to_regprocedure('agentic.agent_document_to_row(jsonb)') is not null"
)

NEEDS_TRANSLATION = (
    "an extension that predates REM-70 accepts this document and stores an agent "
    "with an empty system prompt and no output contract, reporting success. "
    "Upgrade the extension to 0.2.0 or later (`alter extension percolate "
    "update`), or write these agents in the row form -- `system_prompt` and "
    "`structured_output_schema`. Nothing has been written."
)


def is_document(entry: dict[str, Any]) -> bool:
    """Whether this agent entry is written in the schema-document dialect.

    The row form installs correctly on every released extension, so only the
    document form needs the database to be new enough -- and asking precisely
    means a row-shaped plugin still loads against 0.1.x.

    `description` and `properties` are the distinguishing keys because they are
    the two that carry meaning the row spells differently. An entry carrying
    both dialects is not sorted out here: the database refuses it, which is one
    place rather than two deciding what a mixed document means.
    """
    return bool({"description", "properties"} & entry.keys())


async def assert_translates(conn: Any, entries: list[Any], where: str) -> None:
    """Refuse BEFORE the first write if this database would drop half the document.

    `conn` is anything with asyncpg's `fetchval`. Called once, before a load
    begins, rather than at the agent step: a sample that fails a third of the way
    through leaves the schema, the entities and the graph behind, and "partially
    loaded" is the one state neither loading again nor removing handles well.
    That is the same reason the check it replaces ran early, for the dependency
    that is no longer needed.
    """
    from .samples import SampleError

    if not any(is_document(e) for e in entries if isinstance(e, dict)):
        return
    if await conn.fetchval(SUPPORTS_SQL):
        return
    raise SampleError(f"{where} writes agents as JSON Schema documents, and {NEEDS_TRANSLATION}")
