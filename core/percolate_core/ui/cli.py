"""`p8 ui` — the browser surface, served from the same distribution."""

from __future__ import annotations

import typer

app = typer.Typer(help="The web UI: monitor runs, manage access, draft workflows",
                  no_args_is_help=True)


@app.command()
def serve(
    port: int = typer.Option(None, "--port", "-p", help="default: $P8_UI_PORT, else 8082"),
    host: str = typer.Option("0.0.0.0", "--host"),
) -> None:
    """Serve the UI. It talks to PostgREST directly; this process only sends files."""
    from .server import serve as _serve

    _serve(host=host, port=port)


@app.command()
def config() -> None:
    """Print what the browser will be told about this deployment."""
    import json

    from .server import config as _config

    typer.echo(json.dumps(_config(), indent=2))
