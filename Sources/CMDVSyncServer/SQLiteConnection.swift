// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CSQLiteShim
import Foundation

/// A SQLite connection, and nothing about syncing.
///
/// Split out from ``SyncStore`` for two reasons. It keeps the SQL plumbing — binding,
/// stepping, error translation — in one place away from the schema, so a reader of either
/// file is looking at one thing. And it is a plain class rather than actor state, which is
/// what lets ``SyncStore``'s initializer open the database and run its migrations: an actor's
/// initializer is not isolated in Swift 6 and so cannot call the actor's own methods, but it
/// can freely use a local object it has just constructed.
///
/// Not `Sendable`, deliberately. The compiler then guarantees the connection never leaves
/// the actor that owns it, which is a stronger guarantee than SQLite's own threading modes
/// give and is checked rather than documented.
final class SQLiteConnection {
    private let handle: OpaquePointer

    enum ConnectionError: Error, Equatable {
        case cannotOpen(path: String, message: String)
        case statementFailed(sql: String, message: String)
        case executionFailed(sql: String, message: String)
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        // `FULLMUTEX` even though an actor owns this: the actor guarantees this code does not
        // race, and this guarantees SQLite's own internal state is safe regardless.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw ConnectionError.cannotOpen(path: path, message: message)
        }
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// A value bound to a statement parameter.
    ///
    /// Every value that reaches SQL goes through here. Nothing is interpolated into a
    /// statement string anywhere in this package, which is the only reliable defence against
    /// injection — a rule that holds by construction rather than by care.
    enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
    }

    /// Rows affected by the last statement.
    var changes: Int {
        Int(sqlite3_changes(handle))
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    private func prepare(_ sql: String, bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw ConnectionError.statementFailed(sql: sql, message: errorMessage)
        }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch binding {
            case let .text(value):
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .integer(value):
                sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                sqlite3_bind_double(statement, index, value)
            case let .blob(value):
                value.withUnsafeBytes { buffer in
                    // An empty `Data` has a nil base address, and SQLite treats a nil blob
                    // pointer as SQL NULL — which would fail the NOT NULL constraint on a
                    // payload that is legitimately empty.
                    sqlite3_bind_blob(
                        statement,
                        index,
                        buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1),
                        Int32(buffer.count),
                        sqliteTransient
                    )
                }
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw ConnectionError.statementFailed(sql: sql, message: errorMessage)
            }
        }
        return statement
    }

    func execute(_ sql: String, bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw ConnectionError.statementFailed(sql: sql, message: errorMessage)
        }
    }

    func query(
        _ sql: String,
        bindings: [Binding] = [],
        row: (OpaquePointer) -> Void
    ) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                row(statement)
            case SQLITE_DONE:
                return
            default:
                throw ConnectionError.statementFailed(sql: sql, message: errorMessage)
            }
        }
    }

    /// For statements with no parameters: pragmas, schema definitions, transactions.
    func run(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw ConnectionError.executionFailed(sql: sql, message: message)
        }
    }
}

/// SQLite's `SQLITE_TRANSIENT`, which its headers define as a cast Swift cannot import.
///
/// It tells SQLite to copy the bound bytes rather than hold the pointer. Without it a Swift
/// string or `Data` could be deallocated between binding and stepping, and SQLite would read
/// freed memory — a crash that appears only under load.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: Reading columns

extension OpaquePointer {
    /// A text column, or `nil` when it is NULL.
    func text(_ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(self, index) else { return nil }
        return String(cString: bytes)
    }

    func uuid(_ index: Int32) -> UUID? {
        text(index).flatMap(UUID.init(uuidString:))
    }

    func integer(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(self, index))
    }

    func date(_ index: Int32) -> Date? {
        guard sqlite3_column_type(self, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(self, index))
    }

    func blob(_ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(self, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(self, index)))
    }
}
