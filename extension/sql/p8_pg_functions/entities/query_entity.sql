CREATE OR REPLACE FUNCTION p8.query_entity(
	question text,
	table_name text,
	min_confidence numeric DEFAULT 0.7)
    RETURNS TABLE(table_result jsonb) 
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS $BODY$
DECLARE
    query_to_execute TEXT;
    query_confidence NUMERIC;
BEGIN

	/*
	imports p8.nl2sql
	*/
    -- Call the fn_nl2sql function to get the response and confidence
    SELECT   "query", "confidence" INTO query_to_execute, query_confidence FROM p8.nl2sql(question, table_name);

	--RAISE NOTICE 'query: %', query_to_execute;
    -- Check if the confidence is greater than or equal to the minimum threshold
    IF query_confidence >= min_confidence THEN
        -- Execute the dynamic SQL query if confidence is high enough
		query_to_execute := rtrim(query_to_execute, ';');
		
         RETURN QUERY EXECUTE 
            'SELECT jsonb_agg(row_to_json(t)) FROM (' || query_to_execute || ') t';
    ELSE
        -- If the confidence is not high enough, return an error or appropriate message
        RAISE EXCEPTION 'Confidence level too low: %', query_confidence;
    END IF;
END;
$BODY$;