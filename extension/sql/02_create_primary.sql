
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
role_level INTEGER,
    twitter TEXT,
    token_expiry TIMESTAMP,
    email TEXT,
    description TEXT,
    last_session_at TIMESTAMP,
    last_ai_response TEXT,
    email_subscription_active BOOLEAN,
    roles TEXT[],
    name TEXT,
    recent_threads JSON,
    token TEXT,
    metadata JSON,
    slack_id TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    interesting_entity_keys JSON,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    linkedin TEXT,
    graph_paths TEXT[],
    required_access_level INTEGER DEFAULT 1,
    groupid TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    session_id TEXT,
    groups TEXT[]
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
groupid TEXT,
    priority INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    collaborator_ids UUID[] NOT NULL,
    id UUID PRIMARY KEY ,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL,
    name TEXT,
    category TEXT,
    spec JSON NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    functions JSON,
    required_access_level INTEGER DEFAULT 100,
    metadata JSON
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
groupid TEXT,
    embedding_provider TEXT,
    field_type TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_key BOOLEAN,
    id UUID PRIMARY KEY ,
    entity_name TEXT NOT NULL,
    userid UUID,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    scheme TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    completions_uri TEXT NOT NULL,
    model TEXT,
    userid UUID,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    required_access_level INTEGER DEFAULT 100,
    token_env_key TEXT
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
endpoint TEXT,
    groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    verb TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    proxy_uri TEXT NOT NULL,
    description TEXT NOT NULL,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    key TEXT,
    required_access_level INTEGER DEFAULT 100,
    function_spec JSON NOT NULL
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
user_rating REAL,
    thread_id TEXT,
    channel_type TEXT,
    name TEXT,
    session_completed_at TIMESTAMP,
    metadata JSON,
    query TEXT,
    agent TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_type TEXT,
    graph_paths TEXT[],
    required_access_level INTEGER DEFAULT 1,
    groupid TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    channel_id TEXT,
    parent_session_id UUID
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
groupid TEXT,
    required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    rating REAL NOT NULL,
    comments TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL
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
tokens INTEGER,
    tool_calls JSON,
    tokens_in INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    tokens_out INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    role TEXT NOT NULL,
    tool_eval_data JSON,
    required_access_level INTEGER DEFAULT 1,
    groupid TEXT,
    function_stack TEXT[],
    model_name TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    tokens_other INTEGER,
    session_id UUID,
    content TEXT NOT NULL,
    verbatim JSON
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
groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    proxy_uri TEXT NOT NULL,
    userid UUID,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    required_access_level INTEGER DEFAULT 100
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
extra_arguments JSON,
    groupid TEXT,
    questions TEXT[],
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    plan_description TEXT NOT NULL,
    functions JSON,
    depends JSON,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    value TEXT NOT NULL
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
groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    summary TEXT,
    userid UUID,
    name TEXT,
    category TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL,
    content TEXT NOT NULL,
    graph_paths TEXT[],
    resource_timestamp TIMESTAMP,
    uri TEXT NOT NULL,
    required_access_level INTEGER DEFAULT 100,
    metadata JSON
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
tokens INTEGER,
    groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL,
    model_name TEXT NOT NULL,
    tokens_in INTEGER,
    id UUID PRIMARY KEY ,
    metrics JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_out INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_other INTEGER,
    userid UUID,
    session_id UUID,
    entity_full_name TEXT NOT NULL,
    message TEXT,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    priority INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    project_name TEXT,
    estimated_effort REAL,
    collaborator_ids UUID[] NOT NULL,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    name TEXT,
    progress REAL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    required_access_level INTEGER DEFAULT 100,
    relevance_score REAL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    user_metadata JSON,
    resource_id UUID NOT NULL,
    session_id UUID NOT NULL
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
groupid TEXT,
    question_set JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    iteration INTEGER NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    task_id UUID,
    required_access_level INTEGER DEFAULT 100,
    content TEXT,
    conceptual_diagram TEXT
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
groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    summary TEXT,
    userid UUID,
    name TEXT,
    category TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL,
    content TEXT NOT NULL,
    graph_paths TEXT[],
    resource_timestamp TIMESTAMP,
    uri TEXT NOT NULL,
    required_access_level INTEGER DEFAULT 100,
    metadata JSON
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
groupid TEXT,
    required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    count INTEGER,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_id UUID NOT NULL,
    session_id UUID NOT NULL
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
schedule TEXT NOT NULL,
    groupid TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    spec JSON NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    disabled_at TIMESTAMP,
    required_access_level INTEGER DEFAULT 100
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
groupid TEXT,
    required_access_level INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status_payload JSON,
    status TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    caller TEXT NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    error_trace TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- Apply row-level security policy
SELECT p8.attach_rls_policy('p8', 'Audit');
            
-- ------------------
