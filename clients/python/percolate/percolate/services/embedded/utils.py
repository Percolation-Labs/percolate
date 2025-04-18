"""
Utility functions for embedded Percolate implementation.

This module provides helper functions for async operations, index management,
and data conversion between Pydantic and embedded databases.

Example of standalone PyIceberg testing:

```python
# test_pyiceberg.py
import os
from percolate.services.embedded.utils import PyIcebergHelper

# Set PyIceberg environment variable
os.environ["PERCOLATE_USE_PYICEBERG"] = "1" 

# Path to DuckDB database
db_path = "/path/to/your/db"

# Check if PyIceberg is available and enabled
print(f"PyIceberg available: {PyIcebergHelper.is_available()}")
print(f"PyIceberg enabled: {PyIcebergHelper.is_enabled()}")

# Get catalog status
status = PyIcebergHelper.catalog_status(db_path)
print(f"Catalog status: {status}")

# Check table info for a specific table
table_info = PyIcebergHelper.table_info(db_path, "p8", "agent")
print(f"Table info: {table_info}")
```
"""

import asyncio
import os
import uuid
import json
import typing
from loguru import logger
from pydantic import BaseModel
from percolate.utils.env import PERCOLATE_USE_PYICEBERG, P8_EMBEDDED_DB_HOME
from percolate.models import IndexAudit

class AsyncIndexBuilder:
    """Helper for building indexes asynchronously"""
    
    @staticmethod
    async def build_indexes(entity_name: str, fields: typing.List[dict], db_service, id: uuid.UUID = None):
        """Build semantic and entity indexes asynchronously
        
        Args:
            entity_name: Fully qualified entity name (namespace.name)
            fields: List of field definitions
            db_service: Database service instance
            id: Optional UUID for tracking the operation
        
        Returns:
            Metrics about the operation
        """
        if not id:
            id = uuid.uuid1()
            
        logger.info(f"Starting async index build for {entity_name}")
        
        metrics = {
            'entities_added': 0,
            'embeddings_added': 0,
        }
        
        # Check for name field (entity index)
        has_name = False
        for field in fields:
            if field.get('field_name') == 'name':
                has_name = True
                break
                
        # Check for embedding fields (semantic index)
        embedding_fields = []
        for field in fields:
            if field.get('embedding_provider'):
                embedding_fields.append(field.get('field_name'))
        
        # Build entity index if name field exists
        if has_name:
            try:
                # Build entity index
                pass
            except Exception as e:
                logger.error(f"Failed to build entity index: {e}")
        
        # Build semantic index if embedding fields exist
        if embedding_fields:
            try:
                # Build semantic index
                pass
            except Exception as e:
                logger.error(f"Failed to build semantic index: {e}")
        
        logger.info(f"Completed async index build for {entity_name}")
        return metrics

 
class EmbeddingManager:
    """Helper for managing embeddings and vector operations"""
    
    @staticmethod
    def extract_embedding_fields(model: BaseModel) -> typing.List[str]:
        """Extract fields with embedding attributes
        
        Args:
            model: Pydantic model
            
        Returns:
            List of field names with embedding providers
        """
        fields = []
        
        for name, field in model.model_fields.items():
            extra = field.json_schema_extra or {}
            if extra.get('embedding_provider'):
                fields.append(name)
                
        return fields
    
    @staticmethod
    async def create_embeddings_for_record(record: dict, embedding_fields: typing.List[str]):
        """Create embeddings for record fields
        
        Args:
            record: Record with field values
            embedding_fields: Fields to embed
            
        Returns:
            Dictionary of field name to embedding
        """
        # This would be implemented with actual embedding generation
        # For now, return placeholder
        return {field: [0.0] * 384 for field in embedding_fields if field in record}

def dict_to_polars(data: typing.List[dict]) -> "pl.DataFrame":
    """Convert list of dictionaries to Polars DataFrame
    
    Args:
        data: List of dictionaries
        
    Returns:
        Polars DataFrame
    """
    try:
        import polars as pl
        return pl.DataFrame(data)
    except ImportError:
        logger.warning("Polars is not installed")
        return None

def run_async(coroutine):
    """Run coroutine in event loop
    
    Args:
        coroutine: Async coroutine to run
        
    Returns:
        Coroutine result
    """
    try:
        loop = asyncio.get_event_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
    
    return loop.run_until_complete(coroutine)


