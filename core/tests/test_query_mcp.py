"""The query tool server keeps the three properties it was ported for.

`percolate query mcp` is percolate's `specs/agentic/reference/query_mcp.py`
made a command, so a get-percolate install can run it. What it must keep:

1. no tool logic -- the call's query reaches `aiq.query` unchanged, and what
   came back is the result;
2. the description is fetched -- `tools/list` is built from `SCHEMA "p8ql"`,
   so a mode the database declares appears and nothing is invented when the
   read fails;
3. identity is the caller's -- the MCP request's `Authorization` reaches
   PostgREST verbatim, and a request without one reaches it without one.

And the two the port shipped without, which made the sample agent call `query`
fifty times and never answer:

4. SQL mode is executed -- `aiq.query` hands an SQL statement back unexecuted,
   and the description promises it runs "through the SECURITY INVOKER
   passthrough", so the server makes that one hop, as the caller;
5. every failure is an error -- an HTTP refusal and an `error` envelope that
   `aiq.query` returns at 200 both reach the model as `isError`, with the
   database's own message.

Driven through the runtime's own `McpProvider`, the client an agent uses, so
the check is that an agent can list and call it, not that it answers a
hand-written JSON-RPC body. PostgREST is a stdlib fake that records what it was
sent.

Run: python -m unittest discover -s tests -p test_query_mcp.py
"""

from __future__ import annotations

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from percolate_core.agentic.contracts import CanonicalTool, ToolInvocation, ToolServer
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.tools.auth import caller_credentials
from percolate_core.agentic.tools.mcp import McpProvider
from percolate_core.query.mcp import build_server

SCHEMA_DOC = {"schema": {"doc": {"declared": {"modes": [{"mode": "LOOKUP"}, {"mode": "FUZZY"}]},
                                 "grammar": "LOOKUP \"name\""}}}
ROWS = {"plan": {"mode": "LOOKUP"}, "rows": [{"key": "vessel:meridian-dawn"}]}
BEARER = "Bearer caller-token-for-this-test"

# The shapes below are what the gprc stack's PostgREST returned (extension
# 0.2.1), copied rather than imagined.
STATEMENT = "select name from harbour.vessels"
SQL_ENVELOPE = {"mode": "SQL", "statement": STATEMENT,
                "note": "execute via the SECURITY INVOKER read-only passthrough, not here"}
SQL_ROWS = [{"name": "Meridian Dawn"}, {"name": "Aurora Kestrel"}]
GRAPH_MISS = {"mode": "GRAPH", "plan": {"ok": True, "mode": "GRAPH", "arg": "vessels"},
              "rows": [], "error": "no node matches key 'vessels'",
              "did_you_mean": [{"key": "vessel", "entity_type": "type", "score": 0.6}]}
NOT_REGISTERED = {"code": "P0001", "details": None, "hint": None,
                  "message": "lexical source vessels not registered -- "
                             "SCHEMA \"graph\" lists the registered ones"}
BREAK_OUT = {"code": "42601", "details": None,
             "hint": "a SET or a second statement would change whose rows are read; "
                     "write the read as one query",
             "message": "the SQL passthrough runs a single read query, and this is not "
                        "(syntax error at or near \")\")"}


