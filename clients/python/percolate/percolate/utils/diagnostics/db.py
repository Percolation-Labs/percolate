"""A  number of critical integration checks on the database that requires configuration of keys and tokens"""

import traceback
from percolate.utils import logger
from percolate.services import PostgresService

def diag_api_accessible_from_db(with_token=True):
    """
    Runs a query in the database to make sure the api can be reached with the saved token and api configuration
    """

    try:
        result = PostgresService().execute("SELECT * FROM p8.ping_api()")
        """TODO check response code"""
        logger.info(result)
        return 1
    except:
        logger.warning("Failing diagnostic: test_api_accessible_from_db")
        logger.warning(traceback.format_exc())
        return 0
    
    
def diag_embed_with_default_model():
    """
    we use open ai by default and support for other models may be limited - test the api with token
    """
    try:
        result = PostgresService().execute("""
                                           
                                           SELECT * FROM p8.fetch_embeddings(
                                                '["Hello world", "How are you?"]'::jsonb,
                                                NULL,
                                                'text-embedding-ada-002'
                                            );
                                           
                                           """)
 
        for r in result:
            if 'embedding' in r:
                r['embedding'] = f"{str(r['embedding'])[:10]}..."
        logger.info(result)
        return 1
    except:
        logger.warning("Failing diagnostic: test_api_accessible_from_db")
        logger.warning(traceback.format_exc())
        return 0
    
def diag_percolate_function():
    try:
        result = PostgresService().execute("""
                                           
                                           select * from percolate_with_agent('list some pets that str sold', 'p8.PercolateAgent');
                                           
                                           """)
 
        logger.info(result)
    except:
        logger.warning("Failing diagnostic: test_api_accessible_from_db")
        logger.warning(traceback.format_exc())
        return 0
    
    try:
        result = PostgresService().execute("""
                                           
                                           select * from percolate('what is the capital of ireland');
                                           
                                           """)
 
        logger.info(result)
        return 1
    except:
        logger.warning("Failing diagnostic: test_api_accessible_from_db")
        logger.warning(traceback.format_exc())
        return 0
    
def diag_can_index_entities():
    pass



def run_diagnostics():
    """run things marked diag_"""
    for name, obj in globals().items():
        if callable(obj) and name.startswith("diag_"):
            obj()