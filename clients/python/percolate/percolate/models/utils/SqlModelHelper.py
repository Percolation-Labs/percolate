from pydantic import BaseModel
from pydantic.fields import FieldInfo
from ..AbstractModel import AbstractModel
import typing
import uuid
import datetime
import types
import json
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
    
    def create_script(cls):
        """

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

        if 'id' not in mapping:
            key_field = cls.model.get_model_key_field()
            assert key_field, "You must supply either an id or a property like name or key on the model or add json_schema_extra with an is_key property on one if your fields"
        
        """this is assumed for now"""
        id_field = 'id'
        table_name = cls.model.get_model_table_name()
        
        columns = []
        for field_name, field_type in mapping.items():
            column_definition = f"{field_name} {field_type}"
            if field_name == id_field:
                column_definition += " PRIMARY KEY "
            elif not is_optional(fields[field_name]):
                column_definition += " NOT NULL"
            columns.append(column_definition)

        """add system fields"""
        for dcol in ['created_at', 'updated_at', 'deleted_at']:
            if dcol not in mapping.keys():
                columns.append(f"{dcol} TIMESTAMP DEFAULT CURRENT_TIMESTAMP")
        if 'user_id' not in mapping.keys():
            columns.append("userid UUID")

        columns_str = ",\n    ".join(columns)
        create_table_script = f"""CREATE TABLE {table_name} (
            {columns_str}
        );

        CREATE TRIGGER update_updated_at_trigger
        BEFORE UPDATE ON {table_name}
        FOR EACH ROW
        EXECUTE FUNCTION update_updated_at_column();

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
     
        Q = f"""CREATE TABLE {cls.model.get_model_embedding_table_name()} (
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
            
            if 'TEXT[]' in union:
                return 'TEXT[]'
            raise Exception(f"Need to handle disambiguation for union types - {union}")

        if origin in {list, typing.List, tuple, typing.Tuple}:
            sub_type = py_type.__args__[0] if py_type.__args__ else typing.Any
            return f"{SqlModelHelper.python_to_postgres_type(sub_type)}{type_mapping[list]}"

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
                
            def dumping_json(d):
                return d if not isinstance(d,dict) else json.dumps(d,default=str)
                
            data = {k:dumping_json(v) for k,v in data.items()}
            
            return data