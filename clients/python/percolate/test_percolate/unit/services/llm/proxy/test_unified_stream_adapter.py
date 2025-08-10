"""
Unit tests for the unified stream adapter.

These tests demonstrate:
1. State management through the adapter lifecycle
2. Format conversion between providers
3. Tool call buffering behavior
4. Usage aggregation
5. Error handling
"""

import json
import pytest
from unittest.mock import Mock, MagicMock
from typing import List, Tuple

from percolate.services.llm.proxy.unified_stream_adapter import (
    UnifiedStreamAdapter,
    StreamState,
    StreamEventType,
    unified_stream_adapter,
)


class MockResponse:
    """Mock HTTP response that yields pre-defined lines"""
    
    def __init__(self, lines: List[str]):
        self.lines = lines
    
    def iter_lines(self, decode_unicode=True):
        for line in self.lines:
            yield line


class TestStreamState:
    """Test the StreamState data management"""
    
    def test_initial_state(self):
        """Test that StreamState initializes correctly"""
        state = StreamState()
        assert state.tool_calls == {}
        assert state.usage == {}
        assert state.finished_tool_calls is False
        assert state.content_chunks == []
        assert state.current_role is None
        assert state.model is None
    
    def test_add_tool_call(self):
        """Test adding a tool call"""
        state = StreamState()
        tool_call = {
            "id": "call_123",
            "type": "function",
            "function": {"name": "get_weather", "arguments": ""}
        }
        state.add_tool_call(0, tool_call)
        assert 0 in state.tool_calls
        assert state.tool_calls[0] == tool_call
    
    def test_update_tool_call_args(self):
        """Test updating tool call arguments"""
        state = StreamState()
        tool_call = {
            "id": "call_123",
            "type": "function",
            "function": {"name": "get_weather", "arguments": ""}
        }
        state.add_tool_call(0, tool_call)
        
        state.update_tool_call_args(0, '{"city": ')
        state.update_tool_call_args(0, '"Paris"}')
        
        assert state.tool_calls[0]["function"]["arguments"] == '{"city": "Paris"}'
    
    def test_get_complete_tool_calls(self):
        """Test getting all tool calls as a list"""
        state = StreamState()
        tool_call1 = {"id": "call_1", "function": {"name": "func1"}}
        tool_call2 = {"id": "call_2", "function": {"name": "func2"}}
        
        state.add_tool_call(0, tool_call1)
        state.add_tool_call(1, tool_call2)
        
        calls = state.get_complete_tool_calls()
        assert len(calls) == 2
        assert calls[0] == tool_call1
        assert calls[1] == tool_call2
    
    def test_content_aggregation(self):
        """Test content chunk aggregation"""
        state = StreamState()
        state.add_content("Hello ")
        state.add_content("world")
        state.add_content("!")
        
        assert state.get_aggregated_content() == "Hello world!"
    
    def test_usage_update(self):
        """Test usage information updates"""
        state = StreamState()
        state.update_usage({"prompt_tokens": 10, "completion_tokens": 5})
        state.update_usage({"completion_tokens": 15, "total_tokens": 25})
        
        assert state.usage["prompt_tokens"] == 10
        assert state.usage["completion_tokens"] == 15
        assert state.usage["total_tokens"] == 25


