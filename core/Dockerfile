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
FROM python:3.11-slim AS build
WORKDIR /src
COPY pyproject.toml README.md LICENSE ./
COPY percolate_core ./percolate_core
RUN pip install --no-cache-dir build && python -m build --wheel

FROM python:3.11-slim
# Installed from the wheel rather than the source tree, so the image contains
# exactly what a `pip install percolate-core` user gets -- an image that worked
# while the published package did not would be a difference nobody notices
# until a user reports it.
COPY --from=build /src/dist/*.whl /tmp/
# The extras suffix cannot be applied to a glob -- pip reads /tmp/*.whl[all]
# as a literal path. Resolve the filename first.
RUN whl=$(ls /tmp/*.whl) && pip install --no-cache-dir "${whl}[all]" && rm /tmp/*.whl

# DuckDB extensions are downloads from extensions.duckdb.org at first use, and a
# worker without egress would otherwise meet that inside a customer's step. They
# are installed here, into the user's home that the services run as, and the
# lake refuses to download at run time unless told to (engine._load).

# Never root. The services hold no table grants and no filesystem state; there
# is nothing they need root for, and running as root is the default only
# because it is the default.
RUN useradd --create-home --uid 10001 percolate
USER percolate
WORKDIR /home/percolate
RUN percolate lake doctor --install >/dev/null || percolate lake doctor

# No default command: the three services are equal citizens, and defaulting to
# one of them makes the other two look like afterthoughts.
ENTRYPOINT ["percolate"]
CMD ["--help"]
