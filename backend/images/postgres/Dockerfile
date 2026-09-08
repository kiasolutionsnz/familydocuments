# syntax=docker/dockerfile:1.7

FROM golang:1.26.6-alpine3.23@sha256:e57c41c1d5864341031181b0db34b9a537bb5773eb6428e4e5bdaea0f9135406 AS gosu-build

RUN apk add --no-cache git
WORKDIR /src
RUN git clone --filter=blob:none https://github.com/tianon/gosu.git . && \
    git checkout --detach 6456aaa0f3c854d199d0f037f068eb97515b7513 && \
    test "$(git rev-parse HEAD)" = "6456aaa0f3c854d199d0f037f068eb97515b7513" && \
    go mod download && \
    go mod verify && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -buildvcs=false \
      -trimpath \
      -ldflags="-s -w -X main.version=1.19-kia.1" \
      -o /out/gosu . && \
    /out/gosu --version

FROM public.ecr.aws/supabase/postgres:17.6.1.159@sha256:86a2e078779e5bdccda1f6f6c5063aa9779a322d1fface5fb408d051909b230f AS patched

COPY --from=gosu-build --chmod=0755 /out/gosu /usr/local/bin/gosu

RUN gosu --version && \
    gosu postgres true && \
    apk del --no-network curl libcurl && \
    ! test -e /usr/bin/curl && \
    ! test -e /usr/lib/libcurl.so.4

FROM scratch

LABEL org.opencontainers.image.title="Family Documents hardened Supabase PostgreSQL" \
      org.opencontainers.image.description="Supabase PostgreSQL 17.6.1.159 with patched gosu and unused curl runtime removed" \
      org.opencontainers.image.source="https://github.com/supabase/postgres" \
      org.opencontainers.image.version="17.6.1.159-kia.3" \
      nz.co.kiasolutions.base.digest="sha256:86a2e078779e5bdccda1f6f6c5063aa9779a322d1fface5fb408d051909b230f" \
      nz.co.kiasolutions.gosu.source="https://github.com/tianon/gosu" \
      nz.co.kiasolutions.gosu.revision="6456aaa0f3c854d199d0f037f068eb97515b7513" \
      nz.co.kiasolutions.gosu.builder="golang:1.26.6-alpine3.23@sha256:e57c41c1d5864341031181b0db34b9a537bb5773eb6428e4e5bdaea0f9135406"

COPY --from=patched / /

ENV PATH=/nix/var/nix/profiles/default/bin:/usr/lib/postgresql/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PGDATA=/var/lib/postgresql/data \
    POSTGRES_HOST=/var/run/postgresql \
    POSTGRES_USER=supabase_admin \
    POSTGRES_DB=postgres \
    POSTGRES_INITDB_ARGS="--allow-group-access --locale-provider=icu --encoding=UTF-8 --icu-locale=en_US.UTF-8" \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    GRN_PLUGINS_DIR=/usr/lib/groonga/plugins \
    LOCALE_ARCHIVE=/nix/var/nix/profiles/default/lib/locale/locale-archive

EXPOSE 5432
STOPSIGNAL SIGINT
HEALTHCHECK --interval=2s --timeout=2s --retries=10 CMD pg_isready -U postgres -h localhost
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres", "-D", "/etc/postgresql"]
