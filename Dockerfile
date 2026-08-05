# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# syntax=docker/dockerfile:1

ARG GO_VERSION=1.26

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------
# --platform=$BUILDPLATFORM pins the builder to the machine doing the building, so a cross-build for
# linux/arm64 from an amd64 host compiles natively and cross-links rather than running the whole Go
# toolchain under emulation. That is the difference between seconds and several minutes.
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS build

WORKDIR /src

# Manifests alone first, so editing a source file does not re-download the module graph.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY cmd ./cmd
COPY internal ./internal

# TARGETOS and TARGETARCH are supplied by buildx.
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=dev

# CGO_ENABLED=0 is the load-bearing flag. The SQLite driver is pure Go, so with cgo off the result is
# a static binary with no libc dependency at all — which is what makes both the cross-compile above
# and the near-empty runtime image below possible.
#
# -trimpath keeps build-machine paths out of the binary, so the same source produces the same bytes
# wherever it is built.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" \
        -o /out/cmdv-sync-server ./cmd/cmdv-sync-server

# The volume's mount point has to be created here, because the runtime image has no shell to mkdir
# with. Created with the unprivileged user's ownership so the server can write to it.
RUN mkdir -p /out/data && chown 65532:65532 /out/data

# ---------------------------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------------------------
# distroless static rather than `scratch`, and that is a deliberate two-megabyte trade. `scratch` has
# no /etc/passwd, so an unprivileged user is a bare number with no name; no /tmp; and no CA bundle or
# zone database if either is ever needed. Every one of those absences fails obscurely, in production,
# on somebody else's machine. Two megabytes to remove that class of surprise is cheap.
#
# Everything the server needs beyond this is in the binary: the SQLite engine is compiled in, and the
# health check and the backup are subcommands rather than external tools, precisely because there is
# no shell here to run them with.
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

COPY --from=build --chown=65532:65532 /out/data /data
COPY --from=build /out/cmdv-sync-server /cmdv-sync-server

USER nonroot:nonroot

ENV CMDV_SYNC_DATABASE=/data/cmdv-sync.sqlite
WORKDIR /data
VOLUME ["/data"]

# Documentation, not a firewall: EXPOSE publishes nothing on its own. Change the port with
# CMDV_SYNC_PORT and map it with -p; the health check below follows it without being told.
EXPOSE 8080

# The binary probing itself. Exec form because there is no shell, and it needs none: the subcommand
# reads CMDV_SYNC_PORT from the environment, so the check cannot drift out of step with the port the
# server is actually listening on.
#
# Liveness, deliberately — it asks the same unauthenticated endpoint a monitor would. A database this
# process cannot use is caught at startup, before the listener opens, so that failure is immediate and
# visible in the logs rather than something a health check has to discover.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/cmdv-sync-server", "-health-check"]

# Exec form, which is what makes `docker stop` work properly: the binary runs as PID 1 and receives
# SIGTERM directly, so in-flight syncs finish instead of being severed. Wrapped in a shell it would be
# the shell that got the signal.
ENTRYPOINT ["/cmdv-sync-server"]
