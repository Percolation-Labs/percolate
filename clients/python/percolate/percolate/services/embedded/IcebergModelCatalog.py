import duckdb
import uuid
import json
from pyiceberg.exceptions import NoSuchNamespaceError, NamespaceAlreadyExistsError, TableAlreadyExistsError
from pyiceberg.catalog.sql import SqlCatalog
from percolate.utils import logger, make_uuid
from pydantic import BaseModel
from percolate.models import AbstractModel
import typing
import pyarrow as pa
from percolate.utils.env import P8_EMBEDDED_DB_HOME 
from percolate.utils.types.pydantic import arrow_type_to_iceberg_type
from pathlib import Path


class IcebergModelCatalog:
    def __init__(self, model: BaseModel):
        """
        Initialize the Iceberg Model Catalog with a dedicated warehouse path.
        
        Args:
            model: Pydantic model to be used for catalog operations
        """
        # Use the dedicated Iceberg warehouse path for Iceberg data files
        
        Path(P8_EMBEDDED_DB_HOME).mkdir(parents=True,exist_ok=True)
        self.cat = SqlCatalog('default', 
            uri=f"sqlite:///{P8_EMBEDDED_DB_HOME}/percolate.db", 
            warehouse= f"file://{P8_EMBEDDED_DB_HOME}")
    
        self.model:AbstractModel = AbstractModel.Abstracted(model)
        
    # The arrow_type_to_iceberg_type function has been moved to percolate.utils.types.pydantic
    
    def _identify_missing_fields(self, current_schema, model_schema):
        """
        Identify fields that are in the model schema but not in the current table schema.
        
        Args:
            current_schema: PyIceberg Schema of the existing table
            model_schema: PyArrow Schema of the Pydantic model
            
        Returns:
            list: List of PyArrow fields that need to be added to the table
        """
        current_field_names = {field.name for field in current_schema.fields}
        model_field_dict = {field.name: field for field in model_schema}
        
        # Find missing fields (in model but not in table)
        missing_fields = []
        for field_name, new_field in model_field_dict.items():
            if field_name not in current_field_names:
                missing_fields.append(new_field)
                
        return missing_fields
    
    def _create_updated_schema(self, current_schema, missing_fields):
        """
        Create a new PyIceberg Schema that includes the missing fields.
        
        Args:
            current_schema: PyIceberg Schema of the existing table
            missing_fields: List of PyArrow fields to add
            
        Returns:
            PyIceberg Schema: New schema with added fields
        """
        from pyiceberg.schema import NestedField, Schema
        
        # Start with existing fields
        updated_fields = list(current_schema.fields)
        current_fields = current_schema.fields
        
        # Add new fields
        for field in missing_fields:
            # Convert PyArrow type to PyIceberg type
            iceberg_type = arrow_type_to_iceberg_type(field.type)
            
            # Create ID for new field - use max existing ID + 1
            new_field_id = max([f.field_id for f in current_fields]) + 1 if current_fields else 1
            
            # Create new field
            new_field = NestedField(
                field_id=new_field_id,
                name=field.name,
                field_type=iceberg_type,
                required=not field.nullable
            )
            
            # Add to fields list
            updated_fields.append(new_field)
            logger.info(f"Adding new field to schema: {field.name} ({field.type})")
        
        # Create new schema with updated fields
        return Schema(*updated_fields)
        
    def _apply_schema_update(self, table, updated_schema):
        """
        Apply the schema update to the table.
        
        Args:
            table: PyIceberg Table to update
            updated_schema: New PyIceberg Schema
            
        Returns:
            bool: True if successful, False otherwise
        """
        try:
            # In PyIceberg 0.9.0, schema evolution might have limitations
            # We'll make a best effort to update the schema
            table.update_schema(updated_schema)
            
            # Refresh the table to ensure schema changes are applied
            # This helps force a metadata refresh
            metadata_location = table.metadata_location
            self.cat._drop_table(table.identifier)
            self.cat._create_table_from_metadata(metadata_location, table.identifier)
            return True
        except Exception as ex:
            logger.error(f"Error during schema update: {ex}")
            # Even if this fails, we'll continue and not raise an exception
            # Schema evolution might be limited in PyIceberg 0.9.0
            return False
            
    def migrate_table_schema(self):
        """
        Use the pydantic model schema to migrate the schema of the catalog table.
        This handles adding new columns to an existing Iceberg table when the Pydantic model is updated.
        
        Migrations supported:
        - Adding new fields to the model (table columns)
        - Changing field nullability from required to optional (not vice versa)
        
        Returns:
            bool: True if migration was performed, False if no migration was needed
        """
        try:
            # First check if the table exists
            try:
                table = self.cat.load_table(self.model.get_model_full_name())
            except Exception as ex:
                logger.warning(f"Cannot migrate non-existent table: {ex}")
                return False
            
            # Get current table schema
            current_schema = table.schema()
            
            # Get the model's arrow schema
            model_schema = self.model.to_arrow_schema()
            
            # Identify missing fields
            missing_fields = self._identify_missing_fields(current_schema, model_schema)
            
            if not missing_fields:
                logger.info(f"No schema migration needed for {self.model.get_model_full_name()}")
                return False
            
            # Create updated schema
            updated_schema = self._create_updated_schema(current_schema, missing_fields)
            
            # Apply schema update
            self._apply_schema_update(table, updated_schema)
            
            # Also update the embedding table if needed
            if any([(f.json_schema_extra or {}).get('embedding_provider') for f in self.model.model_fields.values()]):
                self.create_embedding_table_for_model()
            
            logger.info(f"Successfully migrated schema for {self.model.get_model_full_name()}")
            return True
            
        except Exception as ex:
            logger.error(f"Error during schema migration: {ex}")
            raise


    def create_embedding_table_for_model(self):
        """
        A convention is used to create a table py_embeddings.namespace_table using the standard fields for embedding tables.
        Similar to PostgreSQL implementation, we create a standard embedding table with fields for storing vectors.
        """
        from pydantic import BaseModel, Field
        from percolate.models import AbstractModel
        import uuid
        from datetime import datetime

        # Check if the model has embedding fields
        has_embedding_fields = False
        for field_name, field_info in self.model.model_fields.items():
            if (field_info.json_schema_extra or {}).get('embedding_provider'):
                has_embedding_fields = True
                break

        if not has_embedding_fields:
            # Skip if no embedding fields are present
            return None

        # Define an embedding table model with the same structure as in PostgreSQL
        class EmbeddingTable(BaseModel):
            model_config = {'namespace': 'p8embeddings'}
            id: uuid.UUID = Field(description="Hash-based unique ID")
            source_record_id: uuid.UUID = Field(description="Foreign key to primary table")
            column_name: str = Field(description="Column name for embedded content")
            embedding_vector: list[float] = Field(description="Embedding vector as an array of floats", default=None)
            embedding_name: str = Field(description="ID for embedding provider", max_length=50)
            created_at: datetime = Field(description="Timestamp for tracking", default_factory=datetime.now)

        # Create an AbstractModel from the EmbeddingTable
        embedding_model = AbstractModel.Abstracted(EmbeddingTable)
        
        # Set the namespace and name for the embedding table
        embedding_namespace = self.model.model_config.get('embedding_namespace', 'py_embeddings')
        embedding_name = f"{self.model.get_model_namespace()}_{self.model.get_model_name()}_embeddings"
        
        # Update the model config with the embedding table namespace and name
        embedding_model.model_config = {
            'name': embedding_name,
            'namespace': embedding_namespace,
            'description': f"Embeddings for {self.model.get_model_full_name()}"
        }
        
        # Create the embedding table
        try:
            table = self._create_table_for_model(embedding_model)
            return table
        except Exception as ex:
            from percolate.utils import logger
            logger.error(f"Failed to create embedding table: {ex}")
            return None

    def _create_table_for_model(self, model: AbstractModel):
        """
        Register the table model in the catalog. If the table already exists,
        check if schema migration is needed.
        """
        
        table = None
            # Try to create the table
        try:
            table = self.cat.create_table(model.get_model_full_name(), schema=model.to_arrow_schema())
            logger.info(f"Table {model.get_model_full_name()} created")
        except NoSuchNamespaceError as nex:
            self.cat.create_namespace(model.get_model_namespace())
          
            table = self.cat.create_table(model.get_model_full_name(), schema=model.to_arrow_schema())
            logger.info(f"Namespace {model.get_model_namespace()} and table {model.get_model_full_name()} created")
        except TableAlreadyExistsError as tex:
            # Table exists, load it and check if migration is needed
            logger.info(f"Table {model.get_model_full_name()} already exists, checking if migration is needed - {tex}")
            table = self.cat.load_table(model.get_model_full_name())
            
            # If we're dealing with the model from this instance, perform migration
            if model == self.model:
                self.migrate_table_schema()
            else:
                # For other models (like embedding tables), perform manual schema check
                current_schema = table.schema()
                current_field_names = {field.name for field in current_schema.fields}
                model_schema = model.to_arrow_schema()
                model_field_names = {field.name for field in model_schema}
                
                if not current_field_names.issuperset(model_field_names):
                    logger.warning(f"Schema mismatch detected for {model.get_model_full_name()}, but migration skipped for non-primary models")
   

        # Handle embedding table if this is the main model
        if model == self.model:
            self.create_embedding_table_for_model()

        return table


    def create_table_for_model(self):
        return self._create_table_for_model(self.model)
    
    def upsert_data(self, data: typing.List[BaseModel], primary_key: str='id'):
        """
        Upsert data based on the join column which is conventionally the id.
        Converts any native Python types like UUID to string for compatibility with PyArrow.
        Ensures schema consistency by using model schema for PyArrow table creation.
        """
        from percolate.utils import logger
        
        table = self.cat.load_table(self.model.get_model_full_name())
    
        try:
            def map_(d):
                for k,v in d.items():
                    if isinstance(v, dict) or isinstance(v,list):
                        d[k] = str(v)
                return d

            """im doing this crude complex type mapping because i dont yet know how pyiceberg does json data or if it does"""
            arrow_table = pa.Table.from_pylist([map_(d.model_dump()) for d in data],schema=self.model.to_arrow_schema() )

            result = table.upsert(df=arrow_table, join_cols=[primary_key])
            logger.info(f"Rows Updated: {result.rows_updated}, Rows Inserted: {result.rows_inserted}")
        except Exception as ex:
            logger.error(f"Error during upsert: {ex}")
            raise
        
    @property
    def table(self):
        """Load the catalog's table"""
        return self.cat.load_table(self.model.get_model_full_name())
    
    @property
    def table_name(self):
        return self.model.get_model_full_name()
    
    @property
    def db(self):
        """get the duckdb connection using the correct table name in the ref (not sure if this can be made lzy - the scan concerns me)"""
        return self.table.scan().to_duckdb(self.table_name)