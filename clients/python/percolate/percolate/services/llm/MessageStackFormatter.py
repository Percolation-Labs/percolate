
import typing
import json
from .CallingContext import CallingContext
from pydantic import BaseModel,Field

class Message(BaseModel):
    role: str
    content: str | dict
    name: typing.Optional[str] = Field(None, description="Functions for example have names in their messages for context")
class MessageStackFormatter:
    pass


    @classmethod
    def format_function_response_data(
        cls, name: str, data: typing.Any, context: CallingContext = None
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
            role="function",
            name=f"{str(name)}",
            content=json.dumps(
                {
                    # do we need to be this paranoid most of the time?? this is a good label to point later stages to the results
                    "about-these-data": f"You called the tool or function `{name}` and here are some data that may or may not contain the answer to your question - please review it carefully",
                    "data": data,
                },
                default=str,
            ),
        )

    @classmethod
    def format_function_response_type_error(
        cls, name: str, ex: Exception, context: CallingContext = None
    ) -> Message:
        """type errors imply the function was incorrectly called and the agent should try again

        Args:
            name (str): the name of the function
            data (typing.Any): the function response
            context (CallingContext, optional): context such as what model we are using to format the message with

        Returns: formatted error messages for agent as a dict
        """
        return Message(
            role="function",
            name=f"{str(name.replace('.','_'))}",
            content=f"""You have called the function incorrectly - try again {ex}.
            If the user does not supply a parameter the function may supply a hint about default parameters.
            You can use the function description in your list of functions for hints if you do not know what parameters to pass!""",
        )

    def format_function_response_error(
        name: str, ex: Exception, context: CallingContext = None
    ) -> Message:
        """general errors imply something wrong with the function call

        Args:
            name (str): the name of the function
            data (typing.Any): the function response
            context (CallingContext, optional): context such as what model we are using to format the message with

        Returns: formatted error messages for agent as a dict
        """

        return Message(
            role="function",
            name=f"{str(name.replace('.','_'))}",
            content=f"""This function failed - you should try different arguments or a different function. - {ex}. 
If no data are found you must search for another function if you can to answer the users question. 
Otherwise check the error and consider your input parameters """,
        )