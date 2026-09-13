"""Test support — exercising the runtime without Postgres, an LLM, or a tool server.

Named ``testing`` rather than ``fakes`` and shipped with the package
deliberately: anything that mounts this runtime (`meta/module-composition.md`)
needs the same in-memory repository and scripted model to test *its* code, and
a test double that only exists in one repo's dev directory cannot be reused by
the host that imports the package.

``meta/skills/spec-driven-development`` §2 says to build the thing and then *use
it like a user would* before writing tests. For a runtime whose three
dependencies are a database, a model provider, and a fleet of microservices,
"use it" needs a substitute for all three for the fast inner loop; ``dev/`` has
the real thing for the slow one.

What the fakes are allowed to be:

- ``MemoryRepository`` — an in-memory stand-in for the *repository contract*,
  not for Postgres. It deliberately does not simulate RLS, transactions, or
  triggers: pretending to would let a design that only works without them look
  like it works. Anything that depends on those is proven against the real
  stack (``experiments/pg19-stack``) or not at all.
- ``FakeToolServer`` providers — canned tool lists and canned results, so tool
  binding, citation derivation, and error classification can be exercised
  end-to-end before a real MCP or OpenAPI service exists.
- ``scripted_model`` — pydantic-ai's own ``FunctionModel``/``TestModel``, so an
  agent runs deterministically with no credentials.
"""

from __future__ import annotations

import json
from typing import Any
from uuid import UUID, uuid4

from .contracts import (
    AgentSpec,
    CanonicalTool,
    InvocationTarget,
    Message,
    Run,
    RunStatus,
    Session,
    ToolInvocation,
    ToolResult,
    ToolServer,
)


class MemoryRepository:
    """The repository contract, backed by dicts. See module docstring for limits."""

    def __init__(self) -> None:
        self.agents: dict[str, AgentSpec] = {}
        self.tool_servers: dict[str, ToolServer] = {}
        self.sessions: dict[UUID, Session] = {}
        self.runs: dict[UUID, Run] = {}
        self.messages: list[Message] = []
        self.notifications: list[tuple[str, str]] = []
        self.chained_calls: list[tuple[str, dict[str, Any]]] = []
        self.workflows: list[tuple[str, dict[str, Any]]] = []
        self.completed_tasks: list[tuple[UUID, dict[str, Any]]] = []
        self.failed_tasks: list[tuple[UUID, dict[str, Any], bool]] = []
        self.hidden_tasks: set[UUID] = set()
        self.quota_allowed = True

    # -- config plane ------------------------------------------------------
    async def get_agent(self, name: str) -> AgentSpec | None:
        return self.agents.get(name)

    async def get_agent_by_id(self, agent_id: UUID) -> AgentSpec | None:
        return next((a for a in self.agents.values() if a.id == agent_id), None)

    async def list_agents(self) -> list[AgentSpec]:
        return sorted(self.agents.values(), key=lambda a: a.name)

    async def upsert_agent(self, agent: AgentSpec) -> AgentSpec:
        self.agents[agent.name] = agent
        return agent

    async def upsert_agent_document(self, doc: dict[str, Any]) -> AgentSpec:
        """The document form, for a twin that has no database to translate it.

        `authoring.from_json_schema` is the in-process mapping and this calls it
        rather than repeating it. For a row that is really stored the database is
        the authority (`brief.md` §6.1); a twin translating a fourth way is the
        drift REM-70 removed.
        """
        from . import authoring

        return await self.upsert_agent(authoring.from_json_schema(doc))

    async def translates_agent_documents(self) -> bool:
        """True: the twin translates in process, so a caller never has to refuse.

        The question exists because a *database* older than REM-70 drops half a
        document (`core.agent_document`). There is no database here.
        """
        return True

    async def get_tool_server(self, name: str) -> ToolServer | None:
        return self.tool_servers.get(name)

    async def list_tool_servers(self) -> list[ToolServer]:
        return sorted(self.tool_servers.values(), key=lambda s: s.name)

    async def upsert_tool_server(self, server: ToolServer) -> ToolServer:
        self.tool_servers[server.name] = server
        return server

    # -- conversation plane ------------------------------------------------
    async def create_session(self, session: Session) -> Session:
        self.sessions[session.id] = session
        return session

    async def get_session(self, session_id: UUID) -> Session | None:
        return self.sessions.get(session_id)

    async def create_run(self, run: Run) -> Run:
        run.status = "running"
        self.runs[run.id] = run
        return run

    async def update_run(
        self, run_id: UUID, *, status: RunStatus | None = None, state: dict[str, Any] | None = None
    ) -> Run:
        run = self.runs[run_id]
        if status is not None:
            run.status = status
        if state is not None:
            run.state = state
        return run

    async def get_run(self, run_id: UUID) -> Run | None:
        return self.runs.get(run_id)

    async def child_runs(self, parent_run_id: UUID) -> list[Run]:
        return [r for r in self.runs.values() if r.parent_run_id == parent_run_id]

    async def append_messages(self, messages: list[Message]) -> list[Message]:
        for index, message in enumerate(messages):
            message.seq = len(self.messages) + index
        self.messages.extend(messages)
        return messages

    async def session_messages(self, session_id: UUID) -> list[Message]:
        return [m for m in self.messages if m.session_id == session_id]

    async def branch_messages(
        self, session_id: UUID, parent_run_id: UUID | None, limit: int | None = None
    ) -> list[Message]:
        runs = {
            r.id
            for r in self.runs.values()
            if r.parent_run_id == parent_run_id and r.trigger_kind == "interactive"
        }
        rows = [
            m
            for m in self.messages
            if m.session_id == session_id and (m.run_id in runs or m.role == "summary")
        ]
        return rows[-limit:] if limit else rows

    async def message_count(self, session_id: UUID) -> int:
        return len(await self.session_messages(session_id))

    # -- streaming ---------------------------------------------------------
    async def notify(self, channel: str, payload: str) -> None:
        self.notifications.append((channel, payload))

    # -- neighbouring systems ---------------------------------------------
    async def has_quota_remaining(self, user_id: UUID | None, resource_kind: str) -> bool:
        """Always allows, unless a test flips ``quota_allowed``.

        Kept switchable because "a denied call ends the run as ``quota_exceeded``
        with partial state preserved" is a *stated guarantee* (``brief.md``
        §5.1), and stated guarantees are exactly what the eventual ~10% of tests
        should cover.
        """
        return self.quota_allowed

    async def call_chained_action(self, target: str, payload: dict[str, Any]) -> Any:
        self.chained_calls.append((target, payload))
        return {"ok": True, "target": target}

    async def start_workflow(
        self, name: str, payload: dict[str, Any], trace_id: str | None = None
    ) -> UUID:
        self.workflows.append((name, payload))
        return uuid4()

    async def complete_task(self, task_id: UUID, output: dict[str, Any]) -> None:
        self.completed_tasks.append((task_id, output))

    async def fail_task(self, task_id: UUID, error: dict[str, Any], terminal: bool) -> None:
        self.failed_tasks.append((task_id, error, terminal))

    async def can_see_task(self, task_id: UUID) -> bool:
        return task_id not in self.hidden_tasks


