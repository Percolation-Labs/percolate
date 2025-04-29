"""some simple streaming adapters
these have not been well tested for all cases but for function calling and simple text content they work.

"""
import requests
import json
import os
import base64
import io
import typing
from . import FunctionCall
from percolate.models.p8 import AIResponse

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
    from .LanguageModel import try_get_open_ai_key

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
    """stream the response into the expected structure but expose a printer"""
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


class HybridResponse:
    """
    HybridResponse wraps a streaming LLM HTTP response to buffer function (tool) calls
    while streaming non-function content as Server-Sent Events (SSE).

    Attributes:
        _response: The underlying HTTP response object with an iter_lines() method.
        _tool_calls: List[FunctionCall] buffered during streaming.
        _content: str concatenated text content from the stream.
    """
    def __init__(self, response):
        """
        Initialize a HybridResponse.

        Args:
            response: HTTP response object with a .iter_lines() method (e.g., requests.Response).
        """
        self._response = response
        # Buffer for SSE-formatted event strings
        self._buffered_lines: list[str] = []
        # Flag indicating whether the response stream is fully consumed and buffered
        self._buffering_done: bool = False
        # Buffered list of FunctionCall objects
        self._tool_calls: list[FunctionCall] = []
        # Accumulated text content
        self._content: str = ""
        # Metadata for building final AIResponse
        self._id: typing.Optional[str] = None
        self._model: typing.Optional[str] = None
        self._usage: typing.Optional[dict] = None
        self._role: typing.Optional[str] = None

    def iter_lines(self, emit_function_events: bool = False, printer=None):
        """
        Iterate over the streaming response, yielding SSE-formatted lines for text content.
        Function calls are buffered internally. Optionally emits SSE events for function calls.

        Args:
            emit_function_events (bool): If True, emits an SSE event of type "function_call"
                when a function call is encountered.
            printer (callable): Optional callback to receive raw text chunks as they arrive.

        Yields:
            str: SSE-formatted event string (ending with a blank line).
        """
        # If buffering is complete, replay cached SSE events
        if self._buffering_done:
            for sse_line in self._buffered_lines:
                yield sse_line
            return
        # Stream for the first time: consume HTTP response, buffer, and yield
        for raw_line in self._response.iter_lines():
            if not raw_line:
                continue
            # Decode bytes to string
            try:
                line = raw_line.decode("utf-8").strip()
            except Exception:
                # Non-UTF8 or binary content, pass through raw
                yield raw_line
                continue
            # Strip SSE "data:" prefix if present
            if line.startswith("data:"):
                line = line[len("data:"):].strip()
            # Skip empty or terminator lines
            if not line or line == "[DONE]":
                continue
            # Try to parse JSON payload
            try:
                payload = json.loads(line)
                # Capture metadata from JSON chunks if present
                if 'id' in payload:
                    self._id = payload.get('id') or self._id
                if 'model' in payload:
                    self._model = payload.get('model') or self._model
                if 'usage' in payload:
                    self._usage = payload.get('usage')
            except json.JSONDecodeError:
                # Not JSON, emit as raw data event
                sse_line = f"data: {line}\n\n"
                self._buffered_lines.append(sse_line)
                yield sse_line
                if printer:
                    printer(line)
                continue
            # Handle OpenAI-style response with 'choices'
            if "choices" in payload and payload["choices"]:
                delta = payload["choices"][0].get("delta", {})
                # Capture role from delta if present
                if 'role' in delta:
                    self._role = delta.get('role')
                # Detect OpenAI-style function_call in delta (name + argument fragments)
                # if "function_call" in delta and delta["function_call"]:
                #     fc = delta["function_call"]
                #     # Buffer each fragment: name or arguments string
                #     func_call = FunctionCall(
                #         name=fc.get("name", "") or "",
                #         arguments=fc.get("arguments", {}) or "",
                #         id=fc.get("id", "") or "",
                #         scheme=None,
                #     )
                #     self._tool_calls.append(func_call)
                #     # Optionally emit an SSE event for the function call fragment
                #     if emit_function_events:
                #         sse_line = f"event: function_call\n" + f"data: {func_call.json()}\n\n"
                #         self._buffered_lines.append(sse_line)
                #         yield sse_line
                #     continue
                # Detect alternative 'tool_calls' array in delta
                if "tool_calls" in delta and delta["tool_calls"]:
                    for call in delta.get("tool_calls"):
                        fn = call.get("function", {})
                        func_call = FunctionCall(
                            name=fn.get("name", ""),
                            arguments=fn.get("arguments") or {},
                            id=call.get("id", ""),
                            scheme=None,
                        )
                        self._tool_calls.append(func_call)
                        if emit_function_events:
                            sse_line = f"event: function_call\n" + f"data: {func_call.json()}\n\n"
                            self._buffered_lines.append(sse_line)
                            yield sse_line
                    # skip streaming this chunk as text
                    continue
                # Detect text content in delta
                text = delta.get("content")
                if text:
                    # Buffer and stream text content
                    self._content += text
                    sse_line = f"data: {text}\n\n"
                    self._buffered_lines.append(sse_line)
                    yield sse_line
                    if printer:
                        printer(text)
                    continue
            # Fallback: unknown JSON payload
            sse_line = f"data: {json.dumps(payload)}\n\n"
            self._buffered_lines.append(sse_line)
            yield sse_line
            if printer:
                printer(json.dumps(payload))
        # End of stream: emit done event
        done_event = "event: done\n\n"
        self._buffered_lines.append(done_event)
        yield done_event
        # Mark buffering complete for future replay
        self._buffering_done = True

    @property
    def tool_calls(self) -> list[FunctionCall]:
        """
        Get the list of buffered function/tool calls, merging any partial
        fragments from both OpenAI-style `function_call` and alternative
        `tool_calls` delta formats into complete calls with full arguments.

        Returns:
            List[FunctionCall]: Complete function call objects.
        """
        # Ensure the stream is consumed before returning calls
        if not self._buffering_done:
            for _ in self.iter_lines():
                pass
        merged_calls: list[FunctionCall] = []
        last_name: str | None = None
        last_id: str = ''
        args_buffer: dict = {}
        args_str: str = ''
        for fc in self._tool_calls:
            # Detect start of a new call (name provided)
            if fc.name:
                # Flush previous call if exists
                if last_name is not None:
                    final_args = args_buffer.copy()
                    # Parse any accumulated JSON string fragments
                    if args_str:
                        try:
                            parsed = json.loads(args_str)
                            if isinstance(parsed, dict):
                                final_args.update(parsed)
                        except Exception:
                            pass
                    merged_calls.append(
                        FunctionCall(name=last_name, arguments=final_args, id=last_id, scheme=fc.scheme)
                    )
                # Start buffering a new call
                last_name = fc.name
                last_id = fc.id or ''
                args_buffer = {}
                args_str = ''
            # Merge dict arguments
            if isinstance(fc.arguments, dict) and fc.arguments:
                args_buffer.update(fc.arguments)
            # Accumulate string fragments
            elif isinstance(fc.arguments, str) and fc.arguments:
                args_str += fc.arguments
        # Flush final call if present
        if last_name is not None:
            final_args = args_buffer.copy()
            if args_str:
                try:
                    parsed = json.loads(args_str)
                    if isinstance(parsed, dict):
                        final_args.update(parsed)
                except Exception:
                    pass
            merged_calls.append(
                FunctionCall(name=last_name, arguments=final_args, id=last_id, scheme=None)
            )
        return merged_calls

    @property
    def content(self) -> str:
        """
        Get the concatenated text content from the stream.

        Returns:
            str: Aggregated text content.
        """
        # Ensure the stream is consumed before returning content
        if not self._buffering_done:
            for _ in self.iter_lines():
                pass
        return self._content
    
    def to_ai_response(self, session_id: typing.Optional[str] = None) -> AIResponse:
        """
        Convert buffered stream into a structured AIResponse without extra LLM calls.

        Args:
            session_id (str): Optional session ID to attach.

        Returns:
            AIResponse: Parsed response with content, usage, and tool_calls.
        """
        # Build a minimal OpenAI-style response dict
        resp = {
            'choices': [{
                'message': {
                    'role': self._role or 'assistant',
                    'content': self._content,
                    'tool_calls': [fc.model_dump() for fc in self.tool_calls]
                }
            }],
            'usage': self._usage or {},
            'model': self._model or ''
        }
        # Use the AIResponse factory to parse it
        return AIResponse.from_open_ai_response(resp, session_id)
    
    @staticmethod
    # Example helper: stream until a function call is encountered, notify user, and expose the call for inspection
    def stream_with_inspection(response, printer=None):  # noqa: E302
        """
        Stream non-function content normally, and when a function call is detected,
        emit a generic notification to the user and return the HybridResponse
        for later inspection of tool_calls.

        Usage:
            # response: requests.Response with stream=True
            hr = stream_with_inspection(response, printer=send_sse)
            # at this point hr.tool_calls contains any FunctionCall objects

        Args:
            response: HTTP response object with .iter_lines()
            printer: Optional callable(str) to receive SSE-formatted lines.

        Returns:
            HybridResponse: buffered response with content and tool_calls available.
        """
        hr = HybridResponse(response)
        # Stream with function events enabled to catch the first function_call
        for sse in hr.iter_lines(emit_function_events=True, printer=printer):
            # Detect the SSE event for function_call
            if sse.startswith("event: function_call"):
                # Notify user with a generic message
                note = "data: I'm looking into it\n\n"
                if printer:
                    printer(note)
                break
            # Relay normal SSE lines
            if printer:
                printer(sse)
            else:
                yield sse
        # Return HybridResponse so caller can inspect hr.tool_calls
        return hr
    


 
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

 

