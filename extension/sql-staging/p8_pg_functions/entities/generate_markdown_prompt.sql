CREATE OR REPLACE FUNCTION p8.generate_markdown_prompt(
	table_entity_name text,
	max_enum_entries integer DEFAULT 200)
    RETURNS text
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
DECLARE
    markdown_prompt TEXT;
    field_info RECORD;
    field_descriptions TEXT := '';
    enum_values TEXT := '';
	column_unique_values JSONB;
BEGIN

	/*
	import
	p8.get_unique_enum_values(table_entity_name);
	*/
    -- Add entity name and description to the markdown
    SELECT '## Agent Name: ' || b.name || E'\n\n' || 
           '### Description: ' || COALESCE(b.description, 'No description provided.') || E'\n\n'
    INTO markdown_prompt
    FROM p8."Agent" b
    WHERE b.name = table_entity_name;

    -- Add field descriptions in a table format
    FOR field_info IN
        SELECT a.name AS field_name, 
               a.field_type, 
               COALESCE(a.description, '') AS field_description
        FROM p8."ModelField" a
        WHERE a.entity_name = table_entity_name
    LOOP
        field_descriptions := field_descriptions || 
            '| ' || field_info.field_name || ' | ' || field_info.field_type || 
            ' | ' || field_info.field_description || ' |' || E'\n';
    END LOOP;

    IF field_descriptions <> '' THEN
        markdown_prompt := markdown_prompt || 
            '### Field Descriptions' || E'\n\n' ||
            '| Field Name | Field Type | Description |' || E'\n' ||
            '|------------|------------|-------------|' || E'\n' ||
            field_descriptions || E'\n';
    END IF;

    -- Check for enums and add them if they are below the max_enum_entries threshold
    -- create some sort of enums view from metadata

	select get_unique_enum_values into column_unique_values from p8.get_unique_enum_values(table_entity_name);
	-- create an example repository for the table
	
    -- Add space for examples and functions
    markdown_prompt := markdown_prompt || 
        '### Examples' || E'\n\n' ||
        'in future we will add examples that match the question via vector search' || E'\n\n'  ||
		'### The unique distinct same values for some columns ' || '\n\n' ||
		column_unique_values || E'\n';

		

    RETURN markdown_prompt;
END;
$BODY$;

