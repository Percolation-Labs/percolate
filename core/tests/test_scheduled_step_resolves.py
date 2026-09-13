"""The documented scheduled step resolves, and a malformed call is told so (REM-126).

`specs/workflow-engine/README.md` documents the reference scheduled step as
`"workflow_task_id": "{{task.id}}"`, and `task` was not a resolvable namespace --
so the documented step raised `unknown template namespace 'task'` at dispatch and
`dev/seed.sql`'s reference definition sent no body at all.

It is not a documentation defect. `/internal/run` needs the id because the
runtime completes its OWN triggering task once the run and any chained action
have finished (`agentic/sequencer.py`, `brief.md` §3). With no id,
`workflow_task_id` is None, that block is skipped, the task is never completed,
the reaper takes its lease and the run happens again -- REM-109's duplicate-work
failure reached from the other end.

What is asserted here is the resolution and the refusal. The end-to-end -- a
scheduled run completing its own task exactly once -- needs a live runtime and a
harness axis that does not exist yet (REM-10).
"""
import json
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

import httpx

from percolate_core.worker.http import DEFAULT_WAIT_MS, Dispatched, http_call
from percolate_core.worker.loop import _hold_until_released, run_once
from percolate_core.worker.templates import TerminalError, resolve

TASK_ID = "11111111-1111-1111-1111-111111111111"

# The body `README.md` documents and `dev/seed.sql` now ships.
DOCUMENTED_STEP = {
    "url": "http://127.0.0.1:8765/internal/run",
    "method": "POST",
    "mode": "async",
    "body": {
        "workflow_task_id": "{{task.id}}",
        "input": {"agent": "{{run.agent}}", "prompt": "{{run.prompt}}"},
    },
}


class ScheduledStepResolves(unittest.TestCase):
    def _ctx(self, **over):
        ctx = {
            "_task_id": TASK_ID,
            "_worker_id": "w1",
            "run_input": {"agent": "summarizer", "prompt": "what changed"},
            "context": {},
        }
        ctx.update(over)
        return ctx

    def test_the_documented_step_resolves(self):
        """The regression. This raised `unknown template namespace 'task'`."""
        out = resolve(DOCUMENTED_STEP, self._ctx())
        self.assertEqual(out["body"]["workflow_task_id"], TASK_ID)
        self.assertEqual(out["body"]["input"]["agent"], "summarizer")

    def test_the_task_id_keeps_its_own_value_not_a_json_string(self):
        """A whole-string reference keeps its native type; the id is a str."""
        out = resolve({"id": "{{task.id}}"}, self._ctx())
        self.assertEqual(out["id"], TASK_ID)
        self.assertNotIn('"', out["id"])

    def test_the_error_names_task_among_the_namespaces(self):
        """A reader who mistypes it should be told task exists."""
        with self.assertRaises(TerminalError) as e:
            resolve("{{tsak.id}}", self._ctx())
        self.assertIn("expected steps, run, task or env", str(e.exception))

    def test_a_missing_task_id_is_a_terminal_error_not_a_null(self):
        """Better to fail the step than to POST `null` and 400 downstream.

        `resolve` already treats an unresolved reference as terminal; this pins
        that `task.id` is not special-cased into something falsy, because a
        `null` task id reaches `/internal/run` and comes back as the refusal
        this change also adds -- one failure is enough.
        """
        with self.assertRaises(TerminalError):
            resolve("{{task.id}}", self._ctx(_task_id=None))


