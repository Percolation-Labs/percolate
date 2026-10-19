"""The documented OpenAI-compatible gateway recipe reaches a chat-completions endpoint (REM-973).

The docs, and the runtime's own error message, say to point an agent at any
OpenAI-compatible gateway by setting OPENAI_BASE_URL and keeping an `openai:`
model. pydantic-ai's `openai:` calls the Responses API, `/v1/responses`, which
most gateways do not serve, so every turn failed `ModelHTTPError:
status_code: 404` (found live in REM-957 against dev/faultsrv). The stub here
is such a gateway: it serves `/v1/chat/completions`, streamed and not, and
answers 404 to everything else. The turn runs through the real sequencer and
engine with the row's own model string, as the docs' recipe has it.

Run: python -m unittest discover -s tests -p test_the_gateway_recipe_reaches_chat_completions.py
"""

from __future__ import annotations

import asyncio
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from percolate_core.agentic import authoring
from percolate_core.agentic.contracts import ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.runtime.engine import gateway_model
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository

ANSWER = "Three vessels are alongside."


class Gateway:
    """A chat-completions-only gateway on localhost that records every path it was asked for."""

    def __init__(self):
        outer = self
        self.paths = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                outer.paths.append(self.path)
                if self.path != "/v1/chat/completions":
                    raw = json.dumps({"error": {"message": "not found", "type": "invalid_request_error"}}).encode()
                    self.send_response(404)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                    return
                base = {"id": "c1", "created": 0, "model": body.get("model", "stub")}
                if body.get("stream"):
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    for chunk in (
                        {"choices": [{"index": 0, "delta": {"role": "assistant", "content": ANSWER},
                                      "finish_reason": None}]},
                        {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                         "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}},
                    ):
                        data = dict(base, object="chat.completion.chunk", **chunk)
                        self.wfile.write(f"data: {json.dumps(data)}\n\n".encode())
                    self.wfile.write(b"data: [DONE]\n\n")
                    return
                raw = json.dumps(dict(base, object="chat.completion", choices=[
                    {"index": 0, "message": {"role": "assistant", "content": ANSWER}, "finish_reason": "stop"}],
                    usage={"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10})).encode()
                self.send_response(200)
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


def turn(model_name, env):
    doc = {"type": "object", "name": "harbourmaster", "description": "Answer briefly.", "model": model_name}

    async def go():
        repo = MemoryRepository()
        await repo.upsert_agent(authoring.from_json_schema(doc))
        sequencer = TurnSequencer(repo, Settings.from_env())
        return await sequencer.run_turn(
            ChatRequest(model="harbourmaster", messages=[InboundMessage(role="user", content="Who is alongside?")]),
            RequestContext(tenant="t"))

    with patch.dict(os.environ, env):
        return asyncio.run(go())


class TheGatewayRecipeWorks(unittest.TestCase):

    def setUp(self):
        self.gateway = Gateway()
        self.env = {"OPENAI_BASE_URL": self.gateway.url, "OPENAI_API_KEY": "gateway-key"}

    def tearDown(self):
        self.gateway.close()

    def test_an_openai_model_behind_a_base_url_reaches_chat_completions(self):
        result = turn("openai:gpt-4o-mini", self.env)
        self.assertEqual(result.run.status, "succeeded", f"paths asked for: {self.gateway.paths}")
        self.assertEqual(result.messages[-1].content, ANSWER)
        self.assertEqual(set(self.gateway.paths), {"/v1/chat/completions"},
                         "the gateway is never asked for /v1/responses")

    def test_an_explicit_prefix_is_kept(self):
        self.assertEqual(gateway_model("openai-responses:gpt-4o"), "openai-responses:gpt-4o")
        self.assertEqual(gateway_model("openai-chat:gpt-4o"), "openai-chat:gpt-4o")
        with patch.dict(os.environ, self.env):
            self.assertEqual(gateway_model("openai-responses:gpt-4o"), "openai-responses:gpt-4o")
            self.assertEqual(gateway_model("anthropic:claude-x"), "anthropic:claude-x")

    def test_openais_own_base_url_changes_nothing(self):
        # get-percolate's compose file sets OPENAI_BASE_URL to OpenAI's own by default.
        with patch.dict(os.environ, {"OPENAI_BASE_URL": "https://api.openai.com/v1"}):
            self.assertEqual(gateway_model("openai:gpt-4o-mini"), "openai:gpt-4o-mini")

    def test_without_a_base_url_nothing_changes(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OPENAI_BASE_URL", None)
            self.assertEqual(gateway_model("openai:gpt-4o-mini"), "openai:gpt-4o-mini")


if __name__ == "__main__":
    unittest.main()
