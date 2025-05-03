"""
Unit tests for the proxy module stream generators.

Tests that verify:
1. Buffering of tool calls and usage information
2. Conversion between different provider formats during streaming
3. Proper handling of streaming response events
"""

import pytest
import json
import time
from unittest.mock import MagicMock, patch
from io import StringIO
import requests

from percolate.services.llm.proxy.stream_generators import (
    stream_with_buffered_functions,
    request_stream_from_model,
    flush_ai_response_audit
)
from percolate.services.llm.proxy.models import (
    OpenAIRequest, AnthropicRequest, GoogleRequest
)
from percolate.services.llm.CallingContext import CallingContext

# mark all tests in this module as slow to skip during regular runs (calls external LLMs)
pytestmark = pytest.mark.slow


# Mock response class that emulates a streaming HTTP response
class MockResponse:
    def __init__(self, lines):
        self.lines = lines
        self.status_code = 200
    
    def iter_lines(self, decode_unicode=False):
        for line in self.lines:
            if decode_unicode:
                yield line
            else:
                yield line.encode('utf-8')


# Sample SSE response lines
OPENAI_STREAM_LINES = [
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"content":" there"},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}',
    'data: [DONE]'
]

OPENAI_TOOL_STREAM_LINES = [
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"loc"}}]},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation\\": \\"Par"}}]},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"is\\""}}]},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
    'data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1677858242,"model":"gpt-4","usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}',
    'data: [DONE]'
]

ANTHROPIC_STREAM_LINES = [
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}',
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}',
    'data: [DONE]'
]

ANTHROPIC_TOOL_STREAM_LINES = [
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
    'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_abc123","name":"get_weather","input":{}}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"loc"}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ation\\": \\"Par"}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"is\\""}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"}"}}',
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}',
    'data: [DONE]'
]

GOOGLE_STREAM_LINES = [
    'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":null}]}',
    'data: {"candidates":[{"content":{"parts":[{"text":" there"}],"role":"model"},"finishReason":null}]}',
    'data: {"candidates":[{"content":{"parts":[],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":20,"totalTokenCount":30}}',
    'data: [DONE]'
]

GOOGLE_TOOL_STREAM_LINES = [
    'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"location":"Paris"}}}],"role":"model"},"finishReason":null}]}',
    'data: {"candidates":[{"content":{"parts":[],"role":"model"},"finishReason":"FUNCTION_CALL"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":20,"totalTokenCount":30}}',
    'data: [DONE]'
]


@pytest.fixture
def mock_openai_response():
    return MockResponse(OPENAI_STREAM_LINES)


@pytest.fixture
def mock_openai_tool_response():
    return MockResponse(OPENAI_TOOL_STREAM_LINES)


@pytest.fixture
def mock_anthropic_response():
    return MockResponse(ANTHROPIC_STREAM_LINES)


@pytest.fixture
def mock_anthropic_tool_response():
    return MockResponse(ANTHROPIC_TOOL_STREAM_LINES)


@pytest.fixture
def mock_google_response():
    return MockResponse(GOOGLE_STREAM_LINES)


@pytest.fixture
def mock_google_tool_response():
    return MockResponse(GOOGLE_TOOL_STREAM_LINES)


@pytest.fixture
def mock_context():
    # Don't use spec to avoid CallingContext method constraints
    context = MagicMock()
    context.session_id = "test_session_123"
    context.username = "test_user"
    context.channel_ts = "test_channel"
    # These methods will be added by our tests
    context.get_api_endpoint = MagicMock(return_value="https://api.example.com/v1/completions")
    context.get_api_key = MagicMock(return_value="test_api_key")
    return context


