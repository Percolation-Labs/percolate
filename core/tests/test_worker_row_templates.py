"""A fan-out child's row text is data: it reaches the request unchanged and
never resolves as a template (workflow-engine YAML.md, "Row text is data").

Found backfilling session transcripts through the upload pipeline: a window
that quoted a workflow document failed with `template {{env.LLM_URL}} resolved
to nothing`, and `{{env.<secret>}}` in an uploaded document would have been
sent to the model provider.
"""
import json
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

import httpx

from percolate_core.worker.http import build_request, http_call
from percolate_core.worker.templates import TerminalError, resolve_task

S = "⦃0123456789ab⦄"     # the sentinel the database records as input.braces


def child(text: str) -> dict:
    """A matrix child as the database hands it over: row text escaped, the
    sentinel recorded, the row kept verbatim."""
    return {
        "url": "{{env.LLM_URL}}/v1/chat/completions",
        "method": "POST",
        "credential_ref": "LLM_API_KEY",
        "body": {"messages": [{"role": "user", "content": text.replace("{", S)}]},
        "item": {"content": text, "window_ordinal": 0},
        "braces": S,
    }


class RowTextTest(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict("os.environ", {
            "LLM_URL": "https://model.example", "LLM_API_KEY": "sk-test",
            "P8_JWT_SECRET": "the-signing-secret"}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_row_text_is_sent_as_written(self):
        text = "config: {{env.P8_JWT_SECRET}} then {{steps.first.result}} and {{run.question}}"
        req, spec = build_request(child(text), {"context": {}, "run_input": {}})
        sent = json.loads(req["content"])["messages"][0]["content"]
        self.assertEqual(sent, text)
        self.assertNotIn("the-signing-secret", req["content"].decode())

    def test_the_authors_templates_still_resolve(self):
        req, _ = build_request(child("plain"), {"context": {}, "run_input": {}})
        self.assertEqual(req["url"], "https://model.example/v1/chat/completions")

    def test_the_row_snapshot_is_not_resolved(self):
        # The raw copy under `item` holds unescaped braces. Resolving it used
        # to raise "resolved to nothing" and fail the child terminally.
        spec = resolve_task(child("{{steps.first.result}}"), {"context": {}, "run_input": {}})
        self.assertEqual(spec["item"]["content"], "{{steps.first.result}}")
        self.assertNotIn("braces", spec)

    def test_adjacent_row_values_cannot_assemble_a_template(self):
        # "{" from one column beside "{env.P8_JWT_SECRET}}" from another.
        spec = {"body": {"q": S + S + "env.P8_JWT_SECRET}}"}, "braces": S}
        out = resolve_task(spec, {"context": {}, "run_input": {}})
        self.assertEqual(out["body"]["q"], "{{env.P8_JWT_SECRET}}")

    def test_without_a_sentinel_resolution_is_unchanged(self):
        out = resolve_task({"q": "{{run.x}}"}, {"context": {}, "run_input": {"x": "v"}})
        self.assertEqual(out, {"q": "v"})


class QuotaTest(unittest.IsolatedAsyncioTestCase):
    async def status(self, code: int, body: dict) -> Exception:
        response = httpx.Response(code, json=body)
        client = MagicMock()
        client.__aenter__ = AsyncMock(return_value=client)
        client.__aexit__ = AsyncMock(return_value=False)
        client.request = AsyncMock(return_value=response)
        with patch("percolate_core.worker.http.httpx.AsyncClient", return_value=client):
            try:
                await http_call({"url": "https://model.example", "method": "POST"}, {})
            except Exception as e:      # noqa: BLE001 -- the class is the assertion
                return e
        self.fail("no error raised")

    async def test_an_exhausted_account_is_terminal(self):
        e = await self.status(429, {"error": {"type": "insufficient_quota",
                                              "code": "credit_balance_exhausted",
                                              "message": "You have no credits remaining."}})
        self.assertIsInstance(e, TerminalError)

    async def test_a_rate_limit_is_still_retried(self):
        e = await self.status(429, {"error": {"type": "requests",
                                              "code": "rate_limit_exceeded"}})
        self.assertNotIsInstance(e, TerminalError)
        self.assertIsInstance(e, RuntimeError)


if __name__ == "__main__":
    unittest.main()
