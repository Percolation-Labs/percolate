# Research-platform scale harness

Does every function a signed-in caller can execute cost the same whatever the size of the tables?
[`specs/research-platform/scale.md`](../../../specs/research-platform/scale.md) holds the answer and how it was
decided. This directory is how to get it again (REM-500).

```sh
docker run -d --name rem500-scale -e POSTGRES_PASSWORD=x -e POSTGRES_DB=scale \
  percolationlabs/percolate-postgres:19-0.2.10 -c shared_buffers=1GB -c work_mem=16MB
# upgrade to the extension under test as app_owner, then one database per size:
docker exec rem500-scale psql -U postgres -c "create database s8000 template scale"
docker exec -i rem500-scale psql -U postgres -d s8000 -v works=8000 < generate.sql
python3 probe.py rem500-scale s8000 results/base-8k.json 3
docker exec -i rem500-scale psql -U postgres -d s8000 < fixes.sql     # candidate fixes, then probe again
```

| File | What it does |
|---|---|
| `generate.sql` | A corpus of `works` works straight into core's tables: 12 claims, 10 sources and 10 edges per work, votes, comments, endorsements, saves, visibility spread. Deterministic ids. About 13 KB per work, so 80,000 works is 1 GB |
| `probe.py` | Every probe as `authenticated` with a real person's claims, warm, rolled back; pages per call from `EXPLAIN (ANALYZE, BUFFERS)`. Refuses a corpus with a dangling reference. `ONCE="a|b"` measures a probe with one call, `SKIP="a|b"` skips it; both for calls already shown to scan, where one call takes minutes |
| `fixes.sql` | The indexes and the two functions (`list_listed`, `search_claims`) that `scale.md` §2 measured |
| `results/` | The runs `scale.md` reports: base and fixed, at 8,000 and 80,000 works, and `sources-*` for `search_sources` (REM-519) |

**Mind the disk.** 250,000 works is about 4 GB and filled a shared laptop on 18 September. Drop each
database when its probe is done, or point the harness at a machine with room.

**Adding a function to core means adding a probe here.** A function that is not probed is a function
nobody has shown to hold, and every defect this directory found was invisible at fixture size.
