#!/usr/bin/env python3
"""
Unit tests for Claude/Anthropic streaming response conversion.

Tests the conversion of Claude's Server-Sent Events format to OpenAI-compatible format,
including edge cases that were causing KeyError: 'choices' issues.
"""

import json
import pytest
from unittest.mock import Mock, patch
from percolate.services.llm.proxy.models import AnthropicStreamDelta
from percolate.services.llm.utils.stream_utils import (
    sse_openai_compatible_stream_with_tool_call_collapse,
    _parse_open_ai_response
)


class TestAnthropicStreamConversion:
    """Test Anthropic/Claude stream format conversion to OpenAI format."""
    
    def test_anthropic_content_delta_conversion(self):
        """Test conversion of Claude content delta to OpenAI format."""
        # Claude content delta format
        claude_chunk = {
            "type": "content_block_delta",
            "index": 0,
            "delta": {
                "type": "text_delta",
                "text": "The capital of France is"
            }
        }
        
        anthropic_delta = AnthropicStreamDelta(**claude_chunk)
        openai_format = anthropic_delta.to_openai_format()
        
        # Should have proper OpenAI structure
        assert "choices" in openai_format
        assert len(openai_format["choices"]) == 1
        assert openai_format["choices"][0]["delta"]["content"] == "The capital of France is"
        assert openai_format["choices"][0]["finish_reason"] is None
        assert openai_format["object"] == "chat.completion.chunk"
    
    def test_anthropic_message_start_conversion(self):
        """Test conversion of Claude message_start event."""
        claude_chunk = {
            "type": "message_start",
            "message": {
                "id": "msg_123",
                "type": "message",
                "role": "assistant",
                "model": "claude-3-7-sonnet-20250219",
                "content": [],
                "stop_reason": None,
                "stop_sequence": None,
                "usage": {
                    "input_tokens": 14,
                    "output_tokens": 5
                }
            }
        }
        
        anthropic_delta = AnthropicStreamDelta(**claude_chunk)
        openai_format = anthropic_delta.to_openai_format()
        
        # Should handle message_start gracefully
        assert "choices" in openai_format
        assert openai_format["choices"][0]["delta"] == {}
    
    def test_anthropic_message_delta_finish_reason(self):
        """Test conversion of Claude finish reason."""
        claude_chunk = {
            "type": "message_delta",
            "delta": {
                "stop_reason": "end_turn",
                "stop_sequence": None
            },
            "usage": {
                "output_tokens": 11
            }
        }
        
        anthropic_delta = AnthropicStreamDelta(**claude_chunk)
        openai_format = anthropic_delta.to_openai_format()
        
        assert "choices" in openai_format
        assert openai_format["choices"][0]["finish_reason"] == "end_turn"
    
    def test_anthropic_ping_event(self):
        """Test handling of Claude ping events."""
        claude_chunk = {
            "type": "ping"
        }
        
        anthropic_delta = AnthropicStreamDelta(**claude_chunk)
        openai_format = anthropic_delta.to_openai_format()
        
        # Ping events should still have valid structure
        assert "choices" in openai_format
        assert openai_format["choices"][0]["delta"] == {}
    
    def test_edge_case_empty_chunk(self):
        """Test handling of edge case with minimal chunk data."""
        claude_chunk = {
            "type": "unknown_event"
        }
        
        anthropic_delta = AnthropicStreamDelta(**claude_chunk)
        openai_format = anthropic_delta.to_openai_format()
        
        # Should still produce valid OpenAI structure
        assert "choices" in openai_format
        assert len(openai_format["choices"]) == 1
        assert "delta" in openai_format["choices"][0]


class TestStreamProcessingRobustness:
    """Test stream processing functions handle edge cases safely."""
    
    def test_parse_openai_response_with_missing_choices(self):
        """Test _parse_open_ai_response handles chunks without choices."""
        chunk_without_choices = {
            "id": "test",
            "object": "chat.completion.chunk"
            # No choices field
        }
        
        # Should not crash and should yield nothing
        result = list(_parse_open_ai_response(chunk_without_choices))
        assert result == []
    
    def test_parse_openai_response_with_empty_choices(self):
        """Test _parse_open_ai_response handles empty choices array."""
        chunk_with_empty_choices = {
            "id": "test",
            "object": "chat.completion.chunk",
            "choices": []
        }
        
        result = list(_parse_open_ai_response(chunk_with_empty_choices))
        assert result == []
    
    def test_parse_openai_response_with_no_content(self):
        """Test _parse_open_ai_response handles delta without content."""
        chunk_no_content = {
            "id": "test",
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {},  # No content
                "finish_reason": None
            }]
        }
        
        result = list(_parse_open_ai_response(chunk_no_content))
        assert result == []
    
    def test_parse_openai_response_with_valid_content(self):
        """Test _parse_open_ai_response extracts content correctly."""
        chunk_with_content = {
            "id": "test",
            "object": "chat.completion.chunk",
            "choices": [{
                "index": 0,
                "delta": {"content": "Hello world"},
                "finish_reason": None
            }]
        }
        
        result = list(_parse_open_ai_response(chunk_with_content))
        assert result == ["Hello world"]
    
    def test_sse_stream_processor_handles_missing_choices(self):
        """Test sse_openai_compatible_stream_with_tool_call_collapse handles chunks without choices."""
        # Mock response with chunks that don't have choices
        mock_response = Mock()
        mock_response.iter_lines.return_value = [
            'data: {"id":"init","object":"chat.completion.chunk"}',  # No choices
            'data: {"type":"ping"}',  # Claude ping event, no choices after conversion
            'data: [DONE]'
        ]
        
        # Should not crash and should handle gracefully
        try:
            result = list(sse_openai_compatible_stream_with_tool_call_collapse(mock_response))
            # Test passed if no exception was raised
            assert True
        except Exception as e:
            # Should not crash even with malformed chunks
            pytest.fail(f"Function should handle missing choices gracefully, but raised: {e}")


class TestCompleteClaudeStreamScenario:
    """Test complete Claude streaming scenario with real data."""
    
    def test_realistic_claude_stream_conversion(self):
        """Test conversion of a realistic Claude stream to OpenAI format."""
        # Realistic Claude stream chunks in order
        claude_chunks = [
            # Message start
            {
                "type": "message_start",
                "message": {
                    "id": "msg_123",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-3-7-sonnet-20250219",
                    "content": [],
                    "stop_reason": None,
                    "usage": {"input_tokens": 14, "output_tokens": 0}
                }
            },
            # Content block start
            {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""}
            },
            # Content deltas
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "The capital"}
            },
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": " of France"}
            },
            {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": " is Paris."}
            },
            # Content block stop
            {
                "type": "content_block_stop",
                "index": 0
            },
            # Message delta with finish reason
            {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                "usage": {"output_tokens": 11}
            },
            # Message stop
            {
                "type": "message_stop"
            }
        ]
        
        converted_content = []
        
        for chunk in claude_chunks:
            anthropic_delta = AnthropicStreamDelta(**chunk)
            openai_format = anthropic_delta.to_openai_format()
            
            # Ensure all chunks have valid structure
            assert "choices" in openai_format
            assert len(openai_format["choices"]) == 1
            
            # Extract content if present
            content = openai_format["choices"][0]["delta"].get("content", "")
            if content:
                converted_content.append(content)
        
        # Should reconstruct the full message
        full_message = "".join(converted_content)
        assert full_message == "The capital of France is Paris."


if __name__ == "__main__":
    pytest.main([__file__, "-v"])