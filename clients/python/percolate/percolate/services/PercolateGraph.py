import json
from typing import Any, Dict, List, Optional
from pydantic import BaseModel
from percolate.models.p8.db_types import ConceptLinks

# Pydantic model for adding relationships in batch or singly
class AddRelationship(BaseModel):
    """
    Pydantic model for adding a relationship between two nodes.

    Attributes:
        source_label: Label of the source node (e.g., 'User').
        source_name: Name or unique identifier of the source node.
        rel_type: Type of the relationship (e.g., 'likes').
        target_name: Name or unique identifier of the target node.
        activate: Whether to activate (True) or deactivate (False) the relationship; defaults to True.
        source_user_id: Optional user identifier for the source node.
        target_label: Optional label for the target node (e.g., 'Concept').
        target_user_id: Optional user identifier for the target node.
        rel_props: Optional dictionary of relationship properties; defaults to empty dict.
    """
    source_label: str
    source_name: str
    rel_type: str
    target_name: str
    activate: bool = True
    source_user_id: Optional[str] = None
    target_label: Optional[str] = None
    target_user_id: Optional[str] = None
    rel_props: Dict[str, Any] = {}

class PercolateGraph:
    """
    A proxy for executing graph-based operations via PostgresService.
    Wraps low-level SQL functions for graph queries and mutations.
    """
    def __init__(self, pg_service: Any):  # pg_service is an instance of PostgresService
        self._pg = pg_service

    
    def get_user_concept_links(
        self,
        user_name: str,
        rel_type: Optional[str] = None,
        select_hub: Optional[bool] = None,
        depth: int = 2,
        as_model:bool=False
    ) -> List[Dict[str, Any]]:
        """
        Retrieve concept nodes linked to a user, with optional relationship filtering and hub selection.
        """
        query = "SELECT * FROM p8.get_user_concept_links(%s, %s, %s, %s)"
        data =  self._pg.execute(query, data=(user_name, rel_type, select_hub, depth))
        if data and as_model:
            """ensure we are using the same schema in the database using the test -> this function returns 'results"""
            data = [ConceptLinks(**d.get('results')) for d in data]
        return data

    def compact_user_memory(
        self,
        threshold: int = 7,
    ) -> List[Dict[str, Any]]:
        """
        Compact user memory relationships into hub nodes when above a threshold.
        """
        query = "SELECT * FROM p8.perform_compact_user_memory_batch(%s)"
        return self._pg.execute(query, data=(threshold,))

    def cypher_query(
        self,
        cypher: str,
        columns: str,
    ) -> List[Dict[str, Any]]:
        """
        Execute a raw Cypher query against the 'percolate' graph.
        """
        query = "SELECT * FROM cypher_query(%s, %s)"
        return self._pg.execute(query, data=(cypher, columns))

    def get_connected_entities(
        self,
        category_name: str,
    ) -> List[Dict[str, Any]]:
        """
        Retrieve entities connected to a given category hub.
        """
        query = "SELECT * FROM p8.get_connected_entities(%s)"
        return self._pg.execute(query, data=(category_name,))

    def get_paths(
        self,
        names: List[str],
        max_length: int = 3,
        max_paths: int = 10,
    ) -> List[Dict[str, Any]]:
        """
        Find paths between chapter nodes given starting names.
        """
        query = "SELECT * FROM p8.get_paths(%s, %s, %s)"
        return self._pg.execute(query, data=(names, max_length, max_paths))

    def get_relationships(
        self,
        source_label: Optional[str] = None,
        source_name: Optional[str] = None,
        rel_type: Optional[str] = None,
        target_label: Optional[str] = None,
        target_name: Optional[str] = None,
        source_user_id: Optional[str] = None,
        target_user_id: Optional[str] = None,
        include_inactive: bool = False,
    ) -> List[Dict[str, Any]]:
        """
        Retrieve relationships from the graph with optional filtering.
        """
        query = (
            "SELECT * FROM p8.get_relationships(%s, %s, %s, %s, %s, %s, %s, %s)"
        )
        return self._pg.execute(
            query,
            data=(
                source_label,
                source_name,
                rel_type,
                target_label,
                target_name,
                source_user_id,
                target_user_id,
                include_inactive,
            ),
        )

    def add_relationship(self, relationship: AddRelationship) -> None:
        """
        Create or deactivate a single relationship between nodes using a Pydantic model.

        Args:
            relationship: An AddRelationship model instance describing the edge.

        Example:
            rel = AddRelationship(
                source_label='User',
                source_name='Alice',
                rel_type='likes',
                target_name='rabbits'
            )
            pg.graph.add_relationship(rel)
        """
        
        return self.add_relationships(relationship)

    def add_relationships(self, relationships: List[AddRelationship]) -> int:
        """
        Batch create or deactivate relationships using a list of Pydantic models.

        Args:
            relationships: A list of AddRelationship instances.

        Returns:
            The result of executing the batch add_relationships_to_node SQL function.
        """
        if not isinstance(relationships,list):
            relationships = [relationships]
        
        payloads = [rel.model_dump() if not isinstance(rel,dict) else rel for rel in relationships]
        
        #print(payloads)
        return self._pg.execute(
            "SELECT p8.add_relationships_to_node(%s::jsonb)",
            data=(json.dumps(payloads),),
        )

    # Placeholder methods for Pydantic model integration
    def add_node_from_model(self, model: BaseModel) -> Any:
        """
        TODO: Implement node creation from Pydantic model
        """
        raise NotImplementedError

    def link_models(
        self,
        source: BaseModel,
        target: BaseModel,
        rel_type: str,
    ) -> Any:
        """
        TODO: Implement linking two Pydantic model instances in the graph
        """
        raise NotImplementedError