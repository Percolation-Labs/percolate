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
# stage writes the requirement list `pip install percolate-core[all]` resolves,
# with the version left out, so the install layer below is reused until a
# dependency changes, and a version bump alone does not invalidate it.
#
# EVERY PIP STEP RUNS NATIVELY, FOR THE TARGET PLATFORM. The amd64 image is built
# on an ARM runner, and pip under QEMU took 783 seconds to install what takes 58
# natively (release 35465268934, 2026-09-19). So `spec`, `build` and `deps` run on
# the build platform, `deps` asks pip for the target platform's binary wheels
# (`--platform`, `--only-binary`) and installs them into a directory, and the
# image only copies that directory in. amd64 and arm64 wheels exist for
# everything in [all], which is what `--only-binary=:all:` insists on.
FROM --platform=$BUILDPLATFORM python:3.11-slim AS spec
COPY pyproject.toml /spec/
RUN python - > /spec/requirements.txt <<'EOF'
import re, tomllib
p = tomllib.load(open("/spec/pyproject.toml", "rb"))["project"]
extras, name = p.get("optional-dependencies", {}), p["name"]
reqs, seen, todo = set(p.get("dependencies", [])), set(), ["all"]
while todo:
    extra = todo.pop()
    if extra in seen:
        continue
    seen.add(extra)
    for r in extras[extra]:
        m = re.fullmatch(re.escape(name) + r"\[(.+)\]", r)
        if m:
            todo += [x.strip() for x in m.group(1).split(",")]
        else:
            reqs.add(r)
print("\n".join(sorted(reqs)))
EOF

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
