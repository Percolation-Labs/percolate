"""The Content Server's own commands, mounted by the root CLI as `percolate content`.

A subpackage owns its command group the same way it owns its router
(`meta/module-composition.md`): the root CLI mounts it, and does not re-declare
its commands — a hand-forwarded subset is a subset that goes stale.
"""

from __future__ import annotations

import typer

app = typer.Typer(help="Content Server: uploads, scraping, ingestion", no_args_is_help=True)


@app.command()
def serve(
    port: int = typer.Option(8081, "--port", "-p"),
    host: str = typer.Option("0.0.0.0", "--host"),
) -> None:
    """Run the Content Server."""
    from .server import serve as _serve

    _serve(host=host, port=port)
