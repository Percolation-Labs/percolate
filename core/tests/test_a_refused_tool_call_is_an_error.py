"""A tool call that failed reaches the model, and the stream, as a failure.

On a compose stack without `P8_TOOL_AUTH_ORIGINS`, a delegated call reached the
agent gateway with no bearer, the gateway answered `a verified caller is
required`, and the MCP provider recorded `is_error=True` on every
`tool_response` row. The model was never told. The forwarder handed pydantic-ai
the error text as an ordinary return value, so the provider saw a successful
tool result, and `TOOL_CALL_END` said `is_error: false`. The model called the
tool again 54 times, until `request_limit` stopped the run.

The model here is pydantic-ai's FunctionModel with a stream function, so the
real tool-execution and streaming paths run. Only the model and the tool
server's answer are fake.

Run: python -m unittest discover -s tests -p test_a_refused_tool_call_is_an_error.py
"""

from __future__ import annotations

import asyncio
import json
import unittest
from unittest.mock import patch

from percolate_core.agentic.contracts import (
    AgentSpec,
    CanonicalTool,
    ChatRequest,
    InboundMessage,
    RequestContext,
    ToolResult,
    ToolServer,
)
from percolate_core.agentic.contracts.tools import InvocationTarget
from percolate_core.agentic.sequencer import TurnSequencer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository
from percolate_core.agentic.tools.mcp import McpProvider

REFUSAL = "a verified caller is required"
TOOL = "agent__fleet_analyst"


def model_that_calls_once(seen: list):
    """Call the tool once, then answer, recording what the model was handed back."""
    from pydantic_ai.models.function import DeltaToolCall, FunctionModel

    async def stream(messages, info):
        returns = [part for message in messages for part in getattr(message, "parts", [])
                   if part.part_kind in ("tool-return", "retry-prompt")]
        if not returns:
            yield {0: DeltaToolCall(name=TOOL, json_args=json.dumps({"prompt": "which vessels?"}),
                                    tool_call_id="call-1")}
            return
        seen.extend(returns)
        yield "stopped"

    return FunctionModel(stream_function=stream)


def run(serves_agents: bool, refused: bool):
    async def refuse(self, server, tool, call, headers=None):
        return ToolResult(call_id=call.call_id, tool_name=tool.name,
                          content=REFUSAL if refused else "two vessels",
                          is_error=refused, error_kind="tool_error" if refused else None)

    async def go():
        repo = MemoryRepository()
        await repo.upsert_tool_server(ToolServer(
            name="p8-agents", kind="mcp", url="http://gateway:8765/mcp",
            serves_agents=serves_agents,
            cached_tools=[CanonicalTool(name=TOOL, target=InvocationTarget(tool_name=TOOL))],
        ))
        await repo.upsert_agent(AgentSpec(name="harbourmaster",
                                          tools=[{"server": "p8-agents", "tools": [TOOL]}]))
        seen: list = []
        sequencer = TurnSequencer(repo, Settings.from_env())
        with patch.object(McpProvider, "invoke", refuse):
            result = await sequencer.run_turn(
                ChatRequest(model="harbourmaster",
                            messages=[InboundMessage(role="user", content="which vessels?")]),
                RequestContext(tenant="t"),
                model=model_that_calls_once(seen),
            )
        return result, sequencer.sink.events, seen

    return asyncio.run(go())


class ARefusedToolCallIsAnError(unittest.TestCase):
    def test_the_model_is_handed_a_failed_result(self):
        # Both kinds of MCP server: the defect was found on a delegation, and an
        # ordinary server goes through the same forwarder.
        for serves_agents in (True, False):
            with self.subTest(serves_agents=serves_agents):
                result, _, seen = run(serves_agents, refused=True)
                self.assertEqual(result.run.status, "succeeded")
                self.assertEqual(len(seen), 1)
                self.assertEqual(seen[0].part_kind, "tool-return")
                self.assertEqual(seen[0].outcome, "failed")
                self.assertIn(REFUSAL, seen[0].model_response_str())

    def test_the_stream_says_the_call_failed(self):
        for serves_agents in (True, False):
            with self.subTest(serves_agents=serves_agents):
                _, events, _ = run(serves_agents, refused=True)
                ends = [e for e in events if e.type == "TOOL_CALL_END"]
                self.assertEqual(len(ends), 1)
                self.assertTrue(ends[0].is_error)

    def test_a_call_that_worked_is_still_a_success(self):
        for serves_agents in (True, False):
            with self.subTest(serves_agents=serves_agents):
                _, events, seen = run(serves_agents, refused=False)
                self.assertEqual(seen[0].outcome, "success")
                self.assertEqual(seen[0].content, "two vessels")
                ends = [e for e in events if e.type == "TOOL_CALL_END"]
                self.assertFalse(ends[0].is_error)


class AFailedChildIsAFailedCall(unittest.TestCase):
    """The gateway's half: a delegated run that failed is not an answer.

    On the same stack every child `fleet_analyst` run failed after answering
    (`no workflow definition named 'summarize_session_window'`), and
    `run_delegated` returned the child's last assistant text regardless, so the
    parent's model was handed `None` as a successful result and delegated 42
    more times in one turn.
    """

    SECRET = "test-only-secret-not-a-production-key"
    CAUSE = "RaiseError: no workflow definition named 'summarize_session_window'"

    def delegate(self, status):
        from contextlib import asynccontextmanager
        from uuid import uuid4

        from percolate_core.agentic import gateway
        from percolate_core.agentic.contracts import Message, Run
        from percolate_core.agentic.sequencer import TurnResult
        from percolate_core.core.identity import mint_jwt

        run_row = Run(status=status, state={"error": self.CAUSE} if status == "failed" else {})

        async def run_turn(self, request, context, **kwargs):
            return TurnResult(run=run_row, session=None,
                              messages=[Message(role="assistant", content="two vessels")])

        @asynccontextmanager
        async def connected(settings, claims):
            yield MemoryRepository()

        headers = {"Authorization": f"Bearer {mint_jwt(str(uuid4()), self.SECRET)}"}
        with patch.dict("os.environ", {"P8_JWT_SECRET": self.SECRET}), \
             patch.object(gateway, "connected", connected), \
             patch.object(TurnSequencer, "run_turn", run_turn):
            return asyncio.run(gateway.run_delegated(
                Settings(), agent_name="fleet_analyst", prompt="which vessels?", headers=headers))

    def test_a_failed_child_raises_with_its_cause(self):
        with self.assertRaises(RuntimeError) as raised:
            self.delegate("failed")
        self.assertIn("finished failed", str(raised.exception))
        self.assertIn(self.CAUSE, str(raised.exception))

    def test_a_succeeded_child_is_its_answer(self):
        self.assertEqual(self.delegate("succeeded"), "two vessels")


if __name__ == "__main__":
    unittest.main()
