// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncServer
import Foundation
import Hummingbird
import Logging

/// Runs the reference sync server.
///
/// Deliberately thin. Everything worth testing — reading the environment, validating it,
/// preparing the database directory — lives in ``Configuration`` in the library, because none of
/// it is reachable by a test from an executable target. What is left here is the order things
/// happen in and what the operator is told.
///
/// **TLS is not terminated here.** Anyone self-hosting already has a reverse proxy — Caddy,
/// nginx, Traefik — that does certificates better than this ever would, and half-doing it here
/// would invite someone to run it directly on the internet with a certificate nobody renews. The
/// app refuses plain HTTP to a public address regardless, which is what makes this safe to say
/// plainly rather than something to work around.

/// Writes a line to standard error.
///
/// Standard error rather than standard output, so that startup notes and diagnostics land in the
/// same stream as the request log — `docker logs` shows both — and a shell pipeline reading
/// stdout is unaffected.
func report(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: Configuration

let environment = ProcessInfo.processInfo.environment

let configuration: Configuration
do {
    configuration = try Configuration.resolve(from: environment)
} catch {
    // Exit 78 is `EX_CONFIG` from sysexits.h: the process is fine, what it was told is not.
    // Docker and systemd both surface the code, and a distinct one saves guessing whether a
    // container that died immediately crashed or was handed something impossible.
    report("cmdv-sync-server: \(error)")
    exit(78)
}

for unrecognized in Configuration.unrecognizedVariables(in: environment) {
    // A warning rather than a failure. A stray `CMDV_SYNC_` variable is nearly always a typo
    // worth mentioning, but refusing to start over one would make this server the awkward member
    // of a compose file that also sets variables for something else.
    report("cmdv-sync-server: warning: \(unrecognized) is set but is not read by this server.")
}

do {
    try configuration.prepareDatabaseDirectory()
} catch {
    report("cmdv-sync-server: \(error)")
    exit(78)
}

// MARK: Logging

// Bootstrapped before anything logs, which is swift-log's requirement, and from the configuration
// so that `CMDV_SYNC_LOG_LEVEL=debug` reaches Hummingbird's own logging as well as this server's.
LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = configuration.logLevel
    return handler
}

// MARK: The server

let store: SyncStore
do {
    store = try SyncStore(
        path: configuration.databasePath,
        passwordIterations: configuration.passwordIterations
    )
} catch {
    // The database is opened and migrated *before* the listener starts, so a database this
    // process cannot use makes the container fail immediately and visibly rather than pass its
    // health check and refuse every sync.
    report("cmdv-sync-server: cannot open the database: \(error)")
    exit(74) // EX_IOERR
}

let server = SyncServer(
    store: store,
    throttle: RegistrationThrottle(limit: configuration.registrationLimit),
    allowedUsernames: configuration.allowedUsernames
)

let application = Application(
    router: server.router(logRequests: configuration.logLevel <= .info ? .info : nil),
    configuration: ApplicationConfiguration(
        address: .hostname(configuration.host, port: configuration.port),
        serverName: "cmdv-sync-server"
    ),
    logger: Logger(label: "cmdv-sync-server")
)

report(
    """
    cmdv-sync-server
    \(configuration.summary)

    TLS is not terminated here. Put this behind a reverse proxy; do not expose it directly.
    """
)

// `runService()` installs handlers for SIGTERM and SIGINT and shuts the listener down gracefully,
// which is what makes `docker stop` finish in-flight requests rather than sever them. It works
// only because the container runs this binary as PID 1 — see the Dockerfile's `ENTRYPOINT`, which
// is in exec form for exactly this reason.
try await application.runService()
