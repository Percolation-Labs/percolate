"""
Unit tests for the proxy module data models.

Tests that verify:
1. API request models (OpenAI, Anthropic, Google) can be converted between formats
2. Stream delta models can be converted between formats
3. Format adaptations preserve essential information
"""

import pytest
import json
from datetime import datetime
from unittest.mock import MagicMock

from percolate.services.llm.proxy.models import (
    LLMApiRequest,
    OpenAIRequest,
    AnthropicRequest,
    GoogleRequest,
    StreamDelta,
    OpenAIStreamDelta,
    AnthropicStreamDelta,
    GoogleStreamDelta
)


# Sample test data
OPENAI_BASIC_REQUEST = {
    "model": "gpt-4",
    "messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Hello, how are you?"}
    ],
    "max_tokens": 100,
    "temperature": 0.7,
    "stream": True
}

OPENAI_TOOL_REQUEST = {
    "model": "gpt-4",
    "messages": [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What's the weather in Paris?"}
    ],
    "tools": [
        {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get the current weather in a location",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "location": {
                            "type": "string",
                            "description": "The city and state, e.g. San Francisco, CA"
                        }
                    },
                    "required": ["location"]
                }
            }
        }
    ],
    "max_tokens": 100,
    "temperature": 0.7,
    "stream": True
}

ANTHROPIC_BASIC_REQUEST = {
    "model": "claude-3-5-sonnet-20241022",
    "messages": [
        {"role": "user", "content": "Hello, how are you?"}
    ],
    "system": "You are a helpful assistant.",
    "max_tokens": 100,
    "temperature": 0.7,
    "stream": True
}

ANTHROPIC_TOOL_REQUEST = {
    "model": "claude-3-5-sonnet-20241022",
    "messages": [
        {"role": "user", "content": "What's the weather in Paris?"}
    ],
    "system": "You are a helpful assistant.",
    "tools": [
        {
            "name": "get_weather",
            "description": "Get the current weather in a location",
            "input_schema": {
                "type": "object",
                "properties": {
                    "location": {
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA"
                    }
                },
                "required": ["location"]
            }
        }
    ],
    "max_tokens": 100,
    "temperature": 0.7,
    "stream": True
}

GOOGLE_BASIC_REQUEST = {
    "contents": [
        {"role": "user", "parts": [{"text": "Hello, how are you?"}]}
    ],
    "systemInstruction": {
        "parts": [{"text": "You are a helpful assistant."}]
    },
    "generationConfig": {
        "temperature": 0.7,
        "maxOutputTokens": 100
    },
    "model": "gemini-1.5-flash"
}

GOOGLE_TOOL_REQUEST = {
    "contents": [
        {"role": "user", "parts": [{"text": "What's the weather in Paris?"}]}
    ],
    "systemInstruction": {
        "parts": [{"text": "You are a helpful assistant."}]
    },
    "tools": [
        {
            "functionDeclarations": [
                {
                    "name": "get_weather",
                    "description": "Get the current weather in a location",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "location": {
                                "type": "string",
                                "description": "The city and state, e.g. San Francisco, CA"
                            }
                        },
                        "required": ["location"]
                    }
                }
            ]
        }
    ],
    "generationConfig": {
        "temperature": 0.7,
        "maxOutputTokens": 100
    },
    "model": "gemini-1.5-flash"
}

# Sample stream data
OPENAI_TEXT_DELTA = {
    "id": "chatcmpl-123",
    "object": "chat.completion.chunk",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "index": 0,
            "delta": {
                "content": " Hello"
            },
            "finish_reason": None
        }
    ]
}

OPENAI_TOOL_DELTA = {
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
                            "arguments": "{\"loc"
                        }
                    }
                ]
            },
            "finish_reason": None
        }
    ]
}

ANTHROPIC_TEXT_DELTA = {
    "type": "content_block_delta",
    "index": 0,
    "delta": {
        "type": "text_delta",
        "text": " Hello"
    }
}

ANTHROPIC_TOOL_DELTA = {
    "type": "content_block_start",
    "index": 0,
    "content_block": {
        "type": "tool_use",
        "id": "toolu_abc123",
        "name": "get_weather",
        "input": {}
    }
}

GOOGLE_TEXT_DELTA = {
    "candidates": [
        {
            "content": {
                "parts": [
                    {"text": " Hello"}
                ],
                "role": "model"
            },
            "finishReason": None
        }
    ]
}

