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


def _version_callback(value: bool) -> None:
    if value:
        from . import __version__

        typer.echo(__version__)
        raise typer.Exit()


@app.callback()
def _main(
    version: bool = typer.Option(
        None,
        "--version",
        "-V",
        help="Show the version and exit.",
        callback=_version_callback,
        is_eager=True,
    ),
) -> None:
    # A callback is the only place a Typer *app* (as opposed to a command) can
    # carry an option, so `percolate --version` works the way every CLI's does.
    # The `version` subcommand stays: scripts that already call it keep working.
    pass

_EXTRAS = {
    "content": ("boto3", "fastapi", "uvicorn"),
    "ingest": ("semchunk", "pymupdf4llm", "pymupdf", "docx", "pydantic"),
    "tabular": ("pyarrow", "duckdb"),
    "agent": ("pydantic_ai", "fastapi", "uvicorn", "mcp", "yaml", "rich"),
}


def _missing_extra(err: ModuleNotFoundError) -> str | None:
    """Which extra would supply the module that is missing, if any.

    The point is the *if any*: an earlier version reported every ImportError as
    "install the extra", so a genuine bug inside an installed subpackage was
    reported as a missing dependency the user already had — a wrong answer that
    reads as a helpful one.
    """
    return next((x for x, mods in _EXTRAS.items() if err.name in mods), None)


def _subcommands(name: str, module: str, help: str) -> typer.Typer:
    """Mount a subpackage's own CLI, or a stub that explains why it is absent.

    Imported at module load rather than per-invocation, deliberately: the
    promise of the extras is that `pip install percolate-core` does not *pull*
    boto3 and pydantic-ai, not that a full install starts a millisecond faster.
    Trying and catching keeps a worker-only install working, and — unlike
    hand-written proxy commands — the whole operator surface of the subpackage
    comes with it instead of whichever commands somebody remembered to forward.
    """
    try:
        module_obj = __import__(module, fromlist=["app"])
        return module_obj.app
    except ModuleNotFoundError as err:
        stub = typer.Typer(help=f"{help} (not installed)")
        extra = _missing_extra(err) or name
        missing = err.name

        @stub.callback(invoke_without_command=True)
        def _unavailable() -> None:
            typer.secho(
                f"this command group needs the '{extra}' extra:\n"
                f"    pip install 'percolate-core[{extra}]'\n"
                f"  (missing module: {missing})",
                fg=typer.colors.RED,
                err=True,
            )
            raise typer.Exit(1)

        return stub


app.add_typer(
    _subcommands("agent", "percolate_core.agentic.cli", "Agent Runtime"),
    name="agent",
    help="Agent Runtime: agents, tools, streaming, delegation",
)
app.add_typer(
    _subcommands("content", "percolate_core.content.cli", "Content Server"),
    name="content",
    help="Content Server: uploads, scraping, ingestion",
)
app.add_typer(
    _subcommands("ingest", "percolate_core.ingest.cli", "Ingest worker"),
    name="ingest",
    help="Ingest worker: parse, chunk and embed uploaded files",
)


# Mounted directly rather than through _subcommands(): `auth` needs nothing
# beyond the base install, so there is no extra for it to be missing and no
# stub to explain. A worker-only deployment is exactly where somebody is
# holding admin credentials with no other tooling around.
from .core.cli import app as _auth_app
from .core.cli import sample_app as _sample_app

app.add_typer(_auth_app, name="auth", help="Bootstrap the first identity, and sign tokens")
app.add_typer(_sample_app, name="sample", help="Load a sample dataset")


@app.command()
def worker(
    queue: str = typer.Option("default", "--queue", "-q"),
    worker_id: str = typer.Option(None, "--id"),
) -> None:
    """Claim and execute tasks. http_call is built in; add your own with @handler."""
    from .worker import run

    run(queue=queue, worker_id=worker_id)


@app.command(help="Show the version and exit (same as --version).")
def version() -> None:
    from . import __version__

    typer.echo(__version__)


if __name__ == "__main__":  # `python -m percolate_core.cli`, as dev/stack.sh runs it
    app()
