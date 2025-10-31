"""some simple streaming adapters
these have not been well tested for all cases but for function calling and simple text content they work.

"""

from .utils.stream_utils import (
    audio_to_text,
    request_openai,
    request_anthropic,
    request_google,
    print_openai_delta_content,
    LLMStreamIterator,
)

# For backwards compatibility
__all__ = [
    "audio_to_text",
    "request_openai",
    "request_anthropic", 
    "request_google",
    "print_openai_delta_content",
    "LLMStreamIterator",
]