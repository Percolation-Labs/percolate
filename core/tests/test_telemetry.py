"""Telemetry is off unless configured, and cannot take a turn down with it.

The guarantee is the second half. An exporter is the one component in this
runtime whose failure has no business affecting an answer -- an unreachable
collector, a missing extra, an OTel version that moved an import. Telemetry that
can take the service down is a worse bargain than no telemetry, and these say so
in a way a refactor has to notice.

Two of these are regression tests for bugs found by running it against a real
SigNoz rather than by reading the code, which is why they are worth the lines:

  * attributes were written to `get_current_span()` BEFORE pydantic-ai opened
    one, so every span arrived with an empty `percolate.run.id`. It looked like
    working code; only querying the backend showed the column blank.
  * the log handler was attached to the ROOT logger, so the exporter's own log
    records were exported, producing more records. `force_flush` never returned
    and the process wedged after a turn had already succeeded.

Run: python -m unittest discover -s tests -p test_telemetry.py
"""

from __future__ import annotations

import logging
import os
import unittest

from percolate_core.agentic import telemetry


class Run:
    id = "0e1d2c3b-4a59-6879-8a9b-0c1d2e3f4a5b"
    session_id = "1f2e3d4c-5b6a-7988-9aab-1c2d3e4f5a6b"
    agent_name = "tester"
    parent_run_id = None
    depth = 2
    trace_id = None


class OffUnlessConfigured(unittest.TestCase):
    def setUp(self):
        self._endpoint = os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
        self._started = telemetry._STARTED

    def tearDown(self):
        if self._endpoint is not None:
            os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = self._endpoint
        else:
            os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)
        telemetry._STARTED = self._started

    def test_no_endpoint_means_not_enabled(self):
        self.assertFalse(telemetry.enabled())

    def test_start_is_a_noop_without_an_endpoint(self):
        telemetry._STARTED = False
        self.assertFalse(telemetry.start())

    def test_an_endpoint_is_the_only_switch(self):
        """No P8_OTEL flag of our own -- one switch, the standard one."""
        os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4318"
        self.assertTrue(telemetry.enabled())


class NeverFatal(unittest.TestCase):
    """Every entry point has to survive being called when things are wrong."""

    def setUp(self):
        self._started = telemetry._STARTED

    def tearDown(self):
        telemetry._STARTED = self._started

    def test_run_span_is_a_noop_when_tracing_is_off(self):
        telemetry._STARTED = False
        with telemetry.run_span(Run()) as span:
            self.assertIsNone(span)

    def test_run_span_tolerates_no_run(self):
        telemetry._STARTED = True
        with telemetry.run_span(None) as span:
            self.assertIsNone(span)

    def test_run_span_yields_even_when_the_tracer_explodes(self):
        """The body must still run if OTel raises on the way in."""
        telemetry._STARTED = True
        import opentelemetry.trace as trace_api

        original = trace_api.get_tracer
        trace_api.get_tracer = lambda *a, **k: (_ for _ in ()).throw(
            RuntimeError("no tracer")
        )
        try:
            ran = False
            with telemetry.run_span(Run()) as span:
                ran = True
                self.assertIsNone(span)
            self.assertTrue(ran, "the turn did not run because tracing failed")
        finally:
            trace_api.get_tracer = original

    def test_a_raising_turn_raises_its_own_error(self):
        """THE REGRESSION. Telemetry must not corrupt the failure path.

        The body's exception was being thrown into the generator, caught by a
        blanket `except`, and answered with a second `yield` -- illegal for a
        context manager -- so every failing traced turn surfaced as
        `RuntimeError: generator didn't stop after throw()` instead of the error
        that actually happened. Found by running an agent whose tool raises.
        """
        telemetry._STARTED = True
        with self.assertRaises(ValueError) as caught:
            with telemetry.run_span(Run()):
                raise ValueError("the tool exploded")
        self.assertEqual(str(caught.exception), "the tool exploded")

    def test_a_raising_turn_raises_its_own_error_untraced_too(self):
        """Same guarantee on the off path, which takes a different branch."""
        telemetry._STARTED = False
        with self.assertRaises(ValueError):
            with telemetry.run_span(Run()):
                raise ValueError("boom")

    def test_record_usage_tolerates_nonsense(self):
        telemetry.record_usage(None, {"a": 1})
        telemetry.record_usage(object(), {})

        class Exploding:
            def is_recording(self):
                raise RuntimeError("gone")

        telemetry.record_usage(Exploding(), {"a": 1})

    def test_start_reports_failure_rather_than_raising(self):
        """A broken install must warn and continue, not abort the process."""
        os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4318"
        telemetry._STARTED = False
        original = telemetry._install
        telemetry._install = lambda: (_ for _ in ()).throw(ImportError("no sdk"))
        try:
            with self.assertLogs(telemetry.__name__, level="WARNING"):
                self.assertFalse(telemetry.start())
            self.assertFalse(telemetry._STARTED)
        finally:
            telemetry._install = original
            os.environ.pop("OTEL_EXPORTER_OTLP_ENDPOINT", None)


