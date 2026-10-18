"""Semantic exceptions on the query tool: off by default, typed when on, a refusal when strict.

The ``query`` MCP tool is the common path every agent's p8ql takes, so this is
where the store's reasoner reaches every caller. Driven through the runtime's
own ``McpProvider`` against the stdlib PostgREST fake of test_query_mcp.py, with
a stub Jev that answers from a table and records what it was asked.

What must hold:

1. off changes nothing -- no ``question`` argument, no extra field;
2. on, the tool takes a ``question``, and every answer carries the typed
   exceptions and a receipt of what was checked, beside the rows, with the
   prompt appended for the model;
3. without a ``question``, a text mode is judged on the string it searched;
4. strict withholds the rows when an error-severity kind is raised;
5. a judge that fails does not fail the query, and the receipt says it did not run.

Run: python -m unittest discover -s tests -p test_query_semantic_exceptions.py
"""

from __future__ import annotations

import threading
import unittest

from percolate_core.agentic.contracts import CanonicalTool, ToolInvocation, ToolServer
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.tools.mcp import McpProvider
from percolate_core.query.mcp import Exceptions, build_server
from percolate_core.semantic_exceptions.query import hits_of, question_of

from test_query_mcp import FakePostgrest

SEARCH = 'SEARCH "entries that never mention Renfield" FROM diary'
SEARCH_DOC = {"mode": "SEARCH",
              "plan": {"mode": "SEARCH", "arg": "entries that never mention Renfield",
                       "source": "diary", "limit": 10},
              "rows": [{"chunk_id": "c1", "content": "4 September. Patient still better.",
                        "rrf_score": 0.03}]}


class Answer:
    def __init__(self, p):
        self.p = p


class Result(dict):
    model, input_tokens = "jev-stub", 7


class StubJev:
    def __init__(self, table):
        self.table, self.asked = table, []

    async def ask(self, state, questions):
        self.asked.append(state)
        out = Result()
        for q in questions:
            out[q] = Answer(self.table.get(q, 0.0))
        return out


class Broken:
    async def ask(self, state, questions):
        raise RuntimeError("Jev answered 429")


