"""The quota gate asks core, and refuses a database that has quota policy but no way to check it (REM-174).

`check_quota` runs before every model call. It used to allow every call when
`rbac.has_quota_remaining` was missing, so a database that had plans and limits
but a broken function would spend with no check at all.
"""
import asyncio
import unittest
from contextlib import asynccontextmanager
from uuid import uuid4

from percolate_core.agentic.db.repository import PgRepository


class Catalogue:
    """A database as the gate sees it: which objects exist, and what core would answer."""

    def __init__(self, decides: bool, has_policy: bool, answer: bool = True) -> None:
        self.decides, self.has_policy, self.answer = decides, has_policy, answer
        self.calls: list[tuple] = []

    async def fetchrow(self, sql, *args):
        assert "to_regprocedure" in sql and "to_regclass" in sql, sql
        return {"decides": self.decides, "has_policy": self.has_policy}

    async def fetchval(self, sql, *args):
        assert sql.startswith("select rbac.has_quota_remaining"), sql
        self.calls.append(args)
        return self.answer


class Client:
    def __init__(self, conn: Catalogue) -> None:
        self.conn = conn

    @asynccontextmanager
    async def as_user(self, claims):
        yield self.conn


def gate(conn: Catalogue) -> bool:
    return asyncio.run(PgRepository(Client(conn), {"sub": str(uuid4())}).has_quota_remaining(uuid4(), "llm_tokens"))


class QuotaGate(unittest.TestCase):
    def test_core_decides_when_it_can(self):
        denied = Catalogue(decides=True, has_policy=True, answer=False)
        self.assertFalse(gate(denied))
        self.assertEqual(len(denied.calls), 1)
        self.assertTrue(gate(Catalogue(decides=True, has_policy=True, answer=True)))

    def test_a_database_that_predates_quota_policy_allows(self):
        self.assertTrue(gate(Catalogue(decides=False, has_policy=False)))

    def test_policy_without_the_check_refuses(self):
        with self.assertLogs("percolate_core.agentic.db.repository", level="ERROR"):
            self.assertFalse(gate(Catalogue(decides=False, has_policy=True)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
