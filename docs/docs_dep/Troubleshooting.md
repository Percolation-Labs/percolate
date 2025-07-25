# Indexes

When we create tables we add metadata about what is indexed. The ModelField should include an entry for each field that has an embedding provider/ 
When data are inserted into that table we run `p8.insert_entity_embeddings(ENTITY_NAME)` from a trigger (you can check if that trigger is added). This will use the percolate-api as a worker to batch request embeddings that are pending for that table.
The p8.IndexAudit stores events. 

## If there are no events

1. check the table has the trigger (if not there is a function to add it TODO)
2. check the model field has an entry for the table - if not register the table (TODO - make it easy to do this from cli
3. public.notify_entity_updates() is called by the trigger
```sql

 SELECT token, proxy_uri 
    INTO api_token_in, proxy_uri_in
    FROM p8."ApiProxy"
    WHERE name = 'percolate'
    LIMIT 1;

  SELECT content INTO response
        FROM public.http(
            ( 'POST', 
            proxy_uri_in || '/admin/index/',
            ARRAY[http_header('Authorization', 'Bearer ' || api_token_in)],
            'application/json',
            json_build_object('entity_full_name', full_name)::jsonb
            )::http_request
        );
```
it must be possible to curl to the API using the token in the ApiProxy.