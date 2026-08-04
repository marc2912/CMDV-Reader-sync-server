// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import CSQLiteShim
import Foundation

/// The server's storage.
///
/// SQLite, reached through its C API directly. That choice is worth stating: an ORM would add
/// a dependency and a query language to learn in exchange for hiding four tables and a dozen
/// statements, and the app already reaches SQLite this way for its search index — so this is
/// the same pattern rather than a second one.
///
/// An actor, so the single connection is never touched concurrently, and the connection is a
/// non-`Sendable` class so the compiler enforces that rather than trusting it.
///
/// The whole schema is three tables, and each exists for a reason the wire format explains:
/// accounts, devices with individually revocable tokens, and documents keyed by kind and
/// identity with a monotonic sequence that *is* the cursor.
public actor SyncStore {
    private let connection: SQLiteConnection

    /// How many PBKDF2 iterations new passwords are hashed with.
    ///
    /// Injected rather than fixed for two reasons. The count is meant to rise as hardware
    /// does, and an operator on slow hardware may reasonably want it lower — the count travels
    /// with each stored hash, so changing it never invalidates an existing password. And it
    /// lets the tests use a small number: at the production count, a suite that registers a
    /// few dozen accounts spends half a minute doing nothing but key derivation.
    private let passwordIterations: Int

    /// Where the sequence has reached, cached so a pull does not read it back per page.
    var lastSequence: Int

    public enum StoreError: Error, Equatable {
        case cannotOpen(path: String, message: String)
        case statementFailed(message: String)
    }

    /// Opens or creates the database.
    ///
    /// - Parameter path: A file path, or `":memory:"` for a database that lives only as long
    ///   as the process — which is what the tests use, and what makes them fast and
    ///   independent of one another.
    /// - Parameter passwordIterations: PBKDF2 iterations for *new* passwords. Defaults to
    ///   ``PasswordHashing/iterations``.
    public init(path: String, passwordIterations: Int = PasswordHashing.iterations) throws {
        self.passwordIterations = max(1, passwordIterations)
        do {
            let connection = try SQLiteConnection(path: path)
            // Write-ahead logging, so a long pull by one device does not block another's
            // push. A sync server's traffic is short bursts from several devices at once,
            // which is exactly the case WAL exists for.
            try connection.run("PRAGMA journal_mode = WAL")
            // NORMAL rather than FULL: a sync lost in the seconds before a power cut costs
            // one exchange, which every device simply sends again. FULL would fsync on every
            // document for a durability guarantee the protocol does not need.
            try connection.run("PRAGMA synchronous = NORMAL")
            try connection.run("PRAGMA foreign_keys = ON")
            // Wait rather than fail if the file is momentarily locked. This actor is the only
            // writer inside the process, so the lock this guards against comes from outside it —
            // `sqlite3 .backup`, a WAL checkpoint, a volume snapshot. Without a timeout SQLite
            // returns SQLITE_BUSY immediately, which would surface to a reader as a failed sync
            // during a routine backup.
            try connection.run("PRAGMA busy_timeout = 5000")
            try Self.migrate(connection)
            self.connection = connection
            lastSequence = try Self.readLastSequence(connection)
        } catch let error as SQLiteConnection.ConnectionError {
            throw StoreError(error, path: path)
        }
    }

    /// Runs a body against the connection, translating SQLite's errors into this type's.
    ///
    /// Every method goes through this rather than translating in seven places, and it is the
    /// only reason ``StoreError`` can stay a small closed set.
    func withConnection<Value>(
        _ body: (SQLiteConnection) throws -> Value
    ) throws -> Value {
        do {
            return try body(connection)
        } catch let error as SQLiteConnection.ConnectionError {
            throw StoreError(error, path: "")
        }
    }

    // MARK: Schema

    private static func migrate(_ connection: SQLiteConnection) throws {
        try connection.run(
            """
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY NOT NULL,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """
        )
        try connection.run(
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY NOT NULL,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                device_name TEXT NOT NULL,
                token_hash TEXT NOT NULL,
                registered_at REAL NOT NULL,
                last_seen_at REAL
            )
            """
        )
        // Tokens are looked up by hash on every single request, so it is indexed. The token
        // itself is never stored — see ``SyncServer/hash(token:)``.
        try connection.run("CREATE INDEX IF NOT EXISTS devices_by_token ON devices(token_hash)")
        try connection.run(
            """
            CREATE TABLE IF NOT EXISTS documents (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                document_id TEXT NOT NULL,
                updated_at REAL NOT NULL,
                device_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                UNIQUE(account_id, kind, document_id)
            )
            """
        )
        // Every pull is "everything for this account above this sequence, in order", which
        // this index answers directly.
        try connection.run(
            """
            CREATE INDEX IF NOT EXISTS documents_by_account_sequence
            ON documents(account_id, sequence)
            """
        )
    }

    static func readLastSequence(_ connection: SQLiteConnection) throws -> Int {
        var result = 0
        try connection.query("SELECT IFNULL(MAX(sequence), 0) FROM documents") { row in
            result = row.integer(0)
        }
        return result
    }

    // MARK: Accounts

    /// What resolving a username and password produced.
    public enum AccountResolution: Sendable, Equatable {
        case created(UUID)
        case existing(UUID)
        case passwordRejected
    }

    /// Creates an account, or returns the existing one when the password matches.
    ///
    /// Registration and sign-in are the same operation, deliberately. A household server has
    /// no sign-up flow and no administrator: the first device to use a username creates it,
    /// and every later device with the same password joins it. That is the shape kosync has
    /// and the right one for something set up once — with the consequence, stated rather than
    /// hidden, that a *mistyped* username creates a second empty account rather than
    /// reporting an error. ``accountExists(username:)`` lets a client warn about that first.
    public func account(username: String, password: String) throws -> AccountResolution {
        if let existing = try findAccount(username: username) {
            guard let stored = PasswordHashing.StoredHash(encoded: existing.passwordHash),
                  PasswordHashing.verify(password: password, against: stored)
            else { return .passwordRejected }
            return .existing(existing.id)
        }

        let id = UUID()
        let hash = PasswordHashing.hash(password: password, iterations: passwordIterations).encoded
        try withConnection { connection in
            try connection.execute(
                """
                INSERT INTO accounts (id, username, password_hash, created_at)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(id.uuidString),
                    .text(username),
                    .text(hash),
                    .real(Date().timeIntervalSince1970),
                ]
            )
        }
        return .created(id)
    }

    public func accountExists(username: String) throws -> Bool {
        try findAccount(username: username) != nil
    }

    private func findAccount(username: String) throws -> (id: UUID, passwordHash: String)? {
        try withConnection { connection in
            var found: (UUID, String)?
            try connection.query(
                "SELECT id, password_hash FROM accounts WHERE username = ?",
                bindings: [.text(username)]
            ) { row in
                guard let id = row.uuid(0), let hash = row.text(1) else { return }
                found = (id, hash)
            }
            return found
        }
    }

    // MARK: Devices

    /// Registers a device against an account, replacing any token it already had.
    ///
    /// Re-registering the same device identifier is the ordinary case rather than an error: a
    /// reader who signs out and back in on the same phone gets a new token, and the old one
    /// stops working the moment it is replaced.
    public func registerDevice(
        deviceID: UUID,
        accountID: UUID,
        deviceName: String,
        tokenHash: String,
        at date: Date
    ) throws {
        try withConnection { connection in
            try connection.execute(
                """
                INSERT INTO devices
                    (device_id, account_id, device_name, token_hash, registered_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    account_id = excluded.account_id,
                    device_name = excluded.device_name,
                    token_hash = excluded.token_hash,
                    registered_at = excluded.registered_at
                """,
                bindings: [
                    .text(deviceID.uuidString),
                    .text(accountID.uuidString),
                    .text(deviceName),
                    .text(tokenHash),
                    .real(date.timeIntervalSince1970),
                ]
            )
        }
    }

    /// Finds the device a token belongs to.
    ///
    /// - Returns: `nil` when the token is unknown, which covers both "never existed" and "was
    ///   revoked". They are the same fact to a caller, and distinguishing them would confirm
    ///   to an attacker which tokens once existed.
    public func device(forTokenHash tokenHash: String) throws -> AuthenticatedDevice? {
        try withConnection { connection in
            var found: AuthenticatedDevice?
            try connection.query(
                "SELECT device_id, account_id FROM devices WHERE token_hash = ?",
                bindings: [.text(tokenHash)]
            ) { row in
                guard let deviceID = row.uuid(0), let accountID = row.uuid(1) else { return }
                found = AuthenticatedDevice(deviceID: deviceID, accountID: accountID)
            }
            return found
        }
    }

    public func recordDeviceSeen(_ deviceID: UUID, at date: Date) throws {
        try withConnection { connection in
            try connection.execute(
                "UPDATE devices SET last_seen_at = ? WHERE device_id = ?",
                bindings: [.real(date.timeIntervalSince1970), .text(deviceID.uuidString)]
            )
        }
    }

    public func devices(forAccountID accountID: UUID) throws -> [SyncDeviceInfo] {
        try withConnection { connection in
            var devices: [SyncDeviceInfo] = []
            try connection.query(
                """
                SELECT device_id, device_name, registered_at, last_seen_at
                FROM devices WHERE account_id = ? ORDER BY registered_at ASC
                """,
                bindings: [.text(accountID.uuidString)]
            ) { row in
                guard let deviceID = row.uuid(0),
                      let name = row.text(1),
                      let registeredAt = row.date(2)
                else { return }
                devices.append(
                    SyncDeviceInfo(
                        deviceID: deviceID,
                        deviceName: name,
                        registeredAt: registeredAt,
                        lastSeenAt: row.date(3)
                    )
                )
            }
            return devices
        }
    }

    /// Revokes a device's access.
    ///
    /// - Returns: Whether a device was removed, so revoking something that does not exist can
    ///   be reported as not found rather than silently succeeding.
    @discardableResult
    public func revokeDevice(_ deviceID: UUID, accountID: UUID) throws -> Bool {
        try withConnection { connection in
            try connection.execute(
                "DELETE FROM devices WHERE device_id = ? AND account_id = ?",
                bindings: [.text(deviceID.uuidString), .text(accountID.uuidString)]
            )
            return connection.changes > 0
        }
    }
}

extension SyncStore.StoreError {
    init(_ error: SQLiteConnection.ConnectionError, path: String) {
        switch error {
        case let .cannotOpen(errorPath, message):
            self = .cannotOpen(path: errorPath.isEmpty ? path : errorPath, message: message)
        case let .statementFailed(_, message), let .executionFailed(_, message):
            // The statement text is deliberately dropped rather than carried into an error
            // that may reach a response: it names columns and tables, which is more than a
            // client needs and more than an attacker should be told.
            self = .statementFailed(message: message)
        }
    }
}

/// A device that presented a valid token.
public struct AuthenticatedDevice: Sendable, Equatable {
    public let deviceID: UUID
    public let accountID: UUID

    public init(deviceID: UUID, accountID: UUID) {
        self.deviceID = deviceID
        self.accountID = accountID
    }
}
