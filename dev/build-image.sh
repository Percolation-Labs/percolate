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

# One .so per architecture. A shared library is compiled against one ABI, so
# "multi-arch" for this file means N files, not one clever one -- and the image
# below picks by $TARGETARCH. Cross-building the non-native one runs the whole
# Rust toolchain under emulation and takes the better part of an hour; CI does
# it natively (see get-percolate/.github/workflows/parser.yml), which is why
# PLATFORMS defaults to just the host here.
PLATFORMS=${PLATFORMS:-$(docker version -f '{{.Server.Arch}}')}
mkdir -p dist
for arch in $PLATFORMS; do
  if [ -f "dist/percolate_parser-$arch.so" ] && [ -z "${REBUILD_PARSER:-}" ]; then
    echo "==> percolate_parser ($arch) already built -- REBUILD_PARSER=1 to force"
    continue
  fi
  echo "==> compiling percolate_parser for linux/$arch"
  docker build -q --platform "linux/$arch" -f Dockerfile.pgrx-builder \
    -t "pgrx-builder:$arch" . >/dev/null
  docker run --rm --platform "linux/$arch" \
    -v "$ROOT/extension/percolate_parser":/work \
    -v "$PWD/pgrx-home-$arch":/pgrxhome \
    -e PGRX_HOME=/pgrxhome -e "CARGO_TARGET_DIR=/work/target-$arch" \
    -w /work "pgrx-builder:$arch" bash -c \
    'cargo pgrx init --pg19 /usr/bin/pg_config >/dev/null 2>&1 || true
     cargo pgrx package --features pg19 --no-default-features --pg-config /usr/bin/pg_config' \
    | tail -2
  cp "$ROOT/extension/percolate_parser/target-$arch/release/percolate_parser-pg19/usr/lib/postgresql/19/lib/percolate_parser.so" \
     "dist/percolate_parser-$arch.so"
done

B="$ROOT/extension/percolate_parser/target-$(docker version -f '{{.Server.Arch}}')/release/percolate_parser-pg19"

# the glob must catch percolate_parser--0.1.0.sql, whose name has no dot
# immediately after the stem -- "percolate_parser.*" silently misses it
cp "$B"/usr/share/postgresql/19/extension/percolate_parser* dist/
cp "$ROOT/extension/percolate/percolate.control" dist/
cp "$ROOT/extension/percolate/sql/percolate--0.1.0.sql" dist/

echo "==> building $TAG"
docker build -f Dockerfile.pg19 -t "$TAG" .
echo "==> done. push with: docker push $TAG"