def build_full_tool_call_message(delta_chunk):
    """
    Converts a streaming-style delta chunk with 'tool_calls'
    into a full non-streaming assistant message.
    """

    choice = delta_chunk["choices"][0]
    index = choice.get("index", 0)
    tool_calls = choice["delta"].get("tool_calls", [])
    
    return {
        "choices": [
            {
                "index": index,
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": tool_calls
                },
                "finish_reason": choice.get("finish_reason", "tool_calls")
            }
        ]
    }

def sse_openai_compatible_stream_with_tool_call_collapse(response) -> typing.Generator[typing.Dict[str, typing.Any], None, None]:
    """
    Mimics OpenAI's SSE stream format, collapsing tool_call delta fragments
    into a single delta message once all arguments are collected.

    Streams content deltas normally, but accumulates tool call fragments
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

        choice = chunk["choices"][0]
        delta = choice.get("delta", {})
        finish_reason = choice.get("finish_reason")
        index = choice.get("index", 0)

        #print(chunk)
    
        # Stream normal assistant content
        if  delta.get('content'):
             yield line, chunk

        # Handle tool_call deltas
        if "tool_calls" in delta:
            for tool_delta in delta["tool_calls"]:
                if tool_delta.get("id"):
                    """first encounter"""
                    tool_call_map[tool_delta['index']] = tool_delta
                else:
                    t = tool_call_map[tool_delta['index']] 
                    t["function"]["arguments"] += tool_delta["function"]["arguments"]

        # Emit combined tool_calls when model is done
        elif finish_reason == "tool_calls" and not finished_tool_calls:
            finished_tool_calls = True
            full_tool_calls = list(tool_call_map.values())

            consolidated_chunk = {
                "choices": [
                    {
                        "delta": {
                            "tool_calls": full_tool_calls
                        },
                        "index": index,
                        "finish_reason": "tool_calls",
                        'role': 'assistant'
                    }
                ]
            }

            yield line, consolidated_chunk 

        # Emit final stop message
        elif finish_reason == "stop":
            yield line, chunk


def print_openai_delta_content(json_data):
    """
    Safely parses the given JSON (string or dict) and prints any
    'content' values found under choices[].delta.
    this is a convenience for printing and testing delta chunks
    """
    
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
            print(content,end='')