# LLM Proxy Stream Adapter

## Overview

This module provides unified streaming support for different LLM providers (OpenAI, Anthropic, Google) with consistent OpenAI-compatible output. The core functionality includes:

1. **Multi-provider format conversion** - Map any source scheme to OpenAI SSE events
2. **Tool call buffering** - Buffer function calls until complete (no partial arguments)
3. **Usage aggregation** - Provide OpenAI-compatible usage at the end
4. **Function announcements** - Emit events when functions are called for better UX

## Implementation Status

✅ **Completed**: `UnifiedStreamAdapter` in `unified_stream_adapter.py`
- Replaces the previous `stream_with_buffered_functions` 
- Supports OpenAI ↔ Anthropic conversion
- Full tool call buffering with complete arguments
- Function announcement events
- Collect mode for non-streaming responses

🔄 **Next**: Integration with `ModelRunner` (this document outlines the plan)

## ModelRunner Integration Plan

### Current State Analysis

The `ModelRunner` currently uses `stream_with_buffered_functions` at line 397:

```python
for line, chunk in stream_with_buffered_functions(
    raw_response, source_scheme=lm_client._scheme
):
```

This function is **critical** for the agent loop because it:

1. **Tool Call Detection**: Buffers tool calls until `finish_reason == "tool_calls"`
2. **Agent Loop Termination**: Properly signals `finish_reason == "stop"`
3. **Function Execution**: Provides complete tool calls to `ModelRunner` for execution
4. **Usage Tracking**: Aggregates token usage for `AIResponse` objects

### Integration Strategy

**CRITICAL REQUIREMENT**: Preserve the exact behavioral interface that `ModelRunner` expects:

#### Input Interface
- Same function signature: `(response, source_scheme, target_scheme, relay_tool_use_events, relay_usage_events)`
- Same return type: `Generator[Tuple[str, dict], None, None]`

#### Output Interface  
- `str`: Raw SSE line in target format (for client streaming)
- `dict`: OpenAI canonical chunk (for `ModelRunner` processing)

#### Critical Behavioral Requirements

1. **Tool Call Buffering**:
   - Must buffer incomplete tool call fragments
   - Emit complete tool calls only when `finish_reason == "tool_calls"`
   - Preserve exact tool call structure that `ModelRunner.invoke()` expects

2. **Finish Reason Mapping**:
   - `anthropic "end_turn"` → `openai "stop"`
   - `anthropic "tool_use"` → `openai "tool_calls"`  
   - Critical for agent loop termination logic

3. **Usage Aggregation**:
   - Aggregate tokens across multiple chunks
   - Emit final usage when appropriate
   - Compatible with `AIResponse` generation

4. **Content Streaming**:
   - Stream content deltas immediately (no buffering)
   - Maintain SSE format for client consumption

### Implementation Plan

#### Phase 1: Interface Compatibility Layer
Create `stream_with_buffered_functions_v2()` that wraps `UnifiedStreamAdapter`:

```python
def stream_with_buffered_functions_v2(
    response: Response,
    source_scheme: str = "openai", 
    target_scheme: str = "openai",
    relay_tool_use_events: bool = False,
    relay_usage_events: bool = False,
) -> typing.Generator[typing.Tuple[str, dict], None, None]:
    """
    Compatibility wrapper around UnifiedStreamAdapter.
    Maintains exact interface expected by ModelRunner.
    """
    adapter = UnifiedStreamAdapter(source_scheme, target_scheme)
    yield from adapter.process_stream(
        response, 
        relay_tool_use_events=relay_tool_use_events,
        relay_usage_events=relay_usage_events,
        emit_function_announcements=True  # New feature!
    )
```

#### Phase 2: Testing Strategy

**Integration Test Requirements**:

1. **Function Call Flow Test**:
   - Input: Anthropic stream with tool calls
   - Verify: `ModelRunner` receives complete tool calls
   - Verify: Functions get executed correctly  
   - Verify: Agent loop continues after function execution

2. **Agent Termination Test**:
   - Input: Stream ending with `"stop"` finish reason
   - Verify: `saw_stop = True` triggers loop termination
   - Verify: Final `AIResponse` is generated

3. **Content Streaming Test**:
   - Input: Stream with content deltas
   - Verify: Content streams immediately to clients
   - Verify: `turn_content` accumulates correctly

4. **Function Announcement Test**: 
   - Input: Stream with tool calls
   - Verify: Function announcement events are emitted
   - Verify: Announcements don't break existing logic

#### Phase 3: Migration

1. **Backup**: Save current `stream_with_buffered_functions` as `stream_with_buffered_functions_legacy`
2. **Replace**: Update `ModelRunner.py` line 397 to use new wrapper
3. **Validate**: Run integration tests to ensure no regressions

### Testing Data Requirements

For comprehensive testing, we need sample streams for:

- **OpenAI**: Text response, tool call response  
- **Anthropic**: Text response, tool call response
- **Edge cases**: Empty responses, error conditions, multiple tool calls

### Risk Assessment

**HIGH RISK**: Breaking agent loop termination logic
- **Mitigation**: Extensive testing of finish reason mapping

**MEDIUM RISK**: Tool call format incompatibility  
- **Mitigation**: Validate exact format expected by `FunctionCall` constructor

**LOW RISK**: Performance impact
- **Mitigation**: The new adapter is more efficient than current implementation

## Below is an example of how we get the raw messages

```
M = UserRoleAgent.build_message_stack("What is the captial of ireland")
#or a GPT or gemini model:>
context = CallingContext.with_model('claude-3-7-sonnet-20250219').in_streaming_mode()
lm_client = LanguageModel.from_context(context)
raw_response = lm_client._call_raw(
        messages=M,
        functions=None,
        context=context,
    )
raw_response
```

This is an example of the top level agent that needs to use this via the ModelRunner - note the stream function.
Internally the function manages a generator that handles tool calling etc once your function provides the buffered tool calls with usage.

```
agent = p8.Agent(UserRoleAgent)
 
context = CallingContext(user_id='10e0a97d-a064-553a-9043-3c1f0a6e6725', role_level=10,
                         #model='claude-3-7-sonnet-20250219'
                        )

for s in agent.stream("What can you tell me about create one", context=context).iter_lines():
    print_openai_delta_content(s.decode())
```