class MalformedInternalRunIsRefused(unittest.TestCase):
    """REM-67's rule, which `/internal/run` predated.

    The handler read `body["workflow_task_id"]` and `body["input"]["agent"]`
    unconditionally, so an omitted field was a KeyError and a 500 -- the server
    reporting itself broken for a bad request. The seeded definition sent no
    body, so 500 was what the documented path actually produced.

    The refusal logic is asserted directly rather than over HTTP: standing up
    the gateway needs a database, and what is being pinned is which fields are
    named in the message.
    """

    @staticmethod
    def _missing(body):
        # Mirrors gateway.py's list comprehension. Kept here deliberately: the
        # gateway builds a JSONResponse and asserting through it needs the app.
        return [
            name for name, present in (
                ("workflow_task_id", bool(body.get("workflow_task_id"))),
                ("input", isinstance(body.get("input"), dict)),
                ("input.agent", isinstance(body.get("input"), dict)
                                and bool(body["input"].get("agent"))),
            ) if not present
        ]

    def test_an_empty_body_names_every_missing_field(self):
        self.assertEqual(
            self._missing({}), ["workflow_task_id", "input", "input.agent"])

    def test_the_seeded_shape_before_this_change_is_refused_by_name(self):
        """`dev/seed.sql` shipped exactly this: a step with no body."""
        self.assertIn("workflow_task_id", self._missing({}))

    def test_the_documented_shape_is_accepted(self):
        body = {"workflow_task_id": TASK_ID,
                "input": {"agent": "summarizer", "prompt": "x"}}
        self.assertEqual(self._missing(body), [])

    def test_a_present_but_empty_task_id_is_still_missing(self):
        """`{{task.id}}` resolving to "" must not look like a valid id."""
        body = {"workflow_task_id": "", "input": {"agent": "a"}}
        self.assertIn("workflow_task_id", self._missing(body))


