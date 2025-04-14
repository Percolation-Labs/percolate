"""Pydantic models for various streaming and non-streaming models for each dialect.

This module contains all the models needed to support different LLM API dialects
(OpenAI, Anthropic, Google) in both streaming and non-streaming modes.
"""

from pydantic import BaseModel, Field, root_validator
from typing import Optional, Union, List, Dict, Any, Literal
import time
import re
import json
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

class MessageContent(BaseModel):
    """A content part that can be text or an image in a message."""
    type: str = Field(..., description="Type of content (e.g., 'text', 'image_url')")
    text: Optional[str] = Field(None, description="Text content when type is 'text'")
    image_url: Optional[Dict[str, str]] = Field(None, description="Image URL and detail when type is 'image_url'")

class Message(BaseModel):
    """A single message in the conversation."""
    role: str = Field(..., description="Role of the message sender (e.g., 'system', 'user', 'assistant', 'tool')")
    content: Optional[Union[str, List[MessageContent]]] = Field(None, description="Content of the message, which can be a string or structured content")
    name: Optional[str] = Field(None, description="Name of the sender, typically used for tools or assistants")
    tool_calls: Optional[List[Dict[str, Any]]] = Field(None, description="Tool calls made by the assistant")
    tool_call_id: Optional[str] = Field(None, description="ID of the tool call this message is responding to")

class FunctionDefinition(BaseModel):
    """Definition of a function that can be called by the model."""
    name: str = Field(..., description="Name of the function")
    description: Optional[str] = Field(None, description="Description of what the function does")
    parameters: Dict[str, Any] = Field(..., description="Parameters the function accepts in JSON Schema format")

