insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, notes)
values ('text-embedding-3-small', 1536, 'openai', 'https://api.openai.com/v1/embeddings', 'LLM_API_KEY',
        'called by the worker with the key it holds as LLM_API_KEY; no secret is stored here')
on conflict (name) do nothing;
set role app_owner;
select aiq.register_embedding_space('text-embedding-3-small');
reset role;
select claims.install_fact_question_workflow('text-embedding-3-small');
