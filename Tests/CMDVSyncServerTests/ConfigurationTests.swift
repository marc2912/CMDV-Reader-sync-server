// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Logging
import Testing

@testable import CMDVSyncServer

/// Reading the environment.
///
/// Worth a suite of its own, because this is where a self-hosted service actually goes wrong. Nobody
/// mistypes a route; everybody eventually mistypes an environment variable, and the failure people
/// remember is the one where the service started anyway and ignored them.
@Suite("Configuration")
struct ConfigurationTests {
    @Test("An empty environment gives values that work unchanged in a container")
    func defaults() throws {
        let configuration = try Configuration.resolve(from: [:])
        // All interfaces, because inside a container `localhost` is unreachable from outside it.
        #expect(configuration.host == "0.0.0.0")
        #expect(configuration.port == 8080)
        #expect(configuration.databasePath == "cmdv-sync.sqlite")
        #expect(configuration.logLevel == .info)
        #expect(configuration.allowedUsernames.isEmpty)
        // The two defaults that must not be permissive.
        #expect(configuration.registrationLimit == .default)
        #expect(configuration.passwordIterations == PasswordHashing.iterations)
    }

    // MARK: Password iterations

    @Test("The iteration count can be lowered for slow hardware")
    func iterationsCanBeLowered() throws {
        let configuration = try Configuration.resolve(
            from: ["CMDV_SYNC_PASSWORD_ITERATIONS": "100000"]
        )
        #expect(configuration.passwordIterations == 100_000)
        // Shown as not the default, so an operator reading the log knows the trade is in effect.
        #expect(configuration.summary.contains("not the default"))
    }

