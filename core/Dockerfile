# One image, three entrypoints.
#
# The services share percolate_core.core, so three images would be three builds
# of the same base and three tags to keep in step. One image with different
# `command`s costs a few megabytes of unused extra and removes a whole class of
# "which tag is current" mistakes.
#
#   docker run percolationlabs/percolate-core percolate worker --queue http
#   docker run percolationlabs/percolate-core percolate content serve
#   docker run percolationlabs/percolate-core percolate agent serve
# THE DEPENDENCIES ARE A LAYER OF THEIR OWN, KEYED ON WHAT THEY ARE. Installing
# them with the wheel meant every source change reinstalled all of them, under
# QEMU for amd64: the image job took 12 minutes of a release on 2026-09-19. This
# stage writes the requirement list the install layer below uses, without this
# package's own line, so that layer is reused until a dependency changes, and a
# version bump alone does not invalidate it.
#
# THE LIST IS THE LOCK, PINNED AND HASHED (REM-1151). It used to be pyproject's
# ranges, so every build resolved fresh against whatever PyPI held that minute:
# published 0.2.10 ran pydantic-ai-slim 2.60 while CI and uv.lock were on 2.42,
# and two builds of one commit an hour apart could differ. `--locked` fails the
# build when uv.lock disagrees with pyproject.toml, rather than exporting a lock
# nobody re-resolved. CI installs the same export, so a test run and an image
# of one commit hold the same versions.
#
# EVERY PIP STEP RUNS NATIVELY, FOR THE TARGET PLATFORM. The amd64 image is built
# on an ARM runner, and pip under QEMU took 783 seconds to install what takes 58
# natively (release 35465268934, 2026-09-19). So `spec`, `build` and `deps` run on
# the build platform, `deps` asks pip for the target platform's binary wheels
# (`--platform`, `--only-binary`) and installs them into a directory, and the
# image only copies that directory in. amd64 and arm64 wheels exist for
# everything in [all], which is what `--only-binary=:all:` insists on.
FROM --platform=$BUILDPLATFORM python:3.11-slim AS spec
COPY --from=ghcr.io/astral-sh/uv:0.10.3 /uv /usr/local/bin/uv
WORKDIR /spec
COPY pyproject.toml uv.lock ./
RUN uv export --locked --no-dev --no-emit-project --extra all -o requirements.txt && \
    uv export --locked --no-dev --no-emit-project --extra embed -o embed-requirements.txt

# THE EMBEDDING MODEL IS DOWNLOADED AT BUILD TIME, ON THE BUILD PLATFORM
# (REM-628). fastembed fetches from Hugging Face on first use and caches it. A
# pod doing that at startup needs egress the deployment does not allow
# (REM-555), pays it on every cold start, and fails its first task rather than
# this build. The files are an ONNX graph and a tokenizer, so they are the same
# bytes for both architectures and this stage runs natively whatever it builds
# for. `bge-small-en-v1.5` resolves to Qdrant's quantised ONNX build, 64MB.
FROM --platform=$BUILDPLATFORM python:3.11-slim AS embedmodel
ARG P8_EMBED_MODEL=BAAI/bge-small-en-v1.5
ENV P8_EMBED_MODEL=$P8_EMBED_MODEL
COPY .github/scripts/cache_embedding_model.py /tmp/cache_embedding_model.py
COPY --from=spec /spec/embed-requirements.txt /tmp/embed-requirements.txt
RUN pip install --no-cache-dir -r /tmp/embed-requirements.txt && python /tmp/cache_embedding_model.py && du -sh /embed-cache

FROM --platform=$BUILDPLATFORM python:3.11-slim AS build
WORKDIR /src
COPY pyproject.toml README.md LICENSE ./
COPY percolate_core ./percolate_core
RUN pip install --no-cache-dir build && python -m build --wheel

