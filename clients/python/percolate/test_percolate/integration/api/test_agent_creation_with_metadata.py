"""
Integration tests for creating agents via API with metadata services
"""
import pytest
import percolate as p8
from percolate.models.p8 import Agent


def test_create_agent_with_web_search_metadata():
    """Test creating an agent with allow_search metadata via repository"""

    # Create agent with web search enabled
    agent_data = Agent(
        name="test.WebSearchAgent",
        category="research",
        description="I can search the web for current information.",
        metadata={
            "allow_search": True,
            "version": "1.0.0"
        }
    )

    # Save to database
    repo = p8.repository(Agent)
    result = repo.update_records([agent_data])

    # Verify agent was created
    assert result is not None
    assert len(result) > 0

    # Verify metadata was saved
    saved_agent = result[0]
    assert saved_agent["metadata"]["allow_search"] is True
    assert saved_agent["metadata"]["version"] == "1.0.0"


def test_load_agent_with_metadata():
    """Test that loading an agent preserves metadata in model_config"""

    # Create and save agent
    agent_data = Agent(
        name="test.MetadataTestAgent",
        description="Test agent for metadata preservation",
        metadata={
            "allow_search": True,
            "allow_generate_image": True,
            "custom_field": "custom_value"
        }
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Load the agent
    loaded_model = Agent.load("test.MetadataTestAgent")

    # Verify metadata is in model_config
    assert hasattr(loaded_model, "model_config")
    assert loaded_model.model_config.get("allow_search") is True
    assert loaded_model.model_config.get("allow_generate_image") is True
    assert loaded_model.model_config.get("custom_field") == "custom_value"


def test_agent_runner_enables_services_from_metadata():
    """Test that ModelRunner enables services based on agent metadata"""

    # Create agent with web search enabled
    agent_data = Agent(
        name="test.RunnerTestAgent",
        description="Test agent for service activation",
        metadata={
            "allow_search": True
        }
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Load and create runner
    loaded_model = Agent.load("test.RunnerTestAgent")
    agent_runner = p8.Agent(loaded_model)

    # Verify search_the_web function is available
    assert 'search_the_web' in agent_runner.functions

    # Verify the function is callable
    func = agent_runner.functions['search_the_web']
    assert callable(func)


def test_agent_without_metadata_services():
    """Test that agents without metadata don't get extra services"""

    # Create agent without any service metadata
    agent_data = Agent(
        name="test.BasicAgent",
        description="Basic agent without special services",
        metadata={
            "version": "1.0.0"
        }
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Load and create runner
    loaded_model = Agent.load("test.BasicAgent")
    agent_runner = p8.Agent(loaded_model)

    # Verify search_the_web is NOT available
    assert 'search_the_web' not in agent_runner.functions
    assert 'generate_image' not in agent_runner.functions

    # But basic functions should still be there
    assert 'search' in agent_runner.functions  # Internal search
    assert 'get_entities' in agent_runner.functions


def test_agent_with_multiple_services():
    """Test agent with both web search and image generation"""

    # Create agent with multiple services
    agent_data = Agent(
        name="test.MultiServiceAgent",
        description="Agent with multiple services enabled",
        metadata={
            "allow_search": True,
            "allow_generate_image": True,
            "version": "2.0.0"
        }
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Load and create runner
    loaded_model = Agent.load("test.MultiServiceAgent")
    agent_runner = p8.Agent(loaded_model)

    # Verify both services are available
    assert 'search_the_web' in agent_runner.functions
    assert 'generate_image' in agent_runner.functions


def test_update_agent_metadata():
    """Test updating agent metadata and reloading"""

    # Create initial agent
    agent_data = Agent(
        name="test.UpdateableAgent",
        description="Agent that will be updated",
        metadata={
            "version": "1.0.0"
        }
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Update with new metadata
    updated_agent = Agent(
        name="test.UpdateableAgent",
        description="Agent that will be updated",
        metadata={
            "allow_search": True,
            "version": "1.1.0"
        }
    )

    repo.update_records([updated_agent])

    # Reload and verify
    loaded_model = Agent.load("test.UpdateableAgent")
    agent_runner = p8.Agent(loaded_model)

    # Should now have web search
    assert 'search_the_web' in agent_runner.functions
    assert loaded_model.model_config.get("version") == "1.1.0"


def test_list_agents():
    """Test listing all agents"""

    # Create a test agent
    agent_data = Agent(
        name="test.ListTestAgent",
        description="Test agent for listing",
        category="test",
        metadata={"version": "1.0.0"}
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # List all agents
    agents = repo.select()

    # Verify we got results
    assert len(agents) > 0

    # Verify our agent is in the list
    agent_names = [a.get("name") for a in agents]
    assert "test.ListTestAgent" in agent_names


def test_get_specific_agent():
    """Test getting a specific agent by name"""

    # Create agent
    agent_data = Agent(
        name="test.SpecificAgent",
        description="Specific test agent",
        metadata={"test": True}
    )

    repo = p8.repository(Agent)
    repo.update_records([agent_data])

    # Get specific agent
    results = repo.select(name="test.SpecificAgent")

    assert len(results) == 1
    assert results[0]["name"] == "test.SpecificAgent"
    assert results[0]["metadata"]["test"] is True


@pytest.fixture(autouse=True)
def cleanup_test_agents():
    """Clean up test agents after each test"""
    yield

    # Note: In a real scenario, you'd want to delete test agents
    # For now, we'll leave them as they use the test namespace
    # and won't interfere with production
