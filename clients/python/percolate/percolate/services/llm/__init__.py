"""although percolate will push the database use case, we can use llms in the app tier"""



from pydantic import BaseModel, model_validator, Field
import typing
import json
class FunctionCall(BaseModel):
    name: str
    arguments: str | dict
    id: str
    scheme: typing.Optional[str] = Field(None, description="information about the scheme for formatting purposes")
    def get_tool_role(self):
        """the role for tool use"""
        if self.scheme == 'anthropic':
            return 'user'
        if self.scheme == 'google':
            return 'user'
        return "tool"
    
    def to_assistant_message(self, scheme:str='openai'):
        """
        assistant declares function call or rather tool call
        """
        args_str = self.arguments if isinstance(self.arguments,str) else json.dumps(self.arguments)
        return { "role": "assistant",
                "content": '',
                "tool_calls": [
                     {
                        "id": self.id,
                        "type": "function",
                        "function": {
                            "name":self.name,
                            "arguments": args_str
                        }
                    }
                ]
            }
    
    @model_validator(mode='before')
    @classmethod
    def _val(cls, values):
        if isinstance(values['arguments'], str):
            values['arguments'] = json.loads(values['arguments'])
        return values
  
      
def _check_all(question  = "what is the capital of ireland and give me one fun fact too", filter_model_keys:typing.List[str]=None, functions: typing.List[dict]=None):
    """this is a simple wrapper to illustrate probing each model with a question
    Args:
        question: any question
        filter_model_keys: this is the key used in the percolate db p8.LanguageModelApi.name. This is sometimes the same as the model name but not always
    """
    from percolate import get_language_model_settings
    from percolate.models.p8 import LanguageModelApi
    
    if filter_model_keys and not isinstance(filter_model_keys,list):
        filter_model_keys = [filter_model_keys]
    models = [LanguageModelApi(**p) for p in get_language_model_settings()]
    responses = {}
    for m in models:
        if filter_model_keys and m.name not in filter_model_keys:
                continue
        llm = LanguageModel(m.name)
        responses[m.name] = llm.call_api_simple(question,functions=functions)
    return responses


from .CallingContext import CallingContext
from .LanguageModel import LanguageModel
from .MessageStackFormatter import MessageStackFormatter