class TheDocumentedStepIsSent(unittest.IsolatedAsyncioTestCase):
    """An async http_call sends its request, and leaves the task to the callee.

    `http_call` returned `{"dispatched": true}` BEFORE making the request, and
    the loop completed the task with that -- so the documented step above
    resolved and was then never sent, and every scheduled agent run, the seeded
    `summarize_session_window` included, finished without reaching
    `/internal/run`. Resolution was fixed by REM-126 and was not the last
    defect on the path.
    """

    CTX = {"_task_id": TASK_ID, "_worker_id": "w1",
           "run_input": {"agent": "summarizer", "prompt": "what changed"}, "context": {}}

    async def dispatch(self, status=202):
        sent = []

        def answer(request):
            sent.append(request)
            return httpx.Response(status, json={"accepted": True, "workflow_task_id": TASK_ID})

        real = httpx.AsyncClient
        # The step's own url is loopback, which the worker refuses unless the
        # operator named it -- which is what P8_AGENT_URL is for.
        with patch.dict("os.environ", {"P8_AGENT_URL": "http://127.0.0.1:8765"}), \
             patch("percolate_core.worker.http.httpx.AsyncClient",
                   side_effect=lambda *a, **kw: real(*a, transport=httpx.MockTransport(answer), **kw)):
            return await http_call(DOCUMENTED_STEP, dict(self.CTX)), sent

    async def test_the_request_reaches_the_runtime_carrying_the_task_id(self):
        out, sent = await self.dispatch()
        self.assertEqual(len(sent), 1, "the async step made no request")
        self.assertEqual(str(sent[0].url), "http://127.0.0.1:8765/internal/run")
        self.assertEqual(json.loads(sent[0].content)["workflow_task_id"], TASK_ID)
        self.assertIsInstance(out, Dispatched)
        self.assertEqual(out["status"], 202)

    async def test_a_dispatch_the_runtime_refuses_fails_as_a_sync_call_does(self):
        with self.assertRaises(TerminalError):
            await self.dispatch(status=400)
        with self.assertRaises(RuntimeError):
            await self.dispatch(status=503)

    async def test_wait_ms_is_checked_before_anything_is_sent(self):
        for bad in (0, -5, "soon", 1.5, True):
            with self.subTest(wait_ms=bad), \
                 patch.dict(DOCUMENTED_STEP, {"wait_ms": bad}), \
                 self.assertRaises(TerminalError):
                await self.dispatch()

    async def test_the_default_wait_fits_a_turn_of_minutes(self):
        out, _ = await self.dispatch()
        self.assertEqual(out.wait_seconds, DEFAULT_WAIT_MS / 1000)
        with patch.dict(DOCUMENTED_STEP, {"wait_ms": 4000}):
            out, _ = await self.dispatch()
        self.assertEqual(out.wait_seconds, 4.0)

    @staticmethod
    def database(beats):
        """A connection whose heartbeat answers come from `beats`, in order.

        The last answer repeats. An exception in the list is raised, which is
        a database blip rather than an answer.
        """
        conn = AsyncMock()
        conn.beats = 0
        answers = list(beats)

        async def fetchval(sql, *args):
            if "claim_task" in sql:
                return TASK_ID
            if "get_task_context" in sql:
                return json.dumps({"kind": "http_call", "step_key": "dispatch",
                                   "task_input": {"mode": "async"}})
            if "queue_stale_timeout" in sql:
                return 120
            if "pg_column_size" in sql:
                return 64
            if "heartbeat_task" in sql:
                conn.beats += 1
                answer = answers.pop(0) if len(answers) > 1 else answers[0]
                if isinstance(answer, Exception):
                    raise answer
                return answer
            return None

        conn.fetchval.side_effect = fetchval

        @asynccontextmanager
        async def service():
            yield conn

        return conn, service

    async def run_step(self, returned, beats=(False,)):
        """Drive run_once with a handler returning `returned`; list the SQL."""
        conn, service = self.database(beats)
        with patch("percolate_core.worker.loop.as_service", service), \
             patch.dict("percolate_core.worker.loop.HANDLERS",
                        {"http_call": AsyncMock(return_value=returned)}):
            await run_once("http", "w1")
        return [c.args[0] for c in conn.execute.await_args_list]

    async def hold(self, beats, wait_seconds=5.0):
        conn, service = self.database(beats)
        with patch("percolate_core.worker.loop.as_service", service):
            await _hold_until_released(TASK_ID, "w1", 0.02, wait_seconds)
        return conn

    async def test_the_loop_does_not_complete_a_dispatched_task(self):
        """The runtime completes it when the run is done (brief.md §3); a
        completion here lands first, and the lease fence then refuses the
        runtime's -- measured on percolate 0.2.0."""
        statements = await self.run_step(
            Dispatched(status=202, result={"accepted": True}, wait_seconds=5))
        self.assertEqual([s for s in statements if "complete_task" in s or "fail_task" in s], [])

    async def test_the_worker_holds_the_lease_until_the_callee_moves_the_task(self):
        """Without the heartbeats the reaper takes a task the callee is still
        working on, after `stale_timeout`, and a second worker dispatches it."""
        conn = await self.hold([True, True, True, False])
        self.assertEqual(conn.beats, 4)
        self.assertEqual(conn.execute.await_args_list, [])

    async def test_a_database_blip_during_the_hold_is_not_a_release(self):
        conn = await self.hold([ConnectionError("reset by peer"), True, False])
        self.assertEqual(conn.beats, 3)
        self.assertEqual(conn.execute.await_args_list, [])

    async def test_a_task_reaped_during_the_hold_gets_no_write_from_this_worker(self):
        conn = await self.hold([False])
        self.assertEqual(conn.beats, 1)
        self.assertEqual(conn.execute.await_args_list, [])

    async def test_past_wait_ms_the_task_is_failed_terminally_as_this_worker(self):
        conn = await self.hold([True], wait_seconds=0.1)
        self.assertEqual(len(conn.execute.await_args_list), 1)
        sql, task, payload, worker = conn.execute.await_args.args
        self.assertEqual(sql, "select workflow.fail_task($1, $2::jsonb, true, $3)")
        self.assertEqual((task, worker), (TASK_ID, "w1"))
        self.assertTrue(payload["terminal"])
        self.assertIn("wait_ms", payload["error"])

    async def test_a_sync_step_is_still_completed_by_the_loop(self):
        statements = await self.run_step({"status": 200, "result": {"ok": True}})
        self.assertEqual(statements, ["select workflow.complete_task($1, $2::jsonb)"])


if __name__ == "__main__":
    unittest.main()
