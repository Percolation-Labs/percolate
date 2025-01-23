"""although percolate will push the database use case, we can use llms in the app tier"""


import requests
import json
import os
import typing

def call_api_simple(question:str, tools: typing.List[dict], model:str, system_prompt:str=None):
    """
    ill ignore the system prompt for simplicity here but add it as a reminder to signature
    ill also assume successful response
    Ill also hard code some things
    """
    
    """select this from the database or other lookup
    e.g. db.execute('select * from "LanguageModelApi" where name = %s ', ('gpt-4o-mini',))[0]
    """
    #
    db = None
    params = db.execute('select * from "LanguageModelApi" where name = %s ', (model,))[0]
    print(params)
    url = params["completions_uri"]
    token = os.environ.get(params['token_env_key'])
    headers = {
        "Content-Type": "application/json",
    }
    if params['scheme'] == 'openai':
        headers["Authorization"] = f"Bearer {token}"
    if params['scheme'] == 'anthropic':
        headers["x-api-key"] =   token
        headers["anthropic-version"] = "2023-06-01"
    if params['scheme'] == 'google':
        url = f"{url}?key={token}"
        print(url)
    data = {
        "model": params['model'],
        "messages": [
            {"role": "user", "content": question}
        ],
        "tools": tools  
    }
    if params['scheme'] == 'anthropic':
        data["max_tokens"] = 1024
    if params['scheme'] == 'google':
        data = {
            "contents": [
                {"role": "user", "parts": {'text': question}}
            ],
            "tool_config": {
              "function_calling_config": {"mode": "ANY"}
            },
            "tools": [{'function_declarations': tools}]
        }
    
    r = requests.post(url, headers=headers, data=json.dumps(data))
    return r.json()
