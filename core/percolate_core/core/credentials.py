"""Where a credential may be sent: one resolver, and it checks before it resolves.

A credential is referenced by NAME (``core.config``) and the destination comes
from somewhere else -- a workflow row, an embedding registry row, an upload's
ingest policy, an API source. Resolving the name without looking at the
destination let whoever wrote the destination choose where the secret went.
The sharp case: ``content.register_upload`` is granted to ``authenticated``
and its ``p_metadata`` becomes the upload's ``ingest_policy``, so any signed-in
user could name a transcription ``endpoint`` on their own host and a
``credential`` of ``P8_S3_SECRET``, and the ingest worker sent that secret to
them as a bearer token.

So every sender asks ``credential_for(ref, url)``, and the operator says, once,
which origins each credential may reach::

    P8_CREDENTIAL_ORIGINS='{"LLM_API_KEY": ["https://api.openai.com"],
                            "GITHUB_TOKEN": "https://api.github.com"}'

DENY BY DEFAULT. A credential with no entry goes nowhere. The alternative --
"unlisted means unrestricted" -- is the hole: every secret in the worker's
environment is unlisted until somebody thinks of it.

``P8_INGEST_CREDENTIAL_ORIGINS`` is the same map under the name API ingestion
read first, and is still read; the two are merged, so a deployment that
configured one keeps working.

``P8_TOOL_AUTH_ORIGINS`` is NOT folded in. It says where the agent runtime may
forward the *caller's own* bearer token, which is not a named credential and
not this process's secret; it shares ``origin()`` below and nothing else.
"""

from __future__ import annotations

import json
import os
from urllib.parse import urlsplit

from .config import ConfigError, TerminalError, credential

__all__ = ["CredentialRefused", "bound_names", "credential_for", "origin"]

ORIGINS_SETTINGS = ("P8_CREDENTIAL_ORIGINS", "P8_INGEST_CREDENTIAL_ORIGINS")
"""Read in this order and merged. The second is the name API ingestion used
before there was one setting for every sender."""


class CredentialRefused(TerminalError, ConfigError):
    """A credential was asked for on the way to an origin it is not bound to.

    Terminal, because the binding is configuration and the next attempt asks
    the same question of the same configuration.
    """


def origin(url: str) -> tuple[str, str, int]:
    """(scheme, host, port) of an HTTP(S) URL, or ``ValueError``.

    The one parser every origin comparison in the package goes through. Refuses
    userinfo (``https://api.example@evil`` names evil), backslashes and
    whitespace (parsers disagree about both, and the disagreement is the
    attack), and anything that is not http or https.
    """
    parsed = urlsplit(url)
    if (parsed.scheme not in {"http", "https"} or not parsed.hostname
            or parsed.username or parsed.password or "\\" in url
            or any(c.isspace() for c in url)):
        raise ValueError("expected an HTTP(S) URL without user information")
    return (parsed.scheme, parsed.hostname.lower(),
            parsed.port or (443 if parsed.scheme == "https" else 80))


def _show(o: tuple[str, str, int]) -> str:
    scheme, host, port = o
    default = 443 if scheme == "https" else 80
    return f"{scheme}://{host}" + ("" if port == default else f":{port}")


def _bindings() -> dict[str, set[tuple[str, str, int]]]:
    """Credential name -> the origins it may reach, from every setting.

    Read per call rather than cached at import, because a worker's environment
    is its configuration and tests (and operators restarting with a new value)
    expect a change to take effect.
    """
    merged: dict[str, set[tuple[str, str, int]]] = {}
    for setting in ORIGINS_SETTINGS:
        raw = (os.environ.get(setting) or "").strip()
        if not raw:
            continue
        try:
            table = json.loads(raw)
            if not isinstance(table, dict):
                raise ValueError
            for name, allowed in table.items():
                entries = [allowed] if isinstance(allowed, str) else allowed
                if not isinstance(entries, list):
                    raise ValueError
                merged.setdefault(str(name), set()).update(origin(e) for e in entries)
        except (ValueError, TypeError):
            raise CredentialRefused(
                f"{setting} must be a JSON object mapping each credential name to "
                'an origin or a list of origins, e.g. {"LLM_API_KEY": '
                '["https://api.openai.com"]}') from None
    return merged


def bound_names() -> frozenset[str]:
    """Every credential name the operator has bound to an origin.

    ``worker.templates`` refuses these in ``{{env.X}}`` whatever else it
    allows, because a template can put a value anywhere in a request, which is
    exactly what the binding exists to stop.
    """
    return frozenset(_bindings())


def credential_for(ref: str, url: str) -> str:
    """The secret named ``ref``, if and only if ``url`` is an origin it is bound to.

    The destination is checked BEFORE the secret is read, so a refusal never
    depends on whether the secret happens to be set. Call it with the URL the
    request will actually go to -- after template resolution -- and send with
    redirects off, which httpx does by default.
    """
    # The name that will actually supply the value, for the same two spellings
    # `credential()` accepts, so the binding checked is the binding of the
    # variable that is read.
    name = ref if os.environ.get(ref) else ref.upper()
    try:
        dest = origin(url)
    except ValueError:
        raise CredentialRefused(
            f"refusing to send credential {name}: the destination is not a plain "
            "HTTP(S) URL") from None
    bindings = _bindings()
    # Either spelling of the key binds it -- API ingestion looked the binding
    # up under the ref exactly as the source row wrote it.
    if dest not in bindings.get(name, set()) | bindings.get(ref, set()):
        raise CredentialRefused(
            f"refusing to send credential {name} to {_show(dest)}: that origin is "
            f"not bound to it. If it should be, add it to P8_CREDENTIAL_ORIGINS on "
            f'this process, e.g. {{"{name}": ["{_show(dest)}"]}}.')
    return credential(name)
