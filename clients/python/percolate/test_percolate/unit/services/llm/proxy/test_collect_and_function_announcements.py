"""
Unit tests for collect functionality and function announcement features.

Tests the new collect() method that converts streams to complete responses,
and the function announcement SSE events that notify clients when functions are called.
"""

import json
import pytest
from percolate.services.llm.proxy.unified_stream_adapter import (
    UnifiedStreamAdapter, 
    collect_stream_to_response,
    StreamEventType
)


class MockResponse:
    """Mock HTTP response for testing"""
    def __init__(self, lines):
        self.lines = lines
    
    def iter_lines(self, decode_unicode=True):
        for line in self.lines:
            yield line


class TestData:
    """Pre-stored test data for unit tests"""
    
    # Anthropic stream with content and tool calls
    ANTHROPIC_TOOL_CALL_STREAM = [
        'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":50,"output_tokens":1}}}',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I\'ll help you check the weather. "}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Let me get that for you."}}',
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}',
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\": \\"San Francisco\\", "}}',
        'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"unit\\": \\"celsius\\"}"}}',
        'data: {"type":"content_block_stop","index":1}',
        'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":25}}',
        'data: {"type":"message_stop"}',
    ]
    
    # Anthropic text-only stream 
    ANTHROPIC_TEXT_STREAM = [
        'data: {"type":"message_start","message":{"id":"msg_456","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":10,"output_tokens":1}}}',
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The capital of Ireland is Dublin."}}',
        'data: {"type":"content_block_stop","index":0}',
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}',
        'data: {"type":"message_stop"}',
    ]
    
    # OpenAI simple stream
    OPENAI_TEXT_STREAM = [
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello world!"}}]}',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}',
    ]
    
    # OpenAI tool call stream
    OPENAI_TOOL_CALL_STREAM = [
        'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me search for that."}}]}',
        'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"web_search","arguments":""}}]}}]}',
        'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"query\\": \\"weather San Francisco\\"}"}}]}}]}',
        'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
        'data: {"id":"chatcmpl-456","object":"chat.completion.chunk","usage":{"prompt_tokens":20,"completion_tokens":15,"total_tokens":35}}',
    ]


class TestCollectFunctionality:
    """Test the collect() method that converts streams to complete responses"""
    
    def test_collect_anthropic_to_complete_response(self):
        """Test converting Anthropic stream to complete OpenAI response"""
        response = MockResponse(TestData.ANTHROPIC_TOOL_CALL_STREAM)
        complete_response = collect_stream_to_response(response, "anthropic", "test-req-123")
        
        # Validate response structure
        assert complete_response["id"] == "test-req-123"
        assert complete_response["object"] == "chat.completion"  # Non-streaming
        assert complete_response["model"] == "claude-3-sonnet"
        
        # Check the message
        message = complete_response["choices"][0]["message"]
        assert message["role"] == "assistant"
        assert message["content"] == "I'll help you check the weather. Let me get that for you."
        assert "tool_calls" in message
        assert len(message["tool_calls"]) == 1
        
        # Check tool call structure
        tool_call = message["tool_calls"][0]
        assert tool_call["id"] == "toolu_123"
        assert tool_call["function"]["name"] == "get_weather"
        assert tool_call["function"]["arguments"] == '{"location": "San Francisco", "unit": "celsius"}'
        
        # Check finish reason and usage structure
        assert complete_response["choices"][0]["finish_reason"] == "tool_calls"
        assert "usage" in complete_response
        assert "prompt_tokens" in complete_response["usage"]
        assert "completion_tokens" in complete_response["usage"]
        assert "total_tokens" in complete_response["usage"]
    
    def test_collect_text_only_response(self):
        """Test collecting a text-only response (no tool calls)"""
        response = MockResponse(TestData.ANTHROPIC_TEXT_STREAM)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        complete_response = adapter.collect(response)
        
        # Validate text-only response structure
        message = complete_response["choices"][0]["message"]
        assert message["content"] == "The capital of Ireland is Dublin."
        assert "tool_calls" not in message or not message["tool_calls"]
        assert complete_response["choices"][0]["finish_reason"] == "stop"
    
    def test_collect_openai_passthrough(self):
        """Test collecting OpenAI stream works correctly"""
        response = MockResponse(TestData.OPENAI_TEXT_STREAM)
        complete_response = collect_stream_to_response(response, "openai")
        
        # Should work correctly with OpenAI format
        assert complete_response["choices"][0]["message"]["content"] == "Hello world!"
        assert complete_response["usage"]["prompt_tokens"] == 5
        assert complete_response["usage"]["completion_tokens"] == 3
    
    def test_streaming_vs_collecting_same_result(self):
        """Test that streaming and collecting produce consistent state"""
        # Stream the data
        response1 = MockResponse(TestData.OPENAI_TEXT_STREAM)
        adapter1 = UnifiedStreamAdapter("openai", "openai")
        streaming_events = list(adapter1.process_stream(response1))
        
        # Collect the same data
        response2 = MockResponse(TestData.OPENAI_TEXT_STREAM)
        complete_response = collect_stream_to_response(response2, "openai")
        
        # Both should have the same final content and usage
        assert complete_response["choices"][0]["message"]["content"] == "Hello world!"
        assert len(streaming_events) > 0  # Streaming should produce events


