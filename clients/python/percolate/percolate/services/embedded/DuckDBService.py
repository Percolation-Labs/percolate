"""
DuckDB Service implementation for Embedded Percolate

This service handles SQL and vector search operations using DuckDB for local,
file-based storage as an alternative to PostgreSQL.
"""

import os
import uuid
import json
import asyncio
import typing
import datetime
from loguru import logger
import duckdb
from pydantic import BaseModel
from tenacity import retry, stop_after_attempt, wait_fixed

from percolate.models.AbstractModel import ensure_model_not_instance, AbstractModel
from percolate.utils import batch_collection, make_uuid
from percolate.utils.env import P8_EMBEDDED_DB_HOME 
from .DuckDBSqlHelper import DuckModelHelper
from .utils import PyIcebergHelper
from .IcebergModelCatalog import IcebergModelCatalog

class DuckDBService:
    """DuckDB implementation of Percolate storage service"""
    
    def __init__(self, model: BaseModel = None, db_path: str = None):
        """Initialize DuckDB service
        
        Args:
            model: Optional Pydantic model for repository operations
            db_path: Path to DuckDB database file (defaults to ~/.percolate/storage/duckdb/p8.db)
        """
        self.model = None
        self.helper = None
        self.conn = None
        
        # Use the specific DuckDB path
        self.db_path = None#db_path or P8_DUCKDB_PATH
        
        try:
            #self.conn = self._connect()
            #self._setup_extensions()
            self.helper = DuckModelHelper(AbstractModel)
            
            if model:
                self.model = AbstractModel.Abstracted(ensure_model_not_instance(model))
                self.helper = DuckModelHelper(model)
                
        except Exception as e:
            logger.warning(f"Failed to initialize DuckDBService: {e}")
            raise
    
    def _connect(self):
        """Connect to DuckDB database"""
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        return duckdb.connect(self.db_path)
    
    def _setup_extensions(self):
        """Set up required DuckDB extensions"""
        # Install and load VSS for vector search
        self.conn.execute("INSTALL vss;")
        self.conn.execute("LOAD vss;")
        
        # Install and load Iceberg for direct Iceberg table access if available
        try:
            from percolate.utils.env import P8_ICEBERG_WAREHOUSE, PERCOLATE_USE_PYICEBERG
            
            if PERCOLATE_USE_PYICEBERG:
                # Try to load the Iceberg extension if available
                try:
                    self.conn.execute("INSTALL iceberg;")
                    self.conn.execute("LOAD iceberg;")
                
                    # Check if the iceberg_catalog function exists
                    catalog_check = self.conn.execute(
                        "SELECT COUNT(*) as exists FROM duckdb_functions() WHERE function_name = 'iceberg_catalog'"
                    ).fetchone()
                    
                    if catalog_check and catalog_check[0] > 0:
                        # Use iceberg_catalog if available 
                        self.conn.execute(f"CALL iceberg_catalog('percolate', 'file://{P8_ICEBERG_WAREHOUSE}')")
                        logger.info(f"Registered Iceberg catalog 'percolate' with warehouse at {P8_ICEBERG_WAREHOUSE}")
                    else:
                        # Use alternative iceberg_scan approach for older versions
                        logger.info(f"Using iceberg_scan for Iceberg integration (iceberg_catalog not available)")
                        # We'll use iceberg_scan directly in queries
                        
                except Exception as e:
                    logger.debug(f"Error loading Iceberg extension: {e}")
        except Exception as e:
            logger.warning(f"Failed to set up Iceberg integration: {e}")
            # Non-critical error, we can continue without Iceberg integration
    
    def __repr__(self):
        return f"DuckDBService({self.model.get_model_full_name() if self.model else None}, {self.db_path})"
    
    @property
    def entity_exists(self):
        """Check if entity table exists"""
        return self.check_entity_exists()
    
    def check_entity_exists(self):
        """Check if model's table exists in database
        
        This method checks both IcebergModelCatalog format (namespace.table) 
        and traditional SQL format (table_name)
        """
        assert self.model, "Model is required to check if entity exists"
        
        namespace = self.model.get_model_namespace().lower()
        name = self.model.get_model_name().lower()
        
        # Try multiple approaches to find the table
        try:
            # First check - try IcebergModelCatalog directly
            try:
                # Create catalog for the model
                catalog = IcebergModelCatalog(self.model)
                
                try:
                    # If table load succeeds, it exists
                    catalog.cat.load_table(self.model.get_model_full_name())
                    logger.debug(f"Table {self.model.get_model_full_name()} exists in Iceberg catalog")
                    return True
                except Exception as ex:
                    # If load fails, table doesn't exist in Iceberg catalog
                    logger.debug(f"Table {self.model.get_model_full_name()} not found in Iceberg catalog: {ex}")
            except Exception as ex:
                logger.debug(f"Error checking Iceberg catalog: {ex}")
            
            # Second check - using namespace.table_name format in DuckDB
            if namespace != "test":
                iceberg_query = """
                SELECT count(*) as exists FROM information_schema.tables 
                WHERE (table_schema = ? AND table_name = ?)
                   OR (table_name = ?)
                """
                iceberg_result = self.execute(iceberg_query, data=(namespace, name, f"{namespace}.{name.lower()}"))
                if iceberg_result and len(iceberg_result) > 0 and iceberg_result[0]['exists'] > 0:
                    logger.debug(f"Table {namespace}.{name} exists in DuckDB information_schema")
                    return True
            
            # Third check - using namespace_table format (common for test namespace)
            sql_query = """
            SELECT count(*) as exists FROM information_schema.tables 
            WHERE table_name = ?
            """
            sql_table_name = f"{namespace}_{name}"
            sql_result = self.execute(sql_query, data=(sql_table_name,))
            if sql_result and len(sql_result) > 0 and sql_result[0]['exists'] > 0:
                logger.debug(f"Table {sql_table_name} exists in DuckDB information_schema")
                return True
                
            # Fourth check - try direct access to see if table is accessible
            try:
                # Generate a query that limits to 1 row to minimize data transfer
                if namespace == "test":
                    # For test namespace, use the prefixed table name format
                    test_query = f"SELECT * FROM {namespace}_{name} LIMIT 1"
                else:
                    # For non-test namespaces, try with schema name
                    test_query = f"SELECT * FROM {namespace}.{name} LIMIT 1"
                
                # If query succeeds, table exists
                self.execute(test_query)
                logger.debug(f"Table {namespace}.{name} exists based on direct query")
                return True
            except Exception as ex:
                # If query fails, we'll try the other formats
                logger.debug(f"Direct table query failed: {ex}")
                
            # If we get here, table doesn't exist
            logger.debug(f"Table {namespace}.{name} does not exist after all checks")
            return False
            
        except Exception as e:
            logger.warning(f"Error checking if entity exists: {e}")
            return False
    
    def repository(self, model: BaseModel, **kwargs) -> "DuckDBService":
        """Create repository for specific model"""
        return DuckDBService(model=model, db_path=self.db_path, **kwargs)
    
    def register(
        self,
        plan: bool = False,
        register_entities: bool = True,
        make_discoverable: bool = False,
        create_indexes: bool = True,
    ):
        """Register model and create required tables using IcebergModelCatalog
        
        Args:
            plan: If True, only return script without executing
            register_entities: If True, register entity in graph database
            make_discoverable: If True, make entity available as a function
            create_indexes: If True, create vector indexes on embedding tables
        """
        assert self.model is not None, "Model is required for registration"
        
 
        # Use IcebergModelCatalog for table creation, embedding table creation and schema management
        try:
            # Create a catalog for this model
            catalog = IcebergModelCatalog(self.model)
            
            # Create the main table
            table = catalog.create_table_for_model()
            logger.info(f"Created/verified table {self.model.get_model_full_name()} using IcebergModelCatalog")
            
            # The embedding table is automatically created if needed by create_table_for_model
            
            # Create indexes for embedding table if requested
            if create_indexes and self.helper.table_has_embeddings:
                self._create_vector_indexes(catalog)
                
        except Exception as e:
            logger.warning(f"Table creation failed with IcebergModelCatalog: {e}")
            # Fall back to SQL-based creation if IcebergModelCatalog fails
            try:
                script = self.helper.create_script()
                self.execute(script)
                logger.debug(f"Created table {self.helper.model.get_model_table_name()} with SQL fallback")
                
                # Create embedding table if needed
                if self.helper.table_has_embeddings:
                    embedding_script = self.helper.create_embedding_table_script()
                    self.execute(embedding_script)
                    logger.debug(f"Created embedding table with SQL fallback")
            except Exception as sql_error:
                logger.error(f"SQL fallback table creation also failed: {sql_error}")
                raise
                
        # Register with graph database if requested
        if register_entities and 'name' in self.helper.model.model_fields:
            from .KuzuDBService import KuzuDBService
            try:
                kuzu = KuzuDBService()
                kuzu.register_entity(self.model.get_model_full_name())
                logger.info(f"Entity registered in graph database")
            except Exception as e:
                logger.warning(f"Graph registration failed: {e}")
                
        logger.info("Registration complete")
        return "Registration successful"
    
    def _create_vector_indexes(self, catalog: IcebergModelCatalog):
        """Create vector indexes for embedding tables
        
        Args:
            catalog: IcebergModelCatalog instance for the model
        """
        try:
            # Get embedding fields from the model
            embedding_fields = []
            for field_name, field_info in self.model.model_fields.items():
                if (field_info.json_schema_extra or {}).get('embedding_provider'):
                    embedding_fields.append(field_name)
            
            if not embedding_fields:
                return
            
            # Get embedding table name
            namespace = self.model.get_model_namespace().lower()
            name = self.model.get_model_name().lower()
            
            if namespace.lower() == "test":
                embedding_table = f"{namespace}_{name}_embeddings"
            else:
                embedding_namespace = "py_embeddings"
                embedding_table = f"{embedding_namespace}.{namespace}_{name}_embeddings"
            
            # Create vector index on embedding column
            # DuckDB uses the VSS extension for vector search
            try:
                # Ensure VSS extension is loaded
                self.conn.execute("INSTALL vss;")
                self.conn.execute("LOAD vss;")
                
                # Create index for each embedding field
                for field in embedding_fields:
                    index_name = f"idx_vector_{namespace}_{name}_{field}"
                    
                    # Drop if exists to prevent errors
                    self.conn.execute(f"DROP INDEX IF EXISTS {index_name}")
                    
                    # Create the vector index
                    index_query = f"""
                    CREATE INDEX {index_name} ON {embedding_table} (
                        embedding_vector vss_cosine_distance
                    ) USING vss WHERE column_name = '{field}'
                    """
                    self.conn.execute(index_query)
                    logger.info(f"Created vector index {index_name} on {embedding_table}")
                    
            except Exception as e:
                logger.warning(f"Failed to create vector index: {e}")
                
        except Exception as e:
            logger.warning(f"Vector index creation failed: {e}")
            # Non-critical error, continue
    
    def update_records(
        self, records: typing.List[BaseModel], batch_size: int = 1000, index_entities: bool = False
    ):
        """Upsert records to database using IcebergModelCatalog with direct DuckDB integration
        
        Args:
            records: List of model instances to insert/update
            batch_size: Size of batches for processing
            index_entities: If True, build indexes after insertion
        """
        if records and not isinstance(records, list):
            records = [records]
            
        if not records:
            logger.warning("No records to update")
            return
            
        if self.model is None:
            return self.repository(records[0]).update_records(
                records=records, batch_size=batch_size, index_entities=index_entities
            )
            
        # Process in batches if needed
        if len(records) > batch_size:
            logger.info(f"Processing {len(records)} records in batches of {batch_size}")
            results = []
            for batch in batch_collection(records, batch_size=batch_size):
                result = self.update_records(batch, batch_size=batch_size, index_entities=False)
                results.append(result)
                
            # Build indexes after all batches if requested
            if index_entities and asyncio:
                # Postponed: index building will be implemented later
                logger.info("Async index building requested but postponed")
                
            return results
        
        # Identify primary key
        id_field = "id"  # Default
        key_field = self.model.get_model_key_field()
        if key_field:
            id_field = key_field
        
        try:
            # Create catalog for this model - using IcebergModelCatalog is now required
            catalog = IcebergModelCatalog(self.model)
            
            # Ensure the table exists by attempting to create it
            # This will handle schema migration if needed
            table = catalog.create_table_for_model()
            
            # Ensure DuckDB Iceberg integration is set up
            # This makes the tables available directly to DuckDB queries
            from percolate.utils.env import PERCOLATE_USE_PYICEBERG, P8_ICEBERG_WAREHOUSE
            if PERCOLATE_USE_PYICEBERG:
                if self.conn is None:
                    self.conn = self._connect()
                    self._setup_extensions()
                
                try:
                    # Make sure the Iceberg extension and catalog are loaded
                    self.conn.execute("INSTALL iceberg;")
                    self.conn.execute("LOAD iceberg;")
                    self.conn.execute(f"CALL iceberg_catalog('percolate', 'file://{P8_ICEBERG_WAREHOUSE}')")
                except Exception as e:
                    logger.debug(f"Iceberg setup in update_records: {e}")
                    # Non-critical error, continue with operation
            
            # Perform upsert using the catalog
            catalog.upsert_data(records, primary_key=id_field)
            
            logger.info(f"Successfully upserted {len(records)} records with IcebergModelCatalog")
            
            # For verification/testing, fetch the inserted records
            if len(records) == 1:
                # If single record, return it
                record_id = self.helper.serialize_for_db(records[0])['id']
                return self.select(id=record_id)
            else:
                # Just return success for bulk inserts
                return {"status": "success", "count": len(records)}
                
        except Exception as e:
            # If upsert failed, use the SQL-based fallback
            logger.warning(f"IcebergModelCatalog upsert failed: {e}, falling back to SQL")
            return self._sql_upsert_fallback(records)
            
    def _sql_upsert_fallback(self, records):
        """Fallback to SQL-based upsert when IcebergModelCatalog fails"""
        query = None  # Initialize query variable outside try block for exception reporting
        try:
            # Ensure table exists
            namespace = self.model.get_model_namespace().lower()
            name = self.model.get_model_name().lower()
            table_identifier = f"{namespace}_{name}" if namespace.lower() == "test" else f"{namespace}.{name}"
            
            if not self.check_entity_exists():
                logger.info(f"Table {table_identifier} does not exist. Creating...")
                script = self.helper.create_script()
                self.execute(script)
                
                # Register table with IcebergModelCatalog if possible 
                try:
                    catalog = IcebergModelCatalog(self.model)
                    catalog.create_table_for_model()
                    logger.info(f"Registered table {table_identifier} with IcebergModelCatalog after SQL fallback creation")
                except Exception as ex:
                    logger.warning(f"Failed to register table with IcebergModelCatalog after SQL creation: {ex}")
            
            # Generate upsert query and prepare parameter data
            query = self.helper.upsert_query(batch_size=len(records))
            
            # Convert records to a flat list of values for DuckDB parameters
            values = []
            for record in records:
                # Serialize the record to a dict
                record_dict = self.helper.serialize_for_db(record)
                # Add each field's value in the order of field_names
                for field in self.helper.field_names:
                    values.append(record_dict.get(field))
            
            # Execute the upsert
            self.execute(query, data=values, as_upsert=True)
            
            # Try to register with IcebergModelCatalog for future operations
            try:
                catalog = IcebergModelCatalog(self.model)
                # For each record, try to insert/update in IcebergModelCatalog
                catalog.upsert_data(records)
                logger.debug(f"Successfully added records to IcebergModelCatalog after SQL upsert")
            except Exception as ex:
                logger.debug(f"Failed to sync with IcebergModelCatalog after SQL upsert: {ex}")
            
            # For verification/testing, fetch the inserted records
            if len(records) == 1:
                # If single record, return it
                record_id = self.helper.serialize_for_db(records[0])['id']
                return self.select(id=record_id)
            else:
                # Just return success for bulk inserts
                return {"status": "success", "count": len(records)}
                
        except Exception as e:
            logger.error(f"SQL upsert fallback failed: {e}")
            if query:
                logger.debug(f"Failed query: {query}")
            raise
    
    def drop_entity(self):
        """Drop entity tables, embeddings, and catalog registrations
        
        This removes all tables and metadata associated with the entity
        """
        assert self.model is not None, "Model is required to drop entity"
        
        namespace = self.model.get_model_namespace().lower()
        name = self.model.get_model_name().lower()
        
        # Construct table names based on namespace convention
        if namespace.lower() == "test":
            table_name = f"{namespace}_{name}"
            embedding_table = f"{namespace}_{name}_embeddings"
        else:
            table_name = f"{namespace}.{name}"
            embedding_table = f"py_embeddings.{namespace}_{name}_embeddings"
        
        success = True
        errors = []
        
        # Try to unregister from Iceberg catalog using IcebergModelCatalog
        try:
            # Create catalog for this model
            catalog = IcebergModelCatalog(self.model)
            
            # Try to drop the table from the catalog
            try:
                # Get the main table identifier
                table_identifier = self.model.get_model_full_name()
                
                # Drop the main table if it exists
                try:
                    # First load the table to check if it exists
                    table = catalog.cat.load_table(table_identifier)
                    catalog.cat.drop_table(table_identifier)
                    logger.info(f"Dropped table {table_identifier} from Iceberg catalog")
                except Exception as e:
                    logger.warning(f"Failed to drop main table from catalog: {e}")
                    errors.append(f"Iceberg main table drop error: {str(e)}")
                    success = False
                
                # Drop the embedding table if it exists
                try:
                    # Determine embedding table name in catalog
                    embedding_namespace = "py_embeddings"
                    embedding_name = f"{namespace}_{name}_embeddings"
                    embedding_identifier = f"{embedding_namespace}.{embedding_name}"
                    
                    # Try to drop the embedding table
                    catalog.cat.drop_table(embedding_identifier)
                    logger.info(f"Dropped embedding table {embedding_identifier} from Iceberg catalog")
                except Exception as e:
                    # This is not critical, as the embedding table might not exist
                    logger.debug(f"Failed to drop embedding table from catalog: {e}")
            except Exception as e:
                logger.warning(f"Iceberg catalog drop operations failed: {e}")
                errors.append(f"Iceberg catalog error: {str(e)}")
                success = False
        except Exception as e:
            logger.warning(f"IcebergModelCatalog setup failed: {e}")
            errors.append(f"Iceberg setup error: {str(e)}")
            success = False
        
        # Drop tables directly from DuckDB as a fallback
        # Drop embedding table if it exists
        try:
            # Check if embedding table exists
            check_query = f"""
            SELECT count(*) as exists FROM information_schema.tables 
            WHERE table_name LIKE '{namespace}_{name}_embeddings' OR 
                  (table_schema = 'py_embeddings' AND table_name = '{namespace}_{name}_embeddings')
            """
                
            result = self.execute(check_query)
            if result and result[0]['exists'] > 0:
                drop_query = f"DROP TABLE IF EXISTS {embedding_table}"
                self.execute(drop_query)
                logger.info(f"Dropped embedding table {embedding_table}")
        except Exception as e:
            logger.warning(f"Failed to drop embedding table: {e}")
            errors.append(f"Embedding table error: {str(e)}")
            success = False
        
        # Drop main entity table
        try:
            drop_query = f"DROP TABLE IF EXISTS {table_name}"
            self.execute(drop_query)
            logger.info(f"Dropped table {table_name}")
        except Exception as e:
            logger.warning(f"Failed to drop table: {e}")
            errors.append(f"Main table error: {str(e)}")
            success = False
        
        # Remove from KuzuDB if available
        if 'name' in self.helper.model.model_fields:
            try:
                from .KuzuDBService import KuzuDBService
                kuzu = KuzuDBService()
                entity_type = self.model.get_model_full_name()
                
                # Currently KuzuDBService doesn't have a drop_entity method
                # but we'll add a placeholder for when it's implemented
                # kuzu.drop_entity(entity_type)
                logger.info(f"Entity {entity_type} would be removed from graph database")
            except Exception as e:
                logger.warning(f"Graph removal skipped: {e}")
        
        if success:
            logger.info(f"Successfully dropped entity {self.model.get_model_full_name()}")
        else:
            logger.warning(f"Partially dropped entity {self.model.get_model_full_name()} with errors: {errors}")
            
        return {"success": success, "errors": errors if errors else None}
    
    async def build_indexes(self, entity_name: str, id: uuid.UUID = None):
        """Asynchronously build indexes for entity
        
        Args:
            entity_name: Fully qualified entity name (namespace.name)
            id: Optional UUID for tracking the index operation
        """
        if not id:
            id = uuid.uuid1()
            
        logger.info(f"Starting async index build for {entity_name}")
        
        # Track metrics
        metrics = {
            'entities_added': 0,
            'embeddings_added': 0,
        }
        errors = []
        
        try:
            # Check if entity has a name field for entity index
            namespace, name = entity_name.split('.')
            query = f"""
            SELECT column_name FROM information_schema.columns 
            WHERE table_name = '{name.lower()}' AND column_name = 'name'
            """
            has_name = len(self.execute(query)) > 0
            
            if has_name:
                # Add to entity graph if KuzuDB is available
                try:
                    from .KuzuDBService import KuzuDBService
                    kuzu = KuzuDBService()
                    
                    # Extract entity records with name and id
                    query = f"""
                    SELECT id, name FROM {namespace}."{name}"
                    """
                    entities = self.execute(query)
                    
                    if entities:
                        count = kuzu.add_entities(entity_name, entities)
                        metrics['entities_added'] = count
                except Exception as e:
                    errors.append(f"Entity index error: {str(e)}")
                    logger.error(f"Failed to build entity index: {e}")
            
            # Check for embedding fields and build vector indexes
            if self.helper and self.helper.table_has_embeddings:
                try:
                    # Vector index creation logic
                    # TODO: Implement embedding index creation
                    metrics['embeddings_added'] = 0
                except Exception as e:
                    errors.append(f"Embedding index error: {str(e)}")
                    logger.error(f"Failed to build embedding index: {e}")
        
        except Exception as e:
            errors.append(f"General indexing error: {str(e)}")
            logger.error(f"Index building failed: {e}")
        
        # Log completion status
        if errors:
            status = "ERROR"
            message = "\n".join(errors)
        else:
            status = "OK"
            message = "Index built successfully"
        
        logger.info(f"Index build complete for {entity_name}: {status}")
        logger.info(f"Metrics: {metrics}")
        
        # Record audit entry
        # TODO: Implement IndexAudit for tracking
        
        return metrics
    
    def execute(self, query: str, data=None, as_upsert: bool = False, page_size: int = 100):
        """Execute query against DuckDB
        
        Args:
            query: SQL query to execute
            data: Parameter values (tuple, list of tuples, or dict)
            as_upsert: True if this is a batch upsert operation
            page_size: Batch size for upserts
        
        Returns:
            Query results as list of dictionaries
        """
        if not query:
            return None
        
        # Ensure connection is available
        if self.conn is None:
            self.conn = self._connect()
            self._setup_extensions()
            
        try:
            # Execute the query based on the type of data and operation
            if as_upsert and isinstance(data, list):
                # Handle batch upsert with multiple records
                # DuckDB executes a transactional batch automatically
                result = self.conn.execute(query, data)
            else:
                # Execute regular query
                if data:
                    result = self.conn.execute(query, data)
                else:
                    result = self.conn.execute(query)
                
                try:
                    # Try to fetch results
                    rows = result.fetchall()
                    
                    # Convert to dictionaries if there are results
                    if rows and result.description:
                        column_names = [desc[0] for desc in result.description]
                        return [dict(zip(column_names, row)) for row in rows]
                    return rows
                except:
                    # If no results to fetch (e.g., for INSERT, UPDATE, etc.)
                    return None
                
        except Exception as e:
            logger.error(f"Query execution failed: {e}\nQuery: {query}")
            if data:
                logger.debug(f"Parameters: {data}")
            raise
    
    def select(self, fields: typing.List[str] = None, **kwargs):
        """Select records matching criteria
        
        Args:
            fields: Optional list of fields to select
            **kwargs: Field-value pairs for filtering
        
        Returns:
            List of matching records
        """
        assert self.model is not None, "Model is required for select operation"
        
        # Try using direct Iceberg integration first if enabled
        try:
            from percolate.utils.env import PERCOLATE_USE_PYICEBERG, P8_ICEBERG_WAREHOUSE
            
            if PERCOLATE_USE_PYICEBERG:
                # Build a query for the Iceberg table
                field_str = "*" if not fields else ", ".join(fields)
                model_namespace = self.model.get_model_namespace().lower()
                model_name = self.model.get_model_name().lower()
                
                # Try using iceberg_scan directly (works with most DuckDB versions)
                iceberg_metadata_location = f"{P8_ICEBERG_WAREHOUSE}/{model_namespace}.db/{model_name}"
                
                # Check if the catalog method exists
                try:
                    catalog_check = self.conn.execute(
                        "SELECT COUNT(*) as exists FROM duckdb_functions() WHERE function_name = 'iceberg_catalog'"
                    ).fetchone()
                    
                    if catalog_check and catalog_check[0] > 0:
                        # Modern DuckDB with iceberg_catalog support
                        iceberg_table = f"percolate.{model_namespace}.{model_name}"
                        
                        # Build where clause
                        where_clause = ""
                        params = []
                        if kwargs:
                            clauses = []
                            for key, value in kwargs.items():
                                clauses.append(f"{key} = ?")
                                params.append(value)
                            where_clause = f" WHERE {' AND '.join(clauses)}"
                        
                        iceberg_query = f"SELECT {field_str} FROM {iceberg_table}{where_clause}"
                    else:
                        # Older DuckDB with only iceberg_scan support
                        if os.path.exists(f"{iceberg_metadata_location}/metadata"):
                            # Build where clause for iceberg_scan
                            filter_expr = "TRUE"
                            params = []
                            if kwargs:
                                clauses = []
                                for key, value in kwargs.items():
                                    clauses.append(f"{key} = ?")
                                    params.append(value)
                                filter_expr = f"{' AND '.join(clauses)}"
                                
                            # Use iceberg_scan directly
                            iceberg_query = f"""
                            SELECT {field_str} FROM iceberg_scan(
                                '{iceberg_metadata_location}', 
                                selected_fields='{field_str if field_str != '*' else ''}',
                                where_expr='{filter_expr}'
                            )
                            """
                        else:
                            raise FileNotFoundError(f"Iceberg metadata not found at {iceberg_metadata_location}")
                            
                    # Try to query using the appropriate method
                    try:
                        result = self.execute(iceberg_query, data=tuple(params) if params else None)
                        if result is not None:
                            logger.debug(f"Direct Iceberg query successful")
                            return result
                    except Exception as e:
                        logger.debug(f"Direct Iceberg query failed, falling back to SQL: {e}")
                        
                except Exception as e:
                    logger.debug(f"Error determining Iceberg capability: {e}")
        except Exception as e:
            logger.debug(f"Error setting up Iceberg query, falling back to SQL: {e}")
        
        # Fall back to SQL query
        query = self.helper.select_query(fields, **kwargs)
        data = tuple(kwargs.values()) if kwargs else None
        
        return self.execute(query, data=data)
    
    def search(self, question: str):
        """Search across SQL, vector, and graph data
        
        Args:
            question: Natural language query
            
        Returns:
            Combined search results
        """
        assert self.model is not None, "Model is required for search operation"
        
        # TODO: Implement combined search across SQL, vector, and graph
        # This should follow similar pattern to PostgresService
        
        logger.warning("Search not yet implemented")
        return [{"status": "NOT_IMPLEMENTED", "message": "Search functionality is not yet implemented"}]
        
    # Helper methods for testing and validating PyIceberg integration
    
    def get_iceberg_status(self) -> dict:
        """Get status of PyIceberg integration
        
        Returns:
            Dictionary with PyIceberg status information
        """
        return PyIcebergHelper.catalog_status(self.db_path)
    
    def get_table_info(self) -> dict:
        """Get detailed information about the current model's table in PyIceberg
        
        Returns:
            Dictionary with table information
        """
        assert self.model is not None, "Model is required to get table info"
        
        namespace = self.model.get_model_namespace().lower()
        name = self.model.get_model_name().lower()
        
        return PyIcebergHelper.table_info(self.db_path, namespace, name)
        
    def add_embeddings(self, records: typing.List[dict], embedding_field: str = "description", batch_size: int = 100):
        """Add embeddings for specific field in records
        
        This is a helper method for testing embedding generation and storage.
        
        Args:
            records: List of record dictionaries (must have 'id' field)
            embedding_field: Name of the field to generate embeddings for
            batch_size: Size of batches for embedding API requests
            
        Returns:
            Dictionary with embedding operation stats
        """
        from percolate.utils.embedding import get_embeddings, prepare_embedding_records
        from percolate.models.p8.embedding_types import EmbeddingRecord
        
        assert self.model is not None, "Model is required to add embeddings"
        
        if not self.helper.table_has_embeddings:
            logger.warning("Model does not have embedding fields")
            return {"success": False, "error": "Model does not have embedding fields"}
        
        # Initialize results
        results = {
            "success": True,
            "embeddings_added": 0,
            "errors": []
        }
        
        try:
            # Filter out records that don't have the required fields
            valid_records = []
            for record in records:
                if "id" not in record or embedding_field not in record:
                    results["errors"].append(f"Record missing 'id' or '{embedding_field}' fields")
                    continue
                valid_records.append(record)
            
            # Create a repository for embedding records
            embedding_repo = self.repository(EmbeddingRecord)
            
            # Ensure embedding table exists by registering the model
            if not embedding_repo.entity_exists:
                logger.info("Embedding table does not exist, creating it")
                embedding_repo.register()
            
            # Process records in batches
            for i in range(0, len(valid_records), batch_size):
                batch = valid_records[i:i+batch_size]
                
                # Extract text for embedding from each record
                texts = [record[embedding_field] for record in batch]
                
                # Get embeddings in batch
                try:
                    # Get API key from environment or settings
                    import os
                    api_key = os.environ.get("OPENAI_API_KEY")
                    
                    # Get embeddings in batch
                    embedding_vectors = get_embeddings(
                        texts=texts, 
                        model="text-embedding-ada-002",
                        api_key=api_key
                    )
                    
                    # Prepare embedding records
                    embedding_records = prepare_embedding_records(
                        records=batch,
                        embedding_vectors=embedding_vectors,
                        field=embedding_field
                    )
                    
                except Exception as e:
                    logger.error(f"Could not get batch embeddings: {e}")
                    results["success"] = False
                    results["errors"].append(f"Embedding API error: {str(e)}")
                    continue
                
                # Use the standard update_records method to properly handle upserts
                if embedding_records:
                    # Insert/update embedding records using the same mechanism as regular records
                    embedding_repo.update_records(
                        records=embedding_records,
                        batch_size=batch_size
                    )
                    
                    results["embeddings_added"] += len(embedding_records)
                
        except Exception as e:
            logger.error(f"Failed to add embeddings: {e}")
            results["success"] = False
            results["errors"].append(str(e))
            
        return results
        
    def semantic_search(
        self, query: str, embedding_field: str = "description", limit: int = 5, threshold: float = 0.7
    ):
        """Perform semantic search using vector similarity with IcebergModelCatalog
        
        This method uses the embedding table schema created by IcebergModelCatalog.
        
        Args:
            query: Search query text
            embedding_field: Field name to search in
            limit: Maximum number of results to return
            threshold: Similarity threshold (0-1), higher means more similar
            
        Returns:
            List of matching records sorted by relevance
        """
        from percolate.utils.embedding import get_embedding
        
        assert self.model is not None, "Model is required for semantic search"
        
        if not self.helper.table_has_embeddings:
            logger.warning("Model does not have embedding fields")
            return []
        
        # Create an IcebergModelCatalog for this model
        catalog = IcebergModelCatalog(self.model)
        
        # Try to ensure the tables exist
        try:
            # This will create both the main table and embedding table if they don't exist
            catalog.create_table_for_model()
        except Exception as e:
            logger.warning(f"Failed to ensure tables exist: {e}")
        
        # Get namespace and name for the main model
        main_namespace = self.model.get_model_namespace().lower()
        main_name = self.model.get_model_name().lower()
        
        # Determine main table name
        main_table = f"{main_namespace}.{main_name}"
        if main_namespace.lower() == "test":
            main_table = f"{main_namespace}_{main_name}"
            
        # Determine embedding table name
        embedding_namespace = "py_embeddings"
        embedding_table = f"{embedding_namespace}.{main_namespace}_{main_name}_embeddings"
        if main_namespace.lower() == "test":
            embedding_table = f"{main_namespace}_{main_name}_embeddings"
            
        # Try to get query embedding
        try:
            # Get API key from environment
            import os
            api_key = os.environ.get("OPENAI_API_KEY")
            
            # Get embedding using the utility
            query_embedding = get_embedding(
                text=query,
                model="text-embedding-ada-002",
                api_key=api_key
            )
            
            # Check if we have a vector search index available
            has_index = False
            try:
                index_query = f"""
                SELECT * FROM duckdb_indexes() 
                WHERE table_name ILIKE '%{main_name}_embeddings%' AND index_type LIKE '%vss%'
                """
                index_result = self.execute(index_query)
                has_index = index_result and len(index_result) > 0
            except Exception as e:
                logger.debug(f"Failed to check for vector index: {e}")
            
            # Create a query using the appropriate vector similarity function
            # With index, we can use vss_search, otherwise use list_cosine_similarity
            if has_index:
                # Use the vss_search function for indexed search
                query_sql = f"""
                SELECT m.*, e.embedding_vector, 
                       vss_cosine_distance(e.embedding_vector, ?) as distance,
                       1 - vss_cosine_distance(e.embedding_vector, ?) as similarity
                FROM {main_table} m
                JOIN {embedding_table} e ON m.id = e.source_record_id
                WHERE e.column_name = '{embedding_field}'
                  AND 1 - vss_cosine_distance(e.embedding_vector, ?) >= {threshold}
                ORDER BY similarity DESC
                LIMIT {limit}
                """
                # Need to pass the embedding vector three times for the placeholders
                results = self.execute(query_sql, data=[query_embedding, query_embedding, query_embedding])
            else:
                # Use list_cosine_similarity for non-indexed search
                query_sql = f"""
                SELECT m.*, e.embedding_vector, 
                       1 - list_cosine_similarity(e.embedding_vector, ?) as distance,
                       list_cosine_similarity(e.embedding_vector, ?) as similarity
                FROM {main_table} m
                JOIN {embedding_table} e ON m.id = e.source_record_id
                WHERE e.column_name = '{embedding_field}'
                  AND list_cosine_similarity(e.embedding_vector, ?) >= {threshold}
                ORDER BY similarity DESC
                LIMIT {limit}
                """
                # Need to pass the embedding vector three times for the placeholders
                results = self.execute(query_sql, data=[query_embedding, query_embedding, query_embedding])
            
            return results if results else []
            
        except Exception as e:
            logger.warning(f"Vector search failed, falling back to text search: {e}")
            # Fall back to text LIKE search
            fallback_query = f"""
            SELECT * FROM {main_table}
            WHERE {embedding_field} LIKE '%{query}%'
            LIMIT {limit}
            """
            
            try:
                results = self.execute(fallback_query)
                return results if results else []
            except Exception as e2:
                logger.error(f"Text search also failed: {e2}")
                return []
    
    def improved_semantic_search(
        self, query: str, embedding_field: str = "description", limit: int = 5, 
        threshold: float = 0.7, include_metadata: bool = True
    ):
        """Enhanced semantic search using IcebergModelCatalog with direct DuckDB connection
        
        Uses the db property of IcebergModelCatalog for direct access to DuckDB connection.
        
        Args:
            query: Search query text
            embedding_field: Field name to search in
            limit: Maximum number of results to return
            threshold: Similarity threshold (0-1), higher means more similar
            include_metadata: Whether to include embedding vector and similarity score
            
        Returns:
            List of matching records sorted by relevance
        """
        from percolate.utils.embedding import get_embedding
        
        assert self.model is not None, "Model is required for semantic search"
        
        if not self.helper.table_has_embeddings:
            logger.warning("Model does not have embedding fields")
            return []
        
        # Create an IcebergModelCatalog for this model
        catalog = IcebergModelCatalog(self.model)
        
        # Try to ensure the tables exist
        try:
            # This will create both the main table and embedding table if they don't exist
            main_table = catalog.create_table_for_model()
        except Exception as e:
            logger.warning(f"Failed to ensure tables exist: {e}")
            return []
        
        # Get embedding table information
        main_namespace = self.model.get_model_namespace().lower()
        main_name = self.model.get_model_name().lower()
        embedding_namespace = "py_embeddings"
        embedding_table_name = f"{main_namespace}_{main_name}_embeddings"
        
        # Try to get query embedding
        try:
            # Get API key from environment
            import os
            api_key = os.environ.get("OPENAI_API_KEY")
            
            # Get embedding using the utility
            query_embedding = get_embedding(
                text=query,
                model="text-embedding-ada-002",
                api_key=api_key
            )
            
            # Use the db connection directly from IcebergModelCatalog
            con = catalog.db
            
            # Register the embedding table with DuckDB
            con.execute(f"""
            CREATE OR REPLACE VIEW {embedding_table_name} AS
            SELECT * FROM '{embedding_namespace}'.'{embedding_table_name}'
            """)
            
            # Construct SQL for semantic search
            # Include metadata fields if requested
            if include_metadata:
                select_fields = "m.*, e.embedding_vector, list_cosine_similarity(e.embedding_vector, ?) as similarity"
            else:
                select_fields = "m.*, list_cosine_similarity(e.embedding_vector, ?) as similarity"
                
            # SQL query with join to embedding table
            search_sql = f"""
            SELECT {select_fields}
            FROM {catalog.table_name} m
            JOIN {embedding_table_name} e ON m.id = e.source_record_id
            WHERE e.column_name = '{embedding_field}'
              AND list_cosine_similarity(e.embedding_vector, ?) >= {threshold}
            ORDER BY similarity DESC
            LIMIT {limit}
            """
            
            # Execute search with query embedding
            result = con.execute(search_sql, [query_embedding, query_embedding]).fetchdf()
            
            # Convert to list of dictionaries
            if not result.empty:
                return result.to_dict(orient='records')
                
            return []
            
        except Exception as e:
            logger.warning(f"Semantic search with IcebergModelCatalog DB failed: {e}")
            # Fall back to regular semantic search
            return self.semantic_search(query, embedding_field, limit, threshold)
            
    def get_entity_by_name(self, entity_name: str):
        """Get entity by name using graph database
        
        This is a helper method for testing entity index functionality.
        
        Args:
            entity_name: Name of the entity to find
            
        Returns:
            Entity record or None if not found
        """
        assert self.model is not None, "Model is required to get entity by name"
        
        # Try to find entity in graph database first
        try:
            from .KuzuDBService import KuzuDBService
            
            entity_type = self.model.get_model_full_name()
            kuzu = KuzuDBService()
            
            # Query entity in graph
            graph_entity = kuzu.find_entity_by_name(entity_type, entity_name)
            
            if graph_entity:
                # If found in graph, get full record from DuckDB
                return self.select(id=graph_entity.get("id"))
                
        except Exception as e:
            logger.warning(f"Graph lookup failed, falling back to SQL: {e}")
        
        # Fallback to SQL lookup
        return self.select(name=entity_name)