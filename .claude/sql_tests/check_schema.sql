-- List all schemas
SELECT schema_name 
FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog', 'information_schema')
ORDER BY schema_name;

-- List all tables in all schemas with exact names
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY table_schema, table_name;

-- Check for case-sensitive table names in p8 schema
SELECT 
    n.nspname as schema_name,
    c.relname as table_name
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'p8'
AND c.relkind = 'r'
ORDER BY c.relname;

-- Search for Resources-like tables (case insensitive)
SELECT table_schema, table_name
FROM information_schema.tables
WHERE LOWER(table_name) LIKE '%resource%'
ORDER BY table_schema, table_name;

-- Search for TUS-like tables (case insensitive)
SELECT table_schema, table_name
FROM information_schema.tables
WHERE LOWER(table_name) LIKE '%tus%'
ORDER BY table_schema, table_name;