GOOGLE_TOOL_DELTA = {
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


class TestRequestModels:
    """Tests for API request models."""
    
    def test_openai_request_basic(self):
        """Test OpenAI request model with basic message."""
        request = OpenAIRequest(**OPENAI_BASIC_REQUEST)
        assert request.model == "gpt-4"
        assert len(request.messages) == 2
        assert request.messages[0]["role"] == "system"
        assert request.max_tokens == 100
        assert request.temperature == 0.7
        assert request.stream == True
    
    def test_openai_request_with_tools(self):
        """Test OpenAI request model with tools."""
        request = OpenAIRequest(**OPENAI_TOOL_REQUEST)
        assert request.model == "gpt-4"
        assert len(request.tools) == 1
        assert request.tools[0]["type"] == "function"
        assert request.tools[0]["function"]["name"] == "get_weather"
    
    def test_anthropic_request_basic(self):
        """Test Anthropic request model with basic message."""
        request = AnthropicRequest(**ANTHROPIC_BASIC_REQUEST)
        assert request.model == "claude-3-5-sonnet-20241022"
        assert len(request.messages) == 1
        assert request.messages[0]["role"] == "user"
        assert request.system == "You are a helpful assistant."
    
    def test_anthropic_request_with_tools(self):
        """Test Anthropic request model with tools."""
        request = AnthropicRequest(**ANTHROPIC_TOOL_REQUEST)
        assert request.model == "claude-3-5-sonnet-20241022"
        assert len(request.tools) == 1
        assert request.tools[0]["name"] == "get_weather"
        assert "input_schema" in request.tools[0]
    
    def test_google_request_basic(self):
        """Test Google request model with basic message."""
        request = GoogleRequest(**GOOGLE_BASIC_REQUEST)
        assert request.model == "gemini-1.5-flash"
        assert len(request.contents) == 1
        assert request.contents[0]["role"] == "user"
        assert request.systemInstruction["parts"][0]["text"] == "You are a helpful assistant."
    
    def test_google_request_with_tools(self):
        """Test Google request model with tools."""
        request = GoogleRequest(**GOOGLE_TOOL_REQUEST)
        assert request.model == "gemini-1.5-flash"
        assert len(request.tools) == 1
        assert "functionDeclarations" in request.tools[0]
        assert request.tools[0]["functionDeclarations"][0]["name"] == "get_weather"
    
    def test_openai_to_anthropic_conversion(self):
        """Test converting OpenAI request to Anthropic format."""
        request = OpenAIRequest(**OPENAI_BASIC_REQUEST)
        anthropic_format = request.to_anthropic_format()
        
        assert anthropic_format["model"] == "gpt-4"
        assert len(anthropic_format["messages"]) == 1  # System message is handled separately
        assert anthropic_format["messages"][0]["role"] == "user"
        assert anthropic_format["system"] == "You are a helpful assistant."
    
    def test_openai_to_google_conversion(self):
        """Test converting OpenAI request to Google format."""
        request = OpenAIRequest(**OPENAI_BASIC_REQUEST)
        google_format = request.to_google_format()
        
        assert "contents" in google_format
        assert len(google_format["contents"]) == 1  # System message is in systemInstruction
        assert google_format["contents"][0]["role"] == "user"
        assert "systemInstruction" in google_format
    
    def test_anthropic_to_openai_conversion(self):
        """Test converting Anthropic request to OpenAI format."""
        request = AnthropicRequest(**ANTHROPIC_BASIC_REQUEST)
        openai_format = request.to_openai_format()
        
        assert openai_format["model"] == "claude-3-5-sonnet-20241022"
        assert len(openai_format["messages"]) == 2  # System + user
        assert openai_format["messages"][0]["role"] == "system"
        assert openai_format["messages"][1]["role"] == "user"
    
    def test_google_to_openai_conversion(self):
        """Test converting Google request to OpenAI format."""
        request = GoogleRequest(**GOOGLE_BASIC_REQUEST)
        openai_format = request.to_openai_format()
        
        assert openai_format["model"] == "gemini-1.5-flash"
        assert len(openai_format["messages"]) == 2  # System + user
        assert openai_format["messages"][0]["role"] == "system"
        assert openai_format["messages"][1]["role"] == "user"
    
    def test_tool_conversion_openai_to_anthropic(self):
        """Test converting OpenAI tools to Anthropic format."""
        request = OpenAIRequest(**OPENAI_TOOL_REQUEST)
        anthropic_format = request.to_anthropic_format()
        
        assert "tools" in anthropic_format
        assert len(anthropic_format["tools"]) == 1
        assert anthropic_format["tools"][0]["name"] == "get_weather"
        assert "input_schema" in anthropic_format["tools"][0]
    
    def test_tool_conversion_openai_to_google(self):
        """Test converting OpenAI tools to Google format."""
        request = OpenAIRequest(**OPENAI_TOOL_REQUEST)
        google_format = request.to_google_format()
        
        assert "tools" in google_format
        assert len(google_format["tools"]) == 1
        assert "functionDeclarations" in google_format["tools"][0]
        assert google_format["tools"][0]["functionDeclarations"][0]["name"] == "get_weather"


class TestDeltaModels:
    """Tests for stream delta models."""
    
    def test_openai_stream_delta_text(self):
        """Test OpenAI text stream delta."""
        delta = OpenAIStreamDelta(**OPENAI_TEXT_DELTA)
        assert delta.model == "gpt-4"
        assert len(delta.choices) == 1
        assert delta.choices[0]["delta"]["content"] == " Hello"
    
    def test_openai_stream_delta_tool(self):
        """Test OpenAI tool stream delta."""
        delta = OpenAIStreamDelta(**OPENAI_TOOL_DELTA)
        assert delta.model == "gpt-4"
        assert len(delta.choices) == 1
        assert "tool_calls" in delta.choices[0]["delta"]
        assert delta.choices[0]["delta"]["tool_calls"][0]["function"]["name"] == "get_weather"
    
    def test_anthropic_stream_delta_text(self):
        """Test Anthropic text stream delta."""
        delta = AnthropicStreamDelta(**ANTHROPIC_TEXT_DELTA)
        assert delta.type == "content_block_delta"
        assert delta.index == 0
        assert delta.delta["type"] == "text_delta"
        assert delta.delta["text"] == " Hello"
    
    def test_anthropic_stream_delta_tool(self):
        """Test Anthropic tool stream delta."""
        delta = AnthropicStreamDelta(**ANTHROPIC_TOOL_DELTA)
        assert delta.type == "content_block_start"
        assert delta.index == 0
        assert delta.content_block["type"] == "tool_use"
        assert delta.content_block["name"] == "get_weather"
    
    def test_google_stream_delta_text(self):
        """Test Google text stream delta."""
        delta = GoogleStreamDelta(**GOOGLE_TEXT_DELTA)
        assert len(delta.candidates) == 1
        assert delta.candidates[0]["content"]["parts"][0]["text"] == " Hello"
    
    def test_google_stream_delta_tool(self):
        """Test Google tool stream delta."""
        delta = GoogleStreamDelta(**GOOGLE_TOOL_DELTA)
        assert len(delta.candidates) == 1
        assert "functionCall" in delta.candidates[0]["content"]["parts"][0]
        assert delta.candidates[0]["content"]["parts"][0]["functionCall"]["name"] == "get_weather"
    
    def test_openai_to_content(self):
        """Test extracting content from OpenAI delta."""
        delta = OpenAIStreamDelta(**OPENAI_TEXT_DELTA)
        assert delta.to_content() == " Hello"
    
    def test_anthropic_to_openai_text(self):
        """Test converting Anthropic text delta to OpenAI format."""
        delta = AnthropicStreamDelta(**ANTHROPIC_TEXT_DELTA)
        openai_format = delta.to_openai_format()
        
        assert openai_format["object"] == "chat.completion.chunk"
        assert len(openai_format["choices"]) == 1
        assert openai_format["choices"][0]["delta"]["content"] == " Hello"
    
    def test_anthropic_to_openai_tool(self):
        """Test converting Anthropic tool delta to OpenAI format."""
        delta = AnthropicStreamDelta(**ANTHROPIC_TOOL_DELTA)
        openai_format = delta.to_openai_format()
        
        assert openai_format["object"] == "chat.completion.chunk"
        assert len(openai_format["choices"]) == 1
        assert "tool_calls" in openai_format["choices"][0]["delta"]
        assert openai_format["choices"][0]["delta"]["tool_calls"][0]["function"]["name"] == "get_weather"
    
    def test_google_to_openai_text(self):
        """Test converting Google text delta to OpenAI format."""
        delta = GoogleStreamDelta(**GOOGLE_TEXT_DELTA)
        openai_format = delta.to_openai_format()
        
        assert openai_format["object"] == "chat.completion.chunk"
        assert len(openai_format["choices"]) == 1
        assert openai_format["choices"][0]["delta"]["content"] == " Hello"
    
    def test_google_to_openai_tool(self):
        """Test converting Google tool delta to OpenAI format."""
        delta = GoogleStreamDelta(**GOOGLE_TOOL_DELTA)
        openai_format = delta.to_openai_format()
        
        assert openai_format["object"] == "chat.completion.chunk"
        assert len(openai_format["choices"]) == 1
        assert "tool_calls" in openai_format["choices"][0]["delta"]
        assert openai_format["choices"][0]["delta"]["tool_calls"][0]["function"]["name"] == "get_weather"
    
    def test_openai_to_anthropic_text(self):
        """Test converting OpenAI text delta to Anthropic format."""
        delta = OpenAIStreamDelta(**OPENAI_TEXT_DELTA)
        anthropic_format = delta.to_anthropic_format()
        
        assert anthropic_format["type"] == "content_block_delta"
        assert anthropic_format["delta"]["type"] == "text_delta"
        assert anthropic_format["delta"]["text"] == " Hello"
    
    def test_openai_to_google_text(self):
        """Test converting OpenAI text delta to Google format."""
        delta = OpenAIStreamDelta(**OPENAI_TEXT_DELTA)
        google_format = delta.to_google_format()
        
        assert "candidates" in google_format
        assert len(google_format["candidates"]) == 1
        assert "parts" in google_format["candidates"][0]["content"]
        assert google_format["candidates"][0]["content"]["parts"][0]["text"] == " Hello"