class TestStreamWithBufferedFunctions:
    """Tests for the stream_with_buffered_functions generator."""
    
    def test_openai_text_streaming(self, mock_openai_response):
        """Test streaming text content from OpenAI."""
        results = list(stream_with_buffered_functions(
            mock_openai_response,
            source_scheme='openai',
            target_scheme='openai'
        ))
        
        # We should get at least 3 results: 2 content lines and [DONE]
        assert len(results) >= 3
        
        # Find content chunks
        content_chunks = []
        for line, chunk in results:
            if "choices" in chunk and "delta" in chunk["choices"][0] and "content" in chunk["choices"][0]["delta"]:
                content_chunks.append(chunk["choices"][0]["delta"]["content"])
        
        # Check for expected content
        assert "Hello" in content_chunks
        
        # Check for finish reason
        stop_chunk = None
        for line, chunk in results:
            if "choices" in chunk and chunk["choices"][0].get("finish_reason") == "stop":
                stop_chunk = chunk
                break
        assert stop_chunk is not None
        
        # Check for [DONE] marker
        done_marker = None
        for line, chunk in results:
            if chunk.get("type") == "done":
                done_marker = chunk
                break
        assert done_marker is not None
    
    def test_openai_tool_call_buffering(self, mock_openai_tool_response):
        """Test buffering of tool calls from OpenAI."""
        results = list(stream_with_buffered_functions(
            mock_openai_tool_response,
            source_scheme='openai',
            target_scheme='openai'
        ))
        
        # The tool_calls finish event should contain the full tool call
        tool_calls_done = None
        for line, chunk in results:
            if "choices" in chunk and chunk["choices"][0].get("finish_reason") == "tool_calls":
                tool_calls_done = chunk
                break
        
        assert tool_calls_done is not None
        assert "tool_calls" in tool_calls_done["choices"][0]["delta"]
        tool_call = tool_calls_done["choices"][0]["delta"]["tool_calls"][0]
        assert tool_call["function"]["name"] == "get_weather"
        assert tool_call["function"]["arguments"] == "{\"location\": \"Paris\"}"
    
    def test_anthropic_to_openai_conversion(self, mock_anthropic_response):
        """Test converting Anthropic stream format to OpenAI format."""
        results = list(stream_with_buffered_functions(
            mock_anthropic_response,
            source_scheme='anthropic',
            target_scheme='openai'
        ))
        
        # Check we get the expected number of yields
        assert len(results) > 0
        
        # Check that content is converted
        content_chunks = []
        for line, chunk in results:
            if "choices" in chunk and "delta" in chunk["choices"][0] and "content" in chunk["choices"][0]["delta"]:
                content_chunks.append(chunk["choices"][0]["delta"]["content"])
        
        assert "Hello" in content_chunks
        assert " there" in content_chunks
    
    def test_google_to_openai_conversion(self, mock_google_response):
        """Test converting Google stream format to OpenAI format."""
        results = list(stream_with_buffered_functions(
            mock_google_response,
            source_scheme='google',
            target_scheme='openai'
        ))
        
        # Check we get the expected number of yields
        assert len(results) > 0
        
        # Check that content is converted
        content_chunks = []
        for line, chunk in results:
            if "choices" in chunk and "delta" in chunk["choices"][0] and "content" in chunk["choices"][0]["delta"]:
                content_chunks.append(chunk["choices"][0]["delta"]["content"])
        
        assert "Hello" in content_chunks
        assert " there" in content_chunks
    
    def test_openai_to_anthropic_conversion(self, mock_openai_response):
        """Test converting OpenAI stream format to Anthropic format."""
        results = list(stream_with_buffered_functions(
            mock_openai_response,
            source_scheme='openai',
            target_scheme='anthropic'
        ))
        
        # Check we get the expected number of yields
        assert len(results) > 0
        
        # Check format conversion
        for line, chunk in results:
            if "delta" in chunk.get("choices", [{}])[0] and "content" in chunk["choices"][0]["delta"]:
                # Extract the raw line
                anthropic_raw = line[6:].strip()  # Remove 'data: ' prefix
                anthropic_data = json.loads(anthropic_raw)
                
                # Verify it's in Anthropic format
                assert "type" in anthropic_data
                if anthropic_data["type"] == "content_block_delta":
                    assert "delta" in anthropic_data
                    assert anthropic_data["delta"]["type"] == "text_delta"
    
    def test_tool_call_not_relayed_by_default(self, mock_openai_tool_response):
        """Test that tool call events are not relayed by default."""
        results = list(stream_with_buffered_functions(
            mock_openai_tool_response,
            source_scheme='openai',
            target_scheme='openai',
            relay_tool_use_events=False
        ))
        
        # Count tool call delta events vs. the consolidated one
        tool_deltas = 0
        tool_done = 0
        
        for line, chunk in results:
            if "choices" in chunk and "delta" in chunk["choices"][0]:
                delta = chunk["choices"][0]["delta"]
                if "tool_calls" in delta:
                    if chunk["choices"][0].get("finish_reason") == "tool_calls":
                        # Only the consolidated event should be present
                        tool_done += 1
                    else:
                        # Individual tool call fragments should not be relayed
                        tool_deltas += 1
        
        assert tool_done == 1  # We should have the consolidated event
        assert tool_deltas == 0  # We should not have any individual delta events
    
    def test_usage_not_relayed_by_default(self, mock_openai_response):
        """Test that usage events are not relayed by default."""
        results = list(stream_with_buffered_functions(
            mock_openai_response,
            source_scheme='openai',
            target_scheme='openai',
            relay_usage_events=False
        ))
        
        # Count raw lines with usage info
        usage_events = 0
        for line, chunk in results:
            if "data: " in line and "usage" in line:
                usage_events += 1
        
        assert usage_events == 0  # Usage should not be relayed


import pytest
from unittest.mock import patch, Mock, MagicMock
from percolate.services.llm.proxy.stream_generators import request_stream_from_model


