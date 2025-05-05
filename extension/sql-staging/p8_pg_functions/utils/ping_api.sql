DROP FUNCTION IF EXISTS p8.ping_api();

CREATE OR REPLACE FUNCTION p8.ping_api()
RETURNS INTEGER AS
$$
DECLARE
    api_token_in TEXT;
    proxy_uri_in TEXT;
    http_result RECORD;
BEGIN
    -- Fetch API details from the p8."ApiProxy" table
    SELECT token, proxy_uri 
    INTO api_token_in, proxy_uri_in
    FROM p8."ApiProxy"
    WHERE name = 'percolate'
    LIMIT 1;

    -- If no API details are found, exit early
    IF api_token_in IS NULL OR proxy_uri_in IS NULL THEN
        RAISE NOTICE 'API details not found, skipping ping';
        RETURN NULL;
    END IF;

    BEGIN
        -- Make the GET request to /auth/ping
        SELECT *
        INTO http_result
        FROM public.http(
            ( 'GET', 
              proxy_uri_in || '/auth/ping',
              ARRAY[http_header('Authorization', 'Bearer ' || api_token_in)],
              NULL,
              NULL
            )::http_request
        );
    EXCEPTION 
        WHEN OTHERS THEN
            RAISE NOTICE 'Error executing ping request: %', SQLERRM;
            RETURN NULL;
    END;

    -- Log and return the status code
    RAISE NOTICE 'Pinged %/auth/ping - Status: %, Response: %', proxy_uri_in, http_result.status, http_result.content;
    RETURN http_result.status;
END;
$$ LANGUAGE plpgsql;
