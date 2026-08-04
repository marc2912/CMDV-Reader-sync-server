# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# syntax=docker/dockerfile:1

# Swift 6.1 is the floor, not a preference: Hummingbird's own manifest declares
# swift-tools-version 6.1, so an older toolchain cannot read its package graph. Overridable so
# you can move forward without editing this file:
#
#   docker build --build-arg SWIFT_VERSION=6.2 -t cmdv-sync-server .
ARG SWIFT_VERSION=6.1

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------
FROM swift:${SWIFT_VERSION}-noble AS build

# SQLite's headers, for the `CSQLiteShim` target. The server reaches SQLite through its C API
# rather than an ORM, and through a shim rather than `import SQLite3` — which is Apple-only, and
# this is the platform that makes the shim worth having.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Manifests alone first, so editing a source file does not re-resolve and re-fetch the whole
# dependency graph. `Package.resolved` is committed and copied deliberately: it is what makes two
# people building this six months apart get the same server.
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Tests before sources, and that order is not arbitrary. Docker invalidates every layer after the
# one that changed, so with sources last, editing a source file rebuilds one layer instead of two.
#
# The test sources have to be here at all — even though this only builds the executable — because
# SwiftPM will not load a manifest whose declared target directories are missing. Leave them out
# and the build fails with `target at '/src/Sources' contains mixed language source files`, which
# says nothing about the actual cause. Do not "optimise" this line away.
COPY Tests ./Tests
COPY Sources ./Sources

RUN swift build -c release --product cmdv-sync-server \
    && install -Dm755 \
        "$(swift build -c release --product cmdv-sync-server --show-bin-path)/cmdv-sync-server" \
        /out/cmdv-sync-server

# ---------------------------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------------------------
# The `-slim` image carries Swift's runtime libraries without the compiler and toolchain, which
# is the difference between an image of a few hundred megabytes and one of several gigabytes.
FROM swift:${SWIFT_VERSION}-noble-slim AS runtime

# `libsqlite3-0` is the library the binary links against, and `curl` is here for the health check
# below. No `ca-certificates`: this server makes no outbound connections, and the health check is
# plain HTTP to the loopback address.
#
# `sqlite3`, the command-line tool, earns its couple of megabytes: the database is in WAL mode, so
# copying the file while the server runs can capture a torn state, and a correct backup needs
# SQLite's online backup API. Shipping the tool is what makes the backup procedure in the README
# something you can run rather than something you first have to install.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 sqlite3 curl \
    && rm -rf /var/lib/apt/lists/*

# An unprivileged user, because nothing here needs root and a sync server holding a household's
# reading history is a poor place to find out otherwise. The identifier is fixed at 1001 rather
# than left to the system so that a bind mount's ownership can be matched deliberately — see the
# README on bind mounts, which is the one setup where this needs thinking about.
RUN groupadd --system --gid 1001 cmdv \
    && useradd --system --uid 1001 --gid cmdv --no-create-home --shell /usr/sbin/nologin cmdv \
    && mkdir -p /data \
    && chown cmdv:cmdv /data

COPY --from=build /out/cmdv-sync-server /usr/local/bin/cmdv-sync-server

USER cmdv:cmdv

# `/data` rather than the working directory, so the database is somewhere a volume obviously
# belongs and nobody has to discover that it landed next to the binary.
ENV CMDV_SYNC_DATABASE=/data/cmdv-sync.sqlite
WORKDIR /data
VOLUME ["/data"]

# Documentation, not a firewall: `EXPOSE` publishes nothing on its own. Change the port with
# `CMDV_SYNC_PORT` and map it with `-p`; the health check below follows it.
EXPOSE 8080

# Shell form on purpose, so `${CMDV_SYNC_PORT}` is expanded at run time and the check still works
# when the port has been changed. It asks the same unauthenticated endpoint a monitor would.
#
# Liveness only — it deliberately does not touch the database. A health check that took the same
# lock as a sync could fail while the server was merely busy, and Docker would answer that by
# restarting a working server in a loop. A database this process cannot use is caught at startup
# instead, before the listener opens, so that failure is immediate and visible in the logs.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${CMDV_SYNC_PORT:-8080}/api/v1/health" || exit 1

# Exec form, which is what makes `docker stop` work properly: the binary runs as PID 1 and
# receives SIGTERM directly, and Hummingbird shuts the listener down gracefully rather than
# severing in-flight syncs. Wrapped in a shell it would be the shell that got the signal.
ENTRYPOINT ["/usr/local/bin/cmdv-sync-server"]
