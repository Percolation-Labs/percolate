"""
LLM utilities module for streaming and formatting.
"""

from .stream_utils import (
    stream_openai_response,
    stream_anthropic_response,
    stream_google_response,
    sse_openai_compatible_stream_with_tool_call_collapse,
    LLMStreamIterator,
    audio_to_text
)

__all__ = [
    "stream_openai_response",
    "stream_anthropic_response",
    "stream_google_response",
    "sse_openai_compatible_stream_with_tool_call_collapse",
    "LLMStreamIterator",
    "audio_to_text"
]

# HybridResponse has been deprecated and removed
# Use the new proxy module functionality instead:
# - stream_with_buffered_functions() in proxy.stream_generators
# - request_stream_from_model() in proxy.stream_generators