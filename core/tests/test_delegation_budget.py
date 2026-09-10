"""The delegation tree spends one budget, not one per level.

`tests/smoke.py` argues that the checks worth keeping are the ones protecting a
STATED guarantee. The guarantee here is pydantic-ai's, quoted in
`runtime/budget.py`: *"pass ctx.usage to the usage keyword argument of the
delegate agent run so usage within that run counts towards the total usage of
the parent agent run."* Our delegate is an HTTP hop away, so the object is
serialised instead -- and a serialisation is exactly the kind of thing that
works on the day it is written and silently stops when a field is renamed.

So these are about the join, not about arithmetic:

  * a child seeded from a parent's headers starts already charged
  * a limit set at the root is still the limit three levels down
  * the fields that cross the wire are fields `RunUsage` and `UsageLimits`
    actually have -- the check that catches a pydantic-ai rename, which is the
    failure this whole file exists for
  * a malformed header degrades to unbudgeted rather than failing the run

Run: python -m unittest discover -s tests -p test_delegation_budget.py
"""

from __future__ import annotations

import json
import os
import unittest

from percolate_core.agentic.runtime.budget import (
    BUDGET_HEADER,
    USAGE_HEADER,
    Budget,
    usage_dict,
)


class FakeUsage:
    """Stands in for `RunUsage` where only the numbers matter."""

    def __init__(self, **kw):
        self.input_tokens = kw.get("input_tokens", 0)
        self.output_tokens = kw.get("output_tokens", 0)
        self.requests = kw.get("requests", 0)
        self.tool_calls = kw.get("tool_calls", 0)
        self.cost = kw.get("cost", 0)


class BudgetCrossesTheWire(unittest.TestCase):
    def test_child_starts_charged_for_its_ancestors(self):
        """The whole point: a child does not begin at zero."""
        parent = Budget(limits={"total_tokens_limit": 10_000})
        headers = parent.to_headers(FakeUsage(input_tokens=700, output_tokens=300))

        child = Budget.from_headers(headers)

        self.assertEqual(child.spent["input_tokens"], 700)
        self.assertEqual(child.spent["output_tokens"], 300)
        self.assertEqual(child.limits["total_tokens_limit"], 10_000)

    def test_spend_accumulates_down_the_tree(self):
        """A grandchild is charged for its grandparent too."""
        root = Budget(limits={"total_tokens_limit": 10_000})
        child = Budget.from_headers(root.to_headers(FakeUsage(input_tokens=400)))
        grandchild = Budget.from_headers(
            child.to_headers(FakeUsage(input_tokens=600))
        )

        self.assertEqual(grandchild.spent["input_tokens"], 1000)

    def test_the_limit_survives_every_hop(self):
        budget = Budget(limits={"request_limit": 5})
        for _ in range(3):
            budget = Budget.from_headers(budget.to_headers(FakeUsage(requests=1)))
        self.assertEqual(budget.limits["request_limit"], 5)
        self.assertEqual(budget.spent["requests"], 3)

    def test_charge_accumulates_within_one_run(self):
        """Turn-by-turn accumulation, which is what the sequencer does."""
        budget = Budget(limits={"request_limit": 5})
        budget = budget.charge({"input_tokens": 100, "requests": 1})
        budget = budget.charge({"input_tokens": 50, "requests": 1})
        self.assertEqual(budget.spent, {"input_tokens": 150, "requests": 2})
        self.assertEqual(budget.limits, {"request_limit": 5})


