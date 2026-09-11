"""A caller the database refuses is told so, not shown a server error (REM-67).

Every authorization rule lives in Postgres, so "you may not do that" arrives in
this process as SQLSTATE 42501. It used to arrive nowhere in particular: a turn
refused by `agentic.start_run` was a bare 500, a sync refused by
`agentic.upsert_tool_server` was `502 Tool discovery failed (RaiseError)` --
blaming the tool server, which had already answered -- and an upload refused by
`content.register_upload` was a 400.

No database: the refusals here are built the way asyncpg builds one off the
wire, `InsufficientPrivilegeError.new({'C': '42501', 'M': ..., 'H': ...})`, so
`message`, `hint` and `sqlstate` are the real attributes the mapping reads. What
is under test is the boundary -- which status a refused statement produces on
each surface, and that a genuinely upstream failure still produces 502.
"""
import asyncio
import json
import os
import unittest
from contextlib import asynccontextmanager
from unittest.mock import AsyncMock, patch

import asyncpg
from fastapi import FastAPI
from fastapi.testclient import TestClient

from percolate_core.agentic.api import router
from percolate_core.agentic.contracts import AgentSpec, ToolServer
from percolate_core.agentic.settings import Settings
from percolate_core.agentic.testing import MemoryRepository
from percolate_core.content.server import build_app as content_app, caller
from percolate_core.core.identity import mint_jwt
from percolate_core.core.refusal import refusal
from percolate_core.worker.loop import run_once

SECRET = "test-only-secret-not-a-production-key"
ALICE = "11111111-1111-1111-1111-111111111111"
INVOKE = ("not authorized to invoke agent rem18",
          "needs agents:invoke, and the agent must be visible to you")
REGISTER = ("not authorized to register tool servers", "needs tool_servers:update")


def refused(message: str, hint: str | None = None) -> asyncpg.PostgresError:
    """A refusal shaped as asyncpg builds one from the server's error fields."""
    fields = {"C": "42501", "M": message}
    if hint:
        fields["H"] = hint
    return asyncpg.InsufficientPrivilegeError.new(fields)


def bearer() -> dict[str, str]:
    return {"Authorization": "Bearer " + mint_jwt(ALICE, SECRET)}


class RefusingRepository(MemoryRepository):
    """The in-memory repository with one statement the database refuses.

    Refusing at a named method is how the two halves of a streamed turn are
    told apart: `create_run` is refused before anything has been published, and
    `append_messages` after RUN_STARTED has gone out.
    """

    def __init__(self, refuse: str | None = None, error: Exception | None = None) -> None:
        super().__init__()
        self.refuse = refuse
        self.error = error
        self.queue: asyncio.Queue | None = None

    def _check(self, method: str) -> None:
        if method == self.refuse:
            raise self.error

    async def create_run(self, run):
        self._check("create_run")
        return await super().create_run(run)

    async def append_messages(self, messages):
        self._check("append_messages")
        return await super().append_messages(messages)

    async def upsert_tool_server(self, server):
        self._check("upsert_tool_server")
        return await super().upsert_tool_server(server)

    async def notify(self, channel: str, payload: str) -> None:
        # Stands in for NOTIFY delivery: what the turn publishes reaches the
        # listener the endpoint is holding, which is what makes "the stream had
        # already started" a real state in these tests rather than a timing
        # accident.
        await super().notify(channel, payload)
        if self.queue is not None:
            self.queue.put_nowait(json.loads(payload))


class FakeListener:
    def __init__(self) -> None:
        self.closed = False

    async def close(self) -> None:
        self.closed = True


class FakeClient:
    """Only what the endpoints ask of the pool: a listener."""

    def __init__(self, repo: RefusingRepository) -> None:
        self.repo = repo
        self.listener = FakeListener()

    async def listen(self, channel: str, queue: asyncio.Queue) -> FakeListener:
        self.repo.queue = queue
        return self.listener


