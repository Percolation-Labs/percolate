"""The CLI — the operator surface, and the way this gets exercised by hand.

CLI first, FastAPI later, deliberately (``meta/skills/spec-driven-development``
§2: build it, then *use it like a user would*, before writing tests). Everything
here calls the same ``TurnSequencer`` the HTTP surface will call; the eventual
FastAPI app adds the SSE bridge and nothing else, so anything that only works
over HTTP would be a design smell rather than a missing feature.

    percolate agent gates            # sequence.md's gates and where they stand
    percolate agent steps            # the canonical order of one turn, with spec refs
    percolate agent demo             # dummy end-to-end: fake model, fake tools, memory repo
    percolate agent show NAME  # read an agent row back as its schema document
    percolate agent push FILE  # apply a schema document as an agent row
"""

from __future__ import annotations

import asyncio
import inspect
import json
import sys
from pathlib import Path
from typing import Any
from uuid import UUID

import typer
from rich.console import Console
from rich.table import Table

from . import authoring, phases
from .contracts import ChatRequest, InboundMessage, RequestContext, ToolServer
from .db import PgClient, connected
from .runtime import EventSink, channel, relay
from .sequencer import TurnSequencer
from .settings import Settings
from .testing import (
    MemoryRepository,
    install_fake_providers,
    retrieval_rows,
    scripted_model,
)

app = typer.Typer(add_completion=False, help="Agent runtime (specs/agentic).")
tools_app = typer.Typer(help="Tool servers are rows too — register once, resolve per run.")
app.add_typer(tools_app, name="tools")
console = Console()


@app.command()
def gates() -> None:
    """Print ``sequence.md``'s phase gates and their honest status."""
    table = Table("Gate", "Phase", "Status", "Criterion", "Blocker", box=None)
    for gate in phases.GATES:
        table.add_row(str(gate.number), gate.phase, gate.status, gate.criterion, gate.blocker)
    console.print(table)


@app.command()
def steps() -> None:
    """Print the canonical turn sequence — the sequencer's control flow, with spec refs."""
    doc = inspect.getdoc(TurnSequencer.run_turn) or ""
    console.print(doc)


@app.command()
def demo(
    prompt: str = typer.Option("What do we know about the outage?", help="User turn."),
    tool: str = typer.Option("semantic_search", help="Tool the fake model calls, or '' for none."),
    show_events: bool = typer.Option(True, help="Print the AG-UI event sequence."),
) -> None:
    """Run one turn end to end against fakes, and show what it produced.

    This is the fast inner loop, not proof of behaviour: a real model, a real
    tool server, and real Postgres are all substituted — ``dev/verify.py`` is
    where those are real. What this shows is that the sequence in §5.1 composes — config resolves to a
    toolset, a turn persists as rows in the right granularity, citations derive
    from tool responses rather than from the model, and the run reaches a
    terminal status with an AG-UI event stream around it.
    """
    asyncio.run(_demo(prompt, tool or None, show_events))


async def _demo(prompt: str, tool: str | None, show_events: bool) -> None:
    repo = MemoryRepository()
    install_fake_providers(
        mcp_tools={"semantic_search": {"rows": retrieval_rows()}},
        openapi_tools={"create_ticket": {"id": "TICKET-1"}},
    )

    await repo.upsert_tool_server(
        ToolServer(name="p8-query", kind="mcp", url="http://p8-query.local/mcp", emits_citations=True)
    )
    await repo.upsert_tool_server(
        ToolServer(name="ops-api", kind="openapi", url="http://ops.local/openapi.json")
    )
    from .tools import sync_server

    for name in ("p8-query", "ops-api"):
        server = await repo.get_tool_server(name)
        assert server is not None
        await sync_server(repo, server)

    spec = authoring.from_json_schema(
        {
            "type": "object",
            "name": "researcher",
            "description": "You are a research agent. Answer only from retrieved sources.",
            "tools": [{"server": "p8-query"}, {"server": "ops-api"}],
            "properties": {},
            "context_policy": {"window_messages": 20, "summarize_after_messages": 40},
        }
    )
    await repo.upsert_agent(spec)

    sequencer = TurnSequencer(repo, Settings.from_env())
    result = await sequencer.run_turn(
        ChatRequest(model="researcher", messages=[InboundMessage(role="user", content=prompt)]),
        RequestContext(tenant="demo"),
        model=scripted_model(reply="Two sources describe the outage.", call_tool=tool),
    )

    table = Table("step", "spec", "detail", box=None)
    for record in result.trace:
        table.add_row(record.name, record.spec_ref, record.detail)
    console.print(table)

    console.print(f"\n[bold]run[/bold] {result.run.id} status={result.run.status} "
                  f"trace={result.run.trace_id} span={result.run.span_id}")
    console.print("\n[bold]message rows[/bold]")
    for message in result.messages:
        console.print(
            f"  seq={message.seq} role={message.role:<14} "
            f"tool_calls={len(message.tool_calls)} citations={len(message.citations)} "
            f"content={(message.content or '')[:60]!r}"
        )

    if show_events:
        console.print("\n[bold]AG-UI events[/bold]")
        for event in sequencer.sink.events:
            console.print(f"  {event.type}")


