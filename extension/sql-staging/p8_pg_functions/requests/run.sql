    DROP FUNCTION IF EXISTS run;
CREATE OR REPLACE FUNCTION run(
    question text,
    agent text DEFAULT 'p8.PercolateAgent',
    model text DEFAULT 'gpt-4o-mini',
    limit_iterations int DEFAULT 3
) RETURNS TABLE (
    message_response text,
    tool_calls jsonb,
    tool_call_result jsonb,
    session_id_out uuid,
    status text
) AS $$
DECLARE
    session_id_captured uuid;
    current_row record;  -- To capture the row from resume_session
    iterations int := 1; -- default to 
BEGIN
    /*
    this function is just for test/poc
    just because we can do this does not mean we should as it presents long running queries
    this would be implemented in practice with a bounder against the API.
    The client would then consume from an API that ways for the result
    Nonetheless, for testing purposes its good to test that the session does resolve as we resume to a limit

    Here is an example if you have registered the tool example for swagger/pets

    select * from run('please activate function get_pet_findByStatus and find two pets that are sold')

    this requires multiple turns - first it realizes it needs the function so activates, then it runs the function (keep in mind we eval tool calls in each turn)
    then it finally generates the answer
    */

    -- First, call percolate_with_agent function
    SELECT p.session_id_out INTO session_id_captured
    FROM percolate_with_agent(question, agent, model) p;
    
    -- Get the function_stack (just an example)
    SELECT function_stack INTO message_response
    FROM p8."AIResponse" r
    WHERE r.session_id = session_id_captured;

    -- Loop to iterate until limit_iterations or status = 'COMPLETED'
    LOOP
		RAISE NOTICE '***resuming session, iteration %***', iterations+1;
        -- Call resume_session to resume the session and get the row
        SELECT * INTO current_row
        FROM p8.resume_session(session_id_captured);
        
        -- Check if the status is 'COMPLETED' or iteration limit reached
        IF current_row.status = 'COMPLETED' OR iterations >= (limit_iterations-1) THEN
            EXIT;
        END IF;
        
        iterations := iterations + 1;
    END LOOP;
    
    -- Return the final row from resume_session
    RETURN QUERY
    SELECT current_row.message_response,
           current_row.tool_calls,
           current_row.tool_call_result,
           current_row.session_id_out,
           current_row.status;
END;
$$ LANGUAGE plpgsql;
