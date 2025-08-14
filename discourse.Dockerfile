# build pg_cjk_parser
ARG POSTGRES_VERSION=15

FROM postgres:${POSTGRES_VERSION} AS build-cjk
ARG POSTGRES_VERSION=15
RUN apt-get update \
	&& apt-get install -y --no-install-recommends postgresql-server-dev-${POSTGRES_VERSION} gcc make icu-devtools libicu-dev \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /root/parser
COPY pg_cjk_parser.c pg_cjk_parser.control Makefile pg_cjk_parser--0.0.1.sql zht2zhs.h .
RUN make clean && make install


# Install pgvector via PGDG packages (matches PG major)
FROM postgres:${POSTGRES_VERSION}
ARG POSTGRES_VERSION
ARG DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends wget gnupg ca-certificates; \
    . /etc/os-release; \
    echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /usr/share/keyrings/postgresql.gpg; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-${POSTGRES_VERSION}-pgvector; \
    rm -rf /var/lib/apt/lists/*


# Copy installed artifacts from build stage (installed by `make install`)
COPY --from=build-cjk /root/parser/pg_cjk_parser.bc /usr/lib/postgresql/$POSTGRES_VERSION/lib/bitcode
COPY --from=build-cjk /root/parser/pg_cjk_parser.so /usr/lib/postgresql/$POSTGRES_VERSION/lib
COPY --from=build-cjk /root/parser/pg_cjk_parser--0.0.1.sql /usr/share/postgresql/$POSTGRES_VERSION/extension
COPY --from=build-cjk /root/parser/pg_cjk_parser.control /usr/share/postgresql/$POSTGRES_VERSION/extension