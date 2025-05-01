DROP FUNCTION IF EXISTS p8.update_user_model;
CREATE OR REPLACE FUNCTION p8.update_user_model(
  user_uuid UUID,
  last_ai_response_in TEXT
)
RETURNS void AS $$
DECLARE
  latest_thread_id TEXT;
  latest_thread_timestamp TIMESTAMP;
  questions TEXT[];
BEGIN
   /*
 a routine to update the user model including kick of async complex tasks
 thread ids can be from any system but we prefer uuids. 
 For this reason we do a case insensitive string match on the ids
 
 select * from p8.update_user_model('10e0a97d-a064-553a-9043-3c1f0a6e6725'::uuid, 'Hello, how can I help?')
 select * from p8."User" where id = '10e0a97d-a064-553a-9043-3c1f0a6e6725'

  SELECT thread_id
  INTO latest_thread_id
  FROM p8."Session"
  WHERE userid = user_uuid
  ORDER BY created_at DESC
  LIMIT 1;

  SELECT ARRAY_AGG(query ORDER BY created_at)
      FROM p8."Session"
      WHERE lower(thread_id) = lower('325aa22e-f6e0-47ba-aa0d-eaafb5e99466')
	  
 */
  SELECT thread_id, updated_at
  INTO latest_thread_id, latest_thread_timestamp
  FROM p8."Session"
  WHERE userid = user_uuid
  ORDER BY created_at DESC
  LIMIT 1;

  IF latest_thread_id IS NOT NULL THEN
    -- Get list of queries in the thread
    SELECT ARRAY_AGG(query ORDER BY created_at)
    INTO questions
    FROM p8."Session"
    WHERE lower(thread_id) = lower(latest_thread_id::TEXT);

    -- Overwrite recent_threads with a new array of one object
    UPDATE p8."User"
    SET recent_threads = jsonb_build_array(jsonb_build_object(
          'thread_timestamp', latest_thread_timestamp,
          'thread_id', latest_thread_id,
          'questions', questions
        )),
        last_ai_response = last_ai_response_in
    WHERE id = user_uuid;
  END IF;
END;
$$ LANGUAGE plpgsql;
