from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query
from percolate.api.routes.auth import hybrid_auth
from pydantic import BaseModel, Field
from percolate.services import PostgresService
from typing import List, Dict, Optional, Any
import uuid
from percolate.models.p8 import Agent, Function

router = APIRouter()


@router.post("/", response_model=Agent)
async def create_agent(
    agent: Agent, 
    make_discoverable: bool = Query(default=False, description="If true, register the agent as a discoverable function"),
    user_id: Optional[str] = Depends(hybrid_auth)
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
        if '.' not in agent.name:
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
                    loaded_model = Agent.load(saved_agent['name'])
                    
                    # Create a Function representation of the agent
                    function = Function.from_entity(loaded_model)
                    
                    # Save the function
                    function_repo = p8.repository(Function, user_id=user_id)
                    function_repo.update_records([function])
                    
                except Exception as func_error:
                    # Log the error but don't fail the agent creation
                    raise HTTPException(
                        status_code=500, 
                        detail=f"Agent created but failed to make discoverable: {str(func_error)}"
                    )
            
            return saved_agent
        else:
            raise HTTPException(status_code=500, detail="Failed to save agent - no result returned")
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to save agent: {str(e)}")


@router.get("/", response_model=List[Agent])
async def list_agents(user_id: Optional[str] = Depends(hybrid_auth)):
    """List all agents."""
    try:
        from percolate import p8
        agents = p8.repository(Agent).select()
        return agents
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to list agents: {str(e)}")


@router.get("/{agent_name}", response_model=Agent)
async def get_agent(agent_name: str, user_id: Optional[str] = Depends(hybrid_auth)):
    """Get a specific agent by name."""
    try:
        from percolate import p8
        agents = p8.repository(Agent).select(name=agent_name)
        if not agents:
            raise HTTPException(status_code=404, detail=f"Agent '{agent_name}' not found")
        return agents[0]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get agent: {str(e)}")


@router.put("/agents/{agent_name}", response_model=Agent)
async def update_agent(agent_name: str, agent_update: Agent, user_id: Optional[str] = Depends(hybrid_auth)):
    """Update an existing agent."""
    return {}


@router.delete("/{agent_name}")
async def delete_agent(agent_name: str, user_id: Optional[str] = Depends(hybrid_auth)):
    """Delete an agent."""
    return {"message": f"Agent '{agent_name}' deleted successfully"}


class EntitySearch(BaseModel):
    query: str = Field(..., description="Search query")
    filters: Optional[Dict[str, Any]] = Field(None, description="Optional filters")
    limit: int = Field(10, description="Maximum results to return", ge=1, le=100)


class GetEntitiesRequest(BaseModel):
    keys: List[str] = Field(..., description="List of entity keys to retrieve")
    allow_fuzzy_match: bool = Field(True, description="Enable fuzzy matching for entity names")
    similarity_threshold: float = Field(0.3, description="Similarity threshold for fuzzy matching (0-1, lower is more permissive)")


@router.post("/get")
async def get_entities(
    request: GetEntitiesRequest,
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """Get entities by their keys with optional fuzzy matching."""
    import percolate as p8
    
    try:
        # Use the interface function that handles fuzzy matching
        results = p8.get_entities(
            keys=request.keys,
            user_id=user_id,
            allow_fuzzy_match=request.allow_fuzzy_match,
            similarity_threshold=request.similarity_threshold
        )
        return results
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/search")
async def search_entities(
    search: EntitySearch, 
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """Search for entities using semantic search."""
    import percolate as p8
    from percolate.models import Agent, Resources, Function, User
    from percolate.models.p8.types import Project, Task, PercolateAgent
    
    try:
        # Determine entity type to search
        entity_type = None
        if search.filters and "entity_name" in search.filters:
            entity_type = search.filters["entity_name"]
        elif search.filters and "entity_type" in search.filters:
            entity_type = search.filters["entity_type"]
        elif search.filters and "type" in search.filters:
            entity_type = search.filters["type"]
        
        # If entity_type is a fully qualified name (e.g., "public.Tasks", "p8.Agent"),
        # try to load it directly as a model
        model_class = None
        if entity_type and '.' in entity_type:
            try:
                # Try to load the entity as a model
                model_class = p8.models.load(entity_type)
            except:
                # If loading fails, try without namespace
                simple_name = entity_type.split('.')[-1]
                entity_type = simple_name
        
        # If we don't have a model class yet, use the mapping
        if not model_class:
            # Map entity type to model class
            entity_map = {
                "Agent": Agent,
                "Resources": Resources,
                "Resource": Resources,
                "Function": Function,
                "Project": Project,
                "Task": Task,
                "Tasks": Task,  # Also support plural
                "User": User,
                "PercolateAgent": PercolateAgent
            }
            
            # Get the model class, default to Agent if not found
            model_class = entity_map.get(entity_type, Agent)
        
        # Use repository search method
        repo = p8.repository(model_class, user_id=user_id)
        results = repo.search(search.query)
        
        # Extract and format results
        all_results = []
        
        if results and isinstance(results, list) and len(results) > 0:
            first_result = results[0]
            
            # Check for vector results
            if isinstance(first_result, dict) and 'vector_result' in first_result:
                vector_results = first_result.get('vector_result')
                if vector_results and isinstance(vector_results, list):
                    # Apply filters if provided
                    if search.filters:
                        filtered = []
                        for item in vector_results:
                            if all(item.get(k) == v for k, v in search.filters.items() if k not in ['entity_type', 'type', 'entity_name']):
                                filtered.append(item)
                        all_results.extend(filtered)
                    else:
                        all_results.extend(vector_results)
            
            # Also include relational results if no vector results
            if not all_results and isinstance(first_result, dict) and 'relational_result' in first_result:
                relational_results = first_result.get('relational_result')
                if relational_results and isinstance(relational_results, list):
                    all_results.extend(relational_results)
        
        return all_results[:search.limit]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


 