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
  (`LookupError`), or no verified caller (`PermissionError`).
* A `TerminalError`, which says so itself.

Everything else -- a dropped connection, a deadlock, a timeout -- is retryable,
which is what the engine's retry budget is for.
"""

from __future__ import annotations


def failure_is_terminal(exc: BaseException) -> bool:
    """True if another attempt at this turn would fail the same way."""
    from ..core.config import TerminalError
    from ..core.provider_errors import classify
    from ..worker.loop import PERMANENT_DB_ERRORS

    if isinstance(exc, (TerminalError, LookupError, PermissionError) + PERMANENT_DB_ERRORS):
        return True
    try:
        from pydantic_ai.exceptions import ModelHTTPError, UsageLimitExceeded
    except ImportError:  # the agent extra is not installed; nothing below can occur
        return False
    if isinstance(exc, UsageLimitExceeded):
        return True
    if isinstance(exc, ModelHTTPError):
        body = exc.body
        if not isinstance(body, (str, bytes)) and body is not None:
            import json

            body = json.dumps(body)
        failure = classify(exc.status_code, body)
        return bool(failure and failure.terminal)
    return False
