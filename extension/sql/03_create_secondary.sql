
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
 ('target_date', '54804545-d390-5f2d-edba-83a8649b1f19', 'p8.Project', 'datetime', NULL, 'Optional target date', NULL);
-- ------------------

-- insert_agent_data (p8.Project)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Project', '3d291419-02cd-58b4-a96e-76aadee594c3', NULL, 'A project is a broadly defined goal with related resources (uses the graph)', '{"description": "A project is a broadly defined goal with related resources (uses the graph)", "properties": {"name": {"description": "The name of the entity e.g. a model in the types or a user defined model", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "description": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Description", "type": "string"}, "target_date": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Optional target date", "title": "Target Date"}}, "required": ["name", "id", "description"], "title": "Project", "type": "object"}', NULL);
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
 ('functions', 'e664cb9d-cbfb-6196-73e8-140930264434', 'p8.Agent', 'dict', NULL, 'The function that agent can call', NULL);
-- ------------------

-- insert_agent_data (p8.Agent)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Agent', '96d1a2ff-045b-55cc-a7de-543d1d3cccf8', NULL, 'The agent model is a meta data object to persist agent metadata for search etc', '{"description": "The agent model is a meta data object to persist agent metadata for search etc", "properties": {"name": {"title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Simple property to filter agents by categories", "title": "Category"}, "description": {"description": "The system prompt as markdown", "embedding_provider": "default", "title": "Description", "type": "string"}, "spec": {"description": "The model json schema", "title": "Spec", "type": "object"}, "functions": {"anyOf": [{"type": "object"}, {"type": "null"}], "description": "The function that agent can call", "title": "Functions"}}, "required": ["name", "id", "description", "spec"], "title": "Agent", "type": "object"}', NULL);
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
 ('is_key', '83940d96-c8da-6825-9fd6-9fff0eb58a24', 'p8.ModelField', 'bool', NULL, 'Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings', NULL);
-- ------------------

-- insert_agent_data (p8.ModelField)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.ModelField', 'ea1ce51b-2377-5f56-9a0e-963ef6116b05', NULL, 'Fields are each field in any saved model/agent. \n    Fields are useful for describing system info such as for embeddings or for promoting.\n    ', '{"description": "Fields are each field in any saved model/agent. \\nFields are useful for describing system info such as for embeddings or for promoting.", "properties": {"name": {"description": "The field name", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "description": "a unique key for the field e.g. field and entity key hashed", "title": "Id"}, "entity_name": {"title": "Entity Name", "type": "string"}, "field_type": {"title": "Field Type", "type": "string"}, "embedding_provider": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The embedding could be a multiple in future", "title": "Embedding Provider"}, "description": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Description"}, "is_key": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": false, "description": "Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings", "title": "Is Key"}}, "required": ["name", "id", "entity_name", "field_type"], "title": "ModelField", "type": "object"}', NULL);
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
 ('token', '5906dae1-3d9f-d08f-85ed-013f565d99b1', 'p8.LanguageModelApi', 'str', NULL, 'It is not recommended to add tokens directly to the data but for convenience you might want to', NULL);
-- ------------------

-- insert_agent_data (p8.LanguageModelApi)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.LanguageModelApi', 'd0a0e81a-3525-5e52-afb3-c736103c42ab', NULL, 'The Language model REST Apis are stored with tokens and scheme information.\n    ', '{"description": "The Language model REST Apis are stored with tokens and scheme information.\\n    ", "properties": {"name": {"description": "A unique name for the model api e.g cerebras-llama3.1-8b", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier", "title": "Model"}, "scheme": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "openai", "description": "In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ", "title": "Scheme"}, "completions_uri": {"description": "The api used for completions in chat and function calling. There may be other uris for other contexts", "title": "Completions Uri", "type": "string"}, "token_env_key": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Conventions are used to resolve keys from env or other services. Provide an alternative key", "title": "Token Env Key"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "It is not recommended to add tokens directly to the data but for convenience you might want to", "title": "Token"}}, "required": ["name", "id", "completions_uri"], "title": "LanguageModelApi", "type": "object"}', NULL);
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
 ('proxy_uri', '9faddba7-2a4b-a536-28cb-ac3bd1b6df53', 'p8.Function', 'str', NULL, 'a reference to an api or library namespace that qualifies the named function', NULL);
-- ------------------

-- insert_agent_data (p8.Function)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Function', '871c0a64-8a7b-5757-9fd0-f046a282656f', NULL, 'Functions are external tools that agents can use. See field comments for context.\n    Functions can be searched and used as LLM tools. \n    The function spec is derived from OpenAPI but adapted to the conventional used in LLMs\n    ', '{"description": "Functions are external tools that agents can use. See field comments for context.\\nFunctions can be searched and used as LLM tools. \\nThe function spec is derived from OpenAPI but adapted to the conventional used in LLMs", "properties": {"name": {"description": "A friendly name that is unique within the proxy scope e.g. a single api or python library", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "description": "A unique id in this case generated by the proxy and function name", "title": "Id"}, "key": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "optional key e.g operation id", "title": "Key"}, "verb": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The verb e.g. get, post etc", "title": "Verb"}, "endpoint": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A callable endpoint in the case of REST", "title": "Endpoint"}, "description": {"default": "", "description": "A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable", "embedding_provider": "default", "title": "Description", "type": "string"}, "function_spec": {"description": "A function description that is OpenAI and based on the OpenAPI spec", "title": "Function Spec", "type": "object"}, "proxy_uri": {"description": "a reference to an api or library namespace that qualifies the named function", "title": "Proxy Uri", "type": "string"}}, "required": ["name", "id", "key", "function_spec", "proxy_uri"], "title": "Function", "type": "object"}', NULL);
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
 ('query', '5f781f67-29c1-c21c-2b4c-f891a1455bf4', 'p8.Session', 'str', NULL, 'the question or context that triggered the session', NULL);
