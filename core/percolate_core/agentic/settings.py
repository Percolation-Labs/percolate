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

from ..core.config import dsn_if_set


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

    # `core.config.dsn()` decides this, for this runtime and for the pool in
    # `core/identity.py`, which used to read the same two names in the opposite
    # order. A process that opened both got two databases and nothing said so.
    #
    # The reasoning that used to live here -- P8_DATABASE_URL wins because it is
    # the specific name, and the localhost default cost a deployment a restart
    # loop -- moved into that function with the decision. This is now a caller.
    # `dsn_if_set`, not `dsn`: constructing a Settings is not connecting, and
    # the tests that parse CORS origins build one without a database in sight.
    # The refusal lives at `PgClient.connect`, which is where the restart loop
    # this comment is about actually happened.
    database_url: str = field(default_factory=lambda: dsn_if_set() or "")
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
    pool_max: int = field(default_factory=lambda: int(os.getenv("P8_POOL_MAX", "16")))
    """TWO PER CONCURRENT TURN, so 16 supports eight people talking at once.

    It was 8, which reads like eight turns and was four. A turn holds one
    connection for its whole life (``db.client.PgClient.publisher``, so that a
    sixty-word answer is not sixty transactions) and takes a second for every
    query inside it. At 8, eight concurrent turns each held one and then waited
    forever for the other -- a deadlock by construction, at exactly the
    concurrency the number looks like it allows. ``core.identity.acquired`` now
    bounds that wait and puts this arithmetic in the error.

    THE PROCESS BUDGET, which is the number an operator actually needs:
    ``max_listeners`` connections (64 by default, each a dedicated
    ``asyncpg.connect`` OUTSIDE this pool, because a stream that went back to
    the pool would stop listening) plus ``pool_max``. So one runtime process can
    want 80 backends. Postgres defaults ``max_connections`` to 100 and reserves
    3 for superusers, so **two of these processes do not fit a default
    database** -- and ``workflow-engine/scale.md:281-290`` records the cluster
    version of the same sum, where 30 pods x 4 connections locked the operator
    out of their own database. Set ``max_connections``, or lower
    ``P8_MAX_LISTENERS``, but do the addition first.
    """

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
