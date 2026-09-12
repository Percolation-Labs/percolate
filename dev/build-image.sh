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
PY="${PY:-python3}"
"$PY" "$ROOT/extension/percolate/build-sql.py"

# One .so per architecture. A shared library is compiled against one ABI, so
# "multi-arch" for this file means N files, not one clever one -- and the image
# below picks by $TARGETARCH. Cross-building the non-native one runs the whole
# Rust toolchain under emulation and takes the better part of an hour; CI does
# it natively (see get-percolate/.github/workflows/parser.yml), which is why
# PLATFORMS defaults to just the host here.
PLATFORMS=${PLATFORMS:-$(docker version -f '{{.Server.Arch}}')}
mkdir -p dist
for arch in $PLATFORMS; do
  # "Already built" has to mean "built from THIS source", and it did not. The
  # check was the existence of the file alone, so an edit to src/*.rs left a
  # .so from before it sitting in dist/ and this script reported reusing it as
  # if that were the same thing. Two parser fixes -- the DEPTH error naming a
  # mode the caller had not written, and one caller's build filter narrowing
  # the next caller's answers -- were committed, and every locally built image
  # afterwards still carried the behaviour they fixed. The test suite failed,
  # which is exactly what it is for, and the source it pointed at was already
  # correct: the artifact under it was not.
  #
  # find -newer, not a timestamp comparison in shell: it is one call, it covers
  # every file under src/ without globbing, and -print -quit stops at the first
  # hit rather than listing a tree to throw away.
  if [ -f "dist/percolate_parser-$arch.so" ] && [ -z "${REBUILD_PARSER:-}" ]; then
    stale=$(find "$ROOT/extension/percolate_parser/src" \
                 "$ROOT/extension/percolate_parser/Cargo.toml" \
                 -newer "dist/percolate_parser-$arch.so" -print -quit 2>/dev/null || true)
    if [ -z "$stale" ]; then
      echo "==> percolate_parser ($arch) already built -- REBUILD_PARSER=1 to force"
      continue
    fi
    echo "==> percolate_parser ($arch) is STALE -- ${stale#"$ROOT"/} is newer than it; rebuilding"
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
  # The .so's OWN provenance, written when it is compiled and read back at
  # stamp time. Without this the stamp below would give the parser whatever
  # commit the image happened to be assembled at -- and since the .so is
  # legitimately reused across builds, that is exactly the false "these agree"
  # this whole mechanism exists to stop reporting.
  psha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
  git -C "$ROOT" diff --quiet HEAD 2>/dev/null || psha="$psha-dirty"
  printf '%s %s\n' "$psha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "dist/percolate_parser-$arch.sha"
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
# ---------------------------------------------------------------- provenance
# Stamped HERE because this is where the artifact is made. The commit cannot be
# baked into the generated SQL (it would have to name the commit containing
# itself, and it would make percolate--<v>.sql differ on every build, which
# defeats build-sql.py --check), so the number travels beside the files and is
# applied at install.
#
# -dirty is not decoration. The whole reason this exists is an image built from
# a working tree that did not match any commit; a SHA on its own would have
# described that image as something reproducible, which is the lie worth
# refusing to tell.
SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$ROOT" diff --quiet HEAD 2>/dev/null || SHA="$SHA-dirty"
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The parser answers for itself. A reused .so keeps the commit it was compiled
# at, so percolate_build() reports the two halves disagreeing when they do.
PARCH=$(docker version -f '{{.Server.Arch}}')
if [ -f "dist/percolate_parser-$PARCH.sha" ]; then
  read -r PSHA PBUILT < "dist/percolate_parser-$PARCH.sha"
else
  PSHA=unknown; PBUILT=$BUILT_AT
fi
echo "==> provenance: schema $SHA, parser $PSHA"
cat > dist/percolate-build.sql <<SQL
-- GENERATED by dev/build-image.sh. What this image was assembled from.
select public.percolate_record_build('schema', '$VERSION', '$SHA', '$BUILT_AT');
select public.percolate_record_build('parser', '$VERSION', '$PSHA', '$PBUILT');
SQL

cp "$ROOT/extension/percolate/percolate.control" dist/
# Stale scripts from a previous version would be picked up by the Dockerfile's
# glob and shipped as extra installable versions nobody meant to publish.
rm -f dist/percolate--*.sql
cp "$ROOT/extension/percolate/sql/percolate--$VERSION.sql" dist/
# The upgrade scripts ship too, or `ALTER EXTENSION percolate UPDATE` has
# nothing to run and an existing database stays stranded at the version that
# installed it. build-sql.py generates percolate--<old>--<VERSION>.sql per
# released version; this glob deliberately catches that double-dash form,
# which "percolate--$VERSION.sql" on its own does not.
for up in "$ROOT"/extension/percolate/sql/percolate--*--"$VERSION".sql; do
  [ -e "$up" ] || continue
  cp "$up" dist/
  echo "    upgrade script: $(basename "$up")"
done

echo "==> building $TAG"
docker build -f Dockerfile.pg19 -t "$TAG" .
echo "==> done. push with: docker push $TAG"
