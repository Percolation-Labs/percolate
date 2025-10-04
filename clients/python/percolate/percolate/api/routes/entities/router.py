from fastapi import APIRouter, HTTPException, BackgroundTasks, Depends, Query
from percolate.api.routes.auth import hybrid_auth, hybrid_auth_with_role
from pydantic import BaseModel, Field
from percolate.services import PostgresService
from typing import List, Dict, Optional, Any, Tuple
import uuid
from percolate.models.p8 import Agent, Function
from percolate.utils import logger
import percolate as p8

router = APIRouter()


class AgentServices(BaseModel):
    """Services configuration for agents"""
    allow_web_search: Optional[bool] = Field(None, description="Enable web search capability")
    allow_generate_image: Optional[bool] = Field(None, description="Enable image generation capability")


class AgentCreateRequest(BaseModel):
    """Extended agent creation request with top-level version and services"""
    name: str
    category: Optional[str] = None
    description: str
    spec: Optional[dict] = Field(default_factory=dict)
    functions: Optional[dict] = Field(default_factory=dict)
    metadata: Optional[dict] = Field(default_factory=dict)
    version: Optional[str] = Field("0", description="Agent version, defaults to '0'")
    services: Optional[AgentServices] = Field(None, description="Service configuration (written to metadata)")

    def to_agent(self) -> Agent:
        """Convert request to Agent model, merging version and services into metadata"""
        # Start with provided metadata or empty dict
        merged_metadata = self.metadata.copy() if self.metadata else {}

        # Always set version in metadata (default to "0")
        merged_metadata["version"] = self.version or "0"

        # Merge services into metadata if provided
        if self.services:
            services_dict = self.services.model_dump(exclude_none=True)
            for key, value in services_dict.items():
                # Only write from services if not already in metadata
                if key not in merged_metadata:
                    merged_metadata[key] = value

        return Agent(
            name=self.name,
            category=self.category,
            description=self.description,
            spec=self.spec,
            functions=self.functions,
            metadata=merged_metadata
        )


def prepare_agent_for_save(agent: Agent, user_id: Optional[str], make_public: bool, role_level: int = 0):
    """Prepare agent for saving by generating appropriate ID and validating public agent conflicts.

    Args:
        agent: The agent to prepare
        user_id: User ID from authentication (None for bearer token)
        make_public: Whether to create a public agent
        role_level: User's role level (>1 allows overwriting public agents)

    Returns:
        Tuple of (prepared_agent, repository)

    Raises:
        HTTPException: If validation fails
    """
    from percolate.utils import make_uuid
    from percolate import p8

    # Ensure agent name is qualified with namespace
    if "." not in agent.name:
        agent.name = f"public.{agent.name}"

    if make_public:
        # For public agents, ID is just based on name
        agent.id = make_uuid(agent.name)

        # Check if public agent with same name already exists
        # Only prevent overwrites if role_level <= 1
        if role_level <= 1:
            existing = p8.repository(Agent, user_id=None).select(name=agent.name)
            if existing and len(existing) > 0:
                raise HTTPException(
                    status_code=409,
                    detail=f"Public agent with name '{agent.name}' already exists. Cannot overwrite public agents (requires role level > 1)."
                )

        # Save without user_id to make it public
        repo = p8.repository(Agent, user_id=None)
    else:
        # For user-bound agents, ID includes user_id
        if not user_id:
            raise HTTPException(
                status_code=401,
                detail="User authentication required for creating user-bound agents"
            )
        agent.id = make_uuid({"name": agent.name, "userid": user_id})
        repo = p8.repository(Agent, user_id=user_id)

    return agent, repo


