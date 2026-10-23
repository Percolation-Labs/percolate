"""Worker pools: rows in Postgres, Deployments and KEDA ScaledObjects out.

The fifth subpackage, alongside `core`, `worker`, `content` and `agentic`.
`specs/workflow-engine/pools.md` §4.1: the subpackage is `manager`, the
command group is `pool` — a command names the thing being operated on, not the
process that implements it.

    p8 pool render <name>    print what would be applied, apply nothing
    p8 pool diff             render against live cluster state
    p8 pool run              the reconcile loop

`render` needs neither a cluster nor a database beyond the row it is given,
which is why it is the part that is tested here. `diff` and `run` need both.
"""

from __future__ import annotations

__all__ = ["app"]


def __getattr__(name):
    """`app` is imported lazily, and that is the whole point.

    Rendering is a pure function of a row and must stay importable with nothing
    installed -- `python3 tests/test_pool_render.py` on a bare interpreter is
    the gate. Importing the Typer app here would put the CLI framework in front
    of it, and a gate that needs a dependency to run is a gate that gets
    skipped on the machine where it matters. Same lazy-import discipline
    cli.py's `_subcommands()` already uses for the extras.
    """
    if name == "app":
        from .cli import app
        return app
    raise AttributeError(name)
