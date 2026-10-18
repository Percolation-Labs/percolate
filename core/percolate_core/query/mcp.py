"""The query tool server: one MCP tool, ``query``, over the p8ql dialect.

    percolate query mcp --port 8090 --postgrest http://postgrest:3000

Ported from p8-subsystems ``specs/agentic/reference/query_mcp.py``, which the
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
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

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

    def rpc(self, fn: str, payload: dict[str, Any], authorization: str | None = None):
        """``(document, None)`` on success, ``(None, error)`` otherwise."""
        req = urllib.request.Request(
            f"{self.base}/rpc/{fn}",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={
                "Content-Type": "application/json",
                # aiq is not PostgREST's default schema, so every call names it.
                "Accept-Profile": "aiq",
                "Content-Profile": "aiq",
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
        if log is None and os.environ.get("P8_QUERY_LOG"):
            from ..semantic_exceptions.log import JsonlLog
            log = JsonlLog(os.environ["P8_QUERY_LOG"])
        self.log = log
        # What each session has already been shown (Report.novel). In use, a
        # warning repeated on every query was skipped with the rest of the block
        # by the third; the server is the only place that sees a session's
        # queries in order. Bounded: the oldest sessions are forgotten.
        self._seen: dict[str, set] = {}

    @property
    def on(self) -> bool:
        """The exceptions are computed (shadow, on, strict)."""
        return self.mode != "off"

    @property
    def shows(self) -> bool:
        """The model reads them (on, strict)."""
        return self.mode in ("on", "strict")

    def novel(self, report: Any, session: str | None) -> Any:
        """The report as this session has not yet seen it; unchanged without a session."""
        if report is None or not session:
            return report
        seen = self._seen.pop(session, set())
        self._seen[session] = seen          # most recent last
        while len(self._seen) > 10_000:
            self._seen.pop(next(iter(self._seen)))
        return report.novel(seen)

    def record(self, query: str, doc: Any, **kw: Any) -> None:
        """Append one event. A log that fails does not fail the query."""
        if self.log is None:
            return
        from ..semantic_exceptions.log import event_of
        try:
            self.log.append(event_of(query, doc, exceptions_mode=self.mode, **kw))
        except Exception as e:
            print(f"[query-mcp] query log: {type(e).__name__}: {e}", flush=True)

    def _jev(self):
        if self._jev_factory is not None:
            return self._jev_factory()
        from ..decide import Jev
        return Jev()

    def inspect(self, doc: Any, question: str | None) -> dict:
        """``{"report": Report | None, "error": str | None}``. A judge that fails
        does not fail the query: the receipt says it did not run, and why."""
        from ..semantic_exceptions import SemanticExceptions
        from ..semantic_exceptions.query import inspect

        async def run():
            jev = self._jev()
            try:
                return await inspect(SemanticExceptions(jev, store=self.store), doc, question,
                                     values_top=self.values_top)
            finally:
                close = getattr(jev, "aclose", None)
                if close is not None:
                    await close()
        try:
            return {"report": asyncio.run(run()), "error": None}
        except Exception as e:  # the rows are still the answer
            return {"report": None, "error": f"{type(e).__name__}: {e}"[:300]}


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
                "instructions": "One tool. Ask the knowledge base in p8ql; read the "
                                "returned plan to confirm the query was understood.",
            })

        if method == "ping":
            return self._result(rid, {})

        if method == "tools/list":
            return self._result(rid, {"tools": [describe_query_tool(up, auth, self.exceptions)]})

        if method == "tools/call":
            params = msg.get("params") or {}
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
            if err is None and _is_unexecuted_sql(doc):
                # The statement the parser recognised, not the raw string, and
                # the caller's header: RLS, the read-only transaction and the
                # break-out guard all apply, and a refusal from any of them is
                # an HTTP error that falls through to the branch below.
                rows, err = up.rpc("sql_passthrough", {"p_statement": doc["statement"]}, auth)
                if err is None:
                    doc = {"mode": "SQL", "statement": doc["statement"], "rows": rows}
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
                    sx.record(q, doc, question=question, headers=ctx, latency_ms=ms(),
                              error=str(err.get("status") or err["kind"]))
                return self._result(rid, {
                    "isError": True,
                    "_meta": {"errorKind": err["kind"]},
                    "content": [{"type": "text", "text": json.dumps(err)}]})
            if sx is not None and sx.on and isinstance(doc, dict):
                checked = sx.inspect(doc, question)
                full = checked["report"]
                # The refusal reads the full report: a blended question is
                # refused every time it is asked, not only the first.
                refused = bool(sx.mode == "strict" and full is not None and full.errors)
                report = sx.novel(full, next(
                    (v for k, v in ctx.items() if k.lower() == "x-p8-session-id"), None))
                sx.record(q, doc, question=question, headers=ctx, report=full,
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
                sx.record(q, doc, question=question, headers=ctx, latency_ms=ms())
            return self._result(rid, {
                "content": [{"type": "text", "text": json.dumps(doc)}],
                # The half a citation-extracting runtime reads (brief §5.3): the
                # rows this query returned, not a restatement of them.
                "structuredContent": doc,
            })

        return self._error(rid, -32601, f"unknown method: {method!r}")


def build_server(host: str, port: int, postgrest: str,
                 exceptions: Exceptions | None = None) -> ThreadingHTTPServer:
    """A server bound and ready to ``serve_forever``; ``port=0`` picks a free one."""
    handler = type("QueryHandler", (Handler,), {"upstream": Upstream(postgrest),
                                                "exceptions": exceptions or Exceptions()})
    return ThreadingHTTPServer((host, port), handler)
