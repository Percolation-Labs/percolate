"""
Streaming utilities for LLM responses.

This module provides utilities for handling streaming responses from different LLM providers
including OpenAI, Anthropic, and Google. It also includes compatibility layers for working
with the new proxy module.
"""

import requests
import json
import os
import base64
import io
import typing
import uuid
import time
from .. import FunctionCall
from percolate.models.p8 import AIResponse
from percolate.utils import logger

def audio_to_text(
    base64_audio: str,
    model: str = "whisper-1",
    temperature: float = 0.0,
    response_format: str = "json",
    language: str = None
) -> dict:
    """
    Transcribes a base64-encoded audio sample to text using OpenAI's Whisper API (REST).

    Parameters:
        base64_audio (str): The audio content encoded in base64.
        model (str): The Whisper model to use (default: "whisper-1").
        api_key (str): Your OpenAI API key. If None, reads from OPENAI_API_KEY env var.
        temperature (float): Sampling temperature (between 0 and 1). Lower values make output more deterministic.
        response_format (str): The format of the response: "json", "text", "srt", "verbose_json", or "vtt".
        language (str): The language spoken in the audio (ISO-639-1). If None, auto-detect.

    Returns:
        dict: Parsed JSON response containing transcription and metadata (or raw text if response_format != "json").
    """
    from ..LanguageModel import try_get_open_ai_key

    # Get API key
    key = try_get_open_ai_key()
    if not key:
        raise ValueError("OpenAI API key must be provided or set in OPENAI_API_KEY environment variable.")

    # Decode base64 audio
    try:
        audio_bytes = base64.b64decode(base64_audio)
    except Exception as e:
        raise ValueError("Invalid base64 audio data.") from e

    # Prepare file payload
    audio_file = io.BytesIO(audio_bytes)
    audio_file.name = "audio.wav"  # Whisper supports wav, mp3, etc.

    # Construct multipart form data
    files = {
        "file": (audio_file.name, audio_file, "application/octet-stream"),
        "model": (None, model),
        "temperature": (None, str(temperature)),
        "response_format": (None, response_format)
    }
    if language:
        files["language"] = (None, language)

    headers = {
        "Authorization": f"Bearer {key}"
    }

    endpoint = "https://api.openai.com/v1/audio/transcriptions"
    response = requests.post(endpoint, headers=headers, files=files)

    # Raise for HTTP errors
    try:
        response.raise_for_status()
    except requests.HTTPError as http_err:
        raise RuntimeError(f"OpenAI API request failed: {http_err} - {response.text}")

    # Return parsed content
    if response_format == "json":
        return response.json()
    else:
        # For non-JSON responses, return raw text
        return {"text": response.text}
    
def stream_openai_response(r, printer=None, relay=None):
    """Stream the response into the expected structure but expose a printer"""
    collected_data = {
        'tool_calls': []
    }
    collected_lines_debug = []
    collected_content = ''
    observed_tool_call = False
    tool_args = {}  # {tool_id: aggregated_args}
    tool_calls = {}
    current_role = None
    for line in r.iter_lines():
        if line:
            """when we are acting as a proxy we can also relay the response as is possibly filtering function calls"""

            #print(line)
            # print('')
            decoded_line = line.decode("utf-8").replace("data: ", "").strip() 
            collected_lines_debug.append(decoded_line)
            if decoded_line and decoded_line != "[DONE]":
                try:
                    json_data = json.loads(decoded_line)
                    if "choices" in json_data and json_data["choices"]:
                        #the last chunk wil not have a choice and will have usage tokens but otherwise keep the structure
                        collected_data = json_data
                        delta = json_data["choices"][0]["delta"]
                        if delta.get('role'):
                            current_role = delta['role']
                        delta['role'] = current_role
                        
                        # Check if there's content and aggregate it
                        if "content" in delta and delta["content"]:
                            #if relay: relay(line) #this is a way to relay with filtration to the user in the proper scheme
                            new_content = delta["content"]
                            collected_content = collected_content + new_content
                            """trace it the for the bottom"""
                            delta['content'] = collected_content
                            """we aggregate the content"""
                            if printer:
                                printer(new_content)
                        else:
                            delta['content'] = collected_content
                            
                        # Check if there are tool calls and aggregate the arguments
                        if "tool_calls" in delta:
                            
                            if not observed_tool_call:
                                observed_tool_call = True
                                # if printer:
                                #     printer(f'invoking {delta["tool_calls"]}')
                            for tool_call in (delta.get("tool_calls") or []):
                                if "index" in tool_call:
                                    """for each tool call, we will index into the initial and aggregate args"""
                                    tool_index = tool_call["index"]
                                    if tool_index not in tool_calls:
                                        tool_calls[tool_index] = tool_call
                                    if "function" in tool_call and "arguments" in tool_call["function"]:
                                        if tool_index > len(tool_calls) -1:
                                            raise Exception(f'the index {tool_index} was expected in {tool_calls} but it was not found - {tool_call=} {collected_lines_debug=}')
                                        
                                        tool_calls[tool_index]['function']['arguments'] += tool_call["function"]["arguments"]              
                
                except json.JSONDecodeError:
                     
                    pass  # Handle incomplete JSON chunks
    
    collected_data['choices'][0]['message'] = delta
    """the dict/stack was good for mapping deltas and now we listify the tool calls again"""
    collected_data['choices'][0]['message']['tool_calls'] = list(tool_calls.values())
    collected_data['usage'] = json_data['usage']
    if printer:
        printer('\n')
    return collected_data

