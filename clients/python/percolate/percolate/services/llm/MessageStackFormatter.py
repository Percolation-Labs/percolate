"""
OpenAI scheme is pretty flexible

anthropic needs a tool result block
https://docs.anthropic.com/en/docs/build-with-claude/tool-use#example-of-successful-tool-result
is_error (optional): Set to true if the tool execution resulted in an erro
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_01A09q90qw90lq917835lq9",
      "content": "15 degrees"
    }
  ]
}

"""



import typing
import json
from .CallingContext import CallingContext
from pydantic import BaseModel,Field
from . import FunctionCall
from percolate.utils import logger

class Message(BaseModel):
    role: str
    content: str | dict | typing.List[dict]
    #name: typing.Optional[str] = Field(None, description="Functions for example have names in their messages for context")
    tool_call_id: typing.Optional[str] = Field(None, description="tools need ids in their messages")
  
class MessageStackFormatter:
  
    @classmethod
    def adapt_tool_response_for_google(cls,data):
        """https://ai.google.dev/gemini-api/docs/function-calling"""
        
        try:
            
            if data.get('tool_call_id'):
                name = data.get('tool_call_id')
                return  {"role": data['role'], "parts": 
                [
                    {'functionResponse':{
                        'name': name,
                        'response' : {
                            'name' : name,
                            'content' : json.loads(data['content'])
                        } 
                    }}
                ]
                }  
        
            """this is the tool call verbatim"""
            return data
        except:
            logger.warning(f"Failed to adapt google message {data}")
            raise
        
    @classmethod
    def adapt_tool_response_for_anthropic(cls,data):
        """anthropic requires tool blocks of this form
        https://docs.anthropic.com/en/docs/build-with-claude/tool-use#example-of-successful-tool-result
        """
        if data.get('tool_call_id'):
            return  {
                    'role': 'user',
                     'content' : [{ 
                        "type": "tool_result",
                        "tool_use_id": data['tool_call_id'],
                        "content": json.dumps(data['content'], default=str)
                        }]
                    }
        """pass through"""
        return data
    
    @classmethod
    def format_function_response_data(
        cls, fc: FunctionCall, data: typing.Any, context: CallingContext = None
    ) -> dict:
        """format the function response for the agent - essentially just a json dump

        Args:
            name (str): the name of the function
            data (typing.Any): the function response
            context (CallingContext, optional): context such as what model we are using to format the message with

        Returns: formatted messages for agent as a dict
        """
        
        """Pydantic things """
        if hasattr(data,'model_dump'):
            data = data.model_dump()

        
        return Message(
            role=fc.get_tool_role(),
            name=f"{str(fc.name)}",
            tool_call_id = fc.id,
            #the tool reuse block is required by anthropic but everyone else is flexible about the json content - they may required a tool use id to be elevated though
            content=  json.dumps(data,default=str) )

    @classmethod
    def format_function_response_type_error(
        cls, fc: FunctionCall, ex: Exception, context: CallingContext = None
    ) -> Message:
        """type errors imply the function was incorrectly called and the agent should try again

        Args:
            name (str): the name of the function
            data (typing.Any): the function response
            context (CallingContext, optional): context such as what model we are using to format the message with

        Returns: formatted error messages for agent as a dict
        """
        return Message(
            role=fc.get_tool_role(),
            name=f"{str(fc.name.replace('.','_'))}",
            tool_call_id = fc.id,
            content=f"""You have called the function incorrectly - try again {ex}.
            If the user does not supply a parameter the function may supply a hint about default parameters.
            You can use the function description in your list of functions for hints if you do not know what parameters to pass!""",
        )

    def format_function_response_error(
        fc: FunctionCall, ex: Exception, context: CallingContext = None
    ) -> Message:
        """general errors imply something wrong with the function call

        Args:
            name (str): the name of the function
            data (typing.Any): the function response
            context (CallingContext, optional): context such as what model we are using to format the message with

        Returns: formatted error messages for agent as a dict
        """

        return Message(
            role=fc.get_tool_role(),
            name=f"{str(fc.name.replace('.','_'))}",
            tool_call_id = fc.id,
            content=f"""This function failed - you should try different arguments or a different function. - {ex}. 
If no data are found you must search for another function if you can to answer the users question. 
Otherwise check the error and consider your input parameters """,
        )