
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
session_id TEXT,
    token_expiry TIMESTAMP,
    interesting_entity_keys JSON,
    email_subscription_active BOOLEAN,
    last_session_at TIMESTAMP,
    userid UUID,
    last_ai_response TEXT,
    required_access_level INTEGER DEFAULT 1,
    name TEXT,
    twitter TEXT,
    linkedin TEXT,
    role_level INTEGER,
    email TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    recent_threads JSON,
    groups TEXT[],
    metadata JSON,
    slack_id TEXT,
    roles TEXT[],
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT,
    groupid TEXT,
    graph_paths TEXT[],
    token TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."User";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."User"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'User');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'User');
            
-- ------------------

-- register entity (p8.Project)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Project" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    id UUID PRIMARY KEY ,
    collaborator_ids UUID[] NOT NULL,
    priority INTEGER,
    description TEXT NOT NULL,
    groupid TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Project";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Project"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Project');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Project');
            
-- ------------------

-- register entity (p8.Agent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Agent" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL,
    groupid TEXT,
    spec JSON NOT NULL,
    userid UUID,
    functions JSON,
    category TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Agent";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Agent"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Agent');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Agent');
            
-- ------------------

-- register entity (p8.ModelField)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ModelField" (
required_access_level INTEGER DEFAULT 100,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_key BOOLEAN,
    id UUID PRIMARY KEY ,
    embedding_provider TEXT,
    field_type TEXT NOT NULL,
    groupid TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    entity_name TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ModelField";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ModelField"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ModelField');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'ModelField');
            
-- ------------------

-- register entity (p8.LanguageModelApi)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."LanguageModelApi" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    model TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    scheme TEXT,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    completions_uri TEXT NOT NULL,
    userid UUID,
    token TEXT,
    token_env_key TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."LanguageModelApi";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."LanguageModelApi"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'LanguageModelApi');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'LanguageModelApi');
            
-- ------------------

-- register entity (p8.Function)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Function" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    function_spec JSON NOT NULL,
    key TEXT,
    verb TEXT,
    description TEXT NOT NULL,
    groupid TEXT,
    userid UUID,
    proxy_uri TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    endpoint TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Function";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Function"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Function');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Function');
            
-- ------------------

-- register entity (p8.Session)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Session" (
agent TEXT NOT NULL,
    query TEXT,
    thread_id TEXT,
    session_type TEXT,
    userid UUID,
    channel_type TEXT,
    required_access_level INTEGER DEFAULT 1,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    channel_id TEXT,
    metadata JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    groupid TEXT,
    parent_session_id UUID,
    graph_paths TEXT[],
    user_rating REAL,
    session_completed_at TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Session";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Session"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Session');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Session');
            
-- ------------------

-- register entity (p8.SessionEvaluation)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."SessionEvaluation" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    userid UUID,
    rating REAL NOT NULL,
    comments TEXT,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."SessionEvaluation";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."SessionEvaluation"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'SessionEvaluation');
            
-- ------------------

-- register entity (p8.AIResponse)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."AIResponse" (
tokens_in INTEGER,
    role TEXT NOT NULL,
    tokens INTEGER,
    userid UUID,
    required_access_level INTEGER DEFAULT 1,
    tool_eval_data JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_other INTEGER,
    status TEXT,
    id UUID PRIMARY KEY ,
    session_id UUID,
    tokens_out INTEGER,
    tool_calls JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    verbatim JSON,
    content TEXT NOT NULL,
    function_stack TEXT[],
    groupid TEXT,
    model_name TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."AIResponse";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."AIResponse"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'AIResponse');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'AIResponse');
            
-- ------------------

-- register entity (p8.ApiProxy)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ApiProxy" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    userid UUID,
    proxy_uri TEXT NOT NULL,
    token TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ApiProxy";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ApiProxy"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ApiProxy');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'ApiProxy');
            
-- ------------------

-- register entity (p8.PlanModel)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."PlanModel" (
required_access_level INTEGER DEFAULT 100,
    extra_arguments JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    plan_description TEXT NOT NULL,
    questions TEXT[],
    userid TEXT,
    functions JSON,
    depends JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."PlanModel";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."PlanModel"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'PlanModel');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'PlanModel');
            
-- ------------------

-- register entity (p8.Settings)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Settings" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    key TEXT,
    groupid TEXT,
    userid UUID,
    value TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Settings";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Settings"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Settings');
            
-- ------------------

-- register entity (p8.PercolateAgent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."PercolateAgent" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    content TEXT NOT NULL,
    resource_timestamp TIMESTAMP,
    metadata JSON,
    graph_paths TEXT[],
    ordinal INTEGER NOT NULL,
    userid UUID,
    groupid TEXT,
    category TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    summary TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."PercolateAgent";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."PercolateAgent"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'PercolateAgent');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'PercolateAgent');
            
-- ------------------

-- register entity (p8.IndexAudit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."IndexAudit" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_other INTEGER,
    metrics JSON,
    id UUID PRIMARY KEY ,
    status TEXT NOT NULL,
    message TEXT,
    entity_full_name TEXT NOT NULL,
    groupid TEXT,
    session_id UUID,
    userid UUID,
    model_name TEXT NOT NULL,
    tokens_in INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_out INTEGER,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens INTEGER
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."IndexAudit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."IndexAudit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'IndexAudit');
            
-- ------------------

-- register entity (p8.Task)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Task" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    id UUID PRIMARY KEY ,
    collaborator_ids UUID[] NOT NULL,
    priority INTEGER,
    description TEXT NOT NULL,
    groupid TEXT,
    userid UUID,
    estimated_effort REAL,
    progress REAL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    project_name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Task";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Task"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Task');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Task');
            
-- ------------------

-- register entity (p8.TaskResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."TaskResources" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_id UUID NOT NULL,
    relevance_score REAL,
    id UUID PRIMARY KEY ,
    user_metadata JSON,
    groupid TEXT,
    userid UUID,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."TaskResources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."TaskResources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'TaskResources');
            
-- ------------------

-- register entity (p8.ResearchIteration)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ResearchIteration" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    task_id UUID,
    id UUID PRIMARY KEY ,
    question_set JSON NOT NULL,
    groupid TEXT,
    userid UUID,
    content TEXT,
    conceptual_diagram TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    iteration INTEGER NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ResearchIteration";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ResearchIteration"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ResearchIteration');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'ResearchIteration');
            
-- ------------------

-- register entity (p8.Resources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Resources" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    content TEXT NOT NULL,
    resource_timestamp TIMESTAMP,
    metadata JSON,
    graph_paths TEXT[],
    ordinal INTEGER NOT NULL,
    userid UUID,
    groupid TEXT,
    category TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    summary TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Resources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Resources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Resources');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Resources');
            
-- ------------------

-- register entity (p8.SessionResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."SessionResources" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_id UUID NOT NULL,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    count INTEGER,
    userid UUID,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."SessionResources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."SessionResources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'SessionResources');
            
-- ------------------

-- register entity (p8.Schedule)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Schedule" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    schedule TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    groupid TEXT,
    spec JSON NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    disabled_at TIMESTAMP,
    name TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Schedule";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Schedule"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Schedule');
            
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Schedule');
            
-- ------------------

-- register entity (p8.Audit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Audit" (
required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    caller TEXT NOT NULL,
    groupid TEXT,
    userid UUID,
    error_trace TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status_payload JSON,
    status TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Audit');
            
-- ------------------
