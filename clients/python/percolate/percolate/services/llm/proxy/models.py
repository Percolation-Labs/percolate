"""
Pydantic models for LLM API requests and both streaming and non-streaming responses.

This module defines the data models used for:
1. Request payload structures for different LLM providers (OpenAI, Anthropic, Google)
2. Streaming delta formats for each provider
3. Non-streaming complete response formats for each provider
4. Conversion utilities between different formats

These models support the unified interface for making LLM API calls and handling
responses across different providers, in both streaming and non-streaming modes.
"""

from pydantic import BaseModel, Field, model_validator, root_validator
from typing import Dict, List, Optional, Union, Any, Literal
import json
import time
import uuid


class LLMApiRequest(BaseModel):
    """Base class for LLM API requests with common interface methods"""
    model: str
    messages: List[Dict[str, Any]]
    max_tokens: Optional[int] = 1024
    temperature: Optional[float] = 0.7
    top_p: Optional[float] = 1.0
    stream: Optional[bool] = False
    tools: Optional[List[Dict[str, Any]]] = None
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI API format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic API format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google API format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def prepare_request_data(self, params: Dict[str, Any], source_scheme: str) -> Dict[str, Any]:
        """
        Prepare the complete request data based on the source scheme
        
        Args:
            params: Model parameters including API credentials and endpoints
            source_scheme: The API scheme to use ('openai', 'anthropic', 'google')
            
        Returns:
            Dict containing the API data, URL, and headers
        """
        if source_scheme == 'openai':
            return self.prepare_openai_request(params)
        elif source_scheme == 'anthropic':
            return self.prepare_anthropic_request(params)
        elif source_scheme == 'google':
            return self.prepare_google_request(params)
        else:
            raise ValueError(f"Unsupported source scheme: {source_scheme}")
    
    def prepare_openai_request(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Prepare an OpenAI formatted request with API data, URL, and headers
        
        Args:
            params: Model parameters including API credentials and endpoints
            
        Returns:
            Dict containing the API data, URL, and headers
        """
        api_data = self.to_openai_format()
        # Ensure streaming is enabled
        api_data["stream"] = True
        
        return {
            "api_data": api_data,
            "api_url": params.get('completions_uri'),
            "headers": {
                "Content-Type": "application/json",
                "Authorization": f"Bearer {params.get('token')}"
            }
        }
    
    def prepare_anthropic_request(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Prepare an Anthropic formatted request with API data, URL, and headers
        
        Args:
            params: Model parameters including API credentials and endpoints
            
        Returns:
            Dict containing the API data, URL, and headers
        """
        api_data = self.to_anthropic_format()
        # Ensure streaming is enabled
        api_data["stream"] = True
        
        return {
            "api_data": api_data,
            "api_url": params.get('completions_uri'),
            "headers": {
                "Content-Type": "application/json",
                "x-api-key": params.get('token'),
                "anthropic-version": params.get('anthropic-version', "2023-06-01")
            }
        }
    
    def prepare_google_request(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """
        Prepare a Google formatted request with API data, URL, and headers
        
        Args:
            params: Model parameters including API credentials and endpoints
            
        Returns:
            Dict containing the API data, URL, and headers
        """
        api_data = self.to_google_format()
        api_url = params.get('completions_uri')
        api_key = params.get('token')
        
        # For Google, streaming uses a different endpoint with ?alt=sse
        if "streamGenerateContent" not in api_url:
            api_url = api_url.replace("generateContent", "streamGenerateContent")
        if "?" not in api_url:
            api_url = f"{api_url}?alt=sse&key={api_key}"
        
        return {
            "api_data": api_data,
            "api_url": api_url,
            "headers": {
                "Content-Type": "application/json"
            }
        }


class OpenAIRequest(LLMApiRequest):
    """
    OpenAI API request format for chat completions with tool calls support
    
    This follows the OpenAI Chat Completions API specification:
    https://platform.openai.com/docs/api-reference/chat/create
    """
    messages: List[Dict[str, Any]]
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: Optional[Union[str, Dict[str, Any]]] = None
    response_format: Optional[Dict[str, str]] = None
    user: Optional[str] = None
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Anthropic format"""
        result = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "stream": self.stream,
        }
        
        # Extract system message
        system_content = ""
        for msg in self.messages:
            if msg["role"] == "system":
                system_content += msg["content"] + "\n" if isinstance(msg["content"], str) else ""
        
        if system_content:
            result["system"] = system_content.strip()
        
        # Convert messages - Anthropic only supports user and assistant roles
        anthropic_messages = []
        for msg in self.messages:
            if msg["role"] == "system":
                continue  # Already handled above
            
            # Convert OpenAI message content format to Anthropic format
            if msg["role"] == "tool":
                # Tool messages become assistant messages in Anthropic
                role = "assistant"
            else:
                role = msg["role"]
            
            content = msg.get("content", "")
            
            # Add to anthropic messages
            anthropic_messages.append({
                "role": role,
                "content": content
            })
        
        result["messages"] = anthropic_messages
        
        # Convert tools if present
        if self.tools:
            anthropic_tools = []
            for tool in self.tools:
                if tool.get("type") == "function" and "function" in tool:
                    function = tool["function"]
                    anthropic_tools.append({
                        "name": function.get("name", ""),
                        "description": function.get("description", ""),
                        "input_schema": function.get("parameters", {})
                    })
            
            if anthropic_tools:
                result["tools"] = anthropic_tools
        
        return result
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert OpenAI format to Google format"""
        result = {
            "generationConfig": {
                "temperature": self.temperature,
                "topP": self.top_p,
                "maxOutputTokens": self.max_tokens,
            }
        }
        
        # Extract system content
        system_content = ""
        for msg in self.messages:
            if msg["role"] == "system":
                system_content += msg["content"] + "\n" if isinstance(msg["content"], str) else ""
        
        # Create Google contents (messages)
        contents = []
        for msg in self.messages:
            if msg["role"] == "system":
                continue  # Handled separately
            
            # Map roles
            if msg["role"] == "user":
                g_role = "user"
            elif msg["role"] == "assistant":
                g_role = "model"
            elif msg["role"] == "tool":
                g_role = "function"
            else:
                g_role = "user"  # Default to user
            
            # Create parts
            parts = []
            content = msg.get("content", "")
            if content:
                if isinstance(content, str):
                    parts.append({"text": content})
                elif isinstance(content, list):
                    for item in content:
                        if item.get("type") == "text":
                            parts.append({"text": item.get("text", "")})
            
            # Add tool calls if present
            if msg.get("tool_calls"):
                for tool_call in msg["tool_calls"]:
                    if "function" in tool_call:
                        function = tool_call["function"]
                        parts.append({
                            "functionCall": {
                                "name": function.get("name", ""),
                                "args": json.loads(function.get("arguments", "{}"))
                            }
                        })
            
            # Add to contents
            if parts:
                contents.append({"role": g_role, "parts": parts})
        
        result["contents"] = contents
        
        # Add system instruction if present
        if system_content:
            result["systemInstruction"] = {"parts": [{"text": system_content.strip()}]}
        
        # Add tools if present
        if self.tools:
            function_declarations = []
            for tool in self.tools:
                if tool.get("type") == "function" and "function" in tool:
                    function = tool["function"]
                    function_declarations.append({
                        "name": function.get("name", ""),
                        "description": function.get("description", ""),
                        "parameters": function.get("parameters", {})
                    })
            
            if function_declarations:
                result["tools"] = [{"functionDeclarations": function_declarations}]
                
                # Add tool config
                result["toolConfig"] = {"functionCallingConfig": {"mode": "AUTO"}}
                
                # Handle specific tool choice
                if self.tool_choice == "none":
                    result["toolConfig"]["functionCallingConfig"]["mode"] = "NONE"
                elif self.tool_choice != "auto" and isinstance(self.tool_choice, dict):
                    if self.tool_choice.get("type") == "function":
                        result["toolConfig"]["functionCallingConfig"]["mode"] = "ANY"
        
        return result
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in OpenAI format"""
        return self.model_dump(exclude_none=True)


class AnthropicRequest(LLMApiRequest):
    """
    Anthropic API request format for Claude models
    
    This follows the Anthropic Messages API specification:
    https://docs.anthropic.com/claude/reference/messages_post
    """
    system: Optional[str] = None
    stop_sequences: Optional[List[str]] = None
    top_k: Optional[int] = None
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert Anthropic format to OpenAI format"""
        openai_messages = []
        
        # Add system message if present
        if self.system:
            openai_messages.append({
                "role": "system", 
                "content": self.system
            })
        
        # Convert Anthropic messages to OpenAI format
        for msg in self.messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            
            # In Anthropic, content can be string or array of content blocks
            if isinstance(content, list):
                # Extract text from content blocks
                text_content = ""
                for block in content:
                    if block.get("type") == "text":
                        text_content += block.get("text", "")
                
                openai_messages.append({
                    "role": role,
                    "content": text_content
                })
            else:
                openai_messages.append({
                    "role": role,
                    "content": content
                })
        
        # Convert tools if present
        openai_tools = None
        if self.tools:
            openai_tools = []
            for tool in self.tools:
                openai_tools.append({
                    "type": "function",
                    "function": {
                        "name": tool.get("name", ""),
                        "description": tool.get("description", ""),
                        "parameters": tool.get("input_schema", {})
                    }
                })
        
        return {
            "model": self.model,
            "messages": openai_messages,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
            "stream": self.stream,
            "tools": openai_tools,
            "stop": self.stop_sequences
        }
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in Anthropic format"""
        return self.model_dump(exclude_none=True)
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert Anthropic format to Google format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIRequest to convert to Google format
        openai_request = OpenAIRequest(**openai_format)
        return openai_request.to_google_format()


class GoogleRequest(LLMApiRequest):
    """
    Google API request format for Gemini models
    
    This follows the Google Gemini API specification:
    https://ai.google.dev/api/rest/v1beta/models/generateContent
    """
    messages: Optional[List[Dict[str, Any]]] = None  # Keep the messages field from LLMApiRequest
    contents: Optional[List[Dict[str, Any]]] = None  # Google-specific contents field
    generationConfig: Optional[Dict[str, Any]] = None
    systemInstruction: Optional[Dict[str, Any]] = None
    safetySettings: Optional[List[Dict[str, Any]]] = None
    tools: Optional[List[Dict[str, Any]]] = None
    toolConfig: Optional[Dict[str, Any]] = None
    
    @model_validator(mode='before')
    @classmethod
    def check_messages(cls, values):
        """Validate and convert between messages and contents"""
        # If contents is provided but messages is not, we're good
        if 'contents' in values and values['contents']:
            if 'messages' not in values or not values['messages']:
                # Create placeholder messages for LLMApiRequest compatibility
                user_content = []
                for content in values['contents']:
                    if content.get('role') == 'user':
                        parts = content.get('parts', [])
                        text_parts = [part.get('text', '') for part in parts if 'text' in part]
                        user_content.append(''.join(text_parts))
                
                if user_content:
                    values['messages'] = [{"role": "user", "content": ' '.join(user_content)}]
                else:
                    values['messages'] = [{"role": "user", "content": ""}]
            return values
            
        # If messages is provided but contents is not, convert messages to contents
        if 'messages' in values and values['messages'] and ('contents' not in values or not values['contents']):
            contents = []
            for msg in values['messages']:
                role = msg.get('role', 'user')
                # Map role
                g_role = 'model' if role == 'assistant' else 'user'
                
                content = msg.get('content', '')
                if isinstance(content, str):
                    parts = [{"text": content}]
                else:
                    parts = [{"text": item.get('text', '')} for item in content if 'text' in item]
                
                contents.append({
                    "role": g_role,
                    "parts": parts
                })
            
            values['contents'] = contents
            
        return values
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert Google format to OpenAI format"""
        openai_messages = []
        
        # Extract system instruction if present
        if self.systemInstruction:
            system_text = ""
            parts = self.systemInstruction.get("parts", [])
            if isinstance(parts, list):
                for part in parts:
                    if "text" in part:
                        system_text += part["text"]
            elif isinstance(parts, dict) and "text" in parts:
                system_text = parts["text"]
            
            if system_text:
                openai_messages.append({
                    "role": "system",
                    "content": system_text
                })
        
        # Convert Google contents to OpenAI messages
        for content in self.contents:
            role = content.get("role", "user")
            # Map Google roles to OpenAI roles
            openai_role = "assistant" if role == "model" else "user"
            
            # Process parts to extract text and function calls
            text_parts = []
            tool_calls = []
            
            for part in content.get("parts", []):
                if "text" in part:
                    text_parts.append(part["text"])
                elif "functionCall" in part:
                    function_call = part["functionCall"]
                    tool_calls.append({
                        "id": f"call_{str(uuid.uuid4())[:16]}",
                        "type": "function",
                        "function": {
                            "name": function_call.get("name", ""),
                            "arguments": json.dumps(function_call.get("args", {}))
                        }
                    })
            
            # Create message
            message = {
                "role": openai_role,
                "content": "\n".join(text_parts) if text_parts else None
            }
            
            # Add tool calls if present
            if tool_calls:
                message["tool_calls"] = tool_calls
            
            openai_messages.append(message)
        
        # Extract generation config
        max_tokens = 1024
        temperature = 0.7
        top_p = 1.0
        
        if self.generationConfig:
            max_tokens = self.generationConfig.get("maxOutputTokens", max_tokens)
            temperature = self.generationConfig.get("temperature", temperature)
            top_p = self.generationConfig.get("topP", top_p)
        
        # Convert tools if present
        openai_tools = None
        if self.tools:
            openai_tools = []
            for tool in self.tools:
                if "functionDeclarations" in tool:
                    for func in tool["functionDeclarations"]:
                        openai_tools.append({
                            "type": "function",
                            "function": {
                                "name": func.get("name", ""),
                                "description": func.get("description", ""),
                                "parameters": func.get("parameters", {})
                            }
                        })
        
        return {
            "model": self.model,
            "messages": openai_messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "top_p": top_p,
            "stream": self.stream,
            "tools": openai_tools
        }
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert Google format to Anthropic format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIRequest to convert to Anthropic format
        openai_request = OpenAIRequest(**openai_format)
        return openai_request.to_anthropic_format()
    
    def to_google_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in Google format"""
        return self.model_dump(exclude_none=True)


class StreamDelta(BaseModel):
    """Abstract base class for streaming payloads with helper methods"""
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI delta format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_content(self) -> str:
        """Extract text content from the delta, if any"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_sse_event(self) -> str:
        """Format as a server-sent event"""
        data = json.dumps(self.to_openai_format())
        return f"data: {data}\n\n"
    
    @classmethod
    def parse_sse(cls, line: str) -> Optional['StreamDelta']:
        """Parse a server-sent event line into a delta object"""
        if not line or not line.startswith("data: "):
            return None
        
        try:
            data = json.loads(line[6:])
            return cls.from_dict(data)
        except json.JSONDecodeError:
            return None
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'StreamDelta':
        """Create a delta object from a dictionary"""
        raise NotImplementedError("Subclasses must implement this method")


class OpenAIStreamDelta(StreamDelta):
    """
    OpenAI streaming delta format
    
    Example text delta:
    {
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1677858242,
        "model": "gpt-4",
        "choices": [{
            "index": 0,
            "delta": {
                "content": " Hello"
            },
            "finish_reason": null
        }]
    }
    
    Example tool call delta:
    {
        "id": "chatcmpl-123",
        "object": "chat.completion.chunk",
        "created": 1677858242,
        "model": "gpt-4",
        "choices": [{
            "index": 0,
            "delta": {
                "tool_calls": [{
                    "index": 0,
                    "id": "call_abc123",
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "arguments": "{\"loc"
                    }
                }]
            },
            "finish_reason": null
        }]
    }
    """
    id: str
    object: str = "chat.completion.chunk"
    created: int
    model: str
    choices: List[Dict[str, Any]]
    usage: Optional[Dict[str, int]] = None
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in OpenAI format"""
        return self.model_dump(exclude_none=True)
    
    def to_content(self) -> str:
        """Extract text content from the delta, if any"""
        if not self.choices:
            return ""
        
        delta = self.choices[0].get("delta", {})
        return delta.get("content", "")
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'OpenAIStreamDelta':
        """Create a delta object from an OpenAI format dictionary"""
        return cls(**data)
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic stream format"""
        if not self.choices:
            return {}
        
        choice = self.choices[0]
        delta = choice.get("delta", {})
        
        # Check for text content
        if "content" in delta and delta["content"]:
            return {
                "type": "content_block_delta",
                "index": 0,
                "delta": {
                    "type": "text_delta",
                    "text": delta["content"]
                }
            }
        
        # Check for tool calls
        elif "tool_calls" in delta and delta["tool_calls"]:
            tool_call = delta["tool_calls"][0]
            if "function" in tool_call:
                # First message with tool name
                if "name" in tool_call["function"]:
                    return {
                        "type": "content_block_start",
                        "index": tool_call.get("index", 0),
                        "content_block": {
                            "type": "tool_use",
                            "id": tool_call.get("id", f"toolu_{str(uuid.uuid4())[:16]}"),
                            "name": tool_call["function"]["name"],
                            "input": {}
                        }
                    }
                # Argument updates
                elif "arguments" in tool_call["function"]:
                    return {
                        "type": "content_block_delta",
                        "index": tool_call.get("index", 0),
                        "delta": {
                            "type": "input_json_delta",
                            "partial_json": tool_call["function"]["arguments"]
                        }
                    }
        
        # Check for finish reason
        finish_reason = choice.get("finish_reason")
        if finish_reason:
            return {
                "type": "message_delta",
                "delta": {
                    "stop_reason": finish_reason,
                    "stop_sequence": None
                }
            }
        
        # Default empty delta
        return {
            "type": "content_block_delta",
            "delta": {}
        }
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google stream format"""
        if not self.choices:
            return {}
        
        choice = self.choices[0]
        delta = choice.get("delta", {})
        
        # Basic structure
        result = {
            "candidates": [
                {
                    "content": {
                        "parts": [],
                        "role": "model"
                    },
                    "finishReason": choice.get("finish_reason")
                }
            ]
        }
        
        # Add text content
        if "content" in delta and delta["content"]:
            result["candidates"][0]["content"]["parts"].append({"text": delta["content"]})
        
        # Add tool calls
        elif "tool_calls" in delta and delta["tool_calls"]:
            tool_call = delta["tool_calls"][0]
            if "function" in tool_call:
                function_call = {
                    "name": tool_call["function"].get("name", ""),
                    "args": {}
                }
                
                # Try to parse arguments if present
                arguments = tool_call["function"].get("arguments", "{}")
                try:
                    function_call["args"] = json.loads(arguments)
                except json.JSONDecodeError:
                    # For partial arguments, we can't convert to Google format properly
                    # as Google expects complete function calls
                    pass
                
                result["candidates"][0]["content"]["parts"].append({"functionCall": function_call})
        
        # Add usage if present
        if self.usage:
            result["usageMetadata"] = {
                "promptTokenCount": self.usage.get("prompt_tokens", 0),
                "candidatesTokenCount": self.usage.get("completion_tokens", 0),
                "totalTokenCount": self.usage.get("total_tokens", 0)
            }
        
        return result


class GoogleStreamDelta(StreamDelta):
    """
    Google streaming delta format
    
    Example text delta:
    {
        "candidates": [{
            "content": {
                "parts": [{"text": "Hello"}],
                "role": "model"
            },
            "finishReason": null
        }]
    }
    
    Example tool call:
    {
        "candidates": [{
            "content": {
                "parts": [{
                    "functionCall": {
                        "name": "get_weather",
                        "args": {"location": "Paris"}
                    }
                }],
                "role": "model"
            },
            "finishReason": null
        }]
    }
    """
    candidates: List[Dict[str, Any]]
    usageMetadata: Optional[Dict[str, int]] = None
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI delta format"""
        # Create base structure
        result = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": "gemini",  # Generic placeholder
            "choices": []
        }
        
        if not self.candidates:
            # Empty chunk
            result["choices"] = [{
                "index": 0,
                "delta": {},
                "finish_reason": None
            }]
            return result
        
        candidate = self.candidates[0]
        delta = {}
        
        # Extract parts from content
        if "content" in candidate and "parts" in candidate["content"]:
            parts = candidate["content"]["parts"]
            
            # Check for text content
            text_parts = [part["text"] for part in parts if "text" in part]
            if text_parts:
                delta["content"] = "".join(text_parts)
            
            # Check for function calls
            function_calls = [part["functionCall"] for part in parts if "functionCall" in part]
            if function_calls:
                tool_calls = []
                for i, func_call in enumerate(function_calls):
                    tool_calls.append({
                        "index": i,
                        "id": f"call_{str(uuid.uuid4())[:16]}",
                        "type": "function",
                        "function": {
                            "name": func_call.get("name", ""),
                            "arguments": json.dumps(func_call.get("args", {}))
                        }
                    })
                
                if tool_calls:
                    delta["tool_calls"] = tool_calls
        
        # Add the choice with delta
        result["choices"].append({
            "index": 0,
            "delta": delta,
            "finish_reason": candidate.get("finishReason")
        })
        
        # Add usage if present
        if self.usageMetadata:
            result["usage"] = {
                "prompt_tokens": self.usageMetadata.get("promptTokenCount", 0),
                "completion_tokens": self.usageMetadata.get("candidatesTokenCount", 0),
                "total_tokens": self.usageMetadata.get("totalTokenCount", 0)
            }
        
        return result
    
    def to_content(self) -> str:
        """Extract text content from the delta, if any"""
        if not self.candidates:
            return ""
        
        content = ""
        candidate = self.candidates[0]
        if "content" in candidate and "parts" in candidate["content"]:
            parts = candidate["content"]["parts"]
            for part in parts:
                if "text" in part:
                    content += part["text"]
        
        return content
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'GoogleStreamDelta':
        """Create a delta object from a Google format dictionary"""
        return cls(**data)
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic stream format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIStreamDelta to convert to Anthropic format
        openai_delta = OpenAIStreamDelta(**openai_format)
        return openai_delta.to_anthropic_format()


class AnthropicStreamDelta(StreamDelta):
    """
    Anthropic streaming delta format
    
    Example text delta:
    {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Hello"}}
    
    Example tool use start:
    {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01GVprq3zv34WNfULDBxGHYE","name":"get_weather","input":{}}}
    
    Example tool use delta:
    {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":\"Par"}}
    
    Example stop:
    {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null}}
    """
    type: str
    index: Optional[int] = 0
    delta: Optional[Dict[str, Any]] = None
    content_block: Optional[Dict[str, Any]] = None
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI delta format"""
        # Create base structure
        result = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": "claude",  # Generic placeholder
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": None
            }]
        }
        
        # Extract content based on type
        if self.type == "content_block_delta":
            if self.delta and self.delta.get("type") == "text_delta":
                # Text content
                result["choices"][0]["delta"]["content"] = self.delta.get("text", "")
            
            elif self.delta and self.delta.get("type") == "input_json_delta":
                # Tool call arguments update
                result["choices"][0]["delta"]["tool_calls"] = [{
                    "index": self.index or 0,
                    "function": {
                        "arguments": self.delta.get("partial_json", "")
                    }
                }]
        
        elif self.type == "content_block_start":
            if self.content_block and self.content_block.get("type") == "tool_use":
                # Tool call initialization
                result["choices"][0]["delta"]["tool_calls"] = [{
                    "index": self.index or 0,
                    "id": self.content_block.get("id", f"call_{str(uuid.uuid4())[:16]}"),
                    "type": "function",
                    "function": {
                        "name": self.content_block.get("name", ""),
                        "arguments": ""
                    }
                }]
        
        elif self.type == "message_delta" and self.delta:
            # Finish reason
            result["choices"][0]["finish_reason"] = self.delta.get("stop_reason")
        
        return result
    
    def to_content(self) -> str:
        """Extract text content from the delta, if any"""
        if self.type == "content_block_delta" and self.delta and self.delta.get("type") == "text_delta":
            return self.delta.get("text", "")
        return ""
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'AnthropicStreamDelta':
        """Create a delta object from an Anthropic format dictionary"""
        return cls(**data)
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google stream format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIStreamDelta to convert to Google format
        openai_delta = OpenAIStreamDelta(**openai_format)
        return openai_delta.to_google_format()


# Non-streaming response models for different providers

class LLMResponse(BaseModel):
    """Base class for complete (non-streaming) LLM responses"""
    model: str
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI response format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic response format"""
        raise NotImplementedError("Subclasses must implement this method")
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google response format"""
        raise NotImplementedError("Subclasses must implement this method")


class OpenAIResponse(LLMResponse):
    """
    OpenAI complete response format
    
    Example:
    {
        "id": "chatcmpl-123",
        "object": "chat.completion",
        "created": 1677858242,
        "model": "gpt-4",
        "usage": {
            "prompt_tokens": 56,
            "completion_tokens": 31,
            "total_tokens": 87
        },
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": "Hello! How can I help you today?",
                    "tool_calls": [
                        {
                            "id": "call_abc123",
                            "type": "function",
                            "function": {
                                "name": "get_weather",
                                "arguments": "{\"location\":\"San Francisco\",\"unit\":\"celsius\"}"
                            }
                        }
                    ]
                },
                "finish_reason": "stop",
                "index": 0
            }
        ]
    }
    """
    id: str
    object: str = "chat.completion"
    created: int
    usage: Dict[str, int]
    choices: List[Dict[str, Any]]
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in OpenAI format"""
        return self.model_dump(exclude_none=True)
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic response format"""
        if not self.choices:
            return {}
        
        choice = self.choices[0]
        message = choice.get("message", {})
        
        # Create base structure
        result = {
            "id": self.id,
            "type": "message",
            "role": message.get("role", "assistant"),
            "model": self.model,
            "stop_reason": choice.get("finish_reason", "stop"),
            "stop_sequence": None,
            "usage": {
                "input_tokens": self.usage.get("prompt_tokens", 0),
                "output_tokens": self.usage.get("completion_tokens", 0)
            }
        }
        
        # Add content blocks
        content_blocks = []
        
        # Add text block if content exists
        if "content" in message and message["content"]:
            content_blocks.append({
                "type": "text",
                "text": message["content"]
            })
        
        # Add tool use blocks if tool calls exist
        if "tool_calls" in message and message["tool_calls"]:
            for tool_call in message["tool_calls"]:
                if tool_call.get("type") == "function" and "function" in tool_call:
                    function = tool_call["function"]
                    # Parse the arguments string to create a proper JSON object
                    try:
                        args = json.loads(function.get("arguments", "{}"))
                    except json.JSONDecodeError:
                        args = {}
                    
                    content_blocks.append({
                        "type": "tool_use",
                        "id": tool_call.get("id", f"toolu_{str(uuid.uuid4())[:16]}"),
                        "name": function.get("name", ""),
                        "input": args
                    })
        
        result["content"] = content_blocks
        
        return result
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google response format"""
        if not self.choices:
            return {}
        
        choice = self.choices[0]
        message = choice.get("message", {})
        
        # Create base structure
        result = {
            "candidates": []
        }
        
        # Create the candidate structure
        candidate = {
            "content": {
                "role": "model",
                "parts": []
            },
            "finishReason": choice.get("finish_reason", "STOP").upper()
        }
        
        # Add text content if exists
        if "content" in message and message["content"]:
            candidate["content"]["parts"].append({
                "text": message["content"]
            })
        
        # Add function calls if they exist
        if "tool_calls" in message and message["tool_calls"]:
            for tool_call in message["tool_calls"]:
                if tool_call.get("type") == "function" and "function" in tool_call:
                    function = tool_call["function"]
                    # Parse the arguments string to create a proper object
                    try:
                        args = json.loads(function.get("arguments", "{}"))
                    except json.JSONDecodeError:
                        args = {}
                    
                    candidate["content"]["parts"].append({
                        "functionCall": {
                            "name": function.get("name", ""),
                            "args": args
                        }
                    })
        
        result["candidates"].append(candidate)
        
        # Add usage data
        if self.usage:
            result["usageMetadata"] = {
                "promptTokenCount": self.usage.get("prompt_tokens", 0),
                "candidatesTokenCount": self.usage.get("completion_tokens", 0),
                "totalTokenCount": self.usage.get("total_tokens", 0)
            }
        
        return result


