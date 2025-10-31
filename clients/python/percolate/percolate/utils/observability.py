"""
OpenTelemetry initialization and configuration for Percolate.

This module handles the setup of OpenTelemetry tracing with the OTLP exporter
to send traces to the configured collector (Phoenix/Jaeger/etc).
"""

import os
from percolate.utils import logger
from percolate.utils.env import OTEL_ENABLED


def initialize_otel():
    """
    Initialize OpenTelemetry tracing if OTEL_ENABLED is true.

    This sets up:
    - TracerProvider with service name
    - OTLP gRPC exporter pointing to the configured collector
    - BatchSpanProcessor for efficient span export

    Configuration via environment variables:
    - OTEL_ENABLED: Enable/disable tracing (default: false)
    - OTEL_SERVICE_NAME: Service name for traces (default: percolate)
    - OTEL_EXPORTER_OTLP_ENDPOINT: Collector endpoint (default: http://localhost:4317)
    - OTEL_EXPORTER_OTLP_PROTOCOL: Protocol to use (default: grpc)
    """
    if not OTEL_ENABLED:
        logger.info("OpenTelemetry tracing is disabled (OTEL_ENABLED=false)")
        return None

    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from opentelemetry.sdk.resources import Resource

        # Get configuration from environment
        service_name = os.environ.get("OTEL_SERVICE_NAME", "percolate")
        endpoint = os.environ.get(
            "OTEL_EXPORTER_OTLP_ENDPOINT",
            "http://localhost:4317"
        )
        project_name = os.environ.get("PROJECT_NAME", "percolate")
        deployment_env = os.environ.get("DEPLOYMENT_ENVIRONMENT", "development")

        # Create resource with service name and Phoenix project organization
        # Phoenix requires openinference.project.name (not just project.name)
        resource = Resource(attributes={
            "service.name": service_name,
            "service.version": "1.0.0",
            "deployment.environment": deployment_env,
            "openinference.project.name": project_name,
        })

        # Set up tracer provider
        provider = TracerProvider(resource=resource)

        # Configure OTLP exporter
        # Use insecure=True for HTTP endpoints (cluster-internal communication)
        exporter = OTLPSpanExporter(
            endpoint=endpoint,
            insecure=True,
        )

        # Add batch span processor for efficient export
        processor = BatchSpanProcessor(exporter)
        provider.add_span_processor(processor)

        # Set as global tracer provider
        trace.set_tracer_provider(provider)

        logger.info(
            f"OpenTelemetry tracing initialized: service={service_name}, endpoint={endpoint}"
        )

        return provider

    except ImportError as e:
        logger.warning(
            f"OpenTelemetry packages not installed: {e}. "
            "Install with: poetry add opentelemetry-api opentelemetry-sdk opentelemetry-exporter-otlp"
        )
        return None
    except Exception as e:
        logger.error(f"Failed to initialize OpenTelemetry: {e}")
        return None


def shutdown_otel(provider=None):
    """
    Shutdown OpenTelemetry and flush any pending spans.

    Args:
        provider: TracerProvider instance (optional, will use global if not provided)
    """
    if not OTEL_ENABLED:
        return

    try:
        if provider:
            provider.force_flush(timeout_millis=5000)
            provider.shutdown()
            logger.info("OpenTelemetry tracer provider shutdown successfully")
    except Exception as e:
        logger.warning(f"Error shutting down OpenTelemetry: {e}")
