"""``percolate query``: the tool server that lets an agent read this database."""

from __future__ import annotations

import typer

app = typer.Typer(help="The query tool server: p8ql over MCP", no_args_is_help=True)


@app.command("mcp")
def mcp(
    # 0.0.0.0 for the reason `agent serve` and `content serve` give: this runs
    # in a container, and the container's own loopback is unreachable from the
    # agent runtime that has to call it.
    host: str = typer.Option("0.0.0.0"),
    port: int = typer.Option(8090),
    signing_key_file: str | None = typer.Option(None, envvar="P8_MCP_SIGNING_KEY_FILE",
        help="Enable per-user connector-key auth. Owner-only file containing the PostgREST JWT signing secret."),
    access_ttl: int = typer.Option(300, min=1, max=900, help="Internal access-token lifetime in connector-key mode."),
    postgrest: str = typer.Option(
        "http://localhost:3000", envvar="P8_POSTGREST_URL",
        help="PostgREST base URL. Every call carries the MCP caller's Authorization header."),
) -> None:
    """Serve query and enabled canvas tools at ``http://HOST:PORT/mcp``.

    With --signing-key-file, authenticate per-user connector keys and mint
    short-lived internal access tokens. See docs/local-connectors.md.
    Without it, caller JWT headers pass through to PostgREST.

    Register that URL as a ``tool_servers`` row of kind ``mcp``, sync its
    catalogue, and put its origin on the agent runtime's
    ``P8_TOOL_AUTH_ORIGINS``. Without that last step the runtime sends no
    bearer, PostgREST answers as the anonymous role, and every query is refused.
    """
    from .mcp import build_server

    server = build_server(host, port, postgrest, signing_key_file=signing_key_file, access_ttl=access_ttl)
    typer.echo(f"[query-mcp] http://{host}:{port}  ->  {postgrest}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
