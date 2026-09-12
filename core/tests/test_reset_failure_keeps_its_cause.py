"""When a publisher's connection cannot be reset, the reason survives.

`_restore_login_role` puts a publisher's connection back as its login role and,
if that fails, terminates the connection rather than returning it to the pool —
so the next caller cannot inherit somebody else's role and identity. That part
is right and this file does not change it.

What it got wrong is the error path's own error. `conn.terminate()` on a
connection that has ALREADY been released raises `InterfaceError: cannot call
Connection.terminate(): connection has been released back to the pool`, and
that exception replaced the one the handler exists to re-raise.

FOUND BY THE TOUR, and the cost was three layers of wrong diagnosis: two acts
got a 500 whose agent log named only the InterfaceError, so the turn's actual
cause appeared nowhere; and the tour, parsing an error body it expected to be
JSON, aborted each whole act on a Python `TypeError`. The visible symptom was
`'str' object has no attribute 'get'` in a test harness, three removes from a
swallowed exception in a connection-reset handler.

No database: two doubles, because what is under test is which exception comes
out of a handler — a question about control flow, where a live connection would
add a fixture and answer nothing extra.
"""
import unittest

import asyncpg

from percolate_core.agentic.db.client import _restore_login_role


class Boom(Exception):
    """The original failure — what a caller needs to be told."""


class ResetFails:
    """A connection whose reset fails and which can still be terminated."""

    def __init__(self):
        self.terminated = False

    async def execute(self, sql, *args):
        raise Boom("reset role: server closed the connection unexpectedly")

    def terminate(self):
        self.terminated = True


class ResetFailsAndIsAlreadyReleased(ResetFails):
    """The case from the tour: the connection is gone before we get here.

    asyncpg raises from `terminate()` itself, so the handler's own cleanup is
    what throws.
    """

    def terminate(self):
        raise asyncpg.InterfaceError(
            "cannot call Connection.terminate(): connection has been released "
            "back to the pool"
        )


class Healthy:
    def __init__(self):
        self.statements = []
        self.terminated = False

    async def execute(self, sql, *args):
        self.statements.append(sql)

    def terminate(self):
        self.terminated = True


class ResetFailureKeepsItsCauseTest(unittest.IsolatedAsyncioTestCase):
    async def test_a_healthy_connection_is_reset_and_not_terminated(self):
        """The control. Without it, "nothing is terminated" proves nothing."""
        conn = Healthy()
        await _restore_login_role(conn)
        self.assertFalse(conn.terminated)
        self.assertEqual(len(conn.statements), 2, conn.statements)
        # `reset role` FIRST: any role may run it, and only the login role may
        # then clear the claims. The order is the rule, not the sequence.
        self.assertEqual(conn.statements[0], "reset role")
        self.assertIn("request.jwt.claims", conn.statements[1])

    async def test_a_failed_reset_still_terminates_the_connection(self):
        """The guarantee this function exists for is unchanged.

        A connection that cannot be proven reset must not go back to the pool
        carrying somebody else's role.
        """
        conn = ResetFails()
        with self.assertRaises(Boom):
            await _restore_login_role(conn)
        self.assertTrue(conn.terminated, "a connection that failed to reset was pooled")

    async def test_the_cause_survives_a_terminate_that_cannot_run(self):
        """The defect: the handler's own cleanup replaced the diagnosis.

        `Boom` is what the caller must see. Before this fix the InterfaceError
        from `terminate()` came out instead, and the reason the turn failed was
        gone.
        """
        conn = ResetFailsAndIsAlreadyReleased()
        with self.assertRaises(Boom):
            await _restore_login_role(conn)

    async def test_the_replacement_exception_is_not_what_comes_out(self):
        """Stated the other way round, because the two are easy to conflate.

        Asserting `Boom` is raised does not by itself say the InterfaceError is
        gone — a handler that raised both in sequence, or chained them the wrong
        way, would satisfy the test above.
        """
        conn = ResetFailsAndIsAlreadyReleased()
        try:
            await _restore_login_role(conn)
        except asyncpg.InterfaceError:  # pragma: no cover - the defect
            self.fail(
                "the InterfaceError from terminate() reached the caller, so the "
                "reason the reset failed was replaced by the reason the cleanup "
                "failed"
            )
        except Boom:
            pass


if __name__ == "__main__":
    unittest.main()
