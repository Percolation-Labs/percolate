"""
OpenTelemetry utility functions for Percolate.

Provides helper functions for instrumenting LLM calls, tool executions,
and agent workflows following GenAI semantic conventions.

All operations are no-ops if OTEL is disabled or no active span exists.
"""

from uuid import UUID
from typing import Optional, List, Any
import json

from opentelemetry import trace
from opentelemetry.trace import Span, SpanKind
from opentelemetry.trace.status import Status, StatusCode

from percolate.utils.env import OTEL_ENABLED
from percolate.utils.span_kinds import (
    OpenInferenceSpanKind,
    OPENINFERENCE_SPAN_KIND,
)


def get_tracer(name: str = __name__):
    """Get a tracer instance."""
    return trace.get_tracer(name)


def is_tracing_enabled() -> bool:
    """Check if OpenTelemetry tracing is enabled."""
    return OTEL_ENABLED


def get_current_span() -> Optional[Span]:
    """Get the current active span if tracing is enabled."""
    if not OTEL_ENABLED:
        return None

    span = trace.get_current_span()
    if not span.get_span_context().is_valid:
        return None

    return span


def set_span_kind(span: Span, span_kind: OpenInferenceSpanKind) -> None:
    """
    Set the OpenInference span kind for Phoenix categorization.

    Phoenix uses the 'openinference.span.kind' attribute to properly
    categorize and visualize different types of AI operations.

    Args:
        span: The span to annotate
        span_kind: The type of operation (LLM, AGENT, TOOL, etc.)
    """
    if not span:
        return

    span.set_attribute(OPENINFERENCE_SPAN_KIND, span_kind.value)


def set_llm_attributes(
    span: Span,
    model: str,
    provider: str,
) -> None:
    """
    Set standard LLM attributes on a span.

    Automatically sets the OpenInference span kind to LLM for Phoenix categorization.

    Args:
        span: The span to annotate
        model: Model identifier (e.g., "gpt-4o-mini", "claude-3.5-sonnet")
        provider: Provider name (e.g., "openai", "anthropic")
    """
    if not span:
        return

    # Set OpenInference span kind for Phoenix
    set_span_kind(span, OpenInferenceSpanKind.LLM)

    # OpenTelemetry GenAI semantic conventions (required attributes)
    span.set_attribute("gen_ai.operation.name", "chat")  # Required: operation type
    span.set_attribute("gen_ai.provider.name", provider)  # Required: provider name (e.g., "openai")

    # Model attributes (recommended)
    span.set_attribute("gen_ai.request.model", model)
    span.set_attribute("gen_ai.response.model", model)


def set_generation_attributes(
    span: Span,
    prompt: Optional[str] = None,
    completion: Optional[str] = None,
    messages: Optional[list] = None,
    input_tokens: Optional[int] = None,
    output_tokens: Optional[int] = None,
    total_tokens: Optional[int] = None,
    input_cost: Optional[float] = None,
    output_cost: Optional[float] = None,
    total_cost: Optional[float] = None,
    temperature: Optional[float] = None,
    max_tokens: Optional[int] = None,
    finish_reason: Optional[str] = None,
    is_streaming: bool = False,
) -> None:
    """
    Annotate span with LLM generation metadata.

    Args:
        span: The span to annotate
        prompt: Input prompt (omitted by default for privacy)
        messages: Structured input messages with roles (for llm.input_messages)
        completion: Model output (omitted by default for privacy)
        input_tokens: Number of input/prompt tokens
        output_tokens: Number of output/completion tokens
        total_tokens: Total tokens (auto-computed if omitted)
        input_cost: Cost for input tokens in USD
        output_cost: Cost for output tokens in USD
        total_cost: Total cost in USD
        temperature: Sampling temperature
        max_tokens: Maximum output tokens requested
        finish_reason: Reason generation stopped
        is_streaming: Whether streaming was used
    """
    if not span:
        return

    # Capture input prompts for Phoenix (following OpenInference conventions)
    if prompt:
        span.set_attribute("llm.prompts", json.dumps([{"text": prompt}]))
        span.set_attribute("input.value", prompt)

    # Capture structured input messages (preserves role information)
    if messages:
        import logging
        logger = logging.getLogger(__name__)
        logger.debug(f"Setting {len(messages)} structured input messages on span")
        for i, msg in enumerate(messages):
            role = msg.get("role", "user")
            content = msg.get("content", "")
            logger.debug(f"  Message {i}: role={role}, content_len={len(content)}")
            span.set_attribute(f"llm.input_messages.{i}.message.role", role)
            span.set_attribute(f"llm.input_messages.{i}.message.content", content)
        logger.debug(f"Finished setting structured messages")

    # Capture output completion with structured message format for Phoenix
    if completion:
        # Legacy attribute
        span.set_attribute("llm.completions", json.dumps([{"text": completion}]))
        # Phoenix OpenInference convention
        span.set_attribute("output.value", completion)
        # Structured output message
        span.set_attribute("llm.output_messages.0.message.role", "assistant")
        span.set_attribute("llm.output_messages.0.message.content", completion)

    if input_tokens is not None:
        span.set_attribute("gen_ai.usage.input_tokens", input_tokens)

    if output_tokens is not None:
        span.set_attribute("gen_ai.usage.output_tokens", output_tokens)

    if total_tokens is not None:
        span.set_attribute("gen_ai.usage.total_tokens", total_tokens)
    elif input_tokens is not None and output_tokens is not None:
        span.set_attribute("gen_ai.usage.total_tokens", input_tokens + output_tokens)

    if input_cost is not None:
        span.set_attribute("gen_ai.usage.input_cost", input_cost)

    if output_cost is not None:
        span.set_attribute("gen_ai.usage.output_cost", output_cost)

    if total_cost is not None:
        span.set_attribute("gen_ai.usage.cost", total_cost)

    if temperature is not None:
        span.set_attribute("gen_ai.request.temperature", temperature)

    if max_tokens is not None:
        span.set_attribute("gen_ai.request.max_tokens", max_tokens)

    if finish_reason:
        span.set_attribute("gen_ai.response.finish_reason", finish_reason)

    span.set_attribute("gen_ai.is_streaming", is_streaming)


