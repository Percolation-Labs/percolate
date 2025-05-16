
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
session_id TEXT,
    description TEXT,
    email TEXT,
    name TEXT,
    slack_id TEXT,
    linkedin TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    recent_threads JSON,
    token_expiry TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    email_subscription_active BOOLEAN,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    interesting_entity_keys JSON,
    token TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    twitter TEXT,
    roles TEXT[],
    graph_paths TEXT[],
    last_session_at TIMESTAMP,
    last_ai_response TEXT
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
collaborator_ids UUID[] NOT NULL,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    name TEXT,
    priority INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
description TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    category TEXT,
    id UUID PRIMARY KEY ,
    functions JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL
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
embedding_provider TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_key BOOLEAN,
    field_type TEXT NOT NULL,
    userid UUID,
    id UUID PRIMARY KEY ,
    description TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    entity_name TEXT NOT NULL
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
scheme TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    model TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completions_uri TEXT NOT NULL,
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
endpoint TEXT,
    description TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    userid UUID,
    verb TEXT,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    function_spec JSON NOT NULL,
    name TEXT,
    proxy_uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
session_completed_at TIMESTAMP,
    thread_id TEXT,
    query TEXT,
    agent TEXT NOT NULL,
    metadata JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    channel_id TEXT,
    id UUID PRIMARY KEY ,
    graph_paths TEXT[],
    user_rating REAL,
    channel_type TEXT,
    session_type TEXT,
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    parent_session_id UUID
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL,
    userid UUID,
    rating REAL NOT NULL,
    id UUID PRIMARY KEY ,
    comments TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
tool_eval_data JSON,
    model_name TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_other INTEGER,
    function_stack TEXT[],
    tokens_out INTEGER,
    tokens_in INTEGER,
    session_id UUID,
    role TEXT NOT NULL,
    tokens INTEGER,
    id UUID PRIMARY KEY ,
    content TEXT NOT NULL,
    verbatim JSON,
    userid UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    tool_calls JSON
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    proxy_uri TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
    depends JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid TEXT,
    id UUID PRIMARY KEY ,
    plan_description TEXT NOT NULL,
    functions JSON,
    questions TEXT[],
    name TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    value TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    content TEXT NOT NULL,
    userid UUID,
    category TEXT,
    id UUID PRIMARY KEY ,
    resource_timestamp TIMESTAMP,
    summary TEXT,
    graph_paths TEXT[],
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL
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
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_other INTEGER,
    tokens_out INTEGER,
    tokens_in INTEGER,
    session_id UUID,
    message TEXT,
    tokens INTEGER,
    id UUID PRIMARY KEY ,
    userid UUID,
    entity_full_name TEXT NOT NULL,
    metrics JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL
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
collaborator_ids UUID[] NOT NULL,
    target_date TIMESTAMP,
    description TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    project_name TEXT,
    id UUID PRIMARY KEY ,
    progress REAL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT,
    name TEXT,
    priority INTEGER,
    estimated_effort REAL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL,
    relevance_score REAL,
    userid UUID,
    id UUID PRIMARY KEY ,
    user_metadata JSON,
    resource_id UUID NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
    conceptual_diagram TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    id UUID PRIMARY KEY ,
    task_id UUID,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    question_set JSON NOT NULL
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    content TEXT NOT NULL,
    userid UUID,
    category TEXT,
    id UUID PRIMARY KEY ,
    resource_timestamp TIMESTAMP,
    summary TEXT,
    graph_paths TEXT[],
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL,
    userid UUID,
    id UUID PRIMARY KEY ,
    resource_id UUID NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    count INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    schedule TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    disabled_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL
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
caller TEXT NOT NULL,
    error_trace TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status_payload JSON,
    userid UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
