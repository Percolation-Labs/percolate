-- FUNCTION: p8.insert_generated_embeddings(text, text, text, text)

-- DROP FUNCTION IF EXISTS p8.insert_generated_embeddings(text, text, text, text);

CREATE OR REPLACE FUNCTION p8.insert_generated_embeddings(
    param_table text,
    param_column text,
    param_embedding_model text DEFAULT 'default',
    param_token text DEFAULT NULL)
    RETURNS integer
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    sanitized_table TEXT;
    affected_rows INTEGER;
    table_exists BOOLEAN DEFAULT TRUE;
    resolved_model TEXT;
    resolved_token TEXT;
BEGIN
/*
imports p8.generate_and_fetch_embeddings
example
select * from p8.insert_generated_embeddings('p8.Agent', 'description')
returns non 0 if it needed to insert somethign
caller e.g. p8.insert_entity_embeddings('p8.Agent') can flush all required embeddings
*/
    -- Resolve the model name, defaulting to 'text-embedding-ada-002' if 'default' is provided
    resolved_model := CASE 
        WHEN param_embedding_model = 'default' THEN 'text-embedding-ada-002'
        ELSE param_embedding_model
    END;

    -- Resolve the token, fetching it if NULL
    IF param_token IS NULL THEN
        SELECT token
        INTO resolved_token
        FROM p8."LanguageModelApi"
        WHERE "name" = 'gpt-4o-mini';
    ELSE
        resolved_token := param_token;
    END IF;

    -- Sanitize the table name
    sanitized_table := REPLACE(param_table, '.', '_');

    -- Check if the target embedding table exists
    SELECT EXISTS (
        SELECT *
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'p8_embeddings' AND c.relname = sanitized_table || '_embeddings'
    )
    INTO table_exists;

    -- Construct and execute the insertion if the table exists
    IF table_exists THEN
        EXECUTE format(
            $sql$
            INSERT INTO p8_embeddings."%s_embeddings" (id, source_record_id, embedding_name, column_name, embedding_vector)
            SELECT * 
            FROM p8.generate_and_fetch_embeddings(
                %L,
                %L,
                %L,
                %L
            )
            $sql$,
            sanitized_table,    -- Target embedding table
            param_table,        -- Passed to the function
            param_column,       -- Column to embed
            resolved_model,     -- Resolved embedding model
            resolved_token      -- Resolved API token
        );

        -- Get the number of affected rows
        GET DIAGNOSTICS affected_rows = ROW_COUNT;
        RETURN affected_rows;
    END IF;

    RETURN 0;
END;
$BODY$;

ALTER FUNCTION p8.insert_generated_embeddings(text, text, text, text)
    OWNER TO postgres;
