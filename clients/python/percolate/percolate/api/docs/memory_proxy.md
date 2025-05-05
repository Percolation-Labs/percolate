# Memory Proxy Architecture

## Overview

The Memory Proxy is designed to provide a unified streaming interface for LLM responses while efficiently handling the auditing and memory functionality. It builds on the existing proxy model architecture to standardize how we handle streaming deltas, tool calls, and usage data across different LLM providers.

## ModelRunner Stream Function with Memory Proxy

The `ModelRunner.stream()` function would be enhanced to leverage our new proxy architecture to make LLM streaming more efficient while automatically handling background memory/auditing operations.

### Current Implementation Challenges

The current `stream()` implementation has several limitations:

1. It manually processes streaming chunks and handles tool calls
2. It has to manage multiple formats across different LLM providers
3. Auditing is tightly coupled with the streaming logic
4. Memory records are created in the streaming path, potentially impacting performance

### Enhanced Implementation with Memory Proxy

```python
def stream(self, question: str, context: CallingContext = None, limit: int = None,
           data: typing.List[dict] = None, language_model: str = None, audit: bool = True):
    """
    Stream the agentic loop as SSE events with efficient memory auditing.
    
    Uses the memory proxy to handle format conversion, buffering tool calls,
    and background auditing without blocking the user stream.
    
    Args:
        question: The user question to begin the loop.
        context: Optional CallingContext; if omitted, a new streaming context is used.
        limit: Max number of agent iterations (function call loops).
        data: Initial data payload for the agent.
        language_model: Override the LLM model name.
        audit: If True, dump audit record after completion.
        
    Yields:
        str: SSE-formatted event strings (e.g. "data: ...\n\n").
    """
    # Set up context and language model client
    if context:
        ctx = context.in_streaming_mode(model=language_model)
    else:
        ctx = CallingContext.with_model(language_model).in_streaming_mode()
    self._context = ctx
    lm_client = LanguageModel.from_context(ctx)
    
    # Initialize message stack
    sys_prompt = GENERIC_P8_PROMPT if not context.plan else f"{GENERIC_P8_PROMPT}\n\n{context.plan}"
    payload = data if data is not None else self._init_data
    self.messages = self.agent_model.build_message_stack(
        question=question,
        functions=self.functions.keys(),
        data=payload,
        system_prompt_preamble=sys_prompt,
        user_memory=ctx.get_user_memory()
    )
    
    max_loops = limit or ctx.max_iterations
    
    def _generator():
        """Generator that manages the agentic loop and streaming"""
        saw_stop = False  # Control flag for agent loop termination
        
        # Agent loop
        for _ in range(max_loops):
            # Track state for this turn
            turn_content = ''
            saw_tool_call = False
            turn_usage = {}
            last_ai_response = None
            
            # Use lm_client to handle raw request with proxy streaming
            raw_response = lm_client.stream_with_proxy(
                messages=self.messages,
                functions=self.function_descriptions,
                context=ctx
            )
            
            # Process the proxied stream
            for line, chunk in raw_response:
                choice = chunk.get('choices', [{}])[0]
                finish = choice.get('finish_reason')
                
                # Handle buffered tool calls
                if finish == 'tool_calls':
                    # Tool-call turn: capture usage and mark
                    saw_tool_call = True
                    turn_usage = chunk.get('usage', {}) or {}
                    
                    # Invoke each buffered function call and build aggregate response data
                    tool_call_evals = {}
                    for tc in choice['delta'].get('tool_calls', []):
                        fc = FunctionCall(id=tc['id'], **tc['function'], scheme='openai')
                        yield f"event: im calling {fc.name}...\n\n"
                        self.messages.add(fc.to_assistant_message())
                        tool_call_evals[fc.id] = self.invoke(fc)
                        
                    last_ai_response = {
                        'tool_calls': choice['delta'].get('tool_calls', []),
                        'tool_eval_data': tool_call_evals,
                        'function_stack': self.functions.keys()
                    }
                
                # Stream content deltas
                delta = choice.get('delta', {}) or {}
                if 'content' in delta:
                    piece = delta.get('content') or ''
                    # Send to any streaming callback
                    if context.streaming_callback:
                        context.streaming_callback(line)
                    # Accumulate content for this turn
                    turn_content += piece
                    # Yield the SSE-formatted line for client
                    yield line
                
                # Handle completion of this turn
                if not saw_tool_call:
                    last_ai_response = {'content': turn_content}
                
                if finish == 'stop':
                    saw_stop = True
                
                # If we have usage data at end of turn, process it
                if turn_usage := chunk.get('usage'):
                    # Yield AIResponse for auditing
                    yield lm_client.parse_ai_response(last_ai_response, turn_usage, ctx)
            
            # Break out of the agentic loop if we're done
            if saw_stop:
                break
                
    # Return properly wrapped stream iterator
    return lm_client.get_stream_iterator(_generator, context=ctx)
```

