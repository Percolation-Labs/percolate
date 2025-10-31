#!/usr/bin/env python3
"""
Test script to send traces to Phoenix via OTEL with OpenInference semantic conventions.

This script demonstrates:
1. Creating traces with OpenTelemetry
2. Using OpenInference span kinds for Phoenix categorization
3. Sending traces through OTEL Collector to Phoenix
4. Organizing traces by project using resource attributes

Usage:
    # Basic usage (uses default endpoint and project)
    python test_phoenix_otel.py

    # With custom configuration
    OTEL_ENDPOINT=http://localhost:4318/v1/traces \
    PROJECT_NAME=my-project \
    SERVICE_NAME=my-service \
    python test_phoenix_otel.py
"""

import os
import time
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk import trace as trace_sdk
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.resources import Resource

# Configuration
OTEL_ENDPOINT = os.getenv("OTEL_ENDPOINT", "http://localhost:4318/v1/traces")
PROJECT_NAME = os.getenv("PROJECT_NAME", "percolate")
SERVICE_NAME = os.getenv("SERVICE_NAME", "test-service")


def create_tracer(project_name: str, service_name: str) -> trace.Tracer:
    """
    Create an OpenTelemetry tracer configured to send traces to OTEL Collector.

    Phoenix uses resource attributes to organize traces:
    - service.name: Name of the service
    - openinference.project.name: Phoenix project name (OpenInference convention)
    """
    # Create resource with service and project information
    # Phoenix requires openinference.project.name (not just project.name)
    resource = Resource.create({
        "service.name": service_name,
        "service.version": "1.0.0",
        "deployment.environment": "test",
        # Phoenix uses openinference.project.name for project organization
        "openinference.project.name": project_name,
    })

    # Create tracer provider with resource
    tracer_provider = trace_sdk.TracerProvider(resource=resource)

    # Configure OTLP exporter to send to OTEL Collector
    # The collector will relay traces to Phoenix
    otlp_exporter = OTLPSpanExporter(
        endpoint=OTEL_ENDPOINT,
        # No auth needed for OTEL Collector
        # The collector handles Phoenix authentication
    )

    # Add batch processor for efficient export
    tracer_provider.add_span_processor(
        BatchSpanProcessor(otlp_exporter)
    )

    # Set as global tracer provider
    trace.set_tracer_provider(tracer_provider)

    # Return tracer
    return trace.get_tracer(__name__, "1.0.0")


def simulate_llm_call(tracer: trace.Tracer):
    """Simulate an LLM API call with proper semantic conventions."""
    with tracer.start_as_current_span(
        "llm.completion",
        kind=trace.SpanKind.CLIENT,
        attributes={
            # OpenInference/Phoenix span kind
            "openinference.span.kind": "LLM",

            # Official OpenTelemetry GenAI conventions
            "gen_ai.operation.name": "chat",
            "gen_ai.provider.name": "openai",
            "gen_ai.request.model": "gpt-4o-mini",
            "gen_ai.response.model": "gpt-4o-mini",
            "gen_ai.request.temperature": 0.7,
            "gen_ai.request.max_tokens": 150,
        }
    ) as span:
        # Simulate API call delay
        time.sleep(0.3)

        # Set usage metrics
        span.set_attribute("gen_ai.usage.input_tokens", 25)
        span.set_attribute("gen_ai.usage.output_tokens", 40)
        span.set_attribute("gen_ai.usage.total_tokens", 65)
        span.set_attribute("gen_ai.response.finish_reasons", ["stop"])

        # Optional: Set cost attributes
        span.set_attribute("gen_ai.usage.input_cost", 0.00001)
        span.set_attribute("gen_ai.usage.output_cost", 0.00003)
        span.set_attribute("gen_ai.usage.cost", 0.00004)