class AgentRuntimeTest(unittest.TestCase):
    """The agent runtime's HTTP surface."""

    def repository(self, refuse: str | None = None, error: Exception | None = None,
                   agent: bool = True, server: ToolServer | None = None) -> RefusingRepository:
        repo = RefusingRepository(refuse, error)
        if agent:
            repo.agents["rem18"] = AgentSpec(name="rem18", system_prompt="hello")
        if server is not None:
            repo.tool_servers[server.name] = server
        return repo

    def client(self, repo: RefusingRepository) -> TestClient:
        env = patch.dict(os.environ, {"P8_JWT_SECRET": SECRET})
        env.start()
        self.addCleanup(env.stop)
        patcher = patch("percolate_core.agentic.api.PgRepository",
                        lambda client, claims: repo)
        patcher.start()
        self.addCleanup(patcher.stop)
        app = FastAPI()
        app.include_router(router())
        app.state.percolate_agent_client = FakeClient(repo)
        app.state.percolate_agent_settings = Settings(default_model="test")
        client = TestClient(app)
        self.addCleanup(client.close)
        return client

    def turn(self, client: TestClient, stream: bool):
        return client.post("/v1/chat/completions", headers=bearer(), json={
            "model": "rem18", "stream": stream,
            "messages": [{"role": "user", "content": "hello"}]})

    def test_a_turn_without_agents_invoke_is_403_with_the_hint(self):
        repo = self.repository("create_run", refused(*INVOKE))
        response = self.turn(self.client(repo), stream=False)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json(),
                         {"detail": INVOKE[0], "code": "42501", "hint": INVOKE[1]})

    def test_a_streamed_turn_refused_before_it_starts_is_403_not_an_event(self):
        # The asymmetry this closes: Starlette sends the 200 with the first
        # frame, so a refusal the endpoint has not waited for can only be a
        # RUN_ERROR inside a successful response.
        repo = self.repository("create_run", refused(*INVOKE))
        response = self.turn(self.client(repo), stream=True)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["hint"], INVOKE[1])
        self.assertNotIn("RUN_ERROR", response.text)

    def test_a_refusal_mid_stream_is_an_event_carrying_message_and_hint(self):
        # Refused after RUN_STARTED is out: the status line is already sent and
        # 200 is now the truth, so the refusal is said in the stream instead.
        repo = self.repository("append_messages", refused(*INVOKE))
        response = self.turn(self.client(repo), stream=True)
        self.assertEqual(response.status_code, 200)
        self.assertIn("RUN_STARTED", response.text)
        error = next(json.loads(line[len("data: "):]) for line in response.text.splitlines()
                     if line.startswith("data: ") and '"RUN_ERROR"' in line)
        self.assertEqual(error["message"], f"{INVOKE[0]} ({INVOKE[1]})")

    def test_a_sync_without_tool_servers_update_is_403_not_502(self):
        server = ToolServer(name="query", kind="openapi", url="http://query:8090")
        repo = self.repository("upsert_tool_server", refused(*REGISTER), server=server)
        with patch("percolate_core.agentic.tools.registry.PROVIDERS",
                   {"openapi": Discovered([])}):
            response = self.client(repo).post("/tools/query/sync", headers=bearer())
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.json()["detail"], REGISTER[0])
        self.assertEqual(response.json()["hint"], REGISTER[1])

    def test_an_upstream_failure_on_sync_is_still_502_and_writes_nothing(self):
        server = ToolServer(name="query", kind="openapi", url="http://query:8090")
        repo = self.repository(server=server)
        with patch("percolate_core.agentic.tools.registry.PROVIDERS",
                   {"openapi": Discovered(ConnectionError("connection refused"))}):
            response = self.client(repo).post("/tools/query/sync", headers=bearer())
        self.assertEqual(response.status_code, 502)
        self.assertIn("Tool discovery failed (ConnectionError)", response.json()["detail"])
        self.assertEqual(repo.tool_servers["query"].cached_tools, [])


class Discovered:
    """A tool server that answers `list_tools`, or fails the way one fails."""

    def __init__(self, answer) -> None:
        self.answer = answer

    async def list_tools(self, server: ToolServer):
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


