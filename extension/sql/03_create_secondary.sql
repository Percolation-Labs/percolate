
-- register_embeddings (p8.Project)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Project_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_project
        FOREIGN KEY (source_record_id) REFERENCES p8."Project"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Project)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', '62a171bf-f6f0-963c-64f7-23353f237304', 'p8.Project', 'str', NULL, 'The name of the entity e.g. a model in the types or a user defined model', NULL),
 ('id', 'dfe5817d-6e11-e3e6-4a34-ce9b1e2983a1', 'p8.Project', 'uuid.UUID | str', NULL, NULL, NULL),
 ('description', '10c00232-88b5-b029-60d8-7b5314b80065', 'p8.Project', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', NULL),
 ('target_date', '54804545-d390-5f2d-edba-83a8649b1f19', 'p8.Project', 'datetime', NULL, 'Optional target date', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.Project)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Project', '3d291419-02cd-58b4-a96e-76aadee594c3', NULL, 'A project is a broadly defined goal with related resources (uses the graph)', '{"description": "A project is a broadly defined goal with related resources (uses the graph)", "properties": {"name": {"description": "The name of the entity e.g. a model in the types or a user defined model", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "description": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Description", "type": "string"}, "target_date": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Optional target date", "title": "Target Date"}}, "required": ["name", "id", "description"], "title": "Project", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.Project)------
-- ------------------
select * from p8.register_entities('p8.Project');
-- ------------------

-- register_embeddings (p8.Agent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Agent_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_agent
        FOREIGN KEY (source_record_id) REFERENCES p8."Agent"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Agent)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', 'e11f251e-8da1-f9df-06ee-2febcb5190f3', 'p8.Agent', 'str', NULL, NULL, NULL),
 ('id', 'aa6cb74c-ef56-96d5-db17-b019bd69eadc', 'p8.Agent', 'uuid.UUID | str', NULL, NULL, NULL),
 ('category', 'd6fc8fdb-3db2-c5a8-db21-ac8f296065f8', 'p8.Agent', 'str', NULL, 'Simple property to filter agents by categories', NULL),
 ('description', '4d70cc01-bff8-cafe-13d3-79ac9f63b1e5', 'p8.Agent', 'str', 'text-embedding-ada-002', 'The system prompt as markdown', NULL),
 ('spec', 'a15c5b3b-7f84-0b80-100f-b489516944f1', 'p8.Agent', 'dict', NULL, 'The model json schema', NULL),
 ('functions', 'e664cb9d-cbfb-6196-73e8-140930264434', 'p8.Agent', 'dict', NULL, 'The function that agent can call', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.Agent)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Agent', '96d1a2ff-045b-55cc-a7de-543d1d3cccf8', NULL, 'The agent model is a meta data object to persist agent metadata for search etc', '{"description": "The agent model is a meta data object to persist agent metadata for search etc", "properties": {"name": {"title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Simple property to filter agents by categories", "title": "Category"}, "description": {"description": "The system prompt as markdown", "embedding_provider": "default", "title": "Description", "type": "string"}, "spec": {"description": "The model json schema", "title": "Spec", "type": "object"}, "functions": {"anyOf": [{"type": "object"}, {"type": "null"}], "description": "The function that agent can call", "title": "Functions"}}, "required": ["name", "id", "description", "spec"], "title": "Agent", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.Agent)------
-- ------------------
select * from p8.register_entities('p8.Agent');
-- ------------------

-- register_embeddings (p8.ModelField)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_ModelField_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_modelfield
        FOREIGN KEY (source_record_id) REFERENCES p8."ModelField"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.ModelField)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', '42b9d359-975d-af7f-ee7b-9e59ef1eaace', 'p8.ModelField', 'str', NULL, 'The field name', NULL),
 ('id', '36d8e543-b15b-c278-4277-bb91ace8073f', 'p8.ModelField', 'UUID', NULL, 'a unique key for the field e.g. field and entity key hashed', NULL),
 ('entity_name', '16bd1d11-281b-1c24-1f00-e7efdc832cee', 'p8.ModelField', 'str', NULL, NULL, NULL),
 ('field_type', '27803534-7efe-5294-e81b-b5c0e28fc7a5', 'p8.ModelField', 'str', NULL, NULL, NULL),
 ('embedding_provider', '801bd727-6b8e-60f0-3904-108b80ab0839', 'p8.ModelField', 'str', NULL, 'The embedding could be a multiple in future', NULL),
 ('description', 'e0135555-a675-92cd-687d-1f03f8b7c28a', 'p8.ModelField', 'str', NULL, NULL, NULL),
 ('is_key', '83940d96-c8da-6825-9fd6-9fff0eb58a24', 'p8.ModelField', 'bool', NULL, 'Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.ModelField)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.ModelField', 'ea1ce51b-2377-5f56-9a0e-963ef6116b05', NULL, 'Fields are each field in any saved model/agent. \n    Fields are useful for describing system info such as for embeddings or for promoting.\n    ', '{"description": "Fields are each field in any saved model/agent. \\nFields are useful for describing system info such as for embeddings or for promoting.", "properties": {"name": {"description": "The field name", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "description": "a unique key for the field e.g. field and entity key hashed", "title": "Id"}, "entity_name": {"title": "Entity Name", "type": "string"}, "field_type": {"title": "Field Type", "type": "string"}, "embedding_provider": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The embedding could be a multiple in future", "title": "Embedding Provider"}, "description": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Description"}, "is_key": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": false, "description": "Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings", "title": "Is Key"}}, "required": ["name", "id", "entity_name", "field_type"], "title": "ModelField", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.ModelField)------
-- ------------------
select * from p8.register_entities('p8.ModelField');
-- ------------------

-- register_embeddings (p8.LanguageModelApi)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_LanguageModelApi_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_languagemodelapi
        FOREIGN KEY (source_record_id) REFERENCES p8."LanguageModelApi"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.LanguageModelApi)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', 'a43ab935-2ede-88e3-4fcf-6b5b9be8e095', 'p8.LanguageModelApi', 'str', NULL, 'A unique name for the model api e.g cerebras-llama3.1-8b', NULL),
 ('id', '6f38ec59-8b59-6efa-b88b-1c7a1b654787', 'p8.LanguageModelApi', 'uuid.UUID | str', NULL, NULL, NULL),
 ('model', 'ed5d930c-a531-4cc5-5732-aca6344ce9f9', 'p8.LanguageModelApi', 'str', NULL, 'The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier', NULL),
 ('scheme', '193ef059-3117-8dca-0a4e-f2dc5d849587', 'p8.LanguageModelApi', 'str', NULL, 'In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ', NULL),
 ('completions_uri', '8ef8334e-d45f-3e7d-5c3f-bb75add8bbb1', 'p8.LanguageModelApi', 'str', NULL, 'The api used for completions in chat and function calling. There may be other uris for other contexts', NULL),
 ('token_env_key', 'b4dca876-7eee-fd69-10df-bdf3effdf1b0', 'p8.LanguageModelApi', 'str', NULL, 'Conventions are used to resolve keys from env or other services. Provide an alternative key', NULL),
 ('token', '5906dae1-3d9f-d08f-85ed-013f565d99b1', 'p8.LanguageModelApi', 'str', NULL, 'It is not recommended to add tokens directly to the data but for convenience you might want to', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.LanguageModelApi)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.LanguageModelApi', 'd0a0e81a-3525-5e52-afb3-c736103c42ab', NULL, 'The Language model REST Apis are stored with tokens and scheme information.\n    ', '{"description": "The Language model REST Apis are stored with tokens and scheme information.\\n    ", "properties": {"name": {"description": "A unique name for the model api e.g cerebras-llama3.1-8b", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier", "title": "Model"}, "scheme": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "openai", "description": "In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ", "title": "Scheme"}, "completions_uri": {"description": "The api used for completions in chat and function calling. There may be other uris for other contexts", "title": "Completions Uri", "type": "string"}, "token_env_key": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Conventions are used to resolve keys from env or other services. Provide an alternative key", "title": "Token Env Key"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "It is not recommended to add tokens directly to the data but for convenience you might want to", "title": "Token"}}, "required": ["name", "id", "completions_uri"], "title": "LanguageModelApi", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.LanguageModelApi)------
