"""An exhausted or refused provider account fails once, on every path (REM-53).

Four call sites send a request to a provider -- the http_call handler, corpus
embedding (which lake refinement also calls), transcription and API ingestion
-- and each used to decide for itself what a failed response meant. Embedding
retried an out-of-credit 429 five times, transcription retried a 401, and API
ingestion retried every 429. Each case here runs the real call site against a
transport that answers with the failure and counts what it was sent: terminal
means a TerminalError after exactly one request, so the engine does not queue
four more.
"""
import asyncio
import json
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

import httpx

from percolate_core.core.provider_errors import classify
from percolate_core.ingest import api as api_module
from percolate_core.ingest import embed as embed_module
from percolate_core.ingest import transcribe as transcribe_module
from percolate_core.ingest.policy import TranscribePolicy
from percolate_core.worker import http as http_module
from percolate_core.worker.templates import TerminalError

PROVIDER = "https://provider.example"
ENV = {
    "PROVIDER_KEY": "sk-unit-test",
    "P8_CREDENTIAL_ORIGINS": json.dumps({"PROVIDER_KEY": [PROVIDER]}),
    "P8_INGEST_CREDENTIAL_ORIGINS": json.dumps({"PROVIDER_KEY": [PROVIDER]}),
}

# What OpenAI sends for an account with no credit left, and for a request rate
# that is merely too high. Same status, opposite remedies.
NO_CREDIT = (429, {"error": {"message": "You exceeded your current quota",
                             "type": "insufficient_quota", "code": "insufficient_quota"}})
RATE_LIMITED = (429, {"error": {"message": "Rate limit reached",
                                "type": "requests", "code": "rate_limit_exceeded"}})
REFUSED = (401, {"error": {"message": "Incorrect API key provided", "code": "invalid_api_key"}})
FORBIDDEN = (403, {"error": {"message": "Project does not have access"}})
DOWN = (503, {"error": {"message": "overloaded"}})


class Answer:
    """A transport that gives one fixed answer and counts the requests."""

    def __init__(self, status, body):
        self.status, self.body, self.sent = status, body, 0

    def __call__(self, request):
        self.sent += 1
        return httpx.Response(self.status, json=self.body, request=request)

    def patch(self, module, cls_name):
        real = getattr(httpx, cls_name)
        return patch.object(module.httpx, cls_name,
                            lambda *a, **kw: real(*a, transport=httpx.MockTransport(self), **kw))


def call_http(answer):
    spec = {"url": PROVIDER + "/v1/chat/completions", "method": "POST",
            "credential_ref": "PROVIDER_KEY", "body": {"model": "m"}}
    with answer.patch(http_module, "AsyncClient"):
        asyncio.run(http_module.http_call(spec, {}))


def call_embed(answer):
    spec = {"url": PROVIDER + "/v1/embeddings", "credential_ref": "PROVIDER_KEY",
            "batch": True, "body": {"model": "m", "input": ["x"]}, "model": "m"}
    with answer.patch(embed_module, "Client"):
        embed_module.embed_texts(spec, ["one", "two"])


def call_transcribe(answer):
    policy = TranscribePolicy(endpoint=PROVIDER + "/v1/audio/transcriptions",
                              model="whisper-1", credential="PROVIDER_KEY")
    with answer.patch(transcribe_module, "Client"):
        transcribe_module.transcribe(b"RIFF", "a.wav", policy)


class FakeConn:
    async def fetchval(self, sql, *args):
        assert "begin_api_pull" in sql, f"nothing should be committed after a failed page: {sql}"
        return json.dumps({"config": {"url": PROVIDER + "/items", "auth_type": "bearer",
                                      "credential_ref": "PROVIDER_KEY"},
                           "revision": 1})


@asynccontextmanager
async def fake_service():
    yield FakeConn()


def call_api(answer):
    with answer.patch(api_module, "AsyncClient"), \
            patch.object(api_module, "as_service", fake_service):
        asyncio.run(api_module.api_pull(
            {"source_id": "00000000-0000-0000-0000-000000000001"},
            {"_task_id": "00000000-0000-0000-0000-000000000002", "_worker_id": "w"}))


PATHS = {"http_call": call_http, "embed": call_embed,
         "transcribe": call_transcribe, "api_pull": call_api}


class EveryPathTest(unittest.TestCase):
    def setUp(self):
        env = patch.dict("os.environ", ENV, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def assert_terminal_once(self, status_body, says):
        for name, call in PATHS.items():
            answer = Answer(*status_body)
            with self.subTest(path=name), self.assertRaises(TerminalError) as caught:
                call(answer)
            with self.subTest(path=name):
                self.assertEqual(answer.sent, 1, f"{name} sent {answer.sent} requests")
                self.assertIn(says, str(caught.exception).lower())

    def assert_retryable(self, status_body):
        for name, call in PATHS.items():
            answer = Answer(*status_body)
            with self.subTest(path=name):
                with self.assertRaises(Exception) as caught:
                    call(answer)
                self.assertNotIsInstance(caught.exception, TerminalError,
                                         f"{name} gave up on a failure worth retrying")
                self.assertEqual(answer.sent, 1)

    def test_an_account_with_no_credit_fails_once(self):
        self.assert_terminal_once(NO_CREDIT, "no credit")

    def test_a_refused_key_fails_once(self):
        self.assert_terminal_once(REFUSED, "refused the credential")
        self.assert_terminal_once(FORBIDDEN, "refused the credential")

    def test_a_rate_limit_is_still_retried(self):
        self.assert_retryable(RATE_LIMITED)

    def test_a_server_outage_is_still_retried(self):
        self.assert_retryable(DOWN)


class ClassifyTest(unittest.TestCase):
    def test_the_rules(self):
        cases = {
            (429, json.dumps(NO_CREDIT[1])): ("quota", True),
            (429, json.dumps(RATE_LIMITED[1])): ("rate_limited", False),
            (429, "not json"): ("rate_limited", False),
            (401, ""): ("auth", True),
            (403, ""): ("auth", True),
            (402, ""): ("quota", True),
            (400, ""): ("client", True),
            (404, ""): ("client", True),
            (408, ""): ("timeout", False),
            (500, ""): ("server", False),
            (503, ""): ("server", False),
        }
        for (status, body), (reason, terminal) in cases.items():
            with self.subTest(status=status, body=body[:20]):
                got = classify(status, body)
                self.assertEqual((got.reason, got.terminal), (reason, terminal))

    def test_a_success_is_not_a_failure(self):
        self.assertIsNone(classify(200, "{}"))


if __name__ == "__main__":
    unittest.main()
