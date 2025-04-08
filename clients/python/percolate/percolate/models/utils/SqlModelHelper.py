from pydantic import BaseModel
from pydantic.fields import FieldInfo
from ..AbstractModel import AbstractModel
import typing
import uuid
import datetime
import types
import json
from percolate.utils import make_uuid
class SqlModelHelper:
    def __init__(cls, model: BaseModel):
        cls.model:AbstractModel = AbstractModel.Abstracted(model)
        cls.table_name = cls.model.get_model_table_name()
        cls.field_names = SqlModelHelper.select_fields(model)
        cls.metadata = {}
        
    @property
    def model_name(cls):
        if cls.model:
            return cls.model.get_model_full_name()
        
    def __repr__(self):
        return f"SqlModelHelper({self.model_name})"
    
    @property
    def should_model_notify_index_update(self):
        """
        this is for most models that have either a name or an embedding
        """
        fields = self.model.model_fields
        """example of disable or force enable in special cases"""
        index_notify = self.model.model_config.get('index_notify')
        if index_notify is not None:
            return index_notify
        """always in this case for graph entity by convention unless disabled"""
        if 'name' in fields:
            return True
        """and always if there are embeddings"""
        for k,v in fields.items():
            if (v.json_schema_extra or{}).get('embedding_provider'):
                return True
        """otherwise skip it"""
        return False
        
    def create_script(cls,if_not_exists:bool = False):
        """

        Args:
            if_not_exists: by default we try and fail to create for schema migration - but initially set this to True to create a clean DB
            
        (WIP) generate tables for entities -> short term we do a single table with now schema management
        then we will add basic migrations and split out the embeddings + add system fields
        we also need to add the other embedding types - if we do async process we need a metadata server
        we also assume the schema exists for now

        We will want to create embedding tables separately and add a view that joins them
        This creates a transaction of three scripts that we create for every entity
        We should add the created at and updated at system fields and maybe a deleted one

        - key register trigger -> upsert into type-name -> on-conflict do nothing

        - we can check existing columns and use an alter to add new ones if the table exists

        """
       
        def is_optional(field):
            return typing.get_origin(field) is typing.Union and type(
                None
            ) in typing.get_args(field)
            
        fields = typing.get_type_hints(cls.model)
        field_descriptions = cls.model.model_fields
        mapping =  {k:SqlModelHelper.python_to_postgres_type(v, field_descriptions.get(k)) for k,v in fields.items()}

 
        key_field = cls.model.get_model_key_field()
        assert key_field or 'id' in mapping, f"For model {cls.model}, You must supply either an id or a property like name or key on the model or add json_schema_extra with an is_key property on one if your fields"
        
        """this is assumed for now"""
        
        table_name = cls.model.get_model_table_name()
        
        columns = []
        """Percolate controls the id as a function of a business key or name"""
        if 'id' not in mapping:
            columns.append(f"ID UUID PRIMARY KEY")
            
        key_set = False
        for field_name, field_type in mapping.items():
            column_definition = f"{field_name} {field_type}"
            if field_name == 'id':
                column_definition += " PRIMARY KEY "
            if field_name in ['name','key', 'id']:
                key_set = True
            elif not is_optional(fields[field_name]):
                column_definition += " NOT NULL"
            columns.append(column_definition)

        if not key_set:
            raise ValueError("The model input does not specify a key field. Add a name or key field or specify is_key on one of your fields")
        """add system fields"""
        for dcol in ['created_at', 'updated_at', 'deleted_at']:
            if dcol not in mapping.keys():
                columns.append(f"{dcol} TIMESTAMP DEFAULT CURRENT_TIMESTAMP")
        if 'user_id' not in mapping.keys():
            columns.append("userid UUID")

        if_not_exists_flag = '' if not if_not_exists else " IF NOT EXISTS "
        columns_str = ",\n    ".join(columns)
        create_table_script = f"""CREATE TABLE {if_not_exists_flag} {table_name} (
{columns_str}
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON {table_name};
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON {table_name}
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        """
    
        #in some case we will attach the notify by calling this function attach_notify_trigger_to_table(schema_name TEXT, table_name TEXT)
              
        if cls.should_model_notify_index_update:
            create_table_script += f"""
SELECT attach_notify_trigger_to_table('{cls.model.get_model_namespace()}', '{cls.model.get_model_name()}');
            """
        
        return create_table_script

    def upsert_query(
        cls,
        batch_size: int,
        returning="*",  # ID, * etc.
        restricted_update_fields: str = None,
        id_field: str = 'id' # by convention
        # records: typing.List[typing.Any],
        # TODO return * or just id for performance
    ):
        """upserts on the ID conflict

        if deleted at set generate another query to set deleted dates for records not in the id list

        This will return a batch statement for some placeholder size. You can then

        ```
        connector.run_update(upsert_sql(...), batch_data)

        ```

        where batch data is some collection of items

        ```
        batch_data = [
            {"id": 1, "name": "Sample1", "description": "A sample description 1", "value": 10.5},
            {"id": 2, "name": "Sample2", "description": "A sample description 2", "value": 20.5},
            {"id": 3, "name": "Sample3", "description": "A sample description 3", "value": 30.5},
        ]
        ```
        """

        if restricted_update_fields is not None and not len(restricted_update_fields):
            raise ValueError("You provided an empty list of restricted field")

        """TODO: the return can be efficient * for example pulls back embeddings which is almost never what you want"""
        field_list = cls.field_names
        """conventionally add in order anything that is added in upsert and missing"""
        for c in restricted_update_fields or []:
            if c not in field_list:
                field_list.append(c)

        non_id_fields = [f for f in field_list if f != id_field]
        insert_columns = ", ".join(field_list)
        insert_values = ", ".join([f"%({field})s" for field in field_list])

        """restricted updated fields are powerful for updates 
           we can ignore the other columns in the inserts and added place holder values in the update
        """
        update_set = ", ".join(
            [
                f"{field} = EXCLUDED.{field}"
                for field in restricted_update_fields or non_id_fields
            ]
        )

        value_placeholders = ", ".join(
            [f"({insert_values})" for _ in range(batch_size)]
        )

        # ^old school way but for psycopg2.extras.execute_values below is good
        value_placeholders = "%s"

        """batch insert with conflict - prefix with a delete statement that sets items to deleted"""
        upsert_statement = f"""
        -- now insert
        INSERT INTO {cls.table_name} ({insert_columns})
        VALUES {value_placeholders}
        ON CONFLICT ({id_field}) DO UPDATE
        SET {update_set}
        RETURNING {returning};
        """

        return upsert_statement.strip()
    
    @classmethod
    def select_fields(cls, model):
        """select db relevant fields"""
        fields = []
        for k, v in model.model_fields.items():
            if v.exclude:
                continue
            attr = v.json_schema_extra or {}
            """we skip fields that are complex"""
            if attr.get("sql_child_relation"):
                continue
            fields.append(k)
        return fields   
    


    @property
    def table_has_embeddings(self)->bool:
        """TODO return true if one or more columns have embeddings"""
        return True
        
    def select_query(self, fields: typing.List[str] = None, **kwargs):
        """
        if kwargs exist we use to add predicates
        """
        fields = fields or ",".join(self.field_names)

        if not kwargs:
            return f"""SELECT { fields } FROM {self.table_name} """
        predicate = SqlModelHelper.construct_where_clause(**kwargs)
        return f"""SELECT { fields } FROM {self.table_name} {predicate}"""
    
    
    @classmethod
    def construct_where_clause(cls, **kwargs) -> str:
        """
        Constructs a SQL WHERE clause from keyword arguments.

        Args:
            **kwargs: Column-value pairs where:
                - Strings, dates, and other scalar types are treated as equality (col = %s).
                - Lists are treated as ANY operator (col = ANY(%s)).

        Returns:
            predicate string
        """
        where_clauses = []
        params = []

        for column, value in kwargs.items():
            if isinstance(value, list):

                where_clauses.append(f"{column} = ANY(%s)")
                params.append(value)
            else:

                where_clauses.append(f"{column} = %s")
                params.append(value)

        where_clause = " AND ".join(where_clauses)

        return f"WHERE {where_clause}" if where_clauses else ""
    
    def create_embedding_table_script(cls)->str:
        """
        Given a model, we create the corresponding embeddings table
        
        """
     
        Q = f"""CREATE TABLE  IF NOT EXISTS {cls.model.get_model_embedding_table_name()} (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_{cls.model.get_model_full_name().replace('.','_').lower()}
        FOREIGN KEY (source_record_id) REFERENCES {cls.table_name}
        ON DELETE CASCADE
);
"""
        return Q
    
    def try_generate_migration_script(self, field_list: typing.List[dict]) ->str:
        """
        pass in fields like this 
        
        [{'field_name': 'name', 'field_type': 'character varying'},
        {'field_name': 'id', 'field_type': 'uuid'},
        {'field_name': 'entity_name', 'field_type': 'character varying'},
        {'field_name': 'field_type', 'field_type': 'character varying'},
        {'field_name': 'deleted_at', 'field_type': 'timestamp without time zone'},
        {'field_name': 'userid', 'field_type': 'uuid'}]
        
        We will add any new fields but we will not remove or modify existing fields yet
        """
        
        field_names = [f['field_name'] for f in field_list]
        fields = typing.get_type_hints(self.model)
        field_descriptions = self.model.model_fields
        new_fields = set(fields.keys()) - set(field_names)
        script = None
        if new_fields:
            script = ""
            for f in new_fields:
                ptype = SqlModelHelper.python_to_postgres_type(fields[f], field_descriptions.get(f))
                script += f"ALTER TABLE {self.table_name} ADD COLUMN {f} {ptype}; "
        return script
    
    @staticmethod
    def python_to_postgres_types(model: BaseModel):
        """map postgres from pydantic types
        - sometimes we use attributes on the fields to coerce otherwise we map defaults from python types
        - an example mapping would be a VARCHAR length which woudl otherwise default to TEXT
        """
        fields = typing.get_type_hints(model)
        field_descriptions = model.model_fields

        return {k:SqlModelHelper.python_to_postgres_type(v, field_descriptions.get(k)) for k,v in fields.items()}
          
    @staticmethod      
    def python_to_postgres_type(py_type: typing.Any, field_annotation: FieldInfo = None) -> str:
        """
        Maps Python types to PostgreSQL types.
        The field hints can be added as overrides to what we would use by default for types
        """

        if field_annotation:
            metadata = field_annotation.json_schema_extra or {}
            if metadata.get('varchar_length'):
                return f"VARCHAR({metadata.get('varchar_length')})"
            if metadata.get('sql_type'):
                return metadata.get('sql_type')
        
        type_mapping = {
            str: "TEXT",
            int: "INTEGER",
            float: "REAL",
            bool: "BOOLEAN",
            uuid.UUID: "UUID",
            dict: "JSON",
            list: "[]",
            set: "[]",
            tuple: "ARRAY",
            datetime.datetime: "TIMESTAMP",
            typing.Any: "TEXT",  
        }

        if "EmailStr" in str(py_type):
            return "TEXT"

        if py_type in type_mapping:
            return type_mapping[py_type]

        origin = typing.get_origin(py_type)
        if origin is typing.Union or origin is types.UnionType:
            sub_types = [SqlModelHelper.python_to_postgres_type(t) for t in py_type.__args__ if t is not type(None)] 
            if len(sub_types) == 1:
                return sub_types[0]  
            
            if 'UUID' in sub_types:
                return "UUID" #precedence

            union =  f"UNION({', '.join(sub_types)})" 
            
            if 'JSON' in union:
                return "JSON"
            if 'TEXT[]' in union:
                return 'TEXT[]'
            if 'TIMESTAMP' in union:
                return 'TIMESTAMP'
            
            raise Exception(f"Need to handle disambiguation for union types - {union}")

        if origin in {list, typing.List, tuple, typing.Tuple}:
            sub_type = py_type.__args__[0] if py_type.__args__ else typing.Any
            pg_type = SqlModelHelper.python_to_postgres_type(sub_type)
            """decide if we want json arrays or just json"""
            if pg_type == 'JSON':
                return pg_type
            return f"{pg_type}{type_mapping[list]}"

        if origin in {dict, typing.Dict}:
            return type_mapping[dict]

        if hasattr(py_type, 'model_dump'):
            return "JSON"

        raise ValueError(f"Unsupported type: {py_type}")
    
    def get_model_field_models(self):
        """wraps the field from model method"""
        from percolate.models.p8 import ModelField
        return ModelField.get_fields_from_model(self.model)
    
    def get_model_agent_record(self):
        """wraps the agent from model method"""
        from percolate.models.p8 import Agent
        return Agent.from_abstract_model(self.model)
    
    def serialize_for_db(cls, model: dict|BaseModel, index:int=-1):
            """this exists only to allow for generalized types
            abstract models can implement model_dump to have an alt serialization path
            """
            if isinstance(model, dict):
                data = model
            elif hasattr(model, "model_dump"):
                data = model.model_dump()
            else:
                data = vars(model) 
                
            def adapt(item):
                """we could implement SQL a little better - but needs more work"""
                if isinstance(item, str):
                    """i dont love this TODO"""
                    return item.replace("'", "''")
                if isinstance(item, uuid.UUID):
                    return str(item)
                if isinstance(item, dict):
                    return json.dumps(item,default=str)
                if isinstance(item, list) and len(item) and isinstance(item[0],dict):
                    return json.dumps(item,default=str)
                return item
                 
            data = {k:adapt(v) for k,v in data.items()}
            if 'id' not in data:
                business_key = model.get_model_key_field()
                """if there is no id we always hash the business key on the model and use it
                we will recommend that an ID and name are provided for models that want to save data. This is a unique id and a user friendly name pairing
                """
                data['id'] = make_uuid(data[business_key])
                            
            return data
        
    def get_data_load_statement(self, records: typing.List[BaseModel]):
        """Generate the insert statement for the data"""

        if not isinstance(records, list):
            records = [records]

        def sql_repr(value):
            """Properly escape SQL values"""
            if value is None:
                return 'NULL'
            if isinstance(value, str):
                return f"""'{value.replace("'", "''")}'"""
            return str(value)

        if not records:
            return ""

        sample = self.serialize_for_db(records[0])
        cols = ", ".join(sample.keys())
        values = ",\n ".join(
            f"({', '.join([sql_repr(v) for v in self.serialize_for_db(obj).values()])})"
            for obj in records
        )

        conflict_cols = [c for c in sample.keys() if c != "id"]
        conflicts = ", ".join(f"{col} = EXCLUDED.{col}" for col in conflict_cols)

        table_name = self.model.get_model_table_name()

        return f"""INSERT INTO {table_name} ({cols}) VALUES
    {values}
    ON CONFLICT (id) DO UPDATE SET {conflicts};"""        
    
    # def get_data_load_statement(self, records: typing.List[BaseModel]):
    #     """Generate the insert statement for the data"""
        
    #     if not isinstance(records,list):
    #         records = [records]
            
    #     def sql_repr(s):
    #         """WIP - use SQL properly"""
    #         return repr(s if not isinstance(s,str) else s.replace("'","''"))  if s else 'NULL'
        
    #     if len(records):
            
    #         sample = self.serialize_for_db(records[0])
    #         cols = f",".join(sample.keys())
    #         values = ",\n ".join(  f"({', '.join([sql_repr(v) for _,v in self.serialize_for_db(obj).items() ])})" for obj in records)
    #         #TODO it may be that id is not always what we want
    #         conflicts =  f",".join([f"{f}=EXCLUDED.{f}" for f in [c for c in sample.keys() if c not in ['id']]])
    #         return f"""INSERT INTO {self.model.get_model_table_name()}({cols}) VALUES\n {values}
    #     ON CONFLICT (id) DO UPDATE SET {conflicts}   ;"""
        
    def get_register_entities_query(self):
        """get the registration script for entities that have names and add the initial entities for testing to the graph"""
        
        if 'name' in self.model.model_fields:
            return  f"""select * from p8.register_entities('{self.model.get_model_full_name()}');"""