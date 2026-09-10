"""One budget for a whole delegation tree, carried over the wire.

pydantic-ai's delegation guidance is a single sentence: *"pass ``ctx.usage`` to
the ``usage`` keyword argument of the delegate agent run so usage within that
run counts towards the total usage of the parent agent run."* That works because
their delegate is an in-process call and the two runs share a Python object.

**Ours is not in-process.** A delegation here is an MCP tool call over HTTP into
``gateway.run_delegated``, which starts its own ``runs`` row in its own
sequencer. There is no shared object to pass, so the child would start from zero
and a parent's ``UsageLimits`` would bind exactly one level of a tree that
``settings.max_delegation_depth`` lets go three deep with unbounded fan-out at
each level. Three levels of an agent that delegates to five agents is 155 model
turns and no ceiling on any of them.

So the object gets serialised instead. The parent sends what it has already
spent and what the tree is allowed to spend; the child seeds its ``RunUsage``
with the former, applies the latter, and sends its own total back up in the tool
result. Same contract as pydantic-ai's, one HTTP hop wider.

**The accounting is deliberately conservative, and that is a real limitation.**
Usage flows *down* on the request and *back up* on the response, so two siblings
delegated concurrently from one parent each see the parent's spend at the moment
they were dispatched and neither sees the other's. Their totals are correct
individually and the tree total is correct once both have returned, but during
execution the budget is checked against a stale figure and a tree can overshoot
by up to what its in-flight siblings spend. Sequential delegation is exact.

The alternative -- a shared counter in Postgres, decremented under a lock -- is
strictly more correct and costs a round trip on every model call inside a
transaction the run does not otherwise need. That trade is worth making when
somebody can show the overshoot mattering; it is recorded here so the choice is
visible rather than discovered. The overshoot is bounded by fan-out, and the
depth limit bounds fan-out.

None of this replaces ``rbac.has_quota_remaining()``, which is a per-user budget
across all runs and is checked before every LLM call. This is a per-tree budget
and it is checked by pydantic-ai inside one. A user can be inside their quota
and still have one runaway tree; that is the case this exists for.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from typing import Any

# One header, not six. The alternative was `x-p8-usage-input-tokens` and friends,
# which turns adding a field to `RunUsage` into a change in three files here --
# and `RunUsage` gained `cache_write_tokens`, `cache_audio_read_tokens` and
# `tool_calls` across versions this package has already shipped against.
USAGE_HEADER = "x-p8-usage"
"""What the tree has already spent, as compact JSON. Absent means a root run."""

BUDGET_HEADER = "x-p8-budget"
"""What the whole tree may spend, as compact JSON. Absent means unlimited."""

# Only the fields that are budgets. `RunUsage` also carries `details`, audio
# counts and cache breakdowns; those are recorded on the run row, not spent
# against a limit, and shipping them here would put unbounded provider-specific
# JSON in a header.
_USAGE_FIELDS = ("input_tokens", "output_tokens", "requests", "tool_calls", "cost")

_LIMIT_FIELDS = (
    "request_limit",
    "tool_calls_limit",
    "input_tokens_limit",
    "output_tokens_limit",
    "total_tokens_limit",
    "cost_limit",
)


@dataclass(frozen=True)
class Budget:
    """A tree's allowance and what it has spent so far.

    Both halves are optional and mean different things when absent: no limits is
    "this deployment does not budget", no usage is "this is the root".
    """

    limits: dict[str, Any] | None = None
    spent: dict[str, Any] | None = None

    # -- construction ------------------------------------------------------

    @classmethod
    def from_env(cls) -> Budget:
        """Deployment-wide default limits, off unless configured.

        Off by default on purpose. A limit invented here would be a number
        nobody chose, applied to every agent in every deployment, and the first
        thing it did would be to fail somebody's legitimate long run at 3am. An
        operator who sets `P8_TREE_TOTAL_TOKENS_LIMIT` has chosen one.
        """
        env = {
            "request_limit": _int_env("P8_TREE_REQUEST_LIMIT"),
            "tool_calls_limit": _int_env("P8_TREE_TOOL_CALLS_LIMIT"),
            "total_tokens_limit": _int_env("P8_TREE_TOTAL_TOKENS_LIMIT"),
            "cost_limit": _float_env("P8_TREE_COST_LIMIT"),
        }
        limits = {k: v for k, v in env.items() if v is not None}
        return cls(limits=limits or None)

    @classmethod
    def from_headers(cls, headers: dict[str, str]) -> Budget:
        """The child's side. Malformed values are ignored, not fatal.

        A delegation that fails because a *budget* header would not parse turns
        an accounting concern into an outage, and the header is written by this
        same package one hop away -- if it is malformed something is already
        wrong and the useful behaviour is to run the child unbudgeted and let
        the parent's own limit still bite when the result comes back.
        """
        lower = {k.lower(): v for k, v in headers.items()}
        return cls(
            limits=_load(lower.get(BUDGET_HEADER)),
            spent=_load(lower.get(USAGE_HEADER)),
        )

    # -- the wire ----------------------------------------------------------

    def to_headers(self, spent: Any = None) -> dict[str, str]:
        """What a parent sends down with a delegation.

        ``spent`` is the parent's live ``RunUsage``; the tree's running total is
        whatever it inherited plus what it has spent itself, so a grandchild is
        charged for its grandparent too.
        """
        out: dict[str, str] = {}
        if self.limits:
            out[BUDGET_HEADER] = json.dumps(self.limits, separators=(",", ":"))
        total = _merge(self.spent, usage_dict(spent))
        if total:
            out[USAGE_HEADER] = json.dumps(total, separators=(",", ":"))
        return out

    def charge(self, spent: dict[str, Any] | None) -> Budget:
        """This tree, after a turn. Frozen, so charging returns a new one.

        Takes the already-flattened dict from ``ExecutionResult.usage`` rather
        than a ``RunUsage``, because by this point the turn is over and the row
        is what matters -- and because a dict keeps the sequencer from importing
        pydantic-ai to add two numbers.
        """
        merged = _merge(self.spent, spent)
        return Budget(limits=self.limits, spent=merged or None)

    # -- what the runtime hands pydantic-ai --------------------------------

    def usage_limits(self) -> Any | None:
        """``UsageLimits``, or None when nothing is budgeted.

        Imported here rather than at module scope: this module is imported by
        the delegation contract, which the base install can read without
        ``[agent]`` present.
        """
        if not self.limits:
            return None
        from pydantic_ai.usage import UsageLimits

        known = {k: v for k, v in self.limits.items() if k in _LIMIT_FIELDS}
        return UsageLimits(**known) if known else None

    def seed_usage(self) -> Any | None:
        """A ``RunUsage`` pre-charged with what the tree already spent.

        This is the whole trick, and it is the same one pydantic-ai performs by
        passing the parent's object: a limit applies to the sum, so the child
        must begin already holding its ancestors' spend rather than at zero.
        """
        if not self.spent:
            return None
        from pydantic_ai.usage import RunUsage

        known = {k: v for k, v in self.spent.items() if k in _USAGE_FIELDS}
        return RunUsage(**known) if known else None


def usage_dict(usage: Any) -> dict[str, Any]:
    """``RunUsage`` -> a plain dict of the budgeted fields, tolerantly.

    Tolerant because this runs on the result path of every turn, and a field
    that moved between pydantic-ai versions must not be able to fail a run whose
    model call already succeeded and was already streamed to the client. The
    cost of a missing field here is a number absent from a row; the cost of
    raising is a completed turn reported as failed.
    """
    if usage is None:
        return {}
    out = {}
    for field in _USAGE_FIELDS:
        value = getattr(usage, field, None)
        if isinstance(value, (int, float)) and value:
            out[field] = value
    return out


def _merge(a: dict[str, Any] | None, b: dict[str, Any] | None) -> dict[str, Any]:
    out = dict(a or {})
    for k, v in (b or {}).items():
        out[k] = out.get(k, 0) + v
    return out


def _load(raw: str | None) -> dict[str, Any] | None:
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except (ValueError, TypeError):
        return None
    return value if isinstance(value, dict) else None


def _int_env(name: str) -> int | None:
    raw = os.getenv(name)
    try:
        return int(raw) if raw else None
    except ValueError:
        return None


def _float_env(name: str) -> float | None:
    raw = os.getenv(name)
    try:
        return float(raw) if raw else None
    except ValueError:
        return None
