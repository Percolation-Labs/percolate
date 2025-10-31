"""
Incremental tests for the unified stream adapter.

Tests are organized in order of increasing complexity:
1. Basic content streaming (Anthropic → OpenAI)
2. Usage aggregation
3. Tool call buffering
4. Optional event relaying
5. OpenAI pass-through validation

Each test builds on the previous functionality.
"""

import json
import os
from pathlib import Path
from typing import List, Tuple, Dict, Any

import pytest

from percolate.services.llm.proxy.unified_stream_adapter import (
    UnifiedStreamAdapter,
    StreamState,
    StreamEventType,
)


class MockResponse:
    """Mock response that yields predefined SSE lines"""
    
    def __init__(self, lines: List[str]):
        self.lines = lines
    
    def iter_lines(self, decode_unicode=True):
        for line in self.lines:
            yield line


class TestLevel1ContentStreaming:
    """Level 1: Test basic content streaming from Anthropic to OpenAI format"""
    
    def test_anthropic_simple_text_conversion(self):
        """Test that Anthropic text deltas are converted to OpenAI format"""
        # Simple Anthropic text stream (no tools, no complex usage)
        anthropic_lines = [
            'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":10,"output_tokens":0}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}',
            'data: {"type":"content_block_stop","index":0}',
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(anthropic_lines)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Test 1.1: Content is non-empty and aggregated
        content = adapter.state.get_aggregated_content()
        assert content, "Content should be non-empty"
        assert "Hello" in content and "world" in content, "Should contain expected text"
        
        # Test 1.2: Model information is captured
        assert adapter.state.model, "Model should be set"
        
        # Test 1.3: Events are generated and in OpenAI format
        content_events = [event for event in events if self._has_content(event)]
        assert content_events, "Should generate content events"
        
        # Test 1.4: Each content event has required structure
        for sse_line, chunk in content_events:
            self._validate_openai_sse_structure(sse_line, chunk)
            self._validate_content_event_structure(chunk)
    
    def test_openai_passthrough_content(self):
        """Test that OpenAI content passes through correctly"""
        openai_lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        ]
        
        response = MockResponse(openai_lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Content should be aggregated properly
        content = adapter.state.get_aggregated_content()
        assert content, "Content should be non-empty"
        assert "Hello" in content and "world" in content, "Should contain expected text"
        
        # Should generate content events
        content_events = [event for event in events if self._has_content(event)]
        assert content_events, "Should generate content events"
    
    def _has_content(self, event: Tuple[str, Dict[str, Any]]) -> bool:
        """Helper to check if an event contains content"""
        sse_line, chunk = event
        if "choices" in chunk and chunk["choices"]:
            delta = chunk["choices"][0].get("delta", {})
            return "content" in delta and delta["content"]
        return False
    
    def _validate_openai_sse_structure(self, sse_line: str, chunk: Dict[str, Any]):
        """Validate that SSE line and chunk have proper OpenAI structure"""
        assert sse_line.startswith("data: "), "SSE line should start with 'data: '"
        
        # Parse the JSON in the SSE line
        parsed = json.loads(sse_line[6:])
        assert "choices" in parsed, "OpenAI format should have 'choices'"
        assert isinstance(parsed["choices"], list), "choices should be a list"
        
        # Chunk should match parsed data
        assert chunk == parsed, "Chunk should match parsed SSE data"
    
    def _validate_content_event_structure(self, chunk: Dict[str, Any]):
        """Validate that a content event has required OpenAI structure"""
        assert "choices" in chunk, "Should have choices"
        assert len(chunk["choices"]) > 0, "Should have at least one choice"
        
        choice = chunk["choices"][0]
        assert "delta" in choice, "Choice should have delta"
        assert "content" in choice["delta"], "Delta should have content"
        assert isinstance(choice["delta"]["content"], str), "Content should be string"


class TestLevel2UsageAggregation:
    """Level 2: Test usage information aggregation"""
    
    def test_anthropic_usage_aggregation(self):
        """Test that Anthropic usage is properly aggregated and converted"""
        anthropic_lines = [
            # Initial usage from message_start
            'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":25,"output_tokens":1}}}',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Short answer"}}',
            'data: {"type":"content_block_stop","index":0}',
            # Final usage from message_delta
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(anthropic_lines)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Test 2.1: Usage contains required fields and non-zero values
        usage = adapter.state.usage
        assert usage, "Usage should be captured"
        assert "prompt_tokens" in usage, "Should have prompt_tokens"
        assert "completion_tokens" in usage, "Should have completion_tokens"
        assert "total_tokens" in usage, "Should have total_tokens"
        
        # Values should be non-zero for a real response
        assert usage["prompt_tokens"] > 0, "Prompt tokens should be positive"
        assert usage["completion_tokens"] > 0, "Completion tokens should be positive"
        assert usage["total_tokens"] > 0, "Total tokens should be positive"
        
        # Total should be reasonable (sum of or greater than components)
        assert usage["total_tokens"] >= usage["prompt_tokens"], "Total should include prompt tokens"
        assert usage["total_tokens"] >= usage["completion_tokens"], "Total should include completion tokens"
    
    def test_openai_usage_passthrough(self):
        """Test that OpenAI usage passes through correctly"""
        openai_lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":25,"completion_tokens":5,"total_tokens":30}}',
        ]
        
        response = MockResponse(openai_lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Should capture usage with required structure
        usage = adapter.state.usage
        assert usage, "Usage should be captured"
        self._validate_usage_structure(usage)
    
    def _validate_usage_structure(self, usage: Dict[str, int]):
        """Validate that usage has the required OpenAI structure"""
        required_fields = ["prompt_tokens", "completion_tokens", "total_tokens"]
        for field in required_fields:
            assert field in usage, f"Usage should have {field}"
            assert isinstance(usage[field], int), f"{field} should be an integer"
            assert usage[field] >= 0, f"{field} should be non-negative"


class TestLevel3ToolCallBuffering:
    """Level 3: Test tool call buffering (most complex functionality)"""
    
    def test_anthropic_tool_call_buffering(self):
        """Test that Anthropic tool calls are properly buffered"""
        anthropic_lines = [
            'data: {"type":"message_start","message":{"id":"msg_123","role":"assistant","model":"claude-3-sonnet","usage":{"input_tokens":50,"output_tokens":1}}}',
            # Text content first
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I\'ll get the weather for you."}}',
            'data: {"type":"content_block_stop","index":0}',
            # Tool call
            'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"location\\":"}}',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \\"San Francisco\\","}}',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":" \\"unit\\": \\"celsius\\"}"}}',
            'data: {"type":"content_block_stop","index":1}',
            'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}',
            'data: {"type":"message_stop"}',
        ]
        
        response = MockResponse(anthropic_lines)
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        events = list(adapter.process_stream(response, relay_tool_use_events=False))
        
        # Test 3.1: Text content is preserved alongside tool calls
        content = adapter.state.get_aggregated_content()
        assert content, "Should have text content"
        assert "weather" in content.lower(), "Should mention weather"
        
        # Test 3.2: Tool calls are buffered and emitted as complete units
        tool_call_events = [event for event in events if self._has_complete_tool_calls(event[1])]
        assert tool_call_events, "Should emit buffered tool calls"
        
        # Test 3.3: Tool call structure is valid
        for sse_line, chunk in tool_call_events:
            self._validate_tool_call_structure(chunk)
        
        # Test 3.4: Usage is captured for tool call scenarios
        usage = adapter.state.usage
        assert usage, "Should have usage data"
        assert usage.get("prompt_tokens", 0) > 0, "Should have prompt tokens"
        assert usage.get("completion_tokens", 0) > 0, "Should have completion tokens"
    
    def test_openai_tool_call_buffering(self):
        """Test that OpenAI tool calls are properly buffered"""
        openai_lines = [
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_123","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"location\\": "}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"San Francisco\\", \\"unit\\": \\"celsius\\"}"}}]}}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
            'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":20,"total_tokens":70}}',
        ]
        
        response = MockResponse(openai_lines)
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response, relay_tool_use_events=False))
        
        # Should buffer and emit complete tool calls
        tool_call_events = [event for event in events if self._has_complete_tool_calls(event[1])]
        assert tool_call_events, "Should emit buffered tool calls"
        
        # Validate structure of tool calls
        for sse_line, chunk in tool_call_events:
            self._validate_tool_call_structure(chunk)
        
        # Should aggregate arguments properly
        tool_calls = adapter.state.get_complete_tool_calls()
        assert tool_calls, "Should have buffered tool calls"
        for tool_call in tool_calls:
            assert tool_call.get("function", {}).get("arguments"), "Should have complete arguments"
            # Arguments should be valid JSON string (not empty)
            args = tool_call["function"]["arguments"]
            assert len(args) > 0, "Arguments should not be empty"
            assert "{" in args and "}" in args, "Arguments should look like JSON"
    
    def _has_complete_tool_calls(self, chunk: Dict[str, Any]) -> bool:
        """Helper to check if chunk has complete tool calls"""
        if "choices" in chunk and chunk["choices"]:
            delta = chunk["choices"][0].get("delta", {})
            if "tool_calls" in delta:
                tool_calls = delta["tool_calls"]
                # Check if we have tool calls with IDs (indicating they're complete/buffered)
                return any("id" in tc for tc in tool_calls)
        return False
    
    def _validate_tool_call_structure(self, chunk: Dict[str, Any]):
        """Validate that a tool call event has proper OpenAI structure"""
        assert "choices" in chunk, "Should have choices"
        assert len(chunk["choices"]) > 0, "Should have at least one choice"
        
        choice = chunk["choices"][0]
        assert "delta" in choice, "Choice should have delta"
        assert "tool_calls" in choice["delta"], "Delta should have tool_calls"
        
        tool_calls = choice["delta"]["tool_calls"]
        assert isinstance(tool_calls, list), "Tool calls should be a list"
        assert len(tool_calls) > 0, "Should have at least one tool call"
        
        for tool_call in tool_calls:
            assert "id" in tool_call, "Tool call should have ID"
            assert "type" in tool_call, "Tool call should have type"
            assert tool_call["type"] == "function", "Type should be 'function'"
            assert "function" in tool_call, "Tool call should have function"
            
            function = tool_call["function"]
            assert "name" in function, "Function should have name"
            assert "arguments" in function, "Function should have arguments"
            assert isinstance(function["name"], str), "Function name should be string"
            assert isinstance(function["arguments"], str), "Arguments should be string"