def stream_anthropic_response(r, printer=None):
    """stream the response into the anthropic structure we expect but expose a printer
    anthropic uses server side events
    """
    collected_data = None
    tool_args = {}  # {tool_id: {index: aggregated_args}}
    content_text = ""  # To accumulate non-tool content
    input_tokens = 0
    output_tokens = 0
    observed_tool_call = False

    event_type = None 
    content_block_type = None
    index = None
    for line in r.iter_lines():
        if line:
            decoded_line = line.decode("utf-8")
            if decoded_line[:6] == 'event:':
                event_type = decoded_line.replace("event: ", "").strip()
                continue
            else:
                decoded_line = decoded_line.replace("data: ", "").strip()

            if decoded_line and decoded_line != "[DONE]":
                try:
                    json_data = json.loads(decoded_line)
                    event_type = json_data.get("type")                    
                    # Handle message start: Initialize structure from the first message
                    if event_type == "message_start":
                        collected_data = dict(json_data['message'])
                        input_tokens = collected_data['usage']['input_tokens']
    
                    elif event_type == "content_block_start":
                        content_block_type = json_data['content_block']['type']
                        #print(content_block_type)
                        index = json_data['index']
                        if content_block_type == 'tool_use':
                            tool_content = json_data['content_block']
                            tool_content['partial_json'] = ''
                            tool_args[index]  = tool_content
                    # Handle content block deltas with text updates
                    elif event_type == "content_block_delta" and content_block_type != 'tool_use':
                        content_type = json_data["delta"].get("type")
                        if content_type == "text_delta":
                            text = json_data["delta"].get("text", "")
                            content_text += text
                            if printer:
                                printer(text)

                    # Handle tool calls and match args using the index
                    elif event_type == "content_block_delta" and content_block_type == 'tool_use':
                        tool_input = json_data["delta"].get("partial_json")
                        if tool_input:
  
                            """TODO store the aggregated json per tool and add at the end into this structure
                            example
                            {'type': 'tool_use',
                           'id': 'toolu_01GV5rqVypHCQ6Yhrfsz8qhQ',
                           'name': 'get_weather',
                           'input': {'city': 'Paris', 'date': '2024-01-16'}}],
                            """
                            if not tool_args[index]['input']:
                                tool_args[index]['input'] = ''
                            tool_args[index]['input'] += tool_input
                            
                    # Handle message delta and stop reason at the end
                    elif event_type == "message_delta":
                        output_tokens = json_data.get("usage", {}).get("output_tokens", 0)
                        collected_data['stop_reason'] = json_data.get('stop_reason')
                        collected_data['stop_sequence'] = json_data.get('stop_sequence')

                except json.JSONDecodeError:
                    pass  # Handle incomplete JSON chunks

    # Aggregate content and tool calls into the final structure
    collected_data['content'] = [{"type": "text", "text": content_text}, 
                                *list(tool_args.values())]
    # Update usage tokens
    collected_data['usage']['input_tokens'] = input_tokens
    collected_data['usage']['output_tokens'] = output_tokens
    
    return collected_data


