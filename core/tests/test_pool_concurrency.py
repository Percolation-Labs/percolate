"""Eight people can hold a conversation at once.

REM-110. A turn holds one connection for its whole life --
`db.client.PgClient.publisher`, so that a sixty-word answer is not sixty
transactions -- and takes a SECOND one for every query inside it. So a turn
needs two connections concurrently, and `P8_POOL_MAX` at its old default of 8
supported four turns while reading like eight. At eight, each turn held one and
then waited forever for the other: a deadlock by construction, at exactly the
concurrency the number looks like it allows, with no load involved.

No database. `FinitePool` is a pool double with a real semaphore, which is the
one property that matters here -- it can be exhausted, and an unbounded acquire
on an exhausted pool never returns.
"""
import asyncio
import unittest.mock
import unittest
from contextlib import asynccontextmanager

from percolate_core.agentic.settings import Settings
from percolate_core.core import identity


class FinitePool:
    """A pool of `size` connections, and nothing else."""

    def __init__(self, size):
        self.slots = asyncio.Semaphore(size)
        self.size = size
        self.peak = 0
        self._held = 0

    def acquire(self, *, timeout=None):
        @asynccontextmanager
        async def held():
            try:
                await asyncio.wait_for(self.slots.acquire(), timeout)
            except asyncio.TimeoutError:
                raise
            self._held += 1
            self.peak = max(self.peak, self._held)
            try:
                yield FakeConn()
            finally:
                self._held -= 1
                self.slots.release()
        return held()


class FakeConn:
    async def execute(self, *args, **kwargs):
        return "OK"

    async def fetchval(self, *args, **kwargs):
        return None

    def transaction(self):
        @asynccontextmanager
        async def tx():
            yield
        return tx()


class TwoConnectionsPerTurn(unittest.IsolatedAsyncioTestCase):

    async def test_eight_turns_each_taking_two_connections_complete(self):
        """The shape of the deadlock, against a pool sized for it."""
        pool = FinitePool(16)

        async def turn():
            # The connection the turn holds for its life...
            async with identity.acquired(pool):
                await asyncio.sleep(0)
                # ...and the one every query inside it takes.
                async with identity.acquired(pool):
                    await asyncio.sleep(0)
            return True

        done = await asyncio.wait_for(
            asyncio.gather(*(turn() for _ in range(8))), timeout=5)
        self.assertEqual(done, [True] * 8)
        self.assertLessEqual(pool.peak, 16)
        self.assertGreater(pool.peak, 8, "two per turn, so more than eight were live")

    async def test_the_same_eight_turns_against_the_old_size_fail_instead_of_hanging(self):
        """THE CONTROL, and the reason the timeout matters more than the number.

        A pool of 8 cannot serve eight two-connection turns. Before this, the
        second acquire waited forever and the process wedged with no error. Now
        it raises, in bounded time, and the message carries the arithmetic --
        which is the difference between an afternoon and a minute.
        """
        pool = FinitePool(8)

        async def turn():
            async with identity.acquired(pool):
                await asyncio.sleep(0.05)
                async with identity.acquired(pool):
                    return True

        # The acquire timeout has to be shorter than this test's own guard, or
        # the guard fires first and the failure says "timeout" rather than
        # saying why -- which is the whole thing being asserted.
        with unittest.mock.patch.dict(
                "os.environ", {"P8_POOL_ACQUIRE_SECONDS": "0.2"}, clear=False):
            with self.assertRaises(RuntimeError) as caught:
                await asyncio.wait_for(
                    asyncio.gather(*(turn() for _ in range(8))), timeout=5)
        message = str(caught.exception)
        self.assertIn("P8_POOL_MAX", message)
        self.assertIn("TWICE", message)

    async def test_the_wait_is_bounded_and_configurable(self):
        pool = FinitePool(1)

        async def hold():
            async with identity.acquired(pool):
                await asyncio.sleep(1)

        with unittest.mock.patch.dict(
                "os.environ", {"P8_POOL_ACQUIRE_SECONDS": "0.05"}, clear=False):
            holder = asyncio.create_task(hold())
            await asyncio.sleep(0)
            with self.assertRaises(RuntimeError):
                async with identity.acquired(pool):
                    pass
            holder.cancel()


class TheBudgetIsStated(unittest.TestCase):

    def test_the_pool_default_is_two_per_turn(self):
        self.assertEqual(Settings().pool_max, 16)

    def test_the_process_budget_is_written_down_where_the_number_is(self):
        """A number without its arithmetic is a number somebody will halve.

        `max_listeners` connections live OUTSIDE the pool -- a stream that went
        back to the pool would stop listening -- so one process can want
        `max_listeners + pool_max` backends. Postgres defaults
        `max_connections` to 100 and reserves 3, so two of these processes do
        not fit a default database.
        """
        import pathlib

        import percolate_core.agentic.settings as module

        text = pathlib.Path(module.__file__).read_text()
        self.assertIn("max_connections", text)
        self.assertIn("max_listeners", text)


if __name__ == "__main__":
    unittest.main()
