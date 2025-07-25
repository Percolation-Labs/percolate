DROP FUNCTION IF EXISTS p8.ping_service(text);

CREATE OR REPLACE FUNCTION p8.ping_service(service_name text DEFAULT 'percolate-api')
RETURNS jsonb AS
$$
DECLARE
    service_url TEXT;
    http_result RECORD;
    result jsonb;
    start_time timestamp;
    end_time timestamp;
    response_time_ms numeric;
BEGIN
    start_time := clock_timestamp();
    
    -- Set service URL based on service name
    CASE service_name
        WHEN 'percolate-api' THEN
            service_url := 'http://percolate-api:5008/health';
        WHEN 'percolate-api-external' THEN
            service_url := 'http://localhost:5008/health';
        WHEN 'ollama' THEN
            service_url := 'http://ollama-service:11434/';
        WHEN 'minio' THEN
            service_url := 'http://minio:9000/minio/health/live';
        ELSE
            -- Custom URL provided
            service_url := service_name;
    END CASE;

    BEGIN
        -- Make the GET request with a 5-second timeout
        SELECT *
        INTO http_result
        FROM public.http(
            ( 'GET', 
              service_url,
              ARRAY[]::http_header[],
              NULL,
              '5000'::text -- 5 second timeout
            )::http_request
        );
        
        end_time := clock_timestamp();
        response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
        
        result := jsonb_build_object(
            'service', service_name,
            'url', service_url,
            'status', 'up',
            'http_status', http_result.status,
            'response_time_ms', response_time_ms,
            'response_body', http_result.content,
            'timestamp', start_time
        );
        
        RAISE NOTICE 'Service % is UP - Status: % (%.2f ms)', service_name, http_result.status, response_time_ms;
        
    EXCEPTION 
        WHEN OTHERS THEN
            end_time := clock_timestamp();
            response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
            
            result := jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'down',
                'error', SQLERRM,
                'response_time_ms', response_time_ms,
                'timestamp', start_time
            );
            
            RAISE NOTICE 'Service % is DOWN - Error: % (%.2f ms)', service_name, SQLERRM, response_time_ms;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text) IS 'Ping a service to check if it is accessible. Returns JSON with status, response time, and details. Use percolate-api, ollama, minio, or provide custom URL.';

-- Create a convenience function to ping all core services
DROP FUNCTION IF EXISTS p8.ping_all_services();

CREATE OR REPLACE FUNCTION p8.ping_all_services()
RETURNS jsonb AS
$$
DECLARE
    results jsonb := '[]'::jsonb;
    service_result jsonb;
BEGIN
    -- Ping each core service
    FOR service_result IN 
        SELECT p8.ping_service(service) as result
        FROM unnest(ARRAY['percolate-api', 'ollama', 'minio']) as service
    LOOP
        results := results || service_result.result;
    END LOOP;
    
    RETURN jsonb_build_object(
        'timestamp', clock_timestamp(),
        'services', results,
        'summary', jsonb_build_object(
            'total', jsonb_array_length(results),
            'up', (SELECT count(*) FROM jsonb_array_elements(results) WHERE value->>'status' = 'up'),
            'down', (SELECT count(*) FROM jsonb_array_elements(results) WHERE value->>'status' = 'down')
        )
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_all_services() IS 'Ping all core Percolate services (API, Ollama, MinIO) and return status summary.';