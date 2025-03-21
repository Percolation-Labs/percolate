DROP FUNCTION IF EXISTS p8.run_web_search;

CREATE OR REPLACE FUNCTION p8.run_web_search(
    query TEXT,
    max_results INT DEFAULT 5,
    fetch_content BOOLEAN DEFAULT FALSE, -- Whether to fetch full page content
    include_images BOOLEAN DEFAULT FALSE,
    api_endpoint TEXT DEFAULT 'https://api.tavily.com/search',
    topic TEXT DEFAULT 'general', -- news|finance and other things
    optional_token TEXT DEFAULT NULL -- Allow token to be optionally passed in
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
    /* We should generalize this for working with Brave or Tavily but for now just the latter.
       The token needs to be set to match the search endpoint for the provider.
       We can normally insert these search results into ingested resources based on context - we can read the search results in full if needed.


	   select * from p8.run_web_search('philosophy of mind')

	   	select * from p8.run_web_search('philosophy of mind','https://api.tavily.com/search', 'general', 3, TRUE,TRUE)

		select * from http_get('https://en.wikipedia.org/wiki/Philosophy_of_mind')
    */

	
    -- Determine API token: Use optional_token if provided, otherwise fetch from ApiProxy
    IF optional_token IS NOT NULL THEN
        api_token := optional_token;
    ELSE
        SELECT token INTO api_token 
        FROM p8."ApiProxy" 
        WHERE proxy_uri = api_endpoint 
        LIMIT 1;
    END IF;


    -- Raise exception if no token is available
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
    SELECT a.content INTO api_response
    FROM http(
        (
            'POST', 
            call_uri, 
            ARRAY[
                http_header('Authorization', 'Bearer ' || api_token)--,
                --http_header('Content-Type', 'application/json')
            ], 
            'application/json', 
            response_json
        )::http_request
    ) as a;

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
            )::TEXT[],
            ARRAY[]::TEXT[]
        );

		--RAISE NOTICE '%', url;
		
        -- Fetch full page content if flag is set
         -- Fetch full page content with error handling
        IF fetch_content THEN
            BEGIN
                SELECT a.content INTO content FROM http_get(url) a;
            EXCEPTION WHEN OTHERS THEN
                content := NULL;
                RAISE NOTICE 'Failed to fetch content for URL: %', url;
            END;
        ELSE
            content := NULL;
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
