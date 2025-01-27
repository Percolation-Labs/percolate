import typing
from percolate.models.p8 import Function
from percolate.models import AbstractModel

class FunctionManager:
    def __init__(cls):
        cls._functions= {}
    
    def add_function(cls, function: typing.Callable | Function):
        """add a function to the stack of functions given to the llm
        
            Args: a callable function or percolate Function type
        """
        pass
    
    
    def activate_agent_context(cls, agent_model: AbstractModel):
        """
        Add and abstract model to activate functions on the type
        Pydantic BaseModels can be abstracted with the AbstractModel.Abstract if necessary
        In practice we import any callable methods on the agent model as callables
        
        Args:
            agent_model: Any class type with @classmethods that can be passed to the LLM
        """
        
        pass
    
    
    def add_functions_by_key(cls, function_keys : typing.List[str]|str):
        """Add function or functions by key(s) - the function keys are expected to existing in the registry
        
        Args:
            function_keys: a list of one or more function(keys) to activate
            
        """
        if function_keys:
            if not isinstance(function_keys,list):
                function_keys = [function_keys]
                """activate here"""        
        
    def plan(cls, questions: str | typing.List[str], use_cache: bool = False):
        """based on one or more questions, we will construct a plan.
        This uses the database function plan to search over functions.
        We can also use the cache to load the functions into memory and do the same thing
        
        Args:
            questions: a question or list of questions to use to construct a plan over agents and functions
            use_cache: (default=False) use the in memory cache rather than the database function to make the plan
        """
        
        pass
    
    
    @property
    def functions(cls):
        return cls._functions
        
    @property
    def function_names(cls):
        return list(cls._functions.keys())