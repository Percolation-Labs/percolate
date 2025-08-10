# Test Coverage - Unified Stream Adapter

## Overview

This document outlines the comprehensive test coverage for the `UnifiedStreamAdapter` and related streaming functionality. The tests validate streaming format conversion, tool call buffering, function call events, and ModelRunner integration.

## Test Structure

### 1. Unit Tests
**Location**: `/test_percolate/unit/services/llm/proxy/`

#### `test_unified_stream_adapter.py`
- **StreamState Management**: Tests the core state tracking dataclass
- **Format Conversion**: Tests conversion between OpenAI and Anthropic formats
- **Tool Call Buffering**: Tests tool call fragment aggregation
- **Function Call Events**: Tests new SSE function call events
- **Error Handling**: Tests malformed data handling
- **Relay Options**: Tests selective event relaying

#### `test_collect_and_function_announcements.py`
- **Collect Functionality**: Tests stream-to-response conversion
- **Function Call Events**: Tests individual function call SSE events
- **Structure Validation**: Tests required field presence
- **Multiple Functions**: Tests handling of multiple simultaneous function calls

#### `test_incremental_adapter.py`
- **Progressive Complexity**: 5 levels of increasing complexity
- **Basic Streaming**: Simple content events
- **Tool Call Scenarios**: Various function calling patterns
- **Edge Cases**: Error conditions and boundary cases

#### `test_unified_adapter_with_samples.py`
- **Real API Data**: Tests with actual API response samples
- **Format Validation**: Ensures proper OpenAI compatibility
- **Content Verification**: Validates content streaming behavior

### 2. Integration Tests
**Location**: `/test_percolate/integration/services/`

#### `test_model_runner_stream_integration.py`
- **ModelRunner Compatibility**: Tests interface compatibility
- **Agent Loop Logic**: Tests termination and continuation signals
- **Function Execution Flow**: Tests tool call → execution → continuation
- **Multi-Provider Support**: Tests OpenAI and Anthropic integration

## Test Data Samples

### 1. Pre-stored Test Data (`TestData` class)

#### OpenAI Samples
```python
# Simple content stream
OPENAI_TEXT_STREAM = [
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello world!"}}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}',
]

# Function call stream with fragmented arguments
OPENAI_TOOL_CALL_STREAM = [
    'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me search for that."}}]}',
    'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"web_search","arguments":""}}]}}]}',
    'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"query\\": \\"weather San Francisco\\"}"}}]}}]}',
    'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
    'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","usage":{"prompt_tokens":20,"completion_tokens":15,"total_tokens":35}}',
]
```

#### Anthropic Samples
```python
# Text-only response
ANTHROPIC_TEXT_STREAM = [
    'data: {"type":"message_start","message":{"id":"msg_456","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":10,"output_tokens":1}}}',
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The capital of Ireland is Dublin."}}',
    'data: {"type":"content_block_stop","index":0}',
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}',
    'data: {"type":"message_stop"}',
]

# Tool call response with complete arguments
ANTHROPIC_TOOL_CALL_STREAM = [
    'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":50,"output_tokens":1}}}',
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I\'ll help you check the weather. Let me get that for you."}}',
    'data: {"type":"content_block_stop","index":0}',
    'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\": \\"San Francisco\\", \\"unit\\": \\"celsius\\"}"}}',
    'data: {"type":"content_block_stop","index":1}',
    'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":25}}',
    'data: {"type":"message_stop"}',
]
```

### 2. Real API Response Files
**Location**: `/test_percolate/unit/services/llm/proxy/test_data/`

#### `openai_text_stream.txt`
- Real OpenAI GPT-4 text-only response
- Used for format validation and content streaming tests

#### `openai_tool_call_stream.txt`
- Real OpenAI GPT-4 function calling response
- Shows actual argument fragmentation patterns
- Used for tool call buffering validation

#### `claude_text_stream.txt`
- Real Anthropic Claude text-only response
- Used for format conversion testing

#### `claude_tool_call_stream.txt`
- Real Anthropic Claude tool calling response
- Shows actual Anthropic tool call format
- Used for OpenAI conversion validation

## Test Coverage Areas

### 1. Core Functionality ✅

#### Stream Processing
- **Content Streaming**: Immediate content relay without buffering
- **Tool Call Buffering**: Fragment aggregation until complete
- **Usage Aggregation**: Token usage accumulation across chunks
- **Format Conversion**: Anthropic ↔ OpenAI format transformation

#### Function Call Events
- **SSE Format**: Proper `event: function_call` format
- **Individual Events**: Separate event per function call
- **Data Structure**: `{"name": "func_name", "arguments": "..."}`
- **Multiple Functions**: Correct handling of multiple simultaneous calls

### 2. Provider Compatibility ✅

#### OpenAI Support
- **Pass-through**: Direct streaming with tool call buffering
- **Tool Call Handling**: Fragment aggregation for incomplete arguments
- **Usage Processing**: Standard OpenAI usage format
- **Finish Reasons**: Proper `stop` and `tool_calls` handling

