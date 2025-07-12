# First step is to build the the extension
FROM debian:bullseye-slim AS builder

# use the advice from here https://cloudnative-pg.io/blog/creating-container-images/
# but also add in the deps for, and use, the AGE repo (https://age.apache.org/getstarted/quickstart/)
# + PG15 did not seem to work due to a string types issue ?? but i just bumped to 16 and it was fine
# i added libcurl4-openssl-dev for http
RUN set -xe ;\
    apt update && apt install wget lsb-release gnupg2 libcurl4-openssl-dev -y ;\
    sh -c 'echo "deb https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list' ;\
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - ;\
    apt-get update ;\
    apt-get install -y postgresql-server-dev-16 build-essential git libreadline-dev zlib1g-dev flex bison; \
    cd /tmp; \
    git clone https://github.com/apache/age.git; \
    cd /tmp/age; \
    PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config make; \
    PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config make install

RUN git clone https://github.com/pramsey/pgsql-http.git /tmp/pgsql-http; \
    cd /tmp/pgsql-http; \
    make PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config; \
    make install;

# Second step, we build the final image
FROM ghcr.io/cloudnative-pg/postgresql:16.4

# To install any package we need to be root user
USER root

# But this time we copy the .so file and .control and addme script from the build process
COPY --from=builder /usr/lib/postgresql/16/lib/age.so /usr/lib/postgresql/16/lib/
COPY --from=builder /usr/share/postgresql/16/extension/age.control /usr/share/postgresql/16/extension/
COPY  --from=builder /usr/share/postgresql/16/extension/age--1.5.0.sql /usr/share/postgresql/16/extension/
# Copy HTTP extension files
COPY --from=builder /usr/lib/postgresql/16/lib/http.so /usr/lib/postgresql/16/lib/
COPY --from=builder /usr/share/postgresql/16/extension/http.control /usr/share/postgresql/16/extension/
COPY --from=builder /usr/share/postgresql/16/extension/http--1.7.sql /usr/share/postgresql/16/extension/

# add pg vector too
RUN set -xe; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
    "postgresql-16-pgvector" ; \
    rm -fr /tmp/* ; \
    rm -rf /var/lib/apt/lists/*;

# libcurl4 
RUN apt update && apt install libcurl4-openssl-dev -y ;

# Create symlinks for AGE to allow non-superuser access per AGE documentation
# This allows non-superuser roles to access AGE extension functions
RUN mkdir -p /usr/lib/postgresql/16/lib/plugins && \
    ln -s /usr/lib/postgresql/16/lib/age.so /usr/lib/postgresql/16/lib/plugins/age.so || true

# Change the uid of postgres to 26
RUN usermod -u 26 postgres
USER 26

#DOCKER_BUILDKIT=1 docker build --progress=plain --platform linux/amd64  -t postgres-base:16 .
#docker tag postgres-base:16 percolationlabs/postgres-base:16
#docker push percolationlabs/postgres-base:16
