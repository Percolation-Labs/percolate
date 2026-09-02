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

# The version comes from percolate.control, which is where Postgres looks for
# it -- not from a copy in this script that a release would have to remember.
VERSION=$(sed -n "s/^default_version = '\\(.*\\)'/\\1/p" "$ROOT/extension/percolate/percolate.control")
[ -n "$VERSION" ] || { echo "no default_version in percolate.control" >&2; exit 1; }

echo "==> regenerating percolate--$VERSION.sql from specs/"
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

# the glob must catch percolate_parser--<version>.sql, whose name has no dot
# immediately after the stem -- "percolate_parser.*" silently misses it
#
# Guarded, because the parser BUILD above is skipped when dist/ already holds
# the .so while this copy was not: a cleaned target/ tree with a populated
# dist/ is an ordinary state (the .so survives in git-ignored dist/, the build
# tree does not), and it made the script abort on a `cp` for files that were
# already sitting in dist/ from the run that produced them.
if [ -d "$B/usr/share/postgresql/19/extension" ]; then
  # Clear before copying, for the same reason the percolate script is cleared
  # below: dist/ is not rebuilt from scratch, so after a version bump it holds
  # BOTH percolate_parser--<old>.sql and --<new>.sql, and the Dockerfile's glob
  # would copy both into the image. Two installable versions of an extension is
  # not an error Postgres reports -- it is an offer, and one half of it is a
  # version nobody meant to ship.
  rm -f dist/percolate_parser--*.sql
  cp "$B"/usr/share/postgresql/19/extension/percolate_parser* dist/
elif [ ! -f "dist/percolate_parser--$VERSION.sql" ] || [ ! -f dist/percolate_parser.control ]; then
  echo "no parser build tree at $B and dist/ has no percolate_parser SQL --" >&2
  echo "run with REBUILD_PARSER=1 to compile it" >&2
  exit 1
else
  echo "==> reusing dist/percolate_parser SQL (no build tree to copy from)"
fi
cp "$ROOT/extension/percolate/percolate.control" dist/
# Stale scripts from a previous version would be picked up by the Dockerfile's
# glob and shipped as extra installable versions nobody meant to publish.
rm -f dist/percolate--*.sql
cp "$ROOT/extension/percolate/sql/percolate--$VERSION.sql" dist/

echo "==> building $TAG"
docker build -f Dockerfile.pg19 -t "$TAG" .
echo "==> done. push with: docker push $TAG"