-- ------------------
select * from p8.register_entities('p8.LanguageModelApi');
-- ------------------

-- register_embeddings (p8.Function)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Function_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_function
        FOREIGN KEY (source_record_id) REFERENCES p8."Function"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Function)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', '34dcf34c-b385-0c19-f398-ff3b5dbcd3b1', 'p8.Function', 'str', NULL, 'A friendly name that is unique within the proxy scope e.g. a single api or python library', NULL),
 ('id', '9ab2626c-973d-996c-2e34-7e539cacec63', 'p8.Function', 'uuid.UUID | str', NULL, 'A unique id in this case generated by the proxy and function name', NULL),
 ('key', '154e802e-a795-2878-5cbc-56b315d7faf2', 'p8.Function', 'str', NULL, 'optional key e.g operation id', NULL),
 ('verb', '70c8ad39-ede9-d287-fc4c-94a9b195fc15', 'p8.Function', 'str', NULL, 'The verb e.g. get, post etc', NULL),
 ('endpoint', '16ab3e97-4d26-05ea-7369-2e29bf2acc53', 'p8.Function', 'str', NULL, 'A callable endpoint in the case of REST', NULL),
 ('description', 'e872491f-13d7-8754-fc1c-95d0cac14169', 'p8.Function', 'str', 'text-embedding-ada-002', 'A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable', NULL),
 ('function_spec', 'ef26856f-b727-bc2e-84cc-d62015a1fde7', 'p8.Function', 'dict', NULL, 'A function description that is OpenAI and based on the OpenAPI spec', NULL),
 ('proxy_uri', '9faddba7-2a4b-a536-28cb-ac3bd1b6df53', 'p8.Function', 'str', NULL, 'a reference to an api or library namespace that qualifies the named function', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.Function)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Function', '871c0a64-8a7b-5757-9fd0-f046a282656f', NULL, 'Functions are external tools that agents can use. See field comments for context.\n    Functions can be searched and used as LLM tools. \n    The function spec is derived from OpenAPI but adapted to the conventional used in LLMs\n    ', '{"description": "Functions are external tools that agents can use. See field comments for context.\\nFunctions can be searched and used as LLM tools. \\nThe function spec is derived from OpenAPI but adapted to the conventional used in LLMs", "properties": {"name": {"description": "A friendly name that is unique within the proxy scope e.g. a single api or python library", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "description": "A unique id in this case generated by the proxy and function name", "title": "Id"}, "key": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "optional key e.g operation id", "title": "Key"}, "verb": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The verb e.g. get, post etc", "title": "Verb"}, "endpoint": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A callable endpoint in the case of REST", "title": "Endpoint"}, "description": {"default": "", "description": "A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable", "embedding_provider": "default", "title": "Description", "type": "string"}, "function_spec": {"description": "A function description that is OpenAI and based on the OpenAPI spec", "title": "Function Spec", "type": "object"}, "proxy_uri": {"description": "a reference to an api or library namespace that qualifies the named function", "title": "Proxy Uri", "type": "string"}}, "required": ["name", "id", "key", "function_spec", "proxy_uri"], "title": "Function", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.Function)------
