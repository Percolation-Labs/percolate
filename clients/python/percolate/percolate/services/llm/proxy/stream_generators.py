"""
ModelRunner integration layer for the new UnifiedStreamAdapter.

This module provides a compatibility wrapper that maintains the exact interface
expected by ModelRunner while using the new UnifiedStreamAdapter internally.
"""

import typing
from typing import Generator, Tuple
from requests import Response

from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter, collect_stream_to_response
from percolate.utils import logger


def stream_with_buffered_functions(
    response: Response,
    source_scheme: str = "openai",
    target_scheme: str = "openai", 
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False,
) -> Generator[Tuple[str, dict], None, None]:
    """
    ModelRunner-compatible wrapper around UnifiedStreamAdapter.
    
    This function maintains the exact interface expected by ModelRunner.py
    while providing the new functionality including function announcements.
    
    Args:
        response: HTTP response object with streaming LLM response
        source_scheme: Source provider scheme ('openai', 'anthropic') 
        target_scheme: Target provider scheme ('openai', 'anthropic')
        relay_tool_use_events: Whether to relay tool use events immediately
        relay_usage_events: Whether to relay usage events immediately
        
    Yields:
        Tuple of (sse_line, canonical_chunk) exactly as expected by ModelRunner
        - sse_line: Raw SSE-formatted line for client streaming  
        - canonical_chunk: OpenAI canonical format for ModelRunner processing
        
    Critical behavioral requirements for ModelRunner integration:
    1. Tool calls must be buffered until complete (no partial arguments)
    2. finish_reason == "tool_calls" must trigger tool execution
    3. finish_reason == "stop" must trigger agent loop termination
    4. Content must stream immediately without buffering
    5. Usage must be aggregated and available for AIResponse generation
    """
    adapter = UnifiedStreamAdapter(source_scheme, target_scheme)
    
    yield from adapter.process_stream(
        response,
        relay_tool_use_events=relay_tool_use_events,
        relay_usage_events=relay_usage_events,
        emit_function_announcements=True  # Enable new functionality
    )


def flush_ai_response_audit(
    content: str,
    tool_calls: typing.List[dict],
    tool_responses: typing.Dict[str, dict],
    usage: typing.Dict[str, int],
) -> None:
    """
    [DEPRECATED] This function has been replaced by audit_response_for_user.

    Use audit_response_for_user with LLMStreamIterator.audit_on_flush=True instead.
    This function remains for backward compatibility but only logs a warning.
    """
    logger.warning(
        "flush_ai_response_audit is deprecated. "
        "Use LLMStreamIterator with audit_on_flush=True instead, "
        "which will call audit_response_for_user at the end of the stream."
    )


def request_stream_from_model(
    request,
    context=None, 
    target_scheme: str = "openai",
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False,
):
    """
    [DEPRECATED] High-level function for streaming from LLM models.
    
    This function is deprecated. Use UnifiedStreamAdapter directly:
    
    ```python
    from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter
    
    adapter = UnifiedStreamAdapter(source_scheme, target_scheme)
    for sse_line, chunk in adapter.process_stream(response):
        # Process events
    ```
    """
    logger.warning(
        "request_stream_from_model is deprecated. "
        "Use UnifiedStreamAdapter directly for better control and clarity."
    )