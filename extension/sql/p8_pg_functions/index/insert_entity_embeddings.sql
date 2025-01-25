-- FUNCTION: p8.insert_entity_embeddings(text, text)

-- DROP FUNCTION IF EXISTS p8.insert_entity_embeddings(text, text);

CREATE OR REPLACE FUNCTION p8.insert_entity_embeddings(
	param_entity_name text,
	param_token text DEFAULT NULL::text)
    RETURNS TABLE(field_id uuid, entity_name_out text, records_affected integer) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    field_record RECORD;
    rows_affected INTEGER;
    total_records INTEGER;
BEGIN

	/*
	import 
	p8.insert_generated_embeddings
	*/

    --we just need a token so any OpenAI model or whatever the embedding is
    IF param_token IS NULL THEN
        SELECT token into param_token
            FROM p8."LanguageModelApi"
            WHERE "name" = 'gpt-4o-mini'
            LIMIT 1;
    END IF;
 
    -- Loop through the fields in the table for the specified entity
    FOR field_record IN 
        SELECT id, name, field_type, embedding_provider
        FROM p8."ModelField"
        WHERE entity_name = param_entity_name
		 and embedding_provider is not null
    LOOP
        -- Initialize the total records affected for this field
        total_records := 0;

        -- Continue calling the insert_generated_embeddings function until no records are affected
        LOOP
            rows_affected := p8.insert_generated_embeddings(
                param_entity_name, 
                field_record.name, 
                field_record.embedding_provider, 
                param_token
            );

            -- Add to the total records count
            total_records := total_records + rows_affected;

            -- Exit the loop if no rows were affected
            IF rows_affected = 0 THEN
                EXIT;
            END IF;
        END LOOP;

        -- Return the metadata for this field
        RETURN QUERY SELECT 
            field_record.id,
			param_entity_name,
            total_records;
    END LOOP;
END;
$BODY$;

ALTER FUNCTION p8.insert_entity_embeddings(text, text)
    OWNER TO postgres;
