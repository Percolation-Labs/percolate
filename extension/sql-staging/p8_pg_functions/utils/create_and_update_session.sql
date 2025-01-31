CREATE OR REPLACE FUNCTION p8.update_session(
    id UUID,
    user_id UUID,
    query TEXT
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO p8."Session" (id, userid, query)
    VALUES (id, userid, query)
    ON CONFLICT (id) 
    DO UPDATE SET query = EXCLUDED.query;
END;
$$ LANGUAGE plpgsql;


 
CREATE OR REPLACE FUNCTION p8.create_session(
    user_id UUID,
    query TEXT,
    agent TEXT DEFAULT NULL,
	parent_session_id UUID DEFAULT NULL
) RETURNS UUID AS $$
DECLARE
    session_id UUID;
BEGIN
    -- Generate session ID from user_id and current timestamp
    session_id := p8.json_to_uuid(
        json_build_object('timestamp', current_timestamp::text, 'user_id', user_id)::JSONB
    );

    -- Upsert into p8.Session
    INSERT INTO p8."Session" (id, userid, query, parent_session_id, agent)
    VALUES (session_id, user_id, query, parent_session_id, agent)
    ON CONFLICT (id) DO UPDATE
    SET userid = EXCLUDED.userid,
        query = EXCLUDED.query,
        parent_session_id = EXCLUDED.parent_session_id,
        agent = EXCLUDED.agent;

    RETURN session_id;
END;
$$ LANGUAGE plpgsql;