    /// The floor exists to catch a dropped digit — 60,000 is a defensible trade and 6,000 is the
    /// same number with a mistake in it.
    @Test("An iteration count below the floor is refused, and the message gives the floor")
    func iterationsHaveAFloor() throws {
        let error = #expect(throws: Configuration.ConfigurationError.self) {
            try Configuration.resolve(from: ["CMDV_SYNC_PASSWORD_ITERATIONS": "6000"])
        }
        let description = try #require(error?.description)
        #expect(description.contains(String(PasswordHashing.minimumIterations)))
        #expect(description.contains(String(PasswordHashing.iterations)))
    }

    @Test("The default iteration count is not announced as unusual")
    func defaultIterationsAreQuiet() throws {
        let configuration = try Configuration.resolve(from: [:])
        #expect(!configuration.summary.contains("not the default"))
        #expect(configuration.summary.contains("600000 iterations"))
    }

    @Test("Every setting can be given")
    func everySetting() throws {
        let configuration = try Configuration.resolve(from: [
            "CMDV_SYNC_HOST": "127.0.0.1",
            "CMDV_SYNC_PORT": "9000",
            "CMDV_SYNC_DATABASE": "/data/sync.sqlite",
            "CMDV_SYNC_LOG_LEVEL": "debug",
            "CMDV_SYNC_REGISTRATION_ATTEMPTS": "4",
            "CMDV_SYNC_REGISTRATION_WINDOW": "60",
            "CMDV_SYNC_USERNAMES": "alice,bob",
            "CMDV_SYNC_PASSWORD_ITERATIONS": "210000",
        ])
        #expect(configuration.host == "127.0.0.1")
        #expect(configuration.port == 9000)
        #expect(configuration.databasePath == "/data/sync.sqlite")
        #expect(configuration.logLevel == .debug)
        #expect(configuration.registrationLimit == .init(attempts: 4, window: 60))
        #expect(configuration.allowedUsernames == ["alice", "bob"])
        #expect(configuration.passwordIterations == 210_000)
    }

    // MARK: Refusals

    /// Refused rather than defaulted around. A server that silently ignored `CMDV_SYNC_PORT=80800`
    /// and listened on 8080 would be a worse outcome than one that would not start.
    @Test("A port that is not a number is refused, and the message says which variable")
    func portMustBeANumber() throws {
        #expect(throws: Configuration.ConfigurationError.notAnInteger(
            variable: "CMDV_SYNC_PORT",
            value: "eighty"
        )) {
            try Configuration.resolve(from: ["CMDV_SYNC_PORT": "eighty"])
        }
    }

    @Test("A port outside the range a port can take is refused", arguments: ["0", "65536", "-1"])
    func portMustBeInRange(_ port: String) throws {
        #expect(throws: (any Error).self) {
            try Configuration.resolve(from: ["CMDV_SYNC_PORT": port])
        }
    }

    /// `PORT=""` in a compose file is a mistake every time, and defaulting it hides that.
    @Test(
        "A variable that is set but empty is refused rather than treated as unset",
        arguments: ["CMDV_SYNC_HOST", "CMDV_SYNC_PORT", "CMDV_SYNC_DATABASE", "CMDV_SYNC_USERNAMES"]
    )
    func emptyIsNotUnset(_ variable: String) throws {
        #expect(throws: Configuration.ConfigurationError.emptyValue(variable: variable)) {
            try Configuration.resolve(from: [variable: "   "])
        }
    }

    @Test("A log level that is not a log level is refused, and the message lists the real ones")
    func logLevelMustBeKnown() throws {
        let error = #expect(throws: Configuration.ConfigurationError.self) {
            try Configuration.resolve(from: ["CMDV_SYNC_LOG_LEVEL": "verbose"])
        }
        let description = try #require(error?.description)
        #expect(description.contains("verbose"))
        #expect(description.contains("trace"))
        #expect(description.contains("critical"))
    }

    @Test("A log level is accepted whatever its case")
    func logLevelIsCaseInsensitive() throws {
        let configuration = try Configuration.resolve(from: ["CMDV_SYNC_LOG_LEVEL": "WARNING"])
        #expect(configuration.logLevel == .warning)
    }

    @Test("A negative registration limit is a mistake rather than an intent")
    func negativeLimitsAreRefused() throws {
        #expect(throws: (any Error).self) {
            try Configuration.resolve(from: ["CMDV_SYNC_REGISTRATION_ATTEMPTS": "-5"])
        }
        #expect(throws: (any Error).self) {
            try Configuration.resolve(from: ["CMDV_SYNC_REGISTRATION_WINDOW": "-5"])
        }
    }

    // MARK: Throttling

    /// Zero disables it, rather than there being a separate on/off variable to keep consistent with
    /// the number.
    @Test("Zero attempts means no throttling")
    func zeroDisablesThrottling() throws {
        let configuration = try Configuration.resolve(
            from: ["CMDV_SYNC_REGISTRATION_ATTEMPTS": "0"]
        )
        #expect(configuration.registrationLimit == nil)
    }

    @Test("Giving one of the two throttle settings keeps the default for the other")
    func partialThrottleSettings() throws {
        let attemptsOnly = try Configuration.resolve(
            from: ["CMDV_SYNC_REGISTRATION_ATTEMPTS": "50"]
        )
        #expect(attemptsOnly.registrationLimit?.attempts == 50)
        #expect(attemptsOnly.registrationLimit?.window == RegistrationThrottle.Limit.default.window)

        let windowOnly = try Configuration.resolve(from: ["CMDV_SYNC_REGISTRATION_WINDOW": "30"])
        #expect(windowOnly.registrationLimit?.window == 30)
        #expect(
            windowOnly.registrationLimit?.attempts == RegistrationThrottle.Limit.default.attempts
        )
    }

    // MARK: The username list

    @Test("A username list survives the spaces people put after commas")
    func usernamesAreTrimmed() throws {
        let configuration = try Configuration.resolve(
            from: ["CMDV_SYNC_USERNAMES": " alice , bob ,, carol "]
        )
        #expect(configuration.allowedUsernames == ["alice", "bob", "carol"])
    }

    @Test("A username list of nothing but separators is refused")
    func usernamesCannotBeAllSeparators() throws {
        #expect(throws: Configuration.ConfigurationError.emptyValue(
            variable: "CMDV_SYNC_USERNAMES"
        )) {
            try Configuration.resolve(from: ["CMDV_SYNC_USERNAMES": ",,,"])
        }
    }

    // MARK: Typos

    /// A mistyped variable that silently does nothing is the most annoying kind of
    /// misconfiguration, because the service starts, looks healthy, and ignores you.
    @Test("A variable that looks like ours but is not is reported")
    func unrecognizedVariablesAreReported() {
        let unrecognized = Configuration.unrecognizedVariables(in: [
            "CMDV_SYNC_PORT": "8080",
            "CMDV_SYNC_DATABSE": "/data/sync.sqlite", // transposed
            "CMDV_SYNC_TLS_CERT": "/etc/cert.pem", // never a thing here
            "PATH": "/usr/bin",
        ])
        #expect(unrecognized == ["CMDV_SYNC_DATABSE", "CMDV_SYNC_TLS_CERT"])
    }

    @Test("Every variable the documentation lists is actually read")
    func recognizedVariablesAreAllHonoured() throws {
        // Guards against a variable being added to the list for the warning's benefit and never
        // wired up — which would make the warning lie in the other direction.
        for variable in Configuration.recognizedVariables {
            #expect(
                Configuration.unrecognizedVariables(in: [variable: "x"]).isEmpty,
                "\(variable) is listed as recognised"
            )
        }
    }

    // MARK: The database directory

    /// SQLite's own failure for a missing directory is `unable to open database file`, which names
    /// neither the directory nor the reason.
    @Test("A missing database directory is created rather than failing later")
    func databaseDirectoryIsCreated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdv-sync-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        var configuration = Configuration()
        configuration.databasePath = root
            .appendingPathComponent("nested")
            .appendingPathComponent("sync.sqlite")
            .path

        try configuration.prepareDatabaseDirectory()
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("nested").path
            )
        )
    }

    @Test("An in-memory database needs no directory")
    func inMemoryNeedsNoDirectory() throws {
        var configuration = Configuration()
        configuration.databasePath = ":memory:"
        try configuration.prepareDatabaseDirectory()
    }

    @Test("A bare filename means the working directory and needs no preparation")
    func bareFilenameNeedsNoDirectory() throws {
        var configuration = Configuration()
        configuration.databasePath = "cmdv-sync.sqlite"
        try configuration.prepareDatabaseDirectory()
    }

    /// A database file in a read-only directory is not enough: WAL mode writes `-wal` and `-shm`
    /// beside it, so this has to be caught now rather than on the first write.
    @Test("A directory that cannot be written to is reported, with the path and the reason")
    func unwritableDirectoryIsReported() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdv-sync-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o500]
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        var configuration = Configuration()
        configuration.databasePath = root.appendingPathComponent("sync.sqlite").path

        let error = #expect(throws: Configuration.ConfigurationError.self) {
            try configuration.prepareDatabaseDirectory()
        }
        let description = try #require(error?.description)
        #expect(description.contains(root.path))
        #expect(description.contains("not writable"))
        // Says where to look, because a Docker volume mounted one path along is the usual cause.
        #expect(description.contains("Docker volume"))
    }

    // MARK: What the operator is shown

    @Test("The startup summary shows every setting and no secret")
    func summaryIsComplete() throws {
        let configuration = try Configuration.resolve(from: [
            "CMDV_SYNC_PORT": "9000",
            "CMDV_SYNC_DATABASE": "/data/sync.sqlite",
            "CMDV_SYNC_USERNAMES": "alice",
        ])
        let summary = configuration.summary
        #expect(summary.contains("0.0.0.0:9000"))
        #expect(summary.contains("/data/sync.sqlite"))
        #expect(summary.contains("alice"))
        #expect(summary.contains("10 attempt(s) per 300s"))
    }

    @Test("An unthrottled server says so rather than showing a blank")
    func summarySaysWhenThrottlingIsOff() throws {
        let configuration = try Configuration.resolve(
            from: ["CMDV_SYNC_REGISTRATION_ATTEMPTS": "0"]
        )
        #expect(configuration.summary.contains("unlimited"))
    }
}
