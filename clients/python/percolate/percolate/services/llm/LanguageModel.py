"""wrap all language model apis - use REST direct to avoid deps in the library
This is a first fraft - will map this to lean more on the database model 
"""

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
import traceback
from .MessageStackFormatter import MessageStackFormatter

ANTHROPIC_MAX_TOKENS_IN = 8192
GENERIC_P8_PROMPT = """\n# General Advice.
Use whatever functions are available to you and use world knowledge only if prompted 
or if there is not other way 
or the user is obviously asking about real world information that is not covered by functions.
Observe what functions you have to use and check the message history to avoid calling the same functions with the same parameters repeatedly.
If you find a function name in your search, you can activate it by naming using one of your functions. You should do so without asking the user.
            """
class OpenAIResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str,  model_name:str)->AIResponse:
        """
        
        example tool call response
        ```
        'tool_calls': [{'id': 'call_0KPgsQaaso8IXPUpG6ktM1DC',
        'type': 'function',
        'function': {'name': 'get_weather',
            'arguments': '{"city":"Dublin","date":"2023-10-07"}'}}],
        ```
        """
        try:
            if response.get('error'):
                logger.warning(f"Error response {response['error'].get('message')}")
                return AIResponse(id = str(uuid.uuid1()),model_name=model_name, tokens_in=0,tokens_out=0, role='assistant',
                                  session_id=sid, content=response['error'].get('message'), status = 'ERROR')
            choice = response['choices'][0]
            tool_calls = choice['message'].get('tool_calls') or []
            
            def adapt(t):
                """we want something we can call and also something to construct the message that is needed for the tool call"""
                f = t['function']
                return   {'name': f['name'], 'arguments':f['arguments'], 'id': t['id']} 
            
            tool_calls = [adapt(t) for t in tool_calls]
            return AIResponse(id = str(uuid.uuid1()),
                    model_name=response['model'],
                    tokens_in=response['usage']['prompt_tokens'],
                    tokens_out=response['usage']['completion_tokens'],
                    session_id=sid,
                    verbatim=choice['message'],
                    role=choice['message']['role'],
                    content=choice['message'].get('content') or '',
                    status='RESPONSE' if not tool_calls else "TOOL_CALLS",
                    tool_calls=tool_calls)
        except Exception as ex:
            logger.warning(f"unexpected structure in OpenAI scheme message {response=} - caused the error {ex}")
            raise 
                    
class AnthropicAIResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str,  model_name:str )->AIResponse:
        choice = response['content'] 
        def adapt(t):
            """anthropic map to our interface"""
            return {'name': t['name'], 'arguments':t['input'], 'id': t['id'], 'scheme': 'anthropic'}
        verbatim = [t for t in choice if t['type'] == 'tool_use']
        tool_calls = [adapt(t) for t in verbatim]
        if verbatim:
            """when tools are used we need a verbatim message with tool call??"""
            verbatim = {
                'role': response['role'],
                'content': response['content']
            }
        
        content = "\n".join([t['text'] for t in choice if t['type'] == 'text']) 
        return AIResponse(id = str(uuid.uuid1()),
                model_name=response['model'],
                tokens_in=response['usage']['input_tokens'],
                tokens_out=response['usage']['output_tokens'],
                session_id=sid,
                role=response['role'],
                content=content or '',
                verbatim=verbatim ,
                status='RESPONSE' if not tool_calls else "TOOL_CALLS",
                tool_calls=tool_calls)
        
class GoogleAIResponseScheme(AIResponse):
    @classmethod
    def parse(cls, response:dict, sid: str, model_name:str)->AIResponse:
        message = response['candidates'][0]['content']
        choice = message['parts']
        content_elements = [p['text'] for p in choice if p.get('text')]
        def adapt(t):
            return {'function': {'name': t['name'], 'arguments':t['args'], 'id': t['name'],'scheme': 'google'}}
        tool_calls = [adapt(p['functionCall']) for p in choice if p.get('functionCall')]
        tool_calls = [t['function'] for t in tool_calls]
        return AIResponse(id = str(uuid.uuid1()),
                model_name=model_name, #does not seem to return it which is fair
                tokens_in=response['usageMetadata']['promptTokenCount'],
                tokens_out=response['usageMetadata']['candidatesTokenCount'],
                session_id=sid,
                role=message['role'],
                content=',\n'.join(content_elements),
                verbatim=message if tool_calls else None,
                status='RESPONSE' if not tool_calls else "TOOL_CALLS",
                tool_calls=tool_calls)