-- ------------------
select * from p8.register_entities('p8.Function');
-- ------------------

-- register_embeddings (p8.Session)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Session_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_session
        FOREIGN KEY (source_record_id) REFERENCES p8."Session"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Session)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', 'fb80623e-7d2d-4307-a912-6e476fa2a1e1', 'p8.Session', 'uuid.UUID | str', NULL, NULL, NULL),
 ('query', '5f781f67-29c1-c21c-2b4c-f891a1455bf4', 'p8.Session', 'str', NULL, 'the question or context that triggered the session', NULL),
 ('user_rating', '8a2e0ec5-e75a-522a-69a5-cfc8e2abfd7b', 'p8.Session', 'float', NULL, 'We can in future rate sessions to learn what works', NULL),
 ('agent', 'f50b93b2-78ab-1a84-9255-87d1b0470b02', 'p8.Session', 'str', NULL, NULL, NULL),
 ('parent_session_id', '15dc76f1-d9f2-da78-40e5-e5f2b27ecf4d', 'p8.Session', 'UUID', NULL, NULL, NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.Session)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Session', '1b116463-808f-5798-8809-8450045f0d53', NULL, 'Tracks groups if session dialogue', '{"description": "Tracks groups if session dialogue", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "query": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "the question or context that triggered the session", "title": "Query"}, "user_rating": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": null, "description": "We can in future rate sessions to learn what works", "title": "User Rating"}, "agent": {"default": "Percolate always expects an agent but we support passing a system prompt which we treat as anonymous agent", "title": "Agent", "type": "string"}, "parent_session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": "A session is a thread from a question+prompt to completion. We maw span child sessions", "title": "Parent Session Id"}}, "required": ["id"], "title": "Session", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_embeddings (p8.AIResponse)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_AIResponse_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_airesponse
        FOREIGN KEY (source_record_id) REFERENCES p8."AIResponse"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.AIResponse)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', '9a6c62f8-ec9f-b2a8-471e-293968cfc5ba', 'p8.AIResponse', 'uuid.UUID | str', NULL, NULL, NULL),
 ('model_name', '22bf53b3-4708-7eeb-fa11-a02d25eafc68', 'p8.AIResponse', 'str', NULL, NULL, NULL),
 ('tokens', '6e1f4c54-9874-ac54-8df0-15d8278d10c6', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed in total', NULL),
 ('tokens_in', '6533706a-7510-8bb6-d19c-04112530a006', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for input', NULL),
 ('tokens_out', '69d48123-4110-3677-c076-f95721671f4b', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for output', NULL),
 ('tokens_other', 'ff8dc4f2-24a7-b660-f7ac-726b8de21857', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for functions and other metadata', NULL),
 ('session_id', '2fbd5e8b-5e3f-59e2-a7f8-ccc25e969f00', 'p8.AIResponse', 'UUID', NULL, 'Session id for a conversation', NULL),
 ('role', 'd2564a0a-9cec-01c2-7928-4c03424e77ce', 'p8.AIResponse', 'str', NULL, 'The role of the user/agent in the conversation', NULL),
 ('content', '66f7279c-aebf-d75d-6938-699fc2a08074', 'p8.AIResponse', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', NULL),
 ('status', '7553391b-4325-699c-2ddc-75e62e0055b7', 'p8.AIResponse', 'str', NULL, 'The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM_RESPONSE', NULL),
 ('tool_calls', '616befa2-4a8f-a966-6980-5bf0275767c4', 'p8.AIResponse', 'dict', NULL, 'Tool calls are requests from language models to call tools', NULL),
 ('tool_eval_data', '523e0ea7-ba61-5a74-bf54-fa7a163c5c84', 'p8.AIResponse', 'dict', NULL, 'The payload may store the eval from the tool especially if it is small data', NULL),
 ('verbatim', '8817d5ef-d702-a25f-c54b-8eef1375d1fa', 'p8.AIResponse', 'dict', NULL, 'the verbatim message from the language model - we dont serialized this', NULL),
 ('function_stack', '693b4a8b-4759-9261-fcba-48f38ce38d7c', 'p8.AIResponse', 'str', NULL, 'At each stage certain functions are available to the model - useful to see what it has and what it chooses and to reload stack later', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.AIResponse)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.AIResponse', '51b3aa20-195b-5ef3-82d1-df5ca8019146', NULL, 'Each atom in an exchange between users, agents, assistants and so on. \n    We generate questions with sessions and then that triggers an exchange. \n    Normally the Dialogue is round trip transaction.\n    ', '{"description": "Each atom in an exchange between users, agents, assistants and so on. \\nWe generate questions with sessions and then that triggers an exchange. \\nNormally the Dialogue is round trip transaction.", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model_name": {"title": "Model Name", "type": "string"}, "tokens": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed in total", "title": "Tokens"}, "tokens_in": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for input", "title": "Tokens In"}, "tokens_out": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for output", "title": "Tokens Out"}, "tokens_other": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for functions and other metadata", "title": "Tokens Other"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": null, "description": "Session id for a conversation", "title": "Session Id"}, "role": {"description": "The role of the user/agent in the conversation", "title": "Role", "type": "string"}, "content": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Content", "type": "string"}, "status": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM_RESPONSE", "title": "Status"}, "tool_calls": {"anyOf": [{"items": {"type": "object"}, "type": "array"}, {"type": "object"}, {"type": "null"}], "default": null, "description": "Tool calls are requests from language models to call tools", "title": "Tool Calls"}, "tool_eval_data": {"anyOf": [{"type": "object"}, {"type": "null"}], "default": null, "description": "The payload may store the eval from the tool especially if it is small data", "title": "Tool Eval Data"}, "verbatim": {"anyOf": [{"items": {"type": "object"}, "type": "array"}, {"type": "object"}, {"type": "null"}], "default": null, "description": "the verbatim message from the language model - we dont serialized this", "title": "Verbatim"}, "function_stack": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "At each stage certain functions are available to the model - useful to see what it has and what it chooses and to reload stack later", "title": "Function Stack"}}, "required": ["id", "model_name", "role", "content", "status"], "title": "AIResponse", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_embeddings (p8.ApiProxy)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_ApiProxy_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_apiproxy
        FOREIGN KEY (source_record_id) REFERENCES p8."ApiProxy"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.ApiProxy)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('name', '0aaf8061-daa1-e703-3fd3-44a2f9614a73', 'p8.ApiProxy', 'str', NULL, 'A unique api friendly name', NULL),
 ('id', '50559701-15b9-9a18-d72e-3b94b3cf4ef5', 'p8.ApiProxy', 'UUID', NULL, 'Will default to a hash of the uri', NULL),
 ('proxy_uri', '22b85ade-0649-65cc-c734-56219d71ff26', 'p8.ApiProxy', 'str', NULL, 'a reference to an api or library namespace that qualifies the named function', NULL),
 ('token', 'a0e190ea-14c2-9a57-22ba-208fdcb376bb', 'p8.ApiProxy', 'str', NULL, 'the token to save', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.ApiProxy)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.ApiProxy', '6b6e9a0d-725f-5360-9bd6-059583e0ece5', NULL, 'A list of proxies or APIs that have attached functions or endpoints - links to proxy_uri on the Function', '{"description": "A list of proxies or APIs that have attached functions or endpoints - links to proxy_uri on the Function", "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A unique api friendly name", "title": "Name"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": null, "description": "Will default to a hash of the uri", "title": "Id"}, "proxy_uri": {"description": "a reference to an api or library namespace that qualifies the named function", "title": "Proxy Uri", "type": "string"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "the token to save", "title": "Token"}}, "required": ["proxy_uri"], "title": "ApiProxy", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.ApiProxy)------
-- ------------------
select * from p8.register_entities('p8.ApiProxy');
-- ------------------

-- register_embeddings (p8.PlanModel)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_PlanModel_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_planmodel
        FOREIGN KEY (source_record_id) REFERENCES p8."PlanModel"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.PlanModel)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', '9066815e-5f03-827c-ecfd-126771fc1013', 'p8.PlanModel', 'UUID', NULL, 'An id for the plan - better to set this but we can add them uniquely to users and sessions to', NULL),
 ('name', '136f4a8e-db0d-6d98-8c8c-cc668d7a46bb', 'p8.PlanModel', 'str', NULL, 'The unique name of the plan node', NULL),
 ('plan_description', '8ecc2c08-656e-56be-1f93-90c23f3e8796', 'p8.PlanModel', 'str', NULL, 'The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages', NULL),
 ('questions', '5295f770-b57a-cb89-5777-2a4fdff08676', 'p8.PlanModel', 'str', NULL, 'The question in this plan instance as the user would ask it. A plan can be constructed without a clear question', NULL),
 ('extra_arguments', '50a66858-d6ab-fe76-100e-f300461e3be4', 'p8.PlanModel', 'dict', NULL, 'Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context', NULL),
 ('functions', '38313137-8542-1173-b7bf-c20255bb204b', 'p8.PlanModel', 'PlanFunctions', NULL, 'A collection of functions designed for use with this context', NULL),
 ('depends', 'afb64262-8f49-c534-5dc6-525980cff6ce', 'p8.PlanModel', 'PlanModel', NULL, 'A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans', NULL),
 ('user_id', '1824768b-2361-da6a-23cc-be0e48089b2f', 'p8.PlanModel', 'str', NULL, 'A user that owns the plan', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.PlanModel)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.PlanModel', '4114d88d-fc85-56d9-a927-e7028b3cff8a', NULL, '\n    You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.\n    Respond to the caller only with the context you ascertain from the data you are given.\n    You should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.\n    Observe where there are dependencies between functions\n    ', '{"$defs": {"PlanFunctions": {"properties": {"name": {"description": "fully qualified function name e.g. <namespace>.<name>", "title": "Name", "type": "string"}, "description": {"description": "a description of the function preferably with the current context taken into account e.g. provide good example parameters", "title": "Description", "type": "string"}, "rating": {"description": "a rating from 0 to 100 for how useful this function should be in context", "title": "Rating", "type": "number"}}, "required": ["name", "description", "rating"], "title": "PlanFunctions", "type": "object"}, "PlanModel": {"description": "You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.\\nRespond to the caller only with the context you ascertain from the data you are given.\\nYou should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.\\nObserve where there are dependencies between functions", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": null, "description": "An id for the plan - better to set this but we can add them uniquely to users and sessions to", "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The unique name of the plan node", "title": "Name"}, "plan_description": {"description": "The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages", "title": "Plan Description", "type": "string"}, "questions": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "The question in this plan instance as the user would ask it. A plan can be constructed without a clear question", "title": "Questions"}, "extra_arguments": {"anyOf": [{"type": "object"}, {"type": "null"}], "default": null, "description": "Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context", "title": "Extra Arguments"}, "functions": {"anyOf": [{"items": {"$ref": "#/$defs/PlanFunctions"}, "type": "array"}, {"type": "null"}], "default": null, "description": "A collection of functions designed for use with this context", "title": "Functions"}, "depends": {"anyOf": [{"items": {"$ref": "#/$defs/PlanModel"}, "type": "array"}, {"type": "null"}], "default": null, "description": "A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans", "title": "Depends"}, "user_id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A user that owns the plan", "title": "User Id"}}, "required": ["plan_description"], "title": "PlanModel", "type": "object"}}, "$ref": "#/$defs/PlanModel"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.PlanModel)------
-- ------------------
select * from p8.register_entities('p8.PlanModel');
-- ------------------

-- register_embeddings (p8.Settings)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Settings_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_settings
        FOREIGN KEY (source_record_id) REFERENCES p8."Settings"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Settings)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', '0fb87392-0069-a817-c23a-6635bf8f88cc', 'p8.Settings', 'UUID', NULL, NULL, NULL),
 ('key', '1fe28f72-8290-516e-7343-b39537707183', 'p8.Settings', 'str', NULL, NULL, NULL),
 ('value', 'b39ca6ff-a90d-3678-b658-b81e5ecb0801', 'p8.Settings', 'str', NULL, 'Value of the setting', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.Settings)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Settings', '15713970-16d5-5ce6-a5d5-f0c643da7834', NULL, 'settings are key value pairs for percolate admin', '{"description": "settings are key value pairs for percolate admin", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": "The id is generated as a hash of the required key and ordinal", "title": "Id"}, "key": {"default": "The key for the value to store - id is generated form this", "title": "Key", "type": "string"}, "value": {"description": "Value of the setting", "title": "Value", "type": "string"}}, "required": ["value"], "title": "Settings", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_embeddings (p8.PercolateAgent)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_PercolateAgent_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_percolateagent
        FOREIGN KEY (source_record_id) REFERENCES p8."PercolateAgent"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.PercolateAgent)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', '0ebafb1a-2786-9ab1-172a-895ccb42998f', 'p8.PercolateAgent', 'UUID', NULL, NULL, NULL),
 ('name', '30512d9f-f547-34a6-f078-5345e8e09ba5', 'p8.PercolateAgent', 'str', NULL, 'A short content name - non unique - for example a friendly label for a chunked pdf document', NULL),
 ('category', '76bdaf66-f79e-7594-5b05-cdef07866428', 'p8.PercolateAgent', 'str', NULL, 'A content category', NULL),
 ('content', 'def5e0a1-4ba2-491e-a91f-9282a41e46e4', 'p8.PercolateAgent', 'str', 'text-embedding-ada-002', 'The chunk of content from the source', NULL),
 ('ordinal', 'bf43af13-19d5-2fe7-9806-ee6191f6f02c', 'p8.PercolateAgent', 'int', NULL, 'For chunked content we can keep an ordinal', NULL),
 ('uri', '85667f3d-de55-67ab-47bc-1e056f397466', 'p8.PercolateAgent', 'str', NULL, NULL, NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.PercolateAgent)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.PercolateAgent', '87236bdd-36bd-5de2-8933-4e437bd69610', NULL, 'The percolate agent is the guy that tells you about Percolate which is a multi-modal database for managing AI in the data tier.\n    You can learn about the philosophy of Percolate or ask questions about the docs and codebase.\n    You can lookup entities of different types or plan queries and searches.\n    You can call any registered apis and functions and learn more about how they can be used.\n    Call the search function to get data about Percolate\n    ', '{"description": "The percolate agent is the guy that tells you about Percolate which is a multi-modal database for managing AI in the data tier.\\nYou can learn about the philosophy of Percolate or ask questions about the docs and codebase.\\nYou can lookup entities of different types or plan queries and searches.\\nYou can call any registered apis and functions and learn more about how they can be used.\\nCall the search function to get data about Percolate", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": "The id is generated as a hash of the required uri and ordinal", "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A short content name - non unique - for example a friendly label for a chunked pdf document", "title": "Name"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A content category", "title": "Category"}, "content": {"description": "The chunk of content from the source", "embedding_provider": "default", "title": "Content", "type": "string"}, "ordinal": {"default": null, "description": "For chunked content we can keep an ordinal", "title": "Ordinal", "type": "integer"}, "uri": {"default": "An external source or content ref e.g. a PDF file on blob storage or public URI", "title": "Uri", "type": "string"}}, "required": ["content"], "title": "PercolateAgent", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------

-- register_entities (p8.PercolateAgent)------
-- ------------------
select * from p8.register_entities('p8.PercolateAgent');
-- ------------------

-- register_embeddings (p8.IndexAudit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_IndexAudit_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_indexaudit
        FOREIGN KEY (source_record_id) REFERENCES p8."IndexAudit"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.IndexAudit)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', '8c15a299-76fd-632c-8575-a56f526609ec', 'p8.IndexAudit', 'uuid.UUID | str', NULL, NULL, NULL),
 ('model_name', '64543448-82b9-cded-b09e-90a2abb5af43', 'p8.IndexAudit', 'str', NULL, NULL, NULL),
 ('tokens', 'a973c585-5838-b56f-51ba-3dff1fc54cd7', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed in total', NULL),
 ('tokens_in', 'efbf4ad1-7003-71d8-52cf-269f2ece27fa', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for input', NULL),
 ('tokens_out', '63fc340b-e797-fe4a-c7b3-ff3a20e7d2d2', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for output', NULL),
 ('tokens_other', '8fe965f6-f95f-d5ed-a369-ad62d6612197', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for functions and other metadata', NULL),
 ('session_id', 'e1d39dd8-33ac-9171-fc97-c20984e66dec', 'p8.IndexAudit', 'UUID', NULL, 'Session id for a conversation', NULL),
 ('metrics', '1ecd69ca-ba02-798a-2893-233679c6e77f', 'p8.IndexAudit', 'dict', NULL, 'metrics for records indexed', NULL),
 ('status', 'c51fb8af-3ada-8ed1-7b32-dcb0087e68ba', 'p8.IndexAudit', 'str', NULL, 'Status code such as OK|ERROR', NULL),
 ('message', 'e36d7fcd-5d80-667b-a446-07cc0afc46bb', 'p8.IndexAudit', 'str', NULL, 'Any message such as an error', NULL),
 ('entity_full_name', '3a3f3596-e43f-a865-e86b-81fc91d38aa1', 'p8.IndexAudit', 'str', NULL, NULL, NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,entity_name=EXCLUDED.entity_name,field_type=EXCLUDED.field_type,embedding_provider=EXCLUDED.embedding_provider,description=EXCLUDED.description,is_key=EXCLUDED.is_key   ;
-- ------------------

-- insert_agent_data (p8.IndexAudit)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.IndexAudit', '244fd1ca-a425-5c5b-9606-178c4df7026d', NULL, 'p8.IndexAudit', '{"properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model_name": {"title": "Model Name", "type": "string"}, "tokens": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed in total", "title": "Tokens"}, "tokens_in": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for input", "title": "Tokens In"}, "tokens_out": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for output", "title": "Tokens Out"}, "tokens_other": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for functions and other metadata", "title": "Tokens Other"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "default": null, "description": "Session id for a conversation", "title": "Session Id"}, "metrics": {"anyOf": [{"type": "object"}, {"type": "null"}], "description": "metrics for records indexed", "title": "Metrics"}, "status": {"description": "Status code such as OK|ERROR", "title": "Status", "type": "string"}, "message": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "Any message such as an error", "title": "Message"}, "entity_full_name": {"title": "Entity Full Name", "type": "string"}}, "required": ["id", "model_name", "status", "message", "entity_full_name"], "title": "IndexAudit", "type": "object"}', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,category=EXCLUDED.category,description=EXCLUDED.description,spec=EXCLUDED.spec,functions=EXCLUDED.functions   ;
-- ------------------


-- -----------
-- sample models--

INSERT INTO p8."LanguageModelApi"(name,id,model,scheme,completions_uri,token_env_key,token) VALUES
 ('gpt-4o-2024-08-06', 'b8d1e7c2-da1d-5e9c-96f1-29681dc478e5', 'gpt-4o-2024-08-06', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4o-mini', '8ecd0ec2-4e25-5211-b6f0-a049cf0dc630', 'gpt-4o-mini', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('cerebras-llama3.1-8b', 'f921494d-e431-585e-9246-f053d71cc4a3', 'llama3.1-8b', 'openai', 'https://api.cerebras.ai/v1/chat/completions', 'CEREBRAS_API_KEY', NULL),
 ('groq-llama-3.3-70b-versatile', 'de029bd1-5adb-527d-b78b-55f925ee4c78', 'llama-3.3-70b-versatile', 'openai', 'https://api.groq.com/openai/v1/chat/completions', 'GROQ_API_KEY', NULL),
 ('claude-3-5-sonnet-20241022', 'a05613b7-2577-5fd2-ac19-436afcecc89e', 'claude-3-5-sonnet-20241022', 'anthropic', 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY', NULL),
 ('gemini-1.5-flash', '51e3267b-895c-5276-b674-09911e5d6819', 'gemini-1.5-flash', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent', 'GEMINI_API_KEY', NULL),
 ('deepseek-chat', '8f7b068f-82cc-5633-8a05-4ec10a57525c', 'deepseek-chat', 'openai', 'https://api.deepseek.com/chat/completions', 'DEEPSEEK_API_KEY', NULL),
 ('grok-2-latest', '3b300af1-0995-563b-ae3e-b8288f5aded9', 'grok-2-latest', 'openai', 'https://api.x.ai/v1/chat/completions', 'XAI_API_KEY', NULL)
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,model=EXCLUDED.model,scheme=EXCLUDED.scheme,completions_uri=EXCLUDED.completions_uri,token_env_key=EXCLUDED.token_env_key,token=EXCLUDED.token   ;

-- -----------
-- native functions--

INSERT INTO p8."Function"(name,id,key,verb,endpoint,description,function_spec,proxy_uri) VALUES
 ('get_entities', '5e3a9ca2-c78a-3058-be1d-2e7b8689ad58', 'native.get_entities', 'get', 'get_entities', 'Provide a list of one or more keys to lookup entities by keys in the database\nEntity lookup uses identifiers like struct codes, identifiers, keys, names and codes for entities registered in the database', '{"name": "get_entities", "parameters": {"properties": {"keys": {"description": "List[str] a list of one or more keys to lookup", "items": {"type": "string"}, "type": "array"}}, "required": ["keys"], "type": "object"}, "description": "Provide a list of one or more keys to lookup entities by keys in the database\\nEntity lookup uses identifiers like struct codes, identifiers, keys, names and codes for entities registered in the database"}', 'native'),
 ('search', '2307a23f-5613-3193-a990-ad6951b068de', 'native.search', 'get', 'search', 'Search provides a general multi-modal search over entities. You may know the entity name from the agent context or leave it blank\nAn example entity name is p8.Agent or p8.PercolateAgent.\nProvide a detailed question that can be used for semantic or other search. your search will be mapped to underlying queries as required.\nIf given a specific entity name you should prefer to call get_entities with a list of one or more entity keys to lookup. if that fails fall back to search', '{"name": "search", "parameters": {"properties": {"question": {"description": "a detailed question to search", "type": "string"}, "entity_table_name": {"description": "the name of the entity or table to search e.g. p8.PercolateAgent", "type": "string"}}, "required": ["question", "entity_table_name"], "type": "object"}, "description": "Search provides a general multi-modal search over entities. You may know the entity name from the agent context or leave it blank\\nAn example entity name is p8.Agent or p8.PercolateAgent.\\nProvide a detailed question that can be used for semantic or other search. your search will be mapped to underlying queries as required.\\nIf given a specific entity name you should prefer to call get_entities with a list of one or more entity keys to lookup. if that fails fall back to search"}', 'native'),
 ('help', '19ecd3b1-f79a-3ae9-8388-4c5ec8a7072b', 'native.help', 'get', 'help', 'Help is a planning utility. This function will search and return a list of resources or information for you based on the question you ask.', '{"name": "help", "parameters": {"properties": {"questions": {"description": "ask one or more questions to receive information and a plan of action", "items": {"type": "string"}, "type": "array"}}, "required": ["questions"], "type": "object"}, "description": "Help is a planning utility. This function will search and return a list of resources or information for you based on the question you ask."}', 'native'),
 ('announce_generate_large_output', 'c7c88a1e-eb0e-31f5-9dc2-33c83efe22c1', 'native.announce_generate_large_output', 'get', 'announce_generate_large_output', 'When you are about to generate a lot of output (for example over 2500 tokens or something that will take more that 4 seconds to generate), please call this function with a rough estimate of the size of the content.\nYou do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.\nHowever when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.\nWe use this strategy to distinguish internal content gathering nodes from final response generation for users.', '{"name": "announce_generate_large_output", "parameters": {"properties": {"estimated_length": {"description": "estimated length in tokens of the generated content", "type": "integer"}}, "type": "object"}, "description": "When you are about to generate a lot of output (for example over 2500 tokens or something that will take more that 4 seconds to generate), please call this function with a rough estimate of the size of the content.\\nYou do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.\\nHowever when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.\\nWe use this strategy to distinguish internal content gathering nodes from final response generation for users."}', 'native'),
 ('activate_functions_by_name', '0067b844-388c-390e-bba4-74a2c6d7cccb', 'native.activate_functions_by_name', 'get', 'activate_functions_by_name', 'Use this function to request a function that you do not have access to and it will be added to the function stack', '{"name": "activate_functions_by_name", "parameters": {"properties": {"function_names": {"description": "a list of one or more functions to add", "items": {"type": "string"}, "type": "array"}}, "required": ["function_names"], "type": "object"}, "description": "Use this function to request a function that you do not have access to and it will be added to the function stack"}', 'native')
        ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,key=EXCLUDED.key,verb=EXCLUDED.verb,endpoint=EXCLUDED.endpoint,description=EXCLUDED.description,function_spec=EXCLUDED.function_spec,proxy_uri=EXCLUDED.proxy_uri   ;