class TestLevel4EventRelaying:
    """Level 4: Test optional event relaying"""
    
    def test_tool_event_relay_behavior(self):
        """Test that relay options control event emission"""
        tool_lines = [
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"get_weather","input":{}}}',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\": \\"Paris\\"}"}}',
            'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}',
        ]
        
        # Test with relay enabled vs disabled
        response1 = MockResponse(tool_lines)
        adapter1 = UnifiedStreamAdapter("anthropic", "openai")
        events_with_relay = list(adapter1.process_stream(response1, relay_tool_use_events=True))
        
        response2 = MockResponse(tool_lines)
        adapter2 = UnifiedStreamAdapter("anthropic", "openai")
        events_without_relay = list(adapter2.process_stream(response2, relay_tool_use_events=False))
        
        # Both should complete successfully
        assert events_with_relay, "Should generate events with relay"
        assert events_without_relay, "Should generate events without relay"
        
        # The key difference is behavioral - both should work
        assert len(events_with_relay) >= len(events_without_relay), "Relay may produce more events"


class TestLevel5CrossValidation:
    """Level 5: Cross-validate that both providers produce equivalent structural results"""
    
    @pytest.mark.parametrize("source_scheme", ["anthropic", "openai"])
    def test_equivalent_content_structure(self, source_scheme):
        """Test that both providers produce structurally equivalent content"""
        if source_scheme == "anthropic":
            lines = [
                'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
                'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}',
                'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}',
            ]
        else:  # openai
            lines = [
                'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"}}]}',
                'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":" world"}}]}',
                'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
            ]
        
        response = MockResponse(lines)
        adapter = UnifiedStreamAdapter(source_scheme, "openai")
        
        events = list(adapter.process_stream(response))
        
        # Both should produce aggregated content
        content = adapter.state.get_aggregated_content()
        assert content, "Should have content"
        assert "Hello" in content and "world" in content, "Should contain expected text"
        
        # Both should produce OpenAI-formatted events
        content_events = [e for e in events if self._has_content_in_event(e)]
        assert content_events, "Should have content events"
        
        # Verify structure consistency
        for sse_line, chunk in content_events:
            self._validate_openai_format_structure(sse_line, chunk)
    
    def _has_content_in_event(self, event: Tuple[str, Dict[str, Any]]) -> bool:
        """Helper to check if event has content"""
        sse_line, chunk = event
        if "choices" in chunk and chunk["choices"]:
            delta = chunk["choices"][0].get("delta", {})
            return "content" in delta and delta["content"]
        return False
    
    def _validate_openai_format_structure(self, sse_line: str, chunk: Dict[str, Any]):
        """Validate that the event conforms to OpenAI format structure"""
        assert sse_line.startswith("data: "), "Should be valid SSE format"
        
        parsed = json.loads(sse_line[6:])
        assert "choices" in parsed, "Should have choices array"
        assert len(parsed["choices"]) > 0, "Should have at least one choice"
        
        choice = parsed["choices"][0]
        assert "delta" in choice, "Choice should have delta"
        
        # Chunk should match parsed structure
        assert chunk == parsed, "Chunk should match parsed SSE data"


if __name__ == "__main__":
    pytest.main([__file__])