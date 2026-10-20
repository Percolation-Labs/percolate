# Contributing

One command runs every gate CI runs: `dev/check.sh`. It includes the tests, the
upgrade checks and the worked examples from the docs. CI runs the same file, so
a change that passes here passes there.

## What you need

- A full clone. The upgrade scripts start from every released version, which
  the scripts read from the `v*` tags, and a shallow clone has none. If you
  cloned with `--depth`, run `git fetch --tags --unshallow`.
- Docker, with at least 6 GB of memory for building the parser.
- Python 3 with PyYAML (`pip install pyyaml`). The build compiles
  `specs/contract/types/*.yaml`; installing the extension needs no Python.
- bash, git and about 10 GB of free disk. Each release image adds about
  260 MB over the layers they share.

No account, secret or private repository is needed.

## Running it

```bash
dev/check.sh --tree                       # no database: 13 gates, about 5 seconds
REBUILD_PARSER=1 TAG=percolate-postgres:mine dev/build-image.sh
IMAGE=percolate-postgres:mine CONTAINER=p8-mine DB=p8mine dev/ci-database.sh
CONTAINER=p8-mine DB=p8mine dev/check.sh  # all 31 gates
```

`dev/check.sh` without a container runs the tree gates and lists the database
gates it skipped, so a green run always says what it did not ask.

Measured on 20 October 2026 from a fresh clone on an M-series Mac with 8 GB
given to Docker: the image built in 90 seconds with Docker's base layers
already cached, `ci-database.sh` took 7 seconds, and the full `check.sh` took
200 seconds. A first build compiles the pgrx toolchain and takes several
minutes longer. The upgrade gate pulls the published image of every release,
about 30 of them, from Docker Hub.

## Changing the schema

The extension's SQL is generated. Edit `specs/`, then run
`python3 extension/percolate/build-sql.py`, which writes
`extension/percolate/sql/percolate--<version>.sql` and an upgrade script from
each released version. Commit the generated files with the spec change; the
first tree gate fails when they disagree.

`core/` is a read-only mirror of percolate-core. Changes made there are
overwritten by the next sync.

## Pull requests

`.github/workflows/check.yml` sends a pull request from a fork to GitHub's
hosted runners, never to ours, and runs `dev/check.sh` there. To
run the gates before every push, `git config core.hooksPath dev/githooks`.
Each push then reloads `$DB`, so set `DB` to a database of your own.
