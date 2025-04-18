"""
KuzuDBService for graph operations in Embedded Percolate.

This service handles graph database operations using KuzuDB for local,
file-based graph storage.
"""

import os
import typing
import uuid
from loguru import logger

try:
    import kuzu
except ImportError:
    logger.warning("KuzuDB not installed - graph functionality will be unavailable")
    kuzu = None

class KuzuDBService:
    """KuzuDB implementation for graph operations in Embedded Percolate"""
    
    def __init__(self, db_path: str = None):
        """Initialize KuzuDB service
        
        Args:
            db_path: Path to KuzuDB directory (defaults to ~/.percolate/graph)
        """
        self.db_path = db_path or os.path.expanduser("~/.percolate/graph")
        self.conn = None
        
        try:
            self._connect()
        except Exception as e:
            logger.warning(f"Failed to initialize KuzuDBService: {e}")
    
    def _connect(self):
        """Connect to KuzuDB database"""
        if kuzu is None:
            return None
            
        os.makedirs(self.db_path, exist_ok=True)
        
        # Check if database needs initialization first
        db_exists = os.path.exists(os.path.join(self.db_path, "kuzudb.meta"))
        
        if not db_exists:
            try:
                # Initialize a new database first
                kuzu.init_database(self.db_path)
            except Exception as e:
                logger.warning(f"Failed to initialize KuzuDB database: {e}")
                return None
        
        try:
            self.conn = kuzu.Connection(self.db_path)
            
            # Initialize schema if needed
            self._init_schema()
            
            return self.conn
        except Exception as e:
            logger.warning(f"Failed to connect to KuzuDB: {e}")
            return None
    
    def _init_schema(self):
        """Initialize basic schema for graph database"""
        if self.conn is None:
            return
            
        try:
            # Create Entity node type if it doesn't exist
            self.conn.execute("""
            CREATE NODE TABLE IF NOT EXISTS Entity (
                id STRING PRIMARY KEY,
                name STRING,
                type STRING
            )
            """)
            
            # Create Relationship edge type if it doesn't exist
            self.conn.execute("""
            CREATE REL TABLE IF NOT EXISTS Relationship (
                FROM Entity TO Entity,
                type STRING,
                weight DOUBLE DEFAULT 1.0
            )
            """)
            
            logger.debug("KuzuDB schema initialized")
        except Exception as e:
            logger.error(f"Failed to initialize KuzuDB schema: {e}")
    
    def register_entity(self, entity_type: str):
        """Register entity type in graph database
        
        Args:
            entity_type: Fully qualified entity name (namespace.name)
            
        Returns:
            Success status
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return False
            
        try:
            # No explicit registration needed for KuzuDB, but we can log it
            logger.info(f"Entity type {entity_type} registered for graph operations")
            return True
        except Exception as e:
            logger.error(f"Failed to register entity type: {e}")
            return False
    
    def add_entities(self, entity_type: str, entities: typing.List[dict]) -> int:
        """Add entity nodes to graph database
        
        Args:
            entity_type: Fully qualified entity name (namespace.name)
            entities: List of entity records with id and name
            
        Returns:
            Number of entities added
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return 0
            
        if not entities:
            return 0
            
        try:
            # Prepare batch insertion
            count = 0
            
            # Create batch of Entity nodes
            for entity in entities:
                if 'id' not in entity or 'name' not in entity:
                    continue
                    
                # Create entity node with id, name and type
                query = """
                MERGE (e:Entity {id: $id})
                SET e.name = $name, e.type = $type
                RETURN e
                """
                
                params = {
                    "id": str(entity['id']),
                    "name": entity['name'],
                    "type": entity_type
                }
                
                self.conn.execute(query, params)
                count += 1
            
            logger.info(f"Added {count} entities of type {entity_type} to graph")
            return count
        except Exception as e:
            logger.error(f"Failed to add entities to graph: {e}")
            return 0
    
    def get_entity_by_name(self, name: str) -> typing.List[dict]:
        """Find entities by name
        
        Args:
            name: Entity name to search for
            
        Returns:
            List of matching entities
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return []
            
        try:
            query = """
            MATCH (e:Entity)
            WHERE e.name CONTAINS $name
            RETURN e.id as id, e.name as name, e.type as type
            """
            
            result = self.conn.execute(query, {"name": name})
            
            # Convert result to list of dictionaries
            entities = []
            for row in result:
                entities.append({
                    "id": row[0],
                    "name": row[1],
                    "type": row[2]
                })
                
            return entities
        except Exception as e:
            logger.error(f"Failed to get entity by name: {e}")
            return []
    
    def get_entity_by_id(self, id: str) -> dict:
        """Get entity by ID
        
        Args:
            id: Entity ID
            
        Returns:
            Entity record or None
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return None
            
        try:
            query = """
            MATCH (e:Entity {id: $id})
            RETURN e.id as id, e.name as name, e.type as type
            """
            
            result = self.conn.execute(query, {"id": id})
            
            for row in result:
                return {
                    "id": row[0],
                    "name": row[1],
                    "type": row[2]
                }
                
            return None
        except Exception as e:
            logger.error(f"Failed to get entity by ID: {e}")
            return None
    
    def create_relationship(self, from_id: str, to_id: str, rel_type: str, weight: float = 1.0) -> bool:
        """Create relationship between entities
        
        Args:
            from_id: Source entity ID
            to_id: Target entity ID
            rel_type: Relationship type
            weight: Relationship weight
            
        Returns:
            Success status
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return False
            
        try:
            query = """
            MATCH (a:Entity {id: $from_id})
            MATCH (b:Entity {id: $to_id})
            CREATE (a)-[r:Relationship {type: $rel_type, weight: $weight}]->(b)
            RETURN r
            """
            
            params = {
                "from_id": str(from_id),
                "to_id": str(to_id),
                "rel_type": rel_type,
                "weight": weight
            }
            
            self.conn.execute(query, params)
            return True
        except Exception as e:
            logger.error(f"Failed to create relationship: {e}")
            return False
    
    def execute_cypher(self, query: str, params: dict = None) -> typing.List[dict]:
        """Execute Cypher query
        
        Args:
            query: Cypher query
            params: Query parameters
            
        Returns:
            Query results
        """
        if self.conn is None:
            logger.warning("KuzuDB connection not available")
            return []
            
        try:
            result = self.conn.execute(query, params or {})
            
            # Convert result to list of dictionaries
            rows = []
            for row in result:
                row_dict = {}
                for i, col in enumerate(result.columns):
                    row_dict[col] = row[i]
                rows.append(row_dict)
                
            return rows
        except Exception as e:
            logger.error(f"Failed to execute Cypher query: {e}")
            return []