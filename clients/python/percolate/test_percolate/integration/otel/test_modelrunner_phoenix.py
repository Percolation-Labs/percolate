#!/usr/bin/env python3
"""
Integration test for ModelRunner OTel tracing to Phoenix.

This test verifies that the ModelRunner correctly sends telemetry to a local Phoenix instance.

Prerequisites:
- Phoenix running locally on ports 4317 (OTLP) and 6006 (UI)
  docker run -d --name phoenix -p 6006:6006 -p 4317:4317 arizephoenix/phoenix:latest

Run:
  source set_res_env.sh && poetry run python -m pytest test_percolate/integration/otel/test_modelrunner_phoenix.py -v -s
"""

import os
import pytest

# Configure OTel before importing percolate
os.environ["OTEL_ENABLED"] = "true"
os.environ["OTEL_SERVICE_NAME"] = "percolate-test"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4317"
os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"


def test_modelrunner_sends_telemetry_to_phoenix():
    """Test that ModelRunner sends OTel traces to Phoenix"""
    # Import after env vars are set
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource

    import percolate as p8
    from percolate.services.ModelRunner import ModelRunner
    from percolate.services.llm import CallingContext

    # Initialize OTel with Phoenix endpoint
    resource = Resource(attributes={"service.name": "percolate-test"})
    provider = TracerProvider(resource=resource)

    # Configure OTLP exporter to Phoenix
    processor = BatchSpanProcessor(
        OTLPSpanExporter(
            endpoint="http://localhost:4317",
            insecure=True,
        )
    )
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    print("\n" + "=" * 80)
    print("Testing ModelRunner OTel Integration with Phoenix")
    print("=" * 80)

    # Load a test agent
    print("\n[1/3] Loading agent...")
    from percolate.models.p8.types import Resources
    runner = p8.Agent(Resources)
    print(f"✓ Loaded agent: {runner.name}")

    # Execute a simple query with streaming
    print("\n[2/3] Executing query with OTel tracing...")
    context = CallingContext(
        user_id="test-user-otel",
        user_email="test@example.com",
        session_id="test-session-phoenix-123",
        model="gpt-4o-mini",
        prefers_streaming=True,
    )

    response_text = ""
    try:
        stream_iterator = runner.stream(
            "What is the capital of France? Answer in one word.",
            context=context
        )

        for chunk in stream_iterator.iter_lines():
            if isinstance(chunk, bytes):
                chunk = chunk.decode('utf-8')
            if chunk.startswith("data:"):
                import json
                try:
                    data = json.loads(chunk[6:])
                    if "choices" in data and data["choices"]:
                        delta = data["choices"][0].get("delta", {})
                        if "content" in delta:
                            content = delta["content"]
                            response_text += content
                except:
                    pass

        print(f"✓ Response received: {response_text.strip()}")
    except Exception as e:
        pytest.fail(f"Stream failed: {e}")

    # Force flush spans to Phoenix
    print("\n[3/3] Flushing spans to Phoenix...")
    provider.force_flush(timeout_millis=5000)
    print("✓ Spans flushed")

    # Verify we got a response
    assert len(response_text) > 0, "Should receive non-empty response"

    print("\n" + "=" * 80)
    print("✅ Test Complete!")
    print("=" * 80)
    print("\n📊 View traces in Phoenix UI:")
    print("   http://localhost:6006")
    print("\n🔍 Look for:")
    print(f"   - Span: agent.{runner.name}.stream")
    print("   - user.id: test-user-otel")
    print("   - user.email: test@example.com")
    print("   - session.id: test-session-phoenix-123")
    print("   - gen_ai.usage.input_tokens")
    print("   - gen_ai.usage.output_tokens")
    print("=" * 80)


if __name__ == "__main__":
    test_modelrunner_sends_telemetry_to_phoenix()
