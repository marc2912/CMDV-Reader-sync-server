// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Logging

/// Everything the server reads from its environment.
///
/// Environment variables and no configuration file, deliberately, for something people run in a
/// container: every setting is visible in the command or compose file that started it, and there
/// is no file to mount, template, or forget to update.
///
/// In the library rather than in `main.swift`, because the parsing is where a self-hosted service
/// actually goes wrong — a port that is not a number, a database path in a directory that does
/// not exist, a variable whose name has a typo — and none of that is testable from an executable
/// target.
public struct Configuration: Sendable, Equatable {
    /// Interface to bind.
    ///
    /// All interfaces by default: inside a container, binding to `localhost` makes the server
    /// unreachable from outside it, which is the single most common way a containerised service
    /// appears broken.
    public var host: String = "0.0.0.0"

    public var port: Int = 8080

    /// Where the SQLite database lives. Back this file up.
    public var databasePath: String = "cmdv-sync.sqlite"

    public var logLevel: Logger.Level = .info

    /// The ceiling on registration attempts, or `nil` for none.
    public var registrationLimit: RegistrationThrottle.Limit? = .default

    /// Usernames permitted to hold an account.
    ///
    /// Empty means any, which is the historical behaviour and the right default for a server on
    /// a home network. Setting it closes the gap that otherwise exists the moment this is
    /// reachable from the internet: registration *is* sign-up here, so without a list anyone who
    /// can reach the endpoint and invent a username gets an account and somewhere to keep data.
    public var allowedUsernames: Set<String> = []

    /// PBKDF2 iterations for *new* passwords.
    ///
    /// Exposed because the default costs about 1.35 seconds per hash on fast hardware and
    /// proportionally more on a small ARM board, where it can turn adding a device into a wait long
    /// enough to look like a failure. Lowering it is a real trade against a stolen database, which
    /// is why the floor in ``PasswordHashing/minimumIterations`` exists — but it is the operator's
    /// server and their trade to make.
    ///
    /// Safe to change at any time: the count travels with each stored hash, so existing passwords
    /// keep verifying at whatever they were made with.
    public var passwordIterations: Int = PasswordHashing.iterations

    public init() {}

    /// What went wrong, in terms an operator can act on.
    ///
    /// Every case names the variable and what it was set to. A service that exits saying
    /// "invalid configuration" has told the person running it nothing.
    public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
        case notAnInteger(variable: String, value: String)
        case outOfRange(variable: String, value: String, permitted: String)
        case unknownLogLevel(value: String, permitted: String)
        case emptyValue(variable: String)
        case databaseDirectoryUnusable(path: String, reason: String)

