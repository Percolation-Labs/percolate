"""POST /embed: a vector for a search query, for a caller with no model (REM-628).

The model is stubbed the way tests/test_local_embed.py stubs it -- a fake
`fastembed` module -- so nothing here downloads 64MB or measures anything. What
is under test is the route: what it refuses, and that the model and dimension
come from the registry rather than from the request.
"""

import json
import sys
import threading
import types
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from percolate_core.content.server import build_app, caller
from percolate_core.ingest import local_embed

LOCAL = {"model": "bge-small-en-v1.5", "dim": 4, "in_process": True,
         "provider": "fastembed", "model_id": "stub/model"}
HOSTED = {"model": "text-embedding-3-small", "dim": 1536, "provider": "openai",
          "url": "https://api.openai.com/v1/embeddings", "batch": True,
          "credential_ref": "openai", "body": {"input": ["a"]}, "jsonpath": "data"}


class StubEmbedding:
    """What fastembed's TextEmbedding looks like from here."""

    threads: list = []

    def __init__(self, **kwargs):
        pass

    def embed(self, texts, batch_size=8, **_):
        StubEmbedding.threads.append(threading.get_ident())
        for i, _t in enumerate(texts):
            yield types.SimpleNamespace(tolist=lambda i=i: [float(i)] * LOCAL["dim"])


class EmbedAQuery(unittest.TestCase):
    def setUp(self):
        local_embed._model = None
        local_embed._model_id = None
        StubEmbedding.threads = []
        sys.modules["fastembed"] = types.SimpleNamespace(TextEmbedding=StubEmbedding)
        self.addCleanup(sys.modules.pop, "fastembed", None)

    def post(self, body, *, spec=LOCAL, anonymous=False):
        """The response, and the arguments the registry call was made with."""
        conn = AsyncMock()
        seen = {}

        async def fetchrow(*args):
            # The route reads the registry TABLES as the caller, because the
            # Content Server's own login cannot set role worker (REM-628). The
            # row is what those tables answer.
            seen["args"] = args
            seen["loop"] = threading.get_ident()
            if spec is None:
                return None
            return {"name": spec["model"], "dim": spec["dim"], "endpoint": spec.get("model_id") or spec.get("url"),
                    "provider": spec["provider"], "in_process": spec.get("in_process", False)}
        conn.fetchrow.side_effect = fetchrow

        @asynccontextmanager
        async def as_caller(_claims):
            yield conn

        application = build_app(())
        if not anonymous:
            application.dependency_overrides[caller] = lambda: {"sub": "test-user"}
        with patch("percolate_core.content.server.as_caller", as_caller):
            with TestClient(application) as client:
                response = client.post("/embed", json=body)
        seen["calls"] = conn.fetchrow.call_count
        return response, seen

    def test_a_query_comes_back_as_one_vector_per_text_in_the_registry_s_dimension(self):
        response, _ = self.post({"texts": ["a claim about a claim", "another"]})
        self.assertEqual(response.status_code, 200, response.text)
        answer = response.json()
        self.assertEqual(answer["model"], LOCAL["model"])
        self.assertEqual(answer["dim"], LOCAL["dim"])
        self.assertEqual(len(answer["vectors"]), 2)
        self.assertTrue(all(len(v) == LOCAL["dim"] for v in answer["vectors"]))

    def test_the_model_comes_from_the_registry_when_the_request_names_none(self):
        response, seen = self.post({"texts": ["a query"]})
        # Null, so the database picks the default row. The answer still names a
        # model, and it is the registry's -- the request never said it.
        self.assertIsNone(seen["args"][1])
        self.assertEqual(response.json()["model"], LOCAL["model"])

    def test_a_named_model_is_passed_to_the_registry_rather_than_believed(self):
        response, seen = self.post({"texts": ["a query"], "model": "bge-small-en-v1.5"})
        self.assertEqual(seen["args"][1], "bge-small-en-v1.5")
        self.assertEqual(response.json()["dim"], LOCAL["dim"])

    def test_a_hosted_model_is_refused_rather_than_proxied(self):
        # The key belongs to the operator and the caller cannot see it, so
        # answering this would spend somebody's paid API on a caller's text.
        response, _ = self.post({"texts": ["a query"]}, spec=HOSTED)
        self.assertEqual(response.status_code, 501, response.text)
        self.assertIn("openai", response.json()["detail"])
        self.assertEqual(StubEmbedding.threads, [])

    def test_too_many_texts_is_refused_before_the_database_is_asked(self):
        response, seen = self.post({"texts": ["q"] * 17})
        self.assertEqual(response.status_code, 413, response.text)
        self.assertEqual(seen["calls"], 0)

    def test_too_many_characters_is_refused_before_the_database_is_asked(self):
        response, seen = self.post({"texts": ["x" * 4_001, "x" * 4_000]})
        self.assertEqual(response.status_code, 413, response.text)
        self.assertEqual(seen["calls"], 0)

    def test_an_empty_or_malformed_body_says_what_to_send(self):
        for body in ({}, {"texts": []}, {"texts": "a query"}, {"texts": [""]}):
            with self.subTest(body=body):
                response, seen = self.post(body)
                self.assertEqual(response.status_code, 400, response.text)
                self.assertEqual(seen["calls"], 0)

    def test_an_anonymous_caller_cannot_burn_the_cpu(self):
        response, seen = self.post({"texts": ["a query"]}, anonymous=True)
        self.assertEqual(response.status_code, 401, response.text)
        self.assertEqual(seen["calls"], 0)

    def test_the_model_does_not_run_on_the_event_loop(self):
        # Inference holds the CPU for the whole call, and on the loop it stalls
        # every file download and every other query behind it.
        _, seen = self.post({"texts": ["a query"]})
        self.assertEqual(len(StubEmbedding.threads), 1)
        self.assertNotEqual(StubEmbedding.threads[0], seen["loop"])


if __name__ == "__main__":
    unittest.main()
