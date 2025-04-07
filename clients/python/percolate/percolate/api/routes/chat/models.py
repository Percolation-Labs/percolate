"""all the pydantic models for the various streaming and non streaming models for each dialect"""

from pydantic import BaseModel, Field
from typing import Optional, Union, List, Dict, Any

class CompletionsRequestOpenApiFormat(BaseModel):
    """the OpenAPI scheme completions wrapper for Percolate"""
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
        0.0, description="Sampling temperature to use, between 0 and 2."
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

    metadata: Optional[Dict[str, str]] = Field(
        None, description="Optional field for additional metadata. (Note: This is not part of the official schema.)"
    )
    
    
"""
OPEN AI RESPONSE MODEL
"""
from typing import Optional, Union, List, Dict, Any
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Request Model
# ---------------------------------------------------------------------------

class CompletionsRequestOpenApiFormat(BaseModel):
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
        1.0, description="Sampling temperature to use, between 0 and 2."
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

    class Config:
        schema_extra = {
            "example": {
                "model": "text-davinci-003",
                "prompt": "Once upon a time,",
                "suffix": None,
                "max_tokens": 50,
                "temperature": 0.7,
                "top_p": 1,
                "n": 1,
                "stream": False,
                "logprobs": None,
                "echo": False,
                "stop": "\n",
                "presence_penalty": 0,
                "frequency_penalty": 0,
                "best_of": 1,
                "logit_bias": {},
                "user": "user-123"
            }
        }

# ---------------------------------------------------------------------------
# Supporting Types for Responses
# ---------------------------------------------------------------------------

class ToolCall(BaseModel):
    name: str = Field(..., description="The name of the tool to call.")
    arguments: str = Field(..., description="JSON-encoded string of arguments for the tool call.")

class Choice(BaseModel):
    text: str = Field(..., description="The generated text for this choice.")
    index: int = Field(..., description="The index of this completion in the returned list.")
    logprobs: Optional[Dict[str, Any]] = Field(
        None, description="Log probabilities of tokens in the generated text."
    )
    finish_reason: Optional[str] = Field(
        None, description="The reason why the completion finished (e.g. length, stop sequence)."
    )
    # Optional tool call field, if the response includes a function/tool call
    tool_call: Optional[ToolCall] = Field(
        None, description="If present, details of the tool call triggered by this completion."
    )

class Usage(BaseModel):
    prompt_tokens: int = Field(..., description="Number of tokens in the prompt.")
    completion_tokens: int = Field(..., description="Number of tokens in the completion.")
    total_tokens: int = Field(..., description="Total number of tokens used (prompt + completion).")

# ---------------------------------------------------------------------------
# Non-Streaming Response Model
# ---------------------------------------------------------------------------

class CompletionsResponse(BaseModel):
    id: str = Field(..., description="Unique identifier for the completion.")
    object: str = Field(..., description="Type of object returned, e.g. 'text_completion'.")
    created: int = Field(..., description="Timestamp of when the completion was generated.")
    model: str = Field(..., description="The model used to generate the completion.")
    choices: List[Choice] = Field(..., description="List of completions choices.")
    usage: Optional[Usage] = Field(None, description="Usage statistics for the request.")

    class Config:
        schema_extra = {
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
        }

# ---------------------------------------------------------------------------
# Streaming Response Models
# ---------------------------------------------------------------------------

class StreamingChoice(BaseModel):
    # In streaming responses, text may be sent incrementally.
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
    id: str = Field(..., description="Unique identifier for the streaming completion.")
    object: str = Field(..., description="Type of object returned, e.g. 'text_completion'.")
    created: int = Field(..., description="Timestamp for when this chunk was generated.")
    model: str = Field(..., description="The model used for the completion.")
    choices: List[StreamingChoice] = Field(..., description="List of choices for this chunk.")

    class Config:
        schema_extra = {
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
        }
