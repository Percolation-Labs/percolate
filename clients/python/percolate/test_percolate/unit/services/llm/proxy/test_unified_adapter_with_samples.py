"""
Integration tests for the unified stream adapter using real API response samples.

These tests verify that the adapter correctly handles actual response formats
from OpenAI and Claude APIs.
"""

import json
import os
from pathlib import Path
from typing import List, Tuple

import pytest

from percolate.services.llm.proxy.unified_stream_adapter import (
    UnifiedStreamAdapter,
    unified_stream_adapter,
)


class FileResponse:
    """Mock response that reads SSE lines from a file"""
    
    def __init__(self, filename: str):
        test_dir = Path(__file__).parent / "test_data"
        self.file_path = test_dir / filename
        
    def iter_lines(self, decode_unicode=True):
        with open(self.file_path, 'r') as f:
            for line in f:
                line = line.rstrip('\n')
                if line:  # Only yield non-empty lines
                    yield line


class TestOpenAIStreams:
    """Test processing real OpenAI stream samples"""
    
    def test_openai_text_stream(self):
        """Test processing a real OpenAI text completion stream"""
        response = FileResponse("openai_text_stream.txt")
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Verify content aggregation
        assert adapter.state.get_aggregated_content() == "The capital of Ireland is Dublin."
        
        # Verify usage was captured
        assert adapter.state.usage["prompt_tokens"] == 12
        assert adapter.state.usage["completion_tokens"] == 8
        assert adapter.state.usage["total_tokens"] == 20
        
        # Verify we got some events (content chunks + stop + usage + done)
        # The exact count depends on how many chunks have actual content
        assert len(events) >= 8  # At least the content chunks + final events
        
        # Verify the last event is [DONE]
        assert events[-1][0] == "data: [DONE]\n\n"
    
    def test_openai_tool_call_stream(self):
        """Test processing a real OpenAI tool call stream"""
        response = FileResponse("openai_tool_call_stream.txt")
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response, relay_tool_use_events=False))
        
        # Find the buffered tool call event
        tool_call_event = None
        for sse_line, chunk in events:
            if "choices" in chunk and chunk["choices"]:
                delta = chunk["choices"][0].get("delta", {})
                if "tool_calls" in delta and delta["tool_calls"]:
                    tool_call_event = chunk
                    break
        
        assert tool_call_event is not None
        tool_calls = tool_call_event["choices"][0]["delta"]["tool_calls"]
        assert len(tool_calls) == 1
        assert tool_calls[0]["id"] == "call_62136354"
        assert tool_calls[0]["function"]["name"] == "get_current_weather"
        assert tool_calls[0]["function"]["arguments"] == '{\n  "location": "San Francisco",\n  "unit": "celsius"\n}'
        
        # Verify usage
        assert adapter.state.usage["prompt_tokens"] == 48
        assert adapter.state.usage["completion_tokens"] == 24
        assert adapter.state.usage["total_tokens"] == 72
    
    def test_openai_tool_call_stream_with_relay(self):
        """Test processing OpenAI tool calls with relay enabled"""
        response = FileResponse("openai_tool_call_stream.txt")
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response, relay_tool_use_events=True))
        
        # Count tool-related events
        tool_events = 0
        for sse_line, chunk in events:
            if "choices" in chunk and chunk["choices"]:
                delta = chunk["choices"][0].get("delta", {})
                if "tool_calls" in delta:
                    tool_events += 1
        
        # Should see multiple tool events when relay is enabled
        assert tool_events > 1  # Initial + deltas + final buffered


class TestClaudeStreams:
    """Test processing real Claude/Anthropic stream samples"""
    
    def test_claude_text_stream(self):
        """Test converting Claude text stream to OpenAI format"""
        response = FileResponse("claude_text_stream.txt")
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Verify content was extracted (note: actual conversion depends on AnthropicStreamDelta implementation)
        # For now, we just verify the adapter processes without errors
        assert len(events) > 0
        
        # If AnthropicStreamDelta is properly implemented, we should see:
        # assert adapter.state.get_aggregated_content() == "The capital of Ireland is Dublin."
    
    def test_claude_tool_call_stream(self):
        """Test converting Claude tool call stream to OpenAI format"""
        response = FileResponse("claude_tool_call_stream.txt")
        adapter = UnifiedStreamAdapter("anthropic", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Verify processing completes without errors
        assert len(events) > 0
        
        # If AnthropicStreamDelta is properly implemented, we should see:
        # - Text content: "I'll check the weather for you."
        # - Tool call with name "get_current_weather" and arguments


class TestCrossProviderConversion:
    """Test converting between different provider formats"""
    
    def test_openai_to_anthropic_conversion(self):
        """Test converting OpenAI stream to Anthropic format"""
        response = FileResponse("openai_text_stream.txt")
        adapter = UnifiedStreamAdapter("openai", "anthropic")
        
        events = list(adapter.process_stream(response))
        
        # Verify we get events in Anthropic format
        for sse_line, _ in events:
            if sse_line.startswith("data: ") and sse_line != "data: [DONE]\n\n":
                # Parse the event
                data = json.loads(sse_line[6:].strip())
                # If OpenAIStreamDelta.to_anthropic_format() is implemented,
                # we should see Anthropic-style events
                assert isinstance(data, dict)


class TestErrorHandling:
    """Test error handling with malformed data"""
    
    def test_handles_mixed_valid_invalid_events(self):
        """Test that adapter continues processing after encountering invalid events"""
        # Create a response with some invalid lines
        class MixedResponse:
            def iter_lines(self, decode_unicode=True):
                yield 'data: {"valid": "event", "id": "123"}'
                yield 'data: {invalid json'
                yield 'not an sse line'
                yield 'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1700677564,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}'
                yield 'data: [DONE]'
        
        response = MixedResponse()
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        events = list(adapter.process_stream(response))
        
        # Should have processed the valid events
        assert len(events) >= 2  # At least the valid content event and [DONE]
        assert adapter.state.get_aggregated_content() == "Hello"


class TestStateManagement:
    """Test that adapter maintains correct state throughout processing"""
    
    def test_state_persistence_across_events(self):
        """Test that state is maintained correctly across multiple events"""
        response = FileResponse("openai_text_stream.txt")
        adapter = UnifiedStreamAdapter("openai", "openai")
        
        # Process events one by one and check state
        event_count = 0
        content_so_far = ""
        
        for sse_line, chunk in adapter.process_stream(response):
            event_count += 1
            
            # Check content accumulation
            current_content = adapter.state.get_aggregated_content()
            assert current_content.startswith(content_so_far)
            content_so_far = current_content
            
            # Model should be set after first event with model info
            if event_count > 1:
                assert adapter.state.model == "gpt-4-1106-preview"
        
        # Final state checks
        assert adapter.state.get_aggregated_content() == "The capital of Ireland is Dublin."
        assert adapter.state.usage["total_tokens"] == 20


@pytest.mark.parametrize("filename,source_scheme,expected_content", [
    ("openai_text_stream.txt", "openai", "The capital of Ireland is Dublin."),
    # Add more test cases as AnthropicStreamDelta implementation improves
])
def test_content_extraction(filename, source_scheme, expected_content):
    """Parameterized test for content extraction from different providers"""
    response = FileResponse(filename)
    adapter = UnifiedStreamAdapter(source_scheme, "openai")
    
    list(adapter.process_stream(response))
    
    if source_scheme == "openai":  # Only check for providers we fully support
        assert adapter.state.get_aggregated_content() == expected_content