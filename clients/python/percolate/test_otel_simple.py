#!/usr/bin/env python3
"""
Simple OTel integration test for ModelRunner

Run with: source set_res_env.sh && export OTEL_ENABLED=true && poetry run python test_otel_simple.py
"""

import os

# Enable OTel
os.environ["OTEL_ENABLED"] = "true"
os.environ["OTEL_SERVICE_NAME"] = "percolate-test"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4317"

print("=" * 80)
print("OpenTelemetry ModelRunner Integration Test")
print("=" * 80)

# Initialize OTel
try:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
    from opentelemetry.sdk.resources import Resource

    resource = Resource(attributes={"service.name": "percolate-test"})
    provider = TracerProvider(resource=resource)

    # Add console exporter to see spans in terminal
    console_processor = BatchSpanProcessor(ConsoleSpanExporter())
    provider.add_span_processor(console_processor)

    # Add OTLP exporter (will fail if Phoenix not running, but that's ok)
    try:
        otlp_processor = BatchSpanProcessor(OTLPSpanExporter(
            endpoint="http://localhost:4317",
            insecure=True,
        ))
        provider.add_span_processor(otlp_processor)
        print("✓ OTLP exporter configured (Phoenix at localhost:4317)")
    except:
        print("✗ OTLP exporter failed (Phoenix may not be running)")

    trace.set_tracer_provider(provider)
    print("✓ OpenTelemetry initialized\n")
except Exception as e:
    print(f"✗ Failed to initialize OTel: {e}\n")
    exit(1)

# Test ModelRunner
import percolate as p8
from percolate.services.ModelRunner import ModelRunner
from percolate.services.llm import CallingContext

print("[1/3] Loading agent...")
try:
    # Load existing agent by class
    from percolate.models.p8.types import Resources
    runner = p8.Agent(Resources)
    print(f"✓ Loaded agent: {runner.name}\n")
except Exception as e:
    print(f"✗ Failed to load agent: {e}\n")
    exit(1)

print("[2/3] Running streaming query with OTel...")
context = CallingContext(
    user_id="test-user-otel",
    session_id="test-session-123",
    model="gpt-4o-mini",
    prefers_streaming=True,
)

response_text = ""
try:
    stream_iterator = runner.stream("What is 2+2? Just answer briefly.", context=context)
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
                        print(content, end="", flush=True)
            except:
                pass

    print(f"\n\n✓ Response received ({len(response_text)} chars)\n")
except Exception as e:
    print(f"\n✗ Stream failed: {e}\n")
    import traceback
    traceback.print_exc()
    exit(1)

print("[3/3] Flushing spans...")
provider.force_flush()
print("✓ Spans flushed\n")

print("=" * 80)
print("✅ Test Complete!")
print("=" * 80)
print("\n📊 Check for traces:")
print("   - Span name: agent.public.Resources.stream")
print("   - user.id: test-user-otel")
print("   - session.id: test-session-123")
print("   - Check console output above for span details")
print("\nIf Phoenix is running:")
print("   - Port-forward: kubectl port-forward -n observability svc/phoenix 6006:6006")
print("   - View at: http://localhost:6006")
print("=" * 80)