class TheSpanIsOpenedNotBorrowed(unittest.TestCase):
    """The regression: attributes must land on a span that is actually recording.

    The first version annotated `get_current_span()` before pydantic-ai opened
    anything, which is a non-recording no-op span -- every attribute silently
    discarded. This asserts the span is ours and the ids are on it.
    """

    def setUp(self):
        self._started = telemetry._STARTED
        telemetry._STARTED = True

    def tearDown(self):
        telemetry._STARTED = self._started

    def test_ids_land_on_a_recording_span(self):
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import SimpleSpanProcessor
        from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
            InMemorySpanExporter,
        )

        exporter = InMemorySpanExporter()
        provider = TracerProvider()
        provider.add_span_processor(SimpleSpanProcessor(exporter))
        original = trace.get_tracer_provider
        trace.get_tracer_provider = lambda: provider
        try:
            with telemetry.run_span(Run()) as span:
                self.assertIsNotNone(span)
                self.assertTrue(span.is_recording())
                telemetry.record_usage(span, {"output_tokens": 3})
        finally:
            trace.get_tracer_provider = original

        spans = exporter.get_finished_spans()
        self.assertEqual(len(spans), 1)
        attrs = dict(spans[0].attributes)
        self.assertEqual(attrs["percolate.run.id"], Run.id)
        self.assertEqual(attrs["percolate.run.agent"], "tester")
        self.assertEqual(attrs["percolate.run.depth"], 2)
        self.assertEqual(attrs["percolate.usage.output_tokens"], 3)
        self.assertNotIn(
            "percolate.run.parent_run_id", attrs, "None must not be exported"
        )
        self.assertEqual(spans[0].name, "percolate.turn tester")


class ContentIsOptOut(unittest.TestCase):
    """Message bodies leave the database's RLS; that needs a deliberate act."""

    def tearDown(self):
        os.environ.pop("P8_OTEL_CONTENT", None)

    def test_off_by_default(self):
        self.assertFalse(telemetry._content_enabled())

    def test_on_when_asked(self):
        for value in ("1", "true", "TRUE", "yes"):
            os.environ["P8_OTEL_CONTENT"] = value
            self.assertTrue(telemetry._content_enabled(), value)

    def test_not_on_for_anything_else(self):
        for value in ("0", "false", "no", ""):
            os.environ["P8_OTEL_CONTENT"] = value
            self.assertFalse(telemetry._content_enabled(), value)


class TheExporterIsNotItsOwnClient(unittest.TestCase):
    """The wedge: OTel's own logs must not be exported.

    A handler on the root logger exported the exporter's log records, which
    produced more records. Measured as `force_flush` never returning on a turn
    that had already succeeded. `_install_logs` breaks the cycle by refusing
    propagation for those loggers; this checks the list has not been quietly
    trimmed.
    """

    def test_the_loop_breakers_are_named(self):
        import inspect

        source = inspect.getsource(telemetry._install_logs)
        for name in ("opentelemetry", "httpx", "httpcore", "urllib3"):
            self.assertIn(
                f'"{name}"',
                source,
                f"{name} no longer has propagation disabled; "
                "the log exporter can feed itself again",
            )
        self.assertIn("propagate", source)


if __name__ == "__main__":
    unittest.main()
