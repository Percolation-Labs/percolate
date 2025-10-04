"""
Integration tests for web search functionality via Tavily API
"""
import pytest
import percolate as p8
from percolate.services.llm import CallingContext
from percolate.types.UserRoleAgent import UserRoleAgent
from percolate.utils.env import TAVILY_API_KEY


@pytest.fixture
def skip_if_no_api_key():
    """Skip tests if TAVILY_API_KEY is not configured"""
    if not TAVILY_API_KEY:
        pytest.skip("TAVILY_API_KEY not configured")


def test_search_the_web_direct(skip_if_no_api_key):
    """Test direct web search functionality"""
    # Create a basic agent
    agent = p8.Agent(UserRoleAgent)

    # Verify the agent has search_the_web function available
    assert 'search_the_web' in agent.functions

    # Test web search
    results = agent._function_manager['search_the_web'](
        query="Python programming language",
        max_results=3
    )

    # Verify results structure
    assert isinstance(results, list)
    assert len(results) > 0
    assert len(results) <= 3

    # Verify each result has expected fields
    for result in results:
        assert 'title' in result
        assert 'url' in result
        assert 'summary' in result
        assert result['title']
        assert result['url'].startswith('http')


def test_search_the_web_via_agent(skip_if_no_api_key):
    """Test web search through agent execution"""
    context = CallingContext(
        username="test@example.com",
        user_id="test@example.com",
        role_level=100
    )

    agent = p8.Agent(UserRoleAgent, context=context)

    # Ask a question that should trigger web search
    response = agent.run(
        "Use search_the_web to find information about the latest Python release"
    )

    # Verify we got a response
    assert response is not None
    assert len(response) > 0


def test_agent_has_web_search_enabled():
    """Test that UserRoleAgent has allow_search metadata"""
    agent = p8.Agent(UserRoleAgent)

    # Verify the agent's model config has allow_search=True
    model_config = getattr(agent.agent_model.model, "model_config", {})
    assert model_config.get("allow_search", False) is True

    # Verify search_the_web is in available functions
    assert 'search_the_web' in agent.functions


def test_web_search_max_results_limit(skip_if_no_api_key):
    """Test that max_results is properly limited"""
    agent = p8.Agent(UserRoleAgent)

    # Request more than the max allowed (should be capped at 10)
    results = agent._function_manager['search_the_web'](
        query="artificial intelligence",
        max_results=20
    )

    # Should be limited to 10
    assert len(results) <= 10


def test_web_search_without_api_key():
    """Test that web search fails gracefully without API key"""
    import os
    from unittest.mock import patch

    # Temporarily remove API key
    with patch.dict(os.environ, {'TAVILY_API_KEY': ''}, clear=False):
        agent = p8.Agent(UserRoleAgent)

        # Attempt to search should raise an exception
        with pytest.raises(Exception) as exc_info:
            agent._function_manager['search_the_web'](
                query="test query"
            )

        assert "TAVILY_API_KEY" in str(exc_info.value)