class TheContractWithPydanticAI(unittest.TestCase):
    """The checks that fail when pydantic-ai renames something.

    A serialised budget is a hand-written mapping onto somebody else's field
    names. `RunUsage` has already gained `cache_write_tokens`,
    `cache_audio_read_tokens` and `tool_calls` across versions this package has
    shipped against; the day one of the names we send is gone, the header still
    serialises, the child still parses it, and the budget silently stops
    binding. These turn that into a red test.
    """

    def test_every_usage_field_we_send_exists_on_RunUsage(self):
        from pydantic_ai.usage import RunUsage

        fields = set(RunUsage.__dataclass_fields__)
        sent = set(usage_dict(FakeUsage(input_tokens=1, output_tokens=1,
                                        requests=1, tool_calls=1, cost=1)))
        missing = sent - fields
        self.assertEqual(
            missing, set(), f"budget.py sends fields RunUsage no longer has: {missing}"
        )

    def test_every_limit_field_we_accept_exists_on_UsageLimits(self):
        from pydantic_ai.usage import UsageLimits

        fields = set(UsageLimits.__dataclass_fields__)
        # The full set budget.py is willing to forward.
        ours = {
            "request_limit",
            "tool_calls_limit",
            "input_tokens_limit",
            "output_tokens_limit",
            "total_tokens_limit",
            "cost_limit",
        }
        missing = ours - fields
        self.assertEqual(
            missing, set(), f"budget.py forwards limits UsageLimits lacks: {missing}"
        )

    def test_seeded_usage_is_a_real_RunUsage(self):
        from pydantic_ai.usage import RunUsage

        seeded = Budget(spent={"input_tokens": 42, "requests": 2}).seed_usage()
        self.assertIsInstance(seeded, RunUsage)
        self.assertEqual(seeded.input_tokens, 42)
        self.assertEqual(seeded.requests, 2)

    def test_limits_become_a_real_UsageLimits(self):
        from pydantic_ai.usage import UsageLimits

        limits = Budget(limits={"total_tokens_limit": 99}).usage_limits()
        self.assertIsInstance(limits, UsageLimits)
        self.assertEqual(limits.total_tokens_limit, 99)


class DegradesRatherThanFails(unittest.TestCase):
    """An accounting header must not be able to cause an outage."""

    def test_malformed_headers_are_ignored(self):
        for bad in ("{not json", "", "[]", "null", "12"):
            budget = Budget.from_headers({USAGE_HEADER: bad, BUDGET_HEADER: bad})
            self.assertIsNone(budget.spent, f"{bad!r} should not parse")
            self.assertIsNone(budget.limits, f"{bad!r} should not parse")

    def test_no_headers_means_a_root_run(self):
        budget = Budget.from_headers({})
        self.assertIsNone(budget.spent)
        self.assertIsNone(budget.limits)
        self.assertIsNone(budget.usage_limits())
        self.assertIsNone(budget.seed_usage())

    def test_unknown_limit_names_are_dropped_not_passed_through(self):
        """A limit `UsageLimits` does not have must not reach its constructor.

        Otherwise a newer parent sending a limit an older child cannot construct
        turns a rolling deploy into a TypeError on the delegate.
        """
        budget = Budget(limits={"total_tokens_limit": 5, "invented_limit": 1})
        limits = budget.usage_limits()
        self.assertEqual(limits.total_tokens_limit, 5)
        self.assertFalse(hasattr(limits, "invented_limit"))

    def test_usage_dict_survives_a_usage_object_missing_fields(self):
        class Sparse:
            input_tokens = 5

        self.assertEqual(usage_dict(Sparse()), {"input_tokens": 5})
        self.assertEqual(usage_dict(None), {})


class OffUnlessConfigured(unittest.TestCase):
    """No budget is invented for a deployment that did not ask for one."""

    def setUp(self):
        self._saved = {
            k: os.environ.pop(k, None)
            for k in (
                "P8_TREE_REQUEST_LIMIT",
                "P8_TREE_TOOL_CALLS_LIMIT",
                "P8_TREE_TOTAL_TOKENS_LIMIT",
                "P8_TREE_COST_LIMIT",
            )
        }

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_unset_means_unlimited(self):
        self.assertIsNone(Budget.from_env().limits)
        self.assertIsNone(Budget.from_env().usage_limits())

    def test_set_means_limited(self):
        os.environ["P8_TREE_TOTAL_TOKENS_LIMIT"] = "1234"
        os.environ["P8_TREE_COST_LIMIT"] = "0.50"
        budget = Budget.from_env()
        self.assertEqual(budget.limits["total_tokens_limit"], 1234)
        self.assertEqual(budget.limits["cost_limit"], 0.50)

    def test_nonsense_env_is_ignored_not_fatal(self):
        os.environ["P8_TREE_TOTAL_TOKENS_LIMIT"] = "lots"
        self.assertIsNone(Budget.from_env().limits)


class HeadersAreCompact(unittest.TestCase):
    def test_only_budgeted_fields_cross_the_wire(self):
        """`RunUsage.details` is provider-specific and unbounded; keep it out."""
        headers = Budget().to_headers(FakeUsage(input_tokens=1))
        payload = json.loads(headers[USAGE_HEADER])
        self.assertEqual(set(payload), {"input_tokens"})

    def test_zero_usage_sends_no_header(self):
        self.assertEqual(Budget().to_headers(FakeUsage()), {})


if __name__ == "__main__":
    unittest.main()
