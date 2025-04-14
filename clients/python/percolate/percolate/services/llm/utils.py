"""some simple streaming adapters
these have not been well tested for all cases but for function calling and simple text content they work.

"""
import requests
import json
import os

def stream_openai_response(r, printer=None):
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
                            for tool_call in delta["tool_calls"]:
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


def stream_google_response(r, printer=None):
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