        public var description: String {
            switch self {
            case let .notAnInteger(variable, value):
                "\(variable) must be a whole number, but was set to '\(value)'."
            case let .outOfRange(variable, value, permitted):
                "\(variable) was set to '\(value)', which is outside the permitted range \(permitted)."
            case let .unknownLogLevel(value, permitted):
                "CMDV_SYNC_LOG_LEVEL was set to '\(value)'. It must be one of: \(permitted)."
            case let .emptyValue(variable):
                """
                \(variable) is set but empty. Unset it to take the default rather than setting \
                it to nothing.
                """
            case let .databaseDirectoryUnusable(path, reason):
                """
                The database directory '\(path)' cannot be used: \(reason). If this is a Docker \
                volume, check that it is mounted and that the container's user can write to it.
                """
            }
        }
    }

    /// Every variable this server reads.
    ///
    /// Listed so a name that is *nearly* right can be reported. A mistyped environment variable
    /// that silently does nothing is the most annoying kind of misconfiguration, because the
    /// service starts, looks healthy, and ignores you.
    public static let recognizedVariables: Set<String> = [
        "CMDV_SYNC_HOST",
        "CMDV_SYNC_PORT",
        "CMDV_SYNC_DATABASE",
        "CMDV_SYNC_LOG_LEVEL",
        "CMDV_SYNC_REGISTRATION_ATTEMPTS",
        "CMDV_SYNC_REGISTRATION_WINDOW",
        "CMDV_SYNC_USERNAMES",
        "CMDV_SYNC_PASSWORD_ITERATIONS",
    ]

    /// Reads and validates the environment.
    ///
    /// - Parameter environment: Injected so this is testable. `main.swift` passes
    ///   `ProcessInfo.processInfo.environment`.
    /// - Throws: ``ConfigurationError`` for anything it cannot make sense of. Refused at startup
    ///   rather than defaulted around: a server that silently ignored `CMDV_SYNC_PORT=80800` and
    ///   listened on 8080 would be a worse outcome than one that would not start.
    public static func resolve(from environment: [String: String]) throws -> Configuration {
        var configuration = Configuration()

        if let host = try value("CMDV_SYNC_HOST", in: environment) {
            configuration.host = host
        }

        if let port = try integer("CMDV_SYNC_PORT", in: environment) {
            guard (1 ... 65535).contains(port) else {
                throw ConfigurationError.outOfRange(
                    variable: "CMDV_SYNC_PORT",
                    value: String(port),
                    permitted: "1–65535"
                )
            }
            configuration.port = port
        }

        if let database = try value("CMDV_SYNC_DATABASE", in: environment) {
            configuration.databasePath = database
        }

        if let level = try value("CMDV_SYNC_LOG_LEVEL", in: environment) {
            guard let parsed = Logger.Level(rawValue: level.lowercased()) else {
                throw ConfigurationError.unknownLogLevel(
                    value: level,
                    permitted: Logger.Level.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            configuration.logLevel = parsed
        }

        // Zero disables, rather than there being a separate on/off variable to keep consistent
        // with it. Negative is refused, because it is a mistake rather than an intent.
        let attempts = try integer("CMDV_SYNC_REGISTRATION_ATTEMPTS", in: environment)
        let window = try integer("CMDV_SYNC_REGISTRATION_WINDOW", in: environment)
        for (variable, given) in [
            ("CMDV_SYNC_REGISTRATION_ATTEMPTS", attempts),
            ("CMDV_SYNC_REGISTRATION_WINDOW", window),
        ] {
            if let given, given < 0 {
                throw ConfigurationError.outOfRange(
                    variable: variable,
                    value: String(given),
                    permitted: "0 or greater"
                )
            }
        }
        if attempts == 0 {
            configuration.registrationLimit = nil
        } else if attempts != nil || window != nil {
            configuration.registrationLimit = RegistrationThrottle.Limit(
                attempts: attempts ?? RegistrationThrottle.Limit.default.attempts,
                window: TimeInterval(
                    window ?? Int(RegistrationThrottle.Limit.default.window)
                )
            )
        }

        if let usernames = try value("CMDV_SYNC_USERNAMES", in: environment) {
            // Split on commas and trimmed, so `alice, bob` works as well as `alice,bob`. A list
            // that arrived with a stray space and silently allowed an account named " bob"
            // would be a genuinely hard afternoon.
            configuration.allowedUsernames = Set(
                usernames
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            guard !configuration.allowedUsernames.isEmpty else {
                throw ConfigurationError.emptyValue(variable: "CMDV_SYNC_USERNAMES")
            }
        }

        if let iterations = try integer("CMDV_SYNC_PASSWORD_ITERATIONS", in: environment) {
            guard iterations >= PasswordHashing.minimumIterations else {
                throw ConfigurationError.outOfRange(
                    variable: "CMDV_SYNC_PASSWORD_ITERATIONS",
                    value: String(iterations),
                    permitted: """
                    \(PasswordHashing.minimumIterations) or greater \
                    (the default is \(PasswordHashing.iterations))
                    """
                )
            }
            configuration.passwordIterations = iterations
        }

        return configuration
    }

    /// Names in the environment that look like they were meant for this server but are not read.
    ///
    /// Returned rather than thrown. A stray `CMDV_SYNC_` variable is nearly always a typo worth
    /// mentioning, but refusing to start over one would make this server the awkward member of a
    /// compose file that also sets variables for something else.
    public static func unrecognizedVariables(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { $0.hasPrefix("CMDV_SYNC_") && !recognizedVariables.contains($0) }
            .sorted()
    }

    /// The configuration as an operator sees it at startup.
    ///
    /// No secrets appear in it, because none are configured this way — there is no admin
    /// password and no API key. The username list is shown because knowing whether it took
    /// effect is the whole reason to set it.
    public var summary: String {
        let registration =
            if let registrationLimit {
                """
                \(registrationLimit.attempts) attempt(s) per \
                \(Int(registrationLimit.window))s
                """
            } else {
                "unlimited"
            }
        return """
        listening on:  \(host):\(port)
        database:      \(databasePath)
        log level:     \(logLevel.rawValue)
        registration:  \(registration)
        usernames:     \(allowedUsernames.isEmpty
            ? "any" : allowedUsernames.sorted().joined(separator: ", "))
        pbkdf2:        \(passwordIterations) iterations\
        \(passwordIterations == PasswordHashing.iterations ? "" : " (not the default)")
        """
    }

    // MARK: Reading

    /// A variable's value, or `nil` when it is not set at all.
    ///
    /// A variable that is *set but empty* is refused rather than treated as unset. `PORT=""` in a
    /// compose file is a mistake every time, and defaulting it hides that.
    private static func value(
        _ variable: String,
        in environment: [String: String]
    ) throws -> String? {
        guard let raw = environment[variable] else { return nil }
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ConfigurationError.emptyValue(variable: variable)
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private static func integer(
        _ variable: String,
        in environment: [String: String]
    ) throws -> Int? {
        guard let raw = try value(variable, in: environment) else { return nil }
        guard let parsed = Int(raw) else {
            throw ConfigurationError.notAnInteger(variable: variable, value: raw)
        }
        return parsed
    }

    // MARK: The database directory

    /// Makes sure the database's directory exists and can be written to, before SQLite tries.
    ///
    /// SQLite's own failure for a missing directory is `unable to open database file`, which
    /// names neither the directory nor the reason, and is what someone with a volume mounted one
    /// path along would spend an evening on. Checked here so the message can say which directory
    /// and why.
    ///
    /// The directory is created if it is missing, since a compose file that names
    /// `/data/cmdv-sync.sqlite` on a fresh volume is the ordinary case rather than an error.
    public func prepareDatabaseDirectory(
        fileManager: FileManager = .default
    ) throws {
        // `:memory:` is not a path at all.
        guard databasePath != ":memory:" else { return }

        // Split by hand rather than through `NSString.deletingLastPathComponent` or `URL`. The
        // first is a bridged API whose availability on Linux is a thing to rely on rather than
        // read, and the second turns a bare filename into an absolute path against the working
        // directory, which would make the "no directory component" case impossible to detect.
        guard let separator = databasePath.lastIndex(of: "/") else {
            // A bare filename: the working directory, which exists by definition.
            return
        }
        let directory = String(databasePath[databasePath.startIndex ..< separator])
        // The root directory, which exists and is not ours to create.
        guard !directory.isEmpty else { return }

        if !fileManager.fileExists(atPath: directory) {
            do {
                try fileManager.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ConfigurationError.databaseDirectoryUnusable(
                    path: directory,
                    reason: "it does not exist and could not be created (\(error.localizedDescription))"
                )
            }
        }

        // WAL mode writes `-wal` and `-shm` files *beside* the database, so a writable database
        // file in a read-only directory is not enough and fails later rather than now.
        guard fileManager.isWritableFile(atPath: directory) else {
            throw ConfigurationError.databaseDirectoryUnusable(
                path: directory,
                reason: "it is not writable by this process"
            )
        }
    }
}