@router.post("/", response_model=Agent)
async def create_agent(
    request: AgentCreateRequest,
    make_discoverable: bool = Query(
        default=False,
        description="If true, register the agent as a discoverable function",
    ),
    make_public: bool = Query(
        default=False,
        description="If true, create a public agent not bound to user (requires role level > 1 to overwrite existing)",
    ),
    auth: Tuple[Optional[str], Optional[int]] = Depends(hybrid_auth_with_role),
):
    """Create a new agent with version tracking and service configuration.

    You can supply the description as prompt. Services like allow_web_search and allow_generate_image
    can be set via the top-level 'services' parameter or directly in metadata.
    Version is tracked automatically (defaults to "0").

    Args:
        request: Agent creation request with version and services
        make_discoverable: If true, register the agent as a discoverable function that other agents can find and use
        make_public: If true, create a public agent accessible to all users (role level > 1 can overwrite existing)
        auth: Tuple of (user_id, role_level) from authentication
    """
    try:
        user_id, role_level = auth
        role_level = role_level or 0  # Default to 0 if None

        # Convert request to Agent model (merges version and services into metadata)
        agent = request.to_agent()

        # Prepare agent and get appropriate repository
        agent, repo = prepare_agent_for_save(agent, user_id, make_public, role_level)

        # Save agent to database
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

        agents = p8.repository(Agent).select() if not user_id else p8.repository(Agent).select(userid=user_id)
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


# Agent Time Machine endpoints

class AgentVersionInfo(BaseModel):
    """Version history information for an agent"""
    id: int
    version: str
    created_at: str
    name: str
    has_version: bool


class RollbackResponse(BaseModel):
    """Response from rollback operation"""
    success: bool
    message: str
    rolled_back_to_version: Optional[str]


@router.get("/agents/{agent_id}/versions", response_model=List[AgentVersionInfo])
async def list_agent_versions(
    agent_id: uuid.UUID,
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """List all available versions for an agent in the time machine."""
    try:
        pg = PostgresService()

        # Call the list_agent_versions function
        result = pg.execute(
            "SELECT * FROM p8.list_agent_versions(%s::uuid)",
            [str(agent_id)]
        )

        if not result:
            return []

        versions = []
        for row in result:
            versions.append(AgentVersionInfo(
                id=row[0],
                version=row[1],
                created_at=str(row[2]),
                name=row[3],
                has_version=row[4]
            ))

        return versions

    except Exception as e:
        logger.error(f"Failed to list agent versions for {agent_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/agents/{agent_id}/rollback", response_model=RollbackResponse)
async def rollback_agent_to_version(
    agent_id: uuid.UUID,
    version: Optional[str] = Query(None, description="Version to rollback to. If not provided, rolls back to most recent versioned entry."),
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """Rollback an agent to a specific version using the time machine.

    If version is not provided, rolls back to the most recent versioned entry.
    Raises an error if no versioned entry is found.
    """
    try:
        pg = PostgresService()

        # Call the rollback function
        if version:
            result = pg.execute(
                "SELECT * FROM p8.rollback_agent_version(%s::uuid, %s)",
                [str(agent_id), version]
            )
        else:
            result = pg.execute(
                "SELECT * FROM p8.rollback_agent_version(%s::uuid)",
                [str(agent_id)]
            )

        if not result or len(result) == 0:
            raise HTTPException(
                status_code=500,
                detail="Rollback operation did not return a result"
            )

        row = result[0]
        response = RollbackResponse(
            success=row[0],
            message=row[1],
            rolled_back_to_version=row[2]
        )

        if not response.success:
            raise HTTPException(status_code=400, detail=response.message)

        return response

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to rollback agent {agent_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/agents/{agent_id}/versions/{version}", response_model=Dict[str, Any])
async def get_agent_version(
    agent_id: uuid.UUID,
    version: str,
    user_id: Optional[str] = Depends(hybrid_auth)
):
    """Get a specific version of an agent from the time machine."""
    try:
        pg = PostgresService()

        # Call the get_agent_version function
        result = pg.execute(
            "SELECT * FROM p8.get_agent_version(%s::uuid, %s)",
            [str(agent_id), version]
        )

        if not result or len(result) == 0:
            raise HTTPException(
                status_code=404,
                detail=f"Version '{version}' not found for agent {agent_id}"
            )

        row = result[0]

        # Build response dict matching the time machine table structure
        version_data = {
            "id": row[0],
            "agent_id": str(row[1]),
            "name": row[2],
            "category": row[3],
            "description": row[4],
            "spec": row[5],
            "functions": row[6],
            "metadata": row[7],
            "version": row[8],
            "created_at": str(row[9]),
            "userid": row[10]
        }

        return version_data

    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Failed to get agent version {version} for {agent_id}: {e}")
        logger.exception("Full traceback:")
        raise HTTPException(status_code=500, detail=str(e))
