-- Configure PostgreSQL to preload AGE extension for proper functionality
-- This needs to happen before any scripts that use cypher() function
-- This matches the CloudNative configuration: session_preload_libraries: "age"
ALTER SYSTEM SET session_preload_libraries = 'age';
SELECT pg_reload_conf();

-- Note: New connections will have AGE preloaded after this change
-- For the current session, we still need to load it manually
LOAD 'age';