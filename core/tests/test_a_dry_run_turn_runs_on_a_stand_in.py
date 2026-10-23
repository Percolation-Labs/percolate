"""A dry-run turn runs on a free stand-in model, with no tools, and counts what it spent (REM-1125).

A workflow is estimated before it spends by running its agent steps once on pydantic-ai's
TestModel: free, minimal schema-valid output, no tool calls. The flag reaches the turn as
`dry_run` on the request; this file holds the turn to it. The agent here names a model whose
provider has no key in this process, so a turn that reached the real model would fail.

Run: python -m unittest discover -s tests -p test_a_dry_run_turn_runs_on_a_stand_in.py
"""
from __future__ import annotations

import asyncio
import os
import unittest
from unittest.mock import patch

from percolate_core.agentic import authoring
from percolate_core.agentic.contracts import ChatRequest, InboundMessage, RequestContext
from percolate_core.agentic.sequencer import TurnSequencer, dry_run_overrides
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository

DOC = {"type": "object", "name": "reader", "description": "Read and answer.",
       "properties": {"verdict": {"type": "string"}}, "required": ["verdict"]}


def request(**kw) -> ChatRequest:
    return ChatRequest(model="reader", messages=[InboundMessage(role="user", content="read this")], **kw)


class DryRun(unittest.TestCase):
    def test_a_turn_that_is_not_a_dry_run_is_untouched(self):
        req = request()
        self.assertEqual(dry_run_overrides(req, False), (req, None))

    def test_a_dry_run_is_a_stand_in_model_with_tools_off(self):
        from pydantic_ai.models.test import TestModel
        req, model = dry_run_overrides(request(dry_run=True), True)
        self.assertIsInstance(model, TestModel)
        self.assertEqual(model.call_tools, [])
        self.assertEqual((req.tool_choice, req.dry_run), ("none", True))

    def test_a_dry_run_turn_finishes_without_the_real_model_and_counts_its_usage(self):
        async def go():
            repo = MemoryRepository()
            agent = authoring.from_json_schema(DOC)
            await repo.upsert_agent(agent.model_copy(update={"model": "openai:gpt-4o"}))
            req, stand_in = dry_run_overrides(request(dry_run=True), True)
            return await TurnSequencer(repo, Settings.from_env()).run_turn(req, RequestContext(tenant="t"), model=stand_in)

        with patch.dict(os.environ, {"OPENAI_API_KEY": ""}):
            result = asyncio.run(go())
        self.assertEqual(result.run.status, "succeeded")
        usage = dict(result.execution.usage)
        self.assertGreaterEqual(usage.get("requests", 0), 1)
        self.assertGreater(usage.get("input_tokens", 0), 0)


if __name__ == "__main__":
    unittest.main()
