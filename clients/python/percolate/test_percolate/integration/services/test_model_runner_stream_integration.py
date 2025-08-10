"""
Integration tests for ModelRunner streaming with the new UnifiedStreamAdapter.

These tests verify that the new stream adapter maintains compatibility with
ModelRunner's critical agent loop logic including:
1. Tool call detection and execution
2. Agent loop termination logic  
3. Content streaming
4. Function announcements (new feature)
"""

import json
from unittest.mock import Mock, patch
from typing import List

import pytest

from percolate.services.llm.proxy.stream_generators_v2 import stream_with_buffered_functions_v2


class MockResponse:
    """Mock HTTP response for testing"""
    def __init__(self, lines: List[str]):
        self.lines = lines
    
    def iter_lines(self, decode_unicode=True):
        for line in self.lines:
            yield line


class TestModelRunnerStreamIntegration:
    """Test integration between new stream adapter and ModelRunner logic"""
    
    def test_openai_tool_call_buffering_and_execution_flow(self):
        """
        Test that OpenAI tool call streams are properly buffered and provide
        complete tool calls for ModelRunner execution logic.
        """
        # Real OpenAI tool call stream (fragmented arguments)
        openai_tool_call_stream = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me check the weather for you."},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"location"}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\":\\"San Francisco\\","}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"unit\\":\\"celsius\\"}"}}]},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","usage":{"prompt_tokens":20,"completion_tokens":15,"total_tokens":35}}',
        ]
        
        response = MockResponse(openai_tool_call_stream)
        
        # Process the stream as ModelRunner would
        events = list(stream_with_buffered_functions_v2(response, "openai", "openai"))
        
        # Extract events by type for analysis
        content_events = []
        function_announcements = []
        tool_call_events = []
        usage_events = []
        
        for sse_line, chunk in events:
            if sse_line.startswith('event: function_call'):
                function_announcements.append((sse_line, chunk))
            elif chunk.get("choices") and chunk["choices"][0].get("finish_reason") == "tool_calls":
                tool_call_events.append((sse_line, chunk))
            elif chunk.get("choices") and "content" in chunk["choices"][0].get("delta", {}):
                content_events.append((sse_line, chunk))
            elif "usage" in chunk:
                usage_events.append((sse_line, chunk))
        
        # CRITICAL TEST 1: Content should stream immediately
        assert len(content_events) > 0, "Content should stream immediately"
        content_chunk = content_events[0][1]
        assert content_chunk["choices"][0]["delta"]["content"] == "Let me check the weather for you."
        
        # CRITICAL TEST 2: Function call events should be emitted (new feature)
        assert len(function_announcements) > 0, "Should emit function call events"
        function_call_sse = function_announcements[0][0]
        assert function_call_sse.startswith("event: function_call"), "Should be proper SSE event"
        
        # Parse the function call event
        lines = function_call_sse.strip().split('\n')
        data_line = lines[1]
        data = json.loads(data_line[6:])  # Remove 'data: '
        assert data["name"] == "get_weather"
        assert "arguments" in data
        
        # CRITICAL TEST 3: Tool calls should be buffered and complete
        assert len(tool_call_events) == 1, "Should have exactly one complete tool call event"
        tool_call_chunk = tool_call_events[0][1]
        
        # Verify structure ModelRunner expects
        assert tool_call_chunk["choices"][0]["finish_reason"] == "tool_calls"
        tool_calls = tool_call_chunk["choices"][0]["delta"]["tool_calls"]
        assert len(tool_calls) == 1
        
        # Verify complete arguments (this is critical for ModelRunner.invoke())
        tool_call = tool_calls[0]
        assert tool_call["id"] == "call_123"
        assert tool_call["function"]["name"] == "get_weather"
        expected_args = '{"location":"San Francisco","unit":"celsius"}'
        assert tool_call["function"]["arguments"] == expected_args
        
        # CRITICAL TEST 4: Usage information should be available
        assert len(usage_events) > 0, "Should have usage information"
        usage_chunk = usage_events[0][1]
        assert usage_chunk["usage"]["prompt_tokens"] == 20
        assert usage_chunk["usage"]["completion_tokens"] == 15
        
        print("✅ OpenAI tool call integration test passed!")
        
    def test_anthropic_to_openai_conversion_and_termination(self):
        """
        Test that Anthropic streams are properly converted to OpenAI format
        and provide correct finish_reason for agent loop termination.
        """
        # Anthropic stream that should terminate the agent loop
        anthropic_text_stream = [
            'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":10,"output_tokens":1}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The capital of Ireland is Dublin."}}',
            'data: {"type":"content_block_stop","index":0}',
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(anthropic_text_stream)
        events = list(stream_with_buffered_functions_v2(response, "anthropic", "openai"))
        
        # Find the stop event that should trigger agent loop termination
        stop_events = [
            (sse_line, chunk) for sse_line, chunk in events
            if chunk.get("choices") and chunk["choices"][0].get("finish_reason") == "stop"
        ]
        
        # CRITICAL TEST: Must have stop finish_reason for agent loop termination
        assert len(stop_events) > 0, "Must have finish_reason='stop' for agent loop termination"
        
        stop_chunk = stop_events[0][1]
        assert stop_chunk["choices"][0]["finish_reason"] == "stop", "Critical: finish_reason must be 'stop'"
        
        # Verify content was streamed
        content_events = [
            (sse_line, chunk) for sse_line, chunk in events
            if chunk.get("choices") and "content" in chunk["choices"][0].get("delta", {})
        ]
        assert len(content_events) > 0, "Content should be streamed"
        
        print("✅ Anthropic conversion and termination test passed!")
        
    def test_anthropic_tool_calls_with_function_announcements(self):
        """
        Test Anthropic tool call stream conversion with function announcements.
        Verify that ModelRunner gets complete tool calls for execution.
        """
        anthropic_tool_stream = [
            'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":50,"output_tokens":1}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I\'ll help you check the weather."}}',
            'data: {"type":"content_block_stop","index":0}',
            'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\": \\"NYC\\", \\"unit\\": \\"fahrenheit\\"}"}}',
            'data: {"type":"content_block_stop","index":1}',
            'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":25}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(anthropic_tool_stream)
        events = list(stream_with_buffered_functions_v2(response, "anthropic", "openai"))
        
        # Extract different event types
        function_announcements = []
        tool_call_events = []
        content_events = []
        
        for sse_line, chunk in events:
            if sse_line.startswith('event: function_call'):
                lines = sse_line.strip().split('\n')
                data_line = lines[1] if len(lines) > 1 else ""
                if data_line.startswith("data: "):
                    function_announcements.append(json.loads(data_line[6:]))
            elif chunk.get("choices") and chunk["choices"][0].get("finish_reason") == "tool_calls":
                tool_call_events.append(chunk)
            elif chunk.get("choices") and "content" in chunk["choices"][0].get("delta", {}):
                content_events.append(chunk)
        
        # CRITICAL TEST 1: Function call events should be emitted
        assert len(function_announcements) > 0, "Should emit function call events"
        announcement = function_announcements[0]
        assert "name" in announcement
        assert "arguments" in announcement
        assert announcement["name"] == "get_weather"
        
        # CRITICAL TEST 2: Tool calls should be complete and in OpenAI format
        assert len(tool_call_events) == 1, "Should have one complete tool call event"
        tool_event = tool_call_events[0]
        assert tool_event["choices"][0]["finish_reason"] == "tool_calls"
        
        tool_calls = tool_event["choices"][0]["delta"]["tool_calls"]
        assert len(tool_calls) == 1
        
        tool_call = tool_calls[0]
        assert tool_call["id"] == "toolu_123"  # Anthropic ID preserved
        assert tool_call["type"] == "function"  # OpenAI format
        assert tool_call["function"]["name"] == "get_weather"
        assert tool_call["function"]["arguments"] == '{"location": "NYC", "unit": "fahrenheit"}'
        
        # CRITICAL TEST 3: Content should stream immediately
        assert len(content_events) > 0, "Content should stream"
        assert content_events[0]["choices"][0]["delta"]["content"] == "I'll help you check the weather."
        
        print("✅ Anthropic tool calls with announcements test passed!")
        
    def test_error_handling_and_malformed_data(self):
        """
        Test that the adapter gracefully handles malformed data without
        breaking ModelRunner's processing logic.
        """
        mixed_stream = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Valid content"},"finish_reason":null}]}',
            'data: {malformed json without closing brace',  # Bad JSON
            'not even a data line',  # Not SSE format
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        ]
        
        response = MockResponse(mixed_stream)
        events = list(stream_with_buffered_functions_v2(response, "openai", "openai"))
        
        # Should still process valid events despite errors
        valid_events = [e for e in events if e[1].get("choices")]
        assert len(valid_events) >= 2, "Should process valid events despite errors"
        
        # Should still have proper termination
        stop_events = [
            e for e in valid_events 
            if e[1]["choices"][0].get("finish_reason") == "stop"
        ]
        assert len(stop_events) > 0, "Should still detect termination despite errors"
        
        print("✅ Error handling test passed!")
        
    def test_backward_compatibility_with_existing_interface(self):
        """
        Test that the new function maintains exact backward compatibility
        with the interface ModelRunner expects.
        """
        simple_stream = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        ]
        
        response = MockResponse(simple_stream)
        
        # Test with same parameters ModelRunner uses
        events = list(stream_with_buffered_functions_v2(
            response, 
            source_scheme="openai",
            target_scheme="openai",
            relay_tool_use_events=False,
            relay_usage_events=False
        ))
        
        # Verify return type is exactly what ModelRunner expects
        for sse_line, chunk in events:
            assert isinstance(sse_line, str), "First element must be string (SSE line)"
            assert isinstance(chunk, dict), "Second element must be dict (canonical chunk)"
            if chunk.get("choices"):
                # This is the format ModelRunner processes
                assert "delta" in chunk["choices"][0], "Must have delta for ModelRunner"
                
        print("✅ Backward compatibility test passed!")


def test_integration_comprehensive():
    """Run all integration tests"""
    test_instance = TestModelRunnerStreamIntegration()
    
    print("🚀 Running ModelRunner Stream Integration Tests...")
    
    test_instance.test_openai_tool_call_buffering_and_execution_flow()
    test_instance.test_anthropic_to_openai_conversion_and_termination() 
    test_instance.test_anthropic_tool_calls_with_function_announcements()
    test_instance.test_error_handling_and_malformed_data()
    test_instance.test_backward_compatibility_with_existing_interface()
    
    print("\n🎉 ALL INTEGRATION TESTS PASSED!")
    print("\nVerified capabilities:")
    print("  ✅ Tool call buffering and complete argument assembly") 
    print("  ✅ Agent loop termination logic (finish_reason mapping)")
    print("  ✅ Content streaming without buffering")
    print("  ✅ Function announcements (new feature)")
    print("  ✅ Anthropic → OpenAI conversion")
    print("  ✅ Error handling and robustness")
    print("  ✅ Backward compatibility with ModelRunner interface")
    print("\n✨ Ready for ModelRunner integration!")


if __name__ == "__main__":
    test_integration_comprehensive()