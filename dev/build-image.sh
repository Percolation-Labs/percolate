#!/usr/bin/env bash
# Build the Postgres image users actually pull.
#
# Users never run this. It exists because a Rust .so must be compiled for the
# target PG version and architecture -- that step cannot be wished away, it can
# only be moved off the user's path, which is what publishing an image does.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
TAG=${TAG:-percolationlabs/percolate-postgres:19}

echo "==> regenerating percolate--0.1.0.sql from specs/"
python3 "$ROOT/extension/percolate/build-sql.py"

echo "==> compiling percolate_parser"
docker build -q -f Dockerfile.pgrx-builder -t pgrx-builder:latest . >/dev/null
docker run --rm -v "$ROOT/extension/percolate_parser":/work -v "$PWD/pgrx-home":/pgrxhome \
  -w /work pgrx-builder:latest bash -c \
  'export PGRX_HOME=/pgrxhome && cargo pgrx package --features pg19 --no-default-features --pg-config /usr/bin/pg_config' \
  | tail -2

mkdir -p dist
B="$ROOT/extension/percolate_parser/target/release/percolate_parser-pg19"
cp "$B/usr/lib/postgresql/19/lib/percolate_parser.so" dist/
# the glob must catch percolate_parser--0.1.0.sql, whose name has no dot
# immediately after the stem -- "percolate_parser.*" silently misses it
cp "$B"/usr/share/postgresql/19/extension/percolate_parser* dist/
cp "$ROOT/extension/percolate/percolate.control" dist/
cp "$ROOT/extension/percolate/sql/percolate--0.1.0.sql" dist/

echo "==> building $TAG"
docker build -f Dockerfile.pg19 -t "$TAG" .
echo "==> done. push with: docker push $TAG"
