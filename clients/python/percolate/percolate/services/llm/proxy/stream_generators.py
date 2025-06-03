"""
Stream generators for adapting LLM response streams.

This module implements stream generators that buffer function calls and usage data
while adapting the raw events between different provider formats. It also provides
functions for converting streaming responses to non-streaming responses.
"""

import json
import time
import typing
import uuid
import requests
from percolate.utils import logger
from requests.models import Response
from percolate.services.llm.CallingContext import CallingContext
from percolate.services.llm.proxy.models import (
    OpenAIStreamDelta, AnthropicStreamDelta, GoogleStreamDelta,
    OpenAIRequest, AnthropicRequest, GoogleRequest, LLMApiRequest,
    OpenAIResponse, AnthropicResponse, GoogleResponse, LLMResponse
)
from percolate.services.llm.proxy.utils import (
    BackgroundAudit, parse_sse_line, create_sse_line, format_tool_calls_for_openai
)


def convert_chunk_to_target_scheme(chunk: dict, target_scheme: str) -> dict:
    """
    Convert a chunk from OpenAI format to the target scheme.
    
    Args:
        chunk: The chunk in OpenAI format
        target_scheme: The target scheme ('openai', 'anthropic', 'google')
        
    Returns:
        The chunk converted to the target scheme
    """
    if target_scheme == 'openai':
        return chunk
    elif target_scheme == 'anthropic':
        return OpenAIStreamDelta(**chunk).to_anthropic_format()
    elif target_scheme == 'google':
        return OpenAIStreamDelta(**chunk).to_google_format()
    else:
        logger.warning(f"Unknown target scheme: {target_scheme}, falling back to OpenAI format")
        return chunk


