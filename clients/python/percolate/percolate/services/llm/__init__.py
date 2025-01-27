"""although percolate will push the database use case, we can use llms in the app tier"""


from .CallingContext import CallingContext
from .LanguageModel import LanguageModel
from .MessageStackFormatter import MessageStackFormatter
from pydantic import BaseModel

class FunctionCall(BaseModel):
    name: str
    arguments: str | dict
    
  