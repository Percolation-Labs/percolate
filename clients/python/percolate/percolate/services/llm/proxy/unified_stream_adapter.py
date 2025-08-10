"""
Unified stream adapter for converting between different LLM provider formats.

This module provides a unified stream adapter that:
1. Converts SSE events from Claude (Anthropic) and OpenAI to OpenAI format
2. Buffers tool/function calls until complete arguments are available
3. Aggregates usage information across chunks
4. Provides clear state management through dataclasses

The adapter is designed to be testable and maintainable with clear separation
of concerns between parsing, buffering, and format conversion.

Currently supports:
- OpenAI GPT models (pass-through with tool call buffering)
- Anthropic Claude models (conversion to OpenAI format)
"""

import json
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Dict, List, Optional, Tuple, Generator, Any

from percolate.utils import logger
from percolate.services.llm.proxy.models import (
    OpenAIStreamDelta,
    AnthropicStreamDelta,
)


class StreamEventType(Enum):
    """Types of events in the stream"""

    CONTENT = "content"
    TOOL_CALL_START = "tool_call_start"
    TOOL_CALL_DELTA = "tool_call_delta"
    TOOL_CALL_COMPLETE = "tool_call_complete"
    FUNCTION_ANNOUNCEMENT = "function_announcement"
    USAGE = "usage"
    DONE = "done"
    ERROR = "error"