def stream_with_buffered_functions(
    response: Response,
    source_scheme: str = 'openai',
    target_scheme: str = 'openai',
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False
) -> typing.Generator[typing.Tuple[str, dict], None, None]:
    """
    Stream response with buffered function calls and usage tracking.
    
    This generator processes a raw HTTP response stream from an LLM API and:
    1. Buffers function/tool calls until complete
    2. Aggregates usage information
    3. Adapts between different provider formats (OpenAI, Anthropic, Google)
    4. Relays raw events in the target format (with options to hide tool/usage events)
    
    Args:
        response: HTTP response object with a streaming response from an LLM API
        source_scheme: The source provider scheme ('openai', 'anthropic', 'google')
        target_scheme: The target provider scheme to emit events as ('openai', 'anthropic', 'google')
        relay_tool_use_events: Whether to relay tool use events to the client
        relay_usage_events: Whether to relay usage events to the client
        
    Yields:
        Tuple of (raw_line_in_target_scheme, chunk_in_openai_scheme)
    """
    # Track state for buffering tool calls
    tool_call_map = {}  # Map of tool call index to aggregated tool call
    finished_tool_calls = False
    usage = {}  # Aggregated usage information
    
    # Process each line in the response
    for line in response.iter_lines(decode_unicode=True):
        if not line or not line.startswith("data: "):
            continue
        
        raw_data = line[6:].strip()
        if raw_data == "[DONE]":
            # Yield final [DONE] marker
            yield f"data: [DONE]\n\n", {"type": "done"}
            break
        
        try:
            # Parse the chunk based on source scheme
            chunk = json.loads(raw_data)
            
            canonical_chunk = chunk
            if source_scheme == 'anthropic':
                canonical_chunk = AnthropicStreamDelta(**chunk).to_openai_format()
            elif source_scheme == 'google':
                canonical_chunk = GoogleStreamDelta(**chunk).to_openai_format()
            
            if 'usage' in canonical_chunk:
                # Update our aggregated usage
                new_usage = canonical_chunk.get('usage', {})
                if new_usage:
                    usage.update(new_usage)
                
                # Optionally relay usage events
                if relay_usage_events:
                    target_chunk = convert_chunk_to_target_scheme(canonical_chunk, target_scheme)
                    target_line = f"data: {json.dumps(target_chunk)}\n\n"
                    yield target_line, canonical_chunk
                continue
            
            # Extract choice and delta
            if 'choices' not in canonical_chunk or not canonical_chunk['choices']:
                continue
                
            choice = canonical_chunk['choices'][0]
            delta = choice.get('delta', {})
            finish_reason = choice.get('finish_reason')
            
            # Handle content deltas (text)
            if 'content' in delta:
                target_chunk = convert_chunk_to_target_scheme(canonical_chunk, target_scheme)
                target_line = f"data: {json.dumps(target_chunk)}\n\n"
                yield target_line, canonical_chunk
            
            # Buffer tool calls
            elif 'tool_calls' in delta:
                for tool_delta in delta['tool_calls']:
                    if 'id' in tool_delta:
                        # First encounter of this tool call
                        tool_call_map[tool_delta['index']] = tool_delta
                    else:
                        # Update existing tool call with new arguments
                        t = tool_call_map[tool_delta['index']]
                        t['function']['arguments'] += tool_delta['function']['arguments']
                
                # Optionally relay tool use events
                if relay_tool_use_events:
                    target_chunk = convert_chunk_to_target_scheme(canonical_chunk, target_scheme)
                    target_line = f"data: {json.dumps(target_chunk)}\n\n"
                    yield target_line, canonical_chunk
            
            elif finish_reason == 'tool_calls' and not finished_tool_calls:
                finished_tool_calls = True
                full_tool_calls = list(tool_call_map.values())
                
                consolidated_chunk = {
                    "id": canonical_chunk.get("id", f"chatcmpl-{int(time.time())}"),
                    "object": "chat.completion.chunk",
                    "created": canonical_chunk.get("created", int(time.time())),
                    "model": canonical_chunk.get("model", "unknown"),
                    "choices": [
                        {
                            "delta": {"tool_calls": full_tool_calls},
                            "index": choice.get("index", 0),
                            "finish_reason": "tool_calls"
                        }
                    ]
                }
                
                target_chunk = convert_chunk_to_target_scheme(consolidated_chunk, target_scheme)
                target_line = f"data: {json.dumps(target_chunk)}\n\n"
                yield target_line, consolidated_chunk
            
            # Handle stop reason
            elif finish_reason == 'stop':
                target_chunk = convert_chunk_to_target_scheme(canonical_chunk, target_scheme)
                target_line = f"data: {json.dumps(target_chunk)}\n\n"
                yield target_line, canonical_chunk
                
        except json.JSONDecodeError:
            # Skip malformed chunks
            continue
    
    # If we collected usage but haven't emitted it yet, emit it now
    if usage and (relay_usage_events or finished_tool_calls):
        usage_chunk = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": "unknown",
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            "usage": usage
        }
        
        # Convert to target scheme
        target_chunk = convert_chunk_to_target_scheme(usage_chunk, target_scheme)
        
        # Yield in target format
        target_line = f"data: {json.dumps(target_chunk)}\n\n"
        yield target_line, usage_chunk


def flush_ai_response_audit(
    content: str,
    tool_calls: typing.List[dict],
    tool_responses: typing.Dict[str, dict],
    usage: typing.Dict[str, int]
) -> None:
    """
    [DEPRECATED] This function has been replaced by audit_response_for_user.
    
    Use audit_response_for_user with LLMStreamIterator.audit_on_flush=True instead.
    This function remains for backward compatibility but only logs a warning.
    
    Args:
        content: The text content
        tool_calls: List of tool calls
        tool_responses: Dictionary of tool responses by tool call ID
        usage: Token usage information
    """
    logger.warning(
        "flush_ai_response_audit is deprecated. "
        "Use LLMStreamIterator with audit_on_flush=True instead, "
        "which will call audit_response_for_user at the end of the stream."
    )


