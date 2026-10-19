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
    # NOT 8081 as the default here: serve() already resolves P8_PORT, and a
    # typer default is a value rather than an absence -- so the CLI passed
    # 8081 on every invocation and the environment variable the module
    # documents could never take effect. Found by trying to run two of these
    # side by side.
    port: int = typer.Option(None, "--port", "-p", help="default: $P8_PORT, else 8081"),
    host: str = typer.Option("0.0.0.0", "--host"),
) -> None:
    """Run the Content Server."""
    from .server import serve as _serve

    _serve(host=host, port=port)
