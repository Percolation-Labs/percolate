#!/bin/bash
# What this image was built from, recorded into the database that gets asked.
#
# dev/ bind-mounts this directory over /docker-entrypoint-initdb.d, which
# REPLACES it, so image-init/00-percolate.sh never runs here and its provenance
# step has to be repeated. The stamp file itself still comes from the image --
# dev/build-image.sh writes it at package time -- so this applies the same file
# the shipped path does rather than restating its contents.
#
# 07, so it runs after the extension exists (01) with no argument about glob
# ordering against 01-percolate.sql. A .sh rather than a .sql because the file
# may legitimately be absent on a hand-assembled image, and psql has no clean
# way to skip a missing \i -- the entrypoint runs .sql with ON_ERROR_STOP=1, so
# an unstamped image would fail to initialise instead of reporting "unknown".
set -e
if [ -f /usr/local/share/percolate/build.sql ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
         -f /usr/local/share/percolate/build.sql >/dev/null
    echo "percolate: build provenance recorded."
else
    echo "percolate: no build stamp in this image -- percolate_build() will be empty."
fi