class PyIcebergHelper:
    """Helper class for PyIceberg integration with DuckDB"""
    
    @staticmethod
    def is_available() -> bool:
        """Check if PyIceberg is available"""
        try:
            import pyiceberg
            return True
        except ImportError:
            return False
    
    @staticmethod
    def is_enabled() -> bool:
        """Check if PyIceberg is enabled
        
        Uses the PERCOLATE_USE_PYICEBERG environment variable defined in utils.env,
        which defaults to enabled (True)
        """
        if not PyIcebergHelper.is_available():
            return False
            
        return PERCOLATE_USE_PYICEBERG
    
    @staticmethod
    def catalog_status(db_path: str) -> dict:
        """Get detailed status of PyIceberg catalog
        
        This method is useful for diagnostic and testing purposes.
        
        Args:
            db_path: Path to DuckDB database
            
        Returns:
            Dictionary with catalog status information
        """
        result = {
            "is_available": PyIcebergHelper.is_available(),
            "is_enabled": PyIcebergHelper.is_enabled(),
            "catalog_name": "percolate",
            "catalog_config": PyIcebergHelper.get_catalog_config(db_path),
            "namespaces": [],
            "tables": {},
            "warehouse_path": None,
            "errors": []
        }
        
        if not result["is_enabled"]:
            return result
            
        try:
            from pyiceberg.catalog import load_catalog
            
            # Configure catalog
            catalog_config = result["catalog_config"]
            result["warehouse_path"] = catalog_config["warehouse"]
            
            # Try to load catalog
            try:
                catalog = load_catalog(result["catalog_name"], **catalog_config)
                result["catalog_loaded"] = True
                
                # List namespaces
                try:
                    result["namespaces"] = catalog.list_namespaces()
                except Exception as e:
                    result["errors"].append(f"Failed to list namespaces: {e}")
                
                # List tables in each namespace
                for namespace in result["namespaces"]:
                    ns_name = ".".join(namespace) if isinstance(namespace, tuple) else namespace
                    try:
                        result["tables"][ns_name] = catalog.list_tables(namespace)
                    except Exception as e:
                        result["errors"].append(f"Failed to list tables in {ns_name}: {e}")
                        result["tables"][ns_name] = []
                        
            except Exception as e:
                result["catalog_loaded"] = False
                result["errors"].append(f"Failed to load catalog: {e}")
                
        except ImportError as e:
            result["errors"].append(f"PyIceberg import error: {e}")
            
        return result
        
    @staticmethod
    def table_info(db_path: str, namespace: str, name: str) -> dict:
        """Get detailed information about a PyIceberg table
        
        Args:
            db_path: Path to DuckDB database
            namespace: Schema namespace
            name: Table name
            
        Returns:
            Dictionary with table information
        """
        result = {
            "table_name": f"{namespace}.{name}",
            "exists": False,
            "schema": None,
            "properties": None,
            "metadata": None,
            "stats": None,
            "errors": []
        }
        
        if not PyIcebergHelper.is_enabled():
            result["errors"].append("PyIceberg is not enabled")
            return result
            
        try:
            from pyiceberg.catalog import load_catalog
            
            # Configure catalog
            catalog_config = PyIcebergHelper.get_catalog_config(db_path)
            
            # Try to load catalog and table
            try:
                catalog = load_catalog("percolate", **catalog_config)
                
                # Check if table exists
                if catalog.table_exists(result["table_name"]):
                    result["exists"] = True
                    
                    # Load table details
                    try:
                        table = catalog.load_table(result["table_name"])
                        
                        # Get schema
                        result["schema"] = str(table.schema())
                        
                        # Get properties
                        result["properties"] = table.properties
                        
                        # Get basic stats if available
                        try:
                            import pandas as pd
                            sample_df = table.scan().limit(5).to_pandas()
                            result["sample_data"] = sample_df.to_dict(orient="records")
                            result["column_count"] = len(sample_df.columns)
                            result["stats"] = {
                                "sample_rows": len(sample_df)
                            }
                        except Exception as e:
                            result["errors"].append(f"Failed to get table stats: {e}")
                            
                    except Exception as e:
                        result["errors"].append(f"Failed to load table details: {e}")
                        
            except Exception as e:
                result["errors"].append(f"Failed to access catalog: {e}")
                
        except ImportError as e:
            result["errors"].append(f"PyIceberg import error: {e}")
            
        return result
    
    @staticmethod
    def get_catalog_config(db_path: str) -> dict:
        """Get PyIceberg catalog configuration for DuckDB"""
        warehouse_path = os.path.join(os.path.dirname(db_path), "warehouse")
        return {
            "type": "duckdb",
            "connection": db_path,
            "warehouse": warehouse_path
        }
    
    @staticmethod
    def setup_catalog(conn, db_path: str) -> typing.Any:
        """Set up PyIceberg catalog for DuckDB
        
        Args:
            conn: DuckDB connection
            db_path: Path to DuckDB database
            
        Returns:
            PyIceberg catalog object or None if setup fails
        """
        if not PyIcebergHelper.is_enabled():
            return None
            
        try:
            from pyiceberg.catalog import load_catalog
            
            # Check if DuckDB has iceberg extension
            try:
                # Correct query for checking extensions
                extension_query = """
                SELECT name FROM duckdb_extensions.loaded 
                WHERE name = 'iceberg'
                """
                extensions = conn.execute(extension_query).fetchall()
                
                # Install and load iceberg extension if not already loaded
                if not extensions or len(extensions) == 0:
                    conn.execute("INSTALL iceberg;")
                    conn.execute("LOAD iceberg;")
                
                # Get catalog configuration
                catalog_name = "percolate"
                catalog_config = PyIcebergHelper.get_catalog_config(db_path)
                
                # Create warehouse directory
                warehouse_path = catalog_config["warehouse"]
                os.makedirs(warehouse_path, exist_ok=True)
                
                # Create or use existing catalog
                try:
                    # Format SQL parameters properly - avoiding string literals and escaping
                    conn.execute(
                        "CALL iceberg_create_catalog(?, ?)",
                        [catalog_name, {
                            'type': 'duckdb',
                            'connection': db_path,
                            'warehouse': warehouse_path
                        }]
                    )
                except Exception as e:
                    # If it fails because catalog already exists, that's ok
                    logger.debug(f"Catalog creation returned: {e}")
                
                # Load the catalog
                return load_catalog(catalog_name, **catalog_config)
                
            except Exception as e:
                logger.warning(f"PyIceberg catalog setup failed: {e}")
                return None
                
        except ImportError:
            logger.debug("PyIceberg not available for catalog setup")
            return None
    
    @staticmethod
    def register_table(conn, catalog: typing.Any, namespace: str, name: str, table_identifier: str) -> bool:
        """Register existing table with PyIceberg
        
        Args:
            conn: DuckDB connection
            catalog: PyIceberg catalog
            namespace: Schema namespace
            name: Table name
            table_identifier: Full table identifier (namespace.name or namespace_name)
            
        Returns:
            True if registration successful, False otherwise
        """
        if not catalog:
            return False
            
        try:
            # Create namespace if needed
            if namespace not in catalog.list_namespaces():
                catalog.create_namespace(namespace)
            
            # Full table name for PyIceberg
            table_name = f"{namespace}.{name}"
            
            # Try two approaches for registering the table:
            # 1. First try PyIceberg's catalog.create_table method directly
            # 2. If that fails, fallback to DuckDB's iceberg extension
            
            if not catalog.table_exists(table_name):
                try:
                    # Try to create table schema natively with PyIceberg
                    try:
                        # Import necessary modules
                        from pyiceberg.schema import Schema
                        from pyiceberg.types import NestedField, StringType, LongType
                        import pandas as pd
                        
                        # Query the DuckDB table to get schema info
                        schema_query = f"DESCRIBE {table_identifier}"
                        schema_info = conn.execute(schema_query).fetchall()
                        
                        # Build PyIceberg schema from DuckDB schema
                        # Default to using the 'id' field as primary key
                        field_id = 1
                        fields = []
                        key_field_ids = []
                        
                        # Map DuckDB types to PyIceberg types
                        for col_name, col_type, _, _ in schema_info:
                            required = True
                            iceberg_type = StringType()  # Default
                            
                            # Map types - this is a simplified mapping
                            if 'int' in col_type.lower() or 'bigint' in col_type.lower():
                                iceberg_type = LongType()
                            
                            # Add to field list
                            fields.append(NestedField(field_id, col_name, iceberg_type, required))
                            
                            # If this is the ID field, mark it as a key
                            if col_name.lower() == 'id':
                                key_field_ids.append(field_id)
                                
                            field_id += 1
                        
                        # Create schema
                        schema = Schema(*fields, identifier_field_ids=key_field_ids)
                        
                        # Create the table
                        warehouse_path = os.path.join(os.path.dirname(catalog.properties.get('warehouse')))
                        table_location = f"{warehouse_path}/{namespace}/{name}"
                        
                        # Ensure location exists
                        os.makedirs(table_location, exist_ok=True)
                        
                        table = catalog.create_table(
                            identifier=table_name,
                            schema=schema,
                            location=table_location,
                            properties={
                                "format-version": "2",
                                "write.upsert.enabled": "true"
                            }
                        )
                        
                        logger.info(f"Created table {table_name} using native PyIceberg")
                        
                        # Now get some data to populate initially for schema safety
                        data_query = f"SELECT * FROM {table_identifier} LIMIT 1"
                        initial_data = conn.execute(data_query).fetchdf()
                        
                        if not initial_data.empty:
                            import pyarrow as pa
                            arrow_table = pa.Table.from_pandas(initial_data)
                            table.append(arrow_table)
                            
                        return True
                        
                    except (ImportError, AttributeError, Exception) as native_error:
                        # Fallback to DuckDB iceberg extension
                        logger.debug(f"Native PyIceberg table creation failed: {native_error}, using DuckDB integration")
                        
                        conn.execute(f"""
                        CALL iceberg_create_table(
                            '{table_name}',
                            TABLE({table_identifier}),
                            {{
                                'format-version': '2',
                                'write.upsert.enabled': 'true'
                            }}
                        );
                        """)
                        
                        logger.info(f"Registered {table_name} with PyIceberg via DuckDB")
                        return True
                        
                except Exception as e:
                    # Check if error is because table already exists
                    if "already exists" in str(e):
                        logger.debug(f"PyIceberg table {table_name} already exists")
                        return True
                    else:
                        logger.warning(f"Failed to register table with PyIceberg: {e}")
                        return False
            else:
                logger.debug(f"PyIceberg table {table_name} already exists")
                return True
                
        except Exception as e:
            logger.warning(f"Error registering table with PyIceberg: {e}")
            return False
    
    @staticmethod
    def perform_upsert(conn, catalog: typing.Any, namespace: str, name: str, 
                       serialized_records: typing.List[dict], id_field: str = "id") -> bool:
        """Perform upsert operation using PyIceberg
        
        Args:
            conn: DuckDB connection
            catalog: PyIceberg catalog
            namespace: Schema namespace
            name: Table name
            serialized_records: List of serialized records
            id_field: Primary key field name
            
        Returns:
            True if upsert successful, False otherwise
        """
        if not catalog:
            return False
            
        try:
            # Import required libraries
            try:
                import pyarrow as pa
                import pandas as pd
                import polars as pl
            except ImportError:
                logger.warning("Required libraries for PyIceberg upsert not available")
                return False
                
            table_name = f"{namespace}.{name}"
            
            # Try native PyIceberg upsert first
            try:
                # Load the table reference
                table = catalog.load_table(table_name)
                
                # Convert records to DataFrame
                df = pd.DataFrame(serialized_records)
                
                # Convert to Arrow table
                # We need to ensure the schema matches what PyIceberg expects
                arrow_table = pa.Table.from_pandas(df)
                
                # Perform the upsert using PyIceberg's native API
                # This follows the example pattern using join_cols
                join_columns = [id_field]
                upsert_result = table.upsert(df=arrow_table, join_cols=join_columns)
                
                logger.info(f"PyIceberg upsert: updated {upsert_result.rows_updated}, inserted {upsert_result.rows_inserted} rows")
                return True
                
            except (AttributeError, ImportError, Exception) as native_error:
                logger.debug(f"Native PyIceberg upsert not available: {native_error}, trying DuckDB integration")
                
                # Fallback to DuckDB iceberg extension integration
                try:
                    # Create a temp table with our data
                    df = pl.DataFrame(serialized_records)
                    conn.execute("CREATE OR REPLACE TABLE temp_df AS SELECT * FROM df")
                    
                    # Get field names for update mapping (exclude ID field)
                    field_names = [f for f in df.columns if f != id_field]
                    
                    # Build update mappings for merge operation
                    mappings = [{'target': field, 'source': f'temp_df.{field}'} for field in field_names]
                    
                    # Perform merge via DuckDB's iceberg extension
                    merge_sql = f"""
                    CALL iceberg_merge_into (
                        '{table_name}',
                        'temp_df',
                        '{table_name}.{id_field} = temp_df.{id_field}',
                        {json.dumps(mappings)}
                    )
                    """
                    conn.execute(merge_sql)
                    logger.info(f"Successfully upserted {len(df)} records with PyIceberg via DuckDB")
                    return True
                    
                except Exception as duckdb_error:
                    logger.warning(f"DuckDB integration failed: {duckdb_error}, trying SQL fallback")
                    
                    # Final fallback: standard SQL upsert
                    try:
                        # Generate SQL upsert
                        fields_str = ", ".join(df.columns)
                        update_clauses = [f"{field} = excluded.{field}" for field in field_names]
                        update_str = ", ".join(update_clauses)
                        
                        sql = f"""
                        INSERT INTO {table_name}
                        SELECT * FROM temp_df
                        ON CONFLICT ({id_field}) DO UPDATE SET
                        {update_str}
                        """
                        conn.execute(sql)
                        logger.info(f"Successfully upserted {len(df)} records with SQL ON CONFLICT")
                        return True
                    except Exception as sql_error:
                        logger.error(f"SQL upsert fallback failed: {sql_error}")
                        return False
        
        except Exception as e:
            logger.error(f"PyIceberg upsert operations failed: {e}")
            return False
        finally:
            # Clean up temporary table
            try:
                conn.execute("DROP TABLE IF EXISTS temp_df")
            except:
                pass
    
    @staticmethod
    def unregister_table(catalog: typing.Any, namespace: str, name: str) -> bool:
        """Unregister table from PyIceberg catalog
        
        Args:
            catalog: PyIceberg catalog
            namespace: Schema namespace
            name: Table name
            
        Returns:
            True if unregistration successful, False otherwise
        """
        if not catalog:
            return False
            
        try:
            table_id = f"{namespace}.{name}"
            
            if catalog.table_exists(table_id):
                catalog.drop_table(table_id)
                logger.info(f"Dropped {table_id} from PyIceberg catalog")
                return True
            return True  # Table doesn't exist, so unregistration is "successful"
        except Exception as e:
            logger.warning(f"PyIceberg catalog drop failed: {e}")
            return False
        
        
