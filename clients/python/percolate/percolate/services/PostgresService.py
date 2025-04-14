from pydantic import BaseModel
from percolate.models.AbstractModel import ensure_model_not_instance, AbstractModel
from percolate.models.utils import SqlModelHelper
from percolate.utils import logger, batch_collection
import typing
from percolate.models.p8 import ModelField,Agent, IndexAudit
import psycopg2
from percolate.utils.env import POSTGRES_CONNECTION_STRING , POSTGRES_DB, POSTGRES_SERVER,DEFAULT_CONNECTION_TIMEOUT
import psycopg2.extras
from psycopg2 import sql
from psycopg2.errors import DuplicateTable
from tenacity import retry, stop_after_attempt, wait_fixed
import traceback
import uuid
import json
from percolate.models.p8 import   Function
class PostgresService:
    """the postgres service wrapper for sinking and querying entities/models"""

    def __init__(self, model: BaseModel = None, connection_string=None, on_connect_error: str = None):
        try:
            self._connection_string = connection_string or POSTGRES_CONNECTION_STRING
            self.conn = None
            self.helper = SqlModelHelper(AbstractModel)  
            if model:
                """we do this because its easy for user to assume the instance is what we want instead of the type"""
                self.model = AbstractModel.Abstracted(ensure_model_not_instance(model))
                self.helper:SqlModelHelper = SqlModelHelper(model) 
            else: self.model=None
            self.conn = psycopg2.connect(self._connection_string)

        except:
            if on_connect_error != 'ignore':
                logger.warning(traceback.format_exc())
                logger.warning(
                    "Could not connect - you will need to check your env and call pg._connect again"
                )
            
    def _create_db(self,name:str):
        """this util is to create a test database primarily"""
        
        self.conn.autocommit = True   
        try:
            cursor = self.conn.cursor()
            cursor.execute(f"""SELECT 1 FROM pg_database WHERE datname = '{name}';""")
            exists = cursor.fetchone()

            if not exists:
                logger.info(f"Creating database: {name}")
                cursor.execute(f"CREATE DATABASE {name};")
            else:
                logger.debug(f"Database {name} already exists.")

            cursor.close()
            self.conn.close()
        except Exception as ex:
            logger.debug(ex)
            raise
        finally:
            pass
        
            
    def __repr__(self):
        return f"PostgresService({self.model.get_model_full_name() if self.model else None}, {POSTGRES_SERVER=}, {POSTGRES_DB=})"
            
    def _reopen_connection(self):
        """util to retry opening closed connections in the service"""
        @retry(wait=wait_fixed(1), stop=stop_after_attempt(4), reraise=True)
        def open_connection_with_retry(conn_string):
            return psycopg2.connect(conn_string, connect_timeout=5) 
        try:
            if self.conn is None:
                self.conn = open_connection_with_retry(self._connection_string)
            self.conn.poll()
        except psycopg2.InterfaceError as error:
            self.conn = None #until we can open it, lets not trust it
            self.conn = open_connection_with_retry(self._connection_string)

    def _connect(self):
        self.conn = psycopg2.connect(self._connection_string)
        return self.conn
    
    @property
    def entity_exists(self):
        """convenience to see if the entity exists"""
      
        return self.check_entity_exists()
    
    def check_entity_exists(self):
        """sanity check for tets"""
  
        assert self.model, "trying to check exists when model is null is not allowed"
        Q = """SELECT EXISTS (    SELECT FROM information_schema.tables    WHERE table_schema = %s AND table_name = %s   )"""
        result = self.execute(Q,data=(self.model.get_model_namespace(),self.model.get_model_name()))
        if result:
            return result[0]['exists']
        return False
    
    def repository(self, model: BaseModel, **kwargs) -> "PostgresService":
        """a connection in the context of the abstract model for crud support"""
        return PostgresService(model=model, connection_string=self._connection_string, **kwargs)

    def get_entities(self, keys: str | typing.List[str]):
        """
        use the get_entities database function to lookup entities
        """
        if keys:
            if not isinstance(keys,list):
                keys = [keys]
                
        data = self.execute(f"""SELECT * FROM p8.get_entities(%s)""", data=(keys,))     if keys else None  
            
        if not data:
            return [{
                "status": "NO DATA",
                "message": f"There were no data when we fetched {keys=} Please use another method to answer the question or return to the user with a new suggested plan or summary of what you know so far. If you still have different functions to use please try those before completion." 
            }]      
        return  data[0]
            

        
    def search(self, question:str):
        """
        If the repository has been activated with a model we use the models search function
        Otherwise we use percolates generic plan and search.
        Either way, feel free to ask a detailed question and we will seek data.
        
        Args:
            question: detailed natural language question 
        """
        
        """in future we should pardo multiple questions"""
        if isinstance(question,list):
            question = '\n'.join(question)
        
        Q = f"""select * from p8.query_entity(%s,%s) """
        
        result =  self.execute(Q, data=(question,self.model.get_model_full_name() ))
        
        try:
            if result:
                a = result[0].get('relational_result')
                b = result[0].get('vector_result')
                if a is None and b is None:
                    logger.warning(f"Nothing was recovered from the relational or vector result - injecting a prompt")
                    return [{'status': 'no data', "next-steps": f"There is no data to address the questions {question} further using this query but dont worry - try asking for help to find another tool if we have not already been able to find data for this question elsewhere"}]
        except:
            pass
        
        return result
        
    def get_model_database_schema(self):
        assert self.model is not None, "The model is empty - you should construct an instance of the postgres service as a repository(Model)"
        q = f"""SELECT 
            column_name AS field_name,
            data_type AS field_type
            FROM information_schema.columns
            WHERE table_name = %s AND table_schema = %s
        """
        return self.execute(q, data=(self.model.get_model_name(),self.model.get_model_namespace()))
    
    def model_registration_script(self, primary: bool= True, secondary:bool=True):
        """for bootstrapping we can generate the model registration script including data
        normally we need to create all the tables first and then we can add aux stuff
        """
        primary_scripts = {
            'register entity':self.helper.create_script(if_not_exists=True),  
        }
        secondary_scripts = { 
            'register_embeddings': self.helper.create_embedding_table_script(),
            'insert_field_data': SqlModelHelper(ModelField).get_data_load_statement(self.helper.get_model_field_models()),
            'insert_agent_data': SqlModelHelper(Agent).get_data_load_statement(self.helper.get_model_agent_record()),
            'register_entities' : self.helper.get_register_entities_query()
        }
        
        
        statement = ''
        def add_scripts(scripts,s):
            for k,v in scripts.items():
                if v:
                    s += f'\n-- {k} ({self.helper.model.get_model_full_name()})------' 
                    s += '\n-- ------------------\n' 
                    s += v
                    s += '\n-- ------------------\n' 
            return s
        if primary:
            statement = add_scripts(primary_scripts,statement)
        if secondary:
            statement = add_scripts(secondary_scripts,statement)
            
        return statement
            
    def register(
        self,
        plan: bool = False,
        register_entities: bool = True,
        make_discoverable: bool=False,
        allow_create_schema: bool = False
    ):
        """register the entity in percolate
        -- create the type's table and embeddings table
        -- add the fields for the model
        -- add the agent model entity
        -- register the entity which means adding some supporting views etc.
        """
        assert (
            self.model is not None
        ), "You need to specify a model in the constructor or via a repository to register models"
        script = self.helper.create_script()
        #logger.debug(script)
        if plan == True:
            logger.debug(f"Exiting as {plan=}")
            return script

        try:
            self.execute(script,verbose_errors=False)
            logger.debug(f"Created table {self.helper.model.get_model_table_name()}")   
        except DuplicateTable:
            logger.warning(f"The table already exists - will check for schema migration or ignore")
            current_fields = self.get_model_database_schema()
            script = self.helper.try_generate_migration_script(current_fields)
            if script:
                logger.warning(f"Migrating schema with {script}")
                self.execute(script)
          
        """added the embedding but check if there are certainly embedding columns"""
        if self.helper.table_has_embeddings:
            try:
                script = self.helper.create_embedding_table_script()
                self.execute(script,verbose_errors=False)
                logger.debug(f"Created embedding table - {self.helper.model.get_model_embedding_table_name()}")
            except DuplicateTable:
                logger.warning(f"The embedding-associated table already exists")

        if make_discoverable:
            """discoverable entities are agents that can be run as functions"""
            self.repository(Function).update_records(Function.from_entity(self.model))

        if register_entities:
            logger.debug("Updating model fields")
            self.repository(ModelField).update_records(self.helper.get_model_field_models())
            
            logger.debug(f"Adding the model agent")
            self.repository(Agent).update_records(self.helper.get_model_agent_record())
        
            """the registration"""
            if 'name' in self.helper.model.model_fields:
                #TODO: we need some way to map a key field for the graph. at the moment a name property is at least implicitly required. We would need this or a business key attribute in the database
                self.execute("select * from p8.register_entities(%s)", data=(self.helper.model.get_model_full_name(),))
            
                logger.info(f"Entity registered")
        else:
            logger.info("Done - register entities was disabled")
        
    def eval_function_call(self, name:str, arguments:dict):
        """call the function which can be rest or native via the database"""
        args = {"function":{
            'name': name,
            'arguments': arguments
        }}
        return self.execute(f""" select * from p8.eval_function_call(%s) """, data=(json.dumps(args),))
        
    def get_tools_metadata(self, names:typing.List[str], scheme:str='openai'):
        """list tool metadata in the scheme by tool names"""
        data  = self.execute(f""" select * from p8.get_tools_by_name(%s,%s) """, data=(names, scheme))
        if data:
            return data[0]['get_tools_by_name']
        return []
        
    def execute(
        cls,
        query: str,
        data: tuple = None,
        as_upsert: bool = False,
        page_size: int = 100,
        verbose_errors:bool=True,
        timeout_seconds: int = None
    ):
        """run any sql query - this works only for selects and transactional updates without selects
        
        Args:
            query: 
            data: tuple of args
            as_upsert: hint to use the upsert mode
            page_size: for upsert batching
            verbose_errors:
            timeout_seconds: keep this off but for testing multi turn you can set it to something but keep in mind we would use background workers for this
        """
        
        if cls.conn is None:
            cls._reopen_connection()
        if not query:
            return
        
        if timeout_seconds and isinstance(timeout_seconds,int):
            query = f"set statement_timeout = '{timeout_seconds}s';{query}"
        try:
            """we can reopen the connection if needed"""
            try:
                c = cls.conn.cursor()
            except:
                cls._reopen_connection()
                c = cls.conn.cursor()
                
            """prepare the query"""
            if as_upsert:
                psycopg2.extras.execute_values(
                    c, query, data, template=None, page_size=page_size
                )
            else:
                c.execute(query, data)

            if c.description:
                result = c.fetchall()
                """if we have and updated and read we can commit and send,
                otherwise we commit outside this block"""
                cls.conn.commit()
                column_names = [desc[0] for desc in c.description or []]
                result = [dict(zip(column_names, r)) for r in result]
                return result
            """case of upsert no-query transactions"""
            cls.conn.commit()
        except Exception as pex:
            msg = f"Failing to execute query {query} for model {cls.model} - Postgres error: {pex}, {data}"
            if not verbose_errors:
                msg = f"Failing to execute query model {cls.model} - {verbose_errors=} - {pex}"
            logger.warning(msg)
            cls.conn.rollback()
            raise
        finally:
            cls.conn.close()
            cls.conn = None

    def select(self, fields: typing.List[str] = None, **kwargs):
        """
        select based on the model and use kwargs as quality or in-list template predicates
        """
        assert (
            self.model is not None
        ), "You need to specify a model in the constructor or via a repository to select models"

        data = None
        if kwargs:
            data = tuple(kwargs.values())
        return self.execute(self.helper.select_query(fields, **kwargs), data=data)

    def get_by_name(cls, name: str, as_model:bool = False):
        """select model by name"""
        data =  cls.select(name=name)
        if data and as_model and cls.model:
            return [cls.model(**d) for d in data]
        return data

        
    def get_by_id(cls, id: str, as_model:bool = False) -> dict|AbstractModel:
        """select dictionary values by if unless as model set set - returns one value"""
        data =  cls.select(id=id)
        if data and as_model and cls.model:
            data = [cls.model(**d) for d in data][0]
            if as_model:
                assert cls.model, "You have asked for a model but the model is not set on the repository"
                return cls.model(**data)
        return data
    
    def select_to_model(self, fields: typing.List[str] = None):
        """
        like select except we construct the model objects
        """
        return [self.model.model_parse(d) for d in self.select(fields)]


    def execute_upsert(cls, query: str, data: tuple = None, page_size: int = 100):
        """run an upsert sql query"""
        return cls.execute(query, data=data, page_size=page_size, as_upsert=True)

    def update_records(
        self, records: typing.List[BaseModel], batch_size: int = 1000, index_entities: bool = False
    ):
        """records are updated using typed object relational mapping."""

        if records and not isinstance(records, list):
            records = [records]

        if self.model is None:
            """we encourage explicitly construct repository but we will infer"""
            return self.repository(records[0]).update_records(
                records=records, batch_size=batch_size
            )

        if len(records) > batch_size:
            logger.info(f"Saving  {len(records)} records in batches of {batch_size}")
            for batch in batch_collection(records, batch_size=batch_size):
                sample = self.update_records(batch, batch_size=batch_size,index_entities=index_entities)
            return sample

        data = [
            tuple(self.helper.serialize_for_db(r).values())
            for i, r in enumerate(records)
        ]

        if records:
            query = self.helper.upsert_query(batch_size=len(records))
            try:
                result = self.execute_upsert(query=query, data=data)
            except:
                logger.warning(f"Failing to run {query}")
                raise

            if index_entities:
                self.index_entities()
            return result
        else:
            logger.warning(f"Nothing to do - records is empty {records}")

    def index_entity_by_name(self, entity_name:str, id:uuid.UUID=None):
        """
        index entities - a session id can be passed in for the audit callback
        this is very much WIP - it may be this moves into background workers in the database
        """
        
        assert self.model is not None, "The model is null - did you mean to create a repository with the model first?"
        
        r1, r2 = None,None
        errors = ""
        try:
            
            r1 = self.execute(f""" select * from p8.insert_entity_nodes(%s); """, data=(entity_name,))
        except Exception as ex:
            errors+= traceback.format_exc()
            logger.warning(f"Failed to compute nodes {traceback.format_exc()}")
        try:
            r2 = self.execute(f""" select * from p8.insert_entity_embeddings(%s); """, data=(entity_name,))
        except Exception as ex:
            errors+= traceback.format_exc()
            logger.warning(f"Failed to compute embeddings {ex}")
            
        metrics =  {
            'entities added': r1,
            'embeddings added': r2,
        }
        
        if not id:
            id = uuid.uuid1()
        
        if errors == '':
            self.repository(IndexAudit).update_records(IndexAudit(id=id,
                                                                  model_name='percolate',
                                                                  entity_full_name=entity_name, 
                                                                  metrics=metrics, 
                                                                  status="OK", 
                                                                  message='Index updated without errors'))
        else:
            self.repository(IndexAudit).update_records(IndexAudit(id=id,
                                                                  model_name='percolate',
                                                                  entity_full_name=entity_name,
                                                                  metrics=metrics, 
                                                                  status="ERROR", 
                                                                  message=errors))
        
        logger.info(metrics)
        return metrics
    
    def index_entities(self):
        """This is to allow push index but we typically use the DB background workers to do this for us
        """
        
        logger.info(f'indexing entity {self.model}')
        return self.index_entity_by_name(self.model.get_model_full_name())
        
    def run(self, question:str, model:str, max_iterations:int=5,agent:str=None):
        """this will run the database run function for convenience testing.
        Run executes an agentic loop using the provided agent class.
        Sessions and AIResponses are saved in the database.
        
        Args:
            question: ask a question
            model: the language model will default to gpt-40
            max_iterations: the number of turns the agent can take - default 5
            agent: the name of the registered agent to use - defaults to the p8.PercolateAgent
        """
        
        from percolate.utils.env import DEFAULT_MODEL
        
        agent = agent or self.model.get_model_full_name() if self.model else None
        """default agent"""
        agent = agent or "p8.PercolateAgent"
        model = model or DEFAULT_MODEL
        return self.execute(f"""SELECT * FROM run(%s,%s, %s, %s)""", data=(question, max_iterations, model, agent))
    