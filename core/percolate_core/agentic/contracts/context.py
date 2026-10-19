"""Ambient context — sourced from the request, never from the conversation.

``brief.md`` §5.1 item 4: context an agent needs but that isn't conversation
content (current date/time, tenant, request-scoped metadata) arrives as HTTP
headers, "kept separate from ``messages`` on purpose, so it never has to be
replayed, summarized, or accidentally dropped by the persistence adapter's
context policy — since it was never conversation content to begin with."

The contract is now defined in §5.1 item 4 rather than open: one ``x-p8-*``
prefix, unknown headers forwarded into typed ``deps``, documented defaults for
absent ones. It is also what carries a delegation's session, parent run and
trace to the agent gateway — one mechanism in both directions.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field

HEADER_PREFIX = "x-p8-"
"""Every injected header shares one prefix so an unknown one is still
forwardable to the agent's ``deps`` without a code change here."""


class RequestContext(BaseModel):
    """Parsed ambient context for one inbound request.

    Absent headers take documented defaults (``now``, ``locale``) and identity
    fields stay ``None`` — one decision point, rather than ``or "utc"``
    fallbacks scattered through the runtime.
    """

    user_id: UUID | None = None
    tenant: str | None = None
    now: datetime = Field(default_factory=lambda: datetime.now(UTC))
    locale: str = "en-US"
    trace_id: str | None = Field(
        default=None,
        description=(
            "Continue, don't restart, an upstream trace — the same rule as "
            "everywhere else in this collection (brief.md §7)."
        ),
    )
    extra: dict[str, str] = Field(
        default_factory=dict, description="Any other x-p8-* header, forwarded verbatim."
    )

    @classmethod
    def from_headers(cls, headers: dict[str, str]) -> RequestContext:
        """Parse the ``x-p8-*`` headers into typed ambient context.

        Shell: a straight, tolerant parse — unknown ``x-p8-*`` headers land in
        ``extra`` rather than erroring, because a strict parse would make adding
        a header a runtime code change, which §5.2's "the runtime never changes
        to accommodate a use case" rules out.
        """
        lower = {k.lower(): v for k, v in headers.items()}
        extra = {
            k[len(HEADER_PREFIX) :]: v
            for k, v in lower.items()
            if k.startswith(HEADER_PREFIX)
        }
        known = {
            "user_id": extra.pop("user-id", None),
            "tenant": extra.pop("tenant", None),
            "locale": extra.pop("locale", None),
        }
        # W3C traceparent is `00-<trace-id>-<span-id>-<flags>`; the trace id is
        # the second field, not the whole header. Storing the whole thing looks
        # fine until something tries to correlate with a real tracer.
        traceparent = lower.get("traceparent")
        trace = extra.pop("trace-id", None)
        if traceparent and traceparent.count("-") == 3:
            trace = traceparent.split("-")[1]
        elif traceparent:
            trace = traceparent
        return cls(
            user_id=UUID(known["user_id"]) if known["user_id"] else None,
            tenant=known["tenant"],
            locale=known["locale"] or "en-US",
            trace_id=trace,
            extra=extra,
        )


    def to_headers(self) -> dict[str, str]:
        """The inverse of ``from_headers`` — how context propagates *outward*.

        Not a debugging convenience: a delegated call is an MCP call to the
        agent gateway (``brief.md`` §5.1 item 3), and this is the mechanism that
        carries the sub-run's tenant, locale and trace across it. One mechanism
        in both directions means a delegated agent sees exactly what a directly
        invoked one sees, with nothing invented for the delegation case.
        """
        headers = {f"{HEADER_PREFIX}locale": self.locale}
        if self.user_id:
            headers[f"{HEADER_PREFIX}user-id"] = str(self.user_id)
        if self.tenant:
            headers[f"{HEADER_PREFIX}tenant"] = self.tenant
        if self.trace_id:
            headers["traceparent"] = self.trace_id
        for key, value in self.extra.items():
            headers[f"{HEADER_PREFIX}{key}"] = value
        return headers


class AgentDeps(BaseModel):
    """pydantic-ai's typed ``deps`` for one run.

    ``brief.md`` §5.1 item 4 allows ambient context to reach the model two ways
    — templated into the system prompt, or passed as typed ``deps``. Both are
    supported by ``runtime.injection``; this is the typed half.
    """

    context: RequestContext
    session_id: UUID | None = None
    run_id: UUID | None = None
    agent_name: str | None = None
    scratch: dict[str, Any] = Field(default_factory=dict)
