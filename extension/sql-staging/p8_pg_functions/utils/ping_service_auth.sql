DROP FUNCTION IF EXISTS p8.ping_service(text, boolean);

CREATE OR REPLACE FUNCTION p8.ping_service(
    service_name text DEFAULT 'percolate-api',
    test_auth boolean DEFAULT FALSE
)
RETURNS jsonb AS
$$
DECLARE
    service_url TEXT;
    http_result RECORD;
    result jsonb;
    start_time timestamp;
    end_time timestamp;
    response_time_ms numeric;
    auth_headers http_header[];
    api_token TEXT;
BEGIN
    start_time := clock_timestamp();
    
    -- Set service URL based on service name and auth requirement
    CASE service_name
        WHEN 'percolate-api' THEN
            IF test_auth THEN
                service_url := 'http://percolate-api:5008/admin/index/';  -- Protected endpoint
            ELSE
                service_url := 'http://percolate-api:5008/health';       -- Health endpoint
            END IF;
        WHEN 'percolate-api-external' THEN
            IF test_auth THEN
                service_url := 'http://localhost:5008/admin/index/';
            ELSE
                service_url := 'http://localhost:5008/health';
            END IF;
        WHEN 'ollama' THEN
            service_url := 'http://ollama-service:11434/';
            test_auth := FALSE; -- Ollama doesn't need auth
        WHEN 'minio' THEN
            service_url := 'http://minio:9000/minio/health/live';
            test_auth := FALSE; -- MinIO health doesn't need auth
        ELSE
            -- Custom URL provided
            service_url := service_name;
    END CASE;

    -- If testing auth, get the API token from database
    IF test_auth THEN
        SELECT token INTO api_token
        FROM p8."ApiProxy"
        WHERE name = 'percolate'
        LIMIT 1;
        
        IF api_token IS NULL THEN
            RETURN jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'error',
                'error', 'No API token found in ApiProxy table',
                'test_auth', test_auth,
                'timestamp', start_time
            );
        END IF;
        
        -- Set authorization header
        auth_headers := ARRAY[
            http_header('Authorization', 'Bearer ' || api_token),
            http_header('Content-Type', 'application/json')
        ];
    ELSE
        auth_headers := ARRAY[]::http_header[];
    END IF;

    BEGIN
        -- Make the request with appropriate headers
        IF test_auth AND service_name LIKE '%percolate-api%' THEN
            -- POST request with JSON body for auth test
            SELECT *
            INTO http_result
            FROM public.http(
                ROW(
                    'POST',
                    service_url,
                    auth_headers,
                    'application/json',
                    '{"model_name": "test", "entity_full_name": "test.ping"}'
                )::http_request
            );
        ELSE
            -- GET request for health check
            SELECT *
            INTO http_result
            FROM public.http(
                ROW(
                    'GET',
                    service_url,
                    auth_headers,
                    NULL,
                    NULL
                )::http_request
            );
        END IF;
        
        end_time := clock_timestamp();
        response_time_ms := EXTRACT(epoch FROM (end_time - start_time)) * 1000;
        
        -- Check if auth test succeeded (200) or failed (401/403)
        IF test_auth THEN
            IF http_result.status = 200 THEN
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',
                    'auth_status', 'authorized',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
                RAISE NOTICE 'Service % auth test PASSED - Token accepted (%.2f ms)', service_name, response_time_ms;
            ELSIF http_result.status IN (401, 403) THEN
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',  -- Service is up but auth failed
                    'auth_status', 'unauthorized',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
                RAISE NOTICE 'Service % auth test FAILED - Token rejected (%.2f ms)', service_name, response_time_ms;
            ELSE
                result := jsonb_build_object(
                    'service', service_name,
                    'url', service_url,
                    'status', 'up',
                    'auth_status', 'unknown',
                    'http_status', http_result.status,
                    'response_time_ms', response_time_ms,
                    'response_body', http_result.content,
                    'test_auth', test_auth,
                    'timestamp', start_time
                );
            END IF;
        ELSE
            -- Regular health check
            result := jsonb_build_object(
                'service', service_name,
                'url', service_url,
                'status', 'up',
                'http_status', http_result.status,
                'response_time_ms', response_time_ms,
                'response_body', http_result.content,
                'test_auth', test_auth,
                'timestamp', start_time
            );
        END IF;
        
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
                'test_auth', test_auth,
                'timestamp', start_time
            );
            
            RAISE NOTICE 'Service % is DOWN - Error: % (%.2f ms)', service_name, SQLERRM, response_time_ms;
    END;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text, boolean) IS 'Ping a service to check if it is accessible. Second parameter (test_auth) when TRUE tests authentication with database token. Returns JSON with status, auth results, response time, and details.';

-- Backward compatibility: keep the old signature
DROP FUNCTION IF EXISTS p8.ping_service(text);

CREATE OR REPLACE FUNCTION p8.ping_service(service_name text DEFAULT 'percolate-api')
RETURNS jsonb AS
$$
BEGIN
    RETURN p8.ping_service(service_name, FALSE);
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION p8.ping_service(text) IS 'Ping a service to check if it is accessible (without auth test). Use ping_service(service, TRUE) to test authentication.';