--if we load the model configs for these in the database - we check the no tool examples for each of these models
select * from percolate('what is the capital of ireland');
select * from percolate('what is the capital of ireland', 'cerebras-llama3.1-8b');
select * from percolate('what is the capital of ireland', 'groq-llama-3.3-70b-versatile');
select * from percolate('what is the capital of ireland', 'deepseek-chat');
select * from percolate('what is the capital of ireland', 'claude-3-5-sonnet-20241022');
select * from percolate('what is the capital of ireland', 'gemini-1.5-flash');

--these usually look for tools based on the question or if a name of tool is supplied
select * from p8.get_tools_by_description('what is the capital of ireland', 5);
--when looking by name we actually load the spec too and we do so in the given scheme
select * from p8.get_tools_by_name(NULL, 'anthropic')

--we can ask for open ai embeddings- we use the small model by default

--get the sql markdown prompt for an agent
select * from p8.generate_markdown_prompt('p8.Agent')
--these is used to generate queries for the agent
--currently i only use the OpenAI compatible models for this and would need to update the code to use different APIs as we did in the ask_X method
select * from p8.nl2sql('what agents do you have', 'p8.Agent')
select * from p8.nl2sql('what agents do you have', 'p8.Agent', 'deepseek-chat')



--indexing
--this adds nodes to the entity graph so we can call get_entities
--its very important to test this because it uses a watermark method to flush and bad logic can lead to long running queries
select * from p8.add_nodes('p8.AgentModel') 
--^the one above does one iteration up to 1664 records tht cypher can deal with
--the one below iterates until the one above returns 0
select * from p8.insert_entity_nodes('p8.Agent')

--the some flushing method is used for embeddings
select * from p8.insert_entity_embeddings('p8.Agent')

--behind the scenes 
SELECT *  FROM p8.generate_and_fetch_embeddings(
	            'p8.Agent',
	            'description',
	            'default',
	            YOUR_KEY_SUCH_AS_OPENAI
	        )
--which uses a watermarking approach to request embeddings
/* 
one or more columns in the database will be linked to an embedding provider such as 'default'
select * from p8."Agent"
select * from p8."ModelField" where entity_name = 'p8.Agent' and embedding_provider is not null
--we can get specific embeddings like this
SELECT *  FROM p8.generate_requests_for_embeddings('p8.Agent', 'description', 'text-embedding-ada-002')

--this snippet makes the payload - as per the comments it needs to be a json array of text
            WITH request AS (
                        SELECT * 
                        FROM p8.generate_requests_for_embeddings('p8.Agent', 'description', 'text-embedding-ada-002')
                        LIMIT 1000
                    ),
            payload AS (
                --the payload is an array of cells with a description
                SELECT jsonb_agg(description) AS aggregated_data
                --SELECT jsonb_build_array(description) AS aggregated_data
                FROM request
            )
            select * from payload
*/
--this allows to always generate embeddings that go into a table
--select * from p8.generate_and_fetch_embeddings('p8.Agent', 'description');
--we cam then insert them -> firstly the low level functions uses batches and watermarks
--until this returns 0 we still have missing embeddings
--select * from p8.insert_generated_embeddings('p8.Agent', 'description')
--flush all with 
--select * from p8.insert_entity_embeddings('p8.Agent')
-- we can then search these - the last parameter is the limit and we loo for the best match here
--	select a.* from p8.get_entity_ids_by_description('something about langauge models', 'p8.Agent', 1) idx 
  -- join p8."Agent" a on a.id = idx.id


--graph nodes
-- this function looks up keys and ids in the graph
-- select * from p8.get_graph_nodes_by_id(ARRAY['p8.Agent'])
-- higher level joins the result of this with the actual tale entity
-- select * from p8.get_graph_nodes_by_id(ARRAY['p8.Agent'])