class AnthropicResponse(LLMResponse):
    """
    Anthropic complete response format
    
    Example:
    {
        "id": "msg_0123456789abcdef",
        "type": "message",
        "role": "assistant",
        "content": [
            {
                "type": "text",
                "text": "Hello! How can I help you today?"
            },
            {
                "type": "tool_use",
                "id": "toolu_01abcdef1234567890",
                "name": "get_weather",
                "input": {
                    "location": "San Francisco",
                    "unit": "celsius"
                }
            }
        ],
        "model": "claude-3-5-sonnet-20241022",
        "stop_reason": "end_turn",
        "stop_sequence": null,
        "usage": {
            "input_tokens": 56,
            "output_tokens": 31
        }
    }
    """
    id: str
    type: str = "message"
    role: str = "assistant"
    content: List[Dict[str, Any]]
    stop_reason: Optional[str] = None
    stop_sequence: Optional[str] = None
    usage: Dict[str, int]
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in Anthropic format"""
        return self.model_dump(exclude_none=True)
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI response format"""
        # Extract text content and tool calls
        text_content = ""
        tool_calls = []
        
        for block in self.content:
            block_type = block.get("type")
            
            if block_type == "text":
                text_content += block.get("text", "")
            
            elif block_type == "tool_use":
                tool_id = block.get("id", f"call_{str(uuid.uuid4())[:16]}")
                tool_name = block.get("name", "")
                tool_input = block.get("input", {})
                
                tool_calls.append({
                    "id": tool_id,
                    "type": "function",
                    "function": {
                        "name": tool_name,
                        "arguments": json.dumps(tool_input)
                    }
                })
        
        # Create the OpenAI response structure
        result = {
            "id": self.id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": self.role,
                        "content": text_content
                    },
                    "finish_reason": self.stop_reason or "stop"
                }
            ],
            "usage": {
                "prompt_tokens": self.usage.get("input_tokens", 0),
                "completion_tokens": self.usage.get("output_tokens", 0),
                "total_tokens": self.usage.get("input_tokens", 0) + self.usage.get("output_tokens", 0)
            }
        }
        
        # Add tool calls if present
        if tool_calls:
            result["choices"][0]["message"]["tool_calls"] = tool_calls
            
            # Update finish reason if appropriate
            if result["choices"][0]["finish_reason"] == "end_turn":
                result["choices"][0]["finish_reason"] = "tool_calls" if tool_calls else "stop"
        
        return result
    
    def to_google_format(self) -> Dict[str, Any]:
        """Convert to Google response format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIResponse to convert to Google format
        openai_response = OpenAIResponse(**openai_format)
        return openai_response.to_google_format()


class GoogleResponse(LLMResponse):
    """
    Google complete response format
    
    Example:
    {
        "candidates": [
            {
                "content": {
                    "role": "model",
                    "parts": [
                        {
                            "text": "Hello! How can I help you today?"
                        },
                        {
                            "functionCall": {
                                "name": "get_weather",
                                "args": {
                                    "location": "San Francisco",
                                    "unit": "celsius"
                                }
                            }
                        }
                    ]
                },
                "finishReason": "STOP"
            }
        ],
        "usageMetadata": {
            "promptTokenCount": 56,
            "candidatesTokenCount": 31,
            "totalTokenCount": 87
        }
    }
    """
    candidates: List[Dict[str, Any]]
    usageMetadata: Optional[Dict[str, int]] = None
    
    def to_google_format(self) -> Dict[str, Any]:
        """Return self as dict, as we're already in Google format"""
        return self.model_dump(exclude_none=True)
    
    def to_openai_format(self) -> Dict[str, Any]:
        """Convert to OpenAI response format"""
        if not self.candidates:
            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": self.model,
                "choices": [],
                "usage": {}
            }
        
        candidate = self.candidates[0]
        
        # Extract role, text content, and function calls
        content = candidate.get("content", {})
        role = content.get("role", "assistant")
        parts = content.get("parts", [])
        
        text_content = ""
        tool_calls = []
        
        for i, part in enumerate(parts):
            if "text" in part:
                text_content += part["text"]
            
            elif "functionCall" in part:
                func_call = part["functionCall"]
                tool_calls.append({
                    "id": f"call_{str(uuid.uuid4())[:16]}",
                    "type": "function",
                    "function": {
                        "name": func_call.get("name", ""),
                        "arguments": json.dumps(func_call.get("args", {}))
                    }
                })
        
        # Determine finish reason
        finish_reason = candidate.get("finishReason", "STOP")
        openai_finish_reason = "stop"
        if finish_reason == "FUNCTION_CALL":
            openai_finish_reason = "tool_calls"
        elif finish_reason == "MAX_TOKENS":
            openai_finish_reason = "length"
        elif finish_reason == "SAFETY":
            openai_finish_reason = "content_filter"
        
        # Create OpenAI response structure
        result = {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": self.model,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant" if role == "model" else role,
                        "content": text_content
                    },
                    "finish_reason": openai_finish_reason
                }
            ],
            "usage": {}
        }
        
        # Add tool calls if present
        if tool_calls:
            result["choices"][0]["message"]["tool_calls"] = tool_calls
        
        # Add usage data if available
        if self.usageMetadata:
            result["usage"] = {
                "prompt_tokens": self.usageMetadata.get("promptTokenCount", 0),
                "completion_tokens": self.usageMetadata.get("candidatesTokenCount", 0),
                "total_tokens": self.usageMetadata.get("totalTokenCount", 0)
            }
        
        return result
    
    def to_anthropic_format(self) -> Dict[str, Any]:
        """Convert to Anthropic response format"""
        # First convert to OpenAI format
        openai_format = self.to_openai_format()
        
        # Then use OpenAIResponse to convert to Anthropic format
        openai_response = OpenAIResponse(**openai_format)
        return openai_response.to_anthropic_format()