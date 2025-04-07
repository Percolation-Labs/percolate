"""Pydantic models for various streaming and non-streaming models for each dialect.

This module contains all the models needed to support different LLM API dialects
(OpenAI, Anthropic, Google) in both streaming and non-streaming modes.
"""

from pydantic import BaseModel, Field, root_validator
from typing import Optional, Union, List, Dict, Any, Literal
import time
import re

# ---------------------------------------------------------------------------
# Metadata Model - Common for all requests
# ---------------------------------------------------------------------------

class RequestMetadata(BaseModel):
    """Metadata fields that can be added to any request."""
    user_id: Optional[str] = Field(None, description="ID of the end user making the request")
    session_id: Optional[str] = Field(None, description="ID for grouping related interactions")
    channel_id: Optional[str] = Field(None, description="ID of the channel where the interaction happens")
    channel_type: Optional[str] = Field(None, description="Type of channel (e.g., slack, web, etc.)")
    api_provider: Optional[str] = Field(None, description="Override the default provider")
    use_sse: Optional[bool] = Field(False, description="Whether to use Server-Sent Events for streaming")

# ---------------------------------------------------------------------------
# OpenAI API Request Model
# ---------------------------------------------------------------------------

class CompletionsRequestOpenApiFormat(BaseModel):
    """The OpenAI API schema completions wrapper for Percolate."""
    model: str = Field(..., description="ID of the model to use for this request.")
    prompt: Optional[Union[str, List[str]]] = Field(
        None, description="The prompt(s) to generate completions for."
    )
    suffix: Optional[str] = Field(
        None, description="A string to append after the completion."
    )
    max_tokens: Optional[int] = Field(
        16, description="The maximum number of tokens to generate in the completion."
    )
    temperature: Optional[float] = Field(
        0.7, description="Sampling temperature to use, between 0 and 2."
    )
    top_p: Optional[float] = Field(
        1.0, description="Nucleus sampling parameter, between 0 and 1."
    )
    n: Optional[int] = Field(
        1, description="The number of completions to generate for each prompt."
    )
    stream: Optional[bool] = Field(
        False, description="If set to True, partial progress is streamed as data-only server-sent events."
    )
    logprobs: Optional[int] = Field(
        None, description="Include the log probabilities on the logprobs most likely tokens, if provided."
    )
    echo: Optional[bool] = Field(
        False, description="If set to True, the prompt is echoed in addition to the completion."
    )
    stop: Optional[Union[str, List[str]]] = Field(
        None, description="Up to 4 sequences where the API will stop generating further tokens."
    )
    presence_penalty: Optional[float] = Field(
        0.0, description="Penalty for repetition: positive values penalize new tokens based on whether they appear in the text so far."
    )
    frequency_penalty: Optional[float] = Field(
        0.0, description="Penalty for repetition: positive values penalize new tokens based on their frequency in the text so far."
    )
    best_of: Optional[int] = Field(
        1, description="Generates multiple completions server-side and returns the best (the one with the highest log probability per token)."
    )
    logit_bias: Optional[Dict[str, float]] = Field(
        None, description="Modify the likelihood of specified tokens appearing in the completion."
    )
    user: Optional[str] = Field(
        None, description="A unique identifier representing the end-user, which can help with rate-limiting and tracking."
    )
    tools: Optional[List[Dict[str, Any]]] = Field(
        None, description="List of tools the model may use. Each tool has a type (usually 'function') and a function object."
    )
    tool_choice: Optional[Union[str, Dict[str, Any]]] = Field(
        None, description="Controls which (if any) tool is called by the model. 'auto', 'none', or a tool selection object."
    )
    metadata: Optional[Dict[str, str]] = Field(
        None, description="Optional field for additional metadata. (Note: This is not part of the official schema.)"
    )
    
    def get_dialect(self, params: Optional[Dict] = None) -> str:
        """Determine the dialect from the request and/or parameters.
        
        The method looks at the model name and any explicit API provider parameters
        to determine which dialect (OpenAI, Anthropic, Google) should be used.
        
        Args:
            params: Additional parameters that might specify the dialect
            
        Returns:
            str: The dialect to use ('openai', 'anthropic', or 'google')
        """
        # First check if an explicit api_provider is specified in the metadata or params
        if params and params.get('api_provider'):
            provider = params.get('api_provider').lower()
            if provider in ['openai', 'anthropic', 'google']:
                return provider
                
        if self.metadata and self.metadata.get('api_provider'):
            provider = self.metadata.get('api_provider').lower()
            if provider in ['openai', 'anthropic', 'google']:
                return provider
        
        # Check model name for clues
        model_name = self.model.lower()
        if any(name in model_name for name in ['gpt', 'davinci', 'curie', 'babbage', 'ada']):
            return 'openai'
        elif any(name in model_name for name in ['claude', 'anthropic']):
            return 'anthropic'
        elif any(name in model_name for name in ['gemini', 'palm', 'bison', 'gecko']):
            return 'google'
        
        # Default to OpenAI if no specific indicators
        return 'openai'
    
    def get_streaming_mode(self, params: Optional[Dict] = None) -> Optional[str]:
        """Determine the streaming mode to use.
        
        Args:
            params: Additional parameters that might specify streaming options
            
        Returns:
            Optional[str]: 'sse' for server-sent events, 'standard' for regular
                          streaming, or None for non-streaming
        """
        # First check if streaming is requested in the model
        is_streaming = self.stream
        
        # Then check if use_sse is specified in metadata or params
        use_sse = False
        if params and 'use_sse' in params:
            use_sse = params.get('use_sse', False)
        elif self.metadata and 'use_sse' in self.metadata:
            use_sse = self.metadata.get('use_sse', False)
        
        # Determine the streaming mode
        if is_streaming:
            return 'sse' if use_sse else 'standard'
        return None
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Anthropic format."""
        # Anthropic uses 'messages' instead of 'prompt'
        prompt = self.prompt
        if isinstance(prompt, list):
            prompt = "\n".join(prompt)
        
        result = {
            "model": self.model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "stop_sequences": self.stop if isinstance(self.stop, list) else [self.stop] if self.stop else None,
            "stream": self.stream,
        }
        
        # Add tools if present
        if self.tools:
            # Convert OpenAI tools format to Anthropic format
            # Note: Actual conversion happens in LanguageModel._adapt_tools_for_anthropic
            result["tools"] = self.tools
            
        return result
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Google format."""
        prompt = self.prompt
        if isinstance(prompt, list):
            prompt = "\n".join(prompt)
            
        result = {
            "contents": [
                {"role": "user", "parts": [{"text": prompt}]}
            ],
            "generationConfig": {
                "temperature": self.temperature,
                "topP": self.top_p,
                "maxOutputTokens": self.max_tokens,
                "stopSequences": self.stop if isinstance(self.stop, list) else [self.stop] if self.stop else None,
            }
        }
        
        # Add tools if present
        if self.tools:
            # Extract function declarations for Google format
            function_declarations = []
            for tool in self.tools:
                if tool.get("type") == "function" and "function" in tool:
                    function_declarations.append(tool["function"])
            
            if function_declarations:
                result["tools"] = [{"function_declarations": function_declarations}]
                # Add tool configuration
                result["tool_config"] = {
                    "function_calling_config": {"mode": "AUTO"}
                }
        
        return result
    
    model_config = {
        "json_schema_extra": {
            "example": {
                "model": "gpt-4",
                "prompt": "What's the weather like in Paris tomorrow?",
                "suffix": None,
                "max_tokens": 50,
                "temperature": 0.7,
                "top_p": 1,
                "n": 1,
                "stream": True,
                "logprobs": None,
                "echo": False,
                "stop": "\n",
                "presence_penalty": 0,
                "frequency_penalty": 0,
                "best_of": 1,
                "logit_bias": {},
                "user": "user-123",
                "tools": [
                    {
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "description": "Get the current weather in a given location",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "location": {
                                        "type": "string",
                                        "description": "The city and state, e.g. San Francisco, CA"
                                    },
                                    "date": {
                                        "type": "string",
                                        "description": "The date for the weather forecast (YYYY-MM-DD)"
                                    }
                                },
                                "required": ["location"]
                            }
                        }
                    }
                ],
                "tool_choice": "auto",
                "metadata": {
                    "user_id": "u123",
                    "session_id": "sess456",
                    "channel_id": "ch789",
                    "channel_type": "slack",
                    "use_sse": True
                }
            }
        }}

