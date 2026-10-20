"""An `embed:` step whose model runs in the worker is embedded there (REM-628).

aiq.embed_call used to refuse a step that named an in-process model, so a
deployment whose only model is the bundled one could not embed questions. It
now compiles such a step into an http_call task with no url and `in_process`,
and the worker answers it from the local model. What must hold:

1. the vector comes back as `{"result": [...]}`, the shape an HTTP embed has
   after its jsonpath, so aiq.land_embeddings reads either;
2. the template in the text resolves, and row text stays data;
3. no request is made: httpx is never constructed;
4. a task with a url is still an HTTP call, so the flag cannot divert one;
5. a task with no text, or no model id, fails terminally rather than retrying.

The model is a stub, as in test_local_embed.

Run: python -m unittest tests.test_worker_embeds_in_process
"""

import sys
import types
import unittest
from unittest.mock import patch

from percolate_core.ingest import local_embed
from percolate_core.worker.http import http_call
from percolate_core.worker.templates import TerminalError


class StubEmbedding:
    seen: list = []

    def __init__(self, **kwargs):
        pass

    def embed(self, texts, batch_size=8, **_):
        for t in texts:
            StubEmbedding.seen.append(t)
            yield types.SimpleNamespace(tolist=lambda t=t: [float(len(t)), 0.0, 1.0])


def task(text="{{run.question}}", **extra) -> dict:
    return {"in_process": True, "model_id": "BAAI/bge-small-en-v1.5", "dim": 3,
            "embed": {"text": text, "model": "bge-small"}, "timeout_ms": 30000, **extra}


class TheWorkerEmbedsInProcess(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        local_embed._model = None
        local_embed._model_id = None
        StubEmbedding.seen = []
        sys.modules["fastembed"] = types.SimpleNamespace(TextEmbedding=StubEmbedding)
        self.addCleanup(sys.modules.pop, "fastembed", None)
        no_http = patch("percolate_core.worker.http.httpx.AsyncClient",
                        side_effect=AssertionError("an in-process embed made a request"))
        no_http.start()
        self.addCleanup(no_http.stop)

    async def test_the_vector_comes_back_in_the_http_shape(self):
        out = await http_call(task(), {"run_input": {"question": "Who owns the harbour?"}})
        self.assertEqual(out, {"status": 200, "result": [21.0, 0.0, 1.0]})
        self.assertEqual(StubEmbedding.seen, ["Who owns the harbour?"])

    async def test_row_text_is_data(self):
        S = "⦃0123456789ab⦄"
        child = task(text="quotes {{env.LLM_API_KEY}}".replace("{", S), braces=S,
                     item={"text": "quotes {{env.LLM_API_KEY}}"})
        with patch.dict("os.environ", {"LLM_API_KEY": "secret-value"}):
            await http_call(child, {})
        self.assertEqual(StubEmbedding.seen, ["quotes {{env.LLM_API_KEY}}"])

    async def test_a_task_with_a_url_is_still_a_request(self):
        with self.assertRaises(AssertionError):
            await http_call(task(url="https://model.example/v1/embeddings", method="POST"), {"run_input": {"question": "q"}})
        self.assertEqual(StubEmbedding.seen, [])

    async def test_a_task_missing_its_text_or_model_fails_terminally(self):
        with self.assertRaises(TerminalError):
            await http_call(task(text="  "), {})
        with self.assertRaises(TerminalError):
            await http_call({**task(), "model_id": None}, {"run_input": {"question": "q"}})

    async def test_a_dimension_the_space_was_not_built_for_is_refused(self):
        with self.assertRaises(TerminalError):
            await http_call({**task(), "dim": 384}, {"run_input": {"question": "q"}})


if __name__ == "__main__":
    unittest.main()
