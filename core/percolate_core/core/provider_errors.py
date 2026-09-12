"""What a failed provider response means, decided once (REM-53).

Every process here that calls a provider -- the http_call handler, corpus and
lake embedding, transcription, API ingestion -- has to answer the same
question when the response is an error: will asking again help? It used to be
answered four times. The http_call handler learned that a 429 saying the
ACCOUNT has no credit is not a rate limit (797 extraction tasks each queued
five attempts against an account that could not succeed, dogfood backfill,
2026-09-11); embedding, transcription and API ingestion had not, and
transcription retried a refused key as well. Each fix was right for the file
it touched and left the other three.

So the answer lives here and the call sites only phrase it. The rules:

* 401 and 403: the provider refused the credential. Terminal; a revoked key
  is revoked on the fifth attempt too.
* 402, and a 429 whose error field says `insufficient_quota` or
  `credit_balance_exhausted`: the account has no credit left. Terminal.
* 408, any other 429, 5xx: the provider's problem, worth waiting out.
* Any other 4xx: the request is wrong and will be wrong again. Terminal.

Read from the status and the provider's own error field, never from message
text. Stdlib only, like the rest of ``core``: callers pass the status and the
body they already hold, so a streaming client reads the body first.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from .config import TerminalError

__all__ = ["Failure", "QUOTA_CODES", "classify", "raise_for"]

# The error codes OpenAI-shaped APIs use for an account out of credit, as
# opposed to a request rate that is too high (`rate_limit_exceeded`).
QUOTA_CODES = frozenset({"insufficient_quota", "credit_balance_exhausted"})

_WHY = {
    "auth": "the provider refused the credential; check the key and its permissions",
    "quota": "the provider account has no credit left; retrying will not help",
    "client": "the provider rejected the request; it will be rejected again",
    "rate_limited": "rate limited by the provider; worth retrying",
    "timeout": "the provider timed out; worth retrying",
    "server": "the provider failed; worth retrying",
}


@dataclass(frozen=True)
class Failure:
    status: int
    reason: str  # one of _WHY's keys
    terminal: bool

    @property
    def why(self) -> str:
        return _WHY[self.reason]


def _out_of_credit(body: str | bytes | None) -> bool:
    try:
        err = json.loads(body or b"").get("error") or {}
    except (ValueError, AttributeError):
        return False
    if not isinstance(err, dict):
        return False
    return bool({err.get("type"), err.get("code")} & QUOTA_CODES)


def classify(status: int, body: str | bytes | None = None) -> Failure | None:
    """None for a success; otherwise what the failure is and whether it recurs."""
    if status < 400:
        return None
    if status in (401, 403):
        return Failure(status, "auth", True)
    if status == 402 or (status == 429 and _out_of_credit(body)):
        return Failure(status, "quota", True)
    if status == 429:
        return Failure(status, "rate_limited", False)
    if status == 408:
        return Failure(status, "timeout", False)
    if status >= 500:
        return Failure(status, "server", False)
    return Failure(status, "client", True)


def raise_for(status: int, body: str | bytes | None, what: str, detail: str = "") -> None:
    """Raise TerminalError or a retryable RuntimeError for an error status.

    `what` names the call ("embedding endpoint"); `detail` is appended as is,
    and is the caller's choice -- API ingestion leaves the body out, because a
    response body from an arbitrary API is not an operator message.
    """
    failure = classify(status, body)
    if failure is None:
        return
    message = f"{what} returned HTTP {status}: {failure.why}"
    if detail:
        message += f": {detail}"
    raise (TerminalError if failure.terminal else RuntimeError)(message)
