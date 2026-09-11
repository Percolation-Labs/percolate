"""Authored SQL is one SELECT. DuckDB's parser decides, not a pattern.

The seal in engine.py confines what a connection can touch; this confines what
authored SQL can SAY. Both are needed, and the second exists because the first
was measured and found to leak: a locked connection still accepts CREATE SECRET,
and one scoped to an allowed prefix with a foreign endpoint turned a COPY into
an upload to that endpoint (lake.md §3.1).

Classifying with `extract_statements` is an identity check, not a language
rule: it asks the same parser that will execute the text what the text is. So
`select * from query('create secret …')` is refused by DuckDB itself ("Expected
a single SELECT statement"), `with … select` is a SELECT, and a second
statement smuggled after a semicolon is two statements.
"""

from __future__ import annotations

from ..worker.templates import TerminalError

__all__ = ["single_select"]


def single_select(sql: str | None) -> str:
    if not sql or not str(sql).strip():
        raise TerminalError("a refine step needs `sql:` -- one SELECT over its inputs")
    from .engine import _duckdb

    duckdb = _duckdb()
    try:
        statements = duckdb.connect().extract_statements(str(sql))
    except Exception as e:  # noqa: BLE001 -- a ParserException, and any parse failure is the author's
        raise TerminalError(f"the refine SQL does not parse: {str(e).splitlines()[0]}") from None
    kinds = [s.type.name for s in statements]
    if kinds != ["SELECT"]:
        raise TerminalError(
            f"the refine SQL must be exactly one SELECT, and it is {len(kinds)} "
            f"statement(s): {', '.join(kinds) or 'none'}. Writes belong to `output:` "
            "and `land:`, which this step performs itself; authored SQL only reads.")
    return str(sql)
