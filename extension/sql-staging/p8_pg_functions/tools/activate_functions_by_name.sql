DROP FUNCTION IF EXISTS p8.activate_functions_by_name;
CREATE OR REPLACE FUNCTION p8.activate_functions_by_name(
    names TEXT[], 
    response_id UUID
) RETURNS TEXT[] AS $$
DECLARE
    updated_functions TEXT[];
BEGIN
    /*
    Merges the list of activated functions in the dialogue and returns the updated function stack.

    Example usage:
	SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'Test', 'Other'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    SELECT * FROM p8.activate_functions_by_name(ARRAY[ 'New'], '42e80e20-6b9e-02f4-8af7-76d4f1ef049f'::UUID);
    */

    INSERT INTO p8."AIResponse" (id, model_name, content, role, function_stack)
    VALUES (
        response_id, 
        'percolate', 
        '', 
        '', 
        names
    )
    ON CONFLICT (id) DO UPDATE 
    SET 
        model_name = EXCLUDED.model_name,
        content = EXCLUDED.content,
        role = EXCLUDED.role,
        function_stack = ARRAY(SELECT DISTINCT unnest(p8."AIResponse".function_stack || EXCLUDED.function_stack))
    RETURNING function_stack INTO updated_functions;

    RETURN updated_functions;
END;
$$ LANGUAGE plpgsql;
