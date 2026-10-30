insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, notes)
values ('bge-small-en-v1.5', 384, 'fastembed', 'BAAI/bge-small-en-v1.5', null,
        'runs inside the worker through fastembed, so it needs no key')
on conflict (name) do nothing;
set role app_owner;
select aiq.register_embedding_space('bge-small-en-v1.5');
reset role;
select claims.install_fact_question_workflow('bge-small-en-v1.5');
