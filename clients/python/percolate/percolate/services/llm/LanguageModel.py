"""wrap all language model apis - use REST direct to avoid deps in the library"""

import requests
import json
import os
import typing
from .CallingContext import CallingContext
from percolate.models import MessageStack
from percolate.services import PostgresService
from percolate.models.p8 import AIResponse
import uuid
from percolate.utils import logger

# return AIResponse(model_name=self.model_name,
#                 tokens_in=tokens_in,
#                 tokens_out=tokens_out,
#                 session_id=context.session_id,
#                 content=content,
#                 status=status,
#                 tool_calls=tool_calls)

class OpenAIResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str)->AIResponse:
        """
        """
        choice = response['choices'][0]
        tool_calls = []
        return AIResponse(id = str(uuid.uuid1()),
                model_name=response['model'],
                tokens_in=response['usage']['prompt_tokens'],
                tokens_out=response['usage']['completion_tokens'],
                session_id=sid,
                role=choice['message']['role'],
                content=choice['message']['content'],
                status='RESPONSE' if not tool_calls else "TOOL_CALLS",
                tool_calls=tool_calls)
        
class AnthropicAIResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str)->AIResponse:
        return 
class GoogleResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str)->AIResponse:
        return 

class LanguageModel:
    """the simplest language model wrapper we can make"""
    def __init__(self, model_name:str):
        """"""
        self.model_name = model_name
        self.db = PostgresService()
        #TODO we can use a cache for this in future
        self.params = self.db.execute('select * from p8."LanguageModelApi" where name = %s ', (model_name,))[0]
        
    def parse(self, response, context: CallingContext=None) -> AIResponse:
        """the llm response form openai or other schemes must be parsed into a dialogue.
        this is also done inside the database and here we replicate the interface before dumping and returning to the executor
        """
        try:
            status = response.status_code
            """check http codes TODO - if there is an error then we can return an error AIResponse"""
            response = response.json()
            
            """check the HTTP response first"""
            if self.params.get('scheme') == 'google':
                return GoogleResponseScheme.parse(response, sid=context.session_id)
            if self.params.get('scheme') == 'anthropic':
                return AnthropicAIResponseScheme.parse(response,sid=context.session_id)
            return OpenAIResponseScheme.parse(response,sid=context.session_id)
        except Exception as ex:
            logger.warning(f"failing to parse {response=}")
        
    def __call__(self, messages: MessageStack, functions: typing.List[dict], context: CallingContext=None ) -> AIResponse:
        """call the language model with the message stack and functions"""
        response = self._call_raw(messages=messages, functions=functions)
        """for consistency with DB we should audit here and also format the message the same with tool calls etc."""
        response = self.parse(response,context=context)
        #self.db.repository(AIResponse).update_records(response)
        return response
    
        
    def _call_raw(self, messages: MessageStack, functions: typing.List[dict]):
         """the raw api call exists for testing - normally for consistency with the database we use a different interface"""
         return self.call_api_simple(messages.question, 
                                    functions=functions,
                                    system_prompt=messages.system_prompt, 
                                    data_content=messages.data)

    @classmethod 
    def from_context(cls, context: CallingContext) -> "LanguageModel":
        return LanguageModel(model_name=context.model)
    
      
    def _elevate_functions_to_tools(self, functions: typing.List[dict]):
        """slightly different dialect of function wrapper"""
        return 
          
    def _adapt_tools_for_anthropic(self, functions: typing.List[dict]):
        """slightly different dialect of function wrapper"""
        return 
    
    def call_api_simple(self, 
                        question:str, 
                        functions: typing.List[dict], 
                        system_prompt:str=None, 
                        data_content:typing.List[dict]=None,
                        is_streaming:bool = False,
                        temperature: float = 0.01,
                        streaming_callback : typing.Callable = None,
                        **kwargs):
        """
        Simple REST wrapper to use with any language model
        """
        
        """select this from the database or other lookup
        e.g. db.execute('select * from "LanguageModelApi" where name = %s ', ('gpt-4o-mini',))[0]
        """
        params = self.params
        data_content = data_content = []
        
        """we may need to adapt this e.g. for the open ai scheme"""
        tools = functions
        
        url = params["completions_uri"]
        token = os.environ.get(params['token_env_key'])
        headers = {
            "Content-Type": "application/json",
        }
        if params['scheme'] == 'openai':
            headers["Authorization"] = f"Bearer {token}"
            tools = self._elevate_functions_to_tools(functions)
        if params['scheme'] == 'anthropic':
            headers["x-api-key"] =   token
            headers["anthropic-version"] = self.params.get('anthropic-version', "2023-06-01")
            tools = self._adapt_tools_for_anthropic(functions)
        if params['scheme'] == 'google':
            url = f"{url}?key={token}"
        data = {
            "model": params['model'],
            "messages": [
                *[{'role': 'system', 'content': s} for s in [system_prompt] if s],
                {"role": "user", "content": question},
                #add in any data content into the stack for arbitrary models
                *data_content
            ],
            "tools": tools  
        }
        if params['scheme'] == 'anthropic':
            data["max_tokens"] = kwargs.get('max_tokens',-1)
        if params['scheme'] == 'google':
            data = {
                "contents": [
                    {"role": "user", "parts": {'text': question}},
                    #add in any data content into the stack for google
                    *[ {"role": dc['role'], "parts": {'text': dc['content']}} for dc in data_content]
                ],
                "tool_config": {
                    #we could disable this for empty tools
                    "function_calling_config": {"mode": "ANY"}
                },
                "tools": [{'function_declarations': tools}]
            }
        
        return requests.post(url, headers=headers, data=json.dumps(data))
        
    