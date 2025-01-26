CREATE OR REPLACE FUNCTION p8.get_tools_by_description(
    description_text text,
    limit_results integer DEFAULT 5)
RETURNS TABLE(name character varying, spec json, distance double precision) 
LANGUAGE 'plpgsql'
COST 100
VOLATILE PARALLEL UNSAFE
ROWS 1000
AS $BODY$
DECLARE
    embedded_question VECTOR; -- Variable to store the computed embedding
BEGIN
    -- Compute the embedding once and store it in the variable
    SELECT embedding
    INTO embedded_question
    FROM p8.get_embedding_for_text(description_text);

    -- Check if embedding calculation returned NULL
    IF embedded_question IS NULL THEN
        RAISE EXCEPTION 'Embedding calculation failed for input: %', description_text;
    END IF;

    -- Perform the query only if embedding is valid
    RETURN QUERY
    WITH records AS (
        SELECT 
            b.name,
            MIN(a.embedding_vector <-> embedded_question) AS vdistance
        FROM p8_embeddings."p8_Function_embeddings" a
        JOIN p8."Function" b ON b.id = a.source_record_id
        WHERE a.embedding_vector <-> embedded_question <= 0.75
        GROUP BY b.name
    )
    SELECT 
        CAST(r.name AS character varying) AS name,
        f.function_spec,
        r.vdistance
    FROM records r
    JOIN p8."Function" f ON r.name = f.name
    ORDER BY r.vdistance ASC
    LIMIT limit_results;

    -- Optional: Return an empty result set if no matches are found
    RETURN;
END;
$BODY$;

ALTER FUNCTION p8.get_tools_by_description(text, integer)
OWNER TO postgres;
