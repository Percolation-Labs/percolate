"""A model provider that refuses the key fails an `agent:` step once (REM-987).

An `agent:` workflow step posts to this runtime's `/chat` and the worker reads
the answer with `core.provider_errors` (REM-53). The runtime answered every
failed turn 502, so a provider's 401 reached the worker as "the provider
failed; worth retrying" and the step was retried five times, about half a
minute each, telling its reader the opposite of the cause. Seen on 0.2.23 in
fresh-reader runs 4 and 5 of the LangGraph article: /chat showed 401
invalid_api_key, the steps showed the 502.

Each case runs the three real pieces in turn: a pydantic-ai agent built from
the row's model string against a stub provider on localhost, the runtime's
answer to the turn it failed, and the worker's http_call reading that answer.
Terminal means a TerminalError after one request, which is what stops the
engine queueing four more attempts.

The second defect is in the first piece. The OpenAI SDK unwraps the provider's
`{"error": {...}}` before pydantic-ai keeps the body, and the classifier reads
the envelope, so an account with no credit was read as a rate limit on this
path and retried.
"""
import asyncio
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

import httpx
from fastapi import HTTPException

from percolate_core.agentic import api
from percolate_core.agentic.contracts import ChatRequest, RequestContext, Run, Session
from percolate_core.agentic.sequencer import TurnResult, TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.task_outcome import failure_is_terminal
from percolate_core.worker import http as http_module
from percolate_core.worker.templates import TerminalError

MODEL = "openai:gpt-4o-mini"
REFUSED = (401, {"error": {"message": "Incorrect API key provided: sk-bad.",
                           "type": "invalid_request_error", "code": "invalid_api_key"}})
NO_CREDIT = (429, {"error": {"message": "You exceeded your current quota",
                             "type": "insufficient_quota", "code": "insufficient_quota"}})
DOWN = (503, {"error": {"message": "overloaded", "type": "server_error"}})


class Provider:
    """A stub model provider on localhost that gives one answer and counts requests."""

    def __init__(self, status, body):
        outer = self
        self.sent = 0

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                outer.sent += 1
                raw = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/v1"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def provider_error(status_body):
    """What a turn against this provider raises, built from the row's model string."""
    from pydantic_ai import Agent

    provider = Provider(*status_body)
    try:
        with patch.dict(os.environ, {"OPENAI_BASE_URL": provider.url, "OPENAI_API_KEY": "sk-bad"}):
            agent = Agent(MODEL, instructions="Answer in one word.")
            try:
                asyncio.run(agent.run("hello"))
            except Exception as exc:  # noqa: BLE001 -- the exception is the subject
                return exc, provider.sent
        raise AssertionError("the stub provider's error did not fail the turn")
    finally:
        provider.close()


def runtime_answer(exc):
    """The status and body the runtime's /chat sends back for a turn that raised `exc`."""
    session = Session(id=uuid4())
    run = Run(status="failed", state={"error": f"{type(exc).__name__}: {exc}"})

    async def run_turn(self, request, context, **kwargs):
        return TurnResult(run=run, session=session, error=exc)

    class Repo:
        async def get_agent(self, name):
            return SimpleNamespace(name=name, model=MODEL)

    async def complete():
        with patch.object(TurnSequencer, "run_turn", run_turn):
            return await api._completion(
                Repo(), Settings(),
                ChatRequest(model="tour", messages=[{"role": "user", "content": "hello"}]),
                RequestContext(), session)

    try:
        response = asyncio.run(complete())
    except HTTPException as e:
        return e.status_code, {"detail": e.detail}
    return response.status_code, json.loads(response.body)


def worker_reads(status, body):
    """The worker's http_call against that answer: what it raises, and how many requests."""
    sent = 0

    def answer(request):
        nonlocal sent
        sent += 1
        return httpx.Response(status, json=body, request=request)

    real = httpx.AsyncClient
    spec = {"url": "http://agent.example/chat", "method": "POST",
            "body": {"model": "tour", "messages": [{"role": "user", "content": "hello"}]}}
    with patch.object(http_module.httpx, "AsyncClient",
                      lambda *a, **kw: real(*a, transport=httpx.MockTransport(answer), **kw)):
        try:
            asyncio.run(http_module.http_call(spec, {}))
        except Exception as exc:  # noqa: BLE001
            return exc, sent
    return None, sent


class ARefusedKeyFailsTheStepOnce(unittest.TestCase):
    def test_a_refused_key_is_final_and_says_which_key(self):
        exc, asked = provider_error(REFUSED)
        self.assertEqual(asked, 1, "the provider was asked again after refusing the key")
        self.assertTrue(failure_is_terminal(exc))

        status, body = runtime_answer(exc)
        self.assertEqual(status, 401, f"the runtime folded the provider's 401 into {status}")
        self.assertIn("OPENAI_API_KEY", body["detail"])
        self.assertIn(MODEL, body["detail"])

        raised, sent = worker_reads(status, body)
        self.assertIsInstance(raised, TerminalError, f"the step would be retried: {raised}")
        self.assertEqual(sent, 1)
        self.assertIn("refused the credential", str(raised))
        self.assertIn("OPENAI_API_KEY", str(raised))
        self.assertNotIn("worth retrying", str(raised))

    def test_an_account_with_no_credit_is_final(self):
        exc, _ = provider_error(NO_CREDIT)
        self.assertTrue(failure_is_terminal(exc),
                        "a 429 for an account with no credit was read as a rate limit")

        status, body = runtime_answer(exc)
        self.assertEqual(status, 429)
        self.assertEqual(body["error"]["code"], "insufficient_quota")

        raised, sent = worker_reads(status, body)
        self.assertIsInstance(raised, TerminalError, f"the step would be retried: {raised}")
        self.assertEqual(sent, 1)

    def test_a_provider_outage_is_still_retried(self):
        exc, _ = provider_error(DOWN)
        self.assertFalse(failure_is_terminal(exc))

        status, body = runtime_answer(exc)
        self.assertEqual(status, 502)

        raised, _ = worker_reads(status, body)
        self.assertIsNotNone(raised)
        self.assertNotIsInstance(raised, TerminalError, "an outage worth waiting out was made final")


if __name__ == "__main__":
    unittest.main()