# ---------------------------------------------------------------------------
# Anthropic API Request Model
# ---------------------------------------------------------------------------

class AnthropicMessage(BaseModel):
    """A message in the Anthropic API format."""
    role: str = Field(..., description="The role of the message sender (user, assistant)")
    content: Union[str, List[Dict[str, Any]]] = Field(..., description="The content of the message")

class AnthropicCompletionsRequest(BaseModel):
    """The Anthropic API schema for Claude models."""
    model: str = Field(..., description="ID of the Claude model to use")
    messages: List[AnthropicMessage] = Field(..., description="List of messages in the conversation")
    system: Optional[str] = Field(None, description="System prompt to set the behavior of the assistant")
    max_tokens: Optional[int] = Field(1024, description="Maximum number of tokens to generate")
    temperature: Optional[float] = Field(0.7, description="Sampling temperature")
    top_p: Optional[float] = Field(0.7, description="Nucleus sampling parameter")
    top_k: Optional[int] = Field(None, description="Top-k sampling parameter")
    stop_sequences: Optional[List[str]] = Field(None, description="Sequences that will stop generation")
    stream: Optional[bool] = Field(False, description="Whether to stream the response")
    metadata: Optional[Dict[str, str]] = Field(None, description="Additional metadata")
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert Anthropic format to OpenAI format."""
        # Extract the prompt from the last user message
        prompt = None
        for msg in reversed(self.messages):
            if msg.role == "user":
                if isinstance(msg.content, str):
                    prompt = msg.content
                else:
                    # For structured content, extract text parts
                    prompt = "\n".join([
                        part.get("text", "") for part in msg.content 
                        if isinstance(part, dict) and "text" in part
                    ])
                break
        
        return {
            "model": self.model,
            "prompt": prompt,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "stop": self.stop_sequences,
            "stream": self.stream,
        }
    
    model_config = {
        "json_schema_extra": {
            "example": {
                "model": "claude-3-5-sonnet-20241022",
                "messages": [
                    {"role": "user", "content": "Hello, can you help me with a question?"}
                ],
                "system": "You are a helpful assistant.",
                "max_tokens": 1024,
                "temperature": 0.7,
                "stream": False
            }
        }}

# ---------------------------------------------------------------------------
# Google API Request Model
# ---------------------------------------------------------------------------

class GooglePart(BaseModel):
    """A part in the Google API format (text, inline data, etc)."""
    text: Optional[str] = Field(None, description="The text content")
    
    # Could add more part types as needed (inline data, etc.)

class GoogleMessage(BaseModel):
    """A message in the Google API format."""
    role: str = Field(..., description="The role of the message sender (user, model)")
    parts: List[GooglePart] = Field(..., description="The parts of the message")

class GoogleGenerationConfig(BaseModel):
    """Configuration for text generation with Google models."""
    temperature: Optional[float] = Field(0.7, description="Sampling temperature")
    topP: Optional[float] = Field(0.95, description="Nucleus sampling parameter")
    topK: Optional[int] = Field(None, description="Top-k sampling parameter")
    maxOutputTokens: Optional[int] = Field(1024, description="Maximum tokens to generate")
    stopSequences: Optional[List[str]] = Field(None, description="Sequences that will stop generation")

class GoogleCompletionsRequest(BaseModel):
    """The Google API schema for Gemini models."""
    contents: List[GoogleMessage] = Field(..., description="List of messages in the conversation")
    generationConfig: Optional[GoogleGenerationConfig] = Field(None, description="Generation configuration")
    systemInstruction: Optional[Dict[str, Any]] = Field(None, description="System instructions for the model")
    tools: Optional[List[Dict[str, Any]]] = Field(None, description="Tools that the model can use")
    metadata: Optional[Dict[str, str]] = Field(None, description="Additional metadata")
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert Google format to OpenAI format."""
        # Extract the prompt from the last user message
        prompt = None
        for msg in reversed(self.contents):
            if msg.role == "user":
                text_parts = [part.text for part in msg.parts if part.text]
                prompt = "\n".join(text_parts)
                break
        
        # Extract generation config
        max_tokens = 16  # Default
        temperature = 0.7  # Default
        top_p = 1.0  # Default
        stop = None
        
        if self.generationConfig:
            max_tokens = self.generationConfig.maxOutputTokens or max_tokens
            temperature = self.generationConfig.temperature or temperature
            top_p = self.generationConfig.topP or top_p
            stop = self.generationConfig.stopSequences
        
        return {
            "model": "gemini",  # Will be replaced with actual model ID
            "prompt": prompt,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "top_p": top_p,
            "stop": stop,
            "stream": False,  # Google uses a different approach for streaming
        }
    
    model_config = {
        "json_schema_extra": {
            "example": {
                "contents": [
                    {
                        "role": "user",
                        "parts": [{"text": "Write a story about a space explorer."}]
                    }
                ],
                "generationConfig": {
                    "temperature": 0.7,
                    "topP": 0.95,
                    "maxOutputTokens": 1024
                }
            }
        }}

