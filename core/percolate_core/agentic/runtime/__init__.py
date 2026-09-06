"""The four components of ``brief.md`` §5.1, plus §4's chained action and §5.3's
citations — one module each, so a reviewer can check the spec section by section.

1. ``persistence``       — Postgres persistence adapter, and the context policy.
2. ``protocol_adapter``  — OpenAI-shaped in, AG-UI out.
3. ``delegation``        — declarative multi-agent delegation.
4. ``injection``         — request-sourced ambient context.

``engine`` is the thin wrapper around pydantic-ai they all hang off.
"""

from .chained_action import fire as fire_chained_action
from .citations import derive as derive_citations
from .delegation import (
    check_depth,
    child_run,
    inbound_delegation,
    outbound_headers,
)
from .engine import AgentEngine, ExecutionResult
from .injection import build_deps, build_instructions
from .persistence import PersistenceAdapter
from .protocol_adapter import (
    EventSink,
    apply_response_format,
    channel,
    latest_user_prompt,
    relay,
)

__all__ = [
    "AgentEngine",
    "EventSink",
    "ExecutionResult",
    "PersistenceAdapter",
    "build_deps",
    "build_instructions",
    "channel",
    "check_depth",
    "child_run",
    "derive_citations",
    "fire_chained_action",
    "inbound_delegation",
    "apply_response_format",
    "latest_user_prompt",
    "outbound_headers",
    "relay",
]
