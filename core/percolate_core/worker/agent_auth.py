"""Authenticate compiled agent steps as the database-verified run owner.

The signing key is a mounted secret FILE, never a template-readable environment
value. A workflow can resolve env.* in HTTP bodies, so putting this key in the
generic worker's environment would give workflow authors a signing oracle.

TWO ENDPOINTS, NOT ONE, and the second is the one scheduled runs actually use.
This module matched a single exact string, ``{{env.P8_AGENT_URL}}/v1/chat/
completions``. The documented scheduled-run step calls ``{{env.P8_AGENT_URL}}/
internal/run`` (``specs/workflow-engine/README.md`` §"scheduled runs"), which
did not match -- so every scheduled agent run in the shipped deployment
authenticated with the static shared ``P8_API_KEY`` instead of the identity of
whoever scheduled it, and RLS applied that one identity's scope to the whole
night's work. A confused deputy on a cron entry (OWASP ASI03).

The runtime side was already right: ``/internal/run`` verifies a token through
``core.identity.claims_from_jwt`` like every other path and refuses without
one. It simply never received a token. Only the worker's matcher was wrong.
"""
import os
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

from ..core.identity import mint_jwt
from .templates import TerminalError

AGENT_URL_TEMPLATE = "{{env.P8_AGENT_URL}}"

# Every path on the runtime a compiled step may address as the run owner. Both
# are first-party endpoints of the same service; a path not on this list gets no
# minted identity, whatever host it names.
AGENT_PATHS = ("/v1/chat/completions", "/internal/run")

# The two template forms the compiler emits, named so callers and tests refer to
# a constant rather than retyping the string. AGENT_URL keeps its old name and
# meaning; AGENT_RUN_URL is the one that was missing.
AGENT_URL = AGENT_URL_TEMPLATE + AGENT_PATHS[0]
AGENT_RUN_URL = AGENT_URL_TEMPLATE + AGENT_PATHS[1]


def _configured_origin() -> tuple[str, str] | None:
    """The runtime's ``(scheme, netloc)`` from P8_AGENT_URL, or None if unusable.

    A credential-bearing request is only ever sent to an origin this process was
    configured with, so anything ambiguous is treated as no configuration at all
    rather than as something to normalise into shape.
    """
    parsed = urlsplit(os.environ.get("P8_AGENT_URL", "").rstrip("/"))
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment):
        return None
    return parsed.scheme, parsed.netloc


def _agent_path(url: str) -> str | None:
    """The runtime path this template url addresses, or None.

    THE TEMPLATE FORM ONLY, deliberately. A literal url that happens to resolve
    to the runtime does not qualify, and neither does one built from run input
    -- ``tests/test_worker_agent_auth.py`` asserts that a step whose url comes
    from ``{{run.target}}`` mints nothing, because run input is data a caller
    can write and minting on it would turn this into a signing oracle for
    whoever can start a run.

    So the eligible set stays exactly what the compiler emits. What changed is
    that it is now two paths rather than one.
    """
    for path in AGENT_PATHS:
        if url == AGENT_URL_TEMPLATE + path:
            return path
    return None


def uses_run_identity(spec: dict) -> bool:
    """Whether this step should be authenticated as the run's owner.

    A pre-filter, called on the UNRESOLVED spec in ``worker/loop.py`` to decide
    whether to pay for a ``workflow.task_owner`` lookup. The security decision
    is ``agent_authorization`` below, against the resolved url.
    """
    return bool(os.environ.get("P8_AGENT_SIGNING_KEY_FILE")) and (
        _agent_path(spec.get("url") or "") is not None
        and spec.get("credential_ref") == "P8_API_KEY"
        and spec.get("method", "GET").upper() == "POST"
    )


def agent_authorization(original: dict, resolved: dict, caller: str | None,
                        starter: dict | None = None, *, task_id: str | None = None,
                        worker_id: str | None = None, attempt: int | None = None) -> str | None:
    """The Authorization header for a compiled agent step: the run owner, and the agent that started the run.

    STARTER, NOT ONLY OWNER (REM-247). ``workflow.task_principal`` returns the
    run's starter beside its owner, from the columns REM-171 records. A run a
    person's agent started mints ``actor`` and ``api_key_id`` too, so the
    runtime's ``rbac.decide`` refuses a human-only capability, a scope the key
    lacks and a key revoked since the run began. It minted ``{sub, role}``
    alone before, which let such a step call the runtime as the person. A
    person's run, and a run from before the starter was recorded, keep the
    owner-only token.
    """
    if not uses_run_identity(original):
        return None
    origin = _configured_origin()
    resolved_url = resolved.get("url") or ""
    parsed = urlsplit(resolved_url)
    # The resolved url is what the request is actually sent to, so it -- not the
    # template it came from -- is what has to match the configured runtime.
    if (origin is None
            or (parsed.scheme, parsed.netloc) != origin
            or parsed.path not in AGENT_PATHS
            or parsed.query or parsed.fragment):
        raise TerminalError("Agent identity can only be sent to the configured runtime endpoint")
    try:
        owner = str(UUID(str(caller)))
    except (TypeError, ValueError):
        raise TerminalError("Agent task has no verified run owner") from None
    try:
        secret = Path(os.environ["P8_AGENT_SIGNING_KEY_FILE"]).read_text().strip()
    except OSError:
        raise TerminalError("The agent signing key file cannot be read; check the worker's secret mount") from None
    if not secret:
        raise TerminalError("The agent signing key file is empty")
    extra = {}
    # Supplied by the worker after task_principal checked its lease; never taken from a step body.
    if task_id is not None:
        if not worker_id or not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
            raise TerminalError("Agent task has no verified lease attempt")
        extra["workflow_worker_id"] = worker_id
        extra["workflow_attempt"] = attempt
        try:
            extra["workflow_task_id"] = str(UUID(str(task_id)))
        except ValueError:
            raise TerminalError("Agent task has no verified task id") from None
    if starter and starter.get("actor") == "agent":
        extra["actor"] = "agent"
        if starter.get("credential_id") is not None:
            try:
                extra["api_key_id"] = str(UUID(str(starter["credential_id"])))
            except ValueError:
                raise TerminalError("Agent task's starting credential is not a key id") from None
    return "Bearer " + mint_jwt(owner, secret, role="authenticated", ttl_seconds=300, extra=extra or None)