# ---------------------------------------------------------------------------
# Supporting Types for Responses
# ---------------------------------------------------------------------------

class ToolCall(BaseModel):
    """A tool call in a completion response."""
    name: str = Field(..., description="The name of the tool to call.")
    arguments: str = Field(..., description="JSON-encoded string of arguments for the tool call.")
    id: Optional[str] = Field(None, description="The ID of the tool call, if available.")

class Choice(BaseModel):
    """A single completion choice in the response."""
    text: str = Field(..., description="The generated text for this choice.")
    index: int = Field(..., description="The index of this completion in the returned list.")
    logprobs: Optional[Dict[str, Any]] = Field(
        None, description="Log probabilities of tokens in the generated text."
    )
    finish_reason: Optional[str] = Field(
        None, description="The reason why the completion finished (e.g. length, stop sequence)."
    )
    tool_call: Optional[ToolCall] = Field(
        None, description="If present, details of the tool call triggered by this completion."
    )

class Usage(BaseModel):
    """Token usage information."""
    prompt_tokens: int = Field(..., description="Number of tokens in the prompt.")
    completion_tokens: int = Field(..., description="Number of tokens in the completion.")
    total_tokens: int = Field(..., description="Total number of tokens used (prompt + completion).")

# ---------------------------------------------------------------------------
# Non-Streaming Response Models
# ---------------------------------------------------------------------------

