"""The query tool server: one MCP tool, ``query``, over the p8ql dialect.

    percolate query mcp --port 8090 --postgrest http://postgrest:3000

Ported from ``specs/agentic/reference/query_mcp.py`` in percolate, which the
collection's dev stack ran from a mounted file. A get-percolate install had no
such file and no such process, so the sample's ``harbourmaster`` bound nothing
and answered "I don't have access to live databases" about the sample it ships
with. A command in the image is something compose and the chart can run.

Why an MCP server rather than binding ``POST /rpc/query`` through the OpenAPI
adapter: that binding is a tool called ``post_rpc_query`` taking
``p_query: string`` among thirty other ``post_rpc_*`` operations, with nothing
saying what a p8ql string looks like. The dialect's difficulty is its grammar,
and MCP is where the grammar can be the tool's description.

Three properties the port keeps, and ``tests/test_query_mcp.py`` checks each:

1.  **No tool logic.** It forwards to ``aiq.query`` and returns what came back.
    Retrieval, ranking and query building live in SQL. One documented hop is
    the exception: ``aiq.query`` does not execute SQL mode, it returns the
    statement with a note to run it through ``aiq.sql_passthrough``, and the
    description the model reads says SQL is "executed read-only through the
    SECURITY INVOKER passthrough". So that hop is made here, with the same
    header, and nothing else is. The port shipped without it: the note came
    back to the model as a success, and the sample agent asked again until
    pydantic-ai's request limit stopped it, fifty calls in.

2.  **The description is fetched, not written.** ``tools/list`` builds it from
    ``SCHEMA "p8ql"``, the dialect facet the parser emits, so a deployment with
    different sources advertises different ones and nothing here restates the
    grammar.

3.  **Identity is the caller's.** The ``Authorization`` header on the MCP
    request goes to PostgREST verbatim. This process holds no credential and
    reads nothing on its own behalf, so row-level security applies to the tool
    call exactly as it would to the person asking. It only receives that header
    from an agent runtime whose ``P8_TOOL_AUTH_ORIGINS`` names this server.

Standard library only: the server forwards one JSON body, and the base install
(no extras) can run it.

SEMANTIC EXCEPTIONS, when the operator turns them on (``P8_SEMANTIC_EXCEPTIONS``
= ``on`` or ``strict``, with ``JEV_API_KEY`` bound like any credential). The
tool then takes an optional ``question`` -- what the caller is trying to find
out, in its own words -- and every answer carries
``structuredContent.semantic_exceptions``: the typed exceptions the question and
the result raised, and a receipt of what was checked, so "nothing raised" is
distinguishable from "nothing ran". Their prompt is appended to the text the
model reads. ``strict`` withholds the rows when an error-severity kind is raised
(a blended question, a negation): the model gets the prompt as an error and
asks again. This is the one place the server adds anything to what ``aiq.query``
returned, and it adds it beside the rows, never in them.

``shadow`` computes the same exceptions and shows the model nothing: the tool
looks as it does under ``on`` but without the paragraph and the block, so an
experiment can compare the two arms on real traffic. ``P8_QUERY_LOG`` names a
file that receives one ``QueryEvent`` per call in every mode (the question, the
plan, result statistics, the exceptions and whether they were shown), with the
session and run from the runtime's ``X-P8-*`` headers so that what a caller
asked next can be paired with what it asked first (semantic_exceptions/log.py).
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from . import memory_tools

# The protocol revision this speaks. A client asking for a different one is
# answered with this one rather than an error, which is what the spec asks for.
PROTOCOL_VERSION = "2025-06-18"

# The one thing said here that the database cannot say for itself: what the tool
# is FOR. The mode list is filled in from the same `SCHEMA "p8ql"` read that
# builds the rest, so a mode reaches the prompt because the parser emits it.
TOOL_PREAMBLE = """\
Ask this database a question in p8ql, its query dialect. One string, one
endpoint, every retrieval mode: %s.

The response carries the parsed `plan` next to the `rows`, so a query that was
understood differently than intended is visible rather than looking like an
empty result. Read the plan when rows come back empty.