def stream_google_response(r, printer=None, relay=None):
    """takes a response from a server side event
    the gemini url for streaming should contain :streamGenerateContent?alt=sse&key=
    Server side events are added and we use a different endpoint
    for example
    https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:streamGenerateContent?alt=sse&key={os.environ.get('GEMINI_API_KEY')}
    """
    current_text_parts = []
    for line in r.iter_lines():
        if line:

            # Each chunk of data is prefixed with 'data: ', so we strip that part which is the SSE header
            line = line.decode("utf-8").strip()
            
            if line.startswith("data: "):
        
                # Remove 'data: ' and parse the JSON
                json_data = json.loads(line[len("data: "):])

                # Extract the text parts from the streamed chunk and also function call args
                candidates = json_data.get("candidates", [])
                for candidate in candidates:
                    parts = candidate.get("content", {}).get("parts", [])
                    for part in parts:
                        text = part.get("text", "")
                        current_text_parts.append(text)
                        if printer:
                            printer(text)

                finish_reason = candidate.get("finishReason")
                if finish_reason == "STOP":
                    break


    return json_data


# This class has been deprecated and replaced by functionality in
# percolate.services.llm.proxy.stream_generators
# 
# For streaming with buffered function calls, see:
# - stream_with_buffered_functions() in proxy.stream_generators
# - request_stream_from_model() in proxy.stream_generators
# - BackgroundAudit in proxy.utils
        
"""some direct calls"""
def request_openai(messages,functions):
    """

    """
    #mm = [_OpenAIMessage.from_message(d) for d in pg.execute(f"""  select * from p8.get_canonical_messages(NULL, '2bc7f694-dd85-11ef-9aff-7606330c2360') """)[0]['messages']]
    #request_openai(mm)
    
    """place all system prompts at the start"""
    
    messages = [m if isinstance(m,dict) else m.model_dump() for m in messages]
    url = "https://api.openai.com/v1/chat/completions"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {os.environ.get('OPENAI_API_KEY')}"
    }

    data = {
        "model": "gpt-4o-mini",
        "messages": messages,
        "tools": functions
    }
    
    return requests.post(url, headers=headers, data=json.dumps(data))

 
def request_anthropic(messages, functions):
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key":  os.environ.get('ANTHROPIC_API_KEY'),
        "anthropic-version": "2023-06-01",
    }
    
    data = {
        "model": "claude-3-5-sonnet-20241022",
        "max_tokens": 1024,
        "messages": [m for m in messages if m['role'] !='system'],
        "tools": functions
    }
    
    system_prompt = [m for m in messages if m['role']=='system']
   
    if system_prompt:
        data['system'] = '\n'.join( item['content'][0]['text'] for item in system_prompt )
    
    return requests.post(url, headers=headers, data=json.dumps(data))

def request_google(messages, functions):
    """
    https://cloud.google.com/vertex-ai/generative-ai/docs/multimodal/function-calling
    
    expected tool call parts [{'functionCall': {'name': 'get_weather', 'args': {'date': '2024-07-27', 'city': 'Paris'}}}]
        
    #get the functions and messages in the correct scheme. the second param in get_tools_by_name takes the scheme
    goo_mm =  [d for d in pg.execute(f" select * from p8.get_google_messages('619857d3-434f-fa51-7c88-6518204974c9') ")[0]['messages']]  
    fns =  [d for d in pg.execute(f" select * from p8.get_tools_by_name(ARRAY['get_pet_findByStatus'],'google') ")[0]['get_tools_by_name']]  
    request_google(goo_mm,fns).json()
    """        
    
    system_prompt = [m for m in messages if m['role']=='system']
    

    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key={os.environ.get('GEMINI_API_KEY')}"
    headers = {
        "Content-Type": "application/json"
    }
    
    """important not to include system prompt - you can get some cryptic messages"""
    data = {
        "contents": [m for m in messages if m['role'] !='system']
    }
     
    if system_prompt:
        data['system_instruction'] = {'parts': {'text': '\n'.join( item['parts'][0]['text'] for item in system_prompt )}}
    
    """i have seen gemini call the tool even when it was the data if this mode is set"""
    if functions:
        data.update(
        #    { "tool_config": {
        #       "function_calling_config": {"mode": "ANY"}
        #     },
            {"tools": functions}
        )
    
    return requests.post(url, headers=headers, data=json.dumps(data))


