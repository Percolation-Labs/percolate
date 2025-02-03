"""all of these are python stubs that provided metadata for native functions
Native functions are functions that can be used in Percolate DB tool calling from the database
These are the same ones that are stored on the python ModelRunner.
We endeavour to have a small number of system functions that are used with all agents unless disabled per agent/

"""

import typing

def get_entities(keys: typing.List[str]):
    """Provide a list of one or more keys to lookup entities by keys in the database
    Entity lookup uses identifiers like struct codes, identifiers, keys, names and codes for entities registered in the database
    Args:
        keys: List[str] a list of one or more keys to lookup
    """
    pass

def search(question:str, entity_table_name:str):
    """Search provides a general multi-modal search over entities. You may know the entity name from the agent context or leave it blank
    An example entity name is p8.Agent or p8.PercolateAgent.
    Provide a detailed question that can be used for semantic or other search. your search will be mapped to underlying queries as required.
    If given a specific entity name you should prefer to call get_entities with a list of one or more entity keys to lookup. if that fails fall back to search
    Args:
        question: a detailed question to search
        entity_table_name: the name of the entity or table to search e.g. p8.PercolateAgent
    """
    pass

def help(questions:typing.List[str]):
    """
    Help us a planning utility. When you ask a question because you need help or tools to call
    this function will search and return a list of resources or information for you
    
    Args:
        questions: ask one or more questions to receive information and a plan of action
    """
    pass


def announce_generate_large_output(self, estimated_length:int=None):
    """When you are about to generate a lot of output, please call this function with a rough estimate of the size of the content.
    You do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.
    However when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.
    We use to distinguish internal content gathering nodes from final response generation for users.
    """

    pass


    
def get_native_functions():
    """get the native functions so they can be saved as models to the database"""
    from percolate.models.p8 import Function
    fns = [get_entities,search,help,announce_generate_large_output]
    return [Function.from_callable(f, proxy_uri='native') for f in fns]