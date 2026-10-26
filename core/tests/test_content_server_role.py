"""The Content Server registers bytes as its own role where the cluster has it (REM-1118).

The database binds a file's bucket and key only for `content_server`, because only the
Content Server has read the bytes whose checksum it registers. A cluster made before
the role existed lacks it until an operator creates it, and uploads there must keep
working as `authenticated` meanwhile.

No database: the pool answers the one question content_role asks.
"""
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

from percolate_core.core import identity


class Pool:
    def __init__(self, has_role):
        self.has_role, self.asked = has_role, []

    @asynccontextmanager
    async def acquire(self):
        pool = self

        class Conn:
            async def fetchval(self, sql, *args):
                pool.asked.append(args)
                return pool.has_role

        yield Conn()


class ContentRoleTest(unittest.IsolatedAsyncioTestCase):
    def use(self, has_role):
        pool = Pool(has_role)
        self.addCleanup(setattr, identity, "_CONTENT_ROLE", None)
        identity._CONTENT_ROLE = None
        p = [patch.object(identity, "pool", new=lambda *a, **k: _async(pool)),
             patch.object(identity, "acquired", new=lambda p: p.acquire())]
        for x in p:
            x.start()
            self.addCleanup(x.stop)
        return pool

    async def test_a_cluster_with_the_role_registers_as_it(self):
        pool = self.use(True)
        self.assertEqual(await identity.content_role(), "content_server")
        self.assertEqual(pool.asked, [("content_server",)])

    async def test_a_cluster_without_it_keeps_uploading_as_the_person(self):
        self.use(False)
        self.assertEqual(await identity.content_role(), identity.ROLE)

    async def test_it_is_asked_once(self):
        pool = self.use(True)
        await identity.content_role()
        await identity.content_role()
        self.assertEqual(len(pool.asked), 1)


async def _async(value):
    return value


if __name__ == "__main__":
    unittest.main()