def sse_openai_compatible_stream_with_tool_call_collapse(response) -> typing.Generator[typing.Tuple[str, dict], None, None]:
    """
    Mimics OpenAI's SSE stream format, except we are collapsing tool_call delta fragments
    into a single delta message once all arguments are collected.

    Streams content-deltas normally, but accumulates tool call fragments
    into a single tool_call delta message keyed by ID.

    When we first receive a tool_call with id, name, and index, we:
    Create a full function call structure {id, type, function: {name, arguments: ""}}.
    Store it in a tool_call_map by id.
    On subsequent deltas:
    We look up tool_call_map[tool_call["id"]] and append to function.arguments.

    Args:
        response: an SSE-style HTTP response using OpenAI's streaming format.
        raw_openai_format: If True, passes through OpenAI's exact SSE chunk format.
    """
    
    tool_call_map: typing.Dict[str, typing.Dict[str, typing.Any]] = {}
    finished_tool_calls = False

    for line in response.iter_lines(decode_unicode=True):
   
        if not line or not line.startswith("data: "):
            continue
    
        raw_data = line[6:].strip()
        if raw_data == "[DONE]":
            break

        try:
            chunk = json.loads(raw_data)
        except json.JSONDecodeError:
            continue  # skip malformed chunk
        
        """in the end there is just usage so break after yield"""            
        
        if chunk.get('usage'):
            yield line, chunk
            continue
        
        choice = chunk["choices"][0]
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason")
        index = choice.get("index", 0)

        if delta.get('content'):
             yield line, chunk

        if "tool_calls" in delta:
            for tool_delta in delta["tool_calls"]:
                if tool_delta.get("id"):
                    """first encounter - send status event immediately"""
                    tool_call_map[tool_delta['index']] = tool_delta
                    
                    # Get function name for the status message
                    function_name = tool_delta.get("function", {}).get("name", "unknown_function")
                    
                    # Instead of status event, send a normal content delta with a message
                    # This will be visible to the user in OpenWebUI
                    status_delta = {
                        "id": str(uuid.uuid4()),
                        "object": "chat.completion.chunk",
                        "choices": [{
                            "index": 0,
                            "delta": {"content": f"\n\n🔍 Using function `{function_name}` to answer your question...\n\n"},
                            "finish_reason": None
                        }]
                    }
                    status_event = f'data: {json.dumps(status_delta)}\n\n'
                    
                    # Comment out the original status event code for potential future use
                    # ---------------------------------------------------------
                    # # First send a newline to flush any previous data
                    # yield "\n", {"status": "flush"}
                    # 
                    # # Then send the actual status message
                    # status_message = {
                    #     "status": f"Preparing to call function: {function_name}...",
                    #     # Add a timestamp to ensure clients recognize this as a new message
                    #     "timestamp": time.time()
                    # }
                    # # Ensure status_event is a properly formatted string (not bytes)
                    # status_event = f'data: {json.dumps(status_message)}\n\n'
                    # # Note: We intentionally don't encode here - the caller will handle encoding
                    # yield status_event, {"status": "function_call_started"}
                    # ---------------------------------------------------------
                    
                    # Send the content delta instead of status message
                    yield status_event, {"content": f"Calling function: {function_name}"}
                else:
                    t = tool_call_map[tool_delta['index']] 
                    t["function"]["arguments"] += tool_delta["function"]["arguments"]

        elif finish_reason == "tool_calls" and not finished_tool_calls:
            finished_tool_calls = True
            full_tool_calls = list(tool_call_map.values())

            # Consolidate all accumulated tool call fragments into one delta
            consolidated_chunk = {
                "choices": [
                    {
                        "delta": {"tool_calls": full_tool_calls},
                        "index": index,
                        "finish_reason": "tool_calls",
                        "role": "assistant"
                    }
                ]
            }


            yield line, consolidated_chunk

        elif finish_reason == "stop":
            yield line, chunk

 
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
    def __init__(self, g, context=None, scheme:str='openai', user_query:str=None, audit_on_flush:bool=False):
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
        
    """return the response object """
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
                if isinstance(item, str) and item.strip() == 'data: [DONE]':
                    done_marker_seen = True
                
                # Collect the tool call responses and emit status messages about them
                if isinstance(item, AIResponse):
                    self.ai_responses.append(item)
                    
                    # Debug log to understand what's in the AIResponse
                    logger.debug(f"AIResponse received: {type(item)}")
                    if hasattr(item, 'tool_calls'):
                        logger.debug(f"tool_calls: {item.tool_calls}")
                    if hasattr(item, 'status'):
                        logger.debug(f"status: {item.status}")
                    if hasattr(item, 'content'):
                        logger.debug(f"content preview: {item.content[:100] if item.content else 'None'}")
                    
                    # Function calls are now detected much earlier in the stream process
                    # We still need to yield the AIResponse for auditing, but we don't need to send
                    # another status message to the client since we already sent one
                    continue
                    
                try:
                    for piece in _parse_open_ai_response(item):
                        self._content += piece
                    
                    # Try to extract tool calls and finish reason
                    try:
                        if isinstance(item, str):
                            try:
                                data = json.loads(item[6:])
                            except:
                                # If this is the [DONE] marker, continue
                                if item.strip() == 'data: [DONE]':
                                    done_marker_seen = True
                                    continue
                                data = None
                        else:
                            data = item
                        
                        if not data:
                            continue
                            
                        # Extract usage information
                        if "usage" in data:
                            self._usage = data["usage"]
                        
                        # Extract tool calls and check for finish_reason
                        if "choices" in data and data["choices"]:
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
                                            
                                            # Get function name
                                            function_name = tool_call.get("function", {}).get("name", "unknown_function")
                                            
                                            # Instead of status event, send a normal content delta with a message
                                            # This will be visible to the user in OpenWebUI
                                            status_delta = {
                                                "id": str(uuid.uuid4()),
                                                "object": "chat.completion.chunk",
                                                "choices": [{
                                                    "index": 0,
                                                    "delta": {"content": f"\n\n🔍 Using function: `{function_name}` to answer your question...\n\n"},
                                                    "finish_reason": None
                                                }]
                                            }
                                            
                                            # Comment out the original status event code for potential future use
                                            # ---------------------------------------------------------
                                            # # First send a newline to flush any previous data
                                            # yield "\n", {"status": "flush"}
                                            # 
                                            # # Then send the actual status message
                                            # status_message = {
                                            #     "status": f"Preparing to call function: {function_name}...",
                                            #     # Add a timestamp to ensure clients recognize this as a new message
                                            #     "timestamp": time.time()
                                            # }
                                            # # Ensure status_event is a properly formatted string (not bytes)
                                            # status_event = f'data: {json.dumps(status_message)}\n\n'
                                            # yield status_event, {"status": "function_call_started"}
                                            # ---------------------------------------------------------
                                            
                                            # Send the content delta instead
                                            yield f'data: {json.dumps(status_delta)}\n\n'.encode('utf-8')
                    except Exception:
                        pass
                except Exception:
                    pass
                
                # Handle both string and bytes items
                if isinstance(item, str):
                    yield item.encode('utf-8')
                else:
                    yield item
            
        except Exception as e:
            logger.error(f"Error during streaming: {str(e)}")
            
        finally:
            self._is_consumed = True
            
            # Send finish_reason "stop" if we haven't seen a finish_reason yet
            if not finish_reason_seen:
                finish_chunk = f'data: {{"id":"{uuid.uuid4()}","object":"chat.completion.chunk","choices":[{{"index":0,"delta":{{}},"finish_reason":"stop"}}]}}\n\n'
                yield finish_chunk.encode('utf-8')
                
            # Always send a [DONE] marker at the end if we haven't seen one yet
            # This ensures OpenWebUI knows the stream is complete
            if not done_marker_seen:
                done_marker = 'data: [DONE]\n\n'
                yield done_marker.encode('utf-8')
            
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
            
            logger.info(f"Auditing stream response, content length: {len(self._content)}")
            
            # Make sure context has a session_id
            if self.context and not getattr(self.context, 'session_id', None):
                self.context.session_id = str(uuid.uuid4())
                logger.debug(f"Generated new session_id for audit: {self.context.session_id}")
            
            # Use the more comprehensive audit_response_for_user method
            audit_response_for_user(
                response=self,
                context=self.context,
                query=self.user_query
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
            raise Exception(f"You are trying to read content from an unconsumed iterator - you must iterate iter_lines first")
        return self._content
    
    @property
    def usage(self):
        """
        Return token usage (prompt_tokens, completion_tokens, total_tokens) from the final SSE chunk.
        Must be accessed after iter_lines() has been fully consumed.
        """
        if not self._is_consumed:
            raise Exception("You must fully consume iter_lines() before accessing usage")
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
            
def print_openai_delta_content(json_data):
    """
    Safely parses the given JSON (string or dict) and prints any
    'content' values found under choices[].delta.
    this is a convenience for printing and testing delta chunks
    """
    for content in _parse_open_ai_response(json_data):
        print(content,end='')