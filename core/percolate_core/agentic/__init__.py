"""p8agentic — the agent runtime speced in ``specs/agentic``.

Agents are rows in Postgres, tools are MCP/OpenAPI services reached over the
network, a turn's rows are written through RLS as an ordinary ``authenticated``
caller, AG-UI events stream out over ``NOTIFY``, and delegation is an MCP call
into this runtime's own agent gateway. ``dev/verify.py`` asserts all of that
against a live LLM.

Layout, mapped onto ``specs/agentic/brief.md``:

- ``contracts``  — the ontology as pydantic types (brief §7, ontology.md), plus
  the two wire protocols (brief §5.1 item 2).
- ``db``         — a small asyncpg client and the ``Repository`` protocol every
  read/write in this runtime goes through (brief §5: "through the same functions
  and RLS any other client would go through, no privileged backdoor").
- ``tools``      — tool-server resolution and invocation: MCP is the canonical
  shape, OpenAPI is an adapter onto it (brief §5.2). Zero built-in tools.
- ``runtime``    — the four components of brief §5.1, one module each, plus the
  chained action (§4) and citation (§5.3) mechanisms.
- ``sequencer``  — the ordered steps of one agent turn, and the mapping from
  ``specs/agentic/sequence.md``'s phase gates onto demos that prove them.
- ``fakes``      — pydantic-ai fake models and an in-memory repository, so the
  whole path above runs with no Postgres and no LLM credentials.
- ``cli``        — the operator surface. FastAPI wraps this later (brief §4:
  streaming is the one piece that structurally can't be plain PostgREST).
"""

__version__ = "0.0.1"


def build_fingerprint() -> str:
    """A short hash of this package's source on disk.

    Exposed by every long-running surface (`/_build`) so a caller can tell
    whether the process it is talking to is running the code in the working
    tree. Three separate debugging sessions in this module's history began with
    a confusing failure whose cause was a server started before the fix — a
    stale process fails in the shape of a bug, and that is worth fifteen lines
    to make impossible.
    """
    import hashlib
    from pathlib import Path

    digest = hashlib.sha256()
    for path in sorted(Path(__file__).parent.rglob("*.py")):
        digest.update(path.name.encode())
        digest.update(str(path.stat().st_mtime_ns).encode())
    return digest.hexdigest()[:12]