class CompletionsRequestOpenApiFormat(BaseModel):
    """The OpenAI API schema for completions and chat completions."""
    # Core parameters
    model: str = Field(..., description="ID of the model to use for this request.")
    
    # Support for both completion API and chat completion API
    prompt: Optional[Union[str, List[str]]] = Field(
        None, description="The prompt(s) to generate completions for (legacy completion API)."
    )
    messages: Optional[List[Message]] = Field(
        None, description="A list of messages comprising the conversation so far (chat completion API)."
    )
    
    # API Authentication
    bearer_token: Optional[str] = Field(
        None, description="Bearer token for API authentication."
    )
    
    # Common parameters
    max_tokens: Optional[int] = Field(
        None, description="The maximum number of tokens to generate in the completion."
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
    stop: Optional[Union[str, List[str]]] = Field(
        None, description="Up to 4 sequences where the API will stop generating further tokens."
    )
    presence_penalty: Optional[float] = Field(
        0.0, description="Penalty for repetition: positive values penalize new tokens based on whether they appear in the text so far."
    )
    frequency_penalty: Optional[float] = Field(
        0.0, description="Penalty for repetition: positive values penalize new tokens based on their frequency in the text so far."
    )
    
    # Functions and Tools (Chat Completion API)
    functions: Optional[List[FunctionDefinition]] = Field(
        None, description="List of functions the model may generate JSON inputs for (legacy format)."
    )
    function_call: Optional[Union[str, Dict[str, str]]] = Field(
        None, description="Controls how the model calls functions (legacy format). Can be 'auto', 'none', or a specific function name."
    )
    tools: Optional[List[Dict[str, Any]]] = Field(
        None, description="List of tools the model may use. Each tool has a type (usually 'function') and a function object."
    )
    tool_choice: Optional[Union[str, Dict[str, Any]]] = Field(
        None, description="Controls which tool is called by the model. 'auto', 'none', or a tool selection object."
    )
    
    # Response format
    response_format: Optional[Dict[str, str]] = Field(
        None, description="Format to return the response in, e.g. {\"type\": \"json_object\"} for JSON mode."
    )
    
    # Completion API specific parameters
    suffix: Optional[str] = Field(
        None, description="A string to append after the completion (legacy completion API)."
    )
    logprobs: Optional[int] = Field(
        None, description="Include the log probabilities on the logprobs most likely tokens, if provided (legacy completion API)."
    )
    echo: Optional[bool] = Field(
        False, description="If set to True, the prompt is echoed in addition to the completion (legacy completion API)."
    )
    best_of: Optional[int] = Field(
        1, description="Generates multiple completions server-side and returns the best (legacy completion API)."
    )
    logit_bias: Optional[Dict[str, float]] = Field(
        None, description="Modify the likelihood of specified tokens appearing in the completion (works in both APIs)."
    )
    
    # User identification and metadata
    user: Optional[str] = Field(
        None, description="A unique identifier representing the end-user, which can help with rate-limiting and tracking."
    )
    metadata: Optional[Dict[str, str]] = Field(
        None, description="Optional field for additional metadata. (Note: This is not part of the official schema.)"
    )
    
    # System message (convenience parameter)
    system: Optional[str] = Field(
        None, description="System message to set the behavior of the assistant. A convenience parameter that will be converted to a message."
    )
    
    def get_tools_as_functions(self):
        """
        Extract function definitions from tools or functions field.
        
        The tools interface for OpenAI is pushed down to functions internally 
        and we map to other dialects from there. This handles both the newer
        tools format and the legacy functions format.
        
        Returns:
            List of function definitions or None if no tools/functions are defined
        """
        # First try the newer tools format
        if self.tools:
            return [r.get('function') for r in self.tools if r.get('type') == 'function' and 'function' in r]
        
        # Then try the legacy functions format
        elif self.functions:
            return [
                {
                    "name": func.name,
                    "description": func.description,
                    "parameters": func.parameters
                } for func in self.functions
            ]
        
        return None
    
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
        
        if is_streaming:
            return 'sse' #if use_sse else 'standard'
        return None
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Anthropic format."""
        result = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "stop_sequences": self.stop if isinstance(self.stop, list) else [self.stop] if self.stop else None,
            "stream": self.stream,
        }
        
        # Handle system message if provided
        if self.system:
            result["system"] = self.system
            
        # Convert messages or prompt to Anthropic format
        if self.messages:
            # Convert OpenAI messages to Anthropic messages
            anthropic_messages = []
            for msg in self.messages:
                # Map role (Anthropic only supports user and assistant roles)
                role = msg.role
                if role == "system":
                    # Handle system message (Anthropic has separate system parameter)
                    result["system"] = msg.content if isinstance(msg.content, str) else None
                    continue
                elif role == "tool":
                    # Convert tool messages to assistant format for Anthropic
                    role = "assistant"
                
                # Handle content (could be string or structured)
                content = msg.content
                
                # Add to messages
                anthropic_messages.append({
                    "role": role,
                    "content": content
                })
            
            result["messages"] = anthropic_messages
        elif self.prompt:
            # Convert prompt to message for Anthropic
            prompt = self.prompt
            if isinstance(prompt, list):
                prompt = "\n".join(prompt)
            
            result["messages"] = [{"role": "user", "content": prompt}]
        
        # Add tools if present
        if self.tools:
            # Convert OpenAI tools format to Anthropic format
            # Note: Actual conversion happens in LanguageModel._adapt_tools_for_anthropic
            result["tools"] = self.tools
        elif self.functions:
            # Convert legacy functions to tools
            functions_as_tools = []
            for func in self.functions:
                functions_as_tools.append({
                    "type": "function",
                    "function": {
                        "name": func.name,
                        "description": func.description,
                        "parameters": func.parameters
                    }
                })
            result["tools"] = functions_as_tools
            
        return result
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Google format.
        
        This handles both message-based and prompt-based formats, and converts
        function/tool calls appropriately.
        """
        result = {
            "generationConfig": {
                "temperature": self.temperature,
                "topP": self.top_p,
                "maxOutputTokens": self.max_tokens,
                "stopSequences": self.stop if isinstance(self.stop, list) else [self.stop] if self.stop else None,
            }
        }
        
        # Create the contents (messages) for Google format
        contents = []
        
        # Handle messages if present (chat completion API)
        if self.messages:
            for msg in self.messages:
                role = msg.role
                # Map OpenAI roles to Google roles
                if role == "user":
                    g_role = "user"
                elif role == "assistant":
                    g_role = "model"
                elif role == "system":
                    g_role = "user"  # Google models handle system messages as user messages
                    msg = Message(role=g_role, content=f"System: {msg.content}" if isinstance(msg.content, str) else msg.content)
                elif role == "tool":
                    g_role = "function"
                else:
                    g_role = "user"  # Default to user
                
                # Handle content based on type
                parts = []
                if isinstance(msg.content, str):
                    parts.append({"text": msg.content})
                elif isinstance(msg.content, list):
                    # Handle structured content (text and images)
                    for content_item in msg.content:
                        if content_item.type == "text":
                            parts.append({"text": content_item.text})
                        elif content_item.type == "image_url":
                            parts.append({"inline_data": content_item.image_url})
                
                # Add tool calls if present
                if msg.tool_calls:
                    for tool_call in msg.tool_calls:
                        if "function" in tool_call:
                            parts.append({
                                "functionCall": {
                                    "name": tool_call["function"].get("name", ""),
                                    "args": json.loads(tool_call["function"].get("arguments", "{}"))
                                }
                            })
                
                contents.append({"role": g_role, "parts": parts})
        
        # Handle prompt if no messages (legacy completion API)
        elif self.prompt:
            prompt = self.prompt
            if isinstance(prompt, list):
                prompt = "\n".join(prompt)
                
            # Add system message if present
            if self.system:
                contents.append({"role": "user", "parts": [{"text": f"System: {self.system}"}]})
                
            contents.append({"role": "user", "parts": [{"text": prompt}]})
        
        result["contents"] = contents
        
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
                tool_config = {"function_calling_config": {"mode": "AUTO"}}
                
                # Handle specific tool choice
                if self.tool_choice and self.tool_choice != "auto" and self.tool_choice != "none":
                    if isinstance(self.tool_choice, dict) and "function" in self.tool_choice:
                        tool_config["function_calling_config"]["mode"] = "ANY"
                    elif self.tool_choice == "none":
                        tool_config["function_calling_config"]["mode"] = "NONE"
                
                result["tool_config"] = tool_config
        
        # Add functions if present (legacy format)
        elif self.functions:
            function_declarations = []
            for func in self.functions:
                function_declarations.append({
                    "name": func.name,
                    "description": func.description,
                    "parameters": func.parameters
                })
            
            if function_declarations:
                result["tools"] = [{"function_declarations": function_declarations}]
                
                # Add tool configuration
                tool_config = {"function_calling_config": {"mode": "AUTO"}}
                
                # Handle specific function call
                if self.function_call and self.function_call != "auto" and self.function_call != "none":
                    if isinstance(self.function_call, dict) and "name" in self.function_call:
                        tool_config["function_calling_config"]["mode"] = "ANY"
                    elif self.function_call == "none":
                        tool_config["function_calling_config"]["mode"] = "NONE"
                
                result["tool_config"] = tool_config
        
        return result
    
    model_config = {
        "json_schema_extra": {
            "example": {
                # Example with messages (Chat Completion API)
                "model": "gpt-4",
                "messages": [
                    {"role": "system", "content": "You are a helpful weather assistant."},
                    {"role": "user", "content": "What's the weather like in Paris tomorrow?"}
                ],
                "max_tokens": 50,
                "temperature": 0.7,
                "top_p": 1,
                "n": 1,
                "stream": True,
                "stop": "\n",
                "presence_penalty": 0,
                "frequency_penalty": 0,
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
                "response_format": {"type": "text"},
                "metadata": {
                    "user_id": "u123",
                    "session_id": "sess456",
                    "channel_id": "ch789",
                    "channel_type": "slack",
                    "use_sse": True
                }
            },
            "example2": {
                # Example with prompt (Legacy Completion API)
                "model": "gpt-3.5-turbo",
                "prompt": "What's the weather like in Paris tomorrow?",
                "system": "You are a helpful weather assistant.",
                "max_tokens": 50,
                "temperature": 0.7, 
                "top_p": 1,
                "stream": False,
                "metadata": {
                    "user_id": "u123",
                    "session_id": "sess456"
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
        """Convert an Anthropic response to the OpenAI format.
        
        This supports mapping from tools which come in streaming data chunks like these examples:
        
   
        For non-streaming responses, the tool use block would look like:
        {
          "type": "tool_use",
          "id": "tu_01ABC123",
          "name": "get_weather",
          "input": {"location": "Paris, France"}
        }
        """
        # Extract text content and tool calls
        content = ""
        tool_call = None
        
        # Handle streaming response chunks
        if response.get("type") == "content_block_delta":
            delta = response.get("delta", {})
            # Text delta
            if delta.get("type") == "text_delta":
                content = delta.get("text", "")
            # Tool call delta (JSON)
            elif delta.get("type") == "input_json_delta":
                tool_call = ToolCall(
                    name="unknown_tool",  # Name typically comes from content_block_start
                    arguments=delta.get("partial_json", "{}"),
                    id=f"tool_{int(time.time())}"
                )
        
        # Handle tool call initialization in streaming
        elif response.get("type") == "content_block_start":
            content_block = response.get("content_block", {})
            if content_block.get("type") == "tool_use":
                tool_call = ToolCall(
                    name=content_block.get("name", ""),
                    arguments="{}",  # Initial empty arguments
                    id=content_block.get("id", f"tool_{int(time.time())}")
                )
            
        # Handle non-streaming response
        elif isinstance(response.get("content"), list):
            # Process each content block
            for block in response.get("content", []):
                # Extract text content
                if block.get("type") == "text":
                    content += block.get("text", "")
                
                # Extract tool calls
                elif block.get("type") == "tool_use":
                    tool_call = ToolCall(
                        name=block.get("name", ""),
                        arguments=block.get("input", "{}"),
                        id=block.get("id", f"tool_{int(time.time())}")
                    )
        else:
            content = response.get("content", "")
        
        # Create choices
        choices = [
            Choice(
                text=content,
                index=0,
                finish_reason=response.get("stop_reason"),
                logprobs=None,
                tool_call=tool_call
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
        """Convert a Google response to the OpenAI format.
        
        Example with tool call:
        
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "functionCall": {
                            "name": "get_weather",
                            "args": {"location": "Paris, France"}
                        }
                    }],
                    "role": "model"
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 54,
                "candidatesTokenCount": 7,
                "totalTokenCount": 61,
                "promptTokensDetails": [{"modality": "TEXT", "tokenCount": 54}],
                "candidatesTokensDetails": [{"modality": "TEXT", "tokenCount": 7}]
            },
            "modelVersion": "gemini-1.5-flash"
        }
        """
        # Extract content and function calls from the first candidate's content parts
        content = ""
        tool_call = None
        
        if response.get("candidates"):
            candidate = response["candidates"][0]
            if "content" in candidate and "parts" in candidate["content"]:
                for part in candidate["content"]["parts"]:
                    # Extract text content
                    if "text" in part:
                        content += part.get("text", "")
                    
                    # Extract function call (tool call)
                    elif "functionCall" in part:
                        function_call = part["functionCall"]
                        tool_call = ToolCall(
                            name=function_call.get("name", ""),
                            arguments=json.dumps(function_call.get("args", {})),
                            id=f"tool_{int(time.time())}"
                        )
        
        # Create choices
        choices = [
            Choice(
                text=content,
                index=0,
                finish_reason=response.get("candidates", [{}])[0].get("finishReason"),
                logprobs=None,
                tool_call=tool_call  # Include the extracted tool call
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

class StreamingDelta(BaseModel):
    """Delta content for streaming responses following the OpenAI format."""
    content: Optional[str] = Field(None, description="Text content in this delta chunk.")
    tool_calls: Optional[List[Dict[str, Any]]] = Field(None, description="Tool calls in this delta chunk.")

class StreamingChoice(BaseModel):
    """A single streaming choice in a response chunk."""
    index: int = Field(..., description="The index of this choice in the returned list.")
    delta: Optional[StreamingDelta] = Field(None, description="The content delta for this chunk.")
    text: Optional[str] = Field(None, description="Partial generated text from this chunk (deprecated).")
    logprobs: Optional[Dict[str, Any]] = Field(
        None, description="Partial log probabilities for tokens, if provided."
    )
    finish_reason: Optional[str] = Field(
        None, description="Indicates if the generation is complete for this choice in this chunk."
    )
    tool_call: Optional[ToolCall] = Field(
        None, description="If present in the chunk, details of the tool call triggered (deprecated)."
    )

class StreamingCompletionsResponseChunk(BaseModel):
    """A single chunk in a streaming response using the OpenAI delta format."""
    id: str = Field(..., description="Unique identifier for the streaming completion.")
    object: str = Field("chat.completion.chunk", description="Type of object returned.")
    created: int = Field(..., description="Timestamp for when this chunk was generated.")
    model: str = Field(..., description="The model used for the completion.")
    choices: List[StreamingChoice] = Field(..., description="List of choices for this chunk.")
    
    @classmethod
    def from_anthropic_chunk(cls, chunk: Dict[str, Any], model: str) -> "StreamingCompletionsResponseChunk":
        """
        Convert an Anthropic streaming chunk to the OpenAI delta format.
        
        Anthropic streaming chunks have the following formats:
        
        # Text content delta:
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" you."}              } 
        
        # Tool call start:
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01AzN15tQcN9kHnnhMv6fqVK","name":"get_weather","input":{}}      } 
        
        # Tool call delta:
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\""}    } 
        
        # Streaming sequence examples:
        {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}     }
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" you."}              } 
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01AzN15tQcN9kHnnhMv6fqVK","name":"get_weather","input":{}}      } 
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}'
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\""}    }
        
        # Stop reason at end of stream:
        {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}
        
        Args:
            chunk: The Anthropic format response chunk
            model: The model name
            
        Returns:
            A StreamingCompletionsResponseChunk with delta format
        """
        # Initialize an empty delta
        delta = StreamingDelta()

        # Handle streaming response chunks
        if chunk.get("type") == "content_block_delta":
            delta_data = chunk.get("delta", {})
            
            # Text delta
            if delta_data.get("type") == "text_delta":
                delta.content = delta_data.get("text", "")
                
            # Tool call JSON delta with input_json_delta
            elif delta_data.get("type") == "input_json_delta" and delta_data.get("partial_json"):
                delta.tool_calls = [{
                    "index": 0,
                    "id": f"tool_{int(time.time())}",
                    "type": "function",
                    "function": {
                        "name": "unknown_tool",  # Name typically comes from content_block_start
                        "arguments": delta_data.get("partial_json")
                    }
                }]
            
            # Tool use (for test_delta_mapping.py compatibility)
            elif delta_data.get("type") == "tool_use":
                delta.tool_calls = [{
                    "index": 0,
                    "id": delta_data.get("id", f"tool_{int(time.time())}"),
                    "type": "function",
                    "function": {
                        "name": delta_data.get("name", ""),
                        "arguments": delta_data.get("partial_json", "{}")
                    }
                }]
        
        # Handle tool call initialization in streaming
        elif chunk.get("type") == "content_block_start":
            content_block = chunk.get("content_block", {})
            if content_block.get("type") == "tool_use":
                delta.tool_calls = [{
                    "index": 0,
                    "id": content_block.get("id", f"tool_{int(time.time())}"),
                    "type": "function",
                    "function": {
                        "name": content_block.get("name", ""),
                        "arguments": "" 
                    }
                }]
        
        # Handle message completion with stop reason
        elif chunk.get("type") == "message_delta" and "stop_reason" in chunk.get("delta", {}):
            # Only set finish reason, no content or tool_calls
            pass
        
        # Get finish reason if present
        finish_reason = chunk.get("delta", {}).get("stop_reason")
        
        # Create streaming choice with delta
        choice = StreamingChoice(
            index=0,
            delta=delta,
            finish_reason=finish_reason,
            logprobs=None
        )
        
        # For backwards compatibility, also set the text and tool_call fields
        if delta.content:
            choice.text = delta.content
        
        if delta.tool_calls and len(delta.tool_calls) > 0:
            tool_call_data = delta.tool_calls[0]
            choice.tool_call = ToolCall(
                name=tool_call_data["function"]["name"],
                arguments=tool_call_data["function"]["arguments"],
                id=tool_call_data["id"]
            )
        
        return cls(
            id=chunk.get("id", f"cmpl-{int(time.time())}"),
            created=int(time.time()),
            model=model,
            choices=[choice]
        )
    
    @classmethod
    def from_google_chunk(cls, chunk: Dict[str, Any], model: str) -> "StreamingCompletionsResponseChunk":
        """
        Convert a Google streaming chunk to the OpenAI delta format.
        
        Google streaming chunks have the following format:
        
        {
            "candidates": [{
                "content": {
                    "parts": [
                        {"text": "Some content"} 
                        // OR
                        {"functionCall": {
                            "name": "get_weather",
                            "args": {"location": "Paris", "date": "2023-04-01"}
                        }}
                    ],
                    "role": "model"
                },
                "finishReason": "STOP" or null
            }]
        }
        
        For tool calls, each chunk contains the complete function call with full arguments,
        unlike OpenAI streams which deliver tool calls incrementally.
        
        Args:
            chunk: The Google format response chunk
            model: The model name
            
        Returns:
            A StreamingCompletionsResponseChunk with delta format
        """
        # Initialize an empty delta
        delta = StreamingDelta()
        
        # Extract content and tool calls
        if chunk.get("candidates"):
            candidate = chunk["candidates"][0]
            
            # Extract finish reason
            finish_reason = candidate.get("finishReason")
            
            if "content" in candidate and "parts" in candidate["content"]:
                for part in candidate["content"]["parts"]:
                    if "text" in part:
                        # Add text content to delta
                        delta.content = part.get("text", "")
                    elif "functionCall" in part:
                        # Add tool call to delta
                        function_call = part["functionCall"]
                        if not delta.tool_calls:
                            delta.tool_calls = []
                        
                        delta.tool_calls.append({
                            "index": 0,
                            "id": f"tool_{int(time.time())}",
                            "type": "function",
                            "function": {
                                "name": function_call.get("name", ""),
                                "arguments": json.dumps(function_call.get("args", {}))
                            }
                        })
            
            # Create streaming choice with delta
            choice = StreamingChoice(
                index=0,
                delta=delta,
                finish_reason=finish_reason,
                logprobs=None
            )
            
            # For backwards compatibility, also set the text and tool_call fields
            if delta.content:
                choice.text = delta.content
            
            if delta.tool_calls and len(delta.tool_calls) > 0:
                tool_call_data = delta.tool_calls[0]
                choice.tool_call = ToolCall(
                    name=tool_call_data["function"]["name"],
                    arguments=tool_call_data["function"]["arguments"],
                    id=tool_call_data["id"]
                )
            
            return cls(
                id=f"cmpl-{int(time.time())}",
                created=int(time.time()),
                model=model,
                choices=[choice]
            )
        
        # Default response if no candidates
        return cls(
            id=f"cmpl-{int(time.time())}",
            created=int(time.time()),
            model=model,
            choices=[
                StreamingChoice(
                    index=0,
                    delta=delta,
                    finish_reason=None,
                    logprobs=None
                )
            ]
        )
    
    @staticmethod
    def map_openai_delta_to_canonical(chunk: Dict[str, Any], model: str) -> Dict[str, Any]:
        """
        Map an OpenAI delta format chunk to canonical format.
        If it already has the right structure, return as is.
        
        The canonical OpenAI delta format is:
        
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1677858242,
            "model": "gpt-4",
            "choices": [{
                "index": 0,
                "delta": {
                    "content": "some text"  // For text content
                    // OR
                    "tool_calls": [{        // For tool calls
                        "index": 0,
                        "id": "call_abc123",
                        "type": "function",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{\"location\":\"Paris\"}"  // May be incremental JSON
                        }
                    }]
                },
                "finish_reason": null
            }]
        }
        
        This method also handles the legacy format that uses 'text' instead of 'delta',
        and converts it to the canonical delta format.
        
        Args:
            chunk: The OpenAI format chunk
            model: The model name
            
        Returns:
            A properly structured OpenAI delta format chunk
        """
        # If it's already in the right format with delta, return as is
        if ("choices" in chunk and 
            len(chunk["choices"]) > 0 and 
            "delta" in chunk["choices"][0]):
            return chunk
        
        # Otherwise, try to convert to the right format
        result = {
            "id": chunk.get("id", f"cmpl-{int(time.time())}"),
            "object": "chat.completion.chunk",
            "created": chunk.get("created", int(time.time())),
            "model": model or chunk.get("model", "unknown"),
            "choices": []
        }
        
        # Extract choices with delta format
        if "choices" in chunk:
            for i, choice in enumerate(chunk["choices"]):
                delta = {}
                
                # Extract content if present in text field
                if "text" in choice and choice["text"]:
                    delta["content"] = choice["text"]
                
                # Extract tool call if present
                if "tool_call" in choice and choice["tool_call"]:
                    tool_call = choice["tool_call"]
                    delta["tool_calls"] = [{
                        "index": 0,
                        "id": tool_call.get("id", f"tool_{int(time.time())}"),
                        "type": "function",
                        "function": {
                            "name": tool_call.get("name", ""),
                            "arguments": tool_call.get("arguments", "")
                        }
                    }]
                
                # Add to choices
                result["choices"].append({
                    "index": i,
                    "delta": delta,
                    "finish_reason": choice.get("finish_reason")
                })
        
        return result
    
    @classmethod
    def map_to_canonical_format(cls, chunk: Dict[str, Any], dialect: str, model: str) -> Dict[str, Any]:
        """
        Map a streaming chunk to canonical OpenAI delta format based on the dialect.
        
        Args:
            chunk: The raw response chunk
            dialect: The provider dialect ('openai', 'anthropic', 'google')
            model: The model name
            
        Returns:
            A dict in canonical OpenAI delta format
        """
        if dialect == 'anthropic':
            # Convert Anthropic format to canonical
            response = cls.from_anthropic_chunk(chunk, model)
            return response.model_dump() if response else None
        elif dialect == 'google':
            # Convert Google format to canonical
            response = cls.from_google_chunk(chunk, model) 
            return response.model_dump() if response else None
        else:
            # Handle OpenAI or default format
            return cls.map_openai_delta_to_canonical(chunk, model)
        
    @staticmethod
    def map_anthropic_chunk_to_canonical(chunk: Dict[str, Any], model: str) -> Dict[str, Any]:
        """
        Map an Anthropic streaming chunk to a canonical format.
        
        Args:
            chunk: The raw Anthropic chunk data
            model: The model name
            
        Returns:
            Dict with a canonical format for streaming
        """
        return StreamingCompletionsResponseChunk.from_anthropic_chunk(chunk, model).model_dump()
    
    @staticmethod
    def map_google_chunk_to_canonical(chunk: Dict[str, Any], model: str) -> Dict[str, Any]:
        """
        Map a Google streaming chunk to a canonical format.
        
        Args:
            chunk: The raw Google chunk data
            model: The model name
            
        Returns:
            Dict with a canonical format for streaming
        """
        return StreamingCompletionsResponseChunk.from_google_chunk(chunk, model).model_dump()
    
    @staticmethod
    def map_openai_delta_to_canonical(chunk: Dict[str, Any], model: str) -> Dict[str, Any]:
        """
        Map an OpenAI delta chunk to a canonical format.
        
        Args:
            chunk: The raw OpenAI delta chunk data
            model: The model name
            
        Returns:
            Dict with a canonical format for streaming
        """
        # If it's already in the right format, preserve it exactly
        if (
            "choices" in chunk and 
            len(chunk["choices"]) > 0 and 
            "delta" in chunk["choices"][0]
        ):
            return chunk
        
        # For older format (with text instead of delta)
        delta = {}
        result = {
            "id": chunk.get("id", f"cmpl-{int(time.time())}"),
            "object": "chat.completion.chunk",
            "created": chunk.get("created", int(time.time())),
            "model": model or chunk.get("model", "unknown"),
            "choices": []
        }
        
        if "choices" in chunk and chunk["choices"]:
            for i, choice in enumerate(chunk["choices"]):
                # Convert text to delta.content
                if "text" in choice and choice["text"]:
                    delta["content"] = choice["text"]
                
                # Convert tool_call to delta.tool_calls
                if "tool_call" in choice and choice["tool_call"]:
                    tool_call = choice["tool_call"]
                    delta["tool_calls"] = [{
                        "index": 0,
                        "id": tool_call.get("id", f"tool_{int(time.time())}"),
                        "type": "function",
                        "function": {
                            "name": tool_call.get("name", ""),
                            "arguments": tool_call.get("arguments", "")
                        }
                    }]
                
                # Add the choice with delta format
                result["choices"].append({
                    "index": i,
                    "delta": delta,
                    "finish_reason": choice.get("finish_reason")
                })
        
        return result
    
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
