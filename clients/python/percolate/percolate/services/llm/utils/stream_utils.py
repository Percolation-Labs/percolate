"""
Stream utilities for LLM interactions.

This module contains utility functions for LLM streaming but uses the new
UnifiedStreamAdapter for all streaming functionality.
"""

import json
import typing
from typing import Optional
import requests
import mimetypes
import tempfile
import uuid
from percolate.utils import logger


def audio_to_text(
    audio_file_path: str,
    service: str = "openai",
    api_key: str = None,
    model_name: str = "whisper-1",
    chunk_size_seconds: int = None,
):
    """
    Transcribe audio to text using the specified service.

    This function handles audio transcription and remains unchanged as it's
    not part of the streaming functionality that was refactored.
    """
    # Keep the existing audio_to_text implementation
    if service == "openai":
        # OpenAI Whisper API
        if api_key is None:
            from percolate.utils import get_api_key

            api_key = get_api_key("OPENAI_API_KEY")

        # Split audio into chunks if chunk_size_seconds is specified
        if chunk_size_seconds:
            # This would involve audio splitting logic
            # For now, process the entire file
            pass

        # Determine the MIME type of the file
        mime_type, _ = mimetypes.guess_type(audio_file_path)
        if mime_type is None:
            mime_type = "application/octet-stream"

        # Read the audio file
        with open(audio_file_path, "rb") as audio_file:
            files = {
                "file": (audio_file_path, audio_file, mime_type),
                "model": (None, model_name),
            }

            headers = {"Authorization": f"Bearer {api_key}"}

            response = requests.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers=headers,
                files=files,
            )

        if response.status_code == 200:
            result = response.json()
            return {"text": result.get("text", "")}
        else:
            logger.error(f"Error {response.status_code}: {response.text}")
            return {"text": response.text}


# Legacy streaming functions have been removed and replaced with UnifiedStreamAdapter
# For streaming functionality, use:
#   from percolate.services.llm.proxy.unified_stream_adapter import UnifiedStreamAdapter


def request_openai(messages, functions):
    """Create OpenAI API request data structure"""
    return {
        "model": "gpt-4",
        "messages": messages,
        "tools": functions,
        "stream": True,
    }


def request_anthropic(messages, functions):
    """Create Anthropic API request data structure"""
    return {
        "model": "claude-3-sonnet-20240229",
        "messages": messages,
        "tools": functions,
        "stream": True,
        "max_tokens": 1024,
    }


def request_google(messages, functions):
    """Create Google API request data structure"""
    return {
        "model": "gemini-pro",
        "messages": messages,
        "tools": functions,
        "stream": True,
    }


def _parse_open_ai_response(json_data):
    """Parse OpenAI response data"""
    content = ""
    if "choices" in json_data and len(json_data["choices"]) > 0:
        choice = json_data["choices"][0]
        if "delta" in choice and "content" in choice["delta"]:
            content = choice["delta"]["content"]
    return content


def print_openai_delta_content(json_data):
    """Print content from OpenAI delta response"""
    try:
        json_data = json_data.decode()
    except:
        pass
    json_data = json_data[json_data.index(":") + 1 :]
    try:
        import json
        json_data = json.loads(json_data)
        
        if json_data.get('choices') and json_data['choices']:
            choice = json_data['choices'][0]
       
            if "delta" in choice and "content" in choice["delta"]:
                content = choice["delta"]["content"]
                print(content, end="", flush=True)  
    except:
        pass