# --------------------------------------------------------------------------
# Real-database commands. Everything below authenticates as an ordinary
# `authenticated` user with real RLS (see PgClient.as_user) — there is no
# privileged mode to fall back to, deliberately.
# --------------------------------------------------------------------------


def repo_for_cli() -> Any:
    """The CLI's connection, as the configured user — see ``db.connected``.

    ``P8_USER_ID`` is checked HERE rather than left to fail later. Without it
    the runtime connects as nobody, ``rbac.current_user_id()`` returns null,
    and the first write hits a not-null constraint:

        NotNullViolationError: null value in column "owner_id" of relation
        "sessions" violates not-null constraint

    printed under forty lines of asyncpg traceback, through a connection pool,
    for a missing environment variable. The refusal itself is the RLS design
    working -- there is deliberately no privileged fallback, because a CLI that
    quietly acted as the owner would be a backdoor around every policy in the
    collection -- but "you have not said who you are" should read as a
    sentence. ``agent push`` says it already; every other subcommand shares
    this helper and said nothing.
    """
    settings = Settings.from_env()
    if not settings.user_id:
        raise typer.BadParameter(
            "no user. Set P8_USER_ID to the id this runs as.\n"
            "  There is no privileged fallback on purpose: the runtime reads and\n"
            "  writes as an ordinary client, so RLS has to scope it to somebody.\n"
            "  `percolate auth bootstrap` prints the id it creates, and an\n"
            "  existing one is `select id from rbac.users where email = '...'`."
        )
    # The CLI has no token to verify, so its claims are the operator's own
    # statement of who it runs as, and only `sub`: with no `orgs` claim RLS
    # scopes it to every org that user belongs to, which is what a person at
    # their own terminal is.
    return connected(settings, {"sub": str(UUID(settings.user_id))})


@app.command("list")
def agent_list() -> None:
    """List agent rows — read through `agents_api`, so RLS applies."""

    async def _run() -> None:
        async with repo_for_cli() as repo:
            for agent in await repo.list_agents():
                console.print(f"{agent.name:<24} {len(agent.tools)} tool server(s)")

    asyncio.run(_run())


@app.command("show")
def agent_show(name: str) -> None:
    """Read one agent row back as the document you would commit (``brief.md`` §6).

    One format, and it is the one ``agent push`` accepts — so pulling an agent,
    editing it and pushing it back is a round trip rather than a translation.
    """

    async def _run() -> None:
        async with repo_for_cli() as repo:
            agent = await repo.get_agent(name)
            if agent is None:
                console.print(f"[red]no agent named {name}[/red]")
                raise typer.Exit(code=1)
            console.print(authoring.to_yaml(agent))

    asyncio.run(_run())


@app.command("push")
def agent_push(path: Path) -> None:
    """Apply an agent definition as a row.

    Accepts a **JSON Schema document** — the shape `model_json_schema()`
    produces, so a file and a code-authored `BaseModel` are the same artifact.
    Either way this is the applying end of ``brief.md`` §6 — "applying it is a
    migration, not a deploy" — and the upsert is gated inside the database on
    ``rbac.has_permission(uid, 'agents', 'update')``, so pushing as a user
    without that permission fails in Postgres, not here.
    """
    spec = authoring.load(path, text=sys.stdin.read() if str(path) == "-" else None)

    async def _run() -> None:
        async with repo_for_cli() as repo:
            stored = await repo.upsert_agent(spec)
            console.print(f"[green]upserted[/green] {stored.name} ({stored.id})")

    asyncio.run(_run())