def simulate_agent_with_tools(tracer: trace.Tracer):
    """Simulate an agent workflow with tool calls."""
    with tracer.start_as_current_span(
        "agent.research_assistant",
        kind=trace.SpanKind.SERVER,
        attributes={
            # OpenInference span kind for agent
            "openinference.span.kind": "AGENT",
            "agent.name": "research_assistant",
            "agent.task": "Research and answer user question",
        }
    ) as agent_span:
        # Agent planning step
        with tracer.start_as_current_span(
            "agent.planning",
            attributes={
                "openinference.span.kind": "CHAIN",
                "agent.step": "plan",
            }
        ):
            time.sleep(0.1)

        # Tool call - web search
        with tracer.start_as_current_span(
            "tool.web_search",
            kind=trace.SpanKind.INTERNAL,
            attributes={
                "openinference.span.kind": "TOOL",
                "tool.name": "web_search",
                "tool.query": "What is Phoenix observability?",
            }
        ) as tool_span:
            time.sleep(0.2)
            tool_span.set_attribute("tool.result_count", 5)

        # LLM call to synthesize results
        simulate_llm_call(tracer)

        # Agent completion
        agent_span.set_attribute("agent.steps_completed", 3)
        agent_span.set_attribute("agent.success", True)


def simulate_rag_pipeline(tracer: trace.Tracer):
    """Simulate a RAG (Retrieval-Augmented Generation) pipeline."""
    with tracer.start_as_current_span(
        "rag.query",
        attributes={
            "openinference.span.kind": "CHAIN",
            "query.text": "How to use Percolate agents?",
            "query.type": "semantic_search",
        }
    ) as span:
        # Vector search
        with tracer.start_as_current_span(
            "rag.vector_search",
            attributes={
                "openinference.span.kind": "RETRIEVER",
                "search.index": "percolate_docs",
                "search.top_k": 5,
                "search.threshold": 0.7,
            }
        ) as retriever_span:
            time.sleep(0.15)
            retriever_span.set_attribute("search.results_count", 3)

        # LLM generation with context
        simulate_llm_call(tracer)

        span.set_attribute("rag.success", True)
        span.set_attribute("rag.documents_used", 3)


def main():
    """Run test scenarios."""
    print(f"🚀 Testing Phoenix OTLP Tracing with OpenInference Conventions")
    print(f"   OTEL Endpoint: {OTEL_ENDPOINT}")
    print(f"   Project: {PROJECT_NAME}")
    print(f"   Service: {SERVICE_NAME}")
    print()

    # Create tracer
    tracer = create_tracer(PROJECT_NAME, SERVICE_NAME)

    print("📊 Generating test traces...")
    print()

    # Test 1: Simple LLM call
    print("1️⃣  Simulating LLM completion with OpenInference span kind...")
    simulate_llm_call(tracer)
    time.sleep(0.5)

    # Test 2: Agent with tools
    print("2️⃣  Simulating agent workflow with AGENT and TOOL span kinds...")
    simulate_agent_with_tools(tracer)
    time.sleep(0.5)

    # Test 3: RAG pipeline
    print("3️⃣  Simulating RAG pipeline with CHAIN and RETRIEVER span kinds...")
    simulate_rag_pipeline(tracer)
    time.sleep(0.5)

    # Force flush to ensure all spans are exported
    trace.get_tracer_provider().force_flush()

    print()
    print("✅ Test traces sent successfully!")
    print()
    print("📋 Next steps:")
    print("   1. View traces in Phoenix UI:")
    print("      http://localhost:6006")
    print()
    print("   2. Look for project:", PROJECT_NAME)
    print("      Service:", SERVICE_NAME)
    print()
    print("   3. Check span kinds in Phoenix:")
    print("      - LLM spans should be categorized as 'LLM'")
    print("      - Agent spans should be categorized as 'AGENT'")
    print("      - Tool spans should be categorized as 'TOOL'")
    print("      - RAG spans should show 'CHAIN' and 'RETRIEVER' types")


if __name__ == "__main__":
    main()
