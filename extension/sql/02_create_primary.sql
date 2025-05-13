
-- register entity (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."User" (
recent_threads JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    linkedin TEXT,
    graph_paths TEXT[],
    slack_id TEXT,
    roles TEXT[],
    userid UUID,
    last_ai_response TEXT,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT,
    interesting_entity_keys JSON,
    email_subscription_active BOOLEAN,
    twitter TEXT,
    email TEXT,
    token TEXT,
    name TEXT
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
    target_date TIMESTAMP,
    status TEXT,
    collaborator_ids UUID[] NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT NOT NULL,
    priority INTEGER,
    name TEXT
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
    spec JSON NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    functions JSON,
    category TEXT,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT NOT NULL,
    name TEXT
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
entity_name TEXT NOT NULL,
    field_type TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    is_key BOOLEAN,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    embedding_provider TEXT,
    description TEXT,
    name TEXT
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
id UUID PRIMARY KEY ,
    completions_uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    model TEXT,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    token_env_key TEXT,
    token TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    scheme TEXT,
    name TEXT
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
id UUID PRIMARY KEY ,
    function_spec JSON NOT NULL,
    proxy_uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    endpoint TEXT,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    verb TEXT,
    key TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT NOT NULL,
    name TEXT
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
id UUID PRIMARY KEY ,
    query TEXT,
    session_type TEXT,
    graph_paths TEXT[],
    user_rating REAL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metadata JSON,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    channel_type TEXT,
    thread_id TEXT,
    parent_session_id UUID,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_completed_at TIMESTAMP,
    channel_id TEXT,
    agent TEXT NOT NULL,
    name TEXT
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
id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    rating REAL NOT NULL,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    comments TEXT
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
id UUID PRIMARY KEY ,
    tokens_other INTEGER,
    tokens_in INTEGER,
    role TEXT NOT NULL,
    status TEXT,
    verbatim JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tool_calls JSON,
    model_name TEXT NOT NULL,
    content TEXT NOT NULL,
    tokens_out INTEGER,
    session_id UUID,
    tool_eval_data JSON,
    function_stack TEXT[],
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
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
id UUID PRIMARY KEY ,
    proxy_uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
            
-- ------------------

-- register entity (p8.PlanModel)------
-- ------------------
CREATE TABLE  IF NOT EXISTS  p8."PlanModel" (
id UUID PRIMARY KEY ,
    questions TEXT[],
    extra_arguments JSON,
    depends JSON,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    functions JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    plan_description TEXT NOT NULL,
    userid TEXT,
    name TEXT
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
id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    value TEXT NOT NULL,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    key TEXT,
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
id UUID PRIMARY KEY ,
    graph_paths TEXT[],
    uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    category TEXT,
    summary TEXT,
    content TEXT NOT NULL,
    metadata JSON,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL,
    name TEXT
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
id UUID PRIMARY KEY ,
    tokens_other INTEGER,
    tokens_in INTEGER,
    entity_full_name TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    metrics JSON,
    model_name TEXT NOT NULL,
    userid UUID,
    tokens_out INTEGER,
    session_id UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    tokens INTEGER,
    status TEXT NOT NULL,
    message TEXT
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
estimated_effort REAL,
    id UUID PRIMARY KEY ,
    target_date TIMESTAMP,
    status TEXT,
    collaborator_ids UUID[] NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    project_name TEXT,
    userid UUID,
    progress REAL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    description TEXT NOT NULL,
    priority INTEGER,
    name TEXT
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
user_metadata JSON,
    id UUID PRIMARY KEY ,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    relevance_score REAL,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
id UUID PRIMARY KEY ,
    content TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    iteration INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    conceptual_diagram TEXT,
    question_set JSON NOT NULL,
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
    graph_paths TEXT[],
    uri TEXT NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    category TEXT,
    summary TEXT,
    content TEXT NOT NULL,
    metadata JSON,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    resource_timestamp TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ordinal INTEGER NOT NULL,
    name TEXT
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
    count INTEGER,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    session_id UUID NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
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
id UUID PRIMARY KEY ,
    spec JSON NOT NULL,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    schedule TEXT NOT NULL,
    userid UUID,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    disabled_at TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    name TEXT
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
id UUID PRIMARY KEY ,
    status_payload JSON,
    error_trace TEXT,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID,
    caller TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    status TEXT NOT NULL
);
DROP TRIGGER IF EXISTS update_updated_at_trigger ON p8."Audit";
CREATE   TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Audit"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
