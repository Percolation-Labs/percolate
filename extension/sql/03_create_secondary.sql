
-- register_embeddings (p8.User)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_User_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_user
        FOREIGN KEY (source_record_id) REFERENCES p8."User"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.User)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '6e93098a-444b-5386-b4c3-1cc4db111f41', 'p8.User', 'str', NULL, 'A display name for a user', False),
 ('id', 'b7ecb2e8-7a48-e772-7c37-d61c46d60a3f', 'p8.User', 'uuid.UUID | str', NULL, NULL, False),
 ('email', '0d42bced-da21-8250-f035-27ec9b51f855', 'p8.User', 'str', NULL, 'email of the user if we know it - the key must be something unique like this', True),
 ('slack_id', 'ea314b80-c83d-f0de-357d-c9e13f7ad5ff', 'p8.User', 'str', NULL, 'slack user U12345', False),
 ('linkedin', '49bc34ea-87a1-22a6-5d67-5a7c451e8ffa', 'p8.User', 'str', NULL, 'linkedin profile for user discovery', False),
 ('twitter', '895e7304-c28b-7c84-8024-afecbc94d640', 'p8.User', 'str', NULL, 'twitter profile for user discovery', False),
 ('description', 'c61d06ae-edf1-9ebd-74d6-621330f4eb33', 'p8.User', 'str', 'text-embedding-ada-002', 'A learned description of the user', False),
 ('recent_threads', '1b684a08-68c0-0a02-2a6b-ac1e4b840578', 'p8.User', 'dict', NULL, 'A thread is a single conversation on any channel - the session contains a list of messages with thread id binding them', False),
 ('last_ai_response', '426ac519-3677-cfe6-1c1f-0d6cfd33bd94', 'p8.User', 'str', NULL, 'We store this context for managing conversations and state', False),
 ('interesting_entity_keys', '928b5489-4ebf-6d97-48a1-6afbd69f221a', 'p8.User', 'dict', NULL, 'For the agents convenience a short term mapping of interesting keys with optional descriptions based on user activity', False),
 ('token', 'a859b4d4-7727-d87f-acf6-e5322cc8a080', 'p8.User', 'str', NULL, 'A token for user authentication to Percolate', False),
 ('token_expiry', 'b8138726-7f5f-9e91-0574-20b62633b89b', 'p8.User', 'datetime', NULL, 'Token expiry datetime for user authentication', False),
 ('session_id', '40a7fa89-4f3e-96c1-0f40-ebd522a80048', 'p8.User', 'str', NULL, 'Last session ID for the user', False),
 ('last_session_at', '0be65a32-79fc-ff7b-998e-93edd6bf9499', 'p8.User', 'datetime', NULL, 'Last session activity timestamp', False),
 ('roles', '75e4a87a-c813-47d5-9996-ee1505099793', 'p8.User', 'str', NULL, 'A list of roles the user is a member of', False),
 ('graph_paths', 'e1ba64d1-64ce-921e-fbac-27ef1dbe70f3', 'p8.User', 'str', NULL, 'Track all paths extracted by an agent as used to build the KG', False),
 ('metadata', '7ab3ba4d-619c-e347-8d63-4b368febcf83', 'p8.User', 'dict', NULL, 'Arbitrary user metadata', False),
 ('email_subscription_active', '5ea41981-4517-33d9-ec67-9cffc5a71ca2', 'p8.User', 'bool', NULL, 'Users can opt in and out of emails', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.User)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.User', '29316f8d-818b-5055-9ba5-23ae4725edb9', NULL, '# Agent - p8.User
A model of a logged in user
# Schema

```{''''description'''': ''''A model of a logged in user'''', ''''properties'''': {''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A display name for a user'''', ''''title'''': ''''Name''''}, ''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''email'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''email of the user if we know it - the key must be something unique like this'''', ''''is_key'''': True, ''''title'''': ''''Email''''}, ''''slack_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''slack user U12345'''', ''''title'''': ''''Slack Id''''}, ''''linkedin'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''linkedin profile for user discovery'''', ''''title'''': ''''Linkedin''''}, ''''twitter'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''twitter profile for user discovery'''', ''''title'''': ''''Twitter''''}, ''''description'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': '''''''', ''''description'''': ''''A learned description of the user'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Description''''}, ''''recent_threads'''': {''''anyOf'''': [{''''items'''': {''''additionalProperties'''': True, ''''type'''': ''''object''''}, ''''type'''': ''''array''''}, {''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''A thread is a single conversation on any channel - the session contains a list of messages with thread id binding them'''', ''''title'''': ''''Recent Threads''''}, ''''last_ai_response'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''We store this context for managing conversations and state'''', ''''title'''': ''''Last Ai Response''''}, ''''interesting_entity_keys'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''For the agents convenience a short term mapping of interesting keys with optional descriptions based on user activity'''', ''''title'''': ''''Interesting Entity Keys''''}, ''''token'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A token for user authentication to Percolate'''', ''''title'''': ''''Token''''}, ''''token_expiry'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Token expiry datetime for user authentication'''', ''''title'''': ''''Token Expiry''''}, ''''session_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Last session ID for the user'''', ''''title'''': ''''Session Id''''}, ''''last_session_at'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Last session activity timestamp'''', ''''title'''': ''''Last Session At''''}, ''''roles'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''description'''': ''''A list of roles the user is a member of'''', ''''title'''': ''''Roles''''}, ''''graph_paths'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Track all paths extracted by an agent as used to build the KG'''', ''''title'''': ''''Graph Paths''''}, ''''metadata'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''Arbitrary user metadata'''', ''''title'''': ''''Metadata''''}, ''''email_subscription_active'''': {''''anyOf'''': [{''''type'''': ''''boolean''''}, {''''type'''': ''''null''''}], ''''default'''': False, ''''description'''': ''''Users can opt in and out of emails'''', ''''title'''': ''''Email Subscription Active''''}}, ''''required'''': [''''id''''], ''''title'''': ''''User'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "A model of a logged in user", "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A display name for a user", "title": "Name"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "email": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "email of the user if we know it - the key must be something unique like this", "is_key": true, "title": "Email"}, "slack_id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "slack user U12345", "title": "Slack Id"}, "linkedin": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "linkedin profile for user discovery", "title": "Linkedin"}, "twitter": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "twitter profile for user discovery", "title": "Twitter"}, "description": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "", "description": "A learned description of the user", "embedding_provider": "default", "title": "Description"}, "recent_threads": {"anyOf": [{"items": {"additionalProperties": true, "type": "object"}, "type": "array"}, {"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "A thread is a single conversation on any channel - the session contains a list of messages with thread id binding them", "title": "Recent Threads"}, "last_ai_response": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "We store this context for managing conversations and state", "title": "Last Ai Response"}, "interesting_entity_keys": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "For the agents convenience a short term mapping of interesting keys with optional descriptions based on user activity", "title": "Interesting Entity Keys"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A token for user authentication to Percolate", "title": "Token"}, "token_expiry": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Token expiry datetime for user authentication", "title": "Token Expiry"}, "session_id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Last session ID for the user", "title": "Session Id"}, "last_session_at": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Last session activity timestamp", "title": "Last Session At"}, "roles": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "description": "A list of roles the user is a member of", "title": "Roles"}, "graph_paths": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "Track all paths extracted by an agent as used to build the KG", "title": "Graph Paths"}, "metadata": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "Arbitrary user metadata", "title": "Metadata"}, "email_subscription_active": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": false, "description": "Users can opt in and out of emails", "title": "Email Subscription Active"}}, "required": ["id"], "title": "User", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_entities (p8.User)------
-- ------------------
select * from p8.register_entities('p8.User');
-- ------------------

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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '62a171bf-f6f0-963c-64f7-23353f237304', 'p8.Project', 'str', NULL, 'The name of the entity e.g. a model in the types or a user defined model', False),
 ('id', 'dfe5817d-6e11-e3e6-4a34-ce9b1e2983a1', 'p8.Project', 'uuid.UUID | str', NULL, NULL, False),
 ('description', '10c00232-88b5-b029-60d8-7b5314b80065', 'p8.Project', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', False),
 ('target_date', '54804545-d390-5f2d-edba-83a8649b1f19', 'p8.Project', 'datetime', NULL, 'Optional target date', False),
 ('collaborator_ids', '11b23f4b-d523-7530-078e-12626a89cdb9', 'p8.Project', 'UUID', NULL, 'Users collaborating on this project', False),
 ('status', 'baa8990b-cfcf-ef6b-1193-76e6787f3893', 'p8.Project', 'str', NULL, 'Project status', False),
 ('priority', '7fba4aa9-9a42-48e9-ca86-835d5f1740c0', 'p8.Project', 'int', NULL, 'Priority level (1-5), 1 being the highest priority', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Project)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Project', '3d291419-02cd-58b4-a96e-76aadee594c3', NULL, '# Agent - p8.Project
A project is a broadly defined goal with related resources (uses the graph)
# Schema

```{''''description'''': ''''A project is a broadly defined goal with related resources (uses the graph)'''', ''''properties'''': {''''name'''': {''''description'''': ''''The name of the entity e.g. a model in the types or a user defined model'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''description'''': {''''description'''': ''''The content for this part of the conversation'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Description'''', ''''type'''': ''''string''''}, ''''target_date'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Optional target date'''', ''''title'''': ''''Target Date''''}, ''''collaborator_ids'''': {''''description'''': ''''Users collaborating on this project'''', ''''items'''': {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, ''''title'''': ''''Collaborator Ids'''', ''''type'''': ''''array''''}, ''''status'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''active'''', ''''description'''': ''''Project status'''', ''''title'''': ''''Status''''}, ''''priority'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 1, ''''description'''': ''''Priority level (1-5), 1 being the highest priority'''', ''''title'''': ''''Priority''''}}, ''''required'''': [''''name'''', ''''id'''', ''''description''''], ''''title'''': ''''Project'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "A project is a broadly defined goal with related resources (uses the graph)", "properties": {"name": {"description": "The name of the entity e.g. a model in the types or a user defined model", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "description": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Description", "type": "string"}, "target_date": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Optional target date", "title": "Target Date"}, "collaborator_ids": {"description": "Users collaborating on this project", "items": {"format": "uuid", "type": "string"}, "title": "Collaborator Ids", "type": "array"}, "status": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "active", "description": "Project status", "title": "Status"}, "priority": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 1, "description": "Priority level (1-5), 1 being the highest priority", "title": "Priority"}}, "required": ["name", "id", "description"], "title": "Project", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', 'e11f251e-8da1-f9df-06ee-2febcb5190f3', 'p8.Agent', 'str', NULL, NULL, False),
 ('id', 'aa6cb74c-ef56-96d5-db17-b019bd69eadc', 'p8.Agent', 'uuid.UUID | str', NULL, NULL, False),
 ('category', 'd6fc8fdb-3db2-c5a8-db21-ac8f296065f8', 'p8.Agent', 'str', NULL, 'Simple property to filter agents by categories', False),
 ('description', '4d70cc01-bff8-cafe-13d3-79ac9f63b1e5', 'p8.Agent', 'str', 'text-embedding-ada-002', 'The system prompt as markdown', False),
 ('spec', 'a15c5b3b-7f84-0b80-100f-b489516944f1', 'p8.Agent', 'dict', NULL, 'The model json schema', False),
 ('functions', 'e664cb9d-cbfb-6196-73e8-140930264434', 'p8.Agent', 'dict', NULL, 'The function that agent can call', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Agent)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Agent', '96d1a2ff-045b-55cc-a7de-543d1d3cccf8', NULL, '# Agent - p8.Agent
The agent model is a meta data object to persist agent metadata for search etc
# Schema

