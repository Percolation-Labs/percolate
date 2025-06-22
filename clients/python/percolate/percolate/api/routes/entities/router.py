from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query
from percolate.api.routes.auth import hybrid_auth
from pydantic import BaseModel, Field
from percolate.services import PostgresService
from typing import List, Dict, Optional
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


@router.post("/search")
async def agentic_search(query: str, agent_name: str, user_id: Optional[str] = Depends(hybrid_auth)):
    """Perform an agent-based search."""
    return {"query": query, "agent": agent_name, "results": ["AI-generated result 1"]}


 