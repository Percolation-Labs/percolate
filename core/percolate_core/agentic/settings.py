"""Runtime configuration — environment only, no config files.

Spec intent: the runtime is deployed Postgres-adjacent exactly like PostgREST
(``specs/README.md`` deployment shape, ``brief.md`` §5), so its configuration
surface is the same shape as PostgREST's: a connection string, a couple of
credentials, and nothing that encodes a use case. Anything use-case-specific is
a row in Postgres, never a setting here (``brief.md`` §5.2).
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass(slots=True)
class Settings:
    """Process-level settings, read once at startup.

    Fields deliberately absent, and why:

    - No agent/tool/model registry of any kind. Agents and tool servers are
      rows (``brief.md`` §2, §5.2); a settings entry for either would be the
      first crack in "the runtime never changes to accommodate a use case."
    - No LLM API key per agent — the key is per *provider*, resolved the way
      pydantic-ai already resolves it, and per-tool-server credentials are
      ``credential_ref`` indirections resolved at call time (``brief.md`` §9,
      open question: this collection has no secrets vault yet).
    """

    # P8_DSN IS READ TOO, and leaving it out cost a deployment. `core/config.py`
    # requires P8_DSN -- "every service connects to Postgres" -- and every other
    # entry point in this package uses it, so a compose file or chart that sets
    # it has configured the database as far as anyone reading those files can
    # tell. This runtime read only P8_DATABASE_URL, found it unset, and silently
    # took the local development default: `agent serve` restart-looped on
    # `Connect call failed ('127.0.0.1', 5500)` in a stack where every other
    # service connected fine.
    #
    # `core/identity.py` already accepted both names. That it did so in one
    # place and not the other is the whole defect -- one thing under two names,
    # agreeing only where somebody happened to write it twice.
    #
    # P8_DATABASE_URL still wins when both are set: it is the specific one, and
    # a deployment that sets it deliberately is pointing this runtime somewhere
    # other than the shared DSN on purpose.
    database_url: str = field(
        default_factory=lambda: (
            os.getenv("P8_DATABASE_URL")
            or os.getenv("P8_DSN")
            or "postgresql://p8:p8@localhost:5500/p8agentic"
        )
    )
    schema: str = field(default_factory=lambda: os.getenv("P8_SCHEMA", "agentic"))
    # The UI and runtime may have separate origins. Opt in per deployment;
    # this grants browser transport access, never identity or database access.
    cors_origins: tuple[str, ...] = field(default_factory=lambda: tuple(
        origin.strip() for origin in os.getenv("P8_CORS_ORIGINS", "").split(",")
        if origin.strip()
    ))
    tool_auth_origins: tuple[str, ...] = field(default_factory=lambda: tuple(
        origin.strip() for origin in os.getenv("P8_TOOL_AUTH_ORIGINS", "").split(",")
        if origin.strip()
    ))
    pool_min: int = field(default_factory=lambda: int(os.getenv("P8_POOL_MIN", "1")))
    pool_max: int = field(default_factory=lambda: int(os.getenv("P8_POOL_MAX", "8")))

    # The identity the runtime authenticates as. In deployment this comes from
    # the inbound request's JWT, per request; for the CLI it is a setting so a
    # local run is still a real `authenticated` caller subject to real RLS,
    # never a privileged shortcut.
    user_id: str | None = field(default_factory=lambda: os.getenv("P8_USER_ID"))
    # No gateway_url setting: where the agent gateway lives is a
    # `tool_servers` row like any other tool provider's url. A second place to
    # configure it would be a second source of truth.

    # A stream holds a connection outside the pool for its whole life, so this
    # is a real resource bound, not a tuning knob.
    max_listeners: int = field(
        default_factory=lambda: int(os.getenv("P8_MAX_LISTENERS", "64"))
    )

    default_model: str = field(
        default_factory=lambda: os.getenv("P8_DEFAULT_MODEL", "openai:gpt-4.1-mini")
    )
    # brief.md §9 open question: "how deep a delegation tree is allowed to go
    # before it's treated as a bug rather than a feature". A hard limit has to
    # exist somewhere; it lives here, and the number is still undecided.
    max_delegation_depth: int = field(
        default_factory=lambda: int(os.getenv("P8_MAX_DELEGATION_DEPTH", "3"))
    )
    # brief.md §3 / §5.1: windowing is the default context-reload policy. The
    # threshold itself is an open question at the parameter level, so it is a
    # setting with a documented default rather than a hardcoded constant.
    window_messages: int = field(
        default_factory=lambda: int(os.getenv("P8_WINDOW_MESSAGES", "20"))
    )
    # The other half of brief.md §9's "message count vs. token estimate", now
    # that pydantic-ai measures the estimate for us (see
    # persistence.needs_summarization). 0.75 leaves a quarter of the window for
    # the turn that trips it plus the summary being written -- a threshold set
    # at 1.0 fires only once there is no room left to act on it.
    summarize_at_context_fraction: float = field(
        default_factory=lambda: float(
            os.getenv("P8_SUMMARIZE_AT_CONTEXT_FRACTION", "0.75")
        )
    )
    # brief.md §3: agents.summarizer_agent_id being null "falls back to one
    # system-wide default summarizer agent" -- this names it. Still data: which
    # agent that is, is a row, not a code path.
    default_summarizer: str = field(
        default_factory=lambda: os.getenv("P8_DEFAULT_SUMMARIZER", "summarizer")
    )
    summarize_after_messages: int = field(
        default_factory=lambda: int(os.getenv("P8_SUMMARIZE_AFTER_MESSAGES", "40"))
    )

    @classmethod
    def from_env(cls) -> Settings:
        return cls()

    def __post_init__(self) -> None:
        from urllib.parse import urlsplit

        for origin in (*self.cors_origins, *self.tool_auth_origins):
            parsed = urlsplit(origin)
            if ("*" in origin or parsed.scheme not in {"http", "https"}
                    or not parsed.netloc or parsed.username or parsed.password
                    or parsed.path or parsed.query or parsed.fragment):
                raise ValueError("CORS and tool auth allowlists must contain explicit HTTP(S) origins without paths")