class CompletionsResponse(BaseModel):
    """The standard non-streaming response format."""
    id: str = Field(..., description="Unique identifier for the completion.")
    object: str = Field("text_completion", description="Type of object returned.")
    created: int = Field(..., description="Timestamp of when the completion was generated.")
    model: str = Field(..., description="The model used to generate the completion.")
    choices: List[Choice] = Field(..., description="List of completions choices.")
    usage: Optional[Usage] = Field(None, description="Usage statistics for the request.")

    @classmethod
    def from_anthropic_response(cls, response: Dict[str, Any], model: str) -> "CompletionsResponse":
        """Convert an Anthropic response to the OpenAI format."""
        # Extract text content
        content = ""
        if isinstance(response.get("content"), list):
            text_blocks = [block.get("text", "") for block in response.get("content", []) 
                          if block.get("type") == "text"]
            content = "".join(text_blocks)
        else:
            content = response.get("content", "")
        
        # Create choices
        choices = [
            Choice(
                text=content,
                index=0,
                finish_reason=response.get("stop_reason"),
                logprobs=None,
                tool_call=None  # Handle tool calls if present
            )
        ]
        
        # Extract usage
        usage = Usage(
            prompt_tokens=response.get("usage", {}).get("input_tokens", 0),
            completion_tokens=response.get("usage", {}).get("output_tokens", 0),
            total_tokens=response.get("usage", {}).get("input_tokens", 0) + response.get("usage", {}).get("output_tokens", 0)
        )
        
        return cls(
            id=response.get("id", f"cmpl-{int(time.time())}"),
            created=int(time.time()),
            model=model,
            choices=choices,
            usage=usage
        )
    
    @classmethod
    def from_google_response(cls, response: Dict[str, Any], model: str) -> "CompletionsResponse":
        """Convert a Google response to the OpenAI format."""
        # Extract content from the first candidate's content parts
        content = ""
        if response.get("candidates"):
            candidate = response["candidates"][0]
            if "content" in candidate and "parts" in candidate["content"]:
                text_parts = [part.get("text", "") for part in candidate["content"]["parts"] 
                             if "text" in part]
                content = "".join(text_parts)
        
        # Create choices
        choices = [
            Choice(
                text=content,
                index=0,
                finish_reason=response.get("candidates", [{}])[0].get("finishReason"),
                logprobs=None,
                tool_call=None  # Handle function calls if present
            )
        ]
        
        # Extract usage
        prompt_tokens = 0
        completion_tokens = 0
        if "usageMetadata" in response:
            prompt_tokens = response["usageMetadata"].get("promptTokenCount", 0)
            completion_tokens = response["usageMetadata"].get("candidatesTokenCount", 0)
        
        usage = Usage(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens
        )
        
        return cls(
            id=f"cmpl-{int(time.time())}",
            created=int(time.time()),
            model=model,
            choices=choices,
            usage=usage
        )
    
    model_config = {
        "json_schema_extra": {
            "example": {
                "id": "cmpl-2MoLR123",
                "object": "text_completion",
                "created": 1589478378,
                "model": "text-davinci-003",
                "choices": [
                    {
                        "text": "The complete story goes...",
                        "index": 0,
                        "logprobs": None,
                        "finish_reason": "length",
                        "tool_call": {
                            "name": "search_tool",
                            "arguments": '{"query": "openapi streaming"}'
                        }
                    }
                ],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 20,
                    "total_tokens": 30
                }
            }
        }}