### Changes to LanguageModel class

To support this implementation, we would add a new method to the LanguageModel class:


## Key Benefits

1. **Efficient Streaming**
   - The new proxy architecture handles all the complexity of stream format conversions
   - Tool calls are properly buffered and only emitted when complete
   - Preserves the essential agentic loop termination conditions

2. **Unified Format Handling**
   - All LLM providers (OpenAI, Anthropic, Google) use the same code path
   - Format conversion is handled by the proxy models
   - Consistent handling of tool calls across providers

3. **Improved Architecture**
   - The LanguageModel class handles the low-level details of proxy streaming
   - ModelRunner maintains control over the agentic loop logic
   - AIResponse auditing is integrated with the existing approach

4. **Proper Resource Usage**
   - Usage data is collected at the end of each turn
   - AIResponses are properly generated at turn boundaries
   - Memory records are collected in the right sequence

## Stream Generators and Proxy Models

The proxy module provides several key components:

1. **Stream Generators**
   - `request_stream_from_model()`: Makes API requests and streams results
   - `stream_with_buffered_functions()`: Processes raw streams, buffers tool calls

2. **Delta Models**
   - `OpenAIStreamDelta`, `AnthropicStreamDelta`, `GoogleStreamDelta`: Handle format conversion
   - Each model type understands how to transform between formats

3. **Request Models**
   - `OpenAIRequest`, `AnthropicRequest`, `GoogleRequest`: Format API requests consistently
   - Common interface for creating API requests across providers

4. **Integration with LLM Client**
   - The LanguageModel class integrates with the proxy system
   - Maintains the context and session auditing logic
   - Preserves the existing generator-based streaming approach

## Implementation Notes and Gotchas

### AIResponse Capture in the Agentic Loop

The implementation carefully preserves our existing approach to capturing AIResponse turns in the agentic loop:

1. **Turn Boundaries**: Each turn in the agent loop (a request-response cycle) generates an AIResponse. Turn boundaries are detected when:
   - A tool call is completed (`finish_reason == 'tool_calls'`)
   - A content response is completed (`finish_reason == 'stop'`)
   - Usage data is received (typically at the end of a turn)

2. **AIResponse Construction**: 
   - For tool calls: We collect the tool calls, their evaluation results, and usage data
   - For content: We accumulate the streamed content chunks and usage data
   - The `parse_ai_response()` method creates standardized AIResponse objects

3. **Yield vs. Audit**: 
   - The implementation yields raw SSE lines directly to the client
   - AIResponse objects are created at turn boundaries with the full context of the turn
   - The LanguageModel's `_audit_response()` method sends AIResponses to the background worker
   - The background worker handles auditing without blocking the main stream

### Potential Gotchas

1. **Format Consistency**: The implementation standardizes on OpenAI format for internal processing, but you must ensure consistent handling of:
   - Function arguments format (JSON string vs. dictionary)
   - Tool call IDs (consistent across models)
   - Function call scheme tracking

2. **Stream Order Guarantees**:
   - The proxy buffers tool calls until complete, ensuring they arrive as a single event
   - Usage events occur after content/tool call events
   - The `[DONE]` event must be the last event in the stream

3. **Termination Conditions**:
   - The agentic loop must properly detect and handle the `saw_stop` flag
   - Each turn must yield an AIResponse for proper auditing
   - Some LLM providers might have different behavior around tool call termination

4. **Background Processing**:
   - Background auditing is non-blocking, but we must ensure all records are flushed
   - If the server terminates before background threads complete, some audit records might be lost

## Testing Considerations

When writing unit tests, consider testing:

1. **Format Conversion**: 
   - Test converting between OpenAI, Anthropic, and Google formats
   - Test with different types of content (text, tool calls, etc.)

2. **Streaming Flow**:
   - Test the complete flow from ModelRunner through LanguageModel and proxy
   - Mock the HTTP response to simulate different streaming patterns

3. **Agentic Loop Termination**:
   - Test that the agent loop correctly terminates on final responses
   - Test that function calls are correctly processed mid-stream

4. **Error Handling**:
   - Test handling of HTTP errors
   - Test malformed responses or unexpected formats

5. **AIResponse Auditing**:
   - Test that AIResponses are correctly created and include all required fields
   - Test that background auditing works correctly

## Conclusion

The Memory Proxy architecture enhances our streaming experience while preserving the critical agentic loop control flow. By delegating format conversions and request handling to the proxy, but keeping control of the agent loop in ModelRunner, we maintain our existing termination conditions and auditing processes while gaining the benefits of unified format handling.

This implementation gives us better scalability, more efficient streaming, and the ability to handle multiple model providers with a single code path while ensuring that our auditing and memory requirements are fully met.