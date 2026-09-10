"""The engine captures what a turn spent, and a limit actually stops a run.

The budget tests next door check the serialisation. These check the wiring, on
a real `pydantic_ai.Agent` driven by `FunctionModel`, because the two failures
worth catching here are both invisible to a unit test of our own objects:

  * `result.usage` moved from a METHOD to an ATTRIBUTE between 2.36 and 2.42.
    A runtime reading it the old way gets a TypeError on a turn whose model call
    already succeeded and whose deltas already reached the client -- a completed
    turn reported as failed. `engine._usage_of` handles either; this is what
    says so on the version actually installed.
  * `usage_limits` being accepted and quietly ignored looks exactly like a
    limit that was never hit.

Run: python -m unittest discover -s tests -p test_engine_usage.py
"""

from __future__ import annotations

import asyncio
import unittest

from pydantic_ai import Agent
from pydantic_ai.messages import ModelResponse, TextPart
from pydantic_ai.models.function import FunctionModel

from percolate_core.agentic.runtime.budget import Budget
from percolate_core.agentic.runtime.engine import AgentEngine, _usage_of


def _model() -> FunctionModel:
    def respond(messages, info):
        return ModelResponse(parts=[TextPart("ok")])

    async def stream(messages, info):
        yield "ok"

    return FunctionModel(respond, stream_function=stream)


class _Run:
    """The two ids the engine forwards to pydantic-ai."""

    def __init__(self, run_id="11111111-1111-1111-1111-111111111111",
                 session_id="22222222-2222-2222-2222-222222222222"):
        self.id = run_id
        self.session_id = session_id
        self.agent_name = "tester"
        self.parent_run_id = None
        self.depth = 0
        self.trace_id = None


def _execute(**kwargs):
    engine = AgentEngine.__new__(AgentEngine)  # no Settings needed for execute()
    agent = Agent(_model())
    return asyncio.run(engine.execute(agent, "hi", [], None, **kwargs))


class UsageIsCaptured(unittest.TestCase):
    def test_a_turn_records_what_it_spent(self):
        """`ExecutionResult.usage` was declared and never written."""
        result = _execute()
        self.assertTrue(
            result.usage,
            "the engine returned no usage; ExecutionResult.usage is unwritten again",
        )
        self.assertIn("requests", result.usage)
        self.assertGreaterEqual(result.usage["requests"], 1)

    def test_usage_accessor_works_whichever_shape_it_has(self):
        """The 2.36-to-2.42 method/attribute change, pinned."""

        class AsAttribute:
            usage = "sentinel"

        class AsMethod:
            def usage(self):
                return "sentinel"

        class Raises:
            def usage(self):
                raise RuntimeError("moved again")

        self.assertEqual(_usage_of(AsAttribute()), "sentinel")
        self.assertEqual(_usage_of(AsMethod()), "sentinel")
        self.assertIsNone(_usage_of(Raises()))
        self.assertIsNone(_usage_of(object()))

    def test_ids_are_accepted_by_the_installed_pydantic_ai(self):
        """`run_id`/`conversation_id` are what join a span to a row.

        If either is dropped from `Agent.run`, this raises TypeError here rather
        than producing traces that silently no longer correlate.
        """
        result = _execute(run=_Run())
        self.assertEqual(result.text, "ok")


class LimitsBind(unittest.TestCase):
    def test_a_seeded_budget_already_over_its_limit_stops_the_run(self):
        """The delegation guarantee, end to end.

        A child seeded with its ancestors' spend and handed the tree's limit
        must refuse -- that is the entire reason the budget crosses the wire. If
        `usage=` or `usage_limits=` stopped being forwarded, this run would
        happily succeed.
        """
        from pydantic_ai.exceptions import UsageLimitExceeded

        budget = Budget(
            limits={"total_tokens_limit": 100},
            spent={"input_tokens": 90, "output_tokens": 50},
        )
        with self.assertRaises(UsageLimitExceeded):
            _execute(budget=budget)

    def test_the_same_run_succeeds_with_room_left(self):
        """The control: it is the budget stopping it, not the fixture."""
        budget = Budget(
            limits={"total_tokens_limit": 100_000},
            spent={"input_tokens": 90, "output_tokens": 50},
        )
        result = _execute(budget=budget)
        self.assertEqual(result.text, "ok")

    def test_an_unbudgeted_run_is_unaffected(self):
        result = _execute(budget=Budget())
        self.assertEqual(result.text, "ok")

    def test_a_request_limit_binds_across_the_hop(self):
        """A tree that has already made its allowed requests cannot make more."""
        from pydantic_ai.exceptions import UsageLimitExceeded

        parent = Budget(limits={"request_limit": 1})

        class Spent:
            input_tokens = output_tokens = tool_calls = cost = 0
            requests = 1

        child = Budget.from_headers(parent.to_headers(Spent()))
        with self.assertRaises(UsageLimitExceeded):
            _execute(budget=child)


class ContextWindowIsMeasured(unittest.TestCase):
    """brief.md §9's "message count vs. token estimate", now the library's job."""

    def test_the_field_exists_on_the_run_context(self):
        """What `needs_summarization` depends on, checked against the install.

        The value is None for FunctionModel, which declares no context window --
        that is the documented behaviour and why the summarizer treats None as
        "no opinion" rather than as zero. What must not change is the attribute.
        """
        from pydantic_ai.tools import RunContext

        self.assertIn(
            "context_window_used",
            dir(RunContext),
            "RunContext.context_window_used is gone; "
            "persistence.needs_summarization silently loses its token trigger",
        )

    def test_execution_result_carries_it(self):
        result = _execute()
        self.assertTrue(hasattr(result, "context_window_used"))


class SummarizerTrigger(unittest.IsolatedAsyncioTestCase):
    """Either signal fires it, and neither masks the other."""

    def _adapter(self, count: int, threshold: int, fraction: float):
        from percolate_core.agentic.runtime.persistence import PersistenceAdapter

        adapter = PersistenceAdapter.__new__(PersistenceAdapter)

        class Repo:
            async def message_count(self, _sid):
                return count

        class Policy:
            summarize_after_messages = None

        class Spec:
            context_policy = Policy()

        class Settings:
            summarize_after_messages = threshold
            summarize_at_context_fraction = fraction

        adapter.repo = Repo()
        adapter.settings = Settings()
        return adapter, Spec()

    async def test_message_count_still_fires_it(self):
        adapter, spec = self._adapter(count=50, threshold=20, fraction=0.75)
        self.assertTrue(await adapter.needs_summarization("s", spec, None))

    async def test_a_full_context_fires_it_below_the_message_count(self):
        adapter, spec = self._adapter(count=2, threshold=20, fraction=0.75)
        self.assertTrue(await adapter.needs_summarization("s", spec, 0.9))

    async def test_a_roomy_context_and_few_messages_does_not(self):
        adapter, spec = self._adapter(count=2, threshold=20, fraction=0.75)
        self.assertFalse(await adapter.needs_summarization("s", spec, 0.1))

    async def test_no_estimate_falls_back_to_the_count(self):
        """A model with no declared window must not disable the trigger."""
        adapter, spec = self._adapter(count=2, threshold=20, fraction=0.75)
        self.assertFalse(await adapter.needs_summarization("s", spec, None))
        adapter, spec = self._adapter(count=99, threshold=20, fraction=0.75)
        self.assertTrue(await adapter.needs_summarization("s", spec, None))


if __name__ == "__main__":
    unittest.main()