def set_trace_attributes(
    span: Span,
    user_id: Optional[str] = None,
    session_id: Optional[str] = None,
    code_path: Optional[str] = None,
    agent_version: Optional[str] = None,
) -> None:
    """
    Annotate span with user, session, and code context.

    Args:
        span: The span to annotate
        user_id: User identifier
        session_id: Session identifier
        code_path: Source code file path
        agent_version: Agent version from metadata
    """
    if not span:
        return

    if user_id:
        span.set_attribute("user.id", user_id)

    if session_id:
        span.set_attribute("session.id", session_id)

    if code_path:
        span.set_attribute("code.filepath", code_path)

    if agent_version:
        span.set_attribute("agent.version", agent_version)


def add_tool_call_event(
    span: Span,
    tool_name: str,
    tool_arguments: dict,
) -> None:
    """
    Add a tool call event to the span.

    Also sets the OpenInference span kind to TOOL for Phoenix categorization.

    Args:
        span: The span to annotate
        tool_name: Name of the tool being called
        tool_arguments: Tool call arguments
    """
    if not span:
        return

    # Set OpenInference span kind for Phoenix
    set_span_kind(span, OpenInferenceSpanKind.TOOL)

    span.add_event(
        name=f"tool.{tool_name}.start",
        attributes={
            "tool.name": tool_name,
            "tool.arguments": json.dumps(tool_arguments),
        }
    )


def add_tool_result_event(
    span: Span,
    tool_name: str,
    tool_result: Any,
    error: Optional[str] = None,
) -> None:
    """
    Add a tool result event to the span.

    Args:
        span: The span to annotate
        tool_name: Name of the tool
        tool_result: Result from tool execution
        error: Error message if tool failed
    """
    if not span:
        return

    attributes = {
        "tool.name": tool_name,
    }

    if error:
        attributes["tool.error"] = error
        span.add_event(name=f"tool.{tool_name}.error", attributes=attributes)
    else:
        # Convert result to JSON string if not already a string
        if isinstance(tool_result, str):
            result_str = tool_result
        else:
            try:
                result_str = json.dumps(tool_result)
            except (TypeError, ValueError):
                # Handle non-serializable objects (e.g., Message objects)
                result_str = str(tool_result)
        attributes["tool.result"] = result_str[:1000]  # Limit size
        span.add_event(name=f"tool.{tool_name}.complete", attributes=attributes)


def mark_span_as_error(span: Span, error_message: str) -> None:
    """
    Mark span as error.

    Args:
        span: The span to mark
        error_message: Error description
    """
    if not span:
        return

    span.set_status(Status(StatusCode.ERROR, error_message))


def add_span_event(
    span: Span,
    event_name: str,
    attributes: Optional[dict] = None,
) -> None:
    """
    Add a generic event to the span.

    Args:
        span: The span to annotate
        event_name: Name of the event
        attributes: Optional event attributes
    """
    if not span:
        return

    span.add_event(event_name, attributes=attributes or {})


def get_current_span_id_as_hex() -> Optional[str]:
    """
    Get the current span ID in hexadecimal format for Phoenix annotations.

    Returns:
        16-character hex string representing the span ID, or None if no valid span
    """
    span = get_current_span()
    if not span:
        return None

    span_id = span.get_span_context().span_id
    return format(span_id, '016x')


def get_current_trace_id_as_hex() -> Optional[str]:
    """
    Get the current trace ID in hexadecimal format for linking.

    Returns:
        32-character hex string representing the trace ID, or None if no valid span
    """
    span = get_current_span()
    if not span:
        return None

    trace_id = span.get_span_context().trace_id
    return format(trace_id, '032x')
