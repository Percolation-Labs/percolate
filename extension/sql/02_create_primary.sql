
-- register entity (p8.Project)------
-- ------------------
CREATE TABLE p8."Project" (
name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    description TEXT NOT NULL,
    target_date TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Project"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Agent)------
-- ------------------
CREATE TABLE p8."Agent" (
name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    category TEXT,
    description TEXT NOT NULL,
    spec JSON NOT NULL,
    functions JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Agent"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.ModelField)------
-- ------------------
CREATE TABLE p8."ModelField" (
name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    entity_name TEXT NOT NULL,
    field_type TEXT NOT NULL,
    embedding_provider TEXT,
    description TEXT,
    is_key BOOLEAN,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."ModelField"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.LanguageModelApi)------
-- ------------------
CREATE TABLE p8."LanguageModelApi" (
name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    model TEXT,
    scheme TEXT,
    completions_uri TEXT NOT NULL,
    token_env_key TEXT,
    token TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."LanguageModelApi"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Function)------
-- ------------------
CREATE TABLE p8."Function" (
name TEXT NOT NULL,
    id UUID PRIMARY KEY ,
    key TEXT,
    verb TEXT,
    endpoint TEXT,
    description TEXT NOT NULL,
    function_spec JSON NOT NULL,
    proxy_uri TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Function"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Session)------
-- ------------------
CREATE TABLE p8."Session" (
id UUID PRIMARY KEY ,
    query TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Session"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------

-- register entity (p8.Dialogue)------
-- ------------------
CREATE TABLE p8."Dialogue" (
id UUID PRIMARY KEY ,
    model_name TEXT NOT NULL,
    tokens INTEGER NOT NULL,
    tokens_in INTEGER,
    tokens_out INTEGER,
    tokens_other INTEGER,
    session_id UUID,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    status TEXT,
    tool_calls JSON,
    tool_eval_data JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    userid UUID
);

CREATE TRIGGER update_updated_at_trigger
BEFORE UPDATE ON p8."Dialogue"
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

        
-- ------------------
