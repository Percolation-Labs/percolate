"""some simple streaming adapters
these have not been well tested for all cases but for function calling and simple text content they work.

"""

from .utils.stream_utils import (
    audio_to_text,
    stream_openai_response,
    stream_anthropic_response,
    stream_google_response,
    sse_openai_compatible_stream_with_tool_call_collapse,
    LLMStreamIterator,
    HybridResponse,
    request_openai,
    request_anthropic,
    request_google,
    _parse_open_ai_response,
    print_openai_delta_content
)

# For backwards compatibility
__all__ = [
    "audio_to_text",
    "stream_openai_response",
    "stream_anthropic_response",
    "stream_google_response",
    "sse_openai_compatible_stream_with_tool_call_collapse",
    "LLMStreamIterator",
    "HybridResponse",
    "request_openai",
    "request_anthropic", 
    "request_google",
    "_parse_open_ai_response",
    "print_openai_delta_content"
]