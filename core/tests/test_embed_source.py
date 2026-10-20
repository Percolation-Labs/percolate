"""`op: embed` over a registered semantic source, by name (REM-662).

No database and no model. `as_service` yields a connection that answers the
three calls the step makes -- aiq.embed_batch_call, aiq.texts_to_embed and
aiq.record_embeddings -- from a dict standing in for the source and its space,
and fastembed is stubbed the way tests/test_local_embed.py stubs it. What is
under test is the loop: that it pages through what the space lacks until
nothing is left, writes every vector through record_embeddings under the model
it resolved once, stops at its cap and says so, and refuses a page that lands
nothing rather than asking for it forever.
"""

import asyncio
import json
import sys
import types
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

from percolate_core.ingest import embed as embed_mod
from percolate_core.ingest import handler, local_embed
from percolate_core.worker.templates import TerminalError

LOCAL = {"model": "bge-small-en-v1.5", "dim": 3, "in_process": True,
         "provider": "fastembed", "model_id": "stub/model"}


class StubEmbedding:
    def __init__(self, **kwargs):
        pass

    def embed(self, texts, batch_size=8, **_):
        for t in texts:
            yield types.SimpleNamespace(tolist=lambda t=t: [float(len(t)), 1.0, 0.0])


class FakeSpace:
    """A source of rows and the space their vectors land in."""

    def __init__(self, rows, lands=True):
        self.rows = dict(rows)          # chunk_id -> text
        self.space = {}                 # chunk_id -> vector
        self.calls = []
        self.lands = lands

    def service(self):
        fake = self

        class Conn:
            async def fetchval(self, sql, *args):
                fake.calls.append((sql.split("(")[0], args))
                if "aiq.embed_batch_call" in sql:
                    return json.dumps(LOCAL)
                if "aiq.texts_to_embed" in sql:
                    source, model, limit = args
                    missing = [k for k in sorted(fake.rows) if k not in fake.space][:limit]
                    return json.dumps([{"chunk_id": k, "content": fake.rows[k]} for k in missing])
                if "aiq.record_embeddings" in sql:
                    model, payload = args
                    if not fake.lands:
                        return 0
                    for r in payload:
                        fake.space[r["chunk_id"]] = r["embedding"]
                    return len(payload)
                raise AssertionError(sql)

        @asynccontextmanager
        async def as_service(*a, **kw):
            yield Conn()
        return as_service


class EmbedASource(unittest.TestCase):
    def setUp(self):
        local_embed._model = None
        local_embed._model_id = None
        sys.modules["fastembed"] = types.SimpleNamespace(TextEmbedding=StubEmbedding)
        self.addCleanup(sys.modules.pop, "fastembed", None)

    def run_step(self, fake, spec):
        with patch.object(embed_mod, "as_service", fake.service()):
            return asyncio.run(handler.work({"op": "embed", **spec}, {}))["result"]

    def test_every_row_the_space_lacks_is_embedded_in_pages_and_the_receipt_counts_them(self):
        fake = FakeSpace({f"c{i:02d}": "claim %d" % i for i in range(7)})
        fake.space["c00"] = [9.0, 9.0, 9.0]          # already embedded: not asked again
        out = self.run_step(fake, {"source": "claims", "page": 3})
        self.assertEqual(out["embedded"], 6)
        self.assertEqual(out["pages"], 2)
        self.assertEqual(out["model"], "bge-small-en-v1.5")
        self.assertFalse(out["more"])
        self.assertEqual(sorted(fake.space), sorted(fake.rows))
        self.assertEqual(fake.space["c00"], [9.0, 9.0, 9.0])
        self.assertEqual(fake.space["c01"], [7.0, 1.0, 0.0])

    def test_the_source_is_asked_for_by_name_under_the_model_resolved_once(self):
        fake = FakeSpace({"q1": "a question"})
        self.run_step(fake, {"source": "questions"})
        asked = [args for name, args in fake.calls if "texts_to_embed" in name]
        self.assertTrue(asked)
        self.assertTrue(all(a[0] == "questions" and a[1] == "bge-small-en-v1.5" for a in asked))
        # Null model: the database chooses the default, and the run writes to the one it chose.
        probe = [args for name, args in fake.calls if "embed_batch_call" in name]
        self.assertEqual(probe, [(None, [])])
        landed = [args[0] for name, args in fake.calls if "record_embeddings" in name]
        self.assertEqual(landed, ["bge-small-en-v1.5"])

    def test_nothing_to_embed_is_a_receipt_of_zero_not_an_error(self):
        out = self.run_step(FakeSpace({}), {"source": "claims"})
        self.assertEqual((out["embedded"], out["pages"], out["more"]), (0, 0, False))

    def test_the_cap_stops_a_task_and_says_more_is_left(self):
        fake = FakeSpace({f"c{i}": "x" for i in range(5)})
        out = self.run_step(fake, {"source": "claims", "page": 2, "max_rows": 3})
        self.assertEqual(out["embedded"], 3)
        self.assertTrue(out["more"])
        self.assertEqual(len(fake.space), 3)

    def test_a_page_that_lands_nothing_is_refused_rather_than_asked_for_forever(self):
        with self.assertRaises(TerminalError):
            self.run_step(FakeSpace({"c1": "x"}, lands=False), {"source": "claims"})

    def test_a_resource_embed_without_a_source_still_needs_its_resource_id(self):
        with self.assertRaises(TerminalError):
            self.run_step(FakeSpace({}), {})


if __name__ == "__main__":
    unittest.main()
