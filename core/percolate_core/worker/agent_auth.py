"""Authenticate compiled agent steps as the database-verified run owner.

The signing key is a mounted secret FILE, never a template-readable environment
value. A workflow can resolve env.* in HTTP bodies, so putting this key in the
generic worker's environment would give workflow authors a signing oracle.
"""
import os
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID

from ..core.identity import mint_jwt
from .templates import TerminalError

AGENT_URL = "{{env.P8_AGENT_URL}}/v1/chat/completions"


def uses_run_identity(spec: dict) -> bool:
    return bool(os.environ.get("P8_AGENT_SIGNING_KEY_FILE")) and (
        spec.get("url") == AGENT_URL
        and spec.get("credential_ref") == "P8_API_KEY"
        and spec.get("method", "GET").upper() == "POST"
    )


def agent_authorization(original: dict, resolved: dict, caller: str | None) -> str | None:
    if not uses_run_identity(original):
        return None
    target = os.environ.get("P8_AGENT_URL", "").rstrip("/")
    parsed = urlsplit(target)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or resolved.get("url") != target + "/v1/chat/completions"):
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
    return "Bearer " + mint_jwt(owner, secret, role="authenticated", ttl_seconds=300)
