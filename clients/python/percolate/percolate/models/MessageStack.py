from pydantic import BaseModel
from percolate.models import AbstractModel
import json
import typing

class MessageStack:
    def __init__(self, question: str, system_prompt:str=None, data: typing.List[dict] = None):
        
        self.question = question
        self.system_prompt = system_prompt
        self.data = data or []
 
        
    def __iter__(self):
        for d in  self.data:
            yield d
     

    def add(self, data: dict|typing.List[dict], **kwargs):
        """add messages to the stack such as function responses typically"""
        if not isinstance(data,list):
            data = [data]
        
        """if its a pydantic object thats fine too"""
        data = [d if not hasattr(d, 'model_dump') else d.model_dump() for d in data]
        
        self.data += data
    
    @classmethod
    def build_message_stack(cls, abstracted_model: AbstractModel, 
                            question:str,
                            data: typing.List[dict] = None, 
                            use_full_description:bool=True,
                            user_memory:dict=None, **kwargs) ->"MessageStack":
        """
        we build a message stack from the model prompt and question
        
        
        Args:
            abstracted_model: provides at least a description for system prompt - we fall back to the doc string of any object
            question: the user question
            data: any initial data to load
        """
        _data = []
        if data or user_memory:
            """need to think about the best way to add this"""
            _data = [{
                "role": "user",
                "content": json.dumps(data,default=str)                
            }]
            
            """we add the user memory as inout data that the language model can use"""
            if user_memory:
                _data.append(
                    {
                        "role": "user",
                        "content": json.dumps(user_memory,default=str)                
                    }
                )
            
        generalized_prompt_preamble = kwargs.get('system_prompt_preamble')
        prompt = f"{generalized_prompt_preamble}\n{abstracted_model.get_model_description(use_full_description)}"
        return MessageStack(question=question, system_prompt=prompt, data = _data)
        