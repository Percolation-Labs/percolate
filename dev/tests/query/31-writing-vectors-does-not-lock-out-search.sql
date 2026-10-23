-- WRITING VECTORS DOES NOT LOCK OUT SEARCH (REM-1149).
--
-- aiq.record_embeddings registered the model's space on every call, and registering re-runs ALTER TABLE ... OWNER
-- and GRANT, which take an ACCESS EXCLUSIVE lock on the space even when nothing changes. So every batch of vectors
-- blocked every search of that space until its transaction ended, and four writers loading LongMemEval-M at once
-- deadlocked. It now registers a space only when it does not exist. This holds that a write into an existing space
-- takes no lock stronger than ROW EXCLUSIVE on it, and that a first write still creates the space.

\set ON_ERROR_STOP on

begin;

do $$
declare v_strong text[];
begin
    if to_regclass('aiq.emb_demo_quad_a') is null then
        raise exception 'the demo-quad-a space is not loaded (dev/init/05-corpus-sample.sql)';
    end if;
    perform aiq.record_embeddings('demo-quad-a', '[{"chunk_id": "33330000-0000-0000-0000-000000000001", "embedding": [1,0,0,0]}]');
    select array_agg(l.mode) into v_strong
      from pg_locks l
     where l.relation = 'aiq.emb_demo_quad_a'::regclass and l.pid = pg_backend_pid()
       and l.mode in ('ShareUpdateExclusiveLock', 'ShareLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock');
    if v_strong is not null then
        raise exception 'writing one vector into an existing space took % on it, which blocks every search of the space', v_strong;
    end if;

    -- A model with no space yet still gets one on its first write.
    insert into aiq.embedding_models (name, dim) values ('test-quad-first-write', 4);
    perform aiq.record_embeddings('test-quad-first-write', '[{"chunk_id": "33330000-0000-0000-0000-000000000001", "embedding": [0,1,0,0]}]');
    if to_regclass('aiq.' || quote_ident(aiq.embedding_space_name('test-quad-first-write'))) is null then
        raise exception 'a first write into a model with no space did not create one';
    end if;
    raise notice 'query/31: a write into an existing space takes no lock that blocks a search, and a first write makes the space';
end $$;

rollback;
