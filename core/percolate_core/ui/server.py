"""Serve the UI — a router, a config document, and the static files.

`meta/module-composition.md`: a subpackage exposes its HTTP surface as a
`router()` the host includes under a prefix *it* chooses, and its standalone
mode is a caller of that router rather than a second implementation. This one
needs no `lifespan()` — it opens no connection and holds no state, because the
browser talks to PostgREST directly and this process only hands it the files.

That is the whole point of serving it from here rather than building a backend
for it: **nothing added to this module can become a second authorization path.**
There is no route here that reads a row. If one ever appears, the property this
UI is built on has been given up, and the review question is whether that was
deliberate.

WHY THE FILES ARE READ THROUGH `importlib.resources` AND NOT `StaticFiles`.
A `StaticFiles` mount needs a real directory, which an installed wheel usually
but not always provides, and a router cannot mount a sub-app anyway — mounting
is an application-level operation, so a module that used it would compose into a
host differently from how it runs alone. Reading package data keeps one code
path for both.
"""

from __future__ import annotations

import mimetypes
import os
from importlib import resources

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse, JSONResponse, Response

from .. import __version__

# The files, listed rather than globbed. A directory listing would serve
# whatever happened to be in the package, including an editor's backup of a file
# with a token in it; this serves what the UI is.
#
# A module missing from this tuple 404s and takes the whole page down with it,
# so `tests/test_ui_reads.py` asserts that every module the UI imports is here
# rather than leaving it to whoever adds the next one to remember.
ASSETS = ("index.html", "api.js", "ui.js", "workspace.js", "md.js", "reads.js", "views.js",
          "access.js", "chat-stream.js", "cron.js", "schedule-assist.js", "agent-authoring.js",
          "agent-assist.js", "agent-editor.js", "workbench.js", "drafts.js", "query-assist.js", "workflow-authoring.js", "workflow-plan.js", "workflow-assist.js", "workflow-composer.js", "help.md", "files.js", "sources.js", "source-authoring.js", "source-assist.js", "api-sources.js", "api-source-authoring.js", "api-source-assist.js", "theme.css")


def _read(name: str) -> bytes:
    if name not in ASSETS:
        raise HTTPException(404, f"no such asset: {name}")
    return (resources.files(__package__) / "static" / name).read_bytes()


def config() -> dict:
    """What the browser needs to know about this deployment, and nothing else.

    The UI ships with localhost defaults so it can be opened as a file during
    development. Served, it must not: a client guessing where PostgREST lives is
    a client that guesses wrong in every deployment but one. So the server says,
    and the page asks its own origin.

    `dev_token` is off unless a deployment turns it on. The sign-in page can
    mint its own JWT with the PGRST secret, which is right for a workbench whose
    secret is printed in a compose file and is a hole anywhere else — so the
    server decides whether that control exists, not the page.
    """
    dev = os.environ.get("P8_UI_DEV_TOKEN", "") == "1"
    return {
        "rest": os.environ.get("P8_UI_REST_URL", "http://localhost:5611"),
        "core": os.environ.get("P8_UI_CORE_URL", ""),
        "content": os.environ.get("P8_UI_CONTENT_URL", ""),
        "workflow_queue": os.environ.get("P8_UI_WORKFLOW_QUEUE", "http"),
        "ingest_queue": os.environ.get("P8_UI_INGEST_QUEUE", "ingest"),
        "dev_token": dev,
        # The signing secret comes from the DEPLOYMENT, and only when that
        # deployment has asked for browser-side minting. It used to be a default
        # in the page -- which meant a published wheel carried a string shaped
        # exactly like a JWT signing key. Inert (it is the dev compose file's
        # throwaway value, already public) and still wrong: a package should not
        # ship a credential-shaped constant, and the next person to copy the
        # pattern will not be using a throwaway.
        "dev_secret": (os.environ.get("P8_UI_DEV_SECRET")
                       or os.environ.get("PGRST_JWT_SECRET")
                       or os.environ.get("P8_JWT_SECRET") or "") if dev else "",
        "version": __version__,
    }


def router() -> APIRouter:
    r = APIRouter()

    @r.get("/", response_class=HTMLResponse)
    async def index() -> HTMLResponse:
        return HTMLResponse(_read("index.html"))

    @r.get("/config.json")
    async def ui_config() -> JSONResponse:
        # No caching: this is the one file whose correct value changes when the
        # deployment moves, and a stale copy points a browser at the wrong
        # database.
        return JSONResponse(config(), headers={"Cache-Control": "no-store"})

    @r.get("/{asset}")
    async def asset(asset: str) -> Response:
        media, _ = mimetypes.guess_type(asset)
        return Response(_read(asset), media_type=media or "application/octet-stream",
                        headers={"Cache-Control": "no-cache"})

    return r


def build_app():
    """Standalone mode: an app that includes the router. Twenty lines, and a
    caller of the mountable piece rather than a copy of it."""
    from fastapi import FastAPI

    app = FastAPI(title="percolate ui", version=__version__)
    app.include_router(router())
    return app


def serve(host: str = "0.0.0.0", port: int | None = None) -> None:
    import uvicorn

    # Resolved here rather than as a Typer default, for the reason content/cli.py
    # records: a default in the option is a value, so it wins over the
    # environment variable the module documents.
    port = port or int(os.environ.get("P8_UI_PORT", "8082"))

    # P8_UI_RELOAD exists because ASSETS is evaluated at import and everything
    # else in this module is read from disk per request. So editing a served
    # file works live, and ADDING one does not: the new module 404s, the page's
    # import graph fails, and the whole UI goes blank with nothing in the server
    # log. It has cost two debugging sessions in one day. Under a source mount
    # the fix is for the process to restart itself when the file it reads the
    # tuple from changes; in production nothing is mounted and this stays off.
    if os.environ.get("P8_UI_RELOAD") == "1":
        uvicorn.run("percolate_core.ui.server:build_app", factory=True,
                    host=host, port=port, reload=True,
                    reload_dirs=[str(resources.files(__package__))])
        return
    uvicorn.run(build_app(), host=host, port=port)