class FakePostgrest:
    """Answers `/rpc/query` and `/rpc/sql_passthrough`, recording every request.

    `answers` maps `(function, argument)` to the `(status, payload)` PostgREST
    gives for it, because an SQL statement reaches both functions as the same
    string; anything unmapped gets the ordinary success.
    """

    def __init__(self, status: int = 200, answers: dict | None = None):
        self.seen: list[dict] = []
        outer = self
        answers = answers or {}

        class H(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.seen.append({"path": self.path, "headers": dict(self.headers), "body": body})
                key = (self.path.removeprefix("/rpc/"), body.get("p_query", body.get("p_statement")))
                if status != 200:
                    code, payload = status, {"message": "permission denied for function query"}
                elif key in answers:
                    code, payload = answers[key]
                elif self.path == "/rpc/sql_passthrough":
                    code, payload = 200, SQL_ROWS
                else:
                    code, payload = 200, SCHEMA_DOC if key[1] == 'SCHEMA "p8ql"' else ROWS
                raw = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def queries(self) -> list[dict]:
        """The requests that were a call, not the SCHEMA read behind tools/list.

        The MCP client lists tools again after a call, so the last request is
        not reliably the call's own.
        """
        return [s for s in self.seen if s["body"].get("p_query") != 'SCHEMA "p8ql"']


class QueryMcpTest(unittest.IsolatedAsyncioTestCase):
    def start(self, postgrest_url: str):
        mcp = build_server("127.0.0.1", 0, postgrest_url)
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        url = f"http://127.0.0.1:{mcp.server_address[1]}"
        return ToolServer(name="harbour-query", kind="mcp", url=url)

    def pg(self, status: int = 200, answers: dict | None = None) -> FakePostgrest:
        fake = FakePostgrest(status, answers)
        self.addCleanup(fake.close)
        return fake

    async def call(self, server: ToolServer, arguments: dict, *, authorized: bool = True):
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query"))
        call = ToolInvocation(call_id="c1", tool_name="query", arguments=arguments)
        if not authorized:
            return await McpProvider().invoke(server, tool, call)
        # How the runtime sends a caller's bearer: only to an origin on
        # P8_TOOL_AUTH_ORIGINS, which here names this server.
        with caller_credentials(BEARER, (server.url,)):
            return await McpProvider().invoke(server, tool, call)

    async def test_an_agent_lists_the_query_tool_described_by_the_live_schema(self):
        pg = self.pg()
        server = self.start(pg.url)
        tools = await McpProvider().list_tools(server)
        # query first; the six memory tools (REM-1056) follow, tested in
        # test_the_persons_agent_reads_and_judges.py.
        self.assertEqual([t.name for t in tools][:1], ["query"])
        self.assertEqual(len(tools), 7)
        self.assertIn("every retrieval mode: LOOKUP, FUZZY.", tools[0].description)
        self.assertIn('LOOKUP \\"name\\"', tools[0].description)
        self.assertEqual(tools[0].input_schema["required"], ["query"])
        self.assertEqual(pg.seen[0]["body"], {"p_query": 'SCHEMA "p8ql"'})

    async def test_a_failed_schema_read_lists_the_tool_and_names_no_modes(self):
        server = self.start(self.pg(status=401).url)
        tools = await McpProvider().list_tools(server)
        # query first; the six memory tools (REM-1056) follow, tested in
        # test_the_persons_agent_reads_and_judges.py.
        self.assertEqual([t.name for t in tools][:1], ["query"])
        self.assertEqual(len(tools), 7)
        self.assertIn("see the grammar below", tools[0].description)
        self.assertIn("could not be read: 401", tools[0].description)

    async def test_the_query_is_forwarded_unchanged_and_the_rows_come_back(self):
        pg = self.pg()
        result = await self.call(self.start(pg.url), {"query": 'LOOKUP "meridian dawn"'})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content, ROWS)
        [sent] = pg.queries()
        self.assertEqual(sent["path"], "/rpc/query")
        self.assertEqual(sent["body"], {"p_query": 'LOOKUP "meridian dawn"'})
        self.assertEqual(sent["headers"]["Content-Profile"], "aiq")

    async def test_the_callers_authorization_reaches_postgrest_verbatim(self):
        pg = self.pg()
        await self.call(self.start(pg.url), {"query": 'LOOKUP "x"'})
        [sent] = pg.queries()
        self.assertEqual(sent["headers"]["Authorization"], BEARER)

    async def test_no_caller_bearer_means_postgrest_sees_none(self):
        pg = self.pg()
        await self.call(self.start(pg.url), {"query": 'LOOKUP "x"'}, authorized=False)
        [sent] = pg.queries()
        self.assertNotIn("Authorization", sent["headers"])

    async def test_a_refusal_is_a_tool_error_and_an_unreachable_postgrest_a_dispatch_error(self):
        refused = await self.call(self.start(self.pg(status=403).url), {"query": 'LOOKUP "x"'})
        self.assertTrue(refused.is_error)
        self.assertEqual(refused.error_kind, "tool_error")
        self.assertIn("permission denied", str(refused.content))

        unreachable = await self.call(self.start("http://127.0.0.1:9"), {"query": 'LOOKUP "x"'})
        self.assertTrue(unreachable.is_error)
        self.assertEqual(unreachable.error_kind, "dispatch_error")

    async def test_an_empty_query_is_refused_before_postgrest(self):
        pg = self.pg()
        result = await self.call(self.start(pg.url), {"query": "  "})
        self.assertTrue(result.is_error)
        self.assertEqual(pg.queries(), [])

    async def test_sql_mode_runs_through_the_passthrough_as_the_caller(self):
        # The loop: aiq.query answered an SQL statement with a note saying where
        # to run it, the server returned the note as a success, and the model
        # asked again. The statement the passthrough runs is the one the parser
        # recognised, and the bearer that reaches it is the caller's.
        pg = self.pg(answers={("query", STATEMENT): (200, SQL_ENVELOPE)})
        result = await self.call(self.start(pg.url), {"query": STATEMENT})
        self.assertFalse(result.is_error, result.content)
        self.assertEqual(result.content, {"mode": "SQL", "statement": STATEMENT, "rows": SQL_ROWS})
        [asked, ran] = pg.queries()
        self.assertEqual((asked["path"], asked["body"]), ("/rpc/query", {"p_query": STATEMENT}))
        self.assertEqual((ran["path"], ran["body"]), ("/rpc/sql_passthrough", {"p_statement": STATEMENT}))
        self.assertEqual(ran["headers"]["Authorization"], BEARER)
        self.assertEqual(ran["headers"]["Content-Profile"], "aiq")

    async def test_sql_mode_without_a_bearer_reaches_the_passthrough_without_one(self):
        pg = self.pg(answers={("query", STATEMENT): (200, SQL_ENVELOPE)})
        await self.call(self.start(pg.url), {"query": STATEMENT}, authorized=False)
        self.assertEqual([s["path"] for s in pg.queries()], ["/rpc/query", "/rpc/sql_passthrough"])
        self.assertTrue(all("Authorization" not in s["headers"] for s in pg.queries()))

    async def test_a_passthrough_refusal_is_a_tool_error_with_its_message(self):
        # p8 #163's break-out guard, as PostgREST returned it on gprc: aiq.query
        # recognises the string as SQL, the passthrough refuses to run it.
        breaks_out = "select 1) _p8_passthrough limit 1) t; set local role postgres; select * from (select 1"
        pg = self.pg(answers={
            ("query", breaks_out): (200, {**SQL_ENVELOPE, "statement": breaks_out}),
            ("sql_passthrough", breaks_out): (400, BREAK_OUT),
        })
        result = await self.call(self.start(pg.url), {"query": breaks_out})
        self.assertTrue(result.is_error)
        self.assertEqual(result.error_kind, "tool_error")
        self.assertIn("runs a single read query", str(result.content))

    async def test_an_error_envelope_at_200_is_a_tool_error_with_its_suggestions(self):
        # GRAPH answers a key that resolves to nothing with HTTP 200, `rows: []`
        # and an `error` field. Without isError that is "nothing is related".
        pg = self.pg(answers={("query", 'GRAPH "vessels"'): (200, GRAPH_MISS)})
        result = await self.call(self.start(pg.url), {"query": 'GRAPH "vessels"'})
        self.assertTrue(result.is_error, result.content)
        self.assertEqual(result.error_kind, "tool_error")
        self.assertIn("no node matches key 'vessels'", str(result.content))
        self.assertIn("did_you_mean", str(result.content))

    async def test_a_database_exception_is_a_tool_error_with_its_message(self):
        pg = self.pg(answers={("query", "TEXT \"x\" FROM vessels"): (400, NOT_REGISTERED)})
        result = await self.call(self.start(pg.url), {"query": "TEXT \"x\" FROM vessels"})
        self.assertTrue(result.is_error)
        self.assertEqual(result.error_kind, "tool_error")
        self.assertIn("lexical source vessels not registered", str(result.content))


