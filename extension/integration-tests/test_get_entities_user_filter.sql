/*
this integration test can be used with the psql tool using the following env vars
P8_PG_HOST
P8_PG_PORT
P8_PG_PASSWORD
these env vars are already set in the env
the database is `app`
*/
\set ON_ERROR_STOP on

-- Integration Test: get_entities with and without user_id filter
-- This test verifies that public resources are always returned,
-- and that private resources (with a userid) are only returned when the same userid is supplied.

-- TEST SETUP -------------------------------------------------------------
-- 1. Define a test user UUID
-- test_user_id = '11111111-1111-1111-1111-111111111111'

-- 2. Clean up any previous test data in p8.Resources
DELETE FROM p8."Resources" WHERE name IN ('res_public', 'res_private');

-- 3. Remove existing graph nodes for these test keys
SELECT * FROM cypher_query(
  'MATCH (r:p8__Resources) WHERE r.key IN [''res_public'', ''res_private''] DETACH DELETE r'
);

-- 4. Insert two Resources: one public (userid NULL) and one private (userid = test_user_id)
INSERT INTO p8."Resources" (id, name, content, ordinal, uri, userid)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'res_public',  'public content', 0, 'uri://public', NULL),
  ('00000000-0000-0000-0000-000000000002', 'res_private', 'private content', 0, 'uri://private', '11111111-1111-1111-1111-111111111111');

-- 5. Register these Resources in the graph
-- NOTE that the above triggers this to happen anyway but async so we can force it here
SELECT * FROM p8.insert_entity_nodes('p8.Resources');

-- TEST CASE 1: No user filter -> only public resource should appear
\echo 'Test 1: No user filter (expect only res_public)'
DO $$
DECLARE
  result JSONB;
  count INT;
BEGIN
  result := p8.get_entities(ARRAY['res_public','res_private']);
  IF result IS NULL OR NOT (result ? 'p8.Resources') THEN
    RAISE EXCEPTION 'Expected key p8.Resources in result, got %', result;
  END IF;
  count := jsonb_array_length(result->'p8.Resources'->'data');
  IF count <> 1 THEN
    RAISE EXCEPTION 'Expected 1 public resource, got %', count;
  END IF;
  IF (result->'p8.Resources'->'data')->0->>'name' <> 'res_public' THEN
    RAISE EXCEPTION 'Expected res_public only, got %', result;
  END IF;
END;
$$;

-- TEST CASE 2: With user filter -> both public and private should appear
\echo 'Test 2: With user filter (expect res_public and res_private)'
DO $$
DECLARE
  result JSONB;
  count INT;
BEGIN
  result := p8.get_entities(ARRAY['res_public','res_private'], '11111111-1111-1111-1111-111111111111');
  IF result IS NULL OR NOT (result ? 'p8.Resources') THEN
    RAISE EXCEPTION 'Expected key p8.Resources in result, got %', result;
  END IF;
  count := jsonb_array_length(result->'p8.Resources'->'data');
  IF count <> 2 THEN
    RAISE EXCEPTION 'Expected 2 resources (public + private), got %', count;
  END IF;
END;
$$;

-- TEST CASE 3: Private-only key with user filter -> only private should appear
\echo 'Test 3: Private-only with user filter (expect only res_private)'
DO $$
DECLARE
  result JSONB;
  count INT;
BEGIN
  result := p8.get_entities(ARRAY['res_private'], '11111111-1111-1111-1111-111111111111');
  IF result IS NULL OR NOT (result ? 'p8.Resources') THEN
    RAISE EXCEPTION 'Expected key p8.Resources in result, got %', result;
  END IF;
  count := jsonb_array_length(result->'p8.Resources'->'data');
  IF count <> 1 THEN
    RAISE EXCEPTION 'Expected 1 private resource, got %', count;
  END IF;
  IF (result->'p8.Resources'->'data')->0->>'name' <> 'res_private' THEN
    RAISE EXCEPTION 'Expected res_private only, got %', result;
  END IF;
END;
$$;

\echo 'Integration test for get_entities user filter completed successfully.'