@tools_app.command("register")
def tools_register(
    name: str,
    url: str,
    kind: str = typer.Option("openapi", help="mcp | openapi"),
    credential_ref: str | None = typer.Option(None, help="e.g. env:MY_TOKEN"),
    emits_citations: bool = typer.Option(False, help="Responses are citable retrieval results."),
    serves_agents: bool = typer.Option(
        False, help="This server's tools ARE agents (the runtime's own gateway)."
    ),
) -> None:
    """Register a tool server and sync it in one step (``brief.md`` §5.2).

    Registration is a *sync* step, not just a stored URL: the tool list is
    fetched now and cached on the row, so no agent invocation ever pays for
    discovery.
    """

    async def _run() -> None:
        from .tools import sync_server

        async with repo_for_cli() as repo:
            stored = await repo.upsert_tool_server(
                ToolServer(
                    name=name,
                    kind=kind,  # type: ignore[arg-type]
                    url=url,
                    credential_ref=credential_ref,
                    emits_citations=emits_citations,
                    serves_agents=serves_agents,
                )
            )
            synced = await sync_server(repo, stored)
            console.print(
                f"[green]registered[/green] {synced.name} ({synced.kind}) — "
                f"{len(synced.cached_tools)} tools"
            )
            for tool in synced.cached_tools[:10]:
                console.print(f"    {tool.name:<40} {tool.description[:50]}")
            if len(synced.cached_tools) > 10:
                console.print(f"    … and {len(synced.cached_tools) - 10} more")

    asyncio.run(_run())


@tools_app.command("sync")
def tools_sync(server: str | None = typer.Argument(None, help="Server name, or all.")) -> None:
    """Re-sync cached tool lists (``brief.md`` §5.2).

    In deployment this is a scheduled ``workflow-engine`` task, not a person
    running a command — the command exists so the sync can be exercised by hand
    first, which is the order `spec-driven-development` §2 asks for.
    """

    async def _run() -> None:
        from .tools import sync_server

        async with repo_for_cli() as repo:
            servers = (
                [await repo.get_tool_server(server)] if server else await repo.list_tool_servers()
            )
            for entry in servers:
                if entry is None:
                    console.print(f"[red]no tool server named {server}[/red]")
                    raise typer.Exit(code=1)
                synced = await sync_server(repo, entry)
                console.print(
                    f"{synced.name:<20} {synced.kind:<8} {len(synced.cached_tools)} tools"
                )

    asyncio.run(_run())


@tools_app.command("list")
def tools_list() -> None:
    """What is registered, and what each server currently exposes."""

    async def _run() -> None:
        async with repo_for_cli() as repo:
            for server in await repo.list_tool_servers():
                console.print(
                    f"[bold]{server.name}[/bold] {server.kind} {server.url} "
                    f"citations={server.emits_citations} tools={len(server.cached_tools)}"
                )
                for tool in server.cached_tools:
                    console.print(f"    {tool.name}")

    asyncio.run(_run())


@app.command()
def chat(
    prompt: str,
    agent: str = typer.Option("researcher", help="agents.name to run."),
    session: str | None = typer.Option(None, help="Existing session id, or a new one."),
    fake: bool = typer.Option(False, help="Use a scripted model instead of a real LLM."),
    tool: str | None = typer.Option(None, help="With --fake: the tool the script calls."),
    tool_args: str | None = typer.Option(None, help="With --fake: JSON args for that tool."),
) -> None:
    """Run one turn against the real database.

    Rows land in `agentic.messages`, AG-UI events go out as `pg_notify` on the
    session's channel, and `percolate agent listen` on that session sees them — which
    is the whole of `brief.md` §4 exercised by hand.
    """

    async def _run() -> None:
        async with repo_for_cli() as repo:
            sink = EventSink(repo)
            sequencer = TurnSequencer(repo, Settings.from_env(), sink=sink)
            result = await sequencer.run_turn(
                ChatRequest(
                    model=agent,
                    messages=[InboundMessage(role="user", content=prompt)],
                    session_id=UUID(session) if session else None,
                ),
                RequestContext(user_id=repo.user_id),
                model=scripted_model(
                    reply="Answered from the database path.",
                    call_tool=tool,
                    tool_args=json.loads(tool_args) if tool_args else None,
                )
                if fake
                else None,
            )
            console.print(
                f"[bold]session[/bold] {result.run.session_id}  "
                f"[bold]run[/bold] {result.run.id}  status={result.run.status}"
            )
            for message in result.messages:
                console.print(f"  {message.role:<12} {(message.content or '')[:70]!r}")

    asyncio.run(_run())