class ContentServerTest(unittest.TestCase):
    """The other HTTP surface in this package, on the same rule."""

    def test_an_upload_the_database_refuses_is_403_and_a_bad_one_is_still_400(self):
        for error, status in ((refused("not authorized to upload content", "needs resources:create"), 403),
                              (asyncpg.RaiseError("no channel named 'nope'"), 400)):
            with self.subTest(status=status):
                @asynccontextmanager
                async def scoped(_claims, error=error):
                    class Conn:
                        async def fetchval(self, *args):
                            raise error
                    yield Conn()

                app = content_app(())
                app.dependency_overrides[caller] = lambda: {"sub": ALICE}
                with patch("percolate_core.content.server.as_caller", scoped), \
                     patch("percolate_core.content.server.storage.put",
                           return_value=("checksum", "object-key")), \
                     patch("percolate_core.content.server.storage.bucket",
                           return_value="test-bucket"):
                    with TestClient(app) as client:
                        response = client.post("/files", content=b"note")
                self.assertEqual(response.status_code, status)


class TheRuleTest(unittest.TestCase):
    """What counts as a refusal, and what does not."""

    def test_only_sqlstate_42501_is_a_refusal(self):
        self.assertIsNone(refusal(asyncpg.RaiseError("Use a source name starting with a letter")))
        self.assertIsNone(refusal(ValueError("42501")))
        self.assertIsNone(refusal(asyncpg.PostgresError.new(
            {"C": "23505", "M": "duplicate key value violates unique constraint"})))
        self.assertEqual(refusal(refused(*INVOKE)).hint, INVOKE[1])

    def test_a_refusal_reads_as_a_sentence_and_as_a_body(self):
        one = refusal(refused("not authorized to grant roles"))
        self.assertEqual(str(one), "not authorized to grant roles")
        self.assertEqual(one.body(), {"detail": "not authorized to grant roles", "code": "42501"})
        two = refusal(refused(*INVOKE))
        self.assertEqual(str(two), f"{INVOKE[0]} ({INVOKE[1]})")
        self.assertEqual(two.body()["hint"], INVOKE[1])


class WorkerRetryTest(unittest.IsolatedAsyncioTestCase):
    """A refused step fails on its first attempt, rather than four times.

    The same rule one layer out. `PERMANENT_DB_ERRORS` decides whether the
    worker spends a task's retry budget, and it listed integrity and data
    errors only -- so a `work:` step refused by a may_* predicate, or by a
    policy admitting no row, burned every attempt on an answer that cannot
    change and buried the message under four copies of itself. The engine's own
    SQL retry lists treat 42501 as terminal (workflow-engine
    execute_sql_step), which is what left this as the last path retrying it.
    """

    async def outcome(self, error: BaseException) -> bool:
        conn = AsyncMock()
        conn.fetchval.side_effect = [
            "1e0f2b8a-0000-4000-8000-000000000001",
            json.dumps({"kind": "work", "step_key": "land", "task_input": {}}),
        ]

        @asynccontextmanager
        async def service():
            yield conn

        handler = AsyncMock(side_effect=error)
        with patch("percolate_core.worker.loop.as_service", service), \
             patch.dict("percolate_core.worker.loop.HANDLERS", {"work": handler}):
            await run_once("ingest", "worker-1")
        handler.assert_awaited_once()
        sql, _task, payload, terminal = conn.execute.await_args.args
        self.assertEqual(sql, "select workflow.fail_task($1, $2::jsonb, $3)")
        self.assertEqual(payload.get("terminal", False), terminal)
        return terminal

    async def test_a_refused_step_is_terminal_on_the_first_attempt(self):
        self.assertTrue(await self.outcome(refused(*INVOKE)))

    async def test_a_busy_database_is_still_retried(self):
        self.assertFalse(await self.outcome(asyncpg.DeadlockDetectedError.new(
            {"C": "40P01", "M": "deadlock detected"})))


if __name__ == "__main__":
    unittest.main()