#### Anthropic Support  
- **Format Conversion**: Complete Anthropic → OpenAI transformation
- **Stop Reason Mapping**: `end_turn` → `stop`, `tool_use` → `tool_calls`
- **Usage Conversion**: `input_tokens`/`output_tokens` → `prompt_tokens`/`completion_tokens`
- **Tool Call Conversion**: `tool_use` → OpenAI function call format

### 3. ModelRunner Integration ✅

#### Interface Compatibility
- **Function Signature**: Maintains expected `(response, source_scheme, target_scheme)` interface
- **Return Format**: `Generator[Tuple[str, dict], None, None]` as expected
- **Chunk Structure**: Proper OpenAI canonical format for processing

#### Agent Loop Support
- **Termination Signals**: Correct `finish_reason: "stop"` for loop exit
- **Tool Call Detection**: Proper `finish_reason: "tool_calls"` for function execution
- **Content Streaming**: Immediate relay for user feedback
- **Usage Tracking**: Aggregated usage for `AIResponse` generation

### 4. Error Handling ✅

#### Malformed Data
- **JSON Parsing Errors**: Graceful handling of invalid JSON
- **Missing Fields**: Safe handling of incomplete chunks
- **Invalid SSE Format**: Proper line format validation

#### Edge Cases
- **Empty Streams**: Proper handling of no-content responses
- **Partial Tool Calls**: Handling of incomplete function arguments
- **Multiple Models**: Switching between different model responses

## Test Execution Results

### Unit Tests Status
```
✅ test_unified_stream_adapter.py - All tests passing
✅ test_collect_and_function_announcements.py - All tests passing  
✅ test_incremental_adapter.py - All levels passing
✅ test_unified_adapter_with_samples.py - All format tests passing
```

### Integration Tests Status
```
✅ OpenAI Content Streaming - Content streams immediately
✅ OpenAI Function Calling - Tool calls buffered, events emitted
✅ Anthropic Content Streaming - Converts to OpenAI format
✅ Anthropic Function Calling - Full format conversion working
✅ Function Call Events - Proper SSE format validated
✅ ModelRunner Compatibility - Interface maintained
```

## Test Commands

### Running Unit Tests
```bash
# All proxy unit tests
poetry run python -m pytest test_percolate/unit/services/llm/proxy/ -v

# Specific test file
poetry run python -m pytest test_percolate/unit/services/llm/proxy/test_unified_stream_adapter.py -v
```

### Running Integration Tests  
```bash
# ModelRunner integration
poetry run python -m pytest test_percolate/integration/services/test_model_runner_stream_integration.py -v
```

### Manual Test Execution
```bash
# Direct test file execution (avoids dependency issues)
poetry run python test_percolate/unit/services/llm/proxy/test_collect_and_function_announcements.py
```

## Sample Usage Examples

### Basic Streaming
```python
from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter

adapter = UnifiedStreamAdapter("anthropic", "openai")
for sse_line, chunk in adapter.process_stream(response):
    if sse_line.startswith('event: function_call'):
        # Handle function call announcement
        lines = sse_line.split('\n')
        data = json.loads(lines[1][6:])
        print(f"Calling {data['name']}...")
    elif chunk.get("choices"):
        # Handle regular content or tool calls
        pass
```

### Collect Mode
```python
from percolate.services.llm.proxy.unified_stream_adapter import collect_stream_to_response

# Convert stream to complete response
response = collect_stream_to_response(stream_response, "anthropic")
print(response["choices"][0]["message"]["content"])
```

### ModelRunner Integration
```python
from percolate.services.llm.proxy.stream_generators_v2 import stream_with_buffered_functions_v2

# Drop-in replacement for ModelRunner
for line, chunk in stream_with_buffered_functions_v2(response, "anthropic"):
    # Same interface as before, but with function call events
    pass
```

## Coverage Metrics

- **Provider Support**: 2/2 (OpenAI, Anthropic) ✅
- **Stream Types**: 2/2 (Content, Function Calls) ✅  
- **Event Types**: 3/3 (Content, Tool Calls, Function Events) ✅
- **Format Conversions**: 4/4 (OpenAI→OpenAI, Anthropic→OpenAI, bidirectional) ✅
- **Integration Points**: 1/1 (ModelRunner) ✅
- **Error Scenarios**: 5/5 (JSON errors, missing fields, malformed SSE, empty streams, partial data) ✅

## Future Extensibility

The test framework is designed to easily accommodate:
- **Google Gemini Support**: Add new provider test data and conversion tests
- **Additional Event Types**: Extend function call events with new formats
- **Performance Testing**: Add latency and throughput benchmarks
- **Real API Testing**: Integration tests with live API endpoints

## Conclusion

The test coverage provides comprehensive validation of:
1. **Core streaming functionality** with both providers
2. **New function call events** feature
3. **Backward compatibility** with ModelRunner
4. **Error resilience** and edge case handling
5. **Format conversion accuracy** between providers

All tests pass and validate that the unified stream adapter successfully replaces the old streaming functions while adding the new function call event capability.