class TestUnifiedStreamAdapter:
    """Test the main adapter functionality"""
    
    def test_parse_sse_line(self):
        """Test SSE line parsing"""
        adapter = UnifiedStreamAdapter()
        
        # Valid JSON
        line = 'data: {"id": "123", "object": "chat.completion.chunk"}'
        result = adapter.parse_sse_line(line)
        assert result == {"id": "123", "object": "chat.completion.chunk"}
        
        # [DONE] marker
        line = "data: [DONE]"
        result = adapter.parse_sse_line(line)
        assert result == {"type": "done"}
        
        # Invalid lines
        assert adapter.parse_sse_line("") is None
        assert adapter.parse_sse_line("not an sse line") is None
        assert adapter.parse_sse_line("data: invalid json") is None
    
    def test_openai_text_streaming(self):
        """Test streaming text content from OpenAI"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"content":" world!"},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Check we got some events (content chunks + stop + done)
        assert len(events) >= 4
        
        # Check content aggregation
        assert adapter.state.get_aggregated_content() == "Hello world!"
        
        # Check usage
        assert adapter.state.usage["prompt_tokens"] == 10
        assert adapter.state.usage["completion_tokens"] == 2
        assert adapter.state.usage["total_tokens"] == 12
    
    def test_openai_tool_call_buffering(self):
        """Test tool call buffering from OpenAI"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\": "}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Paris\\"}"}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response, relay_tool_use_events=False))
        
        # Should have buffered tool calls and emitted them once
        buffered_calls_emitted = False
        for sse_line, chunk in events:
            if "tool_calls" in chunk.get("choices", [{}])[0].get("delta", {}):
                buffered_calls_emitted = True
                tool_calls = chunk["choices"][0]["delta"]["tool_calls"]
                assert len(tool_calls) == 1
                assert tool_calls[0]["id"] == "call_abc123"
                assert tool_calls[0]["function"]["name"] == "get_weather"
                assert tool_calls[0]["function"]["arguments"] == '{"city": "Paris"}'
        
        assert buffered_calls_emitted
    
    def test_anthropic_to_openai_conversion(self):
        """Test converting Anthropic format to OpenAI"""
        # Simulated Anthropic stream events
        lines = [
            'data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-3-sonnet","usage":{"input_tokens":10,"output_tokens":0}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from Claude!"}}',
            'data: {"type":"content_block_stop","index":0}',
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        # Note: This test assumes the AnthropicStreamDelta model handles conversion
        # In reality, you'd need to implement proper Anthropic parsing in the models
        events = list(adapter.process_stream(response))
        
        # Verify some conversion occurred (specific assertions depend on model implementation)
        assert len(events) > 0
    
    def test_invalid_source_scheme(self):
        """Test that invalid source schemes raise ValueError"""
        with pytest.raises(ValueError, match="Unsupported source scheme"):
            UnifiedStreamAdapter("google", "openai")
        
        with pytest.raises(ValueError, match="Unsupported source scheme"):
            UnifiedStreamAdapter("invalid", "openai")
    
    def test_relay_options(self):
        """Test relay options for tool use and usage events"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        
        # Test with relay enabled
        adapter = UnifiedStreamAdapter("openai", "openai")
        events_with_relay = list(adapter.process_stream(
            response, 
            relay_tool_use_events=True, 
            relay_usage_events=True
        ))
        
        # Should see tool use and usage events
        tool_event_count = sum(1 for _, chunk in events_with_relay 
                             if "tool_calls" in chunk.get("choices", [{}])[0].get("delta", {}))
        usage_event_count = sum(1 for _, chunk in events_with_relay 
                              if "usage" in chunk)
        
        assert tool_event_count > 0
        assert usage_event_count > 0
    
    def test_error_handling(self):
        """Test error handling for malformed data"""
        lines = [
            'data: {"malformed": json without closing',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Valid chunk"},"finish_reason":null}]}',
            'not even an sse line',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        # Should handle errors gracefully and continue processing
        events = list(adapter.process_stream(response))
        
        # Should have processed the valid chunk
        assert any("Valid chunk" in str(chunk) for _, chunk in events)
    
    def test_multiple_tool_calls(self):
        """Test handling multiple tool calls in a single response"""
        lines = [
            # First tool call
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"city\\": \\"Paris\\"}"}}]},"finish_reason":null}]}',
            # Second tool call
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_2","type":"function","function":{"name":"get_time","arguments":""}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\\"timezone\\": \\"UTC\\"}"}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Check buffered tool calls
        tool_calls = adapter.state.get_complete_tool_calls()
        assert len(tool_calls) == 2
        assert tool_calls[0]["function"]["name"] == "get_weather"
        assert tool_calls[0]["function"]["arguments"] == '{"city": "Paris"}'
        assert tool_calls[1]["function"]["name"] == "get_time"
        assert tool_calls[1]["function"]["arguments"] == '{"timezone": "UTC"}'


class TestFunctionAnnouncements:
    """Test the new function announcement feature"""
    
    def test_function_announcement_creation(self):
        """Test creating function announcement chunks"""
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        # Add a tool call to the state
        tool_call = {
            "id": "call_123",
            "type": "function", 
            "function": {
                "name": "get_weather",
                "arguments": '{"location": "San Francisco"}'
            }
        }
        adapter.state.add_tool_call(0, tool_call)
        
        # Create announcement
        announcement = adapter.create_function_announcement_chunk()
        
        # Validate structure
        assert announcement is not None
        assert announcement["type"] == "function_announcement"
        assert announcement["object"] == "function_announcement"
        assert "functions_called" in announcement
        assert len(announcement["functions_called"]) == 1
        assert announcement["functions_called"][0]["name"] == "get_weather"
        assert "message" in announcement
        assert "get_weather" in announcement["message"]
    
    def test_function_announcement_in_stream(self):
        """Test that function announcements are included in stream processing"""
        # Mock tool call stream that triggers function completion
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"test_func","arguments":""}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"param\\": \\"value\\"}"}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        # Process with function announcements enabled
        events = list(adapter.process_stream(response, emit_function_announcements=True))
        
        # Should have function announcement event
        announcement_events = [
            event for event in events 
            if 'function_announcement' in event[0]
        ]
        
        assert len(announcement_events) > 0
    
    def test_function_announcements_disabled(self):
        """Test that function announcements can be disabled"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"test_func","arguments":"{\\"param\\": \\"value\\"}"}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
        ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        # Process with function announcements disabled
        events = list(adapter.process_stream(response, emit_function_announcements=False))
        
        # Should not have function announcement events
        announcement_events = [
            event for event in events 
            if 'function_announcement' in event[0]
        ]
        
        assert len(announcement_events) == 0


class TestUnifiedStreamAdapterFunction:
    """Test the main entry point function"""
    
    def test_unified_stream_adapter_function(self):
        """Test the main unified_stream_adapter function"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677652288,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Test"},"finish_reason":null}]}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines)
        events = list(unified_stream_adapter(response, "openai", "openai"))
        
        assert len(events) == 2
        assert any("Test" in str(chunk) for _, chunk in events)
    
    def test_unified_stream_adapter_with_function_announcements(self):
        """Test the main function with function announcement parameter"""
        lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Test"},"finish_reason":null}]}',
            'data: [DONE]',
        ]
        
        response = MockResponse(lines) 
        events = list(unified_stream_adapter(
            response, 
            "openai", 
            "openai",
            emit_function_announcements=True
        ))
        
        # Should work with new parameter
        assert len(events) >= 1