The grammar and the currently registered sources follow, emitted by the parser
and the live schema at the moment you were given this tool:
"""


class Upstream:
    """PostgREST, called with the caller's own credentials."""

    def __init__(self, base: str, timeout: float = 30.0):
        self.base = base.rstrip("/")
        self.timeout = timeout

    def read(self, path: str, authorization: str | None = None, profile: str = "aiq"):
        """A table read as the caller: ``(rows, None)`` or ``(None, error)``."""
        req = urllib.request.Request(f"{self.base}/{path}", headers={
            "Accept-Profile": profile,
            **({"Authorization": authorization} if authorization else {})})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return json.loads(r.read() or b"null"), None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
            return None, {"kind": "dispatch_error", "detail": str(e)}

    def rpc(self, fn: str, payload: dict[str, Any], authorization: str | None = None,
            profile: str = "aiq"):
        """``(document, None)`` on success, ``(None, error)`` otherwise."""
        req = urllib.request.Request(
            f"{self.base}/rpc/{fn}",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                # aiq is not PostgREST's default schema, so every call names it
                # (content for the query log's one write).
                "Accept-Profile": profile,
                "Content-Profile": profile,
                **({"Authorization": authorization} if authorization else {}),
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return json.loads(r.read() or b"null"), None
        except urllib.error.HTTPError as e:
            body: Any = e.read().decode(errors="replace")
            try:
                body = json.loads(body)
            except ValueError:
                pass
            return None, {"kind": "tool_error", "status": e.code, "body": body}
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            # "The tool ran and said no" and "the tool was unreachable" are
            # different facts (brief.md §5.2), and the runtime keeps them apart
            # through `_meta.errorKind`.
            return None, {"kind": "dispatch_error", "detail": str(e)}


# shadow computes and logs the exceptions without showing them: the control arm
# of the same traffic, so "did the agent need a second try where the layer would
# have spoken?" is answerable without the layer having changed what it did.
EXCEPTIONS_MODES = ("off", "shadow", "on", "strict")


class PercolateLog:
    """The query log as rows: each event goes to content.record_query with the
    caller's own Authorization, so it is a private stored row they own on the
    query_log channel (extension 0.2.23). Bound to the handler's upstream when
    the server is built, since that is the PostgREST every query goes to."""

    upstream: "Upstream | None" = None

    def append(self, event: Any, authorization: str | None = None) -> None:
        if self.upstream is None:
            raise RuntimeError("the query log has no PostgREST to write to")
        _, err = self.upstream.rpc("record_query", {"p_event": event.to_dict()}, authorization,
                                   profile="content")
        if err:
            raise RuntimeError(f"content.record_query: {err}")


_UUID = __import__("re").compile(r"^[0-9a-fA-F-]{36}$")
_IDENT = __import__("re").compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def hydrate_semantic(up: "Upstream", doc: dict, authorization: str | None) -> dict:
    """A SEMANTIC answer's rows with the text of each hit.

    aiq.semantic_in returns (chunk_id, distance, model): ids a model cannot
    read, and no mode resolves them (run 2: "SEMANTIC returns only chunk ids,
    with no text, so it was hard to use"). The registry names the source's
    table and text column, and the read-only passthrough fetches them as the
    caller, so row-level security decides what comes back exactly as it does
    for the search. Identifiers come from the registry and are checked; ids
    are checked as UUIDs. Anything unexpected leaves the rows as they were."""
    plan = doc.get("plan") or {}
    rows = doc.get("rows") or []
    ids = [r.get("chunk_id") for r in rows if isinstance(r, dict) and "content" not in r]
    ids = [i for i in ids if isinstance(i, str) and _UUID.match(i)]
    if doc.get("mode") != "SEMANTIC" or not plan.get("source") or not ids:
        return doc
    src, err = up.read(f"semantic_sources?name=eq.{urllib.parse.quote(plan['source'])}"
                       "&select=source_table,content_col", authorization)
    if err or not src:
        return doc
    schema, _, table = (src[0].get("source_table") or "").rpartition(".")
    col = src[0].get("content_col") or ""
    if not all(_IDENT.match(x) for x in (schema, table, col)):
        return doc
    quoted = ", ".join(f"'{i}'" for i in ids)
    found, err = up.rpc("sql_passthrough", {"p_statement":
        f'select id::text as id, "{col}" as content from "{schema}"."{table}" '
        f"where id in ({quoted})"}, authorization)
    if err or not isinstance(found, list):
        return doc
    text = {f.get("id"): f.get("content") for f in found if isinstance(f, dict)}
    return {**doc, "rows": [{**r, "content": text[r["chunk_id"]]}
                            if isinstance(r, dict) and r.get("chunk_id") in text else r
                            for r in rows]}


class QueryEmbedder:
    """Embeds a SEARCH or SEMANTIC query's text when the caller sent no vector.

    ``aiq.query`` takes the vector beside the text because embedding is a model
    call, outside SQL. A shell or an IDE can supply it; a model calling this
    tool cannot, so through MCP both modes failed on every call and agents fell
    back to TEXT (traffic run 1: "SEARCH and SEMANTIC need an embedding I could
    not supply"). The tool is the one place that can.

    Nothing about the model is decided here. The plan comes from the database's
    own parser (``aiq_parse``), and the model from its registry
    (``aiq.embedding_models``): the one the query names with USING, else the
    default, embedded only if its provider runs in-process (fastembed), with
    the registry's ``endpoint`` as the model id -- exactly what the ingest
    worker used to write the vectors being searched. A hosted provider, or no
    fastembed installed, leaves the query failing as it did, with its message.
    The answer says it was embedded here, and with which model.
    """

    def __init__(self, mode: str | None = None):
        self.mode = (mode or os.environ.get("P8_QUERY_EMBED") or "auto").lower()
        self._models: dict[str, dict] = {}

    @property
    def on(self) -> bool:
        if self.mode == "off":
            return False
        if self.mode == "on":
            return True
        try:
            import fastembed  # noqa: F401
            return True
        except ImportError:
            return False

    def plan(self, up: "Upstream", q: str, auth: str | None) -> dict | None:
        doc, err = up.rpc("aiq_parse", {"query": q}, auth, profile="public")
        return doc if err is None and isinstance(doc, dict) and doc.get("ok") else None

    def model(self, up: "Upstream", name: str | None, auth: str | None) -> dict | None:
        key = name or ""
        if key not in self._models:
            where = f"name=eq.{urllib.parse.quote(name)}" if name else "is_default=is.true"
            rows, err = up.read(f"embedding_models?{where}&select=name,dim,provider,endpoint",
                                auth)
            provs, perr = up.read("embedding_providers?select=provider,in_process", auth)
            if err or perr or not rows:
                return None
            local = {p["provider"] for p in provs or () if p.get("in_process")}
            m = rows[0]
            if m.get("provider") not in local or not m.get("endpoint"):
                return None
            self._models[key] = m
        return self._models[key]

    def retry(self, up: "Upstream", q: str, auth: str | None):
        """``(doc, err)`` from asking again with a vector, or None if this
        query is not one the tool can embed."""
        if not self.on:
            return None
        plan = self.plan(up, q, auth)
        if not plan or plan.get("mode") not in ("SEMANTIC", "SEARCH") or not plan.get("arg"):
            return None
        m = self.model(up, plan.get("model"), auth)
        if m is None:
            return None
        from ..ingest.local_embed import embed_local
        [vec] = embed_local(m["endpoint"], [plan["arg"]], expected_dim=m.get("dim"))
        doc, err = up.rpc("query", {"p_query": q, "p_embedding": json.dumps(vec)}, auth)
        if err is None and isinstance(doc, dict):
            doc = {**doc, "embedded": {"by": "query tool", "model": m["name"]}}
        return doc, err
# THE QUERY TOOL'S OWN MOVES, appended to a kind's prompt as "Here: ...". The
# kinds name a remedy in general terms; a searcher acts on the move this tool
# offers for it (the navigation round's lesson: the repository's own command).
QUERY_ACTIONS = {
    "DECOMPOSITION_REQUIRED": "call this tool once per part, then combine the answers.",
    "TWO_QUESTIONS": "call this tool once per question.",
    "CONJUNCTION": "one query per condition; keep the records that come back for both.",
    "COMPARISON": "one query per side, then compare them.",
    "YES_NO_CLAIM": "one SEARCH worded as the claim and one worded as its opposite.",
    "EXACT_MATCH": 'TEXT "<the exact phrase or id>" FROM <source>.',
    "META_QUESTION": 'SCHEMA "sql" FROM <source> and SCHEMA "graph" say what is held.',
    "EMPTY": "if you searched by words (TEXT), search by meaning (SEARCH), and the reverse.",
    "TRUNCATED_AT_LIMIT": "{total} rows match and you saw {returned}. For a count or a full "
                          "list, use SQL over {relation}; otherwise raise the LIMIT or narrow the query.",
    "NEGATION": "SQL over {relation}, excluding what matches.",
    "SUPERLATIVE": "SQL over {relation}, ordered, LIMIT 1.",
    "COUNT": "SQL over {relation}: count(*) under an exact filter.",
    "EXHAUSTIVE": "SQL over {relation} with no LIMIT.",
    "ARITHMETIC": "SQL over {relation} to compute it.",
    "KNOWN_VS_HAPPENED": "SQL over {relation}, filtering on the time column the question means.",
    "RELATIVE_TIME": "SQL over {relation}, with the relative time as a date range.",
}


def actions_for(relation: dict | None, total: int | None = None,
                returned: int | None = None) -> dict[str, str]:
    """QUERY_ACTIONS with the source's own relation and columns written in.

    Run 2: the general wording -- 'SCHEMA "sql" FROM <source> names its
    relation' -- sent a user to `SCHEMA "sql" FROM dracula`, which lists
    nothing because SCHEMA takes a relation, and they concluded the text was
    not reachable by SQL. The two users who found the table on their own
    scored 4.5 of 8; the rest 1.3-2.5. So the move names the table."""
    out = {}
    for k, v in QUERY_ACTIONS.items():
        if "{total}" in v:
            if total is None:
                continue
            v = v.replace("{total}", str(total)).replace("{returned}", str(returned or 0))
        if "{relation}" in v:
            if not relation:
                continue
            cols = ", ".join(relation.get("columns") or ())
            v = v.replace("{relation}", f"{relation['schema']}.{relation['name']}"
                          + (f" (columns: {cols})" if cols else ""))
        out[k] = v
    return out


def count_matches(up: "Upstream", doc: dict, authorization: str | None) -> int | None:
    """PROBE P1: how many rows the query's words match in all, read as a count.

    A ranked result shows its top k and says nothing of the rest, so "these
    are all of them" and "these are ten of four hundred" look the same to the
    caller. When a TEXT or SEARCH result fills its LIMIT, the store counts the
    rows its lexical predicate matches -- the same plainto_tsquery TEXT ranks
    by, from the registry's table and text-search config -- through the
    read-only passthrough as the caller. It reads no content and returns one
    number. None when the result did not fill its limit, the mode has no
    lexical half, or anything about the registry is unexpected."""
    plan = doc.get("plan") or {}
    rows, limit = doc.get("rows") or [], plan.get("limit")
    if (plan.get("mode") not in ("TEXT", "SEARCH") or not plan.get("source")
            or not isinstance(plan.get("arg"), str) or not isinstance(limit, int)
            or len(rows) < limit):
        return None
    reg, err = up.read(f"lexical_sources?name=eq.{urllib.parse.quote(plan['source'])}"
                       "&select=source_table,regconfig,search_with", authorization)
    if err or not reg or reg[0].get("search_with"):
        return None
    schema, _, table = (reg[0].get("source_table") or "").rpartition(".")
    cfg = reg[0].get("regconfig") or ""
    if not all(_IDENT.match(x) for x in (schema, table, cfg)):
        return None
    arg = plan["arg"].replace("'", "''")
    found, err = up.rpc("sql_passthrough", {"p_statement":
        f'select count(*) as n from "{schema}"."{table}" '
        f"where search_tsv @@ plainto_tsquery('{cfg}', '{arg}')"}, authorization)
    if err or not isinstance(found, list) or not found:
        return None
    n = found[0].get("n") if isinstance(found[0], dict) else None
    return int(n) if isinstance(n, (int, float)) else None


class Exceptions:
    """The semantic-exceptions hook: off unless the operator turns it on."""

    def __init__(self, mode: str | None = None, jev_factory: Any = None, values_top: int = 0,
                 store: str | None = None, log: Any = None):
        self.mode = (mode or os.environ.get("P8_SEMANTIC_EXCEPTIONS") or "off").lower()
        if self.mode not in EXCEPTIONS_MODES:
            raise ValueError(f"P8_SEMANTIC_EXCEPTIONS must be one of {EXCEPTIONS_MODES}")
        self.values_top = int(os.environ.get("P8_SEMANTIC_EXCEPTIONS_VALUES", values_top))
        # One sentence on what this store holds. It switches on OUT_OF_DOMAIN and
        # it is the condition the thresholds were measured under; without it the
        # same question can score differently (measured: "the garlic" 0.96 vs
        # below threshold), so an operator should set it.
        self.store = store or os.environ.get("P8_SEMANTIC_EXCEPTIONS_STORE") or None
        self._jev_factory = jev_factory
        # THE QUERY LOG (semantic_exceptions/log.py): one QueryEvent per call,
        # in every mode including off, when P8_QUERY_LOG names a file.
        # `percolate` writes each event through content.record_query as the
        # caller, so it is a private row they own; anything else names a file.
        if log is None and os.environ.get("P8_QUERY_LOG"):
            target = os.environ["P8_QUERY_LOG"]
            if target == "percolate":
                log = PercolateLog()
            else:
                from ..semantic_exceptions.log import JsonlLog
                log = JsonlLog(target)
        self.log = log
        # What each session has already been shown (Report.novel). In use, a
        # warning repeated on every query was skipped with the rest of the block
        # by the third; the server is the only place that sees a session's
        # queries in order. Bounded: the oldest sessions are forgotten.
        self._seen: dict[str, set] = {}
        self._caps: dict[tuple, tuple[float, frozenset]] = {}
        self._relations: dict[tuple, dict | None] = {}

    @property
    def on(self) -> bool:
        """The exceptions are computed (shadow, on, strict)."""
        return self.mode != "off"

    @property
    def shows(self) -> bool:
        """The model reads them (on, strict)."""
        return self.mode in ("on", "strict")

    def capabilities(self, up: "Upstream", authorization: str | None,
                     source: str | None) -> frozenset:
        """What this caller can do on this source, asked of the database:
        "sql" when SCHEMA "sql" FROM <source> lists a relation they may read.
        Cached a few minutes per caller and source; a failed probe grants
        nothing, so the kinds that need it show as limits rather than advice."""
        import time as _t
        key = (authorization, source)
        hit = self._caps.get(key)
        if hit and _t.monotonic() - hit[0] < 300:
            return hit[1]
        relation = self._sql_relation(up, authorization, source) if source else None
        out = frozenset({"sql"} if relation else ())
        self._caps[key] = (_t.monotonic(), out)
        self._relations[key] = relation
        return out

    def relation(self, authorization: str | None, source: str | None) -> dict | None:
        """The relation the last probe found for this caller and source."""
        return self._relations.get((authorization, source))

    @staticmethod
    def _sql_readable(up: "Upstream", authorization: str | None, source: str) -> bool:
        return Exceptions._sql_relation(up, authorization, source) is not None

    @staticmethod
    def _sql_relation(up: "Upstream", authorization: str | None, source: str) -> dict | None:
        """The relation behind `source` that the caller can SELECT from, with
        its columns, or None.

        SCHEMA "sql" FROM takes a RELATION name, and a p8ql source is a
        registry name (`dracula` over `sx.passages`): asked with the source,
        the probe said no on a store whose table the caller could read. So the
        source is resolved through the registry first, and the relation is
        matched by schema and name."""
        table = None
        for reg in ("lexical_sources", "semantic_sources"):
            rows, err = up.read(f"{reg}?name=eq.{urllib.parse.quote(source)}&select=source_table",
                                authorization)
            if err is None and rows:
                table = rows[0].get("source_table")
                break
        schema, _, name = (table or source).rpartition(".")
        doc, err = up.rpc("query", {"p_query": f'SCHEMA "sql" FROM {name}'}, authorization)
        if err is not None or not isinstance(doc, dict):
            return None
        derived = ((doc.get("schema") or {}).get("doc") or {}).get("derived") or {}
        for r in derived.get("relations") or ():
            if r.get("name") == name and (not schema or r.get("schema") == schema):
                return {"schema": r.get("schema") or schema, "name": name,
                        "columns": [c.get("name") for c in r.get("columns") or ()
                                    if isinstance(c, dict) and c.get("name")]}
        return None

    def novel(self, report: Any, session: str | None) -> Any:
        """The report as this session has not yet seen it; unchanged without a session."""
        if report is None or not session:
            return report
        seen = self._seen.pop(session, set())
        self._seen[session] = seen          # most recent last
        while len(self._seen) > 10_000:
            self._seen.pop(next(iter(self._seen)))
        return report.novel(seen)

    def record(self, query: str, doc: Any, authorization: str | None = None, **kw: Any) -> None:
        """Append one event. A log that fails does not fail the query."""
        if self.log is None:
            return
        from ..semantic_exceptions.log import event_of
        try:
            event = event_of(query, doc, exceptions_mode=self.mode, **kw)
            if isinstance(self.log, PercolateLog):
                self.log.append(event, authorization=authorization)
            else:
                self.log.append(event)
        except Exception as e:
            print(f"[query-mcp] query log: {type(e).__name__}: {e}", flush=True)

    def _jev(self):
        if self._jev_factory is not None:
            return self._jev_factory()
        from ..decide import Jev
        return Jev()

    def inspect(self, doc: Any, question: str | None,
                capabilities: frozenset | None = None, relation: dict | None = None,
                total: int | None = None) -> dict:
        """``{"report": Report | None, "error": str | None}``. A judge that fails
        does not fail the query: the receipt says it did not run, and why."""
        from ..semantic_exceptions import SemanticExceptions
        from ..semantic_exceptions.query import inspect

        async def run():
            jev = self._jev()
            try:
                return await inspect(SemanticExceptions(jev, store=self.store,
                                                        actions=actions_for(
                                                            relation, total,
                                                            len(doc.get("rows") or [])),
                                                        capabilities=capabilities),
                                     doc, question, values_top=self.values_top, total=total)
            finally:
                close = getattr(jev, "aclose", None)
                if close is not None:
                    await close()
        try:
            return {"report": asyncio.run(run()), "error": None}
        except Exception as e:  # the rows are still the answer
            return {"report": None, "error": f"{type(e).__name__}: {e}"[:300]}


def describe_sources(up: "Upstream", authorization: str | None) -> str:
    """Each searchable source and the table behind it that this caller may
    query with SQL, with its columns: said once, in the tool's description.

    Probe P1 (evals/semantic_exceptions/probes/RESULTS.md): the fact that moved
    answers was not a count but that the source `dracula` is the table
    sx.passages, whose columns say who wrote each passage and when. Agents not
    told said "the store does not expose which document a passage belongs
    to". A fact about the schema is the same for every query, so it belongs
    here, at no per-query cost, rather than in an exception."""
    names: dict[str, None] = {}
    for reg in ("lexical_sources", "semantic_sources"):
        rows, err = up.read(f"{reg}?select=name&order=name", authorization)
        for r in rows or ():
            if isinstance(r, dict) and r.get("name"):
                names[r["name"]] = None
    lines = []
    for name in names:
        rel = Exceptions._sql_relation(up, authorization, name)
        if rel:
            cols = ", ".join(rel.get("columns") or ())
            lines.append(f"- {name}: the table {rel['schema']}.{rel['name']}"
                         + (f" ({cols})" if cols else ""))
    if not lines:
        return ""
    return ("SOURCES YOU CAN ALSO READ WITH SQL. Each search source below is a table you may "
            "query directly in SQL mode, for exact filters, counts, sorts, exclusions and the "
            "columns a search does not return:\n" + "\n".join(lines))


def describe_query_tool(up: Upstream, authorization: str | None,
                        exceptions: "Exceptions | None" = None) -> dict[str, Any]:
    """The tool definition, its description built from ``SCHEMA "p8ql"``."""
    doc, err = up.rpc("query", {"p_query": 'SCHEMA "p8ql"'}, authorization)
    if err:
        # Listing the tool with a thinner description beats refusing to list
        # it: the agent keeps the capability and loses some prose.
        detail = f"(the live dialect schema could not be read: {err.get('detail') or err.get('status')})"
        modes: list[str] = []
    else:
        facet = (doc or {}).get("schema", {}).get("doc", {})
        detail = json.dumps(facet, indent=1)
        modes = [m["mode"] for m in facet.get("declared", {}).get("modes", [])]
    preamble = TOOL_PREAMBLE % (", ".join(modes) if modes else "see the grammar below")
    properties: dict[str, Any] = {
        "query": {
            "type": "string",
            "description": "One p8ql statement. See the modes above.",
        }
    }
    if os.environ.get("P8_QUERY_DESCRIBE_SOURCES", "off").lower() in ("on", "1", "true"):
        tables = describe_sources(up, authorization)
        if tables:
            preamble = preamble.rstrip() + "\n\n" + tables + "\n"
    if exceptions is not None and exceptions.shows:
        preamble = (preamble.rstrip() + "\n\nThe store also checks what you ask and what came "
                    "back, and answers with SEMANTIC EXCEPTIONS when it sees something you should "
                    "act on (a question to split, a negation to run as an exact filter, a result "
                    "that continues). Act on them before answering.\n")
    if exceptions is not None and exceptions.on:
        # Asked in shadow too, so the two arms differ only in what is shown.
        properties["question"] = {
            "type": "string",
            "description": "What you are trying to find out, in your own words.",
        }
    return {
        "name": "query",
        "title": "Query the Percolate knowledge base",
        "description": preamble + "\n" + detail,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": ["query"],
            "additionalProperties": False,
        },
    }


