"""OpenTelemetry, opt-in and off unless an endpoint is configured.

``brief.md`` §7 already says the delegation tree and the trace tree are the same
tree, and the rows have carried ``trace_id``/``span_id``/``parent_span_id`` since
then. What was missing is that nothing ever *exported* them: the ids were W3C
shaped and correlated with nothing, which `contracts/context.py` says in as many
words -- "fine until something tries to correlate with a real tracer".

This is the real tracer. It stays off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is
set, on the same rule the provider extras follow: a runtime that exports nothing
should not pay for an exporter to find that out.

**What gets emitted, and by whom.** Almost none of it is written here, which is
the point:

  * pydantic-ai emits GenAI-semantic spans for every model request and every
    tool call -- model name, token counts, finish reason, and (only when
    `include_content` is on) the messages themselves. `Agent.instrument_all()`
    turns that on for every agent this runtime constructs, which matters because
    agents here are built per turn from a row and there is no registry to
    decorate.
  * The exporter batches and ships them.
  * This module writes exactly one thing of its own: the run's ids onto the
    span, so a trace in a viewer joins to a row in Postgres.

**Content is off by default and that is a privacy decision, not a default.**
`include_content=True` puts prompts and completions in span attributes, which
means they leave the database's access control and land in whatever the operator
pointed OTLP at. Percolate runs multi-tenant with RLS on every read path; an
exporter is a hole straight through that. `P8_OTEL_CONTENT=1` opens it
deliberately for a debugging session.

Logs are exported the same way when the endpoint is set, so a trace and the log
lines emitted during it share a trace id and land together in one backend.
"""

from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from typing import Any

_STARTED = False

SERVICE_NAME = "percolate-agent-runtime"


def enabled() -> bool:
    """Configured, not merely installed.

    The endpoint is the switch rather than a `P8_OTEL=1` of our own, because
    `OTEL_EXPORTER_OTLP_ENDPOINT` is the variable every other OTel-aware process
    in a deployment already reads. A second switch would be a second thing to
    get wrong, and the failure mode -- tracing silently off because the percolate
    flag was missed -- is the expensive one.
    """
    return bool(os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"))


def start() -> bool:
    """Install providers and instrument pydantic-ai. Idempotent, never fatal.

    Returns whether tracing is now on, so a caller can log the answer rather
    than guess at it.

    Never fatal is deliberate and it is the whole reason this is wrapped: an
    unreachable collector, a missing extra or an OTel version that moved an
    import must not stop an agent answering a question. Telemetry that can take
    the service down is a worse bargain than no telemetry.
    """
    global _STARTED
    if _STARTED or not enabled():
        return _STARTED
    try:
        _install()
    except Exception as exc:  # noqa: BLE001 -- see the docstring
        logging.getLogger(__name__).warning(
            "OpenTelemetry is configured but did not start (%s: %s); "
            "the runtime continues untraced",
            type(exc).__name__,
            exc,
        )
        return False
    _STARTED = True
    return True


def _install() -> None:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    resource = Resource.create(
        {
            "service.name": os.getenv("OTEL_SERVICE_NAME", SERVICE_NAME),
            "service.version": _version(),
        }
    )
    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)

    _install_logs(resource)

    from pydantic_ai import Agent
    from pydantic_ai.models.instrumented import InstrumentationSettings

    # `instrument_all`, not a per-agent flag: agents are constructed per turn
    # from a row (`runtime/engine.py`), so there is no long-lived object to
    # configure and a flag threaded through `build()` would be one more argument
    # that must not be forgotten.
    Agent.instrument_all(
        InstrumentationSettings(
            tracer_provider=provider,
            include_content=_content_enabled(),
        )
    )


def _install_logs(resource: Any) -> None:
    """Ship log records on the same connection, so a trace has its logs.

    Separated from `_install` and swallowed separately because the logs SDK has
    moved between OTel releases more than the trace SDK has, and a viewer with
    traces and no logs is worth much more than a runtime that would not start.
    """
    try:
        from opentelemetry._logs import set_logger_provider
        from opentelemetry.exporter.otlp.proto.http._log_exporter import (
            OTLPLogExporter,
        )
        from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
        from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    except ImportError:
        return
    provider = LoggerProvider(resource=resource)
    provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    set_logger_provider(provider)

    # BREAK THE FEEDBACK LOOP BEFORE ATTACHING THE HANDLER, not after.
    #
    # A handler on the ROOT logger exports every log record in the process --
    # including the ones the exporter itself writes while exporting. Each export
    # then produces records that are themselves queued for export, and the
    # process wedges: measured here as `force_flush` never returning, on a turn
    # that had already completed successfully. The library that ships the
    # telemetry cannot be a client of it.
    #
    # `propagate = False` rather than a filter on the handler, because these
    # loggers must also not reach any OTHER root handler that would write to a
    # stream the exporter is reading -- the same loop with a different rope. The
    # http libraries are here for the same reason: the OTLP/HTTP exporter is an
    # httpx/urllib3 caller, so their request logs are export traffic too.
    for name in (
        "opentelemetry",
        "opentelemetry.sdk",
        "opentelemetry.exporter",
        "httpx",
        "httpcore",
        "urllib3",
    ):
        logging.getLogger(name).propagate = False

    handler = LoggingHandler(level=logging.INFO, logger_provider=provider)
    root = logging.getLogger()
    root.addHandler(handler)
    if root.level > logging.INFO or root.level == logging.NOTSET:
        root.setLevel(logging.INFO)


