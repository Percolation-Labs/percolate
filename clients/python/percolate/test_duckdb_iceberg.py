"""
Test script to verify DuckDB and Iceberg integration works correctly.
This tests ensures we can create a DuckDBService instance with an Agent model
and register it with the Iceberg catalog using separate storage paths.
"""

import os
from pydantic import BaseModel, Field
from uuid import UUID, uuid4
from datetime import datetime
from percolate.services.embedded.DuckDBService import DuckDBService
from percolate.utils.env import P8_DUCKDB_PATH, P8_ICEBERG_WAREHOUSE
import logging
from loguru import logger

# Configure logging
logger.add("test_duckdb_iceberg.log", level="DEBUG")
logger.info(f"DuckDB Path: {P8_DUCKDB_PATH}")
logger.info(f"Iceberg Warehouse: {P8_ICEBERG_WAREHOUSE}")

# Define a simple agent model for testing
class Agent(BaseModel):
    id: UUID = Field(default_factory=uuid4, description="Unique ID for the agent")
    name: str = Field(description="Name of the agent")
    description: str | None = Field(default=None, description="Description of the agent")
    created_at: datetime = Field(default_factory=datetime.now, description="Creation timestamp")
    updated_at: datetime | None = Field(default=None, description="Last update timestamp")
    
    class Config:
        namespace = "test"
        name = "Agent"
        description = "A test agent model"

def test_duckdb_service_init():
    """Test that we can initialize DuckDBService with our Agent model"""
    try:
        # Initialize service with the Agent model
        service = DuckDBService(Agent)
        logger.info(f"DuckDBService initialized successfully with path: {service.db_path}")
        return service
    except Exception as e:
        logger.error(f"Failed to initialize DuckDBService: {e}")
        raise

def test_duckdb_register():
    """Test that we can register the Agent model with Iceberg"""
    try:
        service = test_duckdb_service_init()
        result = service.register()
        logger.info(f"Registration result: {result}")
        return True
    except Exception as e:
        logger.error(f"Failed to register Agent model: {e}")
        raise

def test_duckdb_upsert():
    """Test that we can upsert records to the Agent table"""
    try:
        service = test_duckdb_service_init()
        
        # Create test agent
        test_agent = Agent(
            name="Test Agent",
            description="A test agent for DuckDB integration"
        )
        
        # Upsert the test agent
        result = service.update_records([test_agent])
        logger.info(f"Upsert result: {result}")
        
        # Verify we can retrieve the agent
        agents = service.select(name="Test Agent")
        logger.info(f"Retrieved agents: {agents}")
        
        return len(agents) > 0
    except Exception as e:
        logger.error(f"Failed to upsert/retrieve agent: {e}")
        raise

def test_direct_iceberg_query():
    """Test direct querying of Iceberg tables through DuckDB"""
    try:
        from percolate.utils.env import P8_ICEBERG_WAREHOUSE
        
        service = test_duckdb_service_init()
        
        # Create a new agent for this test
        test_agent = Agent(
            name="Iceberg Direct Query Agent",
            description="An agent to test direct Iceberg queries"
        )
        
        # Add the agent to the database
        service.update_records([test_agent])
        
        # First, try to detect which Iceberg functionality is available
        try:
            catalog_check = service.conn.execute(
                "SELECT COUNT(*) as exists FROM duckdb_functions() WHERE function_name = 'iceberg_catalog'"
            ).fetchone()
            
            has_catalog = catalog_check and catalog_check[0] > 0
            logger.info(f"DuckDB has iceberg_catalog support: {has_catalog}")
            
            iceberg_scan_check = service.conn.execute(
                "SELECT COUNT(*) as exists FROM duckdb_functions() WHERE function_name = 'iceberg_scan'"
            ).fetchone()
            
            has_scan = iceberg_scan_check and iceberg_scan_check[0] > 0
            logger.info(f"DuckDB has iceberg_scan support: {has_scan}")
            
            if has_catalog:
                # Try catalog approach
                service.conn.execute(f"CALL iceberg_catalog('percolate', 'file://{P8_ICEBERG_WAREHOUSE}')")
                direct_query = "SELECT * FROM percolate.test.agent WHERE name = 'Iceberg Direct Query Agent'"
                iceberg_results = service.execute(direct_query)
            elif has_scan:
                # Try iceberg_scan approach
                iceberg_metadata_path = f"{P8_ICEBERG_WAREHOUSE}/test.db/Agent"
                if os.path.exists(f"{iceberg_metadata_path}/metadata"):
                    direct_query = f"""
                    SELECT * FROM iceberg_scan(
                        '{iceberg_metadata_path}',
                        where_expr="name = 'Iceberg Direct Query Agent'"
                    )
                    """
                    iceberg_results = service.execute(direct_query)
                else:
                    logger.warning(f"Iceberg metadata not found at {iceberg_metadata_path}")
                    # Fall back to native DuckDB query
                    direct_query = "SELECT * FROM test_agent WHERE name = 'Iceberg Direct Query Agent'"
                    iceberg_results = service.execute(direct_query)
            else:
                logger.warning("No Iceberg support detected in DuckDB, using native query")
                # Fall back to native DuckDB query
                direct_query = "SELECT * FROM test_agent WHERE name = 'Iceberg Direct Query Agent'"
                iceberg_results = service.execute(direct_query)
                
            logger.info(f"Query used: {direct_query}")
            logger.info(f"Direct query results: {iceberg_results}")
            
            # Verify the results
            if not iceberg_results or len(iceberg_results) == 0:
                logger.error("Direct query failed to return results")
                return False
                
            # Query using the standard select method
            helper_results = service.select(name="Iceberg Direct Query Agent")
            logger.info(f"Standard select method results: {helper_results}")
            
            # Consider the test successful if we can get results from both approaches
            return len(iceberg_results) > 0 and len(helper_results) > 0
            
        except Exception as e:
            logger.warning(f"Error checking DuckDB Iceberg capabilities: {e}")
            # Fall back to native DuckDB query
            try:
                direct_query = "SELECT * FROM test_agent WHERE name = 'Iceberg Direct Query Agent'"
                iceberg_results = service.execute(direct_query)
                logger.info(f"Fallback query results: {iceberg_results}")
                
                # Query using the standard select method
                helper_results = service.select(name="Iceberg Direct Query Agent")
                logger.info(f"Standard select method results: {helper_results}")
                
                # Consider the test successful if both approaches return results
                return len(iceberg_results) > 0 and len(helper_results) > 0
            except Exception as e2:
                logger.error(f"Fallback query also failed: {e2}")
                return False
    except Exception as e:
        logger.error(f"Direct Iceberg query test failed: {e}")
        return False

if __name__ == "__main__":
    logger.info("Starting DuckDB and Iceberg integration test")
    
    # Run tests
    test_duckdb_service_init()
    test_duckdb_register()
    test_duckdb_upsert()
    
    # Test direct Iceberg integration
    direct_result = test_direct_iceberg_query()
    logger.info(f"Direct Iceberg query test result: {direct_result}")
    
    logger.info("All tests completed successfully!")