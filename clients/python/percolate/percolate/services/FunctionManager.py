import typing
from percolate.models.p8 import Function, PlanModel
from percolate.models import AbstractModel
import percolate as p8
from percolate.utils import logger
class FunctionManager:
    def __init__(cls):
        cls._functions= {}
        cls.repo = p8.repository(Function)
        
    def __getitem__(cls, key):
        """unsafely gets the function"""
        return cls._functions[key]
    
    def add_function(cls, function: typing.Callable | Function):
        """add a function to the stack of functions given to the llm
        
            Args: a callable function or percolate Function type
        """
        if not isinstance(function, Function):
            logger.debug(f"adding function: {function}")
            function = Function.from_callable(function)
        cls._functions[function.name] = function
        logger.debug(f"added function {function.name}")
    
    
    def activate_agent_context(cls, agent_model: AbstractModel):
        """
        Add and abstract model to activate functions on the type
        Pydantic BaseModels can be abstracted with the AbstractModel.Abstract if necessary
        In practice we import any callable methods on the agent model as callables
        
        Args:
            agent_model: Any class type with @classmethods that can be passed to the LLM
        """
        required = list((agent_model.get_model_functions() or {}).keys())
        for f in cls.repo.get_by_name(required, as_model=True):
            cls.add_function(f)
        required = set(required) - set(cls.functions.keys())
        logger.warning(f"We could not find the function {required}")  
        """we may lookup the anent and do something with the metadata too"""
 
    def add_functions_by_key(cls, function_keys : typing.List[str]|str):
        """Add function or functions by key(s) - the function keys are expected to existing in the registry
        
        Args:
            function_keys: a list of one or more function(keys) to activate
            
        """
        if function_keys:
            if not isinstance(function_keys,list):
                function_keys = [function_keys]
        """activate here"""   
        required = [f for f in function_keys if f not in cls.functions]     
        if required:
            for f in cls.repo.get_by_name(required, as_model=True):
                cls.add_function(f)
        required = set(required) - set(cls.functions.keys())
        logger.warning(f"We could not find the function {required}")
        
    def plan(cls, questions: str | typing.List[str], use_cache: bool = False):
        """based on one or more questions, we will construct a plan.
        This uses the database function plan to search over functions.
        We can also use the cache to load the functions into memory and do the same thing
        
        Args:
            questions: a question or list of questions to use to construct a plan over agents and functions
            use_cache: (default=False) use the in memory cache rather than the database function to make the plan
        """
        
        """TODO
        in the database we need a Plan model that also can search agents and return a plan
        but in python we can just select the data into the planner agent and fetch the plan
        """
        
        return p8.Agent(PlanModel).run(questions, data=cls.repo.select())
    
    @property
    def functions(cls):
        return cls._functions
        
    @property
    def function_names(cls):
        return list(cls._functions.keys())