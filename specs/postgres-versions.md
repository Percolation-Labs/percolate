# Which PostgreSQL Percolate runs on

**The extension needs PostgreSQL 18 or later.** Nothing in it is newer than 18:
`uuidv7()` is the newest construct it uses. It used to need a PostgreSQL 19 beta
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

## What moving the published image to 18 takes

- **The release.** get-percolate's `image-postgres.yml` builds the image from
  `dev/Dockerfile.pg19` and tags it `19-<version>`. It has to move in the same
  step as this repository's Dockerfile, or the next release breaks.
- **This repository.** The parser's default feature (`pg19` in
  `extension/percolate_parser/Cargo.toml`), the runtime and builder Dockerfiles,
  and the `19` spelled in `dev/docker-compose.yml`, `dev/ci-database.sh`'s
  default image, the three scripts that start a published release
  (`upgrade-from-every-release.sh`, `upgrade-with-data.sh`, `parser-upgrade.sh`)
  and CI's pins.
- **Production's data.** A PG19 beta data directory cannot be read by 18, and
  `pg_upgrade` does not go backwards. Moving is upgrade the extension to 0.2.20
  on 19 (which drops the property graph), `pg_dump` with the 19 client, and
  restore into an 18 server.

PG19 GA would also work: the SQL needs nothing from it, and the parser builds
with `--features pg19`. Staying on a beta has no reason left.