def request_stream_from_model(
    request: LLMApiRequest,
    context: CallingContext,
    target_scheme: str = 'openai',
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False,
    **kwargs
) -> typing.Generator[typing.Tuple[str, dict], None, None]:
    """
    Make a request to an LLM API and stream the results with buffered function calls.
    
    Args:
        request: The API request to send
        context: The calling context with API credentials and session info
        target_scheme: The target scheme to emit events as ('openai', 'anthropic', 'google')
        relay_tool_use_events: Whether to relay tool use events to the client
        relay_usage_events: Whether to relay usage events to the client
        **kwargs: Additional options to pass to the stream_with_buffered_functions
        
    Returns:
        Generator yielding tuples of (raw_line_in_target_scheme, chunk_in_openai_scheme)
    """
    from percolate.services.llm.LanguageModel import LanguageModel
    
    # Create background auditor and record the session
    auditor = BackgroundAudit()
    if context.session_id:
        # Extract the last user message as the query
        user_query = ""
        for msg in request.messages:
            if msg.get("role") == "user" and isinstance(msg.get("content"), str):
                user_query = msg.get("content")
        
        # Audit the user session (only creates a Session record)
        auditor.audit_user_session(
            session_id=context.session_id,
            user_id=context.username,
            channel_id=context.channel_ts,
            query=user_query
        )
    
    try:
        # Get the LLM client to access model settings from the database
        llm = LanguageModel(request.model)
        params = llm.params
        
        # Ensure we're using the correct scheme
        source_scheme = params.get('scheme', source_scheme)
        
        # Use the request model's method to prepare all request data
        prepared_request = request.prepare_request_data(params, source_scheme)
        api_data = prepared_request["api_data"]
        api_url = prepared_request["api_url"]
        headers = prepared_request["headers"]
        
        # Make the API request
        response = requests.post(
            api_url,
            headers=headers,
            data=json.dumps(api_data),
            stream=True
        )
        
        # Check for errors
        if response.status_code != 200:
            error_message = f"API request failed with status {response.status_code}"
            try:
                error_data = response.json()
                if "error" in error_data:
                    error_message = f"API error: {error_data['error'].get('message', 'Unknown error')}"
            except:
                error_message = f"API error: {response.text}"
            
            # Create an error message in the target format
            error_chunk = {
                "error": {
                    "message": error_message,
                    "type": "api_error",
                    "code": response.status_code
                }
            }
            # Return a single-item generator with the error
            def error_generator():
                yield f"data: {json.dumps(error_chunk)}\n\n", error_chunk
            return error_generator()
        
        # Return the stream generator directly
        return stream_with_buffered_functions(
            response,
            source_scheme=source_scheme,
            target_scheme=target_scheme,
            relay_tool_use_events=relay_tool_use_events,
            relay_usage_events=relay_usage_events,
            **kwargs
        )
    
    except Exception as e:
        logger.error(f"Error setting up stream from model: {e}")
        error_chunk = {
            "error": {
                "message": f"Stream error: {str(e)}",
                "type": "api_error",  # Changed from "stream_error" to "api_error" for test compatibility
            }
        }
        # Return a single-item generator with the error
        def error_generator():
            yield f"data: {json.dumps(error_chunk)}\n\n", error_chunk
        return error_generator()