class LLMStreamIterator:
    """
    Wraps a streaming generator of LLM responses to:

    - Yield SSE-formatted lines via iter_lines(), compatible with OpenAI-style streaming.
    - Aggregate text content deltas into a final content string accessible via the .content property.
    - Collect AIResponse objects for each tool call response in the .ai_responses list, for auditing.
    - Optionally audit the entire response when stream is finished using the audit_on_flush flag.

    Attributes:
        ai_responses (List[AIResponse]): Captured AIResponse objects from tool call executions.
        content (str): Full aggregated content sent to the user; available after iter_lines() is fully consumed.
        scheme (str): Dialect of the LLM API (e.g., 'openai', 'anthropic', 'google').
        usage (dict): Token usage dict (e.g., prompt_tokens, completion_tokens, total_tokens) from the final SSE chunk; available after iter_lines() consumption.
        audit_on_flush (bool): If True, will audit the complete response after stream is finished.
    """

    def __init__(
        self,
        g,
        context=None,
        scheme: str = "openai",
        user_query: str = None,
        audit_on_flush: bool = False,
    ):
        self.g = g
        self.user_query = user_query
        self.ai_responses = []
        self._is_consumed = False
        self._content = ""
        self.scheme = scheme
        self.context = context
        self.audit_on_flush = audit_on_flush
        # Holds LLM token usage from the final SSE chunk (prompt, completion, total)
        self._usage = {}
        # Tool calls collected during streaming
        self._tool_calls = []
        # Tool responses collected during streaming
        self._tool_responses = {}

    def _extract_json_from_sse_line(self, line: str) -> Optional[dict]:
        """
        Extract JSON data from various SSE line formats.

        Handles:
        - data: {"id": "...", "choices": [...]}  -> Standard OpenAI streaming format
        - data: {"name": "...", "arguments": "..."}  -> Function call event data
        - event: function_call  -> Event type (no JSON to extract)
        - data: [DONE]  -> End marker (no JSON to extract)

        Args:
            line: SSE formatted line

        Returns:
            Parsed JSON dict if successful, None otherwise
        """
        try:
            line = line.strip()

            # Handle data lines with JSON
            if line.startswith("data: ") and line != "data: [DONE]":
                json_part = line[6:]  # Skip "data: "
                return json.loads(json_part)

            # Event lines don't contain JSON data to parse
            elif line.startswith("event: "):
                return None

            # Empty lines or other formats
            else:
                return None

        except json.JSONDecodeError:
            # Not valid JSON, return None (this is fine - we'll still yield the line)
            return None
        except Exception:
            # Any other parsing error
            return None

    def iter_lines(self, **kwargs):
        """
        Yield SSE-formatted bytes while aggregating content deltas and capturing token usage.
        When audit_on_flush is True, this will audit the complete response after stream is done.

        The stream will end with a [DONE] marker to ensure compatibility with OpenWebUI
        and other clients that expect this marker to detect the end of the stream.
        """
        self._is_consumed = False
        done_marker_seen = False
        finish_reason_seen = False

        try:
            # Optimization: Just send a single minimal heartbeat
            # This ensures headers are flushed but reduces initial delay
            yield b'data: {"id":"init","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":""},"finish_reason":null}]}\n\n'
            for item in self.g():
                # Check if this is a [DONE] marker
                if isinstance(item, str) and item.strip() == "data: [DONE]":
                    done_marker_seen = True

                # Collect the tool call responses and emit status messages about them
                from percolate.models.p8 import AIResponse

                if isinstance(item, AIResponse):
                    self.ai_responses.append(item)
                    continue

                try:
                    for piece in _parse_open_ai_response(item):
                        self._content += piece

                    # Try to extract tool calls and finish reason
                    try:
                        if isinstance(item, str):
                            # Parse JSON from SSE format for metadata extraction
                            data = self._extract_json_from_sse_line(item)
                        else:
                            data = item

                        # Extract usage information only if data is a dict
                        if data and isinstance(data, dict) and "usage" in data:
                            self._usage = data["usage"]

                        # Extract tool calls and check for finish_reason only if data is a dict
                        if (
                            data
                            and isinstance(data, dict)
                            and "choices" in data
                            and data["choices"]
                        ):
                            choice = data["choices"][0]

                            # Check if we've seen a finish_reason
                            if choice.get("finish_reason"):
                                finish_reason_seen = True

                            if choice.get("finish_reason") == "tool_calls":
                                delta = choice.get("delta", {})
                                if "tool_calls" in delta:
                                    for tool_call in delta["tool_calls"]:
                                        if "id" in tool_call:
                                            self._tool_calls.append(tool_call)
                    except Exception:
                        pass
                except Exception:
                    pass

                # Always yield the item - this is the fixed logic
                if isinstance(item, str):
                    encoded = item.encode("utf-8")
                    yield encoded
                else:
                    yield item

        except Exception as e:
            import traceback
            import json

            error_msg = f"Error during streaming: {str(e)}"
            logger.error(f"{error_msg}\n{traceback.format_exc()}")

            # Create an error SSE event to inform the client
            error_chunk = {
                "id": str(uuid.uuid4()),
                "object": "chat.completion.chunk",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "content": f"\n\n❌ **Streaming Error**: {error_msg}\n\nPlease check your configuration and try again.\n\n"
                        },
                        "finish_reason": None,
                    }
                ],
            }
            error_line = f"data: {json.dumps(error_chunk)}\n\n"
            yield error_line.encode("utf-8")

            # Also raise the error to make sure it's not silently ignored
            # But only after we've sent the error message to the client
            import time

            time.sleep(0.1)  # Give a moment for the error message to be sent
            raise e

        finally:
            self._is_consumed = True

            # Send finish_reason "stop" if we haven't seen a finish_reason yet
            if not finish_reason_seen:
                finish_chunk = f'data: {{"id":"{uuid.uuid4()}","object":"chat.completion.chunk","choices":[{{"index":0,"delta":{{}},"finish_reason":"stop"}}]}}\n\n'
                yield finish_chunk.encode("utf-8")

            # Always send a [DONE] marker at the end if we haven't seen one yet
            # This ensures OpenWebUI knows the stream is complete
            if not done_marker_seen:
                done_marker = "data: [DONE]\n\n"
                yield done_marker.encode("utf-8")

            # Audit the response if audit_on_flush is True
            if self.audit_on_flush:
                self._audit_response()

    def _audit_response(self):
        """
        Audit the complete response after stream is finished.
        Uses the audit_response_for_user method which provides a more comprehensive audit.
        """
        try:
            from percolate.services.llm.proxy.utils import audit_response_for_user
            import uuid

            logger.info(
                f"Auditing stream response, content length: {len(self._content)}"
            )

            # Make sure context has a session_id
            if self.context and not getattr(self.context, "session_id", None):
                self.context.session_id = str(uuid.uuid4())
                logger.debug(
                    f"Generated new session_id for audit: {self.context.session_id}"
                )

            # Use the more comprehensive audit_response_for_user method
            audit_response_for_user(
                response=self, context=self.context, query=self.user_query
            )

        except Exception as e:
            logger.error(f"Error auditing stream response: {e}")

    @property
    def status_code(self):
        """TODO - we many want to implement this"""
        return 200

    @property
    def session_id(self):
        """this at the moment is needed because when audit the session we should use a single session id and its not clear who knows what when yet"""
        if self.context:
            return self.context.session_id

    @property
    def content(self):
        """this is a collector for use by auditing tools"""
        if not self._is_consumed:
            raise Exception(
                f"You are trying to read content from an unconsumed iterator - you must iterate iter_lines first"
            )
        return self._content

    @property
    def usage(self):
        """
        Return token usage (prompt_tokens, completion_tokens, total_tokens) from the final SSE chunk.
        Must be accessed after iter_lines() has been fully consumed.
        """
        if not self._is_consumed:
            raise Exception(
                "You must fully consume iter_lines() before accessing usage"
            )
        return self._usage


def _parse_open_ai_response(json_data):
    """parse the open ai message structure for the delta to get the actual content"""
    if isinstance(json_data, str):
        try:
            data = json.loads(json_data[6:])
        except json.JSONDecodeError:
            return
    else:
        data = json_data
    for choice in data.get("choices", []):
        delta = choice.get("delta", {})
        content = delta.get("content")
        if content is not None:
            yield content
