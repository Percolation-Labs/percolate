
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
slack_id TEXT,
    token_expiry TIMESTAMP,
    description TEXT,
    token TEXT,
    twitter TEXT,
    email_subscription_active BOOLEAN,
    userid UUID,
    id UUID PRIMARY KEY ,
    last_session_at TIMESTAMP,
    session_id TEXT,
    graph_paths TEXT[],
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    roles TEXT[],
    interesting_entity_keys JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    linkedin TEXT,
    email TEXT,
    last_ai_response TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    name TEXT,
    recent_threads JSON
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    collaborator_ids UUID[] NOT NULL,
    name TEXT,
    target_date TIMESTAMP,
    priority INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    status TEXT,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    category TEXT,
    functions JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    embedding_provider TEXT,
    name TEXT,
    description TEXT,
    entity_name TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    id UUID PRIMARY KEY ,
    field_type TEXT NOT NULL,
    is_key BOOLEAN,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    model TEXT,
    name TEXT,
    token TEXT,
    token_env_key TEXT,
    scheme TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    completions_uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    name TEXT,
    function_spec JSON NOT NULL,
    proxy_uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    endpoint TEXT,
    verb TEXT,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    name TEXT,
    agent TEXT NOT NULL,
    parent_session_id UUID,
    query TEXT,
    thread_id TEXT,
    graph_paths TEXT[],
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_completed_at TIMESTAMP,
    session_type TEXT,
    user_rating REAL,
    id UUID PRIMARY KEY ,
    channel_type TEXT,
    channel_id TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    comments TEXT,
    userid UUID,
    rating REAL NOT NULL,
    id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID,
    content TEXT NOT NULL,
    tokens INTEGER,
    tokens_other INTEGER,
    tool_calls JSON,
    tokens_out INTEGER,
    model_name TEXT NOT NULL,
    function_stack TEXT[],
    verbatim JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    role TEXT NOT NULL,
    tool_eval_data JSON,
    status TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_in INTEGER
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    token TEXT,
    proxy_uri TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    id UUID PRIMARY KEY ,
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
depends JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    extra_arguments JSON,
    plan_description TEXT NOT NULL,
    functions JSON,
    userid TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    questions TEXT[],
    id UUID PRIMARY KEY ,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    value TEXT NOT NULL,
    id UUID PRIMARY KEY ,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    summary TEXT,
    content TEXT NOT NULL,
    resource_timestamp TIMESTAMP,
    name TEXT,
    category TEXT,
    graph_paths TEXT[],
    ordinal INTEGER NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metrics JSON,
    session_id UUID,
    tokens INTEGER,
    tokens_other INTEGER,
    tokens_out INTEGER,
    model_name TEXT NOT NULL,
    status TEXT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    entity_full_name TEXT NOT NULL,
    userid UUID,
    message TEXT,
    id UUID PRIMARY KEY ,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_in INTEGER
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    collaborator_ids UUID[] NOT NULL,
    name TEXT,
    target_date TIMESTAMP,
    estimated_effort REAL,
    priority INTEGER,
    progress REAL,
    project_name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    status TEXT,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    relevance_score REAL,
    user_metadata JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    resource_id UUID NOT NULL,
    id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    question_set JSON NOT NULL,
    task_id UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    conceptual_diagram TEXT,
    content TEXT,
    userid UUID,
    id UUID PRIMARY KEY ,
    iteration INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    summary TEXT,
    content TEXT NOT NULL,
    resource_timestamp TIMESTAMP,
    name TEXT,
    category TEXT,
    graph_paths TEXT[],
    ordinal INTEGER NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    count INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    resource_id UUID NOT NULL,
    id UUID PRIMARY KEY ,
    session_id UUID NOT NULL,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT,
    disabled_at TIMESTAMP,
    schedule TEXT NOT NULL,
    userid UUID,
    spec JSON NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
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
deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    status TEXT NOT NULL,
    error_trace TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status_payload JSON,
    caller TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
