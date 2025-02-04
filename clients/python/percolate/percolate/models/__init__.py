from pydantic import Field
from functools import partial
import typing

def EmbeddedField(embedding_provider='default')->Field:
    return partial(Field, json_schema_extra={'embedding_provider':embedding_provider})

DefaultEmbeddingField = EmbeddedField()

def KeyField():
    return partial(Field, json_schema_extra={'is_key':True})


from . import utils
from .MessageStack import  MessageStack
from .AbstractModel import AbstractModel

def get_p8_models():
    """convenience to load all p8 models in the library"""
    
    from percolate.models.inspection import get_classes
    return get_classes(package="percolate.models.p8")


from .p8 import * 

def bootstrap(apply:bool = False, root='../../../../extension/'):
    """util to generate the sql that we use to setup percolate"""

    from percolate.models.p8 import sample_models
    from percolate.models.utils import SqlModelHelper
    from percolate.services import PostgresService
    from percolate.models.p8.native_functions import get_native_functions
    pg = PostgresService(on_connect_error='ignore')
    import glob
 
    root = root.rstrip('/')
    print('********Building queries*******')
    """build a list of models we want to init with"""
    models = [ Project, Agent, ModelField, LanguageModelApi, Function, Session, AIResponse, ApiProxy, PlanModel, Settings, PercolateAgent, IndexAudit]
        
    """compile the functions into one file"""
    with open(f'{root}/sql/01_add_functions.sql', 'w') as f:
        print(f)
        for sql in glob.glob(f'{root}/sql-staging/p8_pg_functions/**/*.sql',recursive=True):
            print(sql)
            with open(sql, 'r') as sql:
                f.write(sql.read())
                f.write('\n\n---------\n\n')

    """add base tables"""            
    with open(f'{root}/sql/02_create_primary.sql', 'w') as f:
        print(f)
        for model in models:
            f.write(pg.repository(model,on_connect_error='ignore').model_registration_script(secondary=False, primary=True))

    """add the rest"""
    with open(f'{root}/sql/03_create_secondary.sql', 'w') as f:    
        print(f)
        for model in models:
            print(model)
            f.write(pg.repository(model,on_connect_error='ignore').model_registration_script(secondary=True, primary=False))
            
        script = SqlModelHelper(LanguageModelApi).get_data_load_statement(sample_models)
        f.write('\n\n-- -----------\n')
        f.write('-- sample models--\n\n')
        f.write(script)
        
        """add native functions"""
        script = SqlModelHelper(Function).get_data_load_statement(get_native_functions())
        f.write('\n\n-- -----------\n')
        f.write('-- native functions--\n\n')
        f.write(script)
        
    if apply:
        _test_apply(root=root)
        
def _test_apply(root='../../../../extension/'):
    """
    these are utility test methods - but we will add them to an automated deployment test script later
    """
    
    from percolate.services import PostgresService
    pg = PostgresService()

    print('*****applying sql schema...******')
    print()
    root = root.rstrip('/')
   
    with open(f"{root}/sql/00_install.sql") as f:
        sql = f.read()
        pg.execute(sql)
        
    with open(f"{root}/sql/01_add_functions.sql") as f:
        sql = f.read()
        pg.execute(sql)

    with open(f"{root}/sql/02_create_primary.sql") as f:
        sql = f.read()
        pg.execute(sql)
    with open(f"{root}/sql/03_create_secondary.sql") as f:
        sql = f.read()
        pg.execute(sql)
        
    with open(f"{root}/sql/10_finalize.sql") as f:
        sql = f.read()
        pg.execute(sql)
        
    print('********done*******')