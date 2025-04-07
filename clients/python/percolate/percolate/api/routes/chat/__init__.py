from .router import router


 
 

def _example_parse_tools_or_content_canonical(question:str="What's the weather like in Paris (france) today? - trust the function and call without asking the user",
                                            url = "http://localhost:5009/chat/completions",
                                            model = "gemini-1.5-flash"  ):
    
    """
    This function is docs by example: 
    this is a helper snippet for making sure we can parse content or functions 
    if you ask a question that does not need a function like the capital of ireland, you can see the printed content
    if you ask about the weather in paris, the tool is used and the call is returned in a dictionary of indexed tool calls
    
    """
    import requests
    import json
 
    headers = {"Content-Type": "application/json"}
    payload = {
            "model":model,  
            "prompt": question,
            "max_tokens": 100,
            "temperature": 0.7,
            "stream": True,   
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
                                    "description": "The city "
                                },
                                 
                            },
                            "required": ["location"]
                        }
                    }
                }
            ]
        }

    response = requests.post(url, json=payload, headers=headers, stream=True)
    functions = {}
    for chunk in response.iter_lines():
        if chunk:
            decoded = chunk.decode('utf-8')
            
            decoded = json.loads(decoded[6:]) if  decoded[6] == '{' else None 
            if decoded and decoded['choices']:
                decoded = decoded['choices'][0]['delta']
                if decoded and 'content' in decoded:
                    decoded_content = decoded['content']
                    if decoded_content:
                        print(f"{decoded_content}",end='')
                if decoded and decoded.get('tool_calls'):
                    for t in decoded['tool_calls']:
                        fn = t['index']
                        if fn not in functions:
                            functions[fn] = ''
                        functions[fn]+= t['function']['arguments']
                    decoded = decoded['tool_calls']    
    return functions


##_example_parse_tools_or_content_canonical(model='gemini-1.5-flash')
##_example_parse_tools_or_content_canonical(model="claude-3-5-sonnet-20241022")