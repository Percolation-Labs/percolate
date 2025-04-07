# +

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
  "prompt": "tell me a short story?",
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
        print(chunk)
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
  "model": "claude-3-5-sonnet-20241022",
  "prompt": "tell me a short story?",
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
        decoded = chunk.decode('utf-8')
        print(decoded)
        decoded = json.loads(decoded[6:]) if  decoded[6] == '{' else None 
        if decoded and decoded['choices']:
            decoded = decoded['choices'][0]['delta']
            if 'content' in decoded:
                decoded = decoded['content']
                print(f"{decoded}",end='')

    
# -

# ## Now try function calling