def _content_enabled() -> bool:
    return os.getenv("P8_OTEL_CONTENT", "").lower() in ("1", "true", "yes")


@contextmanager
def run_span(run: Any) -> Any:
    """A span for the whole turn, carrying percolate's own ids.

    THE JOIN, and the reason this module has any code of its own at all. A
    pydantic-ai span says a model was called; a ``runs`` row says which agent, on
    whose behalf, under which parent, at what depth. Without a shared key a
    reader has two systems describing one event and no way to line them up, and
    the delegation tree -- the thing hardest to reason about and the reason §7
    cares about it -- is what a trace viewer draws well and SQL draws badly.

    **It has to be a span we open, not an annotation onto the current one.**
    The first version of this set attributes on ``get_current_span()`` before
    calling ``agent.run()``, which is before pydantic-ai has opened anything --
    so it wrote to a non-recording no-op span and every trace arrived with an
    empty ``percolate.run.id``. It looked exactly like working code, and only
    querying the backend showed the column blank. Opening the span here also
    gets the nesting right: the turn is the parent, and pydantic-ai's
    ``invoke_agent`` and model spans are its children, which is §7's claim that
    the delegation tree and the trace tree are one tree.

    Attribute names are ``percolate.*`` rather than bare ``run_id``: the GenAI
    semantic conventions own the unprefixed namespace, and a collision would be
    resolved in their favour, silently.

    A no-op when tracing is off, so the caller has no branch to write.
    """
    if not _STARTED or run is None:
        yield None
        return

    # ONLY THE SETUP IS GUARDED, NEVER THE BODY, and the distinction is not
    # stylistic. The first version wrapped the `yield` in the same `try`, so an
    # exception raised by the TURN was thrown into this generator, caught by
    # that `except`, and answered with a second `yield` -- which a context
    # manager may not do. Every failing traced turn then surfaced as
    #
    #     RuntimeError: generator didn't stop after throw()
    #
    # in place of its real error: telemetry code corrupting the failure path it
    # exists to record. Caught by running an agent whose tool raises, not by
    # reading it.
    #
    # So: build the span defensively, then get out of the way. An exception
    # from the body propagates through `start_as_current_span`, which records
    # it on the span and re-raises -- which is both correct tracing and correct
    # behaviour.
    span_cm = None
    try:
        from opentelemetry import trace

        tracer = trace.get_tracer("percolate.agentic")
        name = f"percolate.turn {getattr(run, 'agent_name', 'agent')}"
        span_cm = tracer.start_as_current_span(name)
    except Exception:  # noqa: BLE001 -- tracing must never fail a turn
        span_cm = None

    if span_cm is None:
        yield None
        return

    with span_cm as span:
        try:
            for key, value in (
                ("percolate.run.id", getattr(run, "id", None)),
                ("percolate.run.agent", getattr(run, "agent_name", None)),
                ("percolate.run.session_id", getattr(run, "session_id", None)),
                ("percolate.run.parent_run_id", getattr(run, "parent_run_id", None)),
                ("percolate.run.depth", getattr(run, "depth", None)),
                ("percolate.run.trace_id", getattr(run, "trace_id", None)),
            ):
                if value is not None:
                    span.set_attribute(
                        key, value if isinstance(value, int) else str(value)
                    )
        except Exception:  # noqa: BLE001 -- an attribute is not worth a turn
            pass
        yield span


def record_usage(span: Any, usage: dict) -> None:
    """Put what the turn spent on its own span.

    pydantic-ai reports per-request tokens on its model spans. This is the turn's
    total, which is the number a cost question is actually asked about, and it is
    the same figure `ExecutionResult.usage` carries into the row -- so a trace
    and a row cannot disagree about what was spent.
    """
    if span is None or not usage:
        return
    try:
        if not span.is_recording():
            return
        for key, value in usage.items():
            span.set_attribute(f"percolate.usage.{key}", value)
    except Exception:  # noqa: BLE001
        return


def _version() -> str:
    try:
        from importlib.metadata import version

        return version("percolate-core")
    except Exception:  # noqa: BLE001
        return "unknown"
