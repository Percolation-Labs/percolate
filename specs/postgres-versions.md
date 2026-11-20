# Which PostgreSQL Percolate runs on

**Percolate is supported on PostgreSQL 19, the only major the gate runs**
(REM-1084): the published image is built on it, `dev/check.sh` runs against it,
and get-percolate's own-Postgres check runs on `postgres:19.0-bookworm`. Nothing
in the SQL is newer than 18, since `uuidv7()` is the newest construct it uses,
and 18 passed 41 of 43 gates once on 1 October (below). No gate runs it, so 18 is
a measured possibility and not a supported version. It used to need a PostgreSQL 19 beta
for SQL/PGQ, which declared one property graph, `aiq.knowledge_graph`, read by
`GRAPH` depth 1. SQL/PGQ was withdrawn from PostgreSQL 19 before GA (October
2026). The graph was only ever a view over `aiq.nodes` and `aiq.edges_current`,
so depth 1 became the join the reverse direction already used, and the object
is gone (`ai-query-layer/schema.sql` §5). That removal ships in 0.2.20.

## What was measured, 1 October 2026

| Server | How | Result |
|---|---|---|
| PG19 beta3, the published image | `dev/check.sh` on a CI-built database | 43 of 43 gates |
| PG18.6, a local image | branch `amartey/pg18-image`: both Dockerfiles on `postgres:18-bookworm`, parser built with `--features pg18`, then `dev/check.sh` | 41 of 43 |

The two PG18 failures are about switching what is published, not about the
extension:

- **Upgrading from 0.2.19 cannot run on 18.** 0.2.19 declares the property graph,
  so no released version installs on a PG18 server. The upgrade it tests is the
  one existing PG19 databases take, and it passes on 19. On 18 the first upgrade
  path starts at the first release published on 18. Replaying 0.2.20's own
  upgrade body converges on 18 (5,195 objects).
- **REM-11 and REM-78 name `dev/Dockerfile.pg19` as their spec.**

## On 19.0 since 20 November 2026 (REM-1358)

PostgreSQL 19.0 shipped on 19 November. Both Dockerfiles moved from
`postgres:19beta3-bookworm` to `postgres:19.0-bookworm`, which also moves the
parser's headers, pgvector 0.8.6 and the patched pg_cron 1.6.7 onto 19.0. The
parser still builds on pgrx 0.19.2. Measured on arm64 before the release:

| Check | Result |
|---|---|
| `dev/check.sh` on a CI-built database | 40 of 40 gates |
| Memory retrieval (the train's measure: Mem0 twice, LongMemEval S) | equal to 0.2.43 in all seven columns |
| Production's backup restored with `check-restore.sh` | every table loaded, no errors |
| The app's 16-step journey check, on a local app over that restored 19.0 core | 16 of 16, once restores reset their sequences (percolate-application 750876b9) |
| The cutover, rehearsed with production's layout and data (beta3 stopped, `pgdata` set aside, dumped from it, 19.0 on a fresh `pgdata`) | all 205 tables' counts identical, the four pg_cron jobs recreated, 15 s from stop to restored |

**A beta3 data directory does not open under 19.0.** The catalog version moved
from 202607272 to 202610061 and pg_control from 1902 to 1905. So moving an
existing 19 beta database is a dump and restore (or pg_upgrade), not an image
swap. Production moves by restoring its data-only backup
(`deploy/hetzner/restore-data.sh` in percolate-application).

## The published image stays on 19

Decided 1 October 2026: the image stays on PostgreSQL 19 and moves to 19 GA
when it ships. The point of removing SQL/PGQ was not to leave 19 but to stop
depending on something 19 will not have. PG18 support is a measured fact, kept
so that a deployment that cannot run 19 is not stuck, not a migration plan.

If the image ever does move to 18, the build is on branch `amartey/pg18-image`
(both Dockerfiles, the parser's default feature, no pg_cron patch), and three
things move with it: get-percolate's `image-postgres.yml`, which builds from
`dev/Dockerfile.pg19` and tags `19-<version>`; the `19` spelled in compose,
`dev/ci-database.sh`'s default image and the scripts that start a published
release; and production's data, since a 19 data directory cannot be read by 18
and moving is a dump and restore.
