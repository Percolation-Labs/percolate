"""
Unit tests for streaming delta mapping functionality.

These tests verify that streaming responses from different providers 
(Anthropic, Google, OpenAI) are correctly mapped to the canonical format.
"""

import pytest
import json
import time
from unittest.mock import patch

from percolate.api.routes.chat.models import StreamingCompletionsResponseChunk

# Sample test data for different providers
ANTHROPIC_TEXT_CHUNK = {
    "type": "content_block_delta",
    "delta": {
        "type": "text_delta",
        "text": "Paris is beautiful"
    },
    "usage": {
        "output_tokens": 5
    }
}

ANTHROPIC_TOOL_CHUNK = {
    "type": "content_block_delta",
    "delta": {
        "type": "tool_use",
        "id": "tu_01ABC123",
        "name": "get_weather",
        "partial_json": "{\"location\":\"Paris\"}"
    }
}

GOOGLE_TEXT_CHUNK = {
    "candidates": [
        {
            "content": {
                "parts": [
                    {"text": "Paris is beautiful"}
                ],
                "role": "model"
            },
            "finishReason": None
        }
    ]
}

GOOGLE_TOOL_CHUNK = {
    "candidates": [
        {
            "content": {
                "parts": [
                    {
                        "functionCall": {
                            "name": "get_weather",
                            "args": {
                                "location": "Paris"
                            }
                        }
                    }
                ],
                "role": "model"
            },
            "finishReason": None
        }
    ]
}

OPENAI_TEXT_CHUNK = {
    "id": "chatcmpl-123",
    "object": "chat.completion.chunk",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "index": 0,
            "delta": {
                "content": "Paris is beautiful"
            },
            "finish_reason": None
        }
    ]
}

OPENAI_TOOL_CHUNK = {
    "id": "chatcmpl-123",
    "object": "chat.completion.chunk",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "index": 0,
            "delta": {
                "tool_calls": [
                    {
                        "index": 0,
                        "id": "call_abc123",
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{\"location\":\"Paris\"}"
                        }
                    }
                ]
            },
            "finish_reason": None
        }
    ]
}

# Old format (without delta)
OLD_FORMAT_TEXT_CHUNK = {
    "id": "cmpl-123",
    "object": "text_completion",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "text": "Paris is beautiful",
            "index": 0,
            "finish_reason": None
        }
    ]
}

OLD_FORMAT_TOOL_CHUNK = {
    "id": "cmpl-123",
    "object": "text_completion",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "text": "",
            "index": 0,
            "tool_call": {
                "name": "get_weather",
                "arguments": "{\"location\":\"Paris\"}",
                "id": "call_abc123"
            },
            "finish_reason": None
        }
    ]
}


