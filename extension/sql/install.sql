---------extensions----------------------
CREATE EXTENSION IF NOT EXISTS HTTP ;
CREATE EXTENSION  IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;

-----------------------------------------
-----------------------------------------


------Add the p8 graph and schema--------
LOAD  'age';
SET search_path = ag_catalog, "$user", public;
SELECT create_graph('percolate');
-----------------------------------------
-----------------------------------------


------Add any triggers-------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-----------------------------------------
-----------------------------------------


------Add percolate p8 schema------------
CREATE SCHEMA IF NOT EXISTS p8
CREATE SCHEMA IF NOT EXISTS p8_embeddings