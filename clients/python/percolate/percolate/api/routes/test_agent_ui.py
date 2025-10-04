"""
Minimal testing UI for agent management endpoints
For development/testing only - not for production use
"""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
import os

router = APIRouter(prefix="/test", tags=["testing"])


@router.get("/agent-manager", response_class=HTMLResponse)
async def agent_manager_ui(request: Request):
    """Simple grayscale UI for testing agent CRUD operations"""
    import percolate as p8
    from percolate.models.p8.types import Agent, Function

    # Get bearer token from environment for local testing
    bearer_token = os.environ.get("P8_TEST_BEARER_TOKEN", "")

    # Load all agents (most recent first)
    try:
        agent_repo = p8.repository(Agent)
        agents = agent_repo.select()
        # Sort by updated_at or created_at descending (most recent first)
        agents = sorted(agents, key=lambda x: x.get('updated_at') or x.get('created_at') or '', reverse=True)
    except Exception as e:
        agents = []

    # Load all functions
    try:
        func_repo = p8.repository(Function)
        functions = func_repo.select()
    except Exception as e:
        functions = []

    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Agent Manager - Test UI</title>
        <style>
            * {{
                box-sizing: border-box;
                margin: 0;
                padding: 0;
            }}

            body {{
                font-family: monospace;
                background: #1a1a1a;
                color: #e0e0e0;
                padding: 20px;
                line-height: 1.6;
            }}

            .container {{
                max-width: 1400px;
                margin: 0 auto;
            }}

            h1 {{
                color: #fff;
                margin-bottom: 10px;
                font-size: 24px;
            }}

            .info {{
                color: #888;
                margin-bottom: 30px;
                font-size: 12px;
            }}

            .section {{
                background: #2a2a2a;
                border: 1px solid #444;
                padding: 20px;
                margin-bottom: 20px;
            }}

            .section-title {{
                color: #fff;
                font-size: 16px;
                margin-bottom: 15px;
                border-bottom: 1px solid #444;
                padding-bottom: 5px;
            }}

            .form-row {{
                margin-bottom: 15px;
            }}

            label {{
                display: block;
                color: #aaa;
                margin-bottom: 5px;
                font-size: 12px;
            }}

            input[type="text"],
            input[type="number"],
            textarea,
            select {{
                width: 100%;
                padding: 8px;
                background: #1a1a1a;
                border: 1px solid #444;
                color: #e0e0e0;
                font-family: monospace;
                font-size: 13px;
            }}

            textarea {{
                min-height: 100px;
                resize: vertical;
            }}

            button {{
                background: #444;
                color: #fff;
                border: 1px solid #666;
                padding: 8px 16px;
                cursor: pointer;
                font-family: monospace;
                font-size: 13px;
                margin-right: 10px;
            }}

            button:hover {{
                background: #555;
            }}

            button:active {{
                background: #333;
            }}

            .checkbox-group {{
                margin-bottom: 15px;
            }}

            .checkbox-row {{
                margin-bottom: 8px;
            }}

            .checkbox-row input[type="checkbox"] {{
                width: auto;
                margin-right: 8px;
            }}

            .checkbox-row label {{
                display: inline;
                margin-bottom: 0;
            }}

            .function-list {{
                background: #1a1a1a;
                border: 1px solid #444;
                padding: 10px;
                min-height: 100px;
                margin-top: 10px;
            }}

            .function-item {{
                background: #2a2a2a;
                border: 1px solid #555;
                padding: 5px 10px;
                margin-bottom: 5px;
                display: inline-block;
                margin-right: 5px;
            }}

            .function-item button {{
                background: transparent;
                border: none;
                color: #ff6666;
                padding: 0 5px;
                margin: 0 0 0 10px;
                cursor: pointer;
            }}

            .version-list {{
                max-height: 200px;
                overflow-y: auto;
                background: #1a1a1a;
                border: 1px solid #444;
                padding: 10px;
            }}

            .version-item {{
                padding: 8px;
                border-bottom: 1px solid #333;
                cursor: pointer;
            }}

            .version-item:hover {{
                background: #2a2a2a;
            }}

            .version-item.selected {{
                background: #3a3a3a;
                border-left: 3px solid #888;
            }}

            .output-box {{
                background: #0a0a0a;
                border: 1px solid #444;
                padding: 15px;
                min-height: 200px;
                max-height: 400px;
                overflow-y: auto;
                font-size: 12px;
                white-space: pre-wrap;
                word-wrap: break-word;
            }}

            .error {{
                color: #ff6666;
            }}

            .success {{
                color: #66ff66;
            }}

            .split-layout {{
                display: grid;
                grid-template-columns: 1fr 1fr;
                gap: 20px;
            }}

            .metadata-display {{
                background: #1a1a1a;
                border: 1px solid #444;
                padding: 10px;
                font-size: 12px;
                white-space: pre-wrap;
                max-height: 300px;
                overflow-y: auto;
            }}

            @media (max-width: 1024px) {{
                .split-layout {{
                    grid-template-columns: 1fr;
                }}
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Agent Manager - Test UI</h1>
            <div class="info">
                User: amartey@gmail.com | Environment: {request.base_url}
            </div>

            <!-- Hidden bearer token from env -->
            <input type="hidden" id="bearerToken" value="{bearer_token}">

            <!-- Agent Search and Load -->
            <div class="section">
                <div class="section-title">1. Search & Load Agent</div>
                <div class="form-row">
                    <label>Select Agent</label>
                    <select id="agentDropdown" onchange="selectAgentFromDropdown()">
                        <option value="">-- Select Agent --</option>
                        {''.join(f'<option value="{agent.get("name", "")}">{agent.get("name", "")} ({agent.get("category", "uncategorized")})</option>' for agent in agents)}
                    </select>
                </div>
                <div class="form-row">
                    <label>Or Enter Agent Name</label>
                    <input type="text" id="agentName" placeholder="e.g., test.my_agent">
                </div>
                <button onclick="loadAgent()">Load Agent</button>
                <button onclick="clearForm()">Clear Form</button>
            </div>

            <div class="split-layout">
                <!-- Agent Configuration -->
                <div>
                    <div class="section">
                        <div class="section-title">2. Agent Configuration</div>

                        <div class="form-row">
                            <label>Agent ID (read-only)</label>
                            <input type="text" id="agentId" readonly>
                        </div>

                        <div class="form-row">
                            <label>Category</label>
                            <input type="text" id="category" placeholder="e.g., research">
                        </div>

                        <div class="form-row">
                            <label>Description / System Prompt</label>
                            <textarea id="description" placeholder="Agent description and instructions..."></textarea>
                        </div>

                        <div class="form-row">
                            <label>Version</label>
                            <input type="text" id="version" placeholder="e.g., 1.0">
                        </div>

                        <div class="checkbox-group">
                            <div class="section-title">Services</div>
                            <div id="servicesCheckboxes">
                                <div class="checkbox-row">
                                    <input type="checkbox" id="service_allow_web_search" data-service="allow_web_search">
                                    <label for="service_allow_web_search">allow_web_search (Tavily)</label>
                                </div>
                                <div class="checkbox-row">
                                    <input type="checkbox" id="service_allow_generate_image" data-service="allow_generate_image">
                                    <label for="service_allow_generate_image">allow_generate_image (DALL-E)</label>
                                </div>
                            </div>
                        </div>

                        <div class="checkbox-group">
                            <div class="section-title">Visibility</div>
                            <div class="checkbox-row">
                                <input type="checkbox" id="makePublic">
                                <label for="makePublic">Make Public</label>
                            </div>
                            <div class="checkbox-row">
                                <input type="checkbox" id="makeDiscoverable">
                                <label for="makeDiscoverable">Make Discoverable (as Function)</label>
                            </div>
                        </div>
                    </div>

                    <div class="section">
                        <div class="section-title">3. Functions</div>
                        <div class="form-row">
                            <label>Add Function</label>
                            <select id="functionSelect">
                                <option value="">-- Select Function --</option>
                                {''.join(f'<option value="{func.get("name", "")}">{func.get("name", "")} - {func.get("description", "")[:50]}</option>' for func in functions)}
                            </select>
                        </div>
                        <button onclick="addFunction()">Add Function</button>

                        <div class="function-list" id="functionList"></div>
                    </div>

                    <div class="section">
                        <button onclick="saveAgent()">Create/Update Agent</button>
                        <button onclick="deleteAgent()">Delete Agent</button>
                    </div>
                </div>

                <!-- Metadata Display and Version Management -->
                <div>
                    <div class="section">
                        <div class="section-title">Current Metadata</div>
                        <div class="metadata-display" id="metadataDisplay">Load an agent to see metadata</div>
                    </div>

                    <div class="section">
                        <div class="section-title">4. Version History</div>
                        <button onclick="loadVersions()">Refresh Versions</button>
                        <div class="version-list" id="versionList">
                            <div style="color: #888;">Load an agent and click Refresh Versions</div>
                        </div>
                        <button onclick="rollbackVersion()">Rollback to Selected Version</button>
                    </div>
                </div>
            </div>

            <!-- Prompt Testing -->
            <div class="section">
                <div class="section-title">5. Test Agent</div>
                <div class="form-row">
                    <label>Test Query</label>
                    <textarea id="testQuery" placeholder="Enter a test query..."></textarea>
                </div>
                <div class="checkbox-row">
                    <input type="checkbox" id="rawMode">
                    <label for="rawMode">Show Raw SSE (uncheck for parsed messages)</label>
                </div>
                <button onclick="testAgent()">Test Agent (Stream)</button>
                <button onclick="clearOutput()">Clear Output</button>

                <div class="section-title" style="margin-top: 20px;">Events</div>
                <div class="output-box" id="eventsBox" style="max-height: 200px;"></div>

                <div class="section-title" style="margin-top: 20px;">Response</div>
                <div class="output-box" id="outputBox"></div>
            </div>
        </div>

        <script>
            const API_BASE = '{request.base_url}';
            const USER_EMAIL = 'amartey@gmail.com';

            let currentFunctions = [];
            let selectedVersion = null;
            let availableServices = [];
            let availableFunctions = [];

            function apiHeaders() {{
                const headers = {{
                    'X-User-Email': USER_EMAIL,
                    'Content-Type': 'application/json'
                }};

                const token = document.getElementById('bearerToken')?.value.trim();
                if (token) {{
                    headers['Authorization'] = `Bearer ${{token}}`;
                }}

                return headers;
            }}

            function log(message, type = 'info') {{
                const output = document.getElementById('outputBox');
                const timestamp = new Date().toISOString().split('T')[1].split('.')[0];
                let className = '';
                if (type === 'error') className = 'error';
                if (type === 'success') className = 'success';
                output.innerHTML += `<span class="${{className}}">[${{timestamp}}] ${{message}}</span>\\n`;
                output.scrollTop = output.scrollHeight;
            }}

            function clearOutput() {{
                document.getElementById('outputBox').innerHTML = '';
                document.getElementById('eventsBox').innerHTML = '';
            }}

            function logEvent(message, type = 'info') {{
                const output = document.getElementById('eventsBox');
                const timestamp = new Date().toISOString().split('T')[1].split('.')[0];
                let className = '';
                if (type === 'error') className = 'error';
                if (type === 'success') className = 'success';
                output.innerHTML += `<span class="${{className}}">[${{timestamp}}] ${{message}}</span>\\n`;
                output.scrollTop = output.scrollHeight;
            }}

            function clearForm() {{
                document.getElementById('agentId').value = '';
                document.getElementById('agentName').value = '';
                document.getElementById('category').value = '';
                document.getElementById('description').value = '';
                document.getElementById('version').value = '';
                document.getElementById('allowWebSearch').checked = false;
                document.getElementById('allowImageGen').checked = false;
                document.getElementById('makePublic').checked = false;
                document.getElementById('makeDiscoverable').checked = false;
                currentFunctions = [];
                updateFunctionList();
                document.getElementById('metadataDisplay').textContent = 'Load an agent to see metadata';
                document.getElementById('versionList').innerHTML = '<div style="color: #888;">Load an agent and click Refresh Versions</div>';
                selectedVersion = null;
            }}

            // No auto-loading on page load

            function selectAgentFromDropdown() {{
                const dropdown = document.getElementById('agentDropdown');
                const agentName = dropdown.value;
                if (agentName) {{
                    document.getElementById('agentName').value = agentName;
                    loadAgent();
                }}
            }}

            async function loadAgentList() {{
                try {{
                    const response = await fetch(`${{API_BASE}}entities/`, {{
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    const agents = await response.json();
                    const dropdown = document.getElementById('agentDropdown');

                    dropdown.innerHTML = '<option value="">-- Select Agent --</option>';

                    if (Array.isArray(agents)) {{
                        agents.forEach(agent => {{
                            const option = document.createElement('option');
                            option.value = agent.name;
                            option.textContent = `${{agent.name}} (${{agent.category || 'uncategorized'}})`;
                            dropdown.appendChild(option);
                        }});
                    }}
                }} catch (error) {{
                    alert(`Error loading agents: ${{error.message}}`);
                    document.getElementById('agentDropdown').innerHTML = '<option value="">-- Error loading agents --</option>';
                }}
            }}

            async function loadServices() {{
                try {{
                    const response = await fetch(`${{API_BASE}}tools/services`, {{
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    const services = await response.json();
                    availableServices = Array.isArray(services) ? services : [];

                    const container = document.getElementById('servicesCheckboxes');
                    if (availableServices.length === 0) {{
                        // Fallback to hardcoded services if endpoint returns empty
                        availableServices = [
                            {{ name: 'allow_web_search', description: 'Web Search (Tavily)' }},
                            {{ name: 'allow_generate_image', description: 'Image Generation (DALL-E)' }}
                        ];
                    }}

                    container.innerHTML = availableServices.map(service => {{
                        const name = service.name || service;
                        const desc = service.description || name;
                        return `<div class="checkbox-row">
                            <input type="checkbox" id="service_${{name}}" data-service="${{name}}">
                            <label for="service_${{name}}">${{desc}}</label>
                        </div>`;
                    }}).join('');
                }} catch (error) {{
                    // Fallback to hardcoded services
                    const container = document.getElementById('servicesCheckboxes');
                    container.innerHTML = `
                        <div class="checkbox-row">
                            <input type="checkbox" id="service_allow_web_search" data-service="allow_web_search">
                            <label for="service_allow_web_search">allow_web_search (Tavily)</label>
                        </div>
                        <div class="checkbox-row">
                            <input type="checkbox" id="service_allow_generate_image" data-service="allow_generate_image">
                            <label for="service_allow_generate_image">allow_generate_image (DALL-E)</label>
                        </div>`;
                }}
            }}

            async function loadFunctions() {{
                try {{
                    const response = await fetch(`${{API_BASE}}tools/functions`, {{
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    const functions = await response.json();
                    availableFunctions = Array.isArray(functions) ? functions : [];

                    const select = document.getElementById('functionSelect');
                    select.innerHTML = '<option value="">-- Select Function --</option>';

                    availableFunctions.forEach(func => {{
                        const option = document.createElement('option');
                        const name = func.name || func;
                        const desc = func.description || '';
                        option.value = name;
                        option.textContent = desc ? `${{name}} - ${{desc}}` : name;
                        select.appendChild(option);
                    }});
                }} catch (error) {{
                    // Fallback to basic functions
                    const select = document.getElementById('functionSelect');
                    select.innerHTML = `
                        <option value="">-- Select Function --</option>
                        <option value="search">search (local RAG)</option>
                        <option value="search_the_web">search_the_web (Tavily)</option>
                        <option value="generate_image">generate_image (DALL-E)</option>
                        <option value="help">help</option>`;
                }}
            }}

            async function loadAgent() {{
                const name = document.getElementById('agentName').value.trim();
                if (!name) {{
                    alert('Enter agent name');
                    return;
                }}

                clearOutput();
                log(`Loading agent: ${{name}}`);

                try {{
                    const response = await fetch(`${{API_BASE}}entities/${{name}}`, {{
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}: ${{response.statusText}}`);
                    }}

                    const agent = await response.json();
                    log(`Agent loaded: ${{agent.id}}`, 'success');

                    // Populate form
                    document.getElementById('agentId').value = agent.id || '';
                    document.getElementById('category').value = agent.category || '';
                    document.getElementById('description').value = agent.description || '';
                    document.getElementById('version').value = agent.metadata?.version || '0';

                    // Set service checkboxes based on metadata
                    document.querySelectorAll('[data-service]').forEach(checkbox => {{
                        const serviceName = checkbox.dataset.service;
                        checkbox.checked = agent.metadata?.[serviceName] || false;
                    }});

                    // Display metadata
                    document.getElementById('metadataDisplay').textContent = JSON.stringify(agent.metadata || {{}}, null, 2);

                    // Load functions
                    currentFunctions = agent.functions ? Object.keys(agent.functions) : [];
                    updateFunctionList();

                }} catch (error) {{
                    log(`Error loading agent: ${{error.message}}`, 'error');
                }}
            }}

            function addFunction() {{
                const select = document.getElementById('functionSelect');
                const func = select.value;
                if (!func) return;

                if (!currentFunctions.includes(func)) {{
                    currentFunctions.push(func);
                    updateFunctionList();
                }}
                select.value = '';
            }}

            function removeFunction(func) {{
                currentFunctions = currentFunctions.filter(f => f !== func);
                updateFunctionList();
            }}

            function updateFunctionList() {{
                const list = document.getElementById('functionList');
                if (currentFunctions.length === 0) {{
                    list.innerHTML = '<div style="color: #888;">No functions added</div>';
                    return;
                }}

                list.innerHTML = currentFunctions.map(func =>
                    `<div class="function-item">${{func}}<button onclick="removeFunction('${{func}}')">×</button></div>`
                ).join('');
            }}

            async function saveAgent() {{
                const name = document.getElementById('agentName').value.trim();
                const description = document.getElementById('description').value.trim();

                if (!name || !description) {{
                    alert('Name and description are required');
                    return;
                }}

                clearOutput();
                log(`Saving agent: ${{name}}`);

                // Collect checked services
                const services = {{}};
                document.querySelectorAll('[data-service]').forEach(checkbox => {{
                    const serviceName = checkbox.dataset.service;
                    if (checkbox.checked) {{
                        services[serviceName] = true;
                    }}
                }});

                const payload = {{
                    name: name,
                    category: document.getElementById('category').value.trim() || null,
                    description: description,
                    version: document.getElementById('version').value.trim() || '0',
                    services: services,
                    functions: currentFunctions.length > 0 ?
                        Object.fromEntries(currentFunctions.map(f => [f, {{}}])) : {{}},
                    spec: {{}},
                    metadata: {{}}
                }};

                const makePublic = document.getElementById('makePublic').checked;
                const makeDiscoverable = document.getElementById('makeDiscoverable').checked;

                try {{
                    const url = `${{API_BASE}}entities/?make_public=${{makePublic}}&make_discoverable=${{makeDiscoverable}}`;
                    const response = await fetch(url, {{
                        method: 'POST',
                        headers: apiHeaders(),
                        body: JSON.stringify(payload)
                    }});

                    if (!response.ok) {{
                        const error = await response.json();
                        throw new Error(error.detail || `HTTP ${{response.status}}`);
                    }}

                    const result = await response.json();
                    log(`Agent saved successfully: ${{result.id}}`, 'success');
                    log(`Metadata: ${{JSON.stringify(result.metadata)}}`, 'success');

                    // Update form with saved data
                    document.getElementById('agentId').value = result.id;
                    document.getElementById('metadataDisplay').textContent = JSON.stringify(result.metadata || {{}}, null, 2);

                }} catch (error) {{
                    log(`Error saving agent: ${{error.message}}`, 'error');
                }}
            }}

            async function deleteAgent() {{
                const name = document.getElementById('agentName').value.trim();
                if (!name) {{
                    alert('Enter agent name');
                    return;
                }}

                if (!confirm(`Delete agent: ${{name}}?`)) return;

                clearOutput();
                log(`Deleting agent: ${{name}}`);

                try {{
                    const response = await fetch(`${{API_BASE}}entities/${{name}}`, {{
                        method: 'DELETE',
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    log(`Agent deleted successfully`, 'success');
                    clearForm();

                }} catch (error) {{
                    log(`Error deleting agent: ${{error.message}}`, 'error');
                }}
            }}

            async function loadVersions() {{
                const agentId = document.getElementById('agentId').value.trim();
                if (!agentId) {{
                    alert('Load an agent first');
                    return;
                }}

                log(`Loading version history for: ${{agentId}}`);

                try {{
                    const response = await fetch(`${{API_BASE}}entities/agents/${{agentId}}/versions`, {{
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    const versions = await response.json();
                    log(`Found ${{versions.length}} versions`, 'success');

                    const list = document.getElementById('versionList');
                    if (versions.length === 0) {{
                        list.innerHTML = '<div style="color: #888;">No versions found</div>';
                        return;
                    }}

                    list.innerHTML = versions.map(v => {{
                        const date = new Date(v.created_at).toLocaleString();
                        return `<div class="version-item" onclick="selectVersion('${{v.version}}', '${{v.id}}')">
                            <strong>${{v.version || 'unversioned'}}</strong> - ${{date}}<br>
                            <small style="color: #888;">ID: ${{v.id}}</small>
                        </div>`;
                    }}).join('');

                }} catch (error) {{
                    log(`Error loading versions: ${{error.message}}`, 'error');
                }}
            }}

            function selectVersion(version, id) {{
                selectedVersion = version;
                document.querySelectorAll('.version-item').forEach(item => {{
                    item.classList.remove('selected');
                }});
                event.currentTarget.classList.add('selected');
                log(`Selected version: ${{version}} (ID: ${{id}})`);
            }}

            async function rollbackVersion() {{
                const agentId = document.getElementById('agentId').value.trim();
                if (!agentId || !selectedVersion) {{
                    alert('Load an agent and select a version');
                    return;
                }}

                if (!confirm(`Rollback to version: ${{selectedVersion}}?`)) return;

                clearOutput();
                log(`Rolling back to version: ${{selectedVersion}}`);

                try {{
                    const response = await fetch(`${{API_BASE}}entities/agents/${{agentId}}/rollback?version=${{selectedVersion}}`, {{
                        method: 'POST',
                        headers: apiHeaders()
                    }});

                    if (!response.ok) {{
                        const error = await response.json();
                        throw new Error(error.detail || `HTTP ${{response.status}}`);
                    }}

                    const result = await response.json();
                    log(`Rollback successful: ${{result.message}}`, 'success');

                    // Reload agent
                    await loadAgent();

                }} catch (error) {{
                    log(`Error rolling back: ${{error.message}}`, 'error');
                }}
            }}

            async function testAgent() {{
                const name = document.getElementById('agentName').value.trim();
                const query = document.getElementById('testQuery').value.trim();
                const rawMode = document.getElementById('rawMode').checked;

                if (!name || !query) {{
                    alert('Enter agent name and test query');
                    return;
                }}

                clearOutput();
                logEvent(`Testing agent: ${{name}}`);
                logEvent(`Query: ${{query}}`);
                logEvent(`Mode: ${{rawMode ? 'Raw SSE' : 'Parsed Messages'}}`);

                const sessionId = crypto.randomUUID();
                let accumulatedContent = '';

                try {{
                    const response = await fetch(`${{API_BASE}}chat/agent/${{name}}/completions?session_id=${{sessionId}}`, {{
                        method: 'POST',
                        headers: apiHeaders(),
                        body: JSON.stringify({{
                            messages: [{{ role: 'user', content: query }}],
                            model: 'gpt-4o-mini',
                            stream: true
                        }})
                    }});

                    if (!response.ok) {{
                        throw new Error(`HTTP ${{response.status}}`);
                    }}

                    const reader = response.body.getReader();
                    const decoder = new TextDecoder();

                    while (true) {{
                        const {{ done, value }} = await reader.read();
                        if (done) break;

                        const chunk = decoder.decode(value);
                        const lines = chunk.split('\\n');

                        let currentEvent = null;

                        for (const line of lines) {{
                            if (!line.trim()) continue;

                            if (rawMode) {{
                                // Raw mode: show everything
                                log(line);
                            }} else {{
                                // Parsed mode: separate events from data
                                if (line.startsWith('event: ')) {{
                                    // This is an SSE event line
                                    currentEvent = line.substring(7);
                                    logEvent(`SSE Event: ${{currentEvent}}`, 'info');
                                }} else if (line.startsWith('data: ')) {{
                                    // This is an SSE data line
                                    const data = line.substring(6);

                                    // If we have a current event, show the data with that context
                                    if (currentEvent) {{
                                        try {{
                                            const json = JSON.parse(data);
                                            logEvent(`[${{currentEvent}}] ${{JSON.stringify(json).substring(0, 200)}}...`);
                                        }} catch (e) {{
                                            logEvent(`[${{currentEvent}}] ${{data.substring(0, 100)}}...`);
                                        }}
                                        currentEvent = null; // Reset after showing
                                    }} else {{
                                        // Regular data stream - parse as JSON
                                        try {{
                                            const json = JSON.parse(data);

                                            // Extract content from delta
                                            if (json.choices?.[0]?.delta?.content) {{
                                                const content = json.choices[0].delta.content;
                                                accumulatedContent += content;
                                                document.getElementById('outputBox').textContent = accumulatedContent;
                                            }}

                                            // Show finish reason
                                            if (json.choices?.[0]?.finish_reason) {{
                                                logEvent(`Finish: ${{json.choices[0].finish_reason}}`, 'success');
                                            }}
                                        }} catch (e) {{
                                            // Not JSON, show as-is
                                            logEvent(`Data: ${{data.substring(0, 100)}}`);
                                        }}
                                    }}
                                }}
                            }}
                        }}
                    }}

                    logEvent(`Session ID: ${{sessionId}}`, 'success');
                    logEvent('Stream complete', 'success');

                }} catch (error) {{
                    logEvent(`Error: ${{error.message}}`, 'error');
                }}
            }}
        </script>
    </body>
    </html>
    """

    return html_content
