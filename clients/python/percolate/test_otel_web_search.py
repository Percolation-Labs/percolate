#!/usr/bin/env python3
"""
Test OpenTelemetry tracing with web search agent.

This script tests:
1. Agent execution span
2. Tool call events (search_the_web)
3. Token usage attributes
4. User and session context
"""

import os
import sys
import subprocess
import time

# Enable OTel tracing
os.environ["OTEL_ENABLED"] = "true"
os.environ["OTEL_SERVICE_NAME"] = "percolate-websearch-test"
os.environ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:4317"
os.environ["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"

# Import after setting env vars
import percolate as p8
from percolate.models.p8 import Agent
from percolate.services.llm import CallingContext

print("=" * 80)
print("OpenTelemetry Web Search Agent Test")
print("=" * 80)

# Step 1: Check if port-forward is running
print("\n[1/4] Checking Phoenix port-forward...")
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
print("\n[2/4] Initializing OpenTelemetry...")
try:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource

    # Create resource with service name
    resource = Resource(attributes={
        "service.name": "percolate-websearch-test",
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
    print(f"  - Service: percolate-websearch-test")
    print(f"  - Endpoint: http://localhost:4317")
    print(f"  - Phoenix UI: http://localhost:6006")
except ImportError as e:
    print(f"✗ OpenTelemetry packages not installed: {e}")
    print("  Run: poetry add opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp")
    sys.exit(1)
except Exception as e:
    print(f"✗ Error initializing OTel: {e}")
    sys.exit(1)

# Step 3: Load WebSearchAgent
print("\n[3/4] Loading WebSearchAgent...")
try:
    agent_model = Agent.load("test.WebSearchAgent")
    print("✓ Loaded agent: test.WebSearchAgent")
    print(f"  - Metadata: {agent_model.metadata if hasattr(agent_model, 'metadata') else agent_model.model_config}")

    # Create ModelRunner
    from percolate.services.ModelRunner import ModelRunner
    runner = ModelRunner(agent_model)
    print(f"✓ ModelRunner initialized")
    print(f"  - Functions: {list(runner.functions.keys())}")

    # Verify search_the_web is available
    if 'search_the_web' in runner.functions:
        print("  ✓ search_the_web function is available")
    else:
        print("  ✗ search_the_web function NOT available!")
        sys.exit(1)

except Exception as e:
    print(f"✗ Error loading agent: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Step 4: Execute agent with web search
print("\n[4/4] Executing web search with OTel tracing...")
try:
    # Create calling context
    context = CallingContext(
        user_id="test-user-websearch",
        session_id="test-session-websearch-456",
        model="gpt-4o-mini",
        prefers_streaming=True,
    )

    print("  - Query: 'Search for latest Python releases'")
    print("  - User: test-user-websearch")
    print("  - Session: test-session-websearch-456")
    print("  - Streaming: Enabled")
    print("\nResponse:")
    print("-" * 80)

    # Stream the response
    response_text = ""
    tool_calls_seen = []

    stream_iterator = runner.stream("Search for latest Python releases", context=context)
    for chunk in stream_iterator.iter_lines():
        # Process bytes chunks
        if isinstance(chunk, bytes):
            chunk = chunk.decode('utf-8')
            if chunk.startswith("event: function_call"):
                # Track function calls
                continue
            elif chunk.startswith("data: "):
                # Extract content from SSE format
                import json
                try:
                    data = json.loads(chunk[6:])

                    # Track tool calls
                    if "choices" in data and data["choices"]:
                        choice = data["choices"][0]
                        if "delta" in choice and "tool_calls" in choice["delta"]:
                            for tc in choice["delta"]["tool_calls"]:
                                if "function" in tc and "name" in tc["function"]:
                                    tool_calls_seen.append(tc["function"]["name"])

                        # Extract content
                        delta = choice.get("delta", {})
                        if "content" in delta:
                            content = delta["content"]
                            response_text += content
                            print(content, end="", flush=True)
                except:
                    pass

    print("\n" + "-" * 80)
    print(f"\n✓ Agent execution completed")
    print(f"  - Response length: {len(response_text)} chars")
    print(f"  - Tool calls: {set(tool_calls_seen)}")

    # Force flush spans
    provider.force_flush()
    time.sleep(2)  # Give Phoenix time to receive

except Exception as e:
    print(f"\n✗ Error executing agent: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Final summary
print("\n" + "=" * 80)
print("Test Complete!")
print("=" * 80)
print("\n📊 View traces in Phoenix:")
print("   http://localhost:6006")
print("\n🔍 Look for:")
print("   - Span: agent.test.WebSearchAgent.stream")
print("   - Attributes:")
print("     - user.id: test-user-websearch")
print("     - session.id: test-session-websearch-456")
print("     - gen_ai.system: openai")
print("     - gen_ai.request.model: gpt-4o-mini")
print("   - Events:")
print("     - tool.search_the_web.start")
print("     - tool.search_the_web.complete")
print("   - Token usage attributes:")
print("     - gen_ai.usage.input_tokens")
print("     - gen_ai.usage.output_tokens")
print("     - gen_ai.usage.total_tokens")
print("\n💡 Tip: Refresh Phoenix UI if traces don't appear immediately")
print("=" * 80)