# The target platform's wheels, installed by the build platform's pip. glibc
# 2.36 is what python:3.11-slim (bookworm) carries, so manylinux 2.17 to 2.36.
FROM --platform=$BUILDPLATFORM python:3.11-slim AS deps
ARG TARGETARCH
RUN arch=$([ "$TARGETARCH" = amd64 ] && echo x86_64 || echo aarch64) && \
    { echo "--only-binary=:all: --python-version 3.11 --implementation cp --platform manylinux2014_$arch"; \
      for g in $(seq 17 36); do echo "--platform manylinux_2_${g}_$arch"; done; } | tr '\n' ' ' > /pip-target
COPY --from=spec /spec/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --target /deps $(cat /pip-target) -r /tmp/requirements.txt && \
    mkdir -p /deps-bin && mv /deps/bin/* /deps-bin/ 2>/dev/null; rm -rf /deps/bin
# Installed from the wheel rather than the source tree, so the image contains
# exactly what a `pip install percolate-core` user gets -- an image that worked
# while the published package did not would be a difference nobody notices
# until a user reports it. --no-deps because the layer above installed them;
# `pip check` refuses the image if the wheel's own metadata asks for anything
# that layer did not give.
COPY --from=build /src/dist/*.whl /tmp/
RUN pip install --no-cache-dir --target /pkg --no-deps $(cat /pip-target) /tmp/*.whl && \
    mkdir -p /pkg-bin && mv /pkg/bin/* /pkg-bin/ && rm -rf /pkg/bin && \
    PYTHONPATH=/deps:/pkg python -m pip check

FROM python:3.11-slim
# Two layers, so a source change reuses the dependency layer.
COPY --from=deps /deps /usr/local/lib/python3.11/site-packages/
COPY --from=deps /deps-bin /usr/local/bin/
COPY --from=deps /pkg /usr/local/lib/python3.11/site-packages/
COPY --from=deps /pkg-bin /usr/local/bin/
# And refused here if what landed is not the lock: the same check CI runs, so an
# image and a test run of one commit are compared rather than assumed equal.
COPY --from=spec /spec/requirements.txt /opt/percolate/requirements.lock.txt
COPY .github/scripts/installed_is_locked.py /tmp/installed_is_locked.py
RUN python /tmp/installed_is_locked.py /opt/percolate/requirements.lock.txt && rm /tmp/installed_is_locked.py

# The embedding model, from the stage above. P8_EMBED_CACHE is where
# local_embed.py looks, and it is read at run time only: nothing in a pod
# writes here, so a missing file is a build that did not run rather than a
# download nobody expected. `percolate ingest embed-selftest` proves it loads
# with the network denied.
COPY --from=embedmodel /embed-cache /opt/percolate/embed-cache
ENV P8_EMBED_CACHE=/opt/percolate/embed-cache

# DuckDB extensions are downloads from extensions.duckdb.org at first use, and a
# worker without egress would otherwise meet that inside a customer's step. They
# are installed here, into the user's home that the services run as, and the
# lake refuses to download at run time unless told to (engine._load).
#
# Fetched, not installed: `install` runs DuckDB, and the amd64 image is built
# on an ARM runner under QEMU, where DuckDB dies with signal 11 (REM-619). So
# the files are downloaded without DuckDB, and `lake doctor` proves they load
# wherever the build runs natively, which is the arm64 image production runs.

# Never root. The services hold no table grants and no filesystem state; there
# is nothing they need root for, and running as root is the default only
# because it is the default.
RUN useradd --create-home --uid 10001 percolate
USER percolate
WORKDIR /home/percolate
ARG BUILDPLATFORM
ARG TARGETPLATFORM
COPY .github/scripts/fetch_duckdb_extensions.py /tmp/fetch_duckdb_extensions.py
RUN python /tmp/fetch_duckdb_extensions.py && \
    if [ "$BUILDPLATFORM" = "$TARGETPLATFORM" ]; then percolate lake doctor >/dev/null || percolate lake doctor; \
    else echo "built for $TARGETPLATFORM on $BUILDPLATFORM: DuckDB is not run under emulation, so the extensions are fetched, not loaded"; fi

# No default command: the three services are equal citizens, and defaulting to
# one of them makes the other two look like afterthoughts.
ENTRYPOINT ["percolate"]
CMD ["--help"]