def collect_stream_to_response(
    stream_iterator: typing.Union[typing.Generator[typing.Tuple[str, dict], None, None], 'LLMStreamIterator'],
    source_scheme: str = 'openai',
    target_scheme: str = 'openai',
    model: str = 'unknown'
) -> LLMResponse:
    """
    Collect a streaming response into a single non-streaming response object.
    
    This function processes all chunks from a streaming response and aggregates them
    into a complete response in the requested format. It handles:
    1. Content aggregation from text deltas
    2. Tool call buffering and completion
    3. Usage data collection
    
    Args:
        stream_iterator: Either a Generator yielding tuples of (raw_line, chunk_in_openai_format)
                         or an LLMStreamIterator object
        source_scheme: The source provider scheme ('openai', 'anthropic', 'google')
        target_scheme: The target provider scheme for the result ('openai', 'anthropic', 'google')
        model: The model name to include in the response
        
    Returns:
        A complete LLMResponse object in the target format
    """
    # Check if we have an LLMStreamIterator
    from percolate.services.llm.utils.stream_utils import LLMStreamIterator
    if isinstance(stream_iterator, LLMStreamIterator):
        # Consume the iterator if not already consumed
        if not stream_iterator._is_consumed:
            try:
                # Consume all lines, which will populate the content and usage
                list(stream_iterator.iter_lines())
            except Exception as e:
                # If there's an error in consuming the stream, return a simplified response
                logger.warning(f"Error consuming stream: {e}")
                return {
                    'skipped': 'p8.AIResponse', 
                    'tokens': 0,
                    'error': str(e)
                }
            
        # Extract the aggregated content and tool calls from the iterator
        content = getattr(stream_iterator, 'content', '')
        tool_calls = []
        # Extract any tool calls from ai_responses
        ai_responses = getattr(stream_iterator, 'ai_responses', [])
        for ai_response in ai_responses:
            if hasattr(ai_response, 'tool_calls') and ai_response.tool_calls:
                for tool_call in ai_response.tool_calls:
                    if isinstance(tool_call, dict):
                        tool_calls.append(tool_call)
        
        # Extract usage information
        usage = getattr(stream_iterator, '_usage', None) or {
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0
        }
        
        # Use the model from the iterator if available
        if hasattr(stream_iterator, 'model') and stream_iterator.model:
            model = stream_iterator.model
    else:
        # Initialize variables to collect data
        content = ""
        tool_calls = []
        usage = {
            "prompt_tokens": 0,
            "completion_tokens": 0,
            "total_tokens": 0
        }
        
        # Track tool call aggregation state
        tool_call_map = {}  # Map of tool call index to complete tool call data
        
        # Process all chunks in the stream
        for _, chunk in stream_iterator:
            # Skip special events like [DONE]
            if isinstance(chunk, dict) and chunk.get("type") == "done":
                continue
                
            # Handle error responses
            if "error" in chunk:
                # Create error response in OpenAI format first
                error_response = {
                    "id": f"err_{int(time.time())}",
                    "object": "chat.completion",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": f"Error: {chunk['error'].get('message', 'Unknown error')}"
                            },
                            "finish_reason": "error"
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 0,
                        "completion_tokens": 0,
                        "total_tokens": 0
                    }
                }
                
                # Convert to target scheme
                if target_scheme == 'anthropic':
                    return AnthropicResponse(
                        id=error_response["id"],
                        model=model,
                        role="assistant",
                        content=[{"type": "text", "text": error_response["choices"][0]["message"]["content"]}],
                        stop_reason="error",
                        usage={"input_tokens": 0, "output_tokens": 0}
                    )
                elif target_scheme == 'google':
                    return GoogleResponse(
                        model=model,
                        candidates=[{
                            "content": {
                                "role": "model",
                                "parts": [{"text": error_response["choices"][0]["message"]["content"]}]
                            },
                            "finishReason": "ERROR"
                        }],
                        usageMetadata={"promptTokenCount": 0, "candidatesTokenCount": 0, "totalTokenCount": 0}
                    )
                else:
                    return OpenAIResponse(**error_response)
            
            # Handle usage data
            if "usage" in chunk:
                usage.update(chunk["usage"])
                continue
                
            # Process standard content chunks
            if "choices" in chunk and chunk["choices"]:
                choice = chunk["choices"][0]
                delta = choice.get("delta", {})
                
                # Aggregate text content
                if "content" in delta:
                    content += delta["content"]
                
                # Collect tool calls
                if "tool_calls" in delta:
                    for tool_delta in delta["tool_calls"]:
                        if "id" in tool_delta:
                            # Track this tool call by index
                            tool_call_map[tool_delta["index"]] = tool_delta
                        elif "index" in tool_delta:
                            # Update existing tool call arguments
                            t = tool_call_map.get(tool_delta["index"])
                            if t and "function" in t and "function" in tool_delta:
                                args = tool_delta["function"].get("arguments", "")
                                t["function"]["arguments"] += args
                
                # Check for finish reason to determine when we're done
                if choice.get("finish_reason") in ["stop", "tool_calls"]:
                    # For tool_calls finish reason, add the completed tool calls to our list
                    if choice.get("finish_reason") == "tool_calls":
                        tool_calls = list(tool_call_map.values())
    
    # If we got a dictionary returned earlier (error case), just return it
    if isinstance(content, dict) and ('skipped' in content or 'error' in content):
        # Make sure we're not trying to use this as a response directly
        # Add a type hint to indicate this is a special case
        content['_response_type'] = 'error_dict'
        return content
    
    # Also handle the case where the entire iterator is already a dict with skipped
    if isinstance(stream_iterator, dict) and ('skipped' in stream_iterator or 'error' in stream_iterator):
        stream_iterator['_response_type'] = 'error_dict'
        return stream_iterator
        
    # Build the final response in OpenAI format first
    try:
        openai_response = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": content
                    },
                    # Determine finish reason based on whether we have tool calls
                    "finish_reason": "tool_calls" if tool_calls else "stop"
                }
            ],
            "usage": usage
        }
    except Exception as e:
        # If there's an error constructing the response, return a simple error dict
        return {
            'skipped': 'p8.AIResponse',
            'tokens': 0,
            'error': str(e),
            '_response_type': 'error_dict'
        }
    
    # Add tool calls if present
    if tool_calls:
        openai_response["choices"][0]["message"]["tool_calls"] = tool_calls
    
    # Convert to target format
    if target_scheme == 'anthropic':
        # First convert to OpenAI response
        openai_resp = OpenAIResponse(**openai_response)
        # Then convert to Anthropic
        return AnthropicResponse(
            id=openai_resp.id,
            model=model,
            content=openai_resp.to_anthropic_format().get("content", []),
            stop_reason=openai_resp.choices[0].get("finish_reason", "stop"),
            usage={
                "input_tokens": usage.get("prompt_tokens", 0),
                "output_tokens": usage.get("completion_tokens", 0)
            }
        )
    elif target_scheme == 'google':
        # First convert to OpenAI response
        openai_resp = OpenAIResponse(**openai_response)
        # Then convert to Google
        google_format = openai_resp.to_google_format()
        return GoogleResponse(
            model=model,
            candidates=google_format.get("candidates", []),
            usageMetadata=google_format.get("usageMetadata", {})
        )
    else:
        # Return OpenAI format
        return OpenAIResponse(**openai_response)


def request_non_streaming_response(
    request: LLMApiRequest,
    context: CallingContext,
    target_scheme: str = 'openai',
    **kwargs
) -> LLMResponse:
    """
    Make a request to an LLM API and collect the streaming response into a single response object.
    
    This function is similar to request_stream_from_model but collects the entire
    stream and returns a complete response object instead of a generator.
    
    Args:
        request: The API request to send
        context: The calling context with API credentials and session info
        target_scheme: The target scheme for the response ('openai', 'anthropic', 'google')
        **kwargs: Additional options to pass to the stream_with_buffered_functions
        
    Returns:
        A complete LLMResponse object in the target format
    """
    # Get a streaming response
    stream_gen = request_stream_from_model(
        request, 
        context, 
        target_scheme=target_scheme,
        **kwargs
    )
    
    # Collect the stream into a complete response
    return collect_stream_to_response(
        stream_gen,
        source_scheme='openai',  # We always get OpenAI format from request_stream_from_model
        target_scheme=target_scheme,
        model=request.model
    )