def _is_unexecuted_sql(doc: Any) -> bool:
    """``aiq.query``'s SQL-mode answer: the statement, handed back to run elsewhere.

    Recognised by shape (mode SQL, a statement, no rows), so an ``aiq.query``
    that one day executes SQL itself returns rows and is passed through as is.
    """
    return (isinstance(doc, dict) and doc.get("mode") == "SQL"
            and isinstance(doc.get("statement"), str) and "rows" not in doc)


class Handler(BaseHTTPRequestHandler):
    """JSON-RPC over the POST half of streamable HTTP, one response per request."""

    protocol_version = "HTTP/1.1"
    upstream: Upstream | None = None
    exceptions: Exceptions | None = None
    embedder: QueryEmbedder | None = None

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[query-mcp] {fmt % args}", flush=True)

    def _send(self, code: int, payload: Any) -> None:
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _result(self, rid: Any, result: dict[str, Any]) -> None:
        self._send(200, {"jsonrpc": "2.0", "id": rid, "result": result})

    def _error(self, rid: Any, code: int, message: str) -> None:
        self._send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}})

    def do_GET(self) -> None:
        # The GET half of streamable HTTP opens a server-to-client event
        # stream. Nothing here ever pushes.
        self._send(405, {"error": "this server does not initiate messages"})

    def do_POST(self) -> None:
        try:
            n = int(self.headers.get("Content-Length") or 0)
            msg = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._error(None, -32700, "parse error")

        rid, method = msg.get("id"), msg.get("method")
        auth = self.headers.get("Authorization")
        up = self.upstream
        assert up is not None, "Handler.upstream is set by serve()"

        # A notification carries no id and gets no response body.
        if rid is None and method and method.startswith("notifications/"):
            return self._send(202, None)

        if method == "initialize":
            return self._result(rid, {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "p8-query", "version": "0.1.0"},
                "instructions": "Ask the knowledge base with query, in p8ql, and read the returned "
                                "plan to confirm the query was understood. To build memory from a "
                                "conversation, read_session then land_message_facts; to settle what "
                                "is waiting, claim_judgement then decide_judgement.",
            })

        if method == "ping":
            return self._result(rid, {})

        if method == "tools/list":
            # The person's own agent reads conversations and judges with these
            # (REM-1056); each is a pass-through to its SQL, as the caller.
            return self._result(rid, {"tools": [describe_query_tool(up, auth, self.exceptions),
                                                *memory_tools.describe()]})

        if method == "tools/call":
            params = msg.get("params") or {}
            if params.get("name") in memory_tools.TOOLS:
                args = params.get("arguments") or {}
                return self._result(rid, memory_tools.call(
                    up, params["name"], args if isinstance(args, dict) else {}, auth))
            if params.get("name") != "query":
                return self._error(rid, -32602, f"unknown tool: {params.get('name')!r}")
            started = time.monotonic()
            ctx = {k: v for k, v in self.headers.items() if k.lower().startswith("x-p8-")}
            q = (params.get("arguments") or {}).get("query")
            if not isinstance(q, str) or not q.strip():
                # A tool result, not a protocol error: the model wrote a bad
                # argument, which is an observation it can act on.
                return self._result(rid, {
                    "isError": True,
                    "content": [{"type": "text", "text": "query must be a non-empty string"}]})

            doc, err = up.rpc("query", {"p_query": q}, auth)
            if err is not None and err.get("status") == 400 and self.embedder is not None:
                # Only after aiq.query refused, so a query that needed no vector
                # pays nothing, and the plan -- not the error's wording -- says
                # whether a vector is what it lacked.
                try:
                    again = self.embedder.retry(up, q, auth)
                except Exception as e:  # the original refusal is still the answer
                    print(f"[query-mcp] embedding: {type(e).__name__}: {e}", flush=True)
                    again = None
                if again is not None:
                    doc, err = again
            if err is None and _is_unexecuted_sql(doc):
                # The statement the parser recognised, not the raw string, and
                # the caller's header: RLS, the read-only transaction and the
                # break-out guard all apply, and a refusal from any of them is
                # an HTTP error that falls through to the branch below.
                rows, err = up.rpc("sql_passthrough", {"p_statement": doc["statement"]}, auth)
                if err is None:
                    doc = {"mode": "SQL", "statement": doc["statement"], "rows": rows}
            if err is None and isinstance(doc, dict) and doc.get("mode") == "SEMANTIC":
                try:
                    doc = hydrate_semantic(up, doc, auth)
                except Exception as e:  # the ids are still the answer
                    print(f"[query-mcp] semantic text: {type(e).__name__}: {e}", flush=True)
            if err is None and isinstance(doc, dict) and doc.get("error"):
                # aiq.query reports some failures at HTTP 200, as an `error`
                # field beside `rows: []` (GRAPH on a key that resolves to
                # nothing, or to several nodes). Returned as a success that
                # reads as "nothing is related", and the model cannot tell it
                # asked the wrong question. The whole envelope goes back, so
                # `did_you_mean` and `candidates` reach the model with it.
                err = {"kind": "tool_error", "body": doc}
            sx = self.exceptions
            question = (params.get("arguments") or {}).get("question")
            question = question if isinstance(question, str) else None

            def ms() -> int:
                return int((time.monotonic() - started) * 1000)

            if err:
                if sx is not None:
                    sx.record(q, doc, authorization=auth, question=question, headers=ctx, latency_ms=ms(),
                              error=str(err.get("status") or err["kind"]))
                return self._result(rid, {
                    "isError": True,
                    "_meta": {"errorKind": err["kind"]},
                    "content": [{"type": "text", "text": json.dumps(err)}]})
            if sx is not None and sx.on and isinstance(doc, dict):
                source = ((doc.get("plan") or {}).get("source")
                          if isinstance(doc.get("plan"), dict) else None)
                caps = sx.capabilities(up, auth, source)
                total = None
                if "sql" in caps:
                    try:
                        total = count_matches(up, doc, auth)
                    except Exception as e:  # a probe that fails says nothing
                        print(f"[query-mcp] count probe: {type(e).__name__}: {e}", flush=True)
                checked = sx.inspect(doc, question, caps, sx.relation(auth, source), total)
                full = checked["report"]
                # The refusal reads the full report: a blended question is
                # refused every time it is asked, not only the first.
                refused = bool(sx.mode == "strict" and full is not None and full.errors)
                report = sx.novel(full, next(
                    (v for k, v in ctx.items() if k.lower() == "x-p8-session-id"), None))
                sx.record(q, doc, authorization=auth, question=question, headers=ctx, report=full,
                          judge_error=checked["error"], shown=sx.shows, refused=refused,
                          shown_codes=sorted(report.codes) if (sx.shows and report) else [],
                          latency_ms=ms())
                if refused:
                    report = full
                if not sx.shows:
                    return self._result(rid, {
                        "content": [{"type": "text", "text": json.dumps(doc)}],
                        "structuredContent": doc})
                block = (report.to_dict() if report is not None
                         else {"raised": [], "receipt": {"ran": False, "error": checked["error"]}})
                prompt = report.to_prompt(show=6) if report is not None else ""
                if refused:
                    # The rows are withheld, not lost: asking again as the
                    # exceptions say returns them.
                    return self._result(rid, {
                        "isError": True,
                        "_meta": {"errorKind": "semantic_exception"},
                        "content": [{"type": "text", "text": prompt}],
                        "structuredContent": {"semantic_exceptions": block}})
                doc = {**doc, "semantic_exceptions": block}
                content = [{"type": "text", "text": json.dumps(doc)}]
                if prompt:
                    content.append({"type": "text", "text": prompt})
                return self._result(rid, {"content": content, "structuredContent": doc})
            if sx is not None:
                sx.record(q, doc, authorization=auth, question=question, headers=ctx, latency_ms=ms())
            return self._result(rid, {
                "content": [{"type": "text", "text": json.dumps(doc)}],
                # The half a citation-extracting runtime reads (brief §5.3): the
                # rows this query returned, not a restatement of them.
                "structuredContent": doc,
            })

        return self._error(rid, -32601, f"unknown method: {method!r}")


def build_server(host: str, port: int, postgrest: str,
                 exceptions: Exceptions | None = None,
                 embedder: QueryEmbedder | None = None) -> ThreadingHTTPServer:
    """A server bound and ready to ``serve_forever``; ``port=0`` picks a free one."""
    up, sx = Upstream(postgrest), exceptions or Exceptions()
    if isinstance(sx.log, PercolateLog) and sx.log.upstream is None:
        sx.log.upstream = up
    handler = type("QueryHandler", (Handler,), {"upstream": up, "exceptions": sx,
                                                "embedder": embedder or QueryEmbedder()})
    return ThreadingHTTPServer((host, port), handler)
