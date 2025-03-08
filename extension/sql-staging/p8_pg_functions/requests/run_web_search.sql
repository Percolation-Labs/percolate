CREATE OR REPLACE FUNCTION p8.run_web_search(
    query TEXT,
    api_endpoint TEXT DEFAULT 'https://api.tavily.com/search',
    topic TEXT DEFAULT 'general', -- news|finance and other things
    max_results INT DEFAULT 7,
    include_images BOOLEAN DEFAULT FALSE,
    fetch_content BOOLEAN DEFAULT FALSE -- Whether to fetch full page content
) RETURNS TABLE (
    title TEXT,
    url TEXT,
    summary TEXT,
    content TEXT,
    score FLOAT,
    images TEXT[]
) AS $$
DECLARE
    api_token TEXT;
    call_uri TEXT := api_endpoint;
    api_response TEXT;
    response_json JSONB;
    result JSONB;
BEGIN
    /*we should generalize this for working with brave or tavily but for now just the latter
    the token needs to be set to match the search endpoint for the provider
    we can normally insert these search results into ingested resources based on context - we can read the search results in full if needed
    */

    -- Retrieve API token from ApiProxy
    SELECT token INTO api_token 
    FROM p8."ApiProxy" 
    WHERE proxy_uri = api_endpoint 
    LIMIT 1;

    IF api_token IS NULL THEN
        RAISE EXCEPTION 'API token not found for %', api_endpoint;
    END IF;

    -- Construct request payload
    response_json := jsonb_build_object(
        'query', query,
        'topic', topic,
        'max_results', max_results,
        'include_images', include_images
    );

    -- Make the HTTP POST request
    SELECT content INTO api_response
    FROM http(
        (
            'POST', 
            call_uri, 
            ARRAY[
                http_header('Authorization', 'Bearer ' || api_token),
                http_header('Content-Type', 'application/json')
            ], 
            'application/json', 
            response_json
        )::http_request
    );

    -- Convert the response to JSONB
    response_json := api_response::JSONB;

    -- Validate response format
    IF NOT response_json ? 'results' THEN
        RAISE EXCEPTION 'Unexpected API response format: %', response_json;
    END IF;

    -- Loop through each result and return as table rows
    FOR result IN 
        SELECT * FROM jsonb_array_elements(response_json->'results')
    LOOP
        title := result->>'title';
        url := result->>'url';
        summary := result->>'content'; -- Renamed from content to summary
        score := (result->>'score')::FLOAT;
        
        -- Extract images array, defaulting to an empty array if not present
        images := COALESCE(
            ARRAY(
                SELECT jsonb_array_elements_text(result->'images')
            ),
            ARRAY[]::TEXT[]
        );

        -- Fetch full page content if flag is set - we often will want to do this later and selectively but this is good for testing purposes
        -- it may also be useful if we only select the top 1-3 pages and then fetching the content may be ok - remember that when we embed we chunk anyway
        IF fetch_content THEN
            SELECT content INTO content
            FROM http(
                (
                    'GET', 
                    url, 
                    ARRAY[], 
                    NULL, 
                    NULL
                )::http_request
            );
        ELSE
            content := NULL;
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
