"""What a failed turn means for the workflow task that started it.

A scheduled run reaches this runtime through `/internal/run`, dispatched by an
async http_call step (brief.md §3), and the runtime completes that task itself
when the run is done. A run that ended any other way -- an exception inside the
turn, a quota cutoff, a failed chained action -- said nothing to the task, so
the workflow waited: first for the reaper, and, once the dispatching worker
holds the task, for the step's whole wait bound, with no reason recorded.

Terminal or retryable is decided by rules this package already has, per cause:

* The database refused the caller or rejected what was written --
  `worker.loop.PERMANENT_DB_ERRORS` (42501, integrity, data). The next attempt
  asks the same question of the same grants and rows.
* The model provider answered with an error -- `core.provider_errors.classify`
  on its status and body, the rule every other provider call obeys: a refused
  credential, an account with no credit and a malformed request are terminal;
  a 5xx and a plain 429 are not.
* The run's usage limit is spent, and it is spent on the next attempt too.
* There is nothing to run: no agent by that name the caller can see
  (`sequencer.AgentNotFound`), or no verified caller (`PermissionError`).
  Not every `LookupError`: `KeyError` and `IndexError` are LookupErrors too,
  and one raised by a bug inside a turn is left to the retry budget.
* A `TerminalError`, which says so itself.

Everything else -- a dropped connection, a deadlock, a timeout -- is retryable,
which is what the engine's retry budget is for.
"""

from __future__ import annotations


def failure_is_terminal(exc: BaseException) -> bool:
    """True if another attempt at this turn would fail the same way."""
    from ..core.config import TerminalError
    from ..worker.loop import PERMANENT_DB_ERRORS
    from .sequencer import AgentNotFound

    if isinstance(exc, (TerminalError, AgentNotFound, PermissionError) + PERMANENT_DB_ERRORS):
        return True
    try:
        from pydantic_ai.exceptions import UsageLimitExceeded
    except ImportError:  # the agent extra is not installed; nothing below can occur
        return False
    if isinstance(exc, UsageLimitExceeded):
        return True
    failure = provider_failure(exc)
    return bool(failure and failure.terminal)


def provider_failure(exc: BaseException):
    """The model provider's error response, classified, or None if `exc` is not one.

    One reading for both ways a turn is asked for: a scheduled run fails its
    task with it above, and a synchronous `/chat` answers with the provider's
    own status (`api._complete`), so the worker's `raise_for` applies the same
    rule rather than reading every failure as a retryable 502 (REM-987).
    """
    from ..core.provider_errors import classify

    try:
        from pydantic_ai.exceptions import ModelHTTPError
    except ImportError:  # the agent extra is not installed; nothing below can occur
        return None
    if not isinstance(exc, ModelHTTPError):
        return None
    body = exc.body
    # The OpenAI SDK unwraps `{"error": {...}}` before pydantic-ai keeps the
    # body, and classify reads the provider's envelope: without it a 429 from an
    # account with no credit read as a rate limit, and was retried.
    if isinstance(body, dict) and "error" not in body:
        body = {"error": body}
    if not isinstance(body, (str, bytes)) and body is not None:
        import json

        body = json.dumps(body)
    return classify(exc.status_code, body)