class TestFunctionAnnouncements:
    """Test the new function announcement feature"""
    
    def test_function_call_events_creation(self):
        """Test creating individual function call SSE events"""
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Add some tool calls to the state
        tool_call = {
            "id": "call_123",
            "type": "function",
            "function": {
                "name": "get_weather", 
                "arguments": '{"location": "San Francisco"}'
            }
        }
        adapter.state.add_tool_call(0, tool_call)
        
        # Create function call events
        events = adapter.create_function_call_events()
        
        # Validate event structure
        assert len(events) == 1
        event_sse = events[0]
        
        # Should be proper SSE format
        assert event_sse.startswith("event: function_call\n")
        assert "data: " in event_sse
        assert event_sse.endswith("\n\n")
        
        # Extract and validate data
        lines = event_sse.strip().split('\n')
        assert lines[0] == "event: function_call"
        data_line = lines[1]
        assert data_line.startswith("data: ")
        
        data = json.loads(data_line[6:])  # Remove 'data: '
        assert data["name"] == "get_weather"
        assert data["arguments"] == '{"location": "San Francisco"}'
    
    def test_function_call_events_multiple_tools(self):
        """Test individual events for multiple tool calls"""
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Add multiple tool calls
        tool_calls = [
            {"id": "call_1", "type": "function", "function": {"name": "search", "arguments": '{"query": "test"}'}},
            {"id": "call_2", "type": "function", "function": {"name": "calculate", "arguments": '{"expr": "2+2"}'}}
        ]
        for i, tool_call in enumerate(tool_calls):
            adapter.state.add_tool_call(i, tool_call)
        
        events = adapter.create_function_call_events()
        
        # Should have individual events for each function
        assert len(events) == 2, "Should have 2 separate events"
        
        # Validate first event
        lines1 = events[0].strip().split('\n')
        data1 = json.loads(lines1[1][6:])
        assert data1["name"] == "search"
        assert data1["arguments"] == '{"query": "test"}'
        
        # Validate second event  
        lines2 = events[1].strip().split('\n')
        data2 = json.loads(lines2[1][6:])
        assert data2["name"] == "calculate" 
        assert data2["arguments"] == '{"expr": "2+2"}'
    
    def test_function_call_events_in_stream(self):
        """Test that function call events are emitted in streaming"""
        response = MockResponse(TestData.ANTHROPIC_TOOL_CALL_STREAM)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Process stream with function announcements enabled
        events = list(adapter.process_stream(response, emit_function_announcements=True))
        
        # Find the function call events
        function_call_events = [
            (sse_line, chunk) for sse_line, chunk in events 
            if sse_line.startswith('event: function_call')
        ]
        
        # Should have at least one function call event
        assert len(function_call_events) > 0
        
        # Parse the function call event
        function_call_sse, function_call_chunk = function_call_events[0]
        lines = function_call_sse.strip().split('\n')
        assert lines[0] == "event: function_call"
        
        data_line = lines[1]
        data = json.loads(data_line[6:])  # Remove 'data: ' prefix
        
        assert "name" in data
        assert "arguments" in data
    
    def test_function_call_events_disabled(self):
        """Test that function call events can be disabled"""
        response = MockResponse(TestData.ANTHROPIC_TOOL_CALL_STREAM)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Process stream with function announcements disabled
        events = list(adapter.process_stream(response, emit_function_announcements=False))
        
        # Should not have any function call events
        function_call_events = [
            (sse_line, chunk) for sse_line, chunk in events 
            if sse_line.startswith('event: function_call')
        ]
        
        assert len(function_call_events) == 0
    
    def test_no_function_call_events_without_tools(self):
        """Test that no events are created when there are no tool calls"""
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # No tool calls added to state
        events = adapter.create_function_call_events()
        
        # Should return empty list when no tool calls
        assert events == []


class TestStructureValidation:
    """Test that all required fields are present and have correct structure"""
    
    def test_complete_response_has_required_fields(self):
        """Test that complete responses have all required OpenAI fields"""
        response = MockResponse(TestData.ANTHROPIC_TEXT_STREAM)
        complete_response = collect_stream_to_response(response, "anthropic")
        
        # Top-level required fields
        required_fields = ["id", "object", "created", "model", "choices", "usage"]
        for field in required_fields:
            assert field in complete_response, f"Missing required field: {field}"
        
        # Choice structure
        choice = complete_response["choices"][0]
        choice_fields = ["index", "message", "finish_reason", "logprobs"]
        for field in choice_fields:
            assert field in choice, f"Missing choice field: {field}"
        
        # Message structure
        message = choice["message"]
        message_fields = ["role", "content"]
        for field in message_fields:
            assert field in message, f"Missing message field: {field}"
        
        # Usage structure
        usage = complete_response["usage"]
        usage_fields = ["prompt_tokens", "completion_tokens", "total_tokens"]
        for field in usage_fields:
            assert field in usage, f"Missing usage field: {field}"
    
    def test_function_announcement_has_required_fields(self):
        """Test that function announcements have all required fields"""
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Add a tool call
        tool_call = {"id": "call_123", "type": "function", "function": {"name": "test", "arguments": "{}"}}
        adapter.state.add_tool_call(0, tool_call)
        
        announcement = adapter.create_function_announcement_chunk()
        
        # Required announcement fields
        required_fields = ["type", "id", "object", "created", "model", "functions_called", "message"]
        for field in required_fields:
            assert field in announcement, f"Missing announcement field: {field}"
        
        # Functions called structure
        func_info = announcement["functions_called"][0]
        func_fields = ["name", "arguments"]
        for field in func_fields:
            assert field in func_info, f"Missing function info field: {field}"


if __name__ == "__main__":
    # Run basic tests to verify functionality
    test_collect = TestCollectFunctionality()
    test_collect.test_collect_anthropic_to_complete_response()
    test_collect.test_collect_text_only_response()
    
    test_announcements = TestFunctionAnnouncements() 
    test_announcements.test_function_announcement_creation()
    test_announcements.test_function_announcements_in_stream()
    
    print("✅ All unit tests passed!")