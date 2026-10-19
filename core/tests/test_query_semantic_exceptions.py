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
5. a judge that fails does not fail the query, and the receipt says it did not run;
6. shadow computes the exceptions and shows the model nothing, so the two arms
   differ only in what is shown;
7. with a query log, every call -- in every mode, failed or not -- is one typed
   QueryEvent carrying the session and run, and a log that fails does not fail
   the query.

Run: python -m unittest discover -s tests -p test_query_semantic_exceptions.py
"""

from __future__ import annotations

import json
import threading
import unittest

from percolate_core.agentic.contracts import CanonicalTool, ToolInvocation, ToolServer
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.tools.auth import caller_credentials
from percolate_core.agentic.tools.mcp import McpProvider
from percolate_core.query.mcp import (Exceptions, PercolateLog, QueryEmbedder, actions_for,
                                      build_server, count_matches, describe_sources,
                                      hydrate_semantic)
from percolate_core.semantic_exceptions.log import (
    JsonlLog, QueryEvent, event_of, followups, stats_of)
from percolate_core.semantic_exceptions.query import hits_of, question_of

from test_query_mcp import FakePostgrest

SEARCH = 'SEARCH "entries that never mention Renfield" FROM diary'
# What SCHEMA "sql" FROM diary says to a caller who may read the source's relation.
SQL_READABLE = {"mode": "SCHEMA", "schema": {"doc": {"derived": {
    "relations": [{"schema": "sx", "name": "diary", "kind": "table"}], "relation_count": 1}}}}

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


class ListLog:
    def __init__(self):
        self.events: list[QueryEvent] = []

    def append(self, event):
        self.events.append(event)

    def __iter__(self):
        return iter(self.events)


class BrokenLog(ListLog):
    def append(self, event):
        raise OSError("disk full")


class QuerySemanticExceptions(unittest.IsolatedAsyncioTestCase):
    def start(self, mode: str, jev=None, log=None, status=200, sql=True):
        answers = {("query", SEARCH): (200, SEARCH_DOC)}
        if sql:
            answers[("query", 'SCHEMA "sql" FROM diary')] = (200, SQL_READABLE)
        pg = FakePostgrest(status=status, answers=answers)
        self.addCleanup(pg.close)
        sx = Exceptions(mode, jev_factory=(lambda: jev) if jev is not None else None, log=log)
        mcp = build_server("127.0.0.1", 0, pg.url, exceptions=sx)
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        return ToolServer(name="q", kind="mcp", url=f"http://127.0.0.1:{mcp.server_address[1]}")

    async def call(self, server, arguments, headers=None):
        tool = CanonicalTool(name="query", target=InvocationTarget(tool_name="query"))
        return await McpProvider().invoke(
            server, tool, ToolInvocation(call_id="c1", tool_name="query", arguments=arguments),
            headers=headers)

    async def test_off_changes_nothing(self):
        server = self.start("off")
        tool = (await McpProvider().list_tools(server))[0]   # query; the memory tools follow it (REM-1056)
        self.assertNotIn("question", tool.input_schema["properties"])
        result = await self.call(server, {"query": SEARCH})
        self.assertEqual(result.content, SEARCH_DOC)

    async def test_on_the_answer_carries_typed_exceptions_and_a_receipt(self):
        jev = StubJev({"NEGATION": 0.99})
        server = self.start("on", jev)
        tool = (await McpProvider().list_tools(server))[0]   # query; the memory tools follow it (REM-1056)
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

    async def test_without_sql_a_negation_is_a_limit_not_a_refusal(self):
        log = ListLog()
        server = self.start("strict", StubJev({"NEGATION": 0.99}), log, sql=False)
        result = await self.call(server, {"query": SEARCH})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content["rows"], SEARCH_DOC["rows"])
        [r] = result.content["semantic_exceptions"]["raised"]
        self.assertTrue(r["limit"])
        self.assertIsNone(r["action"])
        self.assertIn("may be incomplete", r["prompt"])
        self.assertFalse(log.events[0].refused)

    async def test_with_sql_the_negation_names_the_query_tools_own_move(self):
        result = await self.call(self.start("on", StubJev({"NEGATION": 0.99})), {"query": SEARCH})
        [r] = result.content["semantic_exceptions"]["raised"]
        self.assertNotIn("limit", r)
        # the source's own table, not a lookup command (run 2: `SCHEMA "sql"
        # FROM <source>` listed nothing and a user gave up on SQL)
        self.assertIn("SQL over sx.diary", r["action"])

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

    async def test_shadow_computes_them_and_shows_nothing(self):
        log = ListLog()
        server = self.start("shadow", StubJev({"NEGATION": 0.99}), log)
        tool = (await McpProvider().list_tools(server))[0]   # query; the memory tools follow it (REM-1056)
        self.assertIn("question", tool.input_schema["properties"])
        self.assertNotIn("SEMANTIC EXCEPTIONS", tool.description)
        result = await self.call(server, {"query": SEARCH})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content, SEARCH_DOC)
        [e] = log.events
        self.assertEqual((e.codes, e.shown, e.exceptions_mode), (["NEGATION"], False, "shadow"))

    async def test_a_session_is_shown_each_exception_once(self):
        log = ListLog()
        server = self.start("on", StubJev({"CONJUNCTION": 0.99}), log)
        with caller_credentials("Bearer t", (server.url,)):
            first = await self.call(server, {"query": SEARCH}, headers={"X-P8-Session-Id": "s"})
            again = await self.call(server, {"query": SEARCH}, headers={"X-P8-Session-Id": "s"})
            other = await self.call(server, {"query": SEARCH}, headers={"X-P8-Session-Id": "t"})
        codes = lambda r: [x["code"] for x in r.content["semantic_exceptions"]["raised"]]
        self.assertEqual((codes(first), codes(again), codes(other)),
                         (["CONJUNCTION"], [], ["CONJUNCTION"]))
        # The log keeps what was computed and says what was shown.
        self.assertEqual([(e.codes, e.shown_codes) for e in log.events],
                         [(["CONJUNCTION"], ["CONJUNCTION"]), (["CONJUNCTION"], []),
                          (["CONJUNCTION"], ["CONJUNCTION"])])

    async def test_strict_refuses_a_repeat_too(self):
        server = self.start("strict", StubJev({"NEGATION": 0.99}))
        with caller_credentials("Bearer t", (server.url,)):
            for _ in range(2):
                r = await self.call(server, {"query": SEARCH}, headers={"X-P8-Session-Id": "s"})
                self.assertTrue(r.is_error)
                self.assertIn("NEGATION", str(r.content))

    async def test_strict_records_the_refusal(self):
        log = ListLog()
        await self.call(self.start("strict", StubJev({"NEGATION": 0.99}), log), {"query": SEARCH})
        [e] = log.events
        self.assertTrue(e.shown and e.refused)

    async def test_every_call_is_one_event_with_its_session_and_run(self):
        log = ListLog()
        server = self.start("on", StubJev({}), log)
        # The runtime forwards X-P8-* only to an origin the operator bound, as it
        # would for the query server in a deployment.
        with caller_credentials("Bearer t", (server.url,)):
            await self.call(server, {"query": SEARCH, "question": "What did Seward note?"},
                            headers={"X-P8-Session-Id": "s1", "X-P8-Run-Id": "r1"})
        [e] = log.events
        self.assertEqual((e.session_id, e.run_id, e.question), ("s1", "r1", "What did Seward note?"))
        self.assertEqual((e.mode, e.source, e.limit), ("SEARCH", "diary", 10))
        self.assertEqual(e.stats["rows"], 1)
        self.assertTrue(e.receipt["ran"])
        self.assertGreater(e.receipt["checked"], 20)

    async def test_off_still_logs_without_a_judge(self):
        log = ListLog()
        await self.call(self.start("off", None, log), {"query": SEARCH})
        [e] = log.events
        self.assertEqual((e.exceptions_mode, e.raised, e.receipt), ("off", [], {}))

    async def test_a_failed_query_is_logged_with_its_error(self):
        log = ListLog()
        result = await self.call(self.start("on", StubJev({}), log, status=403), {"query": SEARCH})
        self.assertTrue(result.is_error)
        [e] = log.events
        self.assertEqual(e.error, "403")

    async def test_the_percolate_log_writes_a_row_as_the_caller(self):
        pg = FakePostgrest(answers={("query", SEARCH): (200, SEARCH_DOC)})
        self.addCleanup(pg.close)
        mcp = build_server("127.0.0.1", 0, pg.url,
                           exceptions=Exceptions("shadow", jev_factory=lambda: StubJev({}),
                                                 log=PercolateLog()))
        threading.Thread(target=mcp.serve_forever, daemon=True).start()
        self.addCleanup(mcp.server_close)
        self.addCleanup(mcp.shutdown)
        server = ToolServer(name="q", kind="mcp", url=f"http://127.0.0.1:{mcp.server_address[1]}")
        with caller_credentials("Bearer the-caller", (server.url,)):
            await self.call(server, {"query": SEARCH}, headers={"X-P8-Session-Id": "s"})
        [w] = [r for r in pg.seen if r["path"] == "/rpc/record_query"]
        self.assertEqual(w["headers"]["Content-Profile"], "content")
        self.assertEqual(w["headers"]["Authorization"], "Bearer the-caller")
        self.assertEqual((w["body"]["p_event"]["query"], w["body"]["p_event"]["session_id"]),
                         (SEARCH, "s"))

    async def test_a_failed_log_does_not_fail_the_query(self):
        result = await self.call(self.start("on", StubJev({}), BrokenLog()), {"query": SEARCH})
        self.assertFalse(result.is_error)
        self.assertEqual(result.content["rows"], SEARCH_DOC["rows"])


class Log(unittest.TestCase):
    def test_the_outcome_is_the_next_query_in_the_same_run(self):
        a = QueryEvent("q1", run_id="r", at=1)
        b = QueryEvent("q2", run_id="r", at=2)
        c = QueryEvent("q3", run_id="other", at=1.5)
        d = QueryEvent("q4", at=3)
        pairs = {e.query: (n.query if n else None) for e, n in followups([b, d, c, a])}
        self.assertEqual(pairs, {"q1": "q2", "q2": None, "q3": None, "q4": None})

    def test_a_session_pairs_when_there_is_no_run(self):
        a, b = QueryEvent("q1", session_id="s", at=1), QueryEvent("q2", session_id="s", at=2)
        self.assertEqual(followups([a, b])[0][1].query, "q2")

    def test_the_file_round_trips(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            log = JsonlLog(f"{d}/q.jsonl")
            log.append(event_of(SEARCH, SEARCH_DOC, headers={"X-P8-Session-Id": "s"}))
            [e] = list(log)
            self.assertEqual((e.query, e.session_id, e.mode), (SEARCH, "s", "SEARCH"))

    def test_stats_read_the_envelope(self):
        doc = {"rows": [{"distance": 0.2, "source": "a"}, {"distance": 0.5, "source": "b"}]}
        self.assertEqual(stats_of(doc), {"rows": 2, "empty": False, "distance_min": 0.2,
                                         "distance_max": 0.5, "sources": 2, "with_content": 0,
                                         "ids": []})
        self.assertEqual(stats_of(SEARCH_DOC)["ids"], ["c1"])
        self.assertTrue(stats_of({"rows": []})["empty"])


class FakeUpstream:
    """What QueryEmbedder asks the database: the plan, the model rows, the query."""

    def __init__(self, mode="SEARCH", provider="fastembed", in_process=True):
        self.mode, self.provider, self.in_process = mode, provider, in_process
        self.calls = []

    def rpc(self, fn, payload, authorization=None, profile="aiq"):
        self.calls.append((fn, payload, profile))
        if fn == "aiq_parse":
            return {"ok": True, "mode": self.mode, "arg": "who attacked Lucy", "model": None}, None
        if fn == "query" and "p_embedding" in payload:
            return {"mode": self.mode, "rows": [{"chunk_id": "c1"}]}, None
        return None, {"kind": "tool_error", "status": 400}

    def read(self, path, authorization=None, profile="aiq"):
        if path.startswith("embedding_models"):
            return [{"name": "bge-small-en-v1.5", "dim": 3, "provider": self.provider,
                     "endpoint": "BAAI/bge-small-en-v1.5"}], None
        return [{"provider": self.provider, "in_process": self.in_process}], None


class Probe(unittest.TestCase):
    """The capability probe resolves a source to its relation before asking."""

    class Up:
        def __init__(self, relations, table="sx.passages"):
            self.relations, self.table, self.asked = relations, table, []

        def read(self, path, authorization=None, profile="aiq"):
            return ([{"source_table": self.table}] if self.table else []), None

        def rpc(self, fn, payload, authorization=None, profile="aiq"):
            self.asked.append(payload["p_query"])
            return {"schema": {"doc": {"derived": {"relations": self.relations}}}}, None

    def test_a_source_is_asked_about_by_its_relation(self):
        up = self.Up([{"schema": "sx", "name": "passages"}])
        self.assertTrue(Exceptions._sql_readable(up, None, "dracula"))
        self.assertEqual(up.asked, ['SCHEMA "sql" FROM passages'])

    def test_a_relation_of_the_same_name_in_another_schema_is_not_it(self):
        self.assertFalse(Exceptions._sql_readable(
            self.Up([{"schema": "public", "name": "passages"}]), None, "dracula"))

    def test_nothing_readable_is_no_sql(self):
        self.assertFalse(Exceptions._sql_readable(self.Up([]), None, "dracula"))


class SemanticText(unittest.TestCase):
    ID = "1898b9fd-b962-5817-8f74-92196812463a"

    class Up:
        def __init__(self, table="sx.passages", col="content"):
            self.table, self.col, self.sql = table, col, []

        def read(self, path, authorization=None, profile="aiq"):
            return [{"source_table": self.table, "content_col": self.col}], None

        def rpc(self, fn, payload, authorization=None, profile="aiq"):
            self.sql.append(payload["p_statement"])
            return [{"id": SemanticText.ID, "content": "Listen to them"}], None

    def doc(self):
        return {"mode": "SEMANTIC", "plan": {"source": "dracula"},
                "rows": [{"chunk_id": self.ID, "distance": 0.2}]}

    def test_each_hit_comes_back_with_its_text(self):
        up = self.Up()
        out = hydrate_semantic(up, self.doc(), "Bearer t")
        self.assertEqual(out["rows"][0]["content"], "Listen to them")
        self.assertIn('from "sx"."passages"', up.sql[0])

    def test_a_registry_name_that_is_not_an_identifier_is_not_used(self):
        up = self.Up(table="sx.passages; drop table x")
        self.assertEqual(hydrate_semantic(up, self.doc(), None), self.doc())
        self.assertEqual(up.sql, [])

    def test_other_modes_are_left_alone(self):
        d = {**self.doc(), "mode": "TEXT"}
        self.assertEqual(hydrate_semantic(self.Up(), d, None), d)


class CountProbe(unittest.TestCase):
    """P1: a result that fills its limit is counted, and the count is the move."""

    class Up:
        def __init__(self):
            self.sql = []

        def read(self, path, authorization=None, profile="aiq"):
            return [{"source_table": "sx.passages", "regconfig": "english", "search_with": None}], None

        def rpc(self, fn, payload, authorization=None, profile="aiq"):
            self.sql.append(payload["p_statement"])
            return [{"n": 412}], None

    def doc(self, rows=3, limit=3, mode="TEXT"):
        return {"plan": {"mode": mode, "source": "dracula", "arg": "Lucy's garlic", "limit": limit},
                "rows": [{"chunk_id": str(i)} for i in range(rows)]}

    def test_a_full_result_is_counted_with_the_same_predicate_text_ranks_by(self):
        up = self.Up()
        self.assertEqual(count_matches(up, self.doc(), "Bearer t"), 412)
        self.assertIn("""plainto_tsquery('english', 'Lucy''s garlic')""", up.sql[0])
        self.assertIn('from "sx"."passages"', up.sql[0])

    def test_a_result_short_of_its_limit_is_not_counted(self):
        up = self.Up()
        self.assertIsNone(count_matches(up, self.doc(rows=2), None))
        self.assertEqual(up.sql, [])

    def test_a_mode_with_no_lexical_half_is_not_counted(self):
        self.assertIsNone(count_matches(self.Up(), self.doc(mode="SEMANTIC"), None))

    def test_the_move_carries_the_count(self):
        a = actions_for({"schema": "sx", "name": "passages", "columns": []}, 412, 10)
        self.assertIn("412 rows match and you saw 10", a["TRUNCATED_AT_LIMIT"])
        self.assertNotIn("TRUNCATED_AT_LIMIT", actions_for(None, None, 10))


class DescribeSources(unittest.TestCase):
    class Up:
        def read(self, path, authorization=None, profile="aiq"):
            if path.startswith("lexical_sources?select=name"):
                return [{"name": "dracula"}, {"name": "chunks"}], None
            if path.startswith("semantic_sources?select=name"):
                return [{"name": "dracula"}], None
            table = "sx.passages" if "dracula" in path else "content.resource_chunks"
            return [{"source_table": table}], None

        def rpc(self, fn, payload, authorization=None, profile="aiq"):
            # only the dracula table is readable by this caller
            rel = ([{"schema": "sx", "name": "passages",
                     "columns": [{"name": "source"}, {"name": "time"}]}]
                   if payload["p_query"].endswith("passages") else [])
            return {"schema": {"doc": {"derived": {"relations": rel}}}}, None

    def test_each_readable_source_is_named_with_its_table_and_columns(self):
        text = describe_sources(self.Up(), None)
        self.assertIn("- dracula: the table sx.passages (source, time)", text)
        self.assertNotIn("chunks", text)

    def test_nothing_readable_says_nothing(self):
        class Up(self.Up):
            def rpc(self, fn, payload, authorization=None, profile="aiq"):
                return {"schema": {"doc": {"derived": {"relations": []}}}}, None
        self.assertEqual(describe_sources(Up(), None), "")


class Embedding(unittest.TestCase):
    def setUp(self):
        from unittest import mock
        patch = mock.patch("percolate_core.ingest.local_embed.embed_local",
                           side_effect=lambda model, texts, **kw: [[0.1, 0.2, 0.3]] * len(texts))
        self.embed = patch.start()
        self.addCleanup(patch.stop)

    def test_a_search_is_embedded_with_the_registered_model_and_says_so(self):
        up = FakeUpstream()
        doc, err = QueryEmbedder("on").retry(up, 'SEARCH "who attacked Lucy" FROM d', None)
        self.assertIsNone(err)
        self.assertEqual(doc["embedded"], {"by": "query tool", "model": "bge-small-en-v1.5"})
        self.assertEqual(self.embed.call_args.args[:2], ("BAAI/bge-small-en-v1.5", ["who attacked Lucy"]))
        [(fn, payload, _)] = [c for c in up.calls if c[0] == "query"]
        self.assertEqual(json.loads(payload["p_embedding"]), [0.1, 0.2, 0.3])

    def test_the_plan_comes_from_the_database_parser(self):
        up = FakeUpstream()
        QueryEmbedder("on").retry(up, 'SEARCH "x" FROM d', None)
        self.assertEqual(up.calls[0][0], "aiq_parse")
        self.assertEqual(up.calls[0][2], "public")

    def test_a_mode_without_vectors_is_left_alone(self):
        self.assertIsNone(QueryEmbedder("on").retry(FakeUpstream(mode="TEXT"), "TEXT x", None))
        self.embed.assert_not_called()

    def test_a_hosted_provider_is_not_embedded_here(self):
        up = FakeUpstream(provider="openai", in_process=False)
        self.assertIsNone(QueryEmbedder("on").retry(up, 'SEARCH "x" FROM d', None))
        self.embed.assert_not_called()

    def test_off_never_embeds(self):
        self.assertIsNone(QueryEmbedder("off").retry(FakeUpstream(), 'SEARCH "x" FROM d', None))


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