class LanguageModel:
    """the simplest language model wrapper we can make"""
    def __init__(self, model_name:str):
        """"""
        self.model_name = model_name
        self.db = PostgresService()
        #TODO we can use a cache for this in future
        self.params = self.db.execute('select * from p8."LanguageModelApi" where name = %s ', (model_name,))
        if not self.params:
            raise Exception(f"The model {model_name} does not exist in the Percolate settings")
        self.params = self.params[0]
        if not self.params['token']:
            """if the token is not stored in the database we use whatever token env key to try and load it from environment"""
            self.params['token'] = os.environ.get(self.params['token_env_key'])
            if not self.params['token']:
                raise Exception(f"There is no token or token key configured for model {self.model_name} - you should add an entry to Percolate for the model using the examples in p8.LanguageModelApi")
        """we use the env in favour of what is in the store"""
        self.params['token'] = os.environ.get(self.params['token_env_key']) if self.params.get('token_env_key') else self.params.get('token') 
        
    def parse(self, response, context: CallingContext=None) -> AIResponse:
        """the llm response form openai or other schemes must be parsed into a dialogue.
        this is also done inside the database and here we replicate the interface before dumping and returning to the executor
        """
        try:
            if response.status_code not in [200,201]:
                pass #do something for errors
            """check http codes TODO - if there is an error then we can return an error AIResponse"""
            response = response.json()
            
            sid = None if not context else context.session_id
            """check the HTTP response first"""
            if self.params.get('scheme') == 'google':
                return GoogleAIResponseScheme.parse(response, sid=sid, model_name=self.model_name)
            if self.params.get('scheme') == 'anthropic':
                return AnthropicAIResponseScheme.parse(response,sid=sid,model_name=self.model_name)
            return OpenAIResponseScheme.parse(response,sid=sid, model_name=self.model_name)
        except Exception as ex:
            logger.warning(f"failing to parse {response=} {traceback.format_exc()}")
        
    def __call__(self, messages: MessageStack, functions: typing.List[dict], context: CallingContext=None ) -> AIResponse:
        """call the language model with the message stack and functions"""
        response = self._call_raw(messages=messages, functions=functions)
        """for consistency with DB we should audit here and also format the message the same with tool calls etc."""
        response = self.parse(response,context=context)
        logger.debug(f"Response of type {response.status} with token consumption {response.tokens}")
        #self.db.repository(AIResponse).update_records(response)
        return response
    
    def ask(self, question:str, functions: typing.List[dict]=None, system_prompt: str=None):
        """simple check frr question. our interface normally uses MessageStack and this is a more generic way
        Args:
            question: any question
            system_prompt: to test altering model output behaviour
            functions: optional list of functions in the OpenAPI like scheme
        """
        return self.__call__(MessageStack(question,system_prompt=system_prompt), functions=functions)
        
        
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
        """dialect of function wrapper for openai scheme tools"""
        return [{'type': 'function', 'function': f} for f in functions or []]
          
    def _adapt_tools_for_anthropic(self, functions: typing.List[dict]):
        """slightly different dialect of function wrapper - rename parameters to input_schema"""
        def _rewrite(d):
            return {
                'name' : d['name'],
                'input_schema': d['parameters'],
                'description': d['description']
            }
 
        return [_rewrite(d) for d in functions or []]
    
    def call_api_simple(self, 
                        question:str, 
                        functions: typing.List[dict]=None, 
                        system_prompt:str=None, 
                        data_content:typing.List[dict]=None,
                        is_streaming:bool = False,
                        temperature: float = 0.01,
                        streaming_callback : typing.Callable = None,
                        **kwargs):
        """
        Simple REST wrapper to use with any language model
        """
        logger.debug(f"invoking model {self.model_name}")
        """select this from the database or other lookup
        e.g. db.execute('select * from "LanguageModelApi" where name = %s ', ('gpt-4o-mini',))[0]
        """
        params = self.params
        data_content = data_content or []
        
        """we may need to adapt this e.g. for the open ai scheme"""
        tools = functions or None
        
        if system_prompt:
            system_prompt+= GENERIC_P8_PROMPT
        url = params["completions_uri"]
        """use the env first"""
         
        token = params['token']
        if not token or len(token)==0:
            raise Exception(f"There is no API KEY in the env or database for model {self.model_name} - check ENV {params.get('token_env_key')}")
        headers = {
            "Content-Type": "application/json",
        }
        if params['scheme'] == 'openai':
            headers["Authorization"] = f"Bearer {token}"
            tools = self._elevate_functions_to_tools(functions)
        if params['scheme'] == 'anthropic':
            headers["x-api-key"] = token
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
            "tools": tools,
            'temperature': temperature
        }
        if params['scheme'] == 'anthropic':
            data = {
                "model": params['model'],
                'temperature': temperature,
                "messages": [
                    {"role": "user", "content": question}, 
                    #because they use blocks https://docs.anthropic.com/en/docs/build-with-claude/tool-use#example-of-empty-tool-result
                    *[MessageStackFormatter.adapt_tool_response_for_anthropic(d) for d in data_content if d]
                ]
            }
            if tools:
                data['tools'] = tools
            if system_prompt:
                data['system'] = system_prompt
            data["max_tokens"] = kwargs.get('max_tokens',ANTHROPIC_MAX_TOKENS_IN)
             
        if params['scheme'] == 'google':
            data_content = [MessageStackFormatter.adapt_tool_response_for_google(d) for d in data_content if d]
            optional_tool_config = { "tool_config": {   "function_calling_config": {"mode": "ANY"}  }  }
            data = {
                "contents": [
                    {"role": "user", "parts": [{'text': question}]},
                    *data_content
                ],
                "tools": [{'function_declarations': tools}] if tools else None,
            }
            """gemini is stupid if you add a tool to use but it already has the answer
            "role": "user",  "parts": [{   "functionResponse": { <--- if the message is like this disable tools
            """
            if not data_content or 'functionResponse' not in data_content[-1]['parts'][0]:
                data.update(optional_tool_config)
            if system_prompt:
                data["system_instruction"] =  { "parts": { "text": system_prompt } }
                    
        logger.debug(f"request {data=}")
   
        response =  requests.post(url, headers=headers, data=json.dumps(data))
        
        if response.status_code not in [200,201]:
            logger.warning(f"failed to submit: {response.status_code=}  {response.content}")
            
        return response
    
    
    
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
    
    #read them from the database in the right scheme    
    # def _adapt_tools_for_anthropic( functions: typing.List[dict]):
    #         """slightly different dialect of function wrapper - rename parameters to input_schema"""
    #         def _rewrite(d):
    #             return {
    #                 'name' : d['name'],
    #                 'input_schema': d['parameters'],
    #                 'description': d['description']
    #             } 
    #         return [_rewrite(f) for f in functions]


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