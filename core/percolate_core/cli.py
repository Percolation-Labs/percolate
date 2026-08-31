"""One CLI, three services.

    percolate worker --queue http   # the step loop
    percolate content serve         # the Content Server
    percolate agent serve           # the Agent Runtime

Subcommands import their subpackage lazily, so `percolate worker` does not require
boto3 or pydantic-ai to be installed. That is what makes `pip install percolate-core`
(worker only) a real option rather than a nominal one.
"""

from __future__ import annotations

import typer

app = typer.Typer(help="percolate — Postgres-native subsystems", no_args_is_help=True)
content_app = typer.Typer(help="Content Server: uploads, scraping, ingestion")
agent_app = typer.Typer(help="Agent Runtime: agents, streaming, delegation")
app.add_typer(content_app, name="content")
app.add_typer(agent_app, name="agent")


def _missing(extra: str, err: Exception) -> typer.Exit:
    typer.secho(
        f"this command needs the '{extra}' extra: pip install 'percolate-core[{extra}]'\n  ({err})",
        fg=typer.colors.RED, err=True)
    return typer.Exit(1)


@app.command()
def worker(queue: str = typer.Option("default", "--queue", "-q"),
           worker_id: str = typer.Option(None, "--id")):
    """Claim and execute tasks. http_call is built in; add your own with @handler."""
    from .worker import run
    run(queue=queue, worker_id=worker_id)


@content_app.command("serve")
def content_serve(port: int = typer.Option(8081, "--port", "-p")):
    try:
        from .content import serve
    except ImportError as e:
        raise _missing("content", e)
    serve(port=port)


@agent_app.command("serve")
def agent_serve(port: int = typer.Option(8080, "--port", "-p")):
    try:
        from .agentic.api import app as api
    except ImportError as e:
        raise _missing("agent", e)
    import uvicorn
    uvicorn.run(api, host="0.0.0.0", port=port)


@app.command()
def version():
    from . import __version__
    typer.echo(__version__)


if __name__ == "__main__":
    app()