class QuerySemanticExceptions(unittest.IsolatedAsyncioTestCase):
    def start(self, mode: str, jev=None):
        pg = FakePostgrest(answers={("query", SEARCH): (200, SEARCH_DOC)})
        self.addCleanup(pg.close)
        sx = Exceptions(mode, jev_factory=(lambda: jev) if jev is not None else None)
        mcp = build_server("127.0.0.1", 0, pg.url, exceptions=sx)
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        return ToolServer(name="q", kind="mcp", url=f"http://127.0.0.1:{mcp.server_address[1]}")

    async def call(self, server, arguments):
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query"))
        return await McpProvider().invoke(
            server, tool, ToolInvocation(call_id="c1", tool_name="query", arguments=arguments))

    async def test_off_changes_nothing(self):
        server = self.start("off")
        [tool] = await McpProvider().list_tools(server)
        self.assertNotIn("question", tool.input_schema["properties"])
        result = await self.call(server, {"query": SEARCH})
        self.assertEqual(result.content, SEARCH_DOC)

    async def test_on_the_answer_carries_typed_exceptions_and_a_receipt(self):
        jev = StubJev({"NEGATION": 0.99})
        server = self.start("on", jev)
        [tool] = await McpProvider().list_tools(server)
        self.assertIn("question", tool.input_schema["properties"])
        self.assertIn("SEMANTIC EXCEPTIONS", tool.description)
        result = await self.call(server, {"query": SEARCH,
                                          "question": "Which entries never mention Renfield?"})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content["rows"], SEARCH_DOC["rows"])
        block = result.content["semantic_exceptions"]
        self.assertEqual([r["code"] for r in block["raised"]], ["NEGATION"])
        self.assertEqual(block["raised"][0]["severity"], "error")
        self.assertEqual(block["receipt"]["stages"], ["question", "result"])
        self.assertGreater(block["receipt"]["checked"], 20)
        self.assertEqual(block["receipt"]["model"], "jev-stub")
        self.assertEqual(jev.asked[0]["question"], "Which entries never mention Renfield?")

    async def test_the_store_description_reaches_the_judge(self):
        jev = StubJev({})
        pg = FakePostgrest(answers={("query", SEARCH): (200, SEARCH_DOC)})
        self.addCleanup(pg.close)
        mcp = build_server("127.0.0.1", 0, pg.url,
                           exceptions=Exceptions("on", jev_factory=lambda: jev, store="Dracula"))
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        await self.call(ToolServer(name="q", kind="mcp",
                                   url=f"http://127.0.0.1:{mcp.server_address[1]}"), {"query": SEARCH})
        self.assertEqual(jev.asked[0]["store"], "Dracula")

    async def test_nothing_raised_still_proves_it_looked(self):
        server = self.start("on", StubJev({}))
        result = await self.call(server, {"query": SEARCH, "question": "What did Seward note?"})
        block = result.content["semantic_exceptions"]
        self.assertEqual(block["raised"], [])
        self.assertEqual(block["receipt"]["jev_requests"], 1)
        self.assertGreater(block["receipt"]["checked"], 20)

    async def test_without_a_question_the_searched_string_is_judged(self):
        jev = StubJev({})
        await self.call(self.start("on", jev), {"query": SEARCH})
        self.assertEqual(jev.asked[0]["question"], "entries that never mention Renfield")

    async def test_strict_withholds_the_rows_on_an_error(self):
        server = self.start("strict", StubJev({"NEGATION": 0.99}))
        result = await self.call(server, {"query": SEARCH})
        self.assertTrue(result.is_error)
        # The runtime's vocabulary has two failures, and this is "the tool ran
        # and said no": a tool_error, whose text is the prompt.
        self.assertEqual(result.error_kind, "tool_error")
        self.assertIn("NEGATION", str(result.content))
        self.assertNotIn("Patient still better", str(result.content))

    async def test_strict_lets_a_warning_through(self):
        server = self.start("strict", StubJev({"CAUSAL_WHY": 0.99}))
        result = await self.call(server, {"query": SEARCH, "question": "Why did Renfield change?"})
        self.assertFalse(result.is_error)
        self.assertEqual([r["code"] for r in result.content["semantic_exceptions"]["raised"]],
                         ["CAUSAL_WHY"])

    async def test_a_failed_judge_returns_the_rows_and_says_it_did_not_run(self):
        result = await self.call(self.start("strict", Broken()), {"query": SEARCH})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content["rows"], SEARCH_DOC["rows"])
        receipt = result.content["semantic_exceptions"]["receipt"]
        self.assertFalse(receipt["ran"])
        self.assertIn("429", receipt["error"])


class Adapter(unittest.TestCase):
    def test_a_cosine_distance_is_a_score_and_a_rank_fusion_is_not(self):
        sem = {"mode": "SEMANTIC", "plan": {"mode": "SEMANTIC", "arg": "x"},
               "rows": [{"chunk_id": "a", "distance": 0.25}]}
        self.assertEqual(hits_of(sem), [{"id": "a", "score": 0.75}])
        self.assertNotIn("score", hits_of(SEARCH_DOC)[0])
        self.assertEqual(hits_of(SEARCH_DOC)[0]["content"], "4 September. Patient still better.")

    def test_only_text_modes_lend_their_argument_as_the_question(self):
        self.assertEqual(question_of(SEARCH_DOC, None), "entries that never mention Renfield")
        self.assertIsNone(question_of({"mode": "LOOKUP", "plan": {"mode": "LOOKUP", "arg": "x"}}, None))
        self.assertEqual(question_of(SEARCH_DOC, "mine"), "mine")


if __name__ == "__main__":
    unittest.main()
