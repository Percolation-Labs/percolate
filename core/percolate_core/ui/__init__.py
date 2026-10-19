"""The percolate UI: static ES modules, served from this distribution.

No framework, no build step, no `node_modules` — the page is six files and its
whole data layer is `fetch` against PostgREST. That constraint is the design:
the browser talks to the database's own API under RLS, so this module can serve
the files and own no read path of its own. See `applications/percolate-ui/` in
p8-subsystems for the design notes and the SQL views the screens read.

    p8 ui serve      # standalone
    ui.router()      # mounted into a host app, under whatever prefix it likes
"""

from __future__ import annotations

__all__ = ["app", "router", "build_app"]


def __getattr__(name):
    """Lazy, so that importing this package does not require FastAPI.

    Same discipline as `manager`: a worker-only install imports
    `percolate_core` and must not pull a web framework to do it.
    """
    if name == "app":
        from .cli import app
        return app
    if name in ("router", "build_app"):
        from . import server
        return getattr(server, name)
    raise AttributeError(name)
