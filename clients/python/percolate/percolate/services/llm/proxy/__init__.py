"""
Memory proxy for LLM interfaces with unified streaming.

This module implements a unified approach to handling LLM API streaming,
with support for buffering function calls and proper handling of different
API formats (OpenAI, Anthropic, Google).

Key features:
- Unified pydantic models for all provider APIs
- Stream adaptation between different provider formats
- Function call buffering and aggregation
- Usage tracking
- Background auditing for AIResponse records

Usage:
```python
from percolate.services.llm.proxy import (
    OpenAIRequest, AnthropicRequest, GoogleRequest,
    request_stream_from_model, stream_with_buffered_functions,
    BackgroundAudit
)

# Create a request in any provider format
request = OpenAIRequest(
    model="gpt-4",
    messages=[{"role": "user", "content": "Hello"}],
    max_tokens=100,
    stream=True
)

# Stream with unified handling
for line, chunk in request_stream_from_model(
    request, context, target_scheme='openai'
):
    # line is the raw SSE event line to send to the client
    # chunk is the parsed OpenAI-format chunk for internal use
    # ...
```
"""

# Import models
from .models import (
    LLMApiRequest,
    OpenAIRequest,
    AnthropicRequest,
    GoogleRequest,
    StreamDelta,
    OpenAIStreamDelta,
    AnthropicStreamDelta,
    GoogleStreamDelta
)

# Import utils
from .utils import (
    BackgroundAudit,
    parse_sse_line,
    create_sse_line,
    format_tool_calls_for_openai
)

# Import stream generators
from .stream_generators import (
    stream_with_buffered_functions,
    request_stream_from_model,
    flush_ai_response_audit
)

__all__ = [
    # Models
    'LLMApiRequest',
    'OpenAIRequest',
    'AnthropicRequest',
    'GoogleRequest',
    'StreamDelta',
    'OpenAIStreamDelta',
    'AnthropicStreamDelta',
    'GoogleStreamDelta',
    
    # Utils
    'BackgroundAudit',
    'parse_sse_line',
    'create_sse_line',
    'format_tool_calls_for_openai',
    
    # Stream generators
    'stream_with_buffered_functions',
    'request_stream_from_model',
    'flush_ai_response_audit'
]