class TestDeltaMapping:
    """Tests for mapping streaming chunks to canonical format."""
    
    def test_anthropic_text_mapping(self):
        """Test that Anthropic text chunks are correctly mapped to canonical format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            ANTHROPIC_TEXT_CHUNK, 'anthropic', 'claude-3-5-sonnet-20241022'
        )
        
        # Check structure matches expected format
        assert "id" in result
        assert result["object"] == "chat.completion.chunk"
        assert "created" in result
        assert result["model"] == "claude-3-5-sonnet-20241022"
        assert "choices" in result
        assert len(result["choices"]) == 1
        
        # Check choice structure
        choice = result["choices"][0]
        assert choice["index"] == 0
        assert "delta" in choice
        assert choice["delta"]["content"] == "Paris is beautiful"
        assert choice["finish_reason"] is None
    
    def test_anthropic_tool_mapping(self):
        """Test that Anthropic tool call chunks are correctly mapped to canonical format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            ANTHROPIC_TOOL_CHUNK, 'anthropic', 'claude-3-5-sonnet-20241022'
        )
        
        # Check structure
        assert "id" in result
        assert result["object"] == "chat.completion.chunk"
        assert "created" in result
        assert result["model"] == "claude-3-5-sonnet-20241022"
        assert "choices" in result
        assert len(result["choices"]) == 1
        
        # Check choice structure
        choice = result["choices"][0]
        assert choice["index"] == 0
        assert "delta" in choice
        assert "tool_calls" in choice["delta"]
        assert len(choice["delta"]["tool_calls"]) == 1
        
        # Check tool call structure
        tool_call = choice["delta"]["tool_calls"][0]
        assert tool_call["type"] == "function"
        assert tool_call["function"]["name"] == "get_weather"
        assert tool_call["function"]["arguments"] == "{\"location\":\"Paris\"}"
    
    def test_google_text_mapping(self):
        """Test that Google text chunks are correctly mapped to canonical format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            GOOGLE_TEXT_CHUNK, 'google', 'gemini-1.5-flash'
        )
        
        # Check structure matches expected format
        assert "id" in result
        assert result["object"] == "chat.completion.chunk"
        assert "created" in result
        assert result["model"] == "gemini-1.5-flash"
        assert "choices" in result
        assert len(result["choices"]) == 1
        
        # Check choice structure
        choice = result["choices"][0]
        assert choice["index"] == 0
        assert "delta" in choice
        assert choice["delta"]["content"] == "Paris is beautiful"
        assert choice["finish_reason"] is None
    
    def test_google_tool_mapping(self):
        """Test that Google tool call chunks are correctly mapped to canonical format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            GOOGLE_TOOL_CHUNK, 'google', 'gemini-1.5-flash'
        )
        
        # Check structure
        assert "id" in result
        assert result["object"] == "chat.completion.chunk"
        assert "created" in result
        assert result["model"] == "gemini-1.5-flash"
        assert "choices" in result
        assert len(result["choices"]) == 1
        
        # Check choice structure
        choice = result["choices"][0]
        assert choice["index"] == 0
        assert "delta" in choice
        assert "tool_calls" in choice["delta"]
        assert len(choice["delta"]["tool_calls"]) == 1
        
        # Check tool call structure
        tool_call = choice["delta"]["tool_calls"][0]
        assert tool_call["type"] == "function"
        assert tool_call["function"]["name"] == "get_weather"
        assert json.loads(tool_call["function"]["arguments"])["location"] == "Paris"
    
    def test_openai_format_preserved(self):
        """Test that OpenAI delta format is preserved when already correct."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            OPENAI_TEXT_CHUNK, 'openai', 'gpt-4'
        )
        
        # Should not change the format since it's already correct
        assert result["id"] == OPENAI_TEXT_CHUNK["id"]
        assert result["object"] == OPENAI_TEXT_CHUNK["object"]
        assert result["created"] == OPENAI_TEXT_CHUNK["created"]
        assert result["model"] == OPENAI_TEXT_CHUNK["model"]
        
        # Check delta structure is preserved
        assert result["choices"][0]["delta"]["content"] == "Paris is beautiful"
    
    def test_convert_old_format_to_delta(self):
        """Test that old text format (without delta) is converted to delta format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            OLD_FORMAT_TEXT_CHUNK, 'openai', 'gpt-4'
        )
        
        # Check basic structure
        assert result["object"] == "chat.completion.chunk"
        
        # Check delta format is used
        assert "delta" in result["choices"][0]
        assert result["choices"][0]["delta"]["content"] == "Paris is beautiful"
    
    def test_convert_old_tool_format_to_delta(self):
        """Test that old tool format (without delta) is converted to delta format."""
        result = StreamingCompletionsResponseChunk.map_to_canonical_format(
            OLD_FORMAT_TOOL_CHUNK, 'openai', 'gpt-4'
        )
        
        # Check basic structure
        assert result["object"] == "chat.completion.chunk"
        
        # Check delta format is used with tool_calls
        assert "delta" in result["choices"][0]
        assert "tool_calls" in result["choices"][0]["delta"]
        assert result["choices"][0]["delta"]["tool_calls"][0]["function"]["name"] == "get_weather"
        
        
"""tools are provided as deltas one at a time"""       
sample_multi_tool_test_openai = ['{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"role":"assistant","content":null},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_2EbMHoOk78CD53SsRK4ukTR1","type":"function","function":{"name":"p8_Resources_run","arguments":""}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"qu"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"estio"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"n\\": \\"F"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ind "}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"resou"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"rces r"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"elat"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ed to"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" local"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" to "}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"globa"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"l RAG."}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"}"}}]},"logprobs":null,"finish_reason":null}]}', '{"id":"chatcmpl-BLfQNJycBK780TXtjDpz39RocKie5","object":"chat.completion.chunk","created":1744503823,"model":"gpt-4o-2024-08-06","service_tier":"default","system_fingerprint":"fp_b7faba9ef5","usage":null,"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_F7PcjNHYYWB1eKkW9N7fcg1W","type":"function","function":{"name":"p8_ResearchIteration_run","arguments":""}}]},"logprobs":null,"finish_reason":null}]}']

