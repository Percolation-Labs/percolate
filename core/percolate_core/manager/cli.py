"""`p8 pool` — render, diff, run."""

from __future__ import annotations

import asyncio

import typer

from .render import Config, render_pool

app = typer.Typer(help="Worker pools: declare rows, reconcile Deployments", no_args_is_help=True)


async def _fetch(name: str) -> dict:
    """One pool row plus its queue bindings, read as the manager.

    `as_service("pool_manager")` and not `as_caller`: reconciling pools is the
    service's own work with no user behind it, and saying so is the point of
    that function existing separately (core/identity.py). The role matters —
    pool_manager holds SELECT on desired state and EXECUTE on
    report_pool_status(), and deliberately no write on workflow.pools, so a
    compromised manager cannot rewrite desired state to make its own actions
    look correct (pools.sql §9). Connecting as it here is what proves that
    grant set is sufficient: if the loop needed more, it fails here rather
    than in review.
    """
    from ..core import as_service

    async with as_service("pool_manager") as conn:
        row = await conn.fetchrow(
            """
            select p.*,
                   array(select queue from workflow.pool_queues where pool = p.name) as queues
              from workflow.pools p
             where p.name = $1
            """,
            name,
        )
    if row is None:
        raise typer.BadParameter(f"no pool named {name!r}")
    return dict(row)


@app.command()
def render(
    name: str = typer.Argument(..., help="pool name"),
    out_dir: str = typer.Option(None, "--out", help="write pool-deployment.yaml and "
                                                    "pool-scaledobject.yaml here"),
) -> None:
    """Print the manifests for a pool. Applies nothing, touches no cluster.

    This is not a convenience. It is how a change to the generator gets
    reviewed: the manifests are output, and output nobody can see before it is
    applied is output nobody reviews (pools.md §4.1).
    """
    dep, so = render_pool(asyncio.run(_fetch(name)))
    if out_dir:
        import pathlib
        d = pathlib.Path(out_dir)
        d.mkdir(parents=True, exist_ok=True)
        (d / "pool-deployment.yaml").write_text(dep)
        (d / "pool-scaledobject.yaml").write_text(so)
        typer.echo(f"wrote {d}/pool-deployment.yaml and {d}/pool-scaledobject.yaml")
        return
    typer.echo(dep)
    typer.echo("---")
    typer.echo(so)


@app.command()
def diff() -> None:
    """Render every enabled pool against live cluster state."""
    raise typer.Exit(_not_yet("diff"))


@app.command()
def run() -> None:
    """The reconcile loop: apply, prune, report status. Singleton by advisory lock."""
    raise typer.Exit(_not_yet("run"))


def _not_yet(what: str) -> int:
    typer.secho(
        f"`p8 pool {what}` is not implemented yet.\n"
        "  The loop it will implement is pools.md §4.2, and a working reference\n"
        "  exists in the private tree's kind harness — 21 of 21 of §12's gates pass against\n"
        "  kind. What is missing here is that loop against kubernetes-asyncio\n"
        "  rather than kubectl, with the LISTEN half §4.2 describes.\n"
        f"  `p8 pool render` is implemented and is Gate 1.",
        fg=typer.colors.YELLOW, err=True)
    return 1