class FakeProvider:
    """A tool server that answers from a canned table. Never reaches a network.

    Note this still goes through ``tools.registry.invoke`` — the fake replaces
    the *server*, not the dispatch path, so the "one choke point where a tool
    call leaves the process" claim stays under test.
    """

    def __init__(self, kind: str, tools: dict[str, Any]) -> None:
        self.kind = kind
        self._tools = tools

    async def list_tools(self, server: ToolServer) -> list[CanonicalTool]:
        return [
            CanonicalTool(
                name=name,
                description=f"fake {self.kind} tool {name}",
                input_schema={
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"],
                },
                kind=self.kind,  # type: ignore[arg-type]
                target=InvocationTarget(tool_name=name),
            )
            for name in self._tools
        ]

    async def invoke(
        self,
        server: ToolServer,
        tool: CanonicalTool,
        call: ToolInvocation,
        headers: dict[str, str] | None = None,
    ) -> ToolResult:
        canned = self._tools.get(tool.name)
        if canned is None:
            return ToolResult(
                call_id=call.call_id,
                tool_name=tool.name,
                content="unknown tool",
                is_error=True,
                error_kind="dispatch_error",
            )
        if isinstance(canned, Exception):
            return ToolResult(
                call_id=call.call_id,
                tool_name=tool.name,
                content=str(canned),
                is_error=True,
                error_kind="tool_error",
            )
        return ToolResult(call_id=call.call_id, tool_name=tool.name, content=canned)


def install_fake_providers(mcp_tools: dict[str, Any], openapi_tools: dict[str, Any]) -> None:
    """Swap the real providers out for canned ones, process-wide.

    Blunt on purpose: the alternative is threading a provider registry through
    every call site, which would add an abstraction the production path does not
    need — ``spec-driven-development`` §5's "prefer deleting or simplifying to
    adding".
    """
    from .tools import registry

    registry.PROVIDERS["mcp"] = FakeProvider("mcp", mcp_tools)  # type: ignore[assignment]
    registry.PROVIDERS["openapi"] = FakeProvider("openapi", openapi_tools)  # type: ignore[assignment]


def retrieval_rows() -> list[dict[str, Any]]:
    """A canned ``ai-query-layer`` result, shaped so citations can be derived.

    Both citation kinds appear (``brief.md`` §5.3's tagged union): a chunk from
    ``world-model-ingestion``'s tables, and a graph node.
    """
    return [
        {
            "resource_type": "document",
            "resource_id": str(uuid4()),
            "chunk_id": str(uuid4()),
            "text": "…retrieved chunk…",
        },
        {"node_id": str(uuid4()), "label": "Entity"},
    ]


def scripted_model(
    reply: str = "done",
    call_tool: str | None = None,
    tool_args: dict[str, Any] | None = None,
) -> Any:
    """A deterministic model that *streams*: optionally call one tool, then answer.

    Uses pydantic-ai's own ``FunctionModel`` with a ``stream_function``, so the
    runtime's real streaming path runs — the fake is the model, not the agent,
    and not the stream. A non-streaming fake would have quietly skipped the
    entire AG-UI delta path, which is most of what there is to get wrong here.
    """
    from pydantic_ai.models.function import DeltaToolCall, FunctionModel

    def _already_called(messages: list[Any]) -> bool:
        return any(
            part.part_kind == "tool-return"
            for message in messages
            for part in getattr(message, "parts", [])
        )

    async def stream(messages: list[Any], info: Any) -> Any:
        if call_tool and not _already_called(messages):
            yield {
                0: DeltaToolCall(
                    name=call_tool,
                    json_args=json.dumps(tool_args or {"query": "anything"}),
                    tool_call_id="call-1",
                )
            }
            return
        # Word by word, so a consumer sees more than one delta -- a single-chunk
        # fake makes a broken delta path look fine.
        for index, word in enumerate(reply.split()):
            yield word if index == 0 else f" {word}"

    return FunctionModel(stream_function=stream)