"""
EXAMPLE OF USING PYICEBERG UPSERTS

import os
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.schema import Schema
from pyiceberg.types import NestedField, LongType, StringType
from pyiceberg.partitioning import PartitionSpec, PartitionField
from pyiceberg.transforms import IdentityTransform


# Set up the warehouse path (replace with your actual path)
warehouse_path = "/Users/soumilshah/IdeaProjects/icebergpython/tests/warehouse"
os.makedirs(warehouse_path, exist_ok=True)

# Set up the catalog
catalog = load_catalog(
    "hive",
    warehouse=warehouse_path,
    uri=f"sqlite:///{warehouse_path}/metastore.db"
)

# Define the schema
schema = Schema(
    NestedField(1, "id", LongType(), required=True),
    NestedField(2, "site_id", StringType(), required=True),
    NestedField(3, "message", StringType(), required=True),
    identifier_field_ids=[1]  # 'id' is the primary key
)

# Define the partition spec (partition by 'site_id')
partition_spec = PartitionSpec(
    PartitionField(source_id=2, field_id=1000, transform=IdentityTransform(), name="site_id")
)

# Create the namespace if it doesn't exist
namespace = "my_namespace"
if namespace not in catalog.list_namespaces():
    catalog.create_namespace(namespace)

# Create the table
table_name = f"{namespace}.site_messages"
try:
    table = catalog.create_table(
        identifier=table_name,
        schema=schema,
        partition_spec=partition_spec,
        location=f"{warehouse_path}/{namespace}/site_messages"
    )
    print(f"Created table: {table_name}")
except Exception as e:
    print(f"Table already exists: {e}")
    table = catalog.load_table(table_name)

# Create initial sample data
initial_data = pa.table([
    pa.array([1, 2]),
    pa.array(["site_1", "site_2"]),
    pa.array(["initial message 1", "initial message 2"])
], schema=schema.as_arrow())

# Write initial data to the table
table.append(initial_data)
print("Initial data written to the table")

# Read and print initial data
initial_df = table.scan().to_arrow().to_pandas()
print("\nInitial data in the table:")
print(initial_df)

# Create data for upsert
upsert_data = pa.table([
    pa.array([2, 3]),  # Update id=2, insert id=3
    pa.array(["site_2", "site_3"]),
    pa.array(["updated message 2", "initial message 3"])
], schema=schema.as_arrow())

# Construct boolean expression for merge condition
join_columns = ["id"]
# Perform the merge operation
# Perform the upsert operation
upsert_result = table.upsert(df=upsert_data, join_cols = join_columns)

print("\nUpsert operation completed")
print(f"Rows Updated: {upsert_result.rows_updated}")
print(f"Rows Inserted: {upsert_result.rows_inserted}")

# Read and print the updated data
updated_df = table.scan().to_arrow().to_pandas()
print("\nUpdated data in the table after upsert operation:")
print(updated_df)


"""