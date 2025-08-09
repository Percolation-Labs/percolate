"""
Integration tests for UserRoleAgent with role-based access control
"""
import pytest
import percolate as p8
from percolate.services.llm import CallingContext
from percolate.types.UserRoleAgent import UserRoleAgent


@pytest.fixture
def setup_database():
    """Ensure database connectivity"""
    pg = p8.repository(p8.models.User)
    # Verify we can connect
    assert pg is not None
    return pg


def test_user_role_agent_basic_user(setup_database):
    """Test UserRoleAgent with basic user role (100)"""
    # Create agent with basic user context
    context = CallingContext(
        username="basic@example.com",
        user_id="basic@example.com",
        role_level=100
    )
    
    agent = p8.Agent(UserRoleAgent, context=context)
    
    # Check available functions - should only have general functions
    available_functions = agent._function_manager.get_functions_for_role_level(100)
    function_names = set(available_functions.keys())
    
    # Basic user should have access to general info
    assert 'get_general_info' in function_names
    # But not partner or executive info
    assert 'get_partner_info' not in function_names
    assert 'get_executive_info' not in function_names
    
    # Test calling allowed function
    result = agent.run("What resources are available?")
    assert result is not None


def test_user_role_agent_partner_user(setup_database):
    """Test UserRoleAgent with partner role (10)"""
    # Create agent with partner context
    context = CallingContext(
        username="partner@example.com",
        user_id="partner@example.com",
        role_level=10
    )
    
    agent = p8.Agent(UserRoleAgent, context=context)
    
    # Check available functions
    available_functions = agent._function_manager.get_functions_for_role_level(10)
    function_names = set(available_functions.keys())
    
    # Partner should have access to general and partner info
    assert 'get_general_info' in function_names
    assert 'get_partner_info' in function_names
    # But not executive info
    assert 'get_executive_info' not in function_names
    
    # Test calling partner function
    result = agent.run("Show me partner resources")
    assert result is not None


def test_user_role_agent_admin_user(setup_database):
    """Test UserRoleAgent with admin role (1)"""
    # Create agent with admin context
    context = CallingContext(
        username="admin@example.com", 
        user_id="admin@example.com",
        role_level=1
    )
    
    agent = p8.Agent(UserRoleAgent, context=context)
    
    # Check available functions
    available_functions = agent._function_manager.get_functions_for_role_level(1)
    function_names = set(available_functions.keys())
    
    # Admin should have access to all functions
    assert 'get_general_info' in function_names
    assert 'get_partner_info' in function_names
    assert 'get_executive_info' in function_names
    
    # Test calling executive function
    result = agent.run("Show me executive reports")
    assert result is not None


def test_user_role_agent_system_access(setup_database):
    """Test UserRoleAgent with system access (None role_level)"""
    # Create agent with system context (no role_level)
    context = CallingContext(
        username="system",
        user_id="system",
        role_level=None
    )
    
    agent = p8.Agent(UserRoleAgent, context=context)
    
    # Check available functions
    available_functions = agent._function_manager.get_functions_for_role_level(None)
    function_names = set(available_functions.keys())
    
    # System should have access to all functions
    assert 'get_general_info' in function_names
    assert 'get_partner_info' in function_names
    assert 'get_executive_info' in function_names


def test_context_with_role_level(setup_database):
    """Test CallingContext.context_with_role_level method"""
    # Create context using the class method
    context = CallingContext.context_with_role_level("test@example.com")
    
    assert context.username == "test@example.com"
    assert context.user_id is not None
    assert context.role_level is not None
    
    # The role_level should be loaded from database
    # For a new user, it would typically be 100 (basic user)
    assert isinstance(context.role_level, int)


def test_master_prompt_loading(setup_database):
    """Test that MASTER_PROMPT is loaded from database"""
    from percolate.utils.env import MASTER_PROMPT
    
    # Get the master prompt
    prompt = MASTER_PROMPT()
    
    # It should return a string (empty or with content)
    assert isinstance(prompt, str)
    
    # If loaded from database, it should be non-empty
    # (unless not set in database)
    print(f"Master prompt loaded: {len(prompt)} characters")


def test_function_access_levels():
    """Test that p8.tool decorator properly sets access levels"""
    from percolate.types.UserRoleAgent import UserRoleAgent
    
    # Get the methods
    agent = UserRoleAgent()
    
    # Check that decorated methods have correct attributes
    assert hasattr(agent.get_general_info, '_p8_access_required')
    assert agent.get_general_info._p8_access_required == 100
    
    assert hasattr(agent.get_partner_info, '_p8_access_required')
    assert agent.get_partner_info._p8_access_required == 10
    
    assert hasattr(agent.get_executive_info, '_p8_access_required')
    assert agent.get_executive_info._p8_access_required == 1