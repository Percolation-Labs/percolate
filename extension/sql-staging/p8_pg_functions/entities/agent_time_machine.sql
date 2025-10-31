-- Agent Time Machine: Versioned prompt history tracking
-- Automatically tracks changes to the agents table and provides rollback capabilities

-- Create the agents_time_machine table
CREATE TABLE IF NOT EXISTS p8.agents_time_machine (
    id SERIAL PRIMARY KEY,
    agent_id UUID NOT NULL,
    name TEXT NOT NULL,
    category TEXT,
    description TEXT,
    spec JSONB,
    functions JSONB,
    metadata JSONB,
    version TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    userid TEXT,
    CONSTRAINT fk_agent FOREIGN KEY (agent_id) REFERENCES p8.agents(id) ON DELETE CASCADE
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_agents_time_machine_agent_id ON p8.agents_time_machine(agent_id);
CREATE INDEX IF NOT EXISTS idx_agents_time_machine_version ON p8.agents_time_machine(agent_id, version);
CREATE INDEX IF NOT EXISTS idx_agents_time_machine_created_at ON p8.agents_time_machine(agent_id, created_at DESC);

-- Trigger function to automatically version agents on update
CREATE OR REPLACE FUNCTION p8.agent_version_trigger()
RETURNS TRIGGER AS $$
DECLARE
    version_value TEXT;
BEGIN
    -- Extract version from metadata if it exists
    version_value := NEW.metadata->>'version';

    -- Insert the new version into time machine
    INSERT INTO p8.agents_time_machine (
        agent_id,
        name,
        category,
        description,
        spec,
        functions,
        metadata,
        version,
        userid
    ) VALUES (
        NEW.id,
        NEW.name,
        NEW.category,
        NEW.description,
        NEW.spec,
        NEW.functions,
        NEW.metadata,
        version_value,
        NEW.userid
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger on agents table
DROP TRIGGER IF EXISTS agents_version_trigger ON p8.agents;
CREATE TRIGGER agents_version_trigger
    AFTER INSERT OR UPDATE ON p8.agents
    FOR EACH ROW
    EXECUTE FUNCTION p8.agent_version_trigger();

-- Function to get a specific version of an agent
CREATE OR REPLACE FUNCTION p8.get_agent_version(
    p_agent_id UUID,
    p_version TEXT DEFAULT NULL
)
RETURNS TABLE (
    id INTEGER,
    agent_id UUID,
    name TEXT,
    category TEXT,
    description TEXT,
    spec JSONB,
    functions JSONB,
    metadata JSONB,
    version TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    userid TEXT
) AS $$
BEGIN
    -- If version is specified, get that specific version
    IF p_version IS NOT NULL THEN
        RETURN QUERY
        SELECT
            atm.id,
            atm.agent_id,
            atm.name,
            atm.category,
            atm.description,
            atm.spec,
            atm.functions,
            atm.metadata,
            atm.version,
            atm.created_at,
            atm.userid
        FROM p8.agents_time_machine atm
        WHERE atm.agent_id = p_agent_id
          AND atm.version = p_version
        ORDER BY atm.created_at DESC
        LIMIT 1;
    ELSE
        -- Get the most recent versioned entry (version IS NOT NULL)
        RETURN QUERY
        SELECT
            atm.id,
            atm.agent_id,
            atm.name,
            atm.category,
            atm.description,
            atm.spec,
            atm.functions,
            atm.metadata,
            atm.version,
            atm.created_at,
            atm.userid
        FROM p8.agents_time_machine atm
        WHERE atm.agent_id = p_agent_id
          AND atm.version IS NOT NULL
        ORDER BY atm.created_at DESC
        LIMIT 1;
    END IF;

    -- Check if we found anything
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No versioned entry found for agent_id % with version %',
            p_agent_id, COALESCE(p_version, 'latest');
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Function to rollback agent to a specific version
CREATE OR REPLACE FUNCTION p8.rollback_agent_version(
    p_agent_id UUID,
    p_version TEXT DEFAULT NULL
)
RETURNS TABLE (
    success BOOLEAN,
    message TEXT,
    rolled_back_to_version TEXT
) AS $$
DECLARE
    v_record RECORD;
    v_version TEXT;
BEGIN
    -- Get the version to rollback to
    BEGIN
        SELECT * INTO v_record
        FROM p8.get_agent_version(p_agent_id, p_version);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN QUERY SELECT FALSE, SQLERRM::TEXT, NULL::TEXT;
            RETURN;
    END;

    -- Update the agents table with the versioned data
    UPDATE p8.agents
    SET
        name = v_record.name,
        category = v_record.category,
        description = v_record.description,
        spec = v_record.spec,
        functions = v_record.functions,
        metadata = v_record.metadata,
        updated_at = NOW()
    WHERE id = p_agent_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'Agent not found'::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    v_version := COALESCE(v_record.version, 'unversioned');

    RETURN QUERY SELECT
        TRUE,
        format('Successfully rolled back agent %s to version %s', p_agent_id, v_version)::TEXT,
        v_version;
END;
$$ LANGUAGE plpgsql;

-- Function to list all versions for an agent
CREATE OR REPLACE FUNCTION p8.list_agent_versions(
    p_agent_id UUID
)
RETURNS TABLE (
    id INTEGER,
    version TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    name TEXT,
    has_version BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        atm.id,
        COALESCE(atm.version, 'unversioned')::TEXT as version,
        atm.created_at,
        atm.name,
        (atm.version IS NOT NULL) as has_version
    FROM p8.agents_time_machine atm
    WHERE atm.agent_id = p_agent_id
    ORDER BY atm.created_at DESC;
END;
$$ LANGUAGE plpgsql;

-- Grant necessary permissions
ALTER TABLE p8.agents_time_machine OWNER TO postgres;
ALTER FUNCTION p8.agent_version_trigger() OWNER TO postgres;
ALTER FUNCTION p8.get_agent_version(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION p8.rollback_agent_version(UUID, TEXT) OWNER TO postgres;
ALTER FUNCTION p8.list_agent_versions(UUID) OWNER TO postgres;

-- Add comments for documentation
COMMENT ON TABLE p8.agents_time_machine IS 'Version history for agents table, tracking all changes with optional versioning';
COMMENT ON FUNCTION p8.get_agent_version(UUID, TEXT) IS 'Retrieve a specific version of an agent. If version is NULL, returns the most recent versioned entry.';
COMMENT ON FUNCTION p8.rollback_agent_version(UUID, TEXT) IS 'Rollback an agent to a specific version. If version is NULL, rolls back to the most recent versioned entry.';
COMMENT ON FUNCTION p8.list_agent_versions(UUID) IS 'List all versions available for an agent in the time machine.';
