
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
graph_paths TEXT[],
    twitter TEXT,
    last_session_at TIMESTAMP,
    email_subscription_active BOOLEAN,
    id UUID PRIMARY KEY ,
    session_id TEXT,
    interesting_entity_keys JSON,
    slack_id TEXT,
    token TEXT,
    recent_threads JSON,
    token_expiry TIMESTAMP,
    userid UUID,
    linkedin TEXT,
    last_ai_response TEXT,
    name TEXT,
    email TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    description TEXT,
    roles TEXT[]
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
name TEXT,
    description TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    target_date TIMESTAMP,
    userid UUID,
    status TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    priority INTEGER,
    collaborator_ids UUID[] NOT NULL
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
category TEXT,
    name TEXT,
    description TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    functions JSON,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    embedding_provider TEXT,
    is_key BOOLEAN,
    userid UUID,
    description TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    entity_name TEXT NOT NULL,
    field_type TEXT NOT NULL
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
    model TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token_env_key TEXT,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completions_uri TEXT NOT NULL
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
proxy_uri TEXT NOT NULL,
    name TEXT,
    description TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    function_spec JSON NOT NULL,
    endpoint TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
    name TEXT,
    agent TEXT NOT NULL,
    thread_id TEXT,
    session_completed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    graph_paths TEXT[],
    channel_type TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    session_type TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    query TEXT,
    parent_session_id UUID,
    user_rating REAL
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
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    rating REAL NOT NULL,
    comments TEXT,
    session_id UUID NOT NULL
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
    session_id UUID,
    role TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    function_stack TEXT[],
    verbatim JSON,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_out INTEGER,
    userid UUID,
    tokens_other INTEGER,
    status TEXT,
    tool_calls JSON,
    tool_eval_data JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_in INTEGER,
    content TEXT NOT NULL,
    tokens INTEGER
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
proxy_uri TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
questions TEXT[],
    plan_description TEXT NOT NULL,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    functions JSON,
    id UUID PRIMARY KEY ,
    depends JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid TEXT,
    extra_arguments JSON
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
value TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
    userid UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
ordinal INTEGER NOT NULL,
    category TEXT,
    summary TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    graph_paths TEXT[],
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    userid UUID,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
entity_full_name TEXT NOT NULL,
    model_name TEXT NOT NULL,
    session_id UUID,
    message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_out INTEGER,
    status TEXT NOT NULL,
    metrics JSON,
    userid UUID,
    tokens_other INTEGER,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens_in INTEGER,
    tokens INTEGER
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
name TEXT,
    description TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    progress REAL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    project_name TEXT,
    target_date TIMESTAMP,
    userid UUID,
    status TEXT,
    estimated_effort REAL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    priority INTEGER,
    collaborator_ids UUID[] NOT NULL
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
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    user_metadata JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    relevance_score REAL,
    userid UUID,
    resource_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL
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
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    task_id UUID,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    iteration INTEGER NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    question_set JSON NOT NULL,
    conceptual_diagram TEXT,
    content TEXT
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
ordinal INTEGER NOT NULL,
    category TEXT,
    summary TEXT,
    name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    uri TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    graph_paths TEXT[],
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    userid UUID,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    resource_id UUID NOT NULL,
    count INTEGER,
    session_id UUID NOT NULL
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
name TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    schedule TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    spec JSON NOT NULL,
    userid UUID,
    disabled_at TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    error_trace TEXT,
    userid UUID,
    caller TEXT NOT NULL,
    status_payload JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
