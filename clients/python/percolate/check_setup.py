# +

import percolate as p8
from percolate.models.p8 import PercolateAgent
from percolate.services.llm import CallingContext

def printer(text):
    """streaming output"""
    print(text, end="", flush=True)  
    if text == None:
        print('')



from percolate.api.routes.chat.router import completions, CompletionsRequestOpenApiFormat

from fastapi.testclient import TestClient
from percolate.api.main import app

client = TestClient(app)
# -

# ## Test calling the simple models in the Open AI Dialect

# +
OPENAI_TEST_REQUEST = {
    "model": "gpt-4o-mini",
    "prompt": "What is the capital of ireland",
    "max_tokens": 50,
    "temperature": 0.7,
    "stream": False
}

c = CompletionsRequestOpenApiFormat(**OPENAI_TEST_REQUEST)
r = client.post('/chat/completions', json=c.model_dump())
r.json()

# +
CLAUDE_TEST_REQUEST = {
    "model": "claude-3-5-sonnet-20241022",
    "prompt": "What is the capital of ireland",
    "max_tokens": 50,
    "temperature": 0.7,
    "stream": False
}

c = CompletionsRequestOpenApiFormat(**CLAUDE_TEST_REQUEST)
r = client.post('/chat/completions', json=c.model_dump())
r.json()

# +
CLAUDE_TEST_REQUEST = {
    "model": "gemini-1.5-flash",
    "prompt": "What is the capital of ireland",
    "max_tokens": 50,
    "temperature": 0.7,
    "stream": False
}

c = CompletionsRequestOpenApiFormat(**CLAUDE_TEST_REQUEST)
r = client.post('/chat/completions', json=c.model_dump())
r.json()
# -


# ## Now try streaming

# +
import requests
import json

# Define the request parameters
url = "http://localhost:5009/chat/completions"  # Adjust if needed
headers = {"Content-Type": "application/json"}
payload = {
  "model": "gpt-4o-mini",
  "prompt": "what are the capital of ireland and france and south korea. do not use tools",
  "max_tokens": 50,
  "temperature": 0.7,
  "stream": True
}

#testing actual
response = requests.post(url, json=payload, headers=headers, stream=True)
    
#c = CompletionsRequestOpenApiFormat(**payload)
#with client.stream("POST", '/chat/completions', json=c.model_dump()) as response:


for chunk in response.iter_lines():
    if chunk:
#         print(chunk)
#         print('---')
        decoded = chunk.decode('utf-8')
        try:
            decoded = json.loads(decoded[6:]) if  decoded[6] == '{' else None 
            #print(decoded)
            if decoded and decoded['choices']:
                decoded = decoded['choices'][0]['delta']
                if 'content' in decoded:
                    decoded = decoded['content']
                    print(f"{decoded}",end='')
        except Exception as ex:
            raise
            
            


# +
# Define the request parameters
url = "http://localhost:5009/chat/completions"  # Adjust if needed
headers = {"Content-Type": "application/json"}
payload = {
  "model": "claude-3-5-sonnet-20241022",
  "prompt": "what are the capital of ireland and france and south korea. do not use tools",
  "max_tokens": 100,
  "temperature": 0.7,
  "stream": True
}

 
response = requests.post(url, json=payload, headers=headers, stream=True)    
 
for chunk in response.iter_lines():
    if chunk:
        decoded = chunk.decode('utf-8')
   
        decoded = json.loads(decoded[6:]) if  decoded[6] == '{' else None 
        if decoded and decoded['choices']:
            decoded = decoded['choices'][0]['delta']
            if 'content' in decoded:
                decoded = decoded['content']
                print(f"{decoded}",end='')



# +
# Define the request parameters
url = "http://localhost:5009/chat/completions"  # Adjust if needed
headers = {"Content-Type": "application/json"}
payload = {
  "model": "gemini-1.5-flash",
  #"prompt": "what are the capital of ireland and france and south korea. do not use tools",
    "prompt": "please tell me a short story",
  "max_tokens": 100,
  "temperature": 0.7,
  "stream": True
}

 
response = requests.post(url, json=payload, headers=headers, stream=True)
 
for chunk in response.iter_lines():
    if chunk:
        decoded = chunk.decode('utf-8')
   
        decoded = json.loads(decoded[6:]) if  decoded[6] == '{' else None 
        if decoded and decoded['choices']:
            decoded = decoded['choices'][0]['delta']
            if 'content' in decoded:
                decoded = decoded['content']
                print(f"{decoded}",end='')

# -

# ## Now try function calling

# +
 

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
                #print(decoded)
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
#_example_parse_tools_or_content_canonical(model='gemini-1.5-flash')
_example_parse_tools_or_content_canonical(model="claude-3-5-sonnet-20241022")

# -




