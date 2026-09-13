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
    Retrieval, ranking and query building live in SQL.

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
"""

from __future__ import annotations

import json
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


def describe_query_tool(up: Upstream, authorization: str | None) -> dict[str, Any]:
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
    return {
        "name": "query",
        "title": "Query the Percolate knowledge base",
        "description": preamble + "\n" + detail,
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "One p8ql statement. See the modes above.",
                }
            },
            "required": ["query"],
            "additionalProperties": False,
        },
    }


class Handler(BaseHTTPRequestHandler):
    """JSON-RPC over the POST half of streamable HTTP, one response per request."""

    protocol_version = "HTTP/1.1"
    upstream: Upstream | None = None

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
            return self._result(rid, {"tools": [describe_query_tool(up, auth)]})

        if method == "tools/call":
            params = msg.get("params") or {}
            if params.get("name") != "query":
                return self._error(rid, -32602, f"unknown tool: {params.get('name')!r}")
            q = (params.get("arguments") or {}).get("query")
            if not isinstance(q, str) or not q.strip():
                # A tool result, not a protocol error: the model wrote a bad
                # argument, which is an observation it can act on.
                return self._result(rid, {
                    "isError": True,
                    "content": [{"type": "text", "text": "query must be a non-empty string"}]})

            doc, err = up.rpc("query", {"p_query": q}, auth)
            if err:
                return self._result(rid, {
                    "isError": True,
                    "_meta": {"errorKind": err["kind"]},
                    "content": [{"type": "text", "text": json.dumps(err)}]})
            return self._result(rid, {
                "content": [{"type": "text", "text": json.dumps(doc)}],
                # The half a citation-extracting runtime reads (brief §5.3): the
                # rows this query returned, not a restatement of them.
                "structuredContent": doc,
            })

        return self._error(rid, -32601, f"unknown method: {method!r}")


def build_server(host: str, port: int, postgrest: str) -> ThreadingHTTPServer:
    """A server bound and ready to ``serve_forever``; ``port=0`` picks a free one."""
    handler = type("QueryHandler", (Handler,), {"upstream": Upstream(postgrest)})
    return ThreadingHTTPServer((host, port), handler)
