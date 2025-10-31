"""
Memory proxy for LLM interfaces with unified streaming.

This module implements a unified approach to handling LLM API streaming,
with support for buffering function calls, function call events, and proper
handling of different API formats (OpenAI, Anthropic).

Key features:
- UnifiedStreamAdapter for all streaming needs
- Function call buffering and aggregation  
- Function call SSE events for better UX
- Format conversion between providers
- Usage tracking and aggregation
- Background auditing for AIResponse records

Usage:
```python
from percolate.services.llm.proxy import (
    UnifiedStreamAdapter,
    collect_stream_to_response
)

# Use the unified stream adapter
adapter = UnifiedStreamAdapter("anthropic", "openai")
for sse_line, chunk in adapter.process_stream(response, emit_function_announcements=True):
    if sse_line.startswith('event: function_call'):
        # Handle function call announcements
        print("Function being called...")
    elif chunk.get("choices"):
        # Handle regular content and tool calls
        pass

# Or collect entire stream into complete response  
complete_response = collect_stream_to_response(response, "anthropic")
```

Legacy functions (deprecated):
- `stream_with_buffered_functions` - Use UnifiedStreamAdapter directly
- `request_stream_from_model` - Use UnifiedStreamAdapter directly
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

# Import stream generators (legacy compatibility)
from .stream_generators import (
    stream_with_buffered_functions,
    request_stream_from_model,
    flush_ai_response_audit
)

# Import new unified streaming
from .unified_stream_adapter import (
    UnifiedStreamAdapter,
    collect_stream_to_response
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
    
    # Stream generators (legacy)
    'stream_with_buffered_functions',
    'request_stream_from_model', 
    'flush_ai_response_audit',
    
    # New unified streaming
    'UnifiedStreamAdapter',
    'collect_stream_to_response'
]