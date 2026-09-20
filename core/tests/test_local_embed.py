"""The in-process embedding provider (REM-628).

The dispatch tests use a stub model, so they run anywhere and say nothing about
speed. The one test that loads the real model is skipped unless the model is
cached, because a test that downloads 64MB from Hugging Face is a test that
fails when the network does. The image proves the real load offline at build
time (.github/scripts/cache_embedding_model.py).
"""

import os
import sys
import types
import unittest

from percolate_core.ingest import embed as embed_mod
from percolate_core.ingest import local_embed
from percolate_core.worker.templates import TerminalError


class StubEmbedding:
    """What fastembed's TextEmbedding looks like from here."""

    last_kwargs: dict = {}
    dim = 4

    def __init__(self, **kwargs):
        StubEmbedding.last_kwargs = kwargs

    def embed(self, texts, batch_size=8, **_):
        for i, _t in enumerate(texts):
            yield types.SimpleNamespace(tolist=lambda i=i: [float(i)] * StubEmbedding.dim)


class LocalEmbedding(unittest.TestCase):
    def setUp(self):
        local_embed._model = None
        local_embed._model_id = None
        StubEmbedding.dim = 4
        sys.modules["fastembed"] = types.SimpleNamespace(TextEmbedding=StubEmbedding)
        self.addCleanup(sys.modules.pop, "fastembed", None)

    def test_vectors_come_back_in_input_order(self):
        out = local_embed.embed_local("stub/model", ["a", "b", "c"])
        self.assertEqual([v[0] for v in out], [0.0, 1.0, 2.0])

    def test_the_model_is_loaded_once_and_kept(self):
        local_embed.embed_local("stub/model", ["a"])
        first = local_embed._model
        local_embed.embed_local("stub/model", ["b"])
        self.assertIs(local_embed._model, first)

    def test_a_second_model_id_replaces_the_first(self):
        local_embed.embed_local("stub/one", ["a"])
        first = local_embed._model
        local_embed.embed_local("stub/two", ["a"])
        self.assertIsNot(local_embed._model, first)
        self.assertEqual(local_embed._model_id, "stub/two")

    def test_the_cache_and_thread_count_come_from_the_environment(self):
        os.environ["P8_EMBED_CACHE"] = "/tmp/p8-embed-cache-test"
        os.environ["P8_EMBED_THREADS"] = "2"
        self.addCleanup(os.environ.pop, "P8_EMBED_CACHE", None)
        self.addCleanup(os.environ.pop, "P8_EMBED_THREADS", None)
        local_embed.embed_local("stub/model", ["a"])
        self.assertEqual(StubEmbedding.last_kwargs["cache_dir"], "/tmp/p8-embed-cache-test")
        self.assertEqual(StubEmbedding.last_kwargs["threads"], 2)

    def test_a_dimension_the_space_cannot_hold_is_refused(self):
        # The registry's dim built the vector(n) column, so this is not one bad
        # row: every insert into the space would fail, and the receipt would
        # say the batch succeeded.
        with self.assertRaises(TerminalError) as caught:
            local_embed.embed_local("stub/model", ["a"], expected_dim=384)
        self.assertIn("vector(384)", str(caught.exception))

    def test_a_worker_without_fastembed_says_which_extra_is_missing(self):
        del sys.modules["fastembed"]
        real_import = __builtins__["__import__"] if isinstance(__builtins__, dict) else __import__

        def no_fastembed(name, *a, **k):
            if name == "fastembed":
                raise ModuleNotFoundError("No module named 'fastembed'")
            return real_import(name, *a, **k)

        import builtins
        builtins.__import__ = no_fastembed
        self.addCleanup(setattr, builtins, "__import__", real_import)
        with self.assertRaises(TerminalError) as caught:
            local_embed.embed_local("stub/model", ["a"])
        self.assertIn("percolate-core[embed]", str(caught.exception))


class Dispatch(unittest.TestCase):
    """embed_texts sends an in_process spec to the local model and makes no request."""

    def setUp(self):
        local_embed._model = None
        local_embed._model_id = None
        sys.modules["fastembed"] = types.SimpleNamespace(TextEmbedding=StubEmbedding)
        self.addCleanup(sys.modules.pop, "fastembed", None)

    def test_an_in_process_spec_embeds_here_and_reports_no_requests(self):
        spec = {"model": "bge-small-en-v1.5", "dim": 4, "in_process": True,
                "provider": "fastembed", "model_id": "stub/model"}
        vectors, requests = embed_mod.embed_texts(spec, ["a", "b"])
        self.assertEqual(len(vectors), 2)
        self.assertEqual(len(vectors[0]), 4)
        # Zero is the receipt's way of saying nobody was called. A hosted batch
        # of two would be 1.
        self.assertEqual(requests, 0)

    def test_the_local_default_batch_is_used_when_the_caller_did_not_choose(self):
        seen = {}

        def spy(model_id, texts, batch_size, expected_dim=None):
            seen["batch"] = batch_size
            return [[0.0] * 4 for _ in texts]

        self.addCleanup(setattr, local_embed, "embed_local", local_embed.embed_local)
        local_embed.embed_local = spy
        spec = {"model": "m", "dim": 4, "in_process": True, "model_id": "stub/model"}
        embed_mod.embed_texts(spec, ["a"])
        # 8, not the hosted 96: a batch is padded to its longest member, so a
        # bigger one is a bigger tensor and no more throughput -- and 96 would
        # be gigabytes on a 2GiB pod.
        self.assertEqual(seen["batch"], local_embed.DEFAULT_LOCAL_BATCH)

    def test_a_caller_that_chose_a_batch_size_keeps_it(self):
        seen = {}

        def spy(model_id, texts, batch_size, expected_dim=None):
            seen["batch"] = batch_size
            return [[0.0] * 4 for _ in texts]

        self.addCleanup(setattr, local_embed, "embed_local", local_embed.embed_local)
        local_embed.embed_local = spy
        spec = {"model": "m", "dim": 4, "in_process": True, "model_id": "stub/model"}
        embed_mod.embed_texts(spec, ["a"], batch_size=32)
        self.assertEqual(seen["batch"], 32)


@unittest.skipUnless(os.environ.get("P8_EMBED_CACHE"),
                     "set P8_EMBED_CACHE to a cache holding the model")
class TheRealModel(unittest.TestCase):
    def test_it_loads_with_the_network_denied_and_produces_384_dimensions(self):
        local_embed._model = None
        local_embed._model_id = None
        model_id = os.environ.get("P8_EMBED_MODEL", "BAAI/bge-small-en-v1.5")
        local_embed.assert_offline(model_id)
        vectors = local_embed.embed_local(model_id, ["a claim about a claim"], expected_dim=384)
        self.assertEqual(len(vectors[0]), 384)


if __name__ == "__main__":
    unittest.main()
