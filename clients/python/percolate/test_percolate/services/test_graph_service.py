import os
import uuid
import json

import pytest

from percolate.services.PostgresService import PostgresService
from percolate.services.PercolateGraph import AddRelationship

@pytest.mark.skip("Skipping Postgres registration test: no live database in CI environment")
@pytest.mark.slow
def test_cypher_query_select_user_nodes():
    """
    Test that a simple Cypher query to select User nodes executes without error.
    """
    pg = PostgresService()
    result = pg.graph.cypher_query("MATCH (n:User) RETURN n", "n agtype")
    assert isinstance(result, list)

    # If there are any results, each should have a 'result' key containing JSONB
    if result:
        first = result[0]
        assert isinstance(first, dict)
        assert "result" in first
    
@pytest.mark.skip("Skipping Postgres registration test: no live database in CI environment")
@pytest.mark.slow    
def test_user_concept_links_round_trip():
    """
    Test adding a User->Concept relationship and retrieving it via get_user_concept_links.
    """
    pg = PostgresService()
    # use a fixed user for the test
    user_name = 'amartey@gmail.com'
    # generate a unique concept name
    unique = uuid.uuid4().hex[:8]
    concept_name = f"rabbits-{unique}"
    # create the relationship: User --likes--> Concept
    rel = AddRelationship(
        source_label="User",
        source_name=user_name,
        rel_type="likes",
        target_name=concept_name,
        target_label="Concept",
    )
    pg.graph.add_relationship(rel)
    # retrieve links of type 'likes' for this user
    try:
        rows = pg.graph.get_user_concept_links(
            user_name=user_name,
            rel_type="likes",
            select_hub=False,
            depth=1,
        )

        # serialize rows and ensure our concept_name is present
        dumped = json.dumps(rows)
        assert concept_name in dumped, f"Expected concept '{concept_name}' in results, got: {dumped}"
        
        """check model loading"""
        model_rows = pg.graph.get_user_concept_links(
            user_name=user_name,
            rel_type="likes",
            select_hub=False,
            depth=1,
            as_model=True
        )
        dumped = json.dumps(rows)
        assert concept_name in dumped, f"Expected concept '{concept_name}' in results, got: {dumped}"
        
    # except Exception as ex:
    #     raise
    finally:
        
        # clean up: deactivate the relationship we just created
        rel_deactivate = AddRelationship(
            source_label="User",
            source_name=user_name,
            rel_type="likes",
            target_name=concept_name,
            target_label="Concept",
            activate=False,
        )
        pg.graph.add_relationship(rel_deactivate)
        
        
samples = {
    'user-concept-path': {
        "u": {
            "id": 4503599627370653,
            "label": "User",
            "properties": {
            "name": "amartey@gmail.com"
            }
        },
        "path": [
            {
            "id": 4503599627370653,
            "label": "User",
            "properties": {
                "name": "amartey@gmail.com"
            }
            },
            {
            "id": 4785074604085139,
            "label": "likes",
            "end_id": 5066549580791993,
            "start_id": 4503599627370653,
            "properties": {
                "created_at": "2025-05-03 19:03:33.753288"
            }
            },
            {
            "id": 5066549580791993,
            "label": "Concept",
            "properties": {
                "name": "rabbits-3d5edbfb"
            }
            }
        ],
        "concept": {
            "id": 5066549580791993,
            "label": "Concept",
            "properties": {
            "name": "rabbits-3d5edbfb"
            }
        }
    }
}