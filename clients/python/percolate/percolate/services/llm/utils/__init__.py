"""
LLM utilities module for streaming and formatting.

Legacy streaming functions have been replaced with UnifiedStreamAdapter.
For streaming functionality, use:
  from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter
"""

from .stream_utils import (
    audio_to_text,
    request_openai,
    request_anthropic,
    request_google,
    print_openai_delta_content,
    LLMStreamIterator,
)

__all__ = [
    "audio_to_text",
    "request_openai", 
    "request_anthropic",
    "request_google",
    "print_openai_delta_content",
    "LLMStreamIterator",
]

# Deprecated streaming functions - use UnifiedStreamAdapter instead:
# - Old: stream_openai_response, stream_anthropic_response, stream_google_response
# - Old: sse_openai_compatible_stream_with_tool_call_collapse  
# - New: UnifiedStreamAdapter in proxy.unified_stream_adapter