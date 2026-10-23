"""The shipped worker tells claim_task it can run a dry run's task (REM-1125).

claim_task hands a dry run's task only to a caller that lists 'dry_run', because a runtime that predates the flag
would make the real call. This worker lists it, since its runtime ships in the same image; against a database from
before the capabilities argument, it asks the two-argument form, which has no dry runs to hand out.
"""

from __future__ import annotations

import asyncio
import unittest
from contextlib import asynccontextmanager
from unittest import mock

from percolate_core.worker import loop


class _Conn:
    def __init__(self, calls: list, has_capabilities: bool):
        self.calls = calls
        self.has_capabilities = has_capabilities

    async def fetchval(self, sql: str, *args):
        if "to_regprocedure('workflow.claim_task(text,text,text[])')" in sql:
            return self.has_capabilities
        if "claim_task" in sql:
            self.calls.append((sql, args))
            return None  # an empty queue: run_once stops here
        raise AssertionError(f"unexpected query: {sql}")


def _claims(has_capabilities: bool) -> list:
    calls: list = []

    @asynccontextmanager
    async def as_service(*a, **kw):
        yield _Conn(calls, has_capabilities)

    with mock.patch.object(loop, "as_service", as_service):
        did = asyncio.run(loop.run_once("q-dry", "w-dry"))
    assert did is False
    return calls


class AWorkerDeclaresItCanRunADryRun(unittest.TestCase):
    def test_it_lists_dry_run_when_the_database_takes_capabilities(self):
        [(sql, args)] = _claims(True)
        self.assertIn("claim_task($1, $2, $3::text[])", sql)
        self.assertEqual(args, ("q-dry", "w-dry", ["dry_run"]))

    def test_an_older_database_is_asked_the_two_argument_form(self):
        [(sql, args)] = _claims(False)
        self.assertIn("claim_task($1, $2))", sql)
        self.assertEqual(args, ("q-dry", "w-dry"))


if __name__ == "__main__":
    unittest.main()