@dataclass
class StreamState:
    """
    Maintains the state of the stream processing.

    This class tracks:
    - Buffered tool calls by index
    - Aggregated usage information
    - Current processing state
    """

    tool_calls: Dict[int, Dict[str, Any]] = field(default_factory=dict)
    usage: Dict[str, int] = field(default_factory=dict)
    finished_tool_calls: bool = False
    content_chunks: List[str] = field(default_factory=list)
    current_role: Optional[str] = None
    model: Optional[str] = None

    def add_tool_call(self, index: int, tool_call: Dict[str, Any]) -> None:
        """Add or initialize a tool call"""
        self.tool_calls[index] = tool_call

    def update_tool_call_args(self, index: int, args_delta: str) -> None:
        """Append arguments to an existing tool call"""
        if index in self.tool_calls:
            if "function" in self.tool_calls[index]:
                self.tool_calls[index]["function"]["arguments"] += args_delta

    def get_complete_tool_calls(self) -> List[Dict[str, Any]]:
        """Get all buffered tool calls as a list"""
        return list(self.tool_calls.values())

    def update_usage(self, new_usage: Dict[str, int]) -> None:
        """Update aggregated usage information, properly combining prompt and completion tokens"""
        for key, value in new_usage.items():
            if key in ["prompt_tokens", "input_tokens"]:
                # Keep the highest prompt token count (usually from message_start)
                self.usage["prompt_tokens"] = max(
                    self.usage.get("prompt_tokens", 0), value
                )
            elif key in ["completion_tokens", "output_tokens"]:
                # Keep the highest completion token count (usually from message_delta)
                self.usage["completion_tokens"] = max(
                    self.usage.get("completion_tokens", 0), value
                )
            elif key == "total_tokens":
                # Recalculate total or use provided value if higher
                calculated_total = self.usage.get("prompt_tokens", 0) + self.usage.get(
                    "completion_tokens", 0
                )
                self.usage["total_tokens"] = max(calculated_total, value)
            else:
                self.usage[key] = value

    def add_content(self, content: str) -> None:
        """Add content chunk - only for tracking, not for aggregation"""
        self.content_chunks.append(content)

    def get_aggregated_content(self) -> str:
        """Get all content concatenated"""
        return "".join(self.content_chunks)

    def to_openai_response(self, request_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Convert the aggregated state to a complete OpenAI non-streaming response.

        Args:
            request_id: Optional request ID, will generate one if not provided

        Returns:
            Complete OpenAI chat completion response
        """
        import uuid

        if not request_id:
            request_id = f"chatcmpl-{int(time.time())}"

        # Determine finish reason
        finish_reason = "stop"
        if self.tool_calls:
            finish_reason = "tool_calls"

        # Build the message
        message = {
            "role": self.current_role or "assistant",
            "content": self.get_aggregated_content() or None,
        }

        # Add tool calls if present
        if self.tool_calls:
            message["tool_calls"] = self.get_complete_tool_calls()

        # Build the complete response
        response = {
            "id": request_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.model or "unknown",
            "choices": [
                {
                    "index": 0,
                    "message": message,
                    "finish_reason": finish_reason,
                    "logprobs": None,
                }
            ],
            "usage": {
                "prompt_tokens": self.usage.get("prompt_tokens", 0),
                "completion_tokens": self.usage.get("completion_tokens", 0),
                "total_tokens": self.usage.get("total_tokens", 0),
            },
            "system_fingerprint": None,
        }

        return response


class UnifiedStreamAdapter:
    """
    Unified adapter for converting streaming responses between different LLM providers.

    This adapter handles:
    1. Format conversion between providers (OpenAI and Anthropic)
    2. Tool call buffering
    3. Usage aggregation
    4. Clean error handling

    Supported conversions:
    - OpenAI → OpenAI (with tool call buffering)
    - Anthropic → OpenAI (full format conversion)
    """

    def __init__(self, source_scheme: str = "openai", target_scheme: str = "openai"):
        if source_scheme not in ["openai", "anthropic"]:
            raise ValueError(f"Unsupported source scheme: {source_scheme}")
        if target_scheme not in ["openai", "anthropic"]:
            raise ValueError(f"Unsupported target scheme: {target_scheme}")

        self.source_scheme = source_scheme
        self.target_scheme = target_scheme
        self.state = StreamState()

    def parse_sse_line(self, line: str) -> Optional[Dict[str, Any]]:
        """
        Parse a server-sent event line.

        Args:
            line: The SSE line to parse

        Returns:
            Parsed JSON data or None if parsing fails
        """
        if not line or not line.startswith("data: "):
            return None

        raw_data = line[6:].strip()
        if raw_data == "[DONE]":
            return {"type": "done"}

        try:
            return json.loads(raw_data)
        except json.JSONDecodeError as e:
            logger.debug(f"Failed to parse SSE line: {line}, error: {e}")
            return None

    def convert_to_canonical_format(self, chunk: Dict[str, Any]) -> Dict[str, Any]:
        """
        Convert a chunk from source format to OpenAI canonical format.

        Args:
            chunk: The chunk in source format

        Returns:
            The chunk in OpenAI format
        """
        if self.source_scheme == "openai":
            return chunk
        elif self.source_scheme == "anthropic":
            try:
                return AnthropicStreamDelta(**chunk).to_openai_format()
            except Exception as e:
                logger.error(f"Failed to convert Anthropic chunk: {e}")
                return chunk
        else:
            # This should never happen due to validation in __init__
            logger.warning(f"Unknown source scheme: {self.source_scheme}")
            return chunk

    def convert_to_target_format(self, chunk: Dict[str, Any]) -> Dict[str, Any]:
        """
        Convert a chunk from OpenAI format to target format.

        Args:
            chunk: The chunk in OpenAI format

        Returns:
            The chunk in target format
        """
        if self.target_scheme == "openai":
            return chunk

        try:
            delta = OpenAIStreamDelta(**chunk)
            if self.target_scheme == "anthropic":
                return delta.to_anthropic_format()
            else:
                # This should never happen due to validation in __init__
                logger.warning(f"Unknown target scheme: {self.target_scheme}")
                return chunk
        except Exception as e:
            logger.error(f"Failed to convert to {self.target_scheme} format: {e}")
            return chunk

    def process_chunk(
        self, chunk: Dict[str, Any]
    ) -> Optional[Tuple[StreamEventType, Dict[str, Any]]]:
        """
        Process a single chunk and determine its type and canonical format.

        Args:
            chunk: The chunk to process

        Returns:
            Tuple of (event_type, canonical_chunk) or None
        """
        # Handle special done event
        if chunk.get("type") == "done":
            return (StreamEventType.DONE, chunk)

        # Convert to canonical format
        canonical = self.convert_to_canonical_format(chunk)

        # Extract model if available
        if "model" in canonical:
            self.state.model = canonical["model"]

        # Check for choices first to handle finish reasons
        if "choices" in canonical and canonical["choices"]:
            choice = canonical["choices"][0]
            delta = choice.get("delta", {})
            finish_reason = choice.get("finish_reason")

            # Update role if present
            if "role" in delta:
                self.state.current_role = delta["role"]

            # Handle finish reasons first - this is important for tool calls
            if finish_reason == "tool_calls" and not self.state.finished_tool_calls:
                self.state.finished_tool_calls = True
                # Also capture usage if present
                if "usage" in canonical and canonical["usage"]:
                    self.state.update_usage(canonical["usage"])
                return (StreamEventType.TOOL_CALL_COMPLETE, canonical)
            elif finish_reason == "stop":
                # Also capture usage if present
                if "usage" in canonical and canonical["usage"]:
                    self.state.update_usage(canonical["usage"])
                return (StreamEventType.CONTENT, canonical)

            # Handle content
            if "content" in delta and delta["content"]:
                self.state.add_content(delta["content"])
                return (StreamEventType.CONTENT, canonical)

            # Handle tool calls
            if "tool_calls" in delta:
                for tool_delta in delta["tool_calls"]:
                    if "id" in tool_delta:
                        # New tool call
                        self.state.add_tool_call(tool_delta["index"], tool_delta)
                        return (StreamEventType.TOOL_CALL_START, canonical)
                    else:
                        # Tool call delta
                        if "index" in tool_delta and "function" in tool_delta:
                            args = tool_delta["function"].get("arguments", "")
                            self.state.update_tool_call_args(tool_delta["index"], args)
                        return (StreamEventType.TOOL_CALL_DELTA, canonical)

        # Check for usage information (standalone usage events)
        if "usage" in canonical and canonical["usage"]:
            self.state.update_usage(canonical["usage"])
            return (StreamEventType.USAGE, canonical)

        return None

    def create_buffered_tool_call_chunk(self) -> Dict[str, Any]:
        """
        Create a consolidated chunk with all buffered tool calls.

        Returns:
            OpenAI-formatted chunk with complete tool calls
        """
        return {
            "id": f"chatcmpl-{int(time.time())}",  # OpenAI format ID
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": self.state.model or "unknown",
            "choices": [
                {
                    "delta": {"tool_calls": self.state.get_complete_tool_calls()},
                    "index": 0,
                    "finish_reason": "tool_calls",
                }
            ],
        }

    def create_usage_chunk(self) -> Dict[str, Any]:
        """
        Create a chunk with aggregated usage information.

        Returns:
            OpenAI-formatted chunk with usage data
        """
        return {
            "id": f"chatcmpl-{int(time.time())}",  # OpenAI format ID
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": self.state.model or "unknown",
            "choices": [],  # Empty choices for usage-only chunk
            "usage": self.state.usage,
        }

    def create_function_call_events(self) -> List[str]:
        """
        Create SSE function_call events for each tool call.

        Returns individual SSE events using proper event: format:
        event: function_call
        data: {"name": "get_weather", "arguments": "{...}"}

        Returns:
            List of SSE-formatted function call event strings
        """
        tool_calls = self.state.get_complete_tool_calls()
        if not tool_calls:
            return []

        events = []
        for tool_call in tool_calls:
            if "function" in tool_call:
                event_data = {
                    "name": tool_call["function"]["name"],
                    "arguments": tool_call["function"]["arguments"],
                }

                # Create proper SSE event format
                sse_event = f"event: function_call\ndata: {json.dumps(event_data)}\n\n"
                events.append(sse_event)

        return events

    def process_stream(
        self,
        response,
        relay_tool_use_events: bool = False,
        relay_usage_events: bool = False,
        emit_function_announcements: bool = True,
    ) -> Generator[Tuple[str, Dict[str, Any]], None, None]:
        """
        Process a streaming response and yield formatted events.

        Args:
            response: HTTP response with streaming content
            relay_tool_use_events: Whether to relay tool use events immediately
            relay_usage_events: Whether to relay usage events immediately
            emit_function_announcements: Whether to emit function announcement events

        Yields:
            Tuple of (formatted_sse_line, canonical_chunk)
        """
        for line in response.iter_lines(decode_unicode=True):
            # Parse the line
            chunk = self.parse_sse_line(line)
            if not chunk:
                continue

            # print(chunk)
            # Process the chunk
            result = self.process_chunk(chunk)
            if not result:
                continue

            event_type, canonical_chunk = result

            # Handle different event types
            if event_type == StreamEventType.DONE:
                yield "data: [DONE]\n\n", {"type": "done"}
                break

            elif event_type == StreamEventType.CONTENT:
                # Always relay content
                target_chunk = self.convert_to_target_format(canonical_chunk)
                yield f"data: {json.dumps(target_chunk)}\n\n", canonical_chunk

            elif event_type == StreamEventType.TOOL_CALL_START:
                if relay_tool_use_events:
                    target_chunk = self.convert_to_target_format(canonical_chunk)
                    yield f"data: {json.dumps(target_chunk)}\n\n", canonical_chunk

            elif event_type == StreamEventType.TOOL_CALL_DELTA:
                if relay_tool_use_events:
                    target_chunk = self.convert_to_target_format(canonical_chunk)
                    yield f"data: {json.dumps(target_chunk)}\n\n", canonical_chunk

            elif event_type == StreamEventType.TOOL_CALL_COMPLETE:
                # First emit individual function_call events if enabled
                if emit_function_announcements:
                    function_call_events = self.create_function_call_events()
                    for event_sse in function_call_events:
                        # Yield the SSE event with a minimal chunk for compatibility
                        event_chunk = {"event_type": "function_call"}
                        yield event_sse, event_chunk

                # Then emit the buffered tool calls
                buffered_chunk = self.create_buffered_tool_call_chunk()
                target_chunk = self.convert_to_target_format(buffered_chunk)
                yield f"data: {json.dumps(target_chunk)}\n\n", buffered_chunk

            elif event_type == StreamEventType.USAGE:
                if relay_usage_events:
                    target_chunk = self.convert_to_target_format(canonical_chunk)
                    yield f"data: {json.dumps(target_chunk)}\n\n", canonical_chunk

        # Emit final usage if we have it (always emit at end for ModelRunner compatibility)
        if self.state.usage:
            usage_chunk = self.create_usage_chunk()
            target_chunk = self.convert_to_target_format(usage_chunk)
            yield f"data: {json.dumps(target_chunk)}\n\n", usage_chunk

    def collect(self, response, request_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Process the entire stream and return a complete OpenAI non-streaming response.

        This method consumes the stream internally (without yielding events) and
        aggregates everything into a final complete response. Perfect for when you
        want the convenience of streaming processing but need a non-streaming result.

        Args:
            response: HTTP response with streaming content
            request_id: Optional request ID for the response

        Returns:
            Complete OpenAI chat completion response (non-streaming format)
        """
        # Process all events without yielding them (consume internally)
        for _ in self.process_stream(
            response,
            relay_tool_use_events=False,
            relay_usage_events=False,
            emit_function_announcements=False,
        ):
            pass  # Just consume the stream to populate our state

        # Convert aggregated state to complete response
        return self.state.to_openai_response(request_id)


def unified_stream_adapter(
    response,
    source_scheme: str = "openai",
    target_scheme: str = "openai",
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False,
    emit_function_announcements: bool = True,
) -> Generator[Tuple[str, Dict[str, Any]], None, None]:
    """
    Main entry point for the unified stream adapter.

    This function creates an adapter instance and processes the stream.

    Args:
        response: HTTP response with streaming content
        source_scheme: The source provider scheme ('openai', 'anthropic')
        target_scheme: The target provider scheme ('openai', 'anthropic')
        relay_tool_use_events: Whether to relay tool use events immediately
        relay_usage_events: Whether to relay usage events immediately
        emit_function_announcements: Whether to emit function announcement events

    Yields:
        Tuple of (formatted_sse_line, canonical_chunk)
    """
    adapter = UnifiedStreamAdapter(source_scheme, target_scheme)
    yield from adapter.process_stream(
        response, relay_tool_use_events, relay_usage_events, emit_function_announcements
    )


def collect_stream_to_response(
    response,
    source_scheme: str = "openai",
    request_id: Optional[str] = None,
) -> Dict[str, Any]:
    """
    Convenience function to collect a stream into a complete OpenAI response.

    This processes the streaming response internally and returns a complete
    non-streaming OpenAI chat completion response. Perfect for cases where
    you need the result of streaming processing but want a non-streaming format.

    Args:
        response: HTTP response with streaming content
        source_scheme: The source provider scheme ('openai', 'anthropic')
        request_id: Optional request ID for the response

    Returns:
        Complete OpenAI chat completion response (non-streaming format)

    Example:
        response = requests.post(url, stream=True)
        complete_response = collect_stream_to_response(response, "anthropic")
        # Now you have a complete OpenAI-format response with aggregated content
        # and properly buffered tool calls
    """
    adapter = UnifiedStreamAdapter(source_scheme, "openai")
    return adapter.collect(response, request_id)
