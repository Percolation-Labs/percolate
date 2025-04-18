"""
DuckModelHelper for mapping Pydantic models to DuckDB schemas.

This helper provides schema conversion, type mapping, and SQL generation 
for DuckDB operations in Embedded Percolate.
"""

import typing
import uuid
import datetime
import json
from pydantic import BaseModel
from pydantic.fields import FieldInfo

from percolate.models.AbstractModel import AbstractModel
from percolate.utils import make_uuid

class DuckModelHelper:
    """Helper for converting Pydantic models to DuckDB schemas"""
    
    def __init__(self, model: BaseModel):
        """Initialize helper for model
        
        Args:
            model: Pydantic model to map to DuckDB
        """
        self.model = AbstractModel.Abstracted(model)
        self.table_name = self.model.get_model_table_name()
        self.field_names = self.select_fields(model)
        
    @property
    def model_name(self):
        """Get fully qualified model name"""
        if self.model:
            return self.model.get_model_full_name()
        
    def __repr__(self):
        return f"DuckModelHelper({self.model_name})"
    
    @property
    def should_model_notify_index_update(self):
        """Check if model has fields requiring indexing"""
        fields = self.model.model_fields
        
        # Check config override
        index_notify = self.model.model_config.get('index_notify')
        if index_notify is not None:
            return index_notify
        
        # Check for name field (entity index)
        if 'name' in fields:
            return True
        
        # Check for embedding fields (semantic index)
        for k, v in fields.items():
            if (v.json_schema_extra or {}).get('embedding_provider'):
                return True
        
        return False
    
    @property
    def table_has_embeddings(self) -> bool:
        """Check if model has any fields with embedding attributes"""
        fields = self.model.model_fields
        
        for k, v in fields.items():
            if (v.json_schema_extra or {}).get('embedding_provider'):
                return True
        
        return False
    
    @classmethod
    def select_fields(cls, model):
        """Extract relevant fields from model for DB operations"""
        fields = []
        for k, v in model.model_fields.items():
            if v.exclude:
                continue
            attr = v.json_schema_extra or {}
            if attr.get("sql_child_relation"):
                continue
            fields.append(k)
        return fields
    
    @staticmethod
    def python_to_duckdb_type(py_type: typing.Any, field_annotation: FieldInfo = None) -> str:
        """Map Python/Pydantic types to DuckDB types
        
        Args:
            py_type: Python type annotation
            field_annotation: Optional field metadata
            
        Returns:
            DuckDB type string
        """
        # Check for field metadata overrides
        if field_annotation:
            metadata = field_annotation.json_schema_extra or {}
            if metadata.get('sql_type'):
                return metadata.get('sql_type')
        
        # DuckDB specific type mapping
        # See: https://duckdb.org/docs/stable/sql/data_types/overview.html
        type_mapping = {
            str: "VARCHAR",
            int: "BIGINT",  # Use BIGINT for safety
            float: "DOUBLE",
            bool: "BOOLEAN",
            uuid.UUID: "VARCHAR",  # DuckDB has no native UUID type
            dict: "JSON", 
            list: "JSON",
            set: "JSON",
            tuple: "JSON",
            datetime.datetime: "TIMESTAMP",
            datetime.date: "DATE",
            datetime.time: "TIME",
            typing.Any: "VARCHAR",
            bytes: "BLOB",
        }
        
        # Handle specialized string types
        if "EmailStr" in str(py_type):
            return "VARCHAR"
        
        # Direct type match
        if py_type in type_mapping:
            return type_mapping[py_type]
        
        # Handle Union types (Optional[X] is Union[X, None])
        origin = typing.get_origin(py_type)
        if origin is typing.Union or str(origin) == "<class 'types.UnionType'>":
            # Extract non-None types
            args = typing.get_args(py_type)
            non_none_args = [t for t in args if t is not type(None)]
            
            # Map each non-None type
            sub_types = [
                DuckModelHelper.python_to_duckdb_type(t, field_annotation) 
                for t in non_none_args
            ]
            
            if len(sub_types) == 1:
                return sub_types[0]
            
            # Prioritize types for unions
            for priority_type in ["VARCHAR", "JSON", "DOUBLE", "BIGINT", "BOOLEAN"]:
                if priority_type in sub_types:
                    return priority_type
            
            # Default to the first type if no priority matches
            return sub_types[0]
        
        # Handle array types - DuckDB supports native arrays
        if origin in {list, typing.List}:
            # Check if we have type args to get element type
            if hasattr(py_type, '__args__') and py_type.__args__:
                elem_type = py_type.__args__[0]
                # Simple scalar types can use array
                if elem_type in [int, float, bool, str]:
                    mapped_type = DuckModelHelper.python_to_duckdb_type(elem_type)
                    return f"{mapped_type}[]"
            # Default to JSON for complex lists
            return "JSON"
        
        # Handle Dict types
        if origin in {dict, typing.Dict}:
            return "JSON"
        
        # Handle Tuple types
        if origin in {tuple, typing.Tuple}:
            return "JSON"  # Could use STRUCT but JSON is more flexible
        
        # Handle Pydantic models (serialize as JSON)
        if hasattr(py_type, 'model_dump'):
            return "JSON"
        
        # Default fallback for unknown types
        return "VARCHAR"
    
    def create_script(self, if_not_exists: bool = True) -> str:
        """Generate CREATE TABLE script for the model
        
        Args:
            if_not_exists: Add IF NOT EXISTS clause (default True for DuckDB)
            
        Returns:
            SQL script for table creation
        """
        def is_optional(field):
            """Check if type is Optional (Union with None)"""
            origin = typing.get_origin(field)
            if origin is typing.Union or str(origin) == "<class 'types.UnionType'>":
                return type(None) in typing.get_args(field)
            return False
        
        # Get type information
        fields = typing.get_type_hints(self.model)
        field_descriptions = self.model.model_fields
        
        # Map types to DuckDB
        mapping = {
            k: self.python_to_duckdb_type(v, field_descriptions.get(k)) 
            for k, v in fields.items()
        }
        
        # Check for key field
        key_field = self.model.get_model_key_field()
        assert key_field or 'id' in mapping, f"Model {self.model} must have an id field or a key field"
        
        namespace, name = self.model.get_model_namespace(), self.model.get_model_name()
        
        # Generate column definitions
        columns = []
        
        # Add ID if not present
        if 'id' not in mapping:
            columns.append(f"id VARCHAR PRIMARY KEY")  # UUID as VARCHAR
        
        # Process all fields
        key_set = False
        for field_name, field_type in mapping.items():
            column_definition = f"{field_name} {field_type}"
            
            if field_name == 'id':
                column_definition += " PRIMARY KEY"
                key_set = True
            elif field_name in ['name', 'key']:
                key_set = True
            elif not is_optional(fields.get(field_name, None)):
                column_definition += " NOT NULL"
                
            columns.append(column_definition)
        
        if not key_set:
            raise ValueError("Model must have an id, name, or key field")
        
        # Add system fields
        for sys_field in ['created_at', 'updated_at', 'deleted_at']:
            if sys_field not in mapping:
                columns.append(f"{sys_field} TIMESTAMP")
                
        if 'user_id' not in mapping:
            columns.append("userid VARCHAR")  # UUID as VARCHAR
        
        # Build CREATE TABLE statement
        if_not_exists_clause = "IF NOT EXISTS " if if_not_exists else ""
        columns_str = ",\n    ".join(columns)
        
        # DuckDB has issues with schema "test" (it's reserved)
        # Use a prefix for the table name instead of schema for test namespaces
        if namespace.lower() == "test":
            # Use a flat table name without schema for "test" namespace
            table_name = f"{namespace}_{name}".lower()
            create_table_script = f"""
            CREATE TABLE {if_not_exists_clause}{table_name} (
                {columns_str}
            );
            """
        else:
            # For other namespaces, we can use schema
            create_schema = f"CREATE SCHEMA IF NOT EXISTS {namespace};\n"
            
            create_table_script = f"""
            {create_schema}
            CREATE TABLE {if_not_exists_clause}{namespace}.{name.lower()} (
                {columns_str}
            );
            """
        
        return create_table_script
    
    def create_embedding_table_script(self) -> str:
        """Generate script for companion embedding table
        
        Returns:
            SQL script for embedding table creation
        """
        namespace, name = self.model.get_model_namespace(), self.model.get_model_name()
        
        # For "test" namespace, use a flat table name
        if namespace.lower() == "test":
            embedding_table = f"{namespace}_{name}_embeddings".lower()
            script = f"""
            CREATE TABLE IF NOT EXISTS {embedding_table} (
                id VARCHAR PRIMARY KEY,
                source_record_id VARCHAR NOT NULL,
                column_name VARCHAR NOT NULL,
                embedding DOUBLE[],
                embedding_name VARCHAR,
                created_at TIMESTAMP
            );
            """
        else:
            embedding_table = f"{name}_embeddings".lower()
            script = f"""
            CREATE SCHEMA IF NOT EXISTS {namespace};
            
            CREATE TABLE IF NOT EXISTS {namespace}.{embedding_table} (
                id VARCHAR PRIMARY KEY,
                source_record_id VARCHAR NOT NULL,
                column_name VARCHAR NOT NULL,
                embedding DOUBLE[],
                embedding_name VARCHAR,
                created_at TIMESTAMP
            );
            """
        
        return script
    
    def upsert_query(self, batch_size, returning=None, id_field="id") -> str:
        """Generate upsert query for DuckDB
        
        Args:
            batch_size: Number of records to insert
            returning: Columns to return after operation (ignored in DuckDB)
            id_field: Primary key field name
            
        Returns:
            SQL query for upserting records
        """
        namespace = self.model.get_model_namespace().lower()
        name = self.model.get_model_name().lower()
        
        # Handle "test" namespace differently
        if namespace == "test":
            table_name = f"{namespace}_{name}"
        else:
            table_name = f"{namespace}.{name}"
        
        field_list = self.field_names
        insert_columns = ", ".join(field_list)
        
        # For multiple records, generate placeholders for each record
        all_placeholders = []
        for i in range(batch_size):
            record_placeholders = ", ".join([f"?" for _ in field_list])
            all_placeholders.append(f"({record_placeholders})")
            
        placeholders = ", ".join(all_placeholders)
        
        # DuckDB supports standard INSERT ON CONFLICT (upsert)
        # This is more efficient than DELETE + INSERT
        query = f"""
        INSERT INTO {table_name} ({insert_columns})
        VALUES {placeholders}
        ON CONFLICT ({id_field}) DO UPDATE SET
        """
        
        # Add SET clauses for each column (except ID)
        update_clauses = []
        for field in field_list:
            if field != id_field:
                update_clauses.append(f"{field} = excluded.{field}")
                
        query += ", ".join(update_clauses)
        
        return query
        
    def select_query(self, fields: typing.List[str] = None, **kwargs) -> str:
        """Generate SELECT query with optional filtering
        
        Args:
            fields: Columns to select
            **kwargs: Filter conditions
            
        Returns:
            SQL SELECT query
        """
        namespace = self.model.get_model_namespace().lower()
        name = self.model.get_model_name().lower()
        
        # Handle "test" namespace differently
        if namespace == "test":
            table_name = f"{namespace}_{name}"
        else:
            table_name = f"{namespace}.{name}"
        
        fields_str = "*"
        if fields:
            fields_str = ", ".join(fields)
        
        query = f"SELECT {fields_str} FROM {table_name}"
        
        # Add WHERE clause if needed
        if kwargs:
            conditions = []
            for key in kwargs:
                conditions.append(f"{key} = ?")
            
            where_clause = " AND ".join(conditions)
            query += f" WHERE {where_clause}"
        
        return query
        
    def serialize_for_db(self, model: BaseModel | dict) -> dict:
        """Serialize model for database storage
        
        Args:
            model: Pydantic model or dict to serialize
            
        Returns:
            Dictionary of values ready for DB insertion
        """
        # Convert to dictionary if needed
        if isinstance(model, dict):
            data = model
        elif hasattr(model, "model_dump"):
            data = model.model_dump()
        else:
            data = vars(model)
        
        # Process values for DuckDB
        def adapt(item):
            if isinstance(item, uuid.UUID):
                return str(item)
            if isinstance(item, (dict, list, tuple, set)):
                return json.dumps(item, default=str)
            # If it's already a JSON string, don't double-encode it
            if isinstance(item, str) and (item.startswith('[') or item.startswith('{')):
                try:
                    # Try to parse it as JSON to verify it's already JSON
                    json.loads(item)
                    return item
                except (json.JSONDecodeError, TypeError):
                    # Not valid JSON, treat as normal string
                    pass
            if isinstance(item, datetime.datetime):
                return item.isoformat()
            if isinstance(item, (datetime.date, datetime.time)):
                return item.isoformat()
            return item
        
        data = {k: adapt(v) for k, v in data.items()}
        
        # Generate ID if needed
        if 'id' not in data and self.model:
            business_key = self.model.get_model_key_field()
            if business_key and business_key in data:
                data['id'] = str(make_uuid(data[business_key]))
            else:
                data['id'] = str(uuid.uuid4())
        
        return data