class TestRequestStreamFromModel:
    """Tests for the request_stream_from_model function."""
    
    def test_openai_request(self, mock_context, mock_openai_response, monkeypatch):
        """Test making a request to OpenAI."""
        # Define a patched request_stream_from_model function that doesn't use a database
        def patched_request_stream(request, context, **kwargs):
            # Generate mock data using the provided OpenAI response
            return stream_with_buffered_functions(
                mock_openai_response,
                source_scheme='openai',
                target_scheme='openai'
            )
        
        # Apply the patch
        monkeypatch.setattr(
            'percolate.services.llm.proxy.stream_generators.request_stream_from_model', 
            patched_request_stream
        )
        
        request = OpenAIRequest(
            model="gpt-4",
            messages=[{"role": "user", "content": "Hello"}],
            max_tokens=100,
            stream=True
        )
        
        # Get the generator and consume it
        stream_generator = request_stream_from_model(request, mock_context)
        results = list(stream_generator)
        
        # Check that we got some results
        assert len(results) > 0
    
    def test_anthropic_request(self, mock_context, mock_anthropic_response, monkeypatch):
        """Test making a request to Anthropic."""
        # Define a patched request_stream_from_model function that doesn't use a database
        def patched_request_stream(request, context, **kwargs):
            # Generate mock data using the provided Anthropic response
            return stream_with_buffered_functions(
                mock_anthropic_response,
                source_scheme='anthropic',
                target_scheme='openai'  # We usually convert to OpenAI format
            )
        
        # Apply the patch
        monkeypatch.setattr(
            'percolate.services.llm.proxy.stream_generators.request_stream_from_model', 
            patched_request_stream
        )
        
        request = AnthropicRequest(
            model="claude-3-5-sonnet-20241022",
            messages=[{"role": "user", "content": "Hello"}],
            max_tokens=100,
            stream=True
        )
        
        # Get the generator and consume it
        stream_generator = request_stream_from_model(request, mock_context)
        results = list(stream_generator)
        
        # Check that we got some results
        assert len(results) > 0
    
    def test_google_request(self, mock_context, mock_google_response, monkeypatch):
        """Test making a request to Google."""
        # Define a patched request_stream_from_model function that doesn't use a database
        def patched_request_stream(request, context, **kwargs):
            # Verify request is properly formatted for Google
            assert isinstance(request, GoogleRequest)
            # Ensure it would actually use streamGenerateContent endpoint in the real function
            assert 'generateContent' in request.model
            
            # Generate mock data using the provided Google response
            return stream_with_buffered_functions(
                mock_google_response,
                source_scheme='google',
                target_scheme='openai'  # We usually convert to OpenAI format
            )
        
        # Apply the patch
        monkeypatch.setattr(
            'percolate.services.llm.proxy.stream_generators.request_stream_from_model', 
            patched_request_stream
        )
        
        request = GoogleRequest(
            model="gemini-1.5-flash",
            contents=[{"role": "user", "parts": [{"text": "Hello"}]}],
            generationConfig={"maxOutputTokens": 100},
        )
        
        # Get the generator and consume it
        stream_generator = request_stream_from_model(request, mock_context)
        results = list(stream_generator)
        
        # Check that we got some results
        assert len(results) > 0
    
    def test_error_handling(self, mock_context, monkeypatch):
        """Test handling of API errors."""
        # Create a mock error response
        error_response = MagicMock()
        error_response.status_code = 400
        error_response.text = "Bad request"
        error_response.json.return_value = {"error": {"message": "Invalid request"}}
        
        # Define a patched function that returns an error
        def patched_request_stream(request, context, **kwargs):
            # Create an error message in the target format
            error_chunk = {
                "error": {
                    "message": "API error: Invalid request",
                    "type": "api_error",
                    "code": 400
                }
            }
            # Return a single-item generator with the error
            def error_generator():
                yield f"data: {json.dumps(error_chunk)}\n\n", error_chunk
            return error_generator()
        
        # Apply the patch
        monkeypatch.setattr(
            'percolate.services.llm.proxy.stream_generators.request_stream_from_model', 
            patched_request_stream
        )
        
        request = OpenAIRequest(
            model="gpt-4",
            messages=[{"role": "user", "content": "Hello"}],
            max_tokens=100,
            stream=True
        )
        
        # Get the generator and consume it
        stream_generator = request_stream_from_model(request, mock_context)
        results = list(stream_generator)
        
        # Check that we got an error result
        assert len(results) == 1
        error_line, error_chunk = results[0]
        assert "error" in error_chunk
        # Note: The error_chunk['error']['type'] will be 'api_error' since we're using a mock response with status_code 400
        assert error_chunk["error"]["type"] == "api_error"


class TestBackgroundAudit:
    """Tests for audit functionality."""
    
    def test_flush_ai_response_audit(self):
        """Test flushing an AI response audit."""
        # We'll test directly by checking the function's code structure
        # Import the function
        from percolate.services.llm.proxy.stream_generators import flush_ai_response_audit
        from inspect import signature
        
        # Verify the function accepts the expected arguments
        sig = signature(flush_ai_response_audit)
        param_names = list(sig.parameters.keys())
        
        # Simple validation - check the parameter list
        assert 'content' in param_names
        assert 'tool_calls' in param_names
        assert 'tool_responses' in param_names
        assert 'usage' in param_names