# ---------------------------------------------------------------------------
# Streaming Response Models
# ---------------------------------------------------------------------------

class StreamingChoice(BaseModel):
    """A single streaming choice in a response chunk."""
    text: Optional[str] = Field(None, description="Partial generated text from this chunk.")
    index: int = Field(..., description="The index of this choice in the returned list.")
    logprobs: Optional[Dict[str, Any]] = Field(
        None, description="Partial log probabilities for tokens, if provided."
    )
    finish_reason: Optional[str] = Field(
        None, description="Indicates if the generation is complete for this choice in this chunk."
    )
    tool_call: Optional[ToolCall] = Field(
        None, description="If present in the chunk, details of the tool call triggered."
    )

class StreamingCompletionsResponseChunk(BaseModel):
    """A single chunk in a streaming response."""
    id: str = Field(..., description="Unique identifier for the streaming completion.")
    object: str = Field("text_completion", description="Type of object returned.")
    created: int = Field(..., description="Timestamp for when this chunk was generated.")
    model: str = Field(..., description="The model used for the completion.")
    choices: List[StreamingChoice] = Field(..., description="List of choices for this chunk.")
    
    @classmethod
    def from_anthropic_chunk(cls, chunk: Dict[str, Any], model: str) -> "StreamingCompletionsResponseChunk":
        """Convert an Anthropic streaming chunk to the OpenAI format."""
        # Extract text content
        content = ""
        if chunk.get("type") == "content_block_delta" and chunk.get("delta", {}).get("type") == "text_delta":
            content = chunk.get("delta", {}).get("text", "")
        
        # Create streaming choice
        choices = [
            StreamingChoice(
                text=content,
                index=0,
                finish_reason=None,
                logprobs=None,
                tool_call=None  # Handle tool calls if needed
            )
        ]
        
        return cls(
            id=chunk.get("id", f"cmpl-{int(time.time())}"),
            created=int(time.time()),
            model=model,
            choices=choices
        )
    
    @classmethod
    def from_google_chunk(cls, chunk: Dict[str, Any], model: str) -> "StreamingCompletionsResponseChunk":
        """Convert a Google streaming chunk to the OpenAI format."""
        # Extract text content
        content = ""
        if chunk.get("candidates"):
            candidate = chunk["candidates"][0]
            if "content" in candidate and "parts" in candidate["content"]:
                text_parts = [part.get("text", "") for part in candidate["content"]["parts"] 
                             if "text" in part]
                content = "".join(text_parts)
        
        # Create streaming choice
        choices = [
            StreamingChoice(
                text=content,
                index=0,
                finish_reason=chunk.get("candidates", [{}])[0].get("finishReason"),
                logprobs=None,
                tool_call=None  # Handle function calls if needed
            )
        ]
        
        return cls(
            id=f"cmpl-{int(time.time())}",
            created=int(time.time()),
            model=model,
            choices=choices
        )
    
    model_config = {
        "json_schema_extra": {
            "example": {
                "id": "cmpl-2MoLR123",
                "object": "text_completion",
                "created": 1589478378,
                "model": "text-davinci-003",
                "choices": [
                    {
                        "text": "Partial text...",
                        "index": 0,
                        "logprobs": None,
                        "finish_reason": None,
                        "tool_call": {
                            "name": "search_tool",
                            "arguments": '{"query": "openapi streaming"}'
                        }
                    }
                ]
            }
        }}
