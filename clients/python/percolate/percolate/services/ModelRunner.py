import typing
import traceback
import percolate as p8
from pydantic import BaseModel
from percolate.utils import logger
from percolate.models.p8 import Function 
from .FunctionManager import FunctionManager
from percolate.models import AbstractModel, MessageStack
from percolate.services.llm import CallingContext, FunctionCall, LanguageModel, MessageStackFormatter

GENERIC_P8_PROMPT = """\n# General Advice.
Use whatever functions are available to you and use world knowledge only if prompted 
or if there is not other way 
or the user is obviously asking about real world information that is not covered by functions.

- Observe what functions you have to use and check the message history to avoid calling the same functions with the same parameters repeatedly.
- Your Agent Name is given below and you never need to activate [Agent Name] as a function since the context is already loaded.
- If you encounter a function name that is not your name such as those lists under agent functions, you can activate it with the provided tool to activate_function_by_name assuming you have the correct function name. You should do so without asking the user.
- When generating large output observe the notification that needs to be called first, call it and continue.
Of you call a function that is running another agent, you should always pass the full context from the user in the question. Do not shorten or ask simpler questions which loses the users context.
            """
            
class ModelRunner:
    """The model runner manages chaining agents and reasoning steps together in the execution loop
    We had functions implementing the p8 model runner interface which is also in db native functions
    """
    
    @property
    def name(self):
        return self.agent_model.get_model_full_name()
    def __init__(self, model: BaseModel = None, allow_help: bool = True, depth:int=0, **kwargs):
        """
        A model is passed in or the default is used.
        This supplies the agent context such as prompt and functions.
        If the model has no functions simple Q&A can still be exchanged with LLMs.
        More generally the model can provide a structured response format.
        see TODO: for guidance.
        """
        self.depth = depth  #TODO consider ways to control depth
        self._init_data = kwargs.get('init_data')
        """the agent model is any Pydantic Base model or Abstract model that implements the agent interface"""
        self.agent_model:AbstractModel = AbstractModel.Abstracted(model)
        """a function manager allows for activating functions at runtime and searching and planning over functions"""
        self._function_manager = FunctionManager()
        """the help option links in to the function manager planner"""
        self._allow_help = allow_help
        """the repository provides the Percolate database instance"""
        self.repo = p8.repository(self.agent_model)
        """initialize activates the agent model e.g. functions and prompt for use"""
        self.initialize()
        """the messages stack is the most important control element for llm agent sessions"""
        self.messages = MessageStack(None)
        logger.info(f"******Constructed agent {self.name}******")
        
    def __repr__(self):
        return f"Runner({self.name})"

    def initialize(self):
        """Register the functions and other metadata from the agent model"""
        self._context = None
        if self._allow_help:
            self._function_manager.add_function(self.help)  # :)
        """register the model's functions which can include function search"""
        self._function_manager.activate_agent_context(self.agent_model)
        """the basic bootstrapping means asking for help, entities(types) or functions"""
        self._function_manager.add_function(self.get_entities)
        self._function_manager.add_function(self.search)
        self._function_manager.add_function(self.activate_functions_by_name)
        #self._function_manager.add_function(self.announce_generate_large_output)
        """more complex things will happen from here when we traverse what comes back"""

    def announce_generate_large_output(self, estimated_length:int=None):
        """When you are about to generate a lot of output, please call this function with a rough estimate of the size of the content.
        You do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.
        However when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.
        We use to distinguish internal content gathering nodes from final response generation for users.
        """
        logger.warning(f"The model is requesting to output: {estimated_length=}")
        return {'message': 'acknowledged', 'output_size_estimate': estimated_length}
        
        
    def search(self, questions: typing.List[str]):
        """Run a general search on the model that is being used in the current context as per the system prompt
        If you want to add multiple questions supply a list of strings as an array.
        To find functions use help instead of search. Do not search for functions if there is already a function on the agent that you can activate.
        Args:
            questions: ask one or more questions to search the data store
        """

        return self.repo.search(questions)

    def activate_functions_by_name(self, function_names: typing.List[str], **kwargs):
        """Provide a list of function names to load.
        The names should be fully qualified object_id_function_name and we use underscores in place of periods which are illegal.
        You should not try to activate self as a function. For example if your name is x_Agent, do not try to activate yourself.
        If there are functions on an agent you can activate them without searching.
        """

        logger.debug(f"activating function {function_names} - ill replace any '.' with underscores!!")
        
        for f in function_names:
            f = f.replace('.','_')
            
            if f == self.agent_model.get_model_full_name():
                raise Exception("Error - you should not try to load yourself {f} since you are loaded as a callable agent already. Find another function to use in your available functions")
        missing = self._function_manager.add_functions_by_key(function_names)
        available = set(function_names) - set(missing)
        missing_message = f"" if not missing else f" But the functions {missing} could not be loaded"
        """todo check status"""
        return {
            "status": f"Re: the functions {list(available)} are now ready for use. please go ahead and invoke using the full function name. for example for a function called p8_agent_run do not just call run but call p8_agent_run"+missing_message
        }

    def get_entities(self, keys: typing.Optional[str]):
        """Lookup entity by one or more keys. For example if you encounter entity names or keys in question, data etc you can use
        the entity search to learn more about them
        Args:
            keys: one or more names to use to lookup the entity or entities
        """
        logger.debug(f"get_entities/{keys=}")

        """the function manager can load context and we can also adorn entities with extra metadata"""
        entities = p8.get_entities(keys )

        return entities

    def help(self, questions: str | typing.List[str], context: str = None):
        """If you are stuck ask for help with very detailed questions to help the planner find resources for you. You should execute whatever plan you are given.
        If you know the names of the functions you are looking for you should provide this hint.
        If you have a hint about what the source or tool to use hint that in each question that you ask - you should see ' i need functions or tools to...' do something and ask for a plan that involves tool use.
        For example, you can either just ask a question or you can ask "according to resource X" and then ask the question. This is important context.

        Args:
            questions (str): provide detailed questions to guide the planner. you should augment the users question with the additional context that you have e.g. a known source
            context: any added context e.g. what tool, function, source the user or system suggests may know the answer
        """

        try:
            if context:
                questions = f"Using context: {context}, {questions}"

            """for now strict planning is off"""
            plan = self._function_manager.plan(questions)
        except Exception as ex:
            logger.warning(f"Failed to call help {ex}")
            return {"message": "planning pending - i suggest you use world knowledge"}

        """describe the plan context e.g. its a plan but you need to request the functions and do the thing -> update message stack"""

        return {
            'message': "please execute this plan for the user. any functions that are mentioned can be activated using the `activate_functions_by_name` by tool",
            'plan': plan
        }
        
    def invoke(self, function_call: FunctionCall):
        """Invoke function(s) and parse results into messages

        Args:
            function_call (FunctionCall): the payload send from an LLM to call a function
        """
        logger.info(f"({self.name}){function_call=}")
        f = self._function_manager[function_call.name]
        if not f:
            message = f"attempting to load function {function_call.name} which is not activated - please activate it"
            data = MessageStackFormatter.format_function_response_error(
                function_call, ValueError(message), self._context
            )
        else:
            try:
                """try call the function - assumes its some sort of json thing that comes back"""
                data = f(**function_call.arguments) or {}
                data = MessageStackFormatter.format_function_response_data(
                    function_call, data, self._context
                )
                
                """if there is an error, how you format the message matters - some generic ones are added
                its important to make sure the format coincides with the language model being used in context
                """
            except TypeError as tex:  # type errors are usually the agents fault
                logger.warning(f"Error calling function {traceback.format_exc()}")
                data = MessageStackFormatter.format_function_response_type_error(
                    function_call, tex, self._context
                )
            except Exception as ex:  # general errors are usually our fault
                logger.warning(f"Error calling function {traceback.format_exc()}")
                data = MessageStackFormatter.format_function_response_error(
                    function_call, ex, self._context
                )

        # print(data) # maybe trace here
        """update messages with data if we can or add error messages to notify the language model"""
        self.messages.add(data)

    @property
    def functions(self) -> typing.Dict[str, Function]:
        """Provide access to the function manager's functions"""
        return self._function_manager.functions
    
    @property
    def function_descriptions(self) -> typing.List[dict]:
        """Provide access to the function manager's function specs to send to language models"""
 
        return [f.function_spec for _,f  in self._function_manager.functions.items()]

    def __call__(
        self, question: str, context: CallingContext = None, limit: int = None,data: typing.List[dict] = None, language_model:str=None
    ):
        """
        Ask a question to kick of the agent loop
        """
        return self.run(question, context, data=data, limit=limit,language_model=language_model)


    def run(self, question: str, context: CallingContext = None, limit: int = None, data: typing.List[dict] = None, language_model:str=None):
        """Ask a question to kick of the agent loop
        
        Args:
            question: a user question
            context: a context object with information about users, session and usage
            limit: given that we iterate in the executor, we need to set a max length
            data: we can initialise the data payload as though there are function/data load results
        """
        
        """sometimes you may want to initialize your agent with a bunch of data"""
        data = data or self._init_data
        """setup all the bits before running the loop"""
        self._context = context or CallingContext.with_model(language_model)
        """a generic wrapper around the REST interfaces of any LLM client"""
        lm_client = LanguageModel.from_context(self._context)

        """messages are system prompt etc. agent model's can override how message stack is constructed
           we add p8 preamble in percolate - in future this could be disabled per model
        """
        self.messages = self.agent_model.build_message_stack(question=question, functions=self.functions.keys(), data=data,
                                                             system_prompt_preamble=GENERIC_P8_PROMPT)

        """run the agent loop to completion"""
        for _ in range(limit or self._context.max_iterations):
            response = None
            """the language model may stream into a callback in the calling context"""
            response = lm_client(
                messages=self.messages,
                context=self._context,
                functions=self.function_descriptions,
            )
            if function_calls := response.tool_calls:
                """models need us to add the tool call to the stack - this is not the case for openai function call but for consistency over models we must"""
                self.messages.add(response.verbatim)
                """call one or more functions and update messages - functions can be updated inside this context"""
                for func_call in function_calls: #its assumed to be only one for now but we could par do in future
                    self.invoke(FunctionCall(**func_call))
                continue
            if response is not None:
                # marks the fact that we have unfinished business
                
                """for full auditing we should dump the response here"""
                #p8.repository(AIResponse).update_records(response)
                break

        """fire telemetry TODO and below dump to postgres"""
        p8.dump(question, self.messages.data, response, self._context, agent=self.agent_model.get_model_full_name())

        return response.content