@app.command()
def listen(session: str, seconds: float = typer.Option(30.0, help="How long to listen.")) -> None:
    """Relay one session's AG-UI event stream, exactly as the SSE bridge will.

    One channel per session, so a delegation tree multiplexes itself: parent and
    every child publish here, each event tagged with its own `run_id`
    (`brief.md` §4). This command is `runtime.relay` plus a console; the FastAPI
    bridge will be `runtime.relay` plus `to_sse`. Neither adds protocol logic.
    """

    async def _run() -> None:
        settings = Settings.from_env()
        client = PgClient(settings)
        await client.connect()
        console.print(f"[dim]listening on {channel(UUID(session))} for {seconds}s[/dim]")
        stream = relay(client, UUID(session))
        deadline = asyncio.get_running_loop().time() + seconds
        try:
            while True:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    break
                try:
                    payload = await asyncio.wait_for(anext(stream), timeout=remaining)
                except (TimeoutError, StopAsyncIteration):
                    break
                run = str(payload.get("run_id", ""))[:8]
                console.print(f"  [cyan]{payload.get('type'):<22}[/cyan] run={run} {payload}")
        finally:
            await stream.aclose()
            await client.close()

    asyncio.run(_run())


@app.command()
def gateway(
    # 0.0.0.0, like the Content Server's serve() -- see the note on serve()
    # below. A gateway bound to the container's own loopback is registered as a
    # tool_servers row that nothing can reach.
    host: str = typer.Option("0.0.0.0"),
    port: int = typer.Option(8765),
    stateless: bool = typer.Option(True, help="No session affinity between MCP calls."),
) -> None:
    """Serve this runtime's agents as an MCP server (``brief.md`` §5.1 item 3).

    This is what makes delegation possible without a built-in tool: register
    this URL as an ordinary ``tool_servers`` row of kind ``mcp``, and an agent
    delegates by referencing it like any other server.

    Stateless by default because a delegated call is a complete request —
    session, parent run and trace all arrive as headers, so there is nothing for
    the transport to remember between calls, and nothing to lose when a call
    lands on a different replica.
    """
    from .gateway import build_server

    server = build_server(Settings.from_env())
    console.print(f"[green]agent gateway[/green] on http://{host}:{port}/mcp")
    asyncio.run(server.run_streamable_http_async(host=host, port=port, stateless_http=stateless))


@app.command()
def serve(
    # 0.0.0.0, NOT 127.0.0.1, because this is shipped as a container and that
    # is the container's own loopback. With the old default `agent serve`
    # started, printed `percolate agent on http://127.0.0.1:8080`, reported
    # healthy to Docker, and answered nothing on the published port -- a
    # service that looks fine and is unreachable, which is worse than one that
    # crashes. `content/cli.py` has always defaulted to 0.0.0.0; one package
    # giving two answers to the same question is what made this findable only
    # by running it.
    host: str = typer.Option("0.0.0.0"),
    port: int = typer.Option(8080),
) -> None:
    """Serve the HTTP surface: POST /chat (SSE) and GET /sessions/{id}/events.

    Two endpoints, deliberately (``brief.md`` §4/§8): streaming is the one thing
    PostgREST structurally cannot do, and CRUD is already PostgREST's over the
    ``*_api`` views. A hand-rolled REST layer over the same tables is exactly
    what this collection's ground rules rule out.
    """
    import uvicorn

    from .api import build_app

    console.print(f"[green]percolate agent[/green] on http://{host}:{port}")
    uvicorn.run(build_app(Settings.from_env()), host=host, port=port, log_level="warning")


if __name__ == "__main__":
    app()