-- ------------------

-- insert_agent_data (p8.Session)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Session', '1b116463-808f-5798-8809-8450045f0d53', NULL, 'Tracks groups if session dialogue', '{"description": "Tracks groups if session dialogue", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "query": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "the question or context that triggered the session", "title": "Query"}}, "required": ["id"], "title": "Session", "type": "object"}', NULL);
-- ------------------

-- register_embeddings (p8.Dialogue)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Dialogue_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_dialogue
        FOREIGN KEY (source_record_id) REFERENCES p8."Dialogue"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Dialogue)------
-- ------------------
INSERT INTO p8."ModelField"(name,id,entity_name,field_type,embedding_provider,description,is_key) VALUES
 ('id', 'b837fee2-647c-4e4d-0903-e69d78a9a45b', 'p8.Dialogue', 'uuid.UUID | str', NULL, NULL, NULL),
 ('model_name', '54d271d7-74e9-1367-a2b6-1f53c5a74b65', 'p8.Dialogue', 'str', NULL, NULL, NULL),
 ('tokens', 'de264c1d-9a45-db95-901e-cb5ab7b2761e', 'p8.Dialogue', 'int', NULL, 'the number of tokens consumed in total', NULL),
 ('tokens_in', '8eb8ea77-ee6f-a4d8-56d1-81af6de72d25', 'p8.Dialogue', 'int', NULL, 'the number of tokens consumed for input', NULL),
 ('tokens_out', '90240d70-cef8-3dc7-b000-db22b3f9be85', 'p8.Dialogue', 'int', NULL, 'the number of tokens consumed for output', NULL),
 ('tokens_other', '81efee3d-5076-4c5a-9f38-656232d05168', 'p8.Dialogue', 'int', NULL, 'the number of tokens consumed for functions and other metadata', NULL),
 ('session_id', 'b8ea0d10-ab7f-a6b1-3334-57eb45e7ae6d', 'p8.Dialogue', 'UUID', NULL, 'Session id for a conversation', NULL),
 ('role', '06990195-f99f-08e6-db00-05d839caadd4', 'p8.Dialogue', 'str', NULL, 'The role of the user/agent in the conversation', NULL),
 ('content', '4ff7d8a1-2960-0128-fc0b-c2d09d82229b', 'p8.Dialogue', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', NULL),
 ('status', 'c44e0e21-c8ec-dcb3-a0eb-81e2338ef6dc', 'p8.Dialogue', 'str', NULL, 'The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM', NULL),
 ('tool_calls', 'c3566bc9-e427-dd09-3a51-047fca1adf49', 'p8.Dialogue', 'dict', NULL, 'Tool calls are requests from language models to call tools', NULL),
 ('tool_eval_data', '3dcf404b-1da3-e35a-efd5-78cc8af3d46c', 'p8.Dialogue', 'dict', NULL, 'The payload may store the eval from the tool especially if it is small data', NULL);
-- ------------------

-- insert_agent_data (p8.Dialogue)------
-- ------------------
INSERT INTO p8."Agent"(name,id,category,description,spec,functions) VALUES
 ('p8.Dialogue', '34adb6e5-a6d6-54ad-bda1-e37a04a28ec6', NULL, 'Each atom in an exchange between users, agents, assistants and so on. \n    We generate questions with sessions and then that triggers an exchange. \n    Normally the Dialogue is round trip transaction.\n    ', '{"description": "Each atom in an exchange between users, agents, assistants and so on. \\nWe generate questions with sessions and then that triggers an exchange. \\nNormally the Dialogue is round trip transaction.", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model_name": {"title": "Model Name", "type": "string"}, "tokens": {"description": "the number of tokens consumed in total", "title": "Tokens", "type": "integer"}, "tokens_in": {"anyOf": [{"type": "integer"}, {"type": "null"}], "description": "the number of tokens consumed for input", "title": "Tokens In"}, "tokens_out": {"anyOf": [{"type": "integer"}, {"type": "null"}], "description": "the number of tokens consumed for output", "title": "Tokens Out"}, "tokens_other": {"anyOf": [{"type": "integer"}, {"type": "null"}], "description": "the number of tokens consumed for functions and other metadata", "title": "Tokens Other"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}, {"type": "null"}], "description": "Session id for a conversation", "title": "Session Id"}, "role": {"description": "The role of the user/agent in the conversation", "title": "Role", "type": "string"}, "content": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Content", "type": "string"}, "status": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM", "title": "Status"}, "tool_calls": {"anyOf": [{"type": "object"}, {"type": "null"}], "default": null, "description": "Tool calls are requests from language models to call tools", "title": "Tool Calls"}, "tool_eval_data": {"anyOf": [{"type": "object"}, {"type": "null"}], "default": null, "description": "The payload may store the eval from the tool especially if it is small data", "title": "Tool Eval Data"}}, "required": ["id", "model_name", "tokens", "tokens_in", "tokens_out", "tokens_other", "session_id", "role", "content", "status"], "title": "Dialogue", "type": "object"}', NULL);
-- ------------------


-- -----------
-- sample models--

INSERT INTO p8."LanguageModelApi"(name,id,model,scheme,completions_uri,token_env_key,token) VALUES
 ('gpt-4o-2024-08-06', 'b8d1e7c2-da1d-5e9c-96f1-29681dc478e5', 'gpt-4o-2024-08-06', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4o-mini', '8ecd0ec2-4e25-5211-b6f0-a049cf0dc630', 'gpt-4o-mini', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('cerebras-llama3.1-8b', 'f921494d-e431-585e-9246-f053d71cc4a3', 'llama3.1-8b', 'openai', 'https://api.cerebras.ai/v1/chat/completions', 'CEREBRAS_API_KEY', NULL),
 ('groq-llama-3.3-70b-versatile', 'de029bd1-5adb-527d-b78b-55f925ee4c78', 'llama-3.3-70b-versatile', 'openai', 'https://api.groq.com/openai/v1/chat/completions', NULL, NULL),
 ('claude-3-5-sonnet-20241022', 'a05613b7-2577-5fd2-ac19-436afcecc89e', 'claude-3-5-sonnet-20241022', 'anthropic', 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY', NULL),
 ('gemini-1.5-flash', '51e3267b-895c-5276-b674-09911e5d6819', 'gemini-1.5-flash', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent', 'GEMINI_API_KEY', NULL),
 ('deepseek-chat', '8f7b068f-82cc-5633-8a05-4ec10a57525c', 'deepseek-chat', 'openai', 'https://api.deepseek.com/chat/completions', 'DEEPSEEK_API_KEY', NULL);