```{''''description'''': ''''The agent model is a meta data object to persist agent metadata for search etc'''', ''''properties'''': {''''name'''': {''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''category'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Simple property to filter agents by categories'''', ''''title'''': ''''Category''''}, ''''description'''': {''''description'''': ''''The system prompt as markdown'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Description'''', ''''type'''': ''''string''''}, ''''spec'''': {''''additionalProperties'''': True, ''''description'''': ''''The model json schema'''', ''''title'''': ''''Spec'''', ''''type'''': ''''object''''}, ''''functions'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''The function that agent can call'''', ''''title'''': ''''Functions''''}}, ''''required'''': [''''name'''', ''''id'''', ''''description'''', ''''spec''''], ''''title'''': ''''Agent'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "The agent model is a meta data object to persist agent metadata for search etc", "properties": {"name": {"title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Simple property to filter agents by categories", "title": "Category"}, "description": {"description": "The system prompt as markdown", "embedding_provider": "default", "title": "Description", "type": "string"}, "spec": {"additionalProperties": true, "description": "The model json schema", "title": "Spec", "type": "object"}, "functions": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "The function that agent can call", "title": "Functions"}}, "required": ["name", "id", "description", "spec"], "title": "Agent", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '42b9d359-975d-af7f-ee7b-9e59ef1eaace', 'p8.ModelField', 'str', NULL, 'The field name', False),
 ('id', '36d8e543-b15b-c278-4277-bb91ace8073f', 'p8.ModelField', 'str', NULL, 'a unique key for the field e.g. field and entity key hashed', False),
 ('entity_name', '16bd1d11-281b-1c24-1f00-e7efdc832cee', 'p8.ModelField', 'str', NULL, NULL, False),
 ('field_type', '27803534-7efe-5294-e81b-b5c0e28fc7a5', 'p8.ModelField', 'str', NULL, NULL, False),
 ('embedding_provider', '801bd727-6b8e-60f0-3904-108b80ab0839', 'p8.ModelField', 'str', NULL, 'The embedding could be a multiple in future', False),
 ('description', 'e0135555-a675-92cd-687d-1f03f8b7c28a', 'p8.ModelField', 'str', NULL, NULL, False),
 ('is_key', '83940d96-c8da-6825-9fd6-9fff0eb58a24', 'p8.ModelField', 'bool', NULL, 'Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.ModelField)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.ModelField', 'ea1ce51b-2377-5f56-9a0e-963ef6116b05', NULL, '# Agent - p8.ModelField
Fields are each field in any saved model/agent. 
    Fields are useful for describing system info such as for embeddings or for promoting.
    
# Schema

```{''''description'''': ''''Fields are each field in any saved model/agent. \nFields are useful for describing system info such as for embeddings or for promoting.'''', ''''properties'''': {''''name'''': {''''description'''': ''''The field name'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''description'''': ''''a unique key for the field e.g. field and entity key hashed'''', ''''title'''': ''''Id''''}, ''''entity_name'''': {''''title'''': ''''Entity Name'''', ''''type'''': ''''string''''}, ''''field_type'''': {''''title'''': ''''Field Type'''', ''''type'''': ''''string''''}, ''''embedding_provider'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The embedding could be a multiple in future'''', ''''title'''': ''''Embedding Provider''''}, ''''description'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''title'''': ''''Description''''}, ''''is_key'''': {''''anyOf'''': [{''''type'''': ''''boolean''''}, {''''type'''': ''''null''''}], ''''default'''': False, ''''description'''': ''''Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings'''', ''''title'''': ''''Is Key''''}}, ''''required'''': [''''name'''', ''''id'''', ''''entity_name'''', ''''field_type''''], ''''title'''': ''''ModelField'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Fields are each field in any saved model/agent. \nFields are useful for describing system info such as for embeddings or for promoting.", "properties": {"name": {"description": "The field name", "title": "Name", "type": "string"}, "id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "description": "a unique key for the field e.g. field and entity key hashed", "title": "Id"}, "entity_name": {"title": "Entity Name", "type": "string"}, "field_type": {"title": "Field Type", "type": "string"}, "embedding_provider": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The embedding could be a multiple in future", "title": "Embedding Provider"}, "description": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "title": "Description"}, "is_key": {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": false, "description": "Indicate that the field is the primary key - our convention is the id field should be the primary key and be uuid and we use this to join embeddings", "title": "Is Key"}}, "required": ["name", "id", "entity_name", "field_type"], "title": "ModelField", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', 'a43ab935-2ede-88e3-4fcf-6b5b9be8e095', 'p8.LanguageModelApi', 'str', NULL, 'A unique name for the model api e.g cerebras-llama3.1-8b', False),
 ('id', '6f38ec59-8b59-6efa-b88b-1c7a1b654787', 'p8.LanguageModelApi', 'uuid.UUID | str', NULL, NULL, False),
 ('model', 'ed5d930c-a531-4cc5-5732-aca6344ce9f9', 'p8.LanguageModelApi', 'str', NULL, 'The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier', False),
 ('scheme', '193ef059-3117-8dca-0a4e-f2dc5d849587', 'p8.LanguageModelApi', 'str', NULL, 'In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ', False),
 ('completions_uri', '8ef8334e-d45f-3e7d-5c3f-bb75add8bbb1', 'p8.LanguageModelApi', 'str', NULL, 'The api used for completions in chat and function calling. There may be other uris for other contexts', False),
 ('token_env_key', 'b4dca876-7eee-fd69-10df-bdf3effdf1b0', 'p8.LanguageModelApi', 'str', NULL, 'Conventions are used to resolve keys from env or other services. Provide an alternative key', False),
 ('token', '5906dae1-3d9f-d08f-85ed-013f565d99b1', 'p8.LanguageModelApi', 'str', NULL, 'It is not recommended to add tokens directly to the data but for convenience you might want to', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.LanguageModelApi)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.LanguageModelApi', 'd0a0e81a-3525-5e52-afb3-c736103c42ab', NULL, '# Agent - p8.LanguageModelApi
The Language model REST Apis are stored with tokens and scheme information.
    
# Schema

```{''''description'''': ''''The Language model REST Apis are stored with tokens and scheme information.\n    '''', ''''properties'''': {''''name'''': {''''description'''': ''''A unique name for the model api e.g cerebras-llama3.1-8b'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''model'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier'''', ''''title'''': ''''Model''''}, ''''scheme'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''openai'''', ''''description'''': ''''In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ'''', ''''title'''': ''''Scheme''''}, ''''completions_uri'''': {''''description'''': ''''The api used for completions in chat and function calling. There may be other uris for other contexts'''', ''''title'''': ''''Completions Uri'''', ''''type'''': ''''string''''}, ''''token_env_key'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Conventions are used to resolve keys from env or other services. Provide an alternative key'''', ''''title'''': ''''Token Env Key''''}, ''''token'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''It is not recommended to add tokens directly to the data but for convenience you might want to'''', ''''title'''': ''''Token''''}}, ''''required'''': [''''name'''', ''''id'''', ''''completions_uri''''], ''''title'''': ''''LanguageModelApi'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "The Language model REST Apis are stored with tokens and scheme information.\n    ", "properties": {"name": {"description": "A unique name for the model api e.g cerebras-llama3.1-8b", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The model name defaults to the name as they are often the same. the name can be unique based on a provider qualfier", "title": "Model"}, "scheme": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "openai", "description": "In practice most LLM APIs use an openai scheme - currently `anthropic` and `google` can differ", "title": "Scheme"}, "completions_uri": {"description": "The api used for completions in chat and function calling. There may be other uris for other contexts", "title": "Completions Uri", "type": "string"}, "token_env_key": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Conventions are used to resolve keys from env or other services. Provide an alternative key", "title": "Token Env Key"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "It is not recommended to add tokens directly to the data but for convenience you might want to", "title": "Token"}}, "required": ["name", "id", "completions_uri"], "title": "LanguageModelApi", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '34dcf34c-b385-0c19-f398-ff3b5dbcd3b1', 'p8.Function', 'str', NULL, 'A friendly name that is unique within the proxy scope e.g. a single api or python library', False),
 ('id', '9ab2626c-973d-996c-2e34-7e539cacec63', 'p8.Function', 'uuid.UUID | str', NULL, 'A unique id in this case generated by the proxy and function name', False),
 ('key', '154e802e-a795-2878-5cbc-56b315d7faf2', 'p8.Function', 'str', NULL, 'optional key e.g operation id', False),
 ('verb', '70c8ad39-ede9-d287-fc4c-94a9b195fc15', 'p8.Function', 'str', NULL, 'The verb e.g. get, post etc', False),
 ('endpoint', '16ab3e97-4d26-05ea-7369-2e29bf2acc53', 'p8.Function', 'str', NULL, 'A callable endpoint in the case of REST', False),
 ('description', 'e872491f-13d7-8754-fc1c-95d0cac14169', 'p8.Function', 'str', 'text-embedding-ada-002', 'A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable', False),
 ('function_spec', 'ef26856f-b727-bc2e-84cc-d62015a1fde7', 'p8.Function', 'dict', NULL, 'A function description that is OpenAI and based on the OpenAPI spec', False),
 ('proxy_uri', '9faddba7-2a4b-a536-28cb-ac3bd1b6df53', 'p8.Function', 'str', NULL, 'a reference to an api or library namespace that qualifies the named function', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Function)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Function', '871c0a64-8a7b-5757-9fd0-f046a282656f', NULL, '# Agent - p8.Function
Functions are external tools that agents can use. See field comments for context.
    Functions can be searched and used as LLM tools. 
    The function spec is derived from OpenAPI but adapted to the conventional used in LLMs
    
# Schema

```{''''description'''': ''''Functions are external tools that agents can use. See field comments for context.\nFunctions can be searched and used as LLM tools. \nThe function spec is derived from OpenAPI but adapted to the conventional used in LLMs'''', ''''properties'''': {''''name'''': {''''description'''': ''''A friendly name that is unique within the proxy scope e.g. a single api or python library'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''description'''': ''''A unique id in this case generated by the proxy and function name'''', ''''title'''': ''''Id''''}, ''''key'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''description'''': ''''optional key e.g operation id'''', ''''title'''': ''''Key''''}, ''''verb'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The verb e.g. get, post etc'''', ''''title'''': ''''Verb''''}, ''''endpoint'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A callable endpoint in the case of REST'''', ''''title'''': ''''Endpoint''''}, ''''description'''': {''''default'''': '''''''', ''''description'''': ''''A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Description'''', ''''type'''': ''''string''''}, ''''function_spec'''': {''''additionalProperties'''': True, ''''description'''': ''''A function description that is OpenAI and based on the OpenAPI spec'''', ''''title'''': ''''Function Spec'''', ''''type'''': ''''object''''}, ''''proxy_uri'''': {''''description'''': ''''a reference to an api or library namespace that qualifies the named function'''', ''''title'''': ''''Proxy Uri'''', ''''type'''': ''''string''''}}, ''''required'''': [''''name'''', ''''id'''', ''''key'''', ''''function_spec'''', ''''proxy_uri''''], ''''title'''': ''''Function'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Functions are external tools that agents can use. See field comments for context.\nFunctions can be searched and used as LLM tools. \nThe function spec is derived from OpenAPI but adapted to the conventional used in LLMs", "properties": {"name": {"description": "A friendly name that is unique within the proxy scope e.g. a single api or python library", "title": "Name", "type": "string"}, "id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "description": "A unique id in this case generated by the proxy and function name", "title": "Id"}, "key": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "optional key e.g operation id", "title": "Key"}, "verb": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The verb e.g. get, post etc", "title": "Verb"}, "endpoint": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A callable endpoint in the case of REST", "title": "Endpoint"}, "description": {"default": "", "description": "A detailed description of the function - may be more comprehensive than the one within the function spec - this is semantically searchable", "embedding_provider": "default", "title": "Description", "type": "string"}, "function_spec": {"additionalProperties": true, "description": "A function description that is OpenAI and based on the OpenAPI spec", "title": "Function Spec", "type": "object"}, "proxy_uri": {"description": "a reference to an api or library namespace that qualifies the named function", "title": "Proxy Uri", "type": "string"}}, "required": ["name", "id", "key", "function_spec", "proxy_uri"], "title": "Function", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', 'fb80623e-7d2d-4307-a912-6e476fa2a1e1', 'p8.Session', 'uuid.UUID | str', NULL, NULL, False),
 ('name', '0bcabe86-0da7-a97b-f250-1689eaca8e0e', 'p8.Session', 'str', NULL, 'The name is a pseudo name to make sessions node-compatible', False),
 ('query', '5f781f67-29c1-c21c-2b4c-f891a1455bf4', 'p8.Session', 'str', 'text-embedding-ada-002', 'the question or context that triggered the session - query can be an intent and it can be inferred', False),
 ('user_rating', '8a2e0ec5-e75a-522a-69a5-cfc8e2abfd7b', 'p8.Session', 'float', NULL, 'We can in future rate sessions to learn what works', False),
 ('agent', 'f50b93b2-78ab-1a84-9255-87d1b0470b02', 'p8.Session', 'str', NULL, 'Percolate always expects an agent but we support passing a system prompt which we treat as anonymous agent', False),
 ('parent_session_id', '15dc76f1-d9f2-da78-40e5-e5f2b27ecf4d', 'p8.Session', 'str', NULL, 'A session is a thread from a question+prompt to completion. We span child sessions', False),
 ('thread_id', '45e15ffc-01b7-f83e-9b29-4a988ea8b685', 'p8.Session', 'str', NULL, 'An id for a thread which can contain a number of sessions - thread matches are case insensitive ie.. MyID==myid - typically we prefer ids to be uuids but depends on the system', False),
 ('channel_id', 'de145ff6-182c-e8c9-d2b6-53f807e84655', 'p8.Session', 'str', NULL, 'The platform/channel ID through which the user is interacting (e.g., specific Slack channel ID)', False),
 ('channel_type', '24d30b26-6236-31f5-58b9-75d99a6244d3', 'p8.Session', 'str', NULL, 'The platform type (e.g., ''''slack'''', ''''percolate'''', ''''email'''') - the device info + the channel type tells if its mobile etc', False),
 ('session_type', 'e08aecdd-ccb7-3700-5db7-6d9496dc04a3', 'p8.Session', 'str', NULL, 'The type of session (e.g., ''''conversation'''', ''''resource_management'''', ''''task_creation'''', ''''daily_digest'''')', False),
 ('metadata', '83589148-e6cf-7d27-19e1-c97c974d537e', 'p8.Session', 'dict', NULL, 'Arbitrary metadata - typically this is device info and other context', False),
 ('session_completed_at', '4b372d12-fcbd-25df-89b4-749350663cd2', 'p8.Session', 'datetime', NULL, 'An audit timestamp to write back the completion of the session - its optional as it should manage the last timestamp on the AI Responses for the session', False),
 ('graph_paths', 'f4df843a-5a2d-0bde-3c99-354864a8edd3', 'p8.Session', 'str', NULL, 'Track all paths extracted by an agent as used to build the KG over user sessions', False),
 ('userid', '6ac4a757-b36f-983b-be94-ec5c09843bf8', 'p8.Session', 'str', NULL, 'The user id to use', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Session)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Session', '1b116463-808f-5798-8809-8450045f0d53', NULL, '# Agent - p8.Session
Tracks groups if session dialogue - sessions are requests that produce actions or activity. 
    Typical example is interacting with an AI but also it could be simply a request to bookmark or ingestion some content.
    From the user''''s perspective a session is a single interaction but internally the system performs multiple hops in general - hence "session"
    Sessions can be interactions with the system or agent but they can be inferred e.g. from user activity
    Sessions can also be abstract for example a daily diary can be an abstract session with the intent of capturing daily activity
    Sessions can be hierarchical and moments can be generated from sessions.
    
    Sessions model user intent.
    
# Schema

```{''''description'''': ''''Tracks groups if session dialogue - sessions are requests that produce actions or activity. \nTypical example is interacting with an AI but also it could be simply a request to bookmark or ingestion some content.\nFrom the user\''''s perspective a session is a single interaction but internally the system performs multiple hops in general - hence "session"\nSessions can be interactions with the system or agent but they can be inferred e.g. from user activity\nSessions can also be abstract for example a daily diary can be an abstract session with the intent of capturing daily activity\nSessions can be hierarchical and moments can be generated from sessions.\n\nSessions model user intent.'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The name is a pseudo name to make sessions node-compatible'''', ''''title'''': ''''Name''''}, ''''query'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''the question or context that triggered the session - query can be an intent and it can be inferred'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Query''''}, ''''user_rating'''': {''''anyOf'''': [{''''type'''': ''''number''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''We can in future rate sessions to learn what works'''', ''''title'''': ''''User Rating''''}, ''''agent'''': {''''default'''': ''''percolate'''', ''''description'''': ''''Percolate always expects an agent but we support passing a system prompt which we treat as anonymous agent'''', ''''title'''': ''''Agent'''', ''''type'''': ''''string''''}, ''''parent_session_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A session is a thread from a question+prompt to completion. We span child sessions'''', ''''title'''': ''''Parent Session Id''''}, ''''thread_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An id for a thread which can contain a number of sessions - thread matches are case insensitive ie.. MyID==myid - typically we prefer ids to be uuids but depends on the system'''', ''''title'''': ''''Thread Id''''}, ''''channel_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The platform/channel ID through which the user is interacting (e.g., specific Slack channel ID)'''', ''''title'''': ''''Channel Id''''}, ''''channel_type'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''percolate'''', ''''description'''': "The platform type (e.g., ''''slack'''', ''''percolate'''', ''''email'''') - the device info + the channel type tells if its mobile etc", ''''title'''': ''''Channel Type''''}, ''''session_type'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''conversation'''', ''''description'''': "The type of session (e.g., ''''conversation'''', ''''resource_management'''', ''''task_creation'''', ''''daily_digest'''')", ''''title'''': ''''Session Type''''}, ''''metadata'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''Arbitrary metadata - typically this is device info and other context'''', ''''title'''': ''''Metadata''''}, ''''session_completed_at'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An audit timestamp to write back the completion of the session - its optional as it should manage the last timestamp on the AI Responses for the session'''', ''''title'''': ''''Session Completed At''''}, ''''graph_paths'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Track all paths extracted by an agent as used to build the KG over user sessions'''', ''''title'''': ''''Graph Paths''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The user id to use'''', ''''title'''': ''''Userid''''}}, ''''required'''': [''''id''''], ''''title'''': ''''Session'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Tracks groups if session dialogue - sessions are requests that produce actions or activity. \nTypical example is interacting with an AI but also it could be simply a request to bookmark or ingestion some content.\nFrom the user''s perspective a session is a single interaction but internally the system performs multiple hops in general - hence \"session\"\nSessions can be interactions with the system or agent but they can be inferred e.g. from user activity\nSessions can also be abstract for example a daily diary can be an abstract session with the intent of capturing daily activity\nSessions can be hierarchical and moments can be generated from sessions.\n\nSessions model user intent.", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The name is a pseudo name to make sessions node-compatible", "title": "Name"}, "query": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "the question or context that triggered the session - query can be an intent and it can be inferred", "embedding_provider": "default", "title": "Query"}, "user_rating": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": null, "description": "We can in future rate sessions to learn what works", "title": "User Rating"}, "agent": {"default": "percolate", "description": "Percolate always expects an agent but we support passing a system prompt which we treat as anonymous agent", "title": "Agent", "type": "string"}, "parent_session_id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "A session is a thread from a question+prompt to completion. We span child sessions", "title": "Parent Session Id"}, "thread_id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "An id for a thread which can contain a number of sessions - thread matches are case insensitive ie.. MyID==myid - typically we prefer ids to be uuids but depends on the system", "title": "Thread Id"}, "channel_id": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The platform/channel ID through which the user is interacting (e.g., specific Slack channel ID)", "title": "Channel Id"}, "channel_type": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "percolate", "description": "The platform type (e.g., ''slack'', ''percolate'', ''email'') - the device info + the channel type tells if its mobile etc", "title": "Channel Type"}, "session_type": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "conversation", "description": "The type of session (e.g., ''conversation'', ''resource_management'', ''task_creation'', ''daily_digest'')", "title": "Session Type"}, "metadata": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "Arbitrary metadata - typically this is device info and other context", "title": "Metadata"}, "session_completed_at": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "An audit timestamp to write back the completion of the session - its optional as it should manage the last timestamp on the AI Responses for the session", "title": "Session Completed At"}, "graph_paths": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "Track all paths extracted by an agent as used to build the KG over user sessions", "title": "Graph Paths"}, "userid": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "The user id to use", "title": "Userid"}}, "required": ["id"], "title": "Session", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_entities (p8.Session)------
-- ------------------
select * from p8.register_entities('p8.Session');
-- ------------------

-- register_embeddings (p8.SessionEvaluation)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_SessionEvaluation_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_sessionevaluation
        FOREIGN KEY (source_record_id) REFERENCES p8."SessionEvaluation"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.SessionEvaluation)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', 'b4c7531a-ddd6-caab-93ab-4a3d9590ff7d', 'p8.SessionEvaluation', 'uuid.UUID | str', NULL, NULL, False),
 ('rating', '23cc5619-2221-1138-e0c5-fc6dd943ddec', 'p8.SessionEvaluation', 'float', NULL, 'A rating from 0 to 1 - binary thumb-up/thumbs-down are 0 or 1', False),
 ('comments', 'ffe523cf-a865-9ac9-6c31-76143e228d11', 'p8.SessionEvaluation', 'str', NULL, 'Additional feedback comments from the user', False),
 ('session_id', '9eefd921-809f-53ac-d3d9-3b2c4ee5e992', 'p8.SessionEvaluation', 'uuid.UUID | str', NULL, NULL, False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.SessionEvaluation)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.SessionEvaluation', '10f616fd-740a-5c9e-b77f-e099932428a2', NULL, '# Agent - p8.SessionEvaluation
Tracks groups if session dialogue
# Schema

```{''''description'''': ''''Tracks groups if session dialogue'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''rating'''': {''''default'''': None, ''''description'''': ''''A rating from 0 to 1 - binary thumb-up/thumbs-down are 0 or 1'''', ''''title'''': ''''Rating'''', ''''type'''': ''''number''''}, ''''comments'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Additional feedback comments from the user'''', ''''title'''': ''''Comments''''}, ''''session_id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Session Id''''}}, ''''required'''': [''''id'''', ''''session_id''''], ''''title'''': ''''SessionEvaluation'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Tracks groups if session dialogue", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "rating": {"default": null, "description": "A rating from 0 to 1 - binary thumb-up/thumbs-down are 0 or 1", "title": "Rating", "type": "number"}, "comments": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "Additional feedback comments from the user", "title": "Comments"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Session Id"}}, "required": ["id", "session_id"], "title": "SessionEvaluation", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '9a6c62f8-ec9f-b2a8-471e-293968cfc5ba', 'p8.AIResponse', 'uuid.UUID | str', NULL, NULL, False),
 ('model_name', '22bf53b3-4708-7eeb-fa11-a02d25eafc68', 'p8.AIResponse', 'str', NULL, NULL, False),
 ('tokens', '6e1f4c54-9874-ac54-8df0-15d8278d10c6', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed in total', False),
 ('tokens_in', '6533706a-7510-8bb6-d19c-04112530a006', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for input', False),
 ('tokens_out', '69d48123-4110-3677-c076-f95721671f4b', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for output', False),
 ('tokens_other', 'ff8dc4f2-24a7-b660-f7ac-726b8de21857', 'p8.AIResponse', 'int', NULL, 'the number of tokens consumed for functions and other metadata', False),
 ('session_id', '2fbd5e8b-5e3f-59e2-a7f8-ccc25e969f00', 'p8.AIResponse', 'str', NULL, 'Session id for a conversation', False),
 ('role', 'd2564a0a-9cec-01c2-7928-4c03424e77ce', 'p8.AIResponse', 'str', NULL, 'The role of the user/agent in the conversation', False),
 ('content', '66f7279c-aebf-d75d-6938-699fc2a08074', 'p8.AIResponse', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', False),
 ('status', '7553391b-4325-699c-2ddc-75e62e0055b7', 'p8.AIResponse', 'str', NULL, 'The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM_RESPONSE', False),
 ('tool_calls', '616befa2-4a8f-a966-6980-5bf0275767c4', 'p8.AIResponse', 'dict', NULL, 'Tool calls are requests from language models to call tools', False),
 ('tool_eval_data', '523e0ea7-ba61-5a74-bf54-fa7a163c5c84', 'p8.AIResponse', 'dict', NULL, 'The payload may store the eval from the tool especially if it is small data', False),
 ('verbatim', '8817d5ef-d702-a25f-c54b-8eef1375d1fa', 'p8.AIResponse', 'dict', NULL, 'the verbatim message from the language model - we dont serialize this', False),
 ('function_stack', '693b4a8b-4759-9261-fcba-48f38ce38d7c', 'p8.AIResponse', 'str', NULL, 'At each stage certain functions are available to the model - useful to see what it has and what it chooses and to reload stack later', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.AIResponse)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.AIResponse', '51b3aa20-195b-5ef3-82d1-df5ca8019146', NULL, '# Agent - p8.AIResponse
Each atom in an exchange between users, agents, assistants and so on. 
    We generate questions with sessions and then that triggers an exchange. 
    Normally the Dialogue is round trip transaction.
    
# Schema

```{''''description'''': ''''Each atom in an exchange between users, agents, assistants and so on. \nWe generate questions with sessions and then that triggers an exchange. \nNormally the Dialogue is round trip transaction.'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''model_name'''': {''''title'''': ''''Model Name'''', ''''type'''': ''''string''''}, ''''tokens'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed in total'''', ''''title'''': ''''Tokens''''}, ''''tokens_in'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for input'''', ''''title'''': ''''Tokens In''''}, ''''tokens_out'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for output'''', ''''title'''': ''''Tokens Out''''}, ''''tokens_other'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for functions and other metadata'''', ''''title'''': ''''Tokens Other''''}, ''''session_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Session id for a conversation'''', ''''title'''': ''''Session Id''''}, ''''role'''': {''''description'''': ''''The role of the user/agent in the conversation'''', ''''title'''': ''''Role'''', ''''type'''': ''''string''''}, ''''content'''': {''''description'''': ''''The content for this part of the conversation'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Content'''', ''''type'''': ''''string''''}, ''''status'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''description'''': ''''The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM_RESPONSE'''', ''''title'''': ''''Status''''}, ''''tool_calls'''': {''''anyOf'''': [{''''items'''': {''''additionalProperties'''': True, ''''type'''': ''''object''''}, ''''type'''': ''''array''''}, {''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Tool calls are requests from language models to call tools'''', ''''title'''': ''''Tool Calls''''}, ''''tool_eval_data'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The payload may store the eval from the tool especially if it is small data'''', ''''title'''': ''''Tool Eval Data''''}, ''''verbatim'''': {''''anyOf'''': [{''''items'''': {''''additionalProperties'''': True, ''''type'''': ''''object''''}, ''''type'''': ''''array''''}, {''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''the verbatim message from the language model - we dont serialize this'''', ''''title'''': ''''Verbatim''''}, ''''function_stack'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''At each stage certain functions are available to the model - useful to see what it has and what it chooses and to reload stack later'''', ''''title'''': ''''Function Stack''''}}, ''''required'''': [''''id'''', ''''model_name'''', ''''role'''', ''''content'''', ''''status''''], ''''title'''': ''''AIResponse'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Each atom in an exchange between users, agents, assistants and so on. \nWe generate questions with sessions and then that triggers an exchange. \nNormally the Dialogue is round trip transaction.", "properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model_name": {"title": "Model Name", "type": "string"}, "tokens": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed in total", "title": "Tokens"}, "tokens_in": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for input", "title": "Tokens In"}, "tokens_out": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for output", "title": "Tokens Out"}, "tokens_other": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for functions and other metadata", "title": "Tokens Other"}, "session_id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Session id for a conversation", "title": "Session Id"}, "role": {"description": "The role of the user/agent in the conversation", "title": "Role", "type": "string"}, "content": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Content", "type": "string"}, "status": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "The status of the session such as REQUEST|RESPONSE|ERROR|TOOL_CALL|STREAM_RESPONSE", "title": "Status"}, "tool_calls": {"anyOf": [{"items": {"additionalProperties": true, "type": "object"}, "type": "array"}, {"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "description": "Tool calls are requests from language models to call tools", "title": "Tool Calls"}, "tool_eval_data": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "description": "The payload may store the eval from the tool especially if it is small data", "title": "Tool Eval Data"}, "verbatim": {"anyOf": [{"items": {"additionalProperties": true, "type": "object"}, "type": "array"}, {"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "description": "the verbatim message from the language model - we dont serialize this", "title": "Verbatim"}, "function_stack": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "At each stage certain functions are available to the model - useful to see what it has and what it chooses and to reload stack later", "title": "Function Stack"}}, "required": ["id", "model_name", "role", "content", "status"], "title": "AIResponse", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '0aaf8061-daa1-e703-3fd3-44a2f9614a73', 'p8.ApiProxy', 'str', NULL, 'A unique api friendly name', False),
 ('id', '50559701-15b9-9a18-d72e-3b94b3cf4ef5', 'p8.ApiProxy', 'str', NULL, 'Will default to a hash of the uri', False),
 ('proxy_uri', '22b85ade-0649-65cc-c734-56219d71ff26', 'p8.ApiProxy', 'str', NULL, 'a reference to an api or library namespace that qualifies the named function', False),
 ('token', 'a0e190ea-14c2-9a57-22ba-208fdcb376bb', 'p8.ApiProxy', 'str', NULL, 'the token to save', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.ApiProxy)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.ApiProxy', '6b6e9a0d-725f-5360-9bd6-059583e0ece5', NULL, '# Agent - p8.ApiProxy
A list of proxies or APIs that have attached functions or endpoints - links to proxy_uri on the Function
# Schema

```{''''description'''': ''''A list of proxies or APIs that have attached functions or endpoints - links to proxy_uri on the Function'''', ''''properties'''': {''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A unique api friendly name'''', ''''title'''': ''''Name''''}, ''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Will default to a hash of the uri'''', ''''title'''': ''''Id''''}, ''''proxy_uri'''': {''''description'''': ''''a reference to an api or library namespace that qualifies the named function'''', ''''title'''': ''''Proxy Uri'''', ''''type'''': ''''string''''}, ''''token'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''the token to save'''', ''''title'''': ''''Token''''}}, ''''required'''': [''''proxy_uri''''], ''''title'''': ''''ApiProxy'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "A list of proxies or APIs that have attached functions or endpoints - links to proxy_uri on the Function", "properties": {"name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A unique api friendly name", "title": "Name"}, "id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Will default to a hash of the uri", "title": "Id"}, "proxy_uri": {"description": "a reference to an api or library namespace that qualifies the named function", "title": "Proxy Uri", "type": "string"}, "token": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "the token to save", "title": "Token"}}, "required": ["proxy_uri"], "title": "ApiProxy", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '9066815e-5f03-827c-ecfd-126771fc1013', 'p8.PlanModel', 'str', NULL, 'An id for the plan - better to set this but we can add them uniquely to users and sessions to', False),
 ('name', '136f4a8e-db0d-6d98-8c8c-cc668d7a46bb', 'p8.PlanModel', 'str', NULL, 'The unique name of the plan node', False),
 ('plan_description', '8ecc2c08-656e-56be-1f93-90c23f3e8796', 'p8.PlanModel', 'str', NULL, 'The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages', False),
 ('questions', '5295f770-b57a-cb89-5777-2a4fdff08676', 'p8.PlanModel', 'str', NULL, 'The question in this plan instance as the user would ask it. A plan can be constructed without a clear question', False),
 ('extra_arguments', '50a66858-d6ab-fe76-100e-f300461e3be4', 'p8.PlanModel', 'dict', NULL, 'Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context', False),
 ('functions', '38313137-8542-1173-b7bf-c20255bb204b', 'p8.PlanModel', 'PlanFunctions', NULL, 'A collection of functions designed for use with this context', False),
 ('depends', 'afb64262-8f49-c534-5dc6-525980cff6ce', 'p8.PlanModel', 'PlanModel', NULL, 'A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans', False),
 ('userid', '0e9b50b8-55d5-5aa2-69dd-f130e98f4bf8', 'p8.PlanModel', 'str', NULL, 'A user that owns the plan', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.PlanModel)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.PlanModel', '4114d88d-fc85-56d9-a927-e7028b3cff8a', NULL, '# Agent - p8.PlanModel

    You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.
    Respond to the caller only with the context you ascertain from the data you are given.
    You should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.
    Observe where there are dependencies between functions
    
# Schema

```{''''$defs'''': {''''PlanFunctions'''': {''''properties'''': {''''name'''': {''''description'''': ''''fully qualified function name e.g. <namespace>_<name>'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''description'''': {''''description'''': ''''a description of the function preferably with the current context taken into account e.g. provide good example parameters'''', ''''title'''': ''''Description'''', ''''type'''': ''''string''''}, ''''rating'''': {''''description'''': ''''a rating from 0 to 100 for how useful this function should be in context'''', ''''title'''': ''''Rating'''', ''''type'''': ''''number''''}}, ''''required'''': [''''name'''', ''''description'''', ''''rating''''], ''''title'''': ''''PlanFunctions'''', ''''type'''': ''''object''''}, ''''PlanModel'''': {''''description'''': ''''You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.\nRespond to the caller only with the context you ascertain from the data you are given.\nYou should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.\nObserve where there are dependencies between functions'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An id for the plan - better to set this but we can add them uniquely to users and sessions to'''', ''''title'''': ''''Id''''}, ''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The unique name of the plan node'''', ''''title'''': ''''Name''''}, ''''plan_description'''': {''''description'''': ''''The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages'''', ''''title'''': ''''Plan Description'''', ''''type'''': ''''string''''}, ''''questions'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The question in this plan instance as the user would ask it. A plan can be constructed without a clear question'''', ''''title'''': ''''Questions''''}, ''''extra_arguments'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context'''', ''''title'''': ''''Extra Arguments''''}, ''''functions'''': {''''anyOf'''': [{''''items'''': {''''$ref'''': ''''#/$defs/PlanFunctions''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A collection of functions designed for use with this context'''', ''''title'''': ''''Functions''''}, ''''depends'''': {''''anyOf'''': [{''''items'''': {''''$ref'''': ''''#/$defs/PlanModel''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans'''', ''''title'''': ''''Depends''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A user that owns the plan'''', ''''title'''': ''''Userid''''}}, ''''required'''': [''''plan_description''''], ''''title'''': ''''PlanModel'''', ''''type'''': ''''object''''}}, ''''$ref'''': ''''#/$defs/PlanModel''''}``` 

# Functions
 ```
None```
            ', '{"$defs": {"PlanFunctions": {"properties": {"name": {"description": "fully qualified function name e.g. <namespace>_<name>", "title": "Name", "type": "string"}, "description": {"description": "a description of the function preferably with the current context taken into account e.g. provide good example parameters", "title": "Description", "type": "string"}, "rating": {"description": "a rating from 0 to 100 for how useful this function should be in context", "title": "Rating", "type": "number"}}, "required": ["name", "description", "rating"], "title": "PlanFunctions", "type": "object"}, "PlanModel": {"description": "You are an agent that plans function calling and agent resources for other agents but you do not call functions yourself.\nRespond to the caller only with the context you ascertain from the data you are given.\nYou should construct a Directed Acyclic Graph (RAG) of one or more functions that can be called.\nObserve where there are dependencies between functions", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "An id for the plan - better to set this but we can add them uniquely to users and sessions to", "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The unique name of the plan node", "title": "Name"}, "plan_description": {"description": "The plan to prompt the agent - should provide fully strategy and explain what dependencies exist with other stages", "title": "Plan Description", "type": "string"}, "questions": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "The question in this plan instance as the user would ask it. A plan can be constructed without a clear question", "title": "Questions"}, "extra_arguments": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": null, "description": "Placeholder/hint for extra parameters that should be passed from previous stages such as data or identifiers that were discovered in the data and expected by the function either as a parameter or important context", "title": "Extra Arguments"}, "functions": {"anyOf": [{"items": {"$ref": "#/$defs/PlanFunctions"}, "type": "array"}, {"type": "null"}], "default": null, "description": "A collection of functions designed for use with this context", "title": "Functions"}, "depends": {"anyOf": [{"items": {"$ref": "#/$defs/PlanModel"}, "type": "array"}, {"type": "null"}], "default": null, "description": "A dependency graph - plans can be chained into waves of functions that can be called in parallel or one after the other. Data dependencies are injected to downstream plans", "title": "Depends"}, "userid": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A user that owns the plan", "title": "Userid"}}, "required": ["plan_description"], "title": "PlanModel", "type": "object"}}, "$ref": "#/$defs/PlanModel"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '0fb87392-0069-a817-c23a-6635bf8f88cc', 'p8.Settings', 'str', NULL, NULL, False),
 ('key', '1fe28f72-8290-516e-7343-b39537707183', 'p8.Settings', 'str', NULL, NULL, False),
 ('value', 'b39ca6ff-a90d-3678-b658-b81e5ecb0801', 'p8.Settings', 'str', NULL, 'Value of the setting', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Settings)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Settings', '15713970-16d5-5ce6-a5d5-f0c643da7834', NULL, '# Agent - p8.Settings
settings are key value pairs for percolate admin
# Schema

```{''''description'''': ''''settings are key value pairs for percolate admin'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''The id is generated as a hash of the required key and ordinal. The id must be in a UUID format or can be left blank'''', ''''title'''': ''''Id''''}, ''''key'''': {''''default'''': ''''The key for the value to store - id is generated form this'''', ''''title'''': ''''Key'''', ''''type'''': ''''string''''}, ''''value'''': {''''description'''': ''''Value of the setting'''', ''''title'''': ''''Value'''', ''''type'''': ''''string''''}}, ''''required'''': [''''value''''], ''''title'''': ''''Settings'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "settings are key value pairs for percolate admin", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": "The id is generated as a hash of the required key and ordinal. The id must be in a UUID format or can be left blank", "title": "Id"}, "key": {"default": "The key for the value to store - id is generated form this", "title": "Key", "type": "string"}, "value": {"description": "Value of the setting", "title": "Value", "type": "string"}}, "required": ["value"], "title": "Settings", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '0ebafb1a-2786-9ab1-172a-895ccb42998f', 'p8.PercolateAgent', 'str', NULL, NULL, False),
 ('name', '30512d9f-f547-34a6-f078-5345e8e09ba5', 'p8.PercolateAgent', 'str', NULL, 'A short content name - non unique - for example a friendly label for a chunked pdf document or web page title', False),
 ('category', '76bdaf66-f79e-7594-5b05-cdef07866428', 'p8.PercolateAgent', 'str', NULL, 'A content category', False),
 ('content', 'def5e0a1-4ba2-491e-a91f-9282a41e46e4', 'p8.PercolateAgent', 'str', 'text-embedding-ada-002', 'The chunk of content from the source', False),
 ('summary', '5ec58fc6-908f-b0ef-eb09-59052ba149a0', 'p8.PercolateAgent', 'str', NULL, 'An optional summary', False),
 ('ordinal', 'bf43af13-19d5-2fe7-9806-ee6191f6f02c', 'p8.PercolateAgent', 'int', NULL, 'For chunked content we can keep an ordinal', False),
 ('uri', '85667f3d-de55-67ab-47bc-1e056f397466', 'p8.PercolateAgent', 'str', NULL, NULL, False),
 ('metadata', '771a5a28-65de-0ba9-34a4-258fd041c3a6', 'p8.PercolateAgent', 'dict', NULL, NULL, False),
 ('graph_paths', '0efd55d6-ba88-c002-0013-0f3a54f7aa2d', 'p8.PercolateAgent', 'str', NULL, 'Track all paths extracted by an agent as used to build the KG', False),
 ('resource_timestamp', '98c87391-247a-0d88-6604-8e6be7fe812b', 'p8.PercolateAgent', 'datetime', NULL, 'the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log', False),
 ('userid', 'bb7ca212-29db-c9fb-0198-1fcdaed560a4', 'p8.PercolateAgent', 'str', NULL, 'The user id is a system field but if we need to control the user context this is how we do it', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.PercolateAgent)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.PercolateAgent', '87236bdd-36bd-5de2-8933-4e437bd69610', NULL, '# Agent - p8.PercolateAgent
The percolate agent is the guy that tells you about Percolate which is a multi-modal database for managing AI in the data tier.
    You can learn about the philosophy of Percolate or ask questions about the docs and codebase.
    You can lookup entities of different types or plan queries and searches.
    You can call any registered apis and functions and learn more about how they can be used.
    Call the search function to get data about Percolate
    Only use ''''search'''' if you are asked questions specifically about Percolate otherwise call for help!
    If you do a search and you do not find any data related to the user question you should ALWAYS ask for help to dig deeper.
    
# Schema

```{''''description'''': "The percolate agent is the guy that tells you about Percolate which is a multi-modal database for managing AI in the data tier.\nYou can learn about the philosophy of Percolate or ask questions about the docs and codebase.\nYou can lookup entities of different types or plan queries and searches.\nYou can call any registered apis and functions and learn more about how they can be used.\nCall the search function to get data about Percolate\nOnly use ''''search'''' if you are asked questions specifically about Percolate otherwise call for help!\nIf you do a search and you do not find any data related to the user question you should ALWAYS ask for help to dig deeper.", ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''The id is generated as a hash of the required uri and ordinal'''', ''''title'''': ''''Id''''}, ''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A short content name - non unique - for example a friendly label for a chunked pdf document or web page title'''', ''''title'''': ''''Name''''}, ''''category'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A content category'''', ''''title'''': ''''Category''''}, ''''content'''': {''''description'''': ''''The chunk of content from the source'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Content'''', ''''type'''': ''''string''''}, ''''summary'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An optional summary'''', ''''title'''': ''''Summary''''}, ''''ordinal'''': {''''default'''': 0, ''''description'''': ''''For chunked content we can keep an ordinal'''', ''''title'''': ''''Ordinal'''', ''''type'''': ''''integer''''}, ''''uri'''': {''''default'''': ''''An external source or content ref e.g. a PDF file on blob storage or public URI'''', ''''title'''': ''''Uri'''', ''''type'''': ''''string''''}, ''''metadata'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': {}, ''''title'''': ''''Metadata''''}, ''''graph_paths'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Track all paths extracted by an agent as used to build the KG'''', ''''title'''': ''''Graph Paths''''}, ''''resource_timestamp'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log'''', ''''title'''': ''''Resource Timestamp''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The user id is a system field but if we need to control the user context this is how we do it'''', ''''title'''': ''''Userid''''}}, ''''required'''': [''''content''''], ''''title'''': ''''PercolateAgent'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "The percolate agent is the guy that tells you about Percolate which is a multi-modal database for managing AI in the data tier.\nYou can learn about the philosophy of Percolate or ask questions about the docs and codebase.\nYou can lookup entities of different types or plan queries and searches.\nYou can call any registered apis and functions and learn more about how they can be used.\nCall the search function to get data about Percolate\nOnly use ''search'' if you are asked questions specifically about Percolate otherwise call for help!\nIf you do a search and you do not find any data related to the user question you should ALWAYS ask for help to dig deeper.", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": "The id is generated as a hash of the required uri and ordinal", "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A short content name - non unique - for example a friendly label for a chunked pdf document or web page title", "title": "Name"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A content category", "title": "Category"}, "content": {"description": "The chunk of content from the source", "embedding_provider": "default", "title": "Content", "type": "string"}, "summary": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "An optional summary", "title": "Summary"}, "ordinal": {"default": 0, "description": "For chunked content we can keep an ordinal", "title": "Ordinal", "type": "integer"}, "uri": {"default": "An external source or content ref e.g. a PDF file on blob storage or public URI", "title": "Uri", "type": "string"}, "metadata": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": {}, "title": "Metadata"}, "graph_paths": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "Track all paths extracted by an agent as used to build the KG", "title": "Graph Paths"}, "resource_timestamp": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log", "title": "Resource Timestamp"}, "userid": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "The user id is a system field but if we need to control the user context this is how we do it", "title": "Userid"}}, "required": ["content"], "title": "PercolateAgent", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
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
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '8c15a299-76fd-632c-8575-a56f526609ec', 'p8.IndexAudit', 'uuid.UUID | str', NULL, NULL, False),
 ('model_name', '64543448-82b9-cded-b09e-90a2abb5af43', 'p8.IndexAudit', 'str', NULL, NULL, False),
 ('tokens', 'a973c585-5838-b56f-51ba-3dff1fc54cd7', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed in total', False),
 ('tokens_in', 'efbf4ad1-7003-71d8-52cf-269f2ece27fa', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for input', False),
 ('tokens_out', '63fc340b-e797-fe4a-c7b3-ff3a20e7d2d2', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for output', False),
 ('tokens_other', '8fe965f6-f95f-d5ed-a369-ad62d6612197', 'p8.IndexAudit', 'int', NULL, 'the number of tokens consumed for functions and other metadata', False),
 ('session_id', 'e1d39dd8-33ac-9171-fc97-c20984e66dec', 'p8.IndexAudit', 'str', NULL, 'Session id for a conversation', False),
 ('metrics', '1ecd69ca-ba02-798a-2893-233679c6e77f', 'p8.IndexAudit', 'dict', NULL, 'metrics for records indexed', False),
 ('status', 'c51fb8af-3ada-8ed1-7b32-dcb0087e68ba', 'p8.IndexAudit', 'str', NULL, 'Status code such as OK|ERROR', False),
 ('message', 'e36d7fcd-5d80-667b-a446-07cc0afc46bb', 'p8.IndexAudit', 'str', NULL, 'Any message such as an error', False),
 ('entity_full_name', '3a3f3596-e43f-a865-e86b-81fc91d38aa1', 'p8.IndexAudit', 'str', NULL, NULL, False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.IndexAudit)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.IndexAudit', '244fd1ca-a425-5c5b-9606-178c4df7026d', NULL, '# Agent - p8.IndexAudit
p8.IndexAudit
# Schema

```{''''properties'''': {''''id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''title'''': ''''Id''''}, ''''model_name'''': {''''title'''': ''''Model Name'''', ''''type'''': ''''string''''}, ''''tokens'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed in total'''', ''''title'''': ''''Tokens''''}, ''''tokens_in'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for input'''', ''''title'''': ''''Tokens In''''}, ''''tokens_out'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for output'''', ''''title'''': ''''Tokens Out''''}, ''''tokens_other'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 0, ''''description'''': ''''the number of tokens consumed for functions and other metadata'''', ''''title'''': ''''Tokens Other''''}, ''''session_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Session id for a conversation'''', ''''title'''': ''''Session Id''''}, ''''metrics'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''metrics for records indexed'''', ''''title'''': ''''Metrics''''}, ''''status'''': {''''description'''': ''''Status code such as OK|ERROR'''', ''''title'''': ''''Status'''', ''''type'''': ''''string''''}, ''''message'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''description'''': ''''Any message such as an error'''', ''''title'''': ''''Message''''}, ''''entity_full_name'''': {''''title'''': ''''Entity Full Name'''', ''''type'''': ''''string''''}}, ''''required'''': [''''id'''', ''''model_name'''', ''''status'''', ''''message'''', ''''entity_full_name''''], ''''title'''': ''''IndexAudit'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"properties": {"id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "title": "Id"}, "model_name": {"title": "Model Name", "type": "string"}, "tokens": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed in total", "title": "Tokens"}, "tokens_in": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for input", "title": "Tokens In"}, "tokens_out": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for output", "title": "Tokens Out"}, "tokens_other": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 0, "description": "the number of tokens consumed for functions and other metadata", "title": "Tokens Other"}, "session_id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Session id for a conversation", "title": "Session Id"}, "metrics": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "metrics for records indexed", "title": "Metrics"}, "status": {"description": "Status code such as OK|ERROR", "title": "Status", "type": "string"}, "message": {"anyOf": [{"type": "string"}, {"type": "null"}], "description": "Any message such as an error", "title": "Message"}, "entity_full_name": {"title": "Entity Full Name", "type": "string"}}, "required": ["id", "model_name", "status", "message", "entity_full_name"], "title": "IndexAudit", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_embeddings (p8.Task)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Task_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_task
        FOREIGN KEY (source_record_id) REFERENCES p8."Task"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Task)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('name', '13588c48-c765-a64f-bbd9-944bf4cf86fb', 'p8.Task', 'str', NULL, 'The name of the entity e.g. a model in the types or a user defined model', False),
 ('id', '143b8113-d349-3133-0d8c-718b216a50f8', 'p8.Task', 'str', NULL, 'id generated for the name and project - these must be unique or they are overwritten', False),
 ('description', '2e386ca4-95ca-4139-d7ed-ad71d9a3768d', 'p8.Task', 'str', 'text-embedding-ada-002', 'The content for this part of the conversation', False),
 ('target_date', 'cd8f0166-52df-cc84-70cf-a2aa323cd1be', 'p8.Task', 'datetime', NULL, 'Optional target date', False),
 ('collaborator_ids', 'e4602741-ea1f-b1aa-214e-7524494de0ad', 'p8.Task', 'UUID', NULL, 'Users collaborating on this project', False),
 ('status', '11d0da18-6f30-9ed1-43b4-1d987349a08f', 'p8.Task', 'str', NULL, 'Project status', False),
 ('priority', 'e6d206c9-8769-cd58-6765-70a691e06646', 'p8.Task', 'int', NULL, 'Priority level (1-5), 1 being the highest priority', False),
 ('project_name', 'bfb6c6e9-6fd2-5140-db91-58ad3e7d800c', 'p8.Task', 'str', NULL, 'The related project name if relevant', False),
 ('estimated_effort', 'b192162e-c38a-87c2-4df7-76d79edeeeae', 'p8.Task', 'float', NULL, 'Estimated effort in hours', False),
 ('progress', '96388862-0834-f186-3f07-958e71cb6560', 'p8.Task', 'float', NULL, 'Completion progress (0-1)', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Task)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Task', 'bee70821-5685-5312-b53a-87a12abb0260', NULL, '# Agent - p8.Task
Tasks are sub projects. A project can describe a larger objective and be broken down into tasks.
If if you need to do research or you are asked to search or create a research iteration/plan for world knowledge searches you MUST ask the _ResearchIteration agent_ to help perform the research on your behalf (you can request this agent with the help i.e. ask for an agent by name). 
You should be clear when relaying the users request. If the user asks to construct a plan, you should ask the agent to construct a plan. If the user asks to search, you should ask the research agent to execute  a web search.
If the user asks to look for existing plans, you should ask the research agent to search research plans.
    
# Schema

```{''''description'''': ''''Tasks are sub projects. A project can describe a larger objective and be broken down into tasks.\nIf if you need to do research or you are asked to search or create a research iteration/plan for world knowledge searches you MUST ask the _ResearchIteration agent_ to help perform the research on your behalf (you can request this agent with the help i.e. ask for an agent by name). \nYou should be clear when relaying the users request. If the user asks to construct a plan, you should ask the agent to construct a plan. If the user asks to search, you should ask the research agent to execute  a web search.\nIf the user asks to look for existing plans, you should ask the research agent to search research plans.\n    '''', ''''properties'''': {''''name'''': {''''description'''': ''''The name of the entity e.g. a model in the types or a user defined model'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''id generated for the name and project - these must be unique or they are overwritten'''', ''''title'''': ''''Id''''}, ''''description'''': {''''description'''': ''''The content for this part of the conversation'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Description'''', ''''type'''': ''''string''''}, ''''target_date'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Optional target date'''', ''''title'''': ''''Target Date''''}, ''''collaborator_ids'''': {''''description'''': ''''Users collaborating on this project'''', ''''items'''': {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, ''''title'''': ''''Collaborator Ids'''', ''''type'''': ''''array''''}, ''''status'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''active'''', ''''description'''': ''''Project status'''', ''''title'''': ''''Status''''}, ''''priority'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 1, ''''description'''': ''''Priority level (1-5), 1 being the highest priority'''', ''''title'''': ''''Priority''''}, ''''project_name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The related project name if relevant'''', ''''title'''': ''''Project Name''''}, ''''estimated_effort'''': {''''anyOf'''': [{''''type'''': ''''number''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Estimated effort in hours'''', ''''title'''': ''''Estimated Effort''''}, ''''progress'''': {''''anyOf'''': [{''''type'''': ''''number''''}, {''''type'''': ''''null''''}], ''''default'''': 0.0, ''''description'''': ''''Completion progress (0-1)'''', ''''title'''': ''''Progress''''}}, ''''required'''': [''''name'''', ''''description''''], ''''title'''': ''''Task'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
{''''post_tasks_'''': ''''Used to save tasks by posting the task object. Its good practice to first search for a task of a similar name before saving in case of duplicates''''}```
            ', '{"description": "Tasks are sub projects. A project can describe a larger objective and be broken down into tasks.\nIf if you need to do research or you are asked to search or create a research iteration/plan for world knowledge searches you MUST ask the _ResearchIteration agent_ to help perform the research on your behalf (you can request this agent with the help i.e. ask for an agent by name). \nYou should be clear when relaying the users request. If the user asks to construct a plan, you should ask the agent to construct a plan. If the user asks to search, you should ask the research agent to execute  a web search.\nIf the user asks to look for existing plans, you should ask the research agent to search research plans.\n    ", "properties": {"name": {"description": "The name of the entity e.g. a model in the types or a user defined model", "title": "Name", "type": "string"}, "id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "id generated for the name and project - these must be unique or they are overwritten", "title": "Id"}, "description": {"description": "The content for this part of the conversation", "embedding_provider": "default", "title": "Description", "type": "string"}, "target_date": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Optional target date", "title": "Target Date"}, "collaborator_ids": {"description": "Users collaborating on this project", "items": {"format": "uuid", "type": "string"}, "title": "Collaborator Ids", "type": "array"}, "status": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": "active", "description": "Project status", "title": "Status"}, "priority": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 1, "description": "Priority level (1-5), 1 being the highest priority", "title": "Priority"}, "project_name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The related project name if relevant", "title": "Project Name"}, "estimated_effort": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": null, "description": "Estimated effort in hours", "title": "Estimated Effort"}, "progress": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": 0.0, "description": "Completion progress (0-1)", "title": "Progress"}}, "required": ["name", "description"], "title": "Task", "type": "object"}', '{"post_tasks_": "Used to save tasks by posting the task object. Its good practice to first search for a task of a similar name before saving in case of duplicates"}')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_entities (p8.Task)------
-- ------------------
select * from p8.register_entities('p8.Task');
-- ------------------

-- register_embeddings (p8.TaskResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_TaskResources_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_taskresources
        FOREIGN KEY (source_record_id) REFERENCES p8."TaskResources"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.TaskResources)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', 'dc8d5978-927c-652b-7837-4cee69428b83', 'p8.TaskResources', 'str', NULL, 'unique id for rel', False),
 ('resource_id', '2a2ec07c-84c2-2a05-4fd5-9b4a3886540e', 'p8.TaskResources', 'uuid.UUID | str', NULL, NULL, False),
 ('session_id', '88c0bf07-4c3a-438c-4778-716de371de0b', 'p8.TaskResources', 'uuid.UUID | str', NULL, NULL, False),
 ('user_metadata', '31d1428d-66fa-1dc4-2a47-442a7692e74a', 'p8.TaskResources', 'dict', NULL, 'User-specific metadata for this resource', False),
 ('relevance_score', '1c7a0a43-e1fb-9b1e-0143-546e46fa094c', 'p8.TaskResources', 'float', NULL, 'How relevant this resource is to the session', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.TaskResources)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.TaskResources', '08e43647-3fb3-555f-adb7-ce64bad1a473', NULL, '# Agent - p8.TaskResources
(Deprecate)A link between tasks and resources since resources can be shared between tasks
# Schema

```{''''description'''': ''''(Deprecate)A link between tasks and resources since resources can be shared between tasks'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''unique id for rel'''', ''''title'''': ''''Id''''}, ''''resource_id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''default'''': ''''The resource id'''', ''''title'''': ''''Resource Id''''}, ''''session_id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''default'''': ''''The session id is typically a task or research iteration but can be any session id to group resources'''', ''''title'''': ''''Session Id''''}, ''''user_metadata'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''User-specific metadata for this resource'''', ''''title'''': ''''User Metadata''''}, ''''relevance_score'''': {''''anyOf'''': [{''''type'''': ''''number''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''How relevant this resource is to the session'''', ''''title'''': ''''Relevance Score''''}}, ''''title'''': ''''TaskResources'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "(Deprecate)A link between tasks and resources since resources can be shared between tasks", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "unique id for rel", "title": "Id"}, "resource_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "default": "The resource id", "title": "Resource Id"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "default": "The session id is typically a task or research iteration but can be any session id to group resources", "title": "Session Id"}, "user_metadata": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "User-specific metadata for this resource", "title": "User Metadata"}, "relevance_score": {"anyOf": [{"type": "number"}, {"type": "null"}], "default": null, "description": "How relevant this resource is to the session", "title": "Relevance Score"}}, "title": "TaskResources", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_embeddings (p8.ResearchIteration)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_ResearchIteration_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_researchiteration
        FOREIGN KEY (source_record_id) REFERENCES p8."ResearchIteration"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.ResearchIteration)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '4f4a91fc-85e9-2de4-66e5-1a81b9b96723', 'p8.ResearchIteration', 'str', NULL, 'unique id for rel', False),
 ('iteration', '532ee61f-1fe8-27b9-0059-2d3f81287448', 'p8.ResearchIteration', 'int', NULL, NULL, False),
 ('content', '49d54ee3-f546-492f-559a-64e1dfe2ba2f', 'p8.ResearchIteration', 'str', 'text-embedding-ada-002', 'An optional summary of the results discovered', False),
 ('conceptual_diagram', 'f0de36c3-ebc8-c87f-4989-6d9c3670232e', 'p8.ResearchIteration', 'str', NULL, 'The mermaid diagram for the plan - typically generated in advanced of doing a search', False),
 ('question_set', '8dec436c-0d29-f361-e3dc-38a96c845ff1', 'p8.ResearchIteration', '_QuestionSet', NULL, 'a set of questions and their ids from the conceptual diagram', False),
 ('task_id', '49d300f3-dfbb-0774-9488-6e28e03b0e07', 'p8.ResearchIteration', 'str', NULL, 'Research are linked to tasks which are at minimum a question', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.ResearchIteration)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.ResearchIteration', '3166721c-bc69-5413-8355-d6655488e9bc', NULL, '# Agent - p8.ResearchIteration

    Your job is to use functions to execute research tasks. You do not search for answers directly, you post a research tasks to generate data.
    A research iteration is a plan to deal with a task.     
    If you are asked for a plan you should first use your json structure to create a plan and give it to the user.

    1. if you are asked to information on general topics, you should execute the post_tasks_research_execute
    2. if you are asked about other research iterations only then can you use the _search_ method which is designed to search research plans as opposed to actually search for general information.
    
    You can generate conceptual diagrams using mermaid diagrams to provide an overview of the research plan.
    When you generate a conceptual plan you should link question sets to plans for example each question should have labels that link to part of the conceptual diagram using the mermaid diagram format to describe your plan.
    
# Schema

```{''''$defs'''': {''''_QuestionSet'''': {''''properties'''': {''''query'''': {''''description'''': ''''The question/query to search'''', ''''title'''': ''''Query'''', ''''type'''': ''''string''''}, ''''concept_keys'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''description'''': ''''A list of codes related to the concept diagram matching questions to the research structure'''', ''''title'''': ''''Concept Keys''''}}, ''''required'''': [''''query''''], ''''title'''': ''''_QuestionSet'''', ''''type'''': ''''object''''}}, ''''description'''': ''''Your job is to use functions to execute research tasks. You do not search for answers directly, you post a research tasks to generate data.\nA research iteration is a plan to deal with a task.     \nIf you are asked for a plan you should first use your json structure to create a plan and give it to the user.\n\n1. if you are asked to information on general topics, you should execute the post_tasks_research_execute\n2. if you are asked about other research iterations only then can you use the _search_ method which is designed to search research plans as opposed to actually search for general information.\n\nYou can generate conceptual diagrams using mermaid diagrams to provide an overview of the research plan.\nWhen you generate a conceptual plan you should link question sets to plans for example each question should have labels that link to part of the conceptual diagram using the mermaid diagram format to describe your plan.'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''unique id for rel'''', ''''title'''': ''''Id''''}, ''''iteration'''': {''''title'''': ''''Iteration'''', ''''type'''': ''''integer''''}, ''''content'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An optional summary of the results discovered'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Content''''}, ''''conceptual_diagram'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The mermaid diagram for the plan - typically generated in advanced of doing a search'''', ''''title'''': ''''Conceptual Diagram''''}, ''''question_set'''': {''''description'''': ''''a set of questions and their ids from the conceptual diagram'''', ''''items'''': {''''$ref'''': ''''#/$defs/_QuestionSet''''}, ''''title'''': ''''Question Set'''', ''''type'''': ''''array''''}, ''''task_id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Research are linked to tasks which are at minimum a question'''', ''''title'''': ''''Task Id''''}}, ''''required'''': [''''iteration'''', ''''question_set''''], ''''title'''': ''''ResearchIteration'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
{''''post_tasks_research_execute'''': ''''post the ResearchIteration object to the endpoint to execute a research plan.''''}```
            ', '{"$defs": {"_QuestionSet": {"properties": {"query": {"description": "The question/query to search", "title": "Query", "type": "string"}, "concept_keys": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "description": "A list of codes related to the concept diagram matching questions to the research structure", "title": "Concept Keys"}}, "required": ["query"], "title": "_QuestionSet", "type": "object"}}, "description": "Your job is to use functions to execute research tasks. You do not search for answers directly, you post a research tasks to generate data.\nA research iteration is a plan to deal with a task.     \nIf you are asked for a plan you should first use your json structure to create a plan and give it to the user.\n\n1. if you are asked to information on general topics, you should execute the post_tasks_research_execute\n2. if you are asked about other research iterations only then can you use the _search_ method which is designed to search research plans as opposed to actually search for general information.\n\nYou can generate conceptual diagrams using mermaid diagrams to provide an overview of the research plan.\nWhen you generate a conceptual plan you should link question sets to plans for example each question should have labels that link to part of the conceptual diagram using the mermaid diagram format to describe your plan.", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "unique id for rel", "title": "Id"}, "iteration": {"title": "Iteration", "type": "integer"}, "content": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "An optional summary of the results discovered", "embedding_provider": "default", "title": "Content"}, "conceptual_diagram": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "The mermaid diagram for the plan - typically generated in advanced of doing a search", "title": "Conceptual Diagram"}, "question_set": {"description": "a set of questions and their ids from the conceptual diagram", "items": {"$ref": "#/$defs/_QuestionSet"}, "title": "Question Set", "type": "array"}, "task_id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Research are linked to tasks which are at minimum a question", "title": "Task Id"}}, "required": ["iteration", "question_set"], "title": "ResearchIteration", "type": "object"}', '{"post_tasks_research_execute": "post the ResearchIteration object to the endpoint to execute a research plan."}')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_embeddings (p8.Resources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Resources_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_resources
        FOREIGN KEY (source_record_id) REFERENCES p8."Resources"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Resources)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '9f830929-a07e-1490-3517-082d19d1727f', 'p8.Resources', 'str', NULL, NULL, False),
 ('name', '91a835ac-6763-b001-0ec3-52dc955a0c29', 'p8.Resources', 'str', NULL, 'A short content name - non unique - for example a friendly label for a chunked pdf document or web page title', False),
 ('category', '165b037c-a6fd-be3a-e7f2-f427e005e34e', 'p8.Resources', 'str', NULL, 'A content category', False),
 ('content', '441524bd-7858-aeee-e3b1-7b026685638a', 'p8.Resources', 'str', 'text-embedding-ada-002', 'The chunk of content from the source', False),
 ('summary', 'b7d7dde5-eae3-7788-bdbc-bd230117ef44', 'p8.Resources', 'str', NULL, 'An optional summary', False),
 ('ordinal', 'fee2578b-eaa7-a5b2-071c-6305a07c177d', 'p8.Resources', 'int', NULL, 'For chunked content we can keep an ordinal', False),
 ('uri', 'cc4de245-7b87-232f-8800-b077c30e38dd', 'p8.Resources', 'str', NULL, NULL, False),
 ('metadata', '872374fa-bc59-6e8d-9dff-b919e09a101d', 'p8.Resources', 'dict', NULL, NULL, False),
 ('graph_paths', '5f13d4a9-34c8-9756-06f7-5a4fd0787201', 'p8.Resources', 'str', NULL, 'Track all paths extracted by an agent as used to build the KG', False),
 ('resource_timestamp', 'f3b0381b-c9d9-068b-d586-b7d4227baf09', 'p8.Resources', 'datetime', NULL, 'the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log', False),
 ('userid', 'c9ed1b72-e508-2702-3cc3-a837b9075c72', 'p8.Resources', 'str', NULL, 'The user id is a system field but if we need to control the user context this is how we do it', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Resources)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Resources', '65f85c8a-cf12-58c8-a7c3-c1e39c302fa9', NULL, '# Agent - p8.Resources
Generic parsed content from files, sites etc. added to the system.
    If someone asks about resources, content, files, general information etc. it may be worth doing a search on the Resources.
    If a user expresses interests or preferences or trivia about themselves - you can save it in the background but response naturally in conversation about it.
    If the user asks information about themselves you can also try to search for user facts if you dont have the answer.
    
# Schema

```{''''description'''': ''''Generic parsed content from files, sites etc. added to the system.\nIf someone asks about resources, content, files, general information etc. it may be worth doing a search on the Resources.\nIf a user expresses interests or preferences or trivia about themselves - you can save it in the background but response naturally in conversation about it.\nIf the user asks information about themselves you can also try to search for user facts if you dont have the answer.'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': ''''The id is generated as a hash of the required uri and ordinal'''', ''''title'''': ''''Id''''}, ''''name'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A short content name - non unique - for example a friendly label for a chunked pdf document or web page title'''', ''''title'''': ''''Name''''}, ''''category'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''A content category'''', ''''title'''': ''''Category''''}, ''''content'''': {''''description'''': ''''The chunk of content from the source'''', ''''embedding_provider'''': ''''default'''', ''''title'''': ''''Content'''', ''''type'''': ''''string''''}, ''''summary'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''An optional summary'''', ''''title'''': ''''Summary''''}, ''''ordinal'''': {''''default'''': 0, ''''description'''': ''''For chunked content we can keep an ordinal'''', ''''title'''': ''''Ordinal'''', ''''type'''': ''''integer''''}, ''''uri'''': {''''default'''': ''''An external source or content ref e.g. a PDF file on blob storage or public URI'''', ''''title'''': ''''Uri'''', ''''type'''': ''''string''''}, ''''metadata'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''default'''': {}, ''''title'''': ''''Metadata''''}, ''''graph_paths'''': {''''anyOf'''': [{''''items'''': {''''type'''': ''''string''''}, ''''type'''': ''''array''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Track all paths extracted by an agent as used to build the KG'''', ''''title'''': ''''Graph Paths''''}, ''''resource_timestamp'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log'''', ''''title'''': ''''Resource Timestamp''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''The user id is a system field but if we need to control the user context this is how we do it'''', ''''title'''': ''''Userid''''}}, ''''required'''': [''''content''''], ''''title'''': ''''Resources'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Generic parsed content from files, sites etc. added to the system.\nIf someone asks about resources, content, files, general information etc. it may be worth doing a search on the Resources.\nIf a user expresses interests or preferences or trivia about themselves - you can save it in the background but response naturally in conversation about it.\nIf the user asks information about themselves you can also try to search for user facts if you dont have the answer.", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": "The id is generated as a hash of the required uri and ordinal", "title": "Id"}, "name": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A short content name - non unique - for example a friendly label for a chunked pdf document or web page title", "title": "Name"}, "category": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "A content category", "title": "Category"}, "content": {"description": "The chunk of content from the source", "embedding_provider": "default", "title": "Content", "type": "string"}, "summary": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "An optional summary", "title": "Summary"}, "ordinal": {"default": 0, "description": "For chunked content we can keep an ordinal", "title": "Ordinal", "type": "integer"}, "uri": {"default": "An external source or content ref e.g. a PDF file on blob storage or public URI", "title": "Uri", "type": "string"}, "metadata": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "default": {}, "title": "Metadata"}, "graph_paths": {"anyOf": [{"items": {"type": "string"}, "type": "array"}, {"type": "null"}], "default": null, "description": "Track all paths extracted by an agent as used to build the KG", "title": "Graph Paths"}, "resource_timestamp": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "the database will add a default date but sometimes we want to control when the resource is relevant for - for example a daily log", "title": "Resource Timestamp"}, "userid": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "The user id is a system field but if we need to control the user context this is how we do it", "title": "Userid"}}, "required": ["content"], "title": "Resources", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_entities (p8.Resources)------
-- ------------------
select * from p8.register_entities('p8.Resources');
-- ------------------

-- register_embeddings (p8.SessionResources)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_SessionResources_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_sessionresources
        FOREIGN KEY (source_record_id) REFERENCES p8."SessionResources"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.SessionResources)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '6c5014de-4e05-8b3b-90ed-230991518456', 'p8.SessionResources', 'str', NULL, 'unique id for rel', False),
 ('resource_id', 'f381c004-91f0-8c1b-be7e-dd802847b201', 'p8.SessionResources', 'uuid.UUID | str', NULL, NULL, False),
 ('session_id', '7ed8a4b6-8293-95ab-f1ab-15301d78a5da', 'p8.SessionResources', 'uuid.UUID | str', NULL, NULL, False),
 ('count', '967a1fa2-b31b-2827-e32c-9c3c7ff37054', 'p8.SessionResources', 'int', NULL, 'In a model where we only store head we can track an estimate for chunk count', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.SessionResources)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.SessionResources', 'ac19b7d9-bf88-5289-922b-efff24784903', NULL, '# Agent - p8.SessionResources
A link between sessions and resources since resources can be shared between sessions
# Schema

```{''''description'''': ''''A link between sessions and resources since resources can be shared between sessions'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''unique id for rel'''', ''''title'''': ''''Id''''}, ''''resource_id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''default'''': ''''The resource id'''', ''''title'''': ''''Resource Id''''}, ''''session_id'''': {''''anyOf'''': [{''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''string''''}], ''''default'''': ''''The session id is any user intent from a chat/request/trigger'''', ''''title'''': ''''Session Id''''}, ''''count'''': {''''anyOf'''': [{''''type'''': ''''integer''''}, {''''type'''': ''''null''''}], ''''default'''': 1, ''''description'''': ''''In a model where we only store head we can track an estimate for chunk count'''', ''''title'''': ''''Count''''}}, ''''title'''': ''''SessionResources'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "A link between sessions and resources since resources can be shared between sessions", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "unique id for rel", "title": "Id"}, "resource_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "default": "The resource id", "title": "Resource Id"}, "session_id": {"anyOf": [{"format": "uuid", "type": "string"}, {"type": "string"}], "default": "The session id is any user intent from a chat/request/trigger", "title": "Session Id"}, "count": {"anyOf": [{"type": "integer"}, {"type": "null"}], "default": 1, "description": "In a model where we only store head we can track an estimate for chunk count", "title": "Count"}}, "title": "SessionResources", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_embeddings (p8.Schedule)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Schedule_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_schedule
        FOREIGN KEY (source_record_id) REFERENCES p8."Schedule"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Schedule)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', 'ceff3610-0280-2749-5188-45ad0edc9c0b', 'p8.Schedule', 'str', NULL, 'Unique schedule id', False),
 ('userid', '6943395f-942a-aa5f-11ba-35c8b6f3e504', 'p8.Schedule', 'str', NULL, 'User id associated with schedule', False),
 ('name', 'cc9bb231-eaae-db13-6ab6-0881866a56d6', 'p8.Schedule', 'str', NULL, 'Task to execute', False),
 ('spec', '77c69181-3a27-8d83-4500-57f7c593ea7e', 'p8.Schedule', 'dict', NULL, 'the task spec - The task spec can be any json but we have an internal protocol. LLM instructions are valid should use a system_prompt attribute', False),
 ('schedule', '29027456-c12c-8082-8ec5-a8425ca14d02', 'p8.Schedule', 'str', NULL, 'Cron schedule string, e.g. ''''0 0 * * *''''', False),
 ('disabled_at', 'fc4e777f-1ead-5820-a999-ec2ed3ab5377', 'p8.Schedule', 'datetime', NULL, 'Time when schedule was disabled', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Schedule)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Schedule', '3b3e25c1-9145-52a9-ab3f-87db624a6680', NULL, '# Agent - p8.Schedule
Defines a scheduled task.
    Tasks are scheduled by the system or by users and can be a system prompt for an agent or a function call
    
# Schema

```{''''description'''': ''''Defines a scheduled task.\nTasks are scheduled by the system or by users and can be a system prompt for an agent or a function call'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Unique schedule id'''', ''''title'''': ''''Id''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''User id associated with schedule'''', ''''title'''': ''''Userid''''}, ''''name'''': {''''description'''': ''''Task to execute'''', ''''title'''': ''''Name'''', ''''type'''': ''''string''''}, ''''spec'''': {''''additionalProperties'''': True, ''''description'''': ''''the task spec - The task spec can be any json but we have an internal protocol. LLM instructions are valid should use a system_prompt attribute'''', ''''title'''': ''''Spec'''', ''''type'''': ''''object''''}, ''''schedule'''': {''''description'''': "Cron schedule string, e.g. ''''0 0 * * *''''", ''''title'''': ''''Schedule'''', ''''type'''': ''''string''''}, ''''disabled_at'''': {''''anyOf'''': [{''''format'''': ''''date-time'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Time when schedule was disabled'''', ''''title'''': ''''Disabled At''''}}, ''''required'''': [''''name'''', ''''spec'''', ''''schedule''''], ''''title'''': ''''Schedule'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Defines a scheduled task.\nTasks are scheduled by the system or by users and can be a system prompt for an agent or a function call", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Unique schedule id", "title": "Id"}, "userid": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "User id associated with schedule", "title": "Userid"}, "name": {"description": "Task to execute", "title": "Name", "type": "string"}, "spec": {"additionalProperties": true, "description": "the task spec - The task spec can be any json but we have an internal protocol. LLM instructions are valid should use a system_prompt attribute", "title": "Spec", "type": "object"}, "schedule": {"description": "Cron schedule string, e.g. ''0 0 * * *''", "title": "Schedule", "type": "string"}, "disabled_at": {"anyOf": [{"format": "date-time", "type": "string"}, {"type": "null"}], "default": null, "description": "Time when schedule was disabled", "title": "Disabled At"}}, "required": ["name", "spec", "schedule"], "title": "Schedule", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------

-- register_entities (p8.Schedule)------
-- ------------------
select * from p8.register_entities('p8.Schedule');
-- ------------------

-- register_embeddings (p8.Audit)------
-- ------------------
CREATE TABLE  IF NOT EXISTS p8_embeddings."p8_Audit_embeddings" (
    id UUID PRIMARY KEY,  -- Hash-based unique ID - we typically hash the column key and provider and column being indexed
    source_record_id UUID NOT NULL,  -- Foreign key to primary table
    column_name TEXT NOT NULL,  -- Column name for embedded content
    embedding_vector VECTOR NULL,  -- Embedding vector as an array of floats
    embedding_name VARCHAR(50),  -- ID for embedding provider
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, -- Timestamp for tracking
    
    -- Foreign key constraint
    CONSTRAINT fk_source_table_p8_audit
        FOREIGN KEY (source_record_id) REFERENCES p8."Audit"
        ON DELETE CASCADE
);

-- ------------------

-- insert_field_data (p8.Audit)------
-- ------------------
INSERT INTO p8."ModelField" (name, id, entity_name, field_type, embedding_provider, description, is_key) VALUES
    ('id', '49fa15d9-8055-1667-4be8-2b3c8c7437eb', 'p8.Audit', 'str', NULL, 'Unique id', False),
 ('userid', '27cfbc9c-2449-a3fb-0c75-43dcb93c0a27', 'p8.Audit', 'str', NULL, 'Optional user context', False),
 ('status', '91853ace-88fa-b1fb-da00-6afe94ce9464', 'p8.Audit', 'str', NULL, 'audit status e.g. Fail|Success', False),
 ('caller', 'be715720-9da0-fb2d-3866-c17fd4fa72fb', 'p8.Audit', 'str', NULL, 'The calling object e.g. a class or service', False),
 ('status_payload', '8607d8b9-e82a-169b-7ec5-cb8995661540', 'p8.Audit', 'dict', NULL, 'Details about the event', False),
 ('error_trace', 'cab3edb7-5da8-161c-1a9c-2fdd8a3b2460', 'p8.Audit', 'str', NULL, 'If there is an error dump the stack trace', False)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, entity_name = EXCLUDED.entity_name, field_type = EXCLUDED.field_type, embedding_provider = EXCLUDED.embedding_provider, description = EXCLUDED.description, is_key = EXCLUDED.is_key;
-- ------------------

-- insert_agent_data (p8.Audit)------
-- ------------------
INSERT INTO p8."Agent" (name, id, category, description, spec, functions) VALUES
    ('p8.Audit', 'd02e2b6e-f942-5a0d-96a6-58e92f7e73e0', NULL, '# Agent - p8.Audit
Generic event audit for Percolate
# Schema

```{''''description'''': ''''Generic event audit for Percolate'''', ''''properties'''': {''''id'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Unique id'''', ''''title'''': ''''Id''''}, ''''userid'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''format'''': ''''uuid'''', ''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''Optional user context'''', ''''title'''': ''''Userid''''}, ''''status'''': {''''description'''': ''''audit status e.g. Fail|Success'''', ''''title'''': ''''Status'''', ''''type'''': ''''string''''}, ''''caller'''': {''''description'''': ''''The calling object e.g. a class or service'''', ''''title'''': ''''Caller'''', ''''type'''': ''''string''''}, ''''status_payload'''': {''''anyOf'''': [{''''additionalProperties'''': True, ''''type'''': ''''object''''}, {''''type'''': ''''null''''}], ''''description'''': ''''Details about the event'''', ''''title'''': ''''Status Payload''''}, ''''error_trace'''': {''''anyOf'''': [{''''type'''': ''''string''''}, {''''type'''': ''''null''''}], ''''default'''': None, ''''description'''': ''''If there is an error dump the stack trace'''', ''''title'''': ''''Error Trace''''}}, ''''required'''': [''''status'''', ''''caller'''', ''''status_payload''''], ''''title'''': ''''Audit'''', ''''type'''': ''''object''''}``` 

# Functions
 ```
None```
            ', '{"description": "Generic event audit for Percolate", "properties": {"id": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Unique id", "title": "Id"}, "userid": {"anyOf": [{"type": "string"}, {"format": "uuid", "type": "string"}, {"type": "null"}], "default": null, "description": "Optional user context", "title": "Userid"}, "status": {"description": "audit status e.g. Fail|Success", "title": "Status", "type": "string"}, "caller": {"description": "The calling object e.g. a class or service", "title": "Caller", "type": "string"}, "status_payload": {"anyOf": [{"additionalProperties": true, "type": "object"}, {"type": "null"}], "description": "Details about the event", "title": "Status Payload"}, "error_trace": {"anyOf": [{"type": "string"}, {"type": "null"}], "default": null, "description": "If there is an error dump the stack trace", "title": "Error Trace"}}, "required": ["status", "caller", "status_payload"], "title": "Audit", "type": "object"}', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, description = EXCLUDED.description, spec = EXCLUDED.spec, functions = EXCLUDED.functions;
-- ------------------


-- -----------
-- sample models--

INSERT INTO p8."LanguageModelApi" (name, id, model, scheme, completions_uri, token_env_key, token) VALUES
    ('gpt-4o-2024-08-06', 'b8d1e7c2-da1d-5e9c-96f1-29681dc478e5', 'gpt-4o-2024-08-06', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4o-mini', '8ecd0ec2-4e25-5211-b6f0-a049cf0dc630', 'gpt-4o-mini', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('cerebras-llama3.1-8b', 'f921494d-e431-585e-9246-f053d71cc4a3', 'llama3.1-8b', 'openai', 'https://api.cerebras.ai/v1/chat/completions', 'CEREBRAS_API_KEY', NULL),
 ('groq-llama-3.3-70b-versatile', 'de029bd1-5adb-527d-b78b-55f925ee4c78', 'llama-3.3-70b-versatile', 'openai', 'https://api.groq.com/openai/v1/chat/completions', 'GROQ_API_KEY', NULL),
 ('claude-3-5-sonnet-20241022', 'a05613b7-2577-5fd2-ac19-436afcecc89e', 'claude-3-5-sonnet-20241022', 'anthropic', 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY', NULL),
 ('claude-3-7-sonnet-20250219', 'c58d1ce8-2ef5-51a8-b505-79818072289b', 'claude-3-7-sonnet-20250219', 'anthropic', 'https://api.anthropic.com/v1/messages', 'ANTHROPIC_API_KEY', NULL),
 ('gemini-1.5-flash', '51e3267b-895c-5276-b674-09911e5d6819', 'gemini-1.5-flash', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent', 'GEMINI_API_KEY', NULL),
 ('gemini-2.0-flash', '659f43ef-25db-5f16-a2bc-bd00109eefd4', 'gemini-2.0-flash', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent', 'GEMINI_API_KEY', NULL),
 ('gemini-2.0-flash-thinking-exp-01-21', '6e86d4f4-65b7-574b-8c21-6414be60e72e', 'gemini-2.0-flash-thinking-exp-01-21', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-thinking-exp-01-21:generateContent', 'GEMINI_API_KEY', NULL),
 ('gemini-2.0-pro-exp-02-05', '080ba4f8-306d-5741-9900-4c3c58372855', 'gemini-2.0-pro-exp-02-05', 'google', 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-pro-exp-02-05:generateContent', 'GEMINI_API_KEY', NULL),
 ('deepseek-chat', '8f7b068f-82cc-5633-8a05-4ec10a57525c', 'deepseek-chat', 'openai', 'https://api.deepseek.com/chat/completions', 'DEEPSEEK_API_KEY', NULL),
 ('grok-2-latest', '3b300af1-0995-563b-ae3e-b8288f5aded9', 'grok-2-latest', 'openai', 'https://api.x.ai/v1/chat/completions', 'XAI_API_KEY', NULL),
 ('mercury-coder-small', '6434fab8-3d74-52b5-9a94-0258f81d8823', 'mercury-coder-small', 'openai', 'https://api.inceptionlabs.ai/v1/chat/completions', 'INCEPTION_API_KEY', NULL),
 ('gpt-4.1', 'a0680251-1522-5e7c-a0bf-da1db8cdc7da', 'gpt-4.1', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4.1-mini', '931c3b4d-f486-5473-bdb1-fdf2487294d2', 'gpt-4.1-mini', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4.1-nano', 'c26edbfe-9872-5d72-a6c6-e4ada0ce3adb', 'gpt-4.1-nano', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL),
 ('gpt-4.1-2025-04-14', '069e5783-8cd2-55ab-a4f5-6fc21d806e31', 'gpt-4.1-2025-04-14', 'openai', 'https://api.openai.com/v1/chat/completions', 'OPENAI_API_KEY', NULL)
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, model = EXCLUDED.model, scheme = EXCLUDED.scheme, completions_uri = EXCLUDED.completions_uri, token_env_key = EXCLUDED.token_env_key, token = EXCLUDED.token;

-- -----------
-- native functions--

INSERT INTO p8."Function" (name, id, key, verb, endpoint, description, function_spec, proxy_uri) VALUES
    ('get_entities', '5e3a9ca2-c78a-3058-be1d-2e7b8689ad58', 'native.get_entities', 'get', 'get_entities', 'Provide a list of one or more keys to lookup entities by keys in the database
Entity lookup uses identifiers like struct codes, identifiers, keys, names and codes for entities registered in the database', '{"name": "get_entities", "parameters": {"properties": {"keys": {"description": "List[str] a list of one or more keys to lookup", "items": {"type": "string"}, "type": "array"}}, "required": ["keys"], "type": "object"}, "description": "Provide a list of one or more keys to lookup entities by keys in the database\nEntity lookup uses identifiers like struct codes, identifiers, keys, names and codes for entities registered in the database"}', 'native'),
 ('search', '2307a23f-5613-3193-a990-ad6951b068de', 'native.search', 'get', 'search', 'Search provides a general multi-modal search over entities. You may know the entity name from the agent context or leave it blank
An example entity name is p8.Agent or p8.PercolateAgent.
Provide a detailed question that can be used for semantic or other search. your search will be mapped to underlying queries as required.
If given a specific entity name you should prefer to call get_entities with a list of one or more entity keys to lookup. if that fails fall back to search', '{"name": "search", "parameters": {"properties": {"question": {"description": "a detailed question to search", "type": "string"}, "entity_table_name": {"description": "the name of the entity or table to search e.g. p8.PercolateAgent", "type": "string"}}, "required": ["question", "entity_table_name"], "type": "object"}, "description": "Search provides a general multi-modal search over entities. You may know the entity name from the agent context or leave it blank\nAn example entity name is p8.Agent or p8.PercolateAgent.\nProvide a detailed question that can be used for semantic or other search. your search will be mapped to underlying queries as required.\nIf given a specific entity name you should prefer to call get_entities with a list of one or more entity keys to lookup. if that fails fall back to search"}', 'native'),
 ('help', '19ecd3b1-f79a-3ae9-8388-4c5ec8a7072b', 'native.help', 'get', 'help', 'Help is a planning utility. This function will search and return a list of resources or information for you based on the question you ask.', '{"name": "help", "parameters": {"properties": {"questions": {"description": "ask one or more questions to receive information and a plan of action", "items": {"type": "string"}, "type": "array"}}, "required": ["questions"], "type": "object"}, "description": "Help is a planning utility. This function will search and return a list of resources or information for you based on the question you ask."}', 'native'),
 ('announce_generate_large_output', 'c7c88a1e-eb0e-31f5-9dc2-33c83efe22c1', 'native.announce_generate_large_output', 'get', 'announce_generate_large_output', 'When you are about to generate a lot of output (for example over 2500 tokens or something that will take more that 4 seconds to generate), please call this function with a rough estimate of the size of the content.
You do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.
However when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.
We use this strategy to distinguish internal content gathering nodes from final response generation for users.', '{"name": "announce_generate_large_output", "parameters": {"properties": {"estimated_length": {"description": "estimated length in tokens of the generated content", "type": "integer"}}, "type": "object"}, "description": "When you are about to generate a lot of output (for example over 2500 tokens or something that will take more that 4 seconds to generate), please call this function with a rough estimate of the size of the content.\nYou do not need to do this when you are responding with simple structured responses which are typically small or with simple answers.\nHowever when generating lots of text we would like to request via streaming or async so we want to know before generating a lot of text.\nWe use this strategy to distinguish internal content gathering nodes from final response generation for users."}', 'native'),
 ('activate_functions_by_name', '0067b844-388c-390e-bba4-74a2c6d7cccb', 'native.activate_functions_by_name', 'get', 'activate_functions_by_name', 'Use this function to request a function that you do not have access to and it will be added to the function stack', '{"name": "activate_functions_by_name", "parameters": {"properties": {"function_names": {"description": "a list of one or more functions to add", "items": {"type": "string"}, "type": "array"}}, "required": ["function_names"], "type": "object"}, "description": "Use this function to request a function that you do not have access to and it will be added to the function stack"}', 'native')
    ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, key = EXCLUDED.key, verb = EXCLUDED.verb, endpoint = EXCLUDED.endpoint, description = EXCLUDED.description, function_spec = EXCLUDED.function_spec, proxy_uri = EXCLUDED.proxy_uri;