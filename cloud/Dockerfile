# syntax=docker/dockerfile:1
#
# Builds a Mix release of the EdgeOS cloud server.
# Target platform: linux/amd64 (Debian Bookworm — matches edgeos-prod-01)
#
# Build:
#   docker build --platform linux/amd64 -t edgeos-cloud .
#
# Run as a container:
#   docker run --env-file .env -p 443:443 edgeos-cloud
#
# Extract release binary for traditional systemd deployment:
#   docker create --name edgeos-extract edgeos-cloud
#   docker cp edgeos-extract:/app/. ./edge_os_cloud_release/
#   docker rm edgeos-extract
#   rsync -a ./edge_os_cloud_release/ user@edgeos-prod-01:/opt/edgeos/edge_os_cloud/

# ─── Rust toolchain stage ────────────────────────────────────────────────────
# Provides a current Rust to compile the ex_sctp NIF — Debian's packaged
# rustc is too old (1.63; ex_sctp needs 1.65+).
FROM rust:slim-bookworm AS rust-base

# ─── Build stage ─────────────────────────────────────────────────────────────
FROM hexpm/elixir:1.17.3-erlang-25.3.1-debian-bookworm-20260421-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=rust-base /usr/local/rustup /usr/local/rustup
COPY --from=rust-base /usr/local/cargo  /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:${PATH}"

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Fetch dependencies first — separate layer for cache efficiency
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

# Compile dependencies
COPY config config/
RUN mix deps.compile

# Digest static assets (no assets/ source dir — all statics are pre-committed in priv/)
COPY priv priv/
RUN mix phx.digest

# Compile app and build release
COPY lib lib/
COPY rel rel/
RUN mix compile && mix release

# ─── Runtime stage ───────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libncurses6 \
    locales \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set locale — required by Erlang
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

RUN groupadd --gid 1000 edgeos \
 && useradd --uid 1000 --gid edgeos --shell /bin/sh --create-home edgeos

WORKDIR /app

COPY --from=builder --chown=edgeos:edgeos /app/_build/prod/rel/edge_os_cloud ./

USER edgeos

# SSL cert/key must be bind-mounted at the paths set in SSL_KEY_PATH / SSL_CERT_PATH
EXPOSE 443
EXPOSE 4000

ENV PHX_SERVER=true

ENTRYPOINT ["/app/bin/edge_os_cloud"]
CMD ["foreground"]