class SampleLoadSyncsTheCatalogue(unittest.TestCase):
    """`percolate sample load` asks the runtime to sync what the plugin registered.

    A server registered with no catalogue fails the bound agent's first turn
    with `has no discovered tools`. The loader never fails on this, because the
    rows are already right; it prints what happened and the command to finish.
    """

    def runtime(self, status: int, payload: dict):
        seen: list[dict] = []

        class H(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                seen.append({"path": self.path, "auth": self.headers.get("Authorization")})
                raw = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_address[1]}", seen

    def test_it_syncs_with_the_token_and_names_the_tools(self):
        from percolate_core.core.samples import sync_tool_server

        url, seen = self.runtime(200, {"name": "harbour-query", "tools": ["query"]})
        line = sync_tool_server(url, "harbour-query", "tkn")
        self.assertEqual(line, "tool server harbour-query: synced, 1 tool(s): query")
        self.assertEqual(seen, [{"path": "/tools/harbour-query/sync", "auth": "Bearer tkn"}])

    def test_a_refusal_an_empty_catalogue_and_no_runtime_each_say_what_to_run(self):
        from percolate_core.core.samples import sync_tool_server

        refused, _ = self.runtime(502, {"detail": "Tool discovery failed (ConnectError)"})
        empty, _ = self.runtime(200, {"name": "harbour-query", "tools": []})
        for url, expected in ((refused, "answered 502"), (empty, "exposes no tools"),
                              ("http://127.0.0.1:9", "unreachable")):
            with self.subTest(expected=expected):
                line = sync_tool_server(url, "harbour-query", "tkn")
                self.assertIn(expected, line)
                self.assertIn(f"curl -X POST {url}/tools/harbour-query/sync", line)

    def test_no_token_sends_nothing(self):
        from percolate_core.core.samples import sync_tool_server

        url, seen = self.runtime(200, {"tools": ["query"]})
        self.assertIn("no token", sync_tool_server(url, "harbour-query", None))
        self.assertEqual(seen, [])


if __name__ == "__main__":
    unittest.main()
