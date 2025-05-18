
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
name TEXT,
    interesting_entity_keys JSON,
    roles TEXT[],
    last_session_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    linkedin TEXT,
    slack_id TEXT,
    email TEXT,
    email_subscription_active BOOLEAN,
    graph_paths TEXT[],
    last_ai_response TEXT,
    twitter TEXT,
    description TEXT,
    id UUID PRIMARY KEY ,
    userid UUID,
    recent_threads JSON,
    token TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token_expiry TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id TEXT,
    metadata JSON
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."User";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."User"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'User');
            
-- ------------------

-- register entity (p8.Project)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Project" (
id UUID PRIMARY KEY ,
    userid UUID,
    collaborator_ids UUID[] NOT NULL,
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    status TEXT,
    priority INTEGER
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Project";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Project"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Project');
            
-- ------------------

-- register entity (p8.Agent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Agent" (
id UUID PRIMARY KEY ,
    category TEXT,
    userid UUID,
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT NOT NULL,
    functions JSON
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Agent";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Agent"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Agent');
            
-- ------------------

-- register entity (p8.ModelField)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ModelField" (
id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    field_type TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    embedding_provider TEXT,
    entity_name TEXT NOT NULL,
    is_key BOOLEAN
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ModelField";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ModelField"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ModelField');
            
-- ------------------

-- register entity (p8.LanguageModelApi)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."LanguageModelApi" (
model TEXT,
    id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    token TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    scheme TEXT,
    completions_uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token_env_key TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."LanguageModelApi";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."LanguageModelApi"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'LanguageModelApi');
            
-- ------------------

-- register entity (p8.Function)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Function" (
key TEXT,
    function_spec JSON NOT NULL,
    id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    description TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    endpoint TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    proxy_uri TEXT NOT NULL,
    verb TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Function";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Function"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Function');
            
-- ------------------

-- register entity (p8.Session)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Session" (
channel_id TEXT,
    agent TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    query TEXT,
    parent_session_id UUID,
    graph_paths TEXT[],
    userid UUID,
    name TEXT,
    channel_type TEXT,
    user_rating REAL,
    thread_id TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_completed_at TIMESTAMP,
    session_type TEXT
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Session";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Session"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Session');
            
-- ------------------

-- register entity (p8.SessionEvaluation)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."SessionEvaluation" (
comments TEXT,
    id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
    userid UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    rating REAL NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."SessionEvaluation";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."SessionEvaluation"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.AIResponse)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."AIResponse" (
model_name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    tool_calls JSON,
    tool_eval_data JSON,
    userid UUID,
    tokens INTEGER,
    tokens_other INTEGER,
    session_id UUID,
    tokens_out INTEGER,
    tokens_in INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    function_stack TEXT[],
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    content TEXT NOT NULL,
    verbatim JSON,
    status TEXT,
    role TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."AIResponse";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."AIResponse"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'AIResponse');
            
-- ------------------

-- register entity (p8.ApiProxy)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ApiProxy" (
id UUID PRIMARY KEY ,
    userid UUID,
    name TEXT,
    token TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    proxy_uri TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ApiProxy";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ApiProxy"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ApiProxy');
            
-- ------------------

-- register entity (p8.PlanModel)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."PlanModel" (
extra_arguments JSON,
    id UUID PRIMARY KEY ,
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    plan_description TEXT NOT NULL,
    questions TEXT[],
    depends JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid TEXT,
    functions JSON
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."PlanModel";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."PlanModel"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'PlanModel');
            
-- ------------------

-- register entity (p8.Settings)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Settings" (
key TEXT,
    id UUID PRIMARY KEY ,
    userid UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    value TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Settings";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Settings"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.PercolateAgent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."PercolateAgent" (
id UUID PRIMARY KEY ,
    category TEXT,
    ordinal INTEGER NOT NULL,
    graph_paths TEXT[],
    userid UUID,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    summary TEXT,
    content TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."PercolateAgent";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."PercolateAgent"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'PercolateAgent');
            
-- ------------------

-- register entity (p8.IndexAudit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."IndexAudit" (
model_name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    status TEXT NOT NULL,
    message TEXT,
    userid UUID,
    tokens INTEGER,
    tokens_other INTEGER,
    session_id UUID,
    tokens_out INTEGER,
    entity_full_name TEXT NOT NULL,
    tokens_in INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metrics JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."IndexAudit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."IndexAudit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Task)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Task" (
progress REAL,
    id UUID PRIMARY KEY ,
    userid UUID,
    collaborator_ids UUID[] NOT NULL,
    estimated_effort REAL,
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    project_name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    status TEXT,
    priority INTEGER
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Task";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Task"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Task');
            
-- ------------------

-- register entity (p8.TaskResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."TaskResources" (
relevance_score REAL,
    id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
    userid UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    user_metadata JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_id UUID NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."TaskResources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."TaskResources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.ResearchIteration)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."ResearchIteration" (
content TEXT,
    iteration INTEGER NOT NULL,
    id UUID PRIMARY KEY ,
    conceptual_diagram TEXT,
    userid UUID,
    question_set JSON NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    task_id UUID
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."ResearchIteration";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ResearchIteration"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'ResearchIteration');
            
-- ------------------

-- register entity (p8.Resources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Resources" (
id UUID PRIMARY KEY ,
    category TEXT,
    ordinal INTEGER NOT NULL,
    graph_paths TEXT[],
    userid UUID,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    summary TEXT,
    content TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Resources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Resources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Resources');
            
-- ------------------

-- register entity (p8.SessionResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."SessionResources" (
id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
    userid UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    count INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_id UUID NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."SessionResources";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."SessionResources"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Schedule)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Schedule" (
userid UUID,
    id UUID PRIMARY KEY ,
    schedule TEXT NOT NULL,
    name TEXT,
    disabled_at TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Schedule";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Schedule"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
SELECT attach_notify_trigger_to_table('p8', 'Schedule');
            
-- ------------------

-- register entity (p8.Audit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."Audit" (
userid UUID,
    status TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    error_trace TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    caller TEXT NOT NULL,
    status_payload JSON
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
