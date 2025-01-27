from pydantic import BaseModel
from percolate.models import AbstractModel

class MessageStack:
    def __init__(self, question: str, system_prompt:str=None):
        
        self.question = question
        self.system_prompt = system_prompt
        self.data = []

    def add(**kwargs):
        pass
    
    @classmethod
    def build_message_stack(cls, abstracted_model: AbstractModel, question:str, **kwargs) ->"MessageStack":
        """
        we build a message stack from the model prompt and question
        
        Args:
            abstracted_model: provides at least a description for system prompt - we fall back to the doc string of any object
        """
        
        return MessageStack(question=question, system_prompt=abstracted_model.get_model_description())
        