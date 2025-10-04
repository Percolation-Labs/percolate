#!/usr/bin/env python3
"""
Test script for OpenTelemetry tracing with Phoenix.

This script:
1. Opens port-forward to Phoenix on the cluster
2. Enables OTel tracing
3. Makes a test request to an agent
4. Verifies traces appear in Phoenix
"""

import os
import sys
import subprocess
import time

# Enable OTel tracing
os.environ["OTEL_ENABLED"] = "true"
os.environ["OTEL_SERVICE_NAME"] = "percolate-test"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4317"
os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"

# Import after setting env vars
import percolate as p8
from percolate.models.p8 import Agent, SessionFeedback
from percolate.services.llm import CallingContext

print("=" * 80)
print("OpenTelemetry + Phoenix Test")
print("=" * 80)

# Step 1: Check if port-forward is running
print("\n[1/5] Checking Phoenix port-forward...")
try:
    result = subprocess.run(
        ["pgrep", "-f", "port-forward.*observability.*phoenix"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print("✓ Phoenix port-forward already running")
    else:
        print("✗ Phoenix port-forward not running. Starting...")
        # Start port-forward in background
        subprocess.Popen(
            ["kubectl", "port-forward", "-n", "observability", "svc/phoenix", "4317:4317", "6006:6006"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print("  Waiting for port-forward to establish...")
        time.sleep(3)
        print("✓ Phoenix port-forward started")
except Exception as e:
    print(f"✗ Error setting up port-forward: {e}")
    sys.exit(1)

# Step 2: Initialize OpenTelemetry
print("\n[2/5] Initializing OpenTelemetry...")
try:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource

    # Create resource with service name
    resource = Resource(attributes={
        "service.name": "percolate-test",
    })

    # Set up tracer provider
    provider = TracerProvider(resource=resource)
    processor = BatchSpanProcessor(OTLPSpanExporter(
        endpoint="http://localhost:4317",
        insecure=True,
    ))
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    print("✓ OpenTelemetry initialized")
    print(f"  - Service: percolate-test")
    print(f"  - Endpoint: http://localhost:4317")
    print(f"  - Phoenix UI: http://localhost:6006")
except ImportError as e:
    print(f"✗ OpenTelemetry packages not installed: {e}")
    print("  Run: pip install opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp")
    sys.exit(1)
except Exception as e:
    print(f"✗ Error initializing OTel: {e}")
    sys.exit(1)

# Step 3: Load or create a test agent
print("\n[3/5] Loading test agent...")
try:
    # Try to load existing agent
    try:
        agent_model = Agent.load("public.Resources")
        print("✓ Loaded existing agent: public.Resources")
    except:
        # Create a simple test agent
        agent_model = Agent(
            name="public.TestAgent",
            description="Test agent for OTel tracing",
            metadata={"allow_search": False}
        )
        repo = p8.repository(Agent, user_id=None)
        repo.update_records([agent_model])
        print("✓ Created test agent: public.TestAgent")

    # Create ModelRunner
    from percolate.services import ModelRunner
    runner = ModelRunner(agent_model)
    print(f"✓ ModelRunner initialized for: {runner.name}")

except Exception as e:
    print(f"✗ Error loading agent: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Step 4: Execute agent with OTel tracing
print("\n[4/5] Executing agent with OTel tracing...")
try:
    # Create calling context
    context = CallingContext(
        user_id="test-user-otel",
        session_id="test-session-123",
        model="gpt-4o-mini",
        prefers_streaming=True,
    )

    print("  - Query: 'What is 2+2?'")
    print("  - User: test-user-otel")
    print("  - Session: test-session-123")
    print("  - Streaming: Enabled")

    # Stream the response
    response_text = ""
    for chunk in runner.stream("What is 2+2?", context=context):
        # Skip AIResponse objects, only process string chunks
        if isinstance(chunk, str):
            if chunk.startswith("data: "):
                # Extract content from SSE format
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

    print(f"\n\n✓ Agent execution completed")
    print(f"  - Response length: {len(response_text)} chars")

    # Force flush spans
    provider.force_flush()
    time.sleep(2)  # Give Phoenix time to receive

except Exception as e:
    print(f"\n✗ Error executing agent: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Step 5: Submit feedback (also traced)
print("\n[5/5] Submitting session feedback...")
try:
    feedback = SessionFeedback(
        session_id="test-session-123",
        approved=True,
        note="Test feedback for OTel tracing",
        tags=["test", "otel", "phoenix"]
    )

    repo = p8.repository(SessionFeedback)
    repo.update_records([feedback])

    print("✓ Feedback submitted")
    print(f"  - Session: {feedback.session_id}")
    print(f"  - Approved: {feedback.approved}")
    print(f"  - Tags: {feedback.tags}")

    # Force flush again
    provider.force_flush()

except Exception as e:
    print(f"✗ Error submitting feedback: {e}")
    import traceback
    traceback.print_exc()

# Final summary
print("\n" + "=" * 80)
print("Test Complete!")
print("=" * 80)
print("\n📊 View traces in Phoenix:")
print("   http://localhost:6006")
print("\n🔍 Look for:")
print("   - Trace: agent.{agent_name}.stream")
print("   - Spans with user.id: test-user-otel")
print("   - Spans with session.id: test-session-123")
print("   - Tool call events")
print("   - Token usage attributes")
print("\n💡 Tip: Refresh Phoenix UI if traces don't appear immediately")
print("=" * 80)
