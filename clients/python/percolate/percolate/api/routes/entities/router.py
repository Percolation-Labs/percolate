from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query
from percolate.api.routes.auth import hybrid_auth
from pydantic import BaseModel, Field
from percolate.services import PostgresService
from typing import List, Dict, Optional, Any
import uuid
from percolate.models.p8 import Agent, Function
from percolate.utils import logger

router = APIRouter()


@router.post("/", response_model=Agent)
async def create_agent(
    agent: Agent,
    make_discoverable: bool = Query(
        default=False,
        description="If true, register the agent as a discoverable function",
    ),
    user_id: Optional[str] = Depends(hybrid_auth),
):
    """Create a new agent.

    Args:
        agent: The agent to create
        make_discoverable: If true, register the agent as a discoverable function that other agents can find and use
        user_id: User ID from authentication
    """
    # user_id will be None for bearer token, string for session auth
    try:
        # Ensure agent name is qualified with namespace
        if "." not in agent.name:
            # Default to 'public' namespace if not specified
            agent.name = f"public.{agent.name}"

        # Save agent to database
        from percolate import p8

        repo = p8.repository(Agent, user_id=user_id)
        result = repo.update_records([agent])

        # update_records returns a list, get the first item
        if result and len(result) > 0:
            saved_agent = result[0]

            # If make_discoverable is True, register the agent as a function
            if make_discoverable:
                try:
                    # Load the agent as a model to get the proper structure
                    loaded_model = Agent.load(saved_agent["name"])

                    # Create a Function representation of the agent
                    function = Function.from_entity(loaded_model)

                    # Save the function
                    function_repo = p8.repository(Function, user_id=user_id)
                    function_repo.update_records([function])

                except Exception as func_error:
                    logger.error(f"Failed to make agent discoverable: {func_error}")
                    logger.exception("Full traceback:")
                    raise HTTPException(
                        status_code=500,
                        detail=f"Agent created but failed to make discoverable: {str(func_error)}",
                    )

            return saved_agent
        else:
            raise HTTPException(
                status_code=500, detail="Failed to save agent - no result returned"
            )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to save agent: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=f"Failed to save agent: {str(e)}")


@router.get("/", response_model=List[Agent])
async def list_agents(user_id: Optional[str] = Depends(hybrid_auth)):
    """List all agents."""
    try:
        from percolate import p8

        agents = p8.repository(Agent).select()
        return agents
    except Exception as e:
        logger.error(f"Failed to list agents: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=f"Failed to list agents: {str(e)}")


@router.get("/{agent_name}", response_model=Agent)
async def get_agent(agent_name: str, user_id: Optional[str] = Depends(hybrid_auth)):
    """Get a specific agent by name."""
    try:
        from percolate import p8

        agents = p8.repository(Agent).select(name=agent_name)
        if not agents:
            raise HTTPException(
                status_code=404, detail=f"Agent '{agent_name}' not found"
            )
        return agents[0]
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get agent '{agent_name}': {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=f"Failed to get agent: {str(e)}")


@router.put("/agents/{agent_name}", response_model=Agent)
async def update_agent(
    agent_name: str, agent_update: Agent, user_id: Optional[str] = Depends(hybrid_auth)
):
    """Update an existing agent."""
    return {}


@router.delete("/{agent_name}")
async def delete_agent(agent_name: str, user_id: Optional[str] = Depends(hybrid_auth)):
    """Delete an agent."""
    return {"message": f"Agent '{agent_name}' deleted successfully"}


class EntitySearch(BaseModel):
    query: str = Field(..., description="Search query")
    entity_name: str = Field(
        "p8.Agent", description="An Optional entity name to search e.g. a custom table"
    )
    filters: Optional[Dict[str, Any]] = Field(None, description="Optional filters")
    limit: int = Field(10, description="Maximum results to return", ge=1, le=100)


class GetEntitiesRequest(BaseModel):
    keys: List[str] = Field(..., description="List of entity keys to retrieve")
    allow_fuzzy_match: bool = Field(
        True, description="Enable fuzzy matching for entity names"
    )
    similarity_threshold: float = Field(
        0.3,
        description="Similarity threshold for fuzzy matching (0-1, lower is more permissive)",
    )


@router.post("/get")
async def get_entities(
    request: GetEntitiesRequest, user_id: Optional[str] = Depends(hybrid_auth)
):
    """Get entities by their keys with optional fuzzy matching."""
    import percolate as p8

    try:
        # Use the interface function that handles fuzzy matching
        results = p8.get_entities(
            keys=request.keys,
            user_id=user_id,
            allow_fuzzy_match=request.allow_fuzzy_match,
            similarity_threshold=request.similarity_threshold,
        )
        return results
    except Exception as e:
        logger.error(f"Failed to get entities with keys {request.keys}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/search")
async def search_entities(
    search: EntitySearch, user_id: Optional[str] = Depends(hybrid_auth)
):
    """Search for entities using semantic search."""
    import percolate as p8
    from percolate.models import Agent, Resources, Function, User
    from percolate.models.p8.types import Project, Task, PercolateAgent

    try:
        # Special handling for searching entities by type (e.g., "p8.Agent" means find all agents)
        entity_type = search.entity_name

        # If entity_type is a fully qualified name (e.g., "public.Tasks"),
        # try to load it directly as a model
        if "." not in entity_type:
            entity_type = f"public.{entity_type}"
        model_class = None

        # Try to load the entity as a model using load_model
        loaded = p8.try_load_model(entity_type)
        if not loaded:
            logger.error(f"Could not load entity type: {entity_type}")
            raise HTTPException(
                status_code=400,
                detail=f"Invalid entity type: {entity_type}. Entity type must be a valid model.",
            )

        # Use repository search method
        repo = p8.repository(loaded, user_id=user_id)
        results = repo.search(search.query)

        return results
    except HTTPException:
        raise
    except Exception as e:
        logger.error(
            f"Failed to search entities of type '{search.entity_name}' with query '{search.query}': {e}"
        )
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/list/{entity_type}")
async def list_entities(
    entity_type: str,
    limit: int = Query(100, description="Maximum results to return", ge=1, le=1000),
    offset: int = Query(0, description="Offset for pagination", ge=0),
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """List all entities of a specific type."""
    import percolate as p8
    
    try:
        # Special handling for p8.Function
        if entity_type == "p8.Function":
            repo = p8.repository(Function, user_id=user_id)
            results = repo.select()
            
            # Extract relevant fields for functions
            function_list = []
            if results:
                for func in results[offset:offset+limit]:
                    function_info = {
                        'name': func.get('name', ''),
                        'description': func.get('description', ''),
                        'parameters': func.get('parameters', {}),
                        'entity_type': 'p8.Function'
                    }
                    function_list.append(function_info)
            
            return function_list
        else:
            # Try to load the entity type
            loaded = p8.try_load_model(entity_type)
            if not loaded:
                raise HTTPException(
                    status_code=400,
                    detail=f"Invalid entity type: {entity_type}. Entity type must be a valid model."
                )
            
            repo = p8.repository(loaded, user_id=user_id)
            results = repo.select()
            
            # Return paginated results
            return results[offset:offset+limit] if results else []
            
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to list entities of type '{entity_type}': {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))
