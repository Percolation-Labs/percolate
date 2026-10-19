"""`percolate resolve` -- run the resolver worker."""

from __future__ import annotations

import typer

app = typer.Typer(help="Resolve extracted names to registered nodes with a decision model",
                  no_args_is_help=True)


@app.command()
def serve(queue: str = typer.Option("resolve", "--queue", "-q"),
          worker_id: str = typer.Option(None, "--id")) -> None:
    """Claim resolve steps and run them. The same loop as `percolate worker`."""
    from ..worker import run
    from . import handler  # noqa: F401  -- registers @handler("work")

    run(queue=queue, worker_id=worker_id)
