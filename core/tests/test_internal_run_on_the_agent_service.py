"""A scheduled run reaches the agent service, and the runtime can report back.

Three defects, one path. A scheduled step posts to
`{{env.P8_AGENT_URL}}/internal/run`, and:

1. Only `percolate agent gateway` served that route. Every shipped deployment
   points `P8_AGENT_URL` at `agent serve`, and the worker sends the run owner's
   token to that origin only (`worker/agent_auth.py`). So on a stock install
   every scheduled run was a 404.
2. The runtime completed or failed the task by switching its own login to
   `worker`. That login is `authenticator`, which no install makes a member
   of `worker`, so the switch was refused with `permission denied to set role
   "worker"`. The run ended `failed`, the task was never told, and the step
   waited out its whole `wait_ms`. Measured on a stock compose stack with a
   gateway added: one 202, one failed run, a task released only by the
   worker's wait bound. Pinned in
   `test_task_completion_uses_the_worker_login.py`.
3. With no token, the refusal happened inside the background turn, which then
   failed the named task terminally. Anyone who could reach the route could fail
   any task whose id they knew. Serving the route on the published agent port
   makes that matter, so the call is now checked before it is accepted.

No database: the checks are asserted at the seams they pass through. The live
proof is get-percolate's `ci/coldstart.sh`, which dispatches to a missing agent
and requires a terminal failure within 30 seconds, from the runtime.
"""
import asyncio
import os
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch
from uuid import uuid4

from fastapi.testclient import TestClient

from percolate_core.agentic import gateway
from percolate_core.agentic.api import build_app, router
from percolate_core.agentic.settings import Settings
from percolate_core.core import identity

SECRET = "0123456789abcdef0123456789abcdef"
TASK = uuid4()
USER = str(uuid4())
BODY = {"workflow_task_id": str(TASK), "input": {"agent": "summarizer", "prompt": "x"}}


def bearer(sub=USER):
    return {"authorization": "Bearer " + identity.mint_jwt(sub, SECRET, ttl_seconds=300)}


class TaskVisibility:
    """The repository seam `accept_run` asks, answering as told."""

    def __init__(self, visible):
        self.visible = visible
        self.asked = []
        self.claims = None

    def connected(self):
        @asynccontextmanager
        async def connected(settings, claims=None):
            self.claims = claims
            yield self
        return connected

    async def can_see_task(self, task_id):
        self.asked.append(task_id)
        return self.visible


class AcceptRun(unittest.IsolatedAsyncioTestCase):
    """What `/internal/run` refuses before it answers 202, and that it refuses
    without touching the task."""

    def setUp(self):
        env = patch.dict(os.environ, {"P8_JWT_SECRET": SECRET})
        env.start()
        self.addCleanup(env.stop)
        self.dispatch = AsyncMock()
        self.fail_task = AsyncMock()
        self.problem = AsyncMock(return_value=None)
        for target, mock in ((gateway, "_dispatch"), (gateway, "_fail_task")):
            p = patch.object(target, mock, self.dispatch if mock == "_dispatch" else self.fail_task)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(identity, "task_worker_problem", self.problem)
        p.start()
        self.addCleanup(p.stop)

    async def accept(self, headers, body=BODY, visible=True):
        seam = TaskVisibility(visible)
        with patch.object(gateway, "connected", seam.connected()):
            status, payload = await gateway.accept_run(Settings(), headers, body)
        await asyncio.sleep(0)  # let an accepted dispatch start
        return status, payload, seam

    def assert_task_untouched(self):
        self.dispatch.assert_not_called()
        self.fail_task.assert_not_called()

    async def test_no_token_is_401_and_the_task_is_not_failed(self):
        status, payload, seam = await self.accept({})
        self.assertEqual(status, 401, payload)
        self.assertEqual(seam.asked, [], "the task was looked up for an unverified caller")
        self.assert_task_untouched()

    async def test_a_forged_token_is_401(self):
        forged = {"authorization": "Bearer " + identity.mint_jwt(USER, "x" * 32, ttl_seconds=300)}
        status, payload, _ = await self.accept(forged)
        self.assertEqual(status, 401, payload)
        self.assert_task_untouched()

    async def test_a_task_the_caller_cannot_see_is_404(self):
        status, payload, seam = await self.accept(bearer(), visible=False)
        self.assertEqual(status, 404, payload)
        self.assertEqual(seam.asked, [TASK])
        self.assertEqual(seam.claims["sub"], USER, "visibility was asked as someone else")
        self.assert_task_untouched()

    async def test_a_runtime_that_cannot_act_as_worker_refuses_before_accepting(self):
        self.problem.return_value = "cannot become worker -- set P8_WORKER_DSN"
        status, payload, _ = await self.accept(bearer())
        self.assertEqual(status, 503, payload)
        self.assertIn("P8_WORKER_DSN", payload["error"])
        self.assert_task_untouched()

    async def test_a_malformed_body_is_400_before_anything_else(self):
        for body in ({}, {"workflow_task_id": "not-a-uuid", "input": {"agent": "a"}}, []):
            with self.subTest(body=body):
                status, payload, seam = await self.accept(bearer(), body=body)
                self.assertEqual(status, 400, payload)
                self.assertEqual(seam.asked, [])
        self.assert_task_untouched()

    async def test_an_accepted_run_is_dispatched_once_for_that_task(self):
        status, payload, _ = await self.accept(bearer())
        self.assertEqual(status, 202, payload)
        self.assertEqual(payload["workflow_task_id"], str(TASK))
        self.dispatch.assert_awaited_once()
        kwargs = self.dispatch.await_args.kwargs
        self.assertEqual((kwargs["task_id"], kwargs["agent_name"]), (TASK, "summarizer"))
        self.fail_task.assert_not_called()


class TheAgentServiceServesIt(unittest.TestCase):
    """`agent serve`, the service P8_AGENT_URL names, answers the route."""

    def client(self):
        settings = Settings()
        app = build_app(settings)
        # Not entering the lifespan: nothing here may reach a database.
        app.state.percolate_agent_client = object()
        app.state.percolate_agent_settings = settings
        return TestClient(app)

    def test_the_route_is_on_the_mountable_router(self):
        """On `router()`, so a host that mounts the runtime gets it too."""
        routes = {(r.path, m) for r in router().routes for m in getattr(r, "methods", ())}
        self.assertIn(("/internal/run", "POST"), routes)

    def test_it_is_the_same_checked_implementation(self):
        dispatch = AsyncMock()
        seam = TaskVisibility(True)
        with patch.dict(os.environ, {"P8_JWT_SECRET": SECRET}), \
             patch.object(gateway, "_dispatch", dispatch), \
             patch.object(gateway, "connected", seam.connected()), \
             patch.object(identity, "task_worker_problem", AsyncMock(return_value=None)):
            # Not `with client`: that would enter the lifespan and open a pool.
            client = self.client()
            self.addCleanup(client.close)
            self.assertEqual(client.post("/internal/run", json=BODY).status_code, 401)
            self.assertEqual(client.post("/internal/run", json={}, headers=bearer()).status_code, 400)
            accepted = client.post("/internal/run", json=BODY, headers=bearer())
        self.assertEqual(accepted.status_code, 202, accepted.text)
        self.assertEqual(seam.asked, [TASK])
        dispatch.assert_called_once()


if __name__ == "__main__":
    unittest.main()
