"""A runtime that cannot open a session refuses at startup, not per turn.

REM-136. A percolate-core pointed at a database it cannot serve used to start,
report healthy, and fail inside the first turn -- and fail *in band*: AG-UI
answers HTTP 200 with a well-formed stream carrying one `RUN_ERROR`, so
`docker compose ps` calls the container healthy and every watchdog agrees with
it. REM-10 found the live instance only by asserting on the events inside the
stream. The live pair is REM-135: a runtime older than 0.1.9 writes the role
before the claims, and a 0.2.0 database refuses `set_config` to `authenticated`,
so no turn opens a session at all.

WHAT THIS CANNOT DO, stated here as well as in the docstring because a test
file is where somebody checks what is covered: a check that ships in 0.1.9 does
not run in 0.1.8, so the REM-135 pairing itself is not caught by this and never
will be. The cure for an already-published runtime is not to pair it (REM-135). What is under test here is that the NEXT such
pairing is loud.

No database: the pool is a double, which is `test_caller_identity.py`'s idiom
and the right one here -- what these prove is what the runtime does with the
answer it gets, and "a database that refuses" is a one-line double where it is
a whole fixture to arrange for real.
"""
import asyncio
import unittest
from contextlib import asynccontextmanager

import asyncpg

from percolate_core.core import identity


class RefusingConn:
    """A connection that refuses one statement, the way a 0.2.0 database does.

    `refuse_on` is matched as a substring rather than by equality: the statement
    `as_caller` runs carries a parameter placeholder and whitespace this file
    should not have to reproduce, and a double that only matches an exact string
    is a double that silently stops refusing the day somebody reformats the
    query it is standing in for.
    """

    def __init__(self, refuse_on: str | None):
        self.refuse_on = refuse_on
        self.statements: list[str] = []

    async def execute(self, sql, *args):
        self.statements.append(sql)
        if self.refuse_on and self.refuse_on in sql:
            raise asyncpg.InsufficientPrivilegeError(
                "permission denied for function set_config"
            )

    def transaction(self):
        @asynccontextmanager
        async def tx():
            yield
        return tx()


class RefusingPool:
    def __init__(self, refuse_on: str | None):
        self.conn = RefusingConn(refuse_on)

    def acquire(self, *, timeout=None):
        @asynccontextmanager
        async def held():
            yield self.conn
        return held()


class StartupProbeTest(unittest.IsolatedAsyncioTestCase):
    def use(self, refuse_on):
        pool = RefusingPool(refuse_on)
        identity.set_pool(pool)
        self.addCleanup(identity.set_pool, None)
        return pool

    async def test_a_database_that_serves_this_runtime_is_not_refused(self):
        """The control, and without it every assertion below is free.

        A probe that refused everything would pass all the negative cases in
        this file and take the whole deployment down with it.
        """
        pool = self.use(None)
        await identity.verify_can_open_a_session()
        self.assertEqual(len(pool.conn.statements), 2, pool.conn.statements)

    async def test_it_probes_by_doing_the_thing_not_by_reading_a_version(self):
        """Capability, not `extversion` -- the `agent_document.py` precedent.

        The two statements are the ones `as_caller` runs, in its order: a
        version comparison would need a table of which pairs work, which is a
        second home for a fact the database already enforces, and it answers
        wrongly for a database upgraded in place where `pg_extension.extversion`
        has been known to lag what is installed.
        """
        pool = self.use(None)
        await identity.verify_can_open_a_session()
        first, second = pool.conn.statements
        self.assertIn("set_config('request.jwt.claims'", first)
        self.assertTrue(second.startswith("set local role"), second)
        self.assertNotIn("extversion", " ".join(pool.conn.statements))

    async def test_a_database_that_refuses_set_config_stops_startup(self):
        """MADE TO FAIL ON PURPOSE -- the clause this file exists for.

        A test that only ever sees a working database cannot tell a probe from
        a `pass`. This is the shape of the refusal a 0.2.0 database gives a
        runtime that asks in the wrong order.
        """
        self.use("set_config")
        with self.assertRaises(RuntimeError) as caught:
            await identity.verify_can_open_a_session()
        self.assertIn("cannot open a session", str(caught.exception))

    async def test_the_refusal_names_a_remedy_rather_than_a_stack_trace(self):
        """The person who sees this is deploying, not debugging.

        Each of the three arms is a different thing to go and do, and which one
        applies is not knowable from here -- so all three are named rather than
        one guessed at. Asserted because a message is the entire product of this
        function and nothing else would notice it rotting.
        """
        self.use("set_config")
        with self.assertRaises(RuntimeError) as caught:
            await identity.verify_can_open_a_session()
        message = str(caught.exception)
        self.assertIn("upgrade the runtime", message)
        self.assertIn("alter extension percolate update", message)
        self.assertIn("P8_ROLE", message)
        # And it repeats what Postgres said, so the reader is not told to
        # reproduce it themselves.
        self.assertIn("permission denied for function set_config", message)

    async def test_a_failure_that_is_not_about_compatibility_is_left_alone(self):
        """A database that is down is not a version mismatch.

        Reporting one as the other sends somebody to upgrade a runtime that is
        fine. Only `InsufficientPrivilegeError` is translated; everything else
        propagates as itself, which is why this asserts on the original type
        rather than on a message.
        """

        class Down(RefusingConn):
            async def execute(self, sql, *args):
                raise asyncpg.PostgresConnectionError("the database is not there")

        pool = RefusingPool(None)
        pool.conn = Down(None)
        identity.set_pool(pool)
        self.addCleanup(identity.set_pool, None)

        with self.assertRaises(asyncpg.PostgresConnectionError):
            await identity.verify_can_open_a_session()


class LifespanRefusesTest(unittest.IsolatedAsyncioTestCase):
    """The probe is wired into startup, not merely available to be called.

    A function nothing calls is the state this issue is about -- `banned.py`
    works, is documented, and is wired to nothing. So the wiring is asserted,
    not just the function.
    """

    async def test_the_agent_lifespan_refuses_before_it_yields(self):
        from fastapi import FastAPI

        from percolate_core.agentic import api

        seen = {}

        async def refuse():
            seen["called"] = True
            raise RuntimeError("cannot open a session as `authenticated`")

        class FakeClient:
            def __init__(self, settings):
                pass

            async def connect(self):
                seen["connected"] = True

            async def close(self):
                seen["closed"] = True

        served = False
        original_client, original_verify = api.PgClient, api.identity.verify_can_open_a_session
        api.PgClient = FakeClient
        api.identity.verify_can_open_a_session = lambda *a, **k: refuse()
        try:
            with self.assertRaises(RuntimeError):
                async with api.lifespan(FastAPI(), settings=_settings()):
                    served = True
        finally:
            api.PgClient = original_client
            api.identity.verify_can_open_a_session = original_verify

        self.assertTrue(seen.get("connected"), "the probe ran before the pool opened")
        self.assertTrue(seen.get("called"), "startup did not probe at all")
        self.assertFalse(served, "the app served requests despite the refusal")


def _settings():
    from percolate_core.agentic.settings import Settings

    return Settings(database_url="postgres://p8:p8@localhost:5432/nowhere")


if __name__ == "__main__":
    unittest.main()
