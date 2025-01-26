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
	
   RETURN QUERY
   with records as(
    SELECT b.name,   min(a.embedding_vector <-> embedded_question) as vdistance
    FROM p8_embeddings."p8_Function_embeddings" a
    JOIN p8."Function" b ON b.id = a.source_record_id
    WHERE a.embedding_vector <-> embedded_question <= 0.75
	GROUP BY b.name 
    --ORDER BY a.embedding_vector <-> embedded_question ASC 
 	
	) select a.name, b.function_spec, a.vdistance from records a
	 join p8."Function" b on a.name = b.name
	order by vdistance 
	asc limit limit_results; 
	
END;
$BODY$;
