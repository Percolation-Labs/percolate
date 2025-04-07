"""
Tests for the Chat Proxy API.

These tests verify that the Chat API can:
1. Accept requests in different dialects (OpenAI, Anthropic, Google)
2. Call different model providers
3. Handle streaming and non-streaming responses
4. Translate between different dialects correctly
"""
import pytest
import json
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient
import percolate.services.llm

from percolate.api.routes.chat.models import (
    CompletionsRequestOpenApiFormat,
    AnthropicCompletionsRequest,
    GoogleCompletionsRequest,
    CompletionsResponse,
    StreamingCompletionsResponseChunk
)

from percolate.api.routes.chat.router import (
    handle_openai_request,
    handle_anthropic_request,
    handle_google_request,
    extract_metadata
)

# Sample test data
OPENAI_TEST_REQUEST = {
    "model": "gpt-4o-mini",
    "prompt": "Tell me a short story",
    "max_tokens": 50,
    "temperature": 0.7,
    "stream": False
}

ANTHROPIC_TEST_REQUEST = {
    "model": "claude-3-5-sonnet-20241022",
    "messages": [
        {"role": "user", "content": "Tell me a short story"}
    ],
    "max_tokens": 50,
    "temperature": 0.7,
    "stream": False
}

GOOGLE_TEST_REQUEST = {
    "contents": [
        {
            "role": "user",
            "parts": [{"text": "Tell me a short story"}]
        }
    ],
    "generationConfig": {
        "temperature": 0.7,
        "maxOutputTokens": 50
    }
}

# Mock responses
MOCK_OPENAI_RESPONSE = {
    "id": "cmpl-123",
    "object": "text_completion",
    "created": 1677858242,
    "model": "gpt-4",
    "choices": [
        {
            "text": "Once upon a time in a digital land...",
            "index": 0,
            "logprobs": None,
            "finish_reason": "length"
        }
    ],
    "usage": {
        "prompt_tokens": 10,
        "completion_tokens": 20,
        "total_tokens": 30
    }
}

MOCK_ANTHROPIC_RESPONSE = {
    "id": "msg_123",
    "type": "message",
    "role": "assistant",
    "content": [
        {"type": "text", "text": "Once upon a time in a digital land..."}
    ],
    "model": "claude-3-5-sonnet-20241022",
    "stop_reason": "max_tokens",
    "usage": {
        "input_tokens": 10,
        "output_tokens": 20
    }
}

MOCK_GOOGLE_RESPONSE = {
    "candidates": [
        {
            "content": {
                "role": "model",
                "parts": [{"text": "Once upon a time in a digital land..."}]
            },
            "finishReason": "MAX_TOKENS"
        }
    ],
    "usageMetadata": {
        "promptTokenCount": 10,
        "candidatesTokenCount": 20
    }
}


class TestDialectDetection:
    """Test the dialect detection logic in the models."""
    
    def test_detect_openai_dialect(self):
        """Test that OpenAI models are correctly detected."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",
            prompt="Hello",
            max_tokens=10
        )
        assert request.get_dialect() == "openai"
        
        request = CompletionsRequestOpenApiFormat(
            model="text-davinci-003",
            prompt="Hello",
            max_tokens=10
        )
        assert request.get_dialect() == "openai"
    
    def test_detect_anthropic_dialect(self):
        """Test that Anthropic models are correctly detected."""
        request = CompletionsRequestOpenApiFormat(
            model="claude-3-5-sonnet-20241022",
            prompt="Hello",
            max_tokens=10
        )
        assert request.get_dialect() == "anthropic"
    
    def test_detect_google_dialect(self):
        """Test that Google models are correctly detected."""
        request = CompletionsRequestOpenApiFormat(
            model="gemini-1.5-flash",
            prompt="Hello",
            max_tokens=10
        )
        assert request.get_dialect() == "google"
    
    def test_override_dialect_with_params(self):
        """Test that the dialect can be overridden with params."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",  # This would normally detect as OpenAI
            prompt="Hello",
            max_tokens=10
        )
        params = {"api_provider": "anthropic"}
        assert request.get_dialect(params) == "anthropic"
    
    def test_override_dialect_with_metadata(self):
        """Test that the dialect can be overridden with metadata."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",  # This would normally detect as OpenAI
            prompt="Hello",
            max_tokens=10,
            metadata={"api_provider": "google"}
        )
        assert request.get_dialect() == "google"


class TestFormatConversion:
    """Test the format conversion between different dialects."""
    
    def test_openai_to_anthropic(self):
        """Test converting from OpenAI format to Anthropic format."""
        request = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
        anthropic_format = request.to_anthropic_format()
        
        assert "messages" in anthropic_format
        assert anthropic_format["messages"][0]["role"] == "user"
        assert anthropic_format["messages"][0]["content"] == "Tell me a short story"
        assert anthropic_format["temperature"] == 0.7
        assert anthropic_format["max_tokens"] == 50
    
    def test_openai_to_google(self):
        """Test converting from OpenAI format to Google format."""
        request = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
        google_format = request.to_google_format()
        
        assert "contents" in google_format
        assert google_format["contents"][0]["role"] == "user"
        assert google_format["contents"][0]["parts"][0]["text"] == "Tell me a short story"
        assert google_format["generationConfig"]["temperature"] == 0.7
        assert google_format["generationConfig"]["maxOutputTokens"] == 50
    
    def test_anthropic_to_openai(self):
        """Test converting from Anthropic format to OpenAI format."""
        request = AnthropicCompletionsRequest(**ANTHROPIC_TEST_REQUEST)
        openai_format = request.to_openai_format()
        
        assert "prompt" in openai_format
        assert openai_format["prompt"] == "Tell me a short story"
        assert openai_format["temperature"] == 0.7
        assert openai_format["max_tokens"] == 50
    
    def test_google_to_openai(self):
        """Test converting from Google format to OpenAI format."""
        request = GoogleCompletionsRequest(**GOOGLE_TEST_REQUEST)
        openai_format = request.to_openai_format()
        
        assert "prompt" in openai_format
        assert openai_format["prompt"] == "Tell me a short story"
        assert openai_format["temperature"] == 0.7
        assert openai_format["max_tokens"] == 50


class TestResponseConversion:
    """Test converting responses between different dialects."""
    
    def test_convert_anthropic_to_openai_response(self):
        """Test converting an Anthropic response to OpenAI format."""
        response = CompletionsResponse.from_anthropic_response(MOCK_ANTHROPIC_RESPONSE, "claude-3-5-sonnet-20241022")
        
        assert response.model == "claude-3-5-sonnet-20241022"
        assert len(response.choices) == 1
        assert response.choices[0].text == "Once upon a time in a digital land..."
        assert response.usage.prompt_tokens == 10
        assert response.usage.completion_tokens == 20
    
    def test_convert_google_to_openai_response(self):
        """Test converting a Google response to OpenAI format."""
        response = CompletionsResponse.from_google_response(MOCK_GOOGLE_RESPONSE, "gemini-1.5-pro")
        
        assert response.model == "gemini-1.5-pro"
        assert len(response.choices) == 1
        assert response.choices[0].text == "Once upon a time in a digital land..."
        assert response.usage.prompt_tokens == 10
        assert response.usage.completion_tokens == 20


class TestHandlerFunctions:
    """Test the handler functions for different dialects."""
    
    def test_handle_openai_request(self):
        """Test handling an OpenAI request."""
        # Create a mock LLM class
        mock_llm_class = MagicMock()
        mock_instance = MagicMock()
        mock_llm_class.return_value = mock_instance
        
        # Create the request
        request = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
        
        # Call the handler with our mock class
        handle_openai_request(request, language_model_class=mock_llm_class)
        
        # Verify that the LLM was created with the correct model
        mock_llm_class.assert_called_once_with("gpt-4o-mini")
        
        # Verify that the LLM instance was called
        mock_instance.assert_called_once()
    
    def test_handle_anthropic_request(self):
        """Test handling an Anthropic request."""
        # Create a mock LLM class
        mock_llm_class = MagicMock()
        mock_instance = MagicMock()
        mock_llm_class.return_value = mock_instance
        
        # Create the request
        request = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
        
        # Call the handler with our mock class
        handle_anthropic_request(request, language_model_class=mock_llm_class)
        
        # Verify that the LLM was created
        mock_llm_class.assert_called_once()
        
        # Verify that the LLM instance was called
        mock_instance.assert_called_once()
    
    def test_handle_google_request(self):
        """Test handling a Google request."""
        # Create a mock LLM class
        mock_llm_class = MagicMock()
        mock_instance = MagicMock()
        mock_llm_class.return_value = mock_instance
        
        # Create the request
        request = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
        
        # Call the handler with our mock class
        handle_google_request(request, language_model_class=mock_llm_class)
        
        # Verify that the LLM was created
        mock_llm_class.assert_called_once()
        
        # Verify that the LLM instance was called
        mock_instance.assert_called_once()


class TestMetadataExtraction:
    """Test metadata extraction from requests."""
    
    def test_extract_metadata_from_request(self):
        """Test extracting metadata from the request object."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",
            prompt="Hello",
            max_tokens=10,
            metadata={
                "user_id": "user123",
                "session_id": "session456",
                "channel_id": "channel789"
            }
        )
        
        metadata = extract_metadata(request)
        
        assert metadata["user_id"] == "user123"
        assert metadata["session_id"] == "session456"
        assert metadata["channel_id"] == "channel789"
    
    def test_extract_metadata_from_params(self):
        """Test extracting metadata from params."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",
            prompt="Hello",
            max_tokens=10
        )
        
        params = {
            "user_id": "user123",
            "session_id": "session456",
            "channel_id": "channel789"
        }
        
        metadata = extract_metadata(request, params)
        
        assert metadata["user_id"] == "user123"
        assert metadata["session_id"] == "session456"
        assert metadata["channel_id"] == "channel789"
    
    def test_params_override_request_metadata(self):
        """Test that params override request metadata."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",
            prompt="Hello",
            max_tokens=10,
            metadata={
                "user_id": "user_from_request",
                "session_id": "session_from_request"
            }
        )
        
        params = {
            "user_id": "user_from_params",
            "channel_id": "channel_from_params"
        }
        
        metadata = extract_metadata(request, params)
        
        assert metadata["user_id"] == "user_from_params"  # Overridden by params
        assert metadata["session_id"] == "session_from_request"  # From request metadata
        assert metadata["channel_id"] == "channel_from_params"  # Only in params
    
    def test_generate_session_id_if_missing(self):
        """Test that a session_id is generated if not provided."""
        request = CompletionsRequestOpenApiFormat(
            model="gpt-4",
            prompt="Hello",
            max_tokens=10
        )
        
        metadata = extract_metadata(request)
        
        assert "session_id" in metadata
        assert metadata["session_id"] is not None