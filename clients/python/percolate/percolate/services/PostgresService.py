from pydantic import BaseModel
from percolate.models.AbstractModel import ensure_model_not_instance, AbstractModel
from percolate.models.utils import SqlModelHelper
from percolate.utils import logger, batch_collection
import typing
from percolate.models.p8 import ModelField,Agent
import psycopg2
from percolate.utils.env import POSTGRES_CONNECTION_STRING , POSTGRES_DB, POSTGRES_SERVER
import psycopg2.extras
from psycopg2 import sql
from psycopg2.errors import DuplicateTable
from tenacity import retry, stop_after_attempt, wait_fixed
import traceback

class PostgresService:
    """the postgres service wrapper for sinking and querying entities/models"""

    def __init__(self, model: BaseModel = None, conn=None):
        try:
            self.conn = conn or psycopg2.connect(POSTGRES_CONNECTION_STRING)
            self.helper = SqlModelHelper(AbstractModel)  
            if model:
                """we do this because its easy for user to assume the instance is what we want instead of the type"""
                self.model = AbstractModel.Abstracted(ensure_model_not_instance(model))
                self.helper:SqlModelHelper = SqlModelHelper(model) 
        except:
            logger.warning(traceback.format_exc())
            logger.warning(
                "Could not connect - you will need to check your env and call pg._connect again"
            )
            
    def __repr__(self):
        return f"PostgresService({self.model.get_model_full_name() if self.model else None}, {POSTGRES_SERVER=}, {POSTGRES_DB=})"
            
    def _reopen_connection(self):
        """util to retry opening closed connections in the service"""
        @retry(wait=wait_fixed(1), stop=stop_after_attempt(4), reraise=True)
        def open_connection_with_retry(conn_string):
            return psycopg2.connect(conn_string, connect_timeout=6) 
        try:
            if self.conn is None:
                self.conn = open_connection_with_retry(POSTGRES_CONNECTION_STRING)
            self.conn.poll()
        except psycopg2.InterfaceError as error:
            self.conn = None #until we can open it, lets not trust it
            self.conn = open_connection_with_retry(POSTGRES_CONNECTION_STRING)

    def _connect(self):
        self.conn = psycopg2.connect(POSTGRES_CONNECTION_STRING)
        return self.conn

    def repository(self, model: BaseModel) -> "PostgresService":
        """a connection in the context of the abstract model for crud support"""
        return PostgresService(model=model, conn=self.conn)
    
    def get_model_database_schema(self):
        assert self.model is not None, "The model is empty - you should construct an instance of the postgres service as a repository(Model)"
        q = f"""SELECT 
            column_name AS field_name,
            data_type AS field_type
            FROM 
                information_schema.columns
            WHERE 
                table_name = '{self.model.get_model_name()}' -- Replace with your table name
                AND table_schema = '{self.model.get_model_namespace()}'
        """
        return self.execute(q)
    
    def register(
        self,
        plan: bool = False,
        register_entities: bool = True,
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
                self.execute(self.helper.create_embedding_table_script(),verbose_errors=False)
                logger.debug(f"Created embedding table - {self.helper.model.get_model_embedding_table_name()}")
            except DuplicateTable:
                logger.warning(f"The embedding-associated table already exists")


        if register_entities:
            logger.debug("Updating model fields")
            self.repository(ModelField).update_records(self.helper.get_model_field_models())
            
            logger.debug(f"Adding the model agent")
            self.repository(Agent).update_records(self.helper.get_model_agent_record())
        
            """the registration"""
            self.execute("select * from p8.register_entities(%s)", data=(self.helper.model.get_model_full_name(),))
            
            logger.info(f"Entity registered")
        else:
            logger.info("Done - register entities was disabled")
        
    def execute(
        cls,
        query: str,
        data: tuple = None,
        as_upsert: bool = False,
        page_size: int = 100,
        verbose_errors:bool=True
    ):
        """run any sql query - this works only for selects and transactional updates without selects
        """
        
        if cls.conn is None:
            cls._reopen_connection()
        if not query:
            return
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
        select based on the model
        """
        assert (
            self.model is not None
        ), "You need to specify a model in the constructor or via a repository to select models"

        data = None
        if kwargs:
            data = tuple(kwargs.values())
        return self.execute(self.helper.select_query(fields, **kwargs), data=data)

    def get_by_id(cls, id: str):
        """select model by id"""
        return cls.select(id=id)

    def select_to_model(self, fields: typing.List[str] = None):
        """
        like select except we construct the model objects
        """
        return [self.model.model_parse(d) for d in self.select(fields)]


    def execute_upsert(cls, query: str, data: tuple = None, page_size: int = 100):
        """run an upsert sql query"""
        return cls.execute(query, data=data, page_size=page_size, as_upsert=True)

    def update_records(
        self, records: typing.List[BaseModel], batch_size: int = 50
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
                sample = self.update_records(batch, batch_size=batch_size)
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

            return result
        else:
            logger.warning(f"Nothing to do - records is empty {records}")

