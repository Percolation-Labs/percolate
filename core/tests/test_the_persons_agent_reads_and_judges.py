"""The person's own agent reads conversations and judges, with no second model (REM-1056).

The query MCP server offers a connected agent six more tools: read a session
and land what it learned (agentic.session_messages, agentic.land_message_facts),
and list, claim, decide and release queued judgements (aiq.list_judgements,
aiq.claim_judgement, aiq.complete_judgement, aiq.release_judgement). Each is a
pass-through to its SQL as the caller. What must hold:

1. every tool reaches its function in its schema, with the arguments named as
   the SQL names them;
2. identity is the caller's: the MCP request's Authorization reaches PostgREST
   verbatim, so row policy decides, as in test_query_mcp;
3. a decision is always the agent's tier: the agent cannot pass itself off as
   a person or a configured model;
4. a refusal from the database reaches the agent as isError with the
   database's message, and a missing argument never reaches the database;
5. no model is involved: OPENAI_API_KEY and friends are unset throughout.

Driven through the runtime's own McpProvider, the client an agent uses, against
a stdlib fake of PostgREST that records what it was sent.

Run: python -m unittest discover -s tests -p test_the_persons_agent_reads_and_judges.py
"""

from __future__ import annotations

import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from percolate_core.agentic.contracts import CanonicalTool, ToolInvocation, ToolServer
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.tools.auth import caller_credentials
from percolate_core.agentic.tools.mcp import McpProvider
from percolate_core.query.mcp import build_server

BEARER = "Bearer the-persons-own-token"
SESSION = "01a10000-0000-0000-0000-000000000001"
MESSAGE = "01a10000-0000-0000-0000-000000000002"
JUDGEMENT = "01a10000-0000-0000-0000-000000000003"
NODE = "01a10000-0000-0000-0000-000000000004"
GRAPH = {"nodes": [{"k": "person", "n": "Maya Okafor"}, {"k": "place", "n": "Lisbon"}],
         "edges": [{"s": 0, "t": 1, "r": "lives_in"}]}
LAPSED = {"code": "42501", "details": None, "hint": "claim it again",
          "message": "complete_judgement: your claim on this item has lapsed"}

# (MCP tool, its arguments) -> (PostgREST schema, function, the body it must send)
CASES = [
    ("read_session", {"session_id": SESSION}, "agentic", "session_messages", {"p_session": SESSION}),
    ("land_message_facts", {"message_id": MESSAGE, "graph": GRAPH},
     "agentic", "land_message_facts", {"p_message_id": MESSAGE, "p_graph": GRAPH}),
    ("list_judgements", {}, "aiq", "list_judgements", {"p_status": "open", "p_limit": 50}),
    ("claim_judgement", {"id": JUDGEMENT}, "aiq", "claim_judgement", {"p_id": JUDGEMENT, "p_kinds": None}),
    ("decide_judgement", {"id": JUDGEMENT, "verdict": {"decision": "bind", "target": NODE},
                          "reason": "Same harbourmaster, same port, same years."},
     "aiq", "complete_judgement",
     {"p_id": JUDGEMENT, "p_verdict": {"decision": "bind", "target": NODE},
      "p_reason": "Same harbourmaster, same port, same years.", "p_tier": "agent"}),
    ("release_judgement", {"id": JUDGEMENT}, "aiq", "release_judgement", {"p_id": JUDGEMENT}),
]


class FakePostgrest:
    """Answers any /rpc/<fn>, recording each request; `refuse` maps a function to a (status, body)."""

    def __init__(self, refuse: dict | None = None):
        self.seen: list[dict] = []
        outer, refuse = self, refuse or {}

        class H(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fn = self.path.removeprefix("/rpc/")
                outer.seen.append({"fn": fn, "headers": dict(self.headers), "body": body})
                code, payload = refuse.get(fn, (200, {"ok": True, "fn": fn}))
                if fn == "query":  # the SCHEMA read behind the query tool's description
                    code, payload = 200, {"schema": {"doc": {"declared": {"modes": []}}}}
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

    def calls(self) -> list[dict]:
        return [s for s in self.seen if s["fn"] != "query"]


NO_MODEL = {k: "" for k in ("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "LLM_API_KEY", "OPENAI_BASE_URL")}


class ThePersonsAgentReadsAndJudges(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        env = patch.dict(os.environ, NO_MODEL)
        env.start()
        self.addCleanup(env.stop)

    def start(self, refuse: dict | None = None):
        pg = FakePostgrest(refuse)
        self.addCleanup(pg.close)
        mcp = build_server("127.0.0.1", 0, pg.url)
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        return pg, ToolServer(name="p8-query", kind="mcp", url=f"http://127.0.0.1:{mcp.server_address[1]}")

    async def call(self, server, name, arguments):
        tool = CanonicalTool(name=name, target=InvocationTarget(tool_name=name))
        with caller_credentials(BEARER, (server.url,)):
            return await McpProvider().invoke(server, tool, ToolInvocation(call_id="c1", tool_name=name,
                                                                           arguments=arguments))

    async def test_the_agent_is_offered_the_six_tools(self):
        _pg, server = self.start()
        names = [t.name for t in await McpProvider().list_tools(server)]
        self.assertEqual(names[1:], [c[0] for c in CASES])

    async def test_each_tool_reaches_its_sql_as_the_caller(self):
        for name, args, profile, fn, body in CASES:
            with self.subTest(tool=name):
                pg, server = self.start()
                result = await self.call(server, name, args)
                self.assertFalse(result.is_error, result)
                (seen,) = pg.calls()
                self.assertEqual(seen["fn"], fn)
                self.assertEqual(seen["body"], body)
                self.assertEqual(seen["headers"].get("Content-Profile"), profile)
                self.assertEqual(seen["headers"].get("Authorization"), BEARER)

    async def test_a_decision_is_always_the_agents(self):
        pg, server = self.start()
        await self.call(server, "decide_judgement",
                        {"id": JUDGEMENT, "verdict": {"decision": "none"}, "reason": "unsure", "tier": "human"})
        self.assertEqual(pg.calls()[0]["body"]["p_tier"], "agent")

    async def test_a_refusal_reaches_the_agent_with_the_databases_words(self):
        pg, server = self.start(refuse={"complete_judgement": (403, LAPSED)})
        result = await self.call(server, "decide_judgement",
                                 {"id": JUDGEMENT, "verdict": {"decision": "none"}, "reason": "unsure"})
        self.assertTrue(result.is_error)
        self.assertIn("your claim on this item has lapsed", json.dumps(result.model_dump(mode="json")))

    async def test_a_missing_argument_never_reaches_the_database(self):
        pg, server = self.start()
        result = await self.call(server, "land_message_facts", {"graph": GRAPH})
        self.assertTrue(result.is_error)
        self.assertEqual(pg.calls(), [])


if __name__ == "__main__":
    unittest.main()
