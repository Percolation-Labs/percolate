insert into aiq.embedding_models (name, dim, provider, endpoint, credential_ref, is_default, notes)
values ('bge-small-en-v1.5', 384, 'fastembed', 'BAAI/bge-small-en-v1.5', null, true,
        'runs inside the worker through fastembed, so it needs no key')
on conflict (name) do nothing;
set role app_owner;
select aiq.register_embedding_space('bge-small-en-v1.5') is not null as space;
reset role;
select aiq.install_source_embed_workflow(array['questions', 'facts', 'chunks']) as embedding;
