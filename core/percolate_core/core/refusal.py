"""The database refused this caller, decided once (REM-67).

Every authorization rule in this collection lives in Postgres -- RLS policies
and the `may_*` predicates the extension's SECURITY DEFINER functions call --
so the answer "you may not do that" arrives here as a raised Postgres error,
never as something this process worked out for itself. Whoever catches it has
to recognise it, and the recognitions had drifted: the agent runtime did not
recognise it at all (`agentic.start_run`'s refusal reached a caller as a bare
HTTP 500, and `agentic.upsert_tool_server`'s as `502 Tool discovery failed`,
after discovery had succeeded), the Content Server called it a 400, and the
CLI matched `RaiseError` by name, which is a different SQLSTATE.

**The rule is the SQLSTATE and nothing else: 42501, `insufficient_privilege`.**
Not the message text. Postgres itself raises 42501 for a denied grant and for
a row an RLS policy refuses; the extension raises it for its own refusals
(`agentic.invoke` -- "needs agents:invoke", `content.register_upload`,
`lake.*`, `content.save_api_source`); and PostgREST, the CRUD half of the same
API, already answers 42501 with 403 and P0001 with 400. So a rule keyed on the
SQLSTATE makes the two HTTP surfaces over this database agree, and it holds for
an error Postgres raises that nobody wrote a message for.

The extension's older authorization raises carried no errcode at all, which is
why the rule could not be written before: they are P0001, indistinguishable
from a validation message. Those raises now say `using errcode =
'insufficient_privilege'` (p8-subsystems, REM-67), which is where the fact
belongs -- the database is the only layer that knows a refusal is a refusal.

`message` and `hint` are carried through to the caller deliberately. A refusal
names the permission it wants ("needs agents:invoke, and the agent must be
visible to you"), and that sentence is the difference between a person granting
themselves the permission and a person filing a bug about a 500.

Stdlib only, like the rest of `core`: this reads the attributes asyncpg puts on
a `PostgresError` without importing asyncpg, so the CLI keeps its lazy import.
"""

from __future__ import annotations

from dataclasses import dataclass

__all__ = ["SQLSTATE", "STATUS", "Refusal", "refusal"]

SQLSTATE = "42501"
"""`insufficient_privilege`. The one thing this module tests."""

STATUS = 403
"""What a refusal is over HTTP. 401 is "who are you", and by the time the
database has refused, the token was verified and the answer is "not you"."""


@dataclass(frozen=True)
class Refusal:
    """What the database said when it refused, as a caller should hear it."""

    message: str
    hint: str | None = None

    def __str__(self) -> str:
        return self.message + (f" ({self.hint})" if self.hint else "")

    def body(self) -> dict[str, str]:
        """The JSON body for an HTTP surface.

        `detail` is FastAPI's field for the sentence a client shows, and the
        browser client reads exactly that. `code` and `hint` are PostgREST's
        names for the same two values, so a client that already parses a
        PostgREST error parses this one.
        """
        body = {"detail": self.message, "code": SQLSTATE}
        if self.hint:
            body["hint"] = self.hint
        return body


def refusal(exc: BaseException) -> Refusal | None:
    """A `Refusal` if the database refused this caller, otherwise None.

    The exception itself, not its `__cause__` chain: a refusal that something
    has already wrapped has been given a meaning by whoever wrapped it, and
    reaching past that to overrule it is how one error acquires two answers.
    """
    if getattr(exc, "sqlstate", None) != SQLSTATE:
        return None
    # asyncpg sets `message` when the error came off the wire; a hand-built one
    # (the tests, and `asyncpg.InsufficientPrivilegeError("...")`) has only args.
    message = getattr(exc, "message", None) or str(exc).split("\n")[0]
    return Refusal(message=message, hint=getattr(exc, "hint", None))
