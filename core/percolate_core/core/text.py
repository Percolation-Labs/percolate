"""What a text column can hold, enforced where a string crosses into one.

One function, because one byte is the whole problem: Postgres `text` cannot
store U+0000, and every write this runtime makes goes through a jsonb argument
that the SQL side reads back with `->>`. So a single NUL anywhere in the
payload aborts the entire statement with `unsupported Unicode escape sequence`,
and the caller is told nothing about which string carried it.
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any


def without_nul(value: Any) -> Any:
    """U+0000 out of anything bound for a text column, at the last moment.

    Called in ONE place: the jsonb encoder every pool in this package installs
    (`core.identity.jsonb_text`), because every write that carries a foreign
    string does so through a jsonb argument. It was first called at two call
    sites, the two below, and at least three more writes had the same defect
    without it -- an http_call response on its way to `complete_task` (which
    also crosses `worker.artifacts.stored_size`), an API source's page on its
    way to `commit_api_page`, and a tool server's catalogue on its way to
    `upsert_tool_server`. A rule applied per call site is a rule the next call
    site does not know about.

    The first two were measured failing on 2026-09-12 against a live stack.

    * The agent path: the live petstore demo API served a NUL inside a pet's
      name, `agentic.persist_turn` read `content` with `->>`, and the turn
      finished `failed` after twenty-three seconds -- the model had run, the
      tools had run, and the only thing left was writing it down. Reported to
      the caller as a bare 502 with a wall-clock duration, which is why REM-146
      was filed as a timeout. It is not a timeout. Nothing here is timed.
    * The ingestion path: a 777-byte markdown upload with one NUL in it,
      `content.record_chunks` reading `c->>'content'`, the ingest task terminal
      and the three tasks after it cancelled. Zero chunks. A user can do this to
      their own upload with one byte.

    U+FFFD rather than deletion, because a message that lost a character should
    say where it lost it: a silently shortened tool result or chunk is a thing
    a reader would later have no way to notice, and the offsets a chunk carries
    back into its source would quietly stop lining up.
    """
    if isinstance(value, str):
        return value.replace("\x00", "�")
    if isinstance(value, Mapping):
        # KEYS TOO. `content.record_chunks` reads its keys back with
        # `jsonb_object_keys(c)`, which is text, so a key is a text column
        # by the same argument the values are.
        return {without_nul(k): without_nul(v) for k, v in value.items()}
    if isinstance(value, list):
        return [without_nul(v) for v in value]
    return value
