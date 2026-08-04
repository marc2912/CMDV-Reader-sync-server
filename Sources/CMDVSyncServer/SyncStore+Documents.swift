// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import CSQLiteShim
import Foundation

/// Storing and delivering documents.
///
/// Split from the rest of the store because this is where the protocol actually lives: the
/// superseding rule, the sequence that *is* the cursor, and the paging. Accounts and devices are
/// ordinary bookkeeping by comparison.
public extension SyncStore {
    /// One page of documents, and where to resume.
    ///
    /// A named type rather than a tuple: `(documents:cursor:hasMore:)` is exactly the shape where
    /// a caller silently transposes two members, and the cursor being wrong is the failure that
    /// loses a reader's highlights.
    struct Page: Sendable, Equatable {
        public let documents: [SyncDocument]
        public let cursor: SyncCursor
        public let hasMore: Bool

        public init(documents: [SyncDocument], cursor: SyncCursor, hasMore: Bool) {
            self.documents = documents
            self.cursor = cursor
            self.hasMore = hasMore
        }
    }

    /// Stores documents, keeping whichever wins for each identity.
    ///
    /// The comparison is ``SyncDocument/supersedes(_:)`` — the deliberately crude rule that
    /// belongs to the server. It is applied here rather than in SQL because the rule is part
    /// of the protocol and lives in exactly one place, imported by both ends.
    ///
    /// - Returns: How many were stored, excluding those an existing document beat.
    @discardableResult
    func store(_ documents: [SyncDocument], accountID: UUID) throws -> Int {
        guard !documents.isEmpty else { return 0 }

        let stored = try withConnection { connection -> Int in
            var stored = 0
            // One transaction for the whole push. Without it, a partly-applied push would
            // leave some documents visible below the cursor the client is about to be given,
            // and the rest would never be delivered.
            try connection.run("BEGIN IMMEDIATE")
            do {
                for document in documents {
                    if let existing = try Self.existingDocument(
                        connection,
                        kind: document.kind,
                        documentID: document.documentID,
                        accountID: accountID
                    ) {
                        guard document.supersedes(existing) else {
                            // The push lost, and the winner is already in the table — but at a
                            // sequence the pushing device has usually read past, so nothing
                            // would ever tell it that its own version was rejected. It would
                            // show the reader an edit that no other device has, forever.
                            //
                            // The protocol treats clock skew as normal, which makes this the
                            // expected case rather than a corner one: a device five minutes slow
                            // loses every comparison and diverges silently.
                            //
                            // Giving the winner a fresh sequence re-delivers it to everyone,
                            // including the loser, which is the same mechanism a replaced
                            // document already relies on.
                            try Self.bumpSequence(
                                connection,
                                kind: document.kind,
                                documentID: document.documentID,
                                accountID: accountID
                            )
                            continue
                        }
                    }
                    try Self.upsert(connection, document, accountID: accountID)
                    stored += 1
                }
                try connection.run("COMMIT")
            } catch {
                // Rolled back rather than left half-applied. The client's cursor has not
                // moved, so it sends the same documents again.
                try? connection.run("ROLLBACK")
                throw error
            }
            return stored
        }

        lastSequence = try withConnection(Self.readLastSequence)
        return stored
    }

    fileprivate static func existingDocument(
        _ connection: SQLiteConnection,
        kind: SyncDocumentKind,
        documentID: String,
        accountID: UUID
    ) throws -> SyncDocument? {
        var found: SyncDocument?
        try connection.query(
            """
            SELECT sequence, kind, document_id, updated_at, device_id, payload
            FROM documents WHERE account_id = ? AND kind = ? AND document_id = ?
            """,
            bindings: [.text(accountID.uuidString), .text(kind.rawValue), .text(documentID)]
        ) { row in
            found = document(from: row)
        }
        return found
    }

    /// Moves a document to the end of the sequence without changing it.
    ///
    /// Used when an incoming push loses to what is already stored: the content is right and its
    /// position is stale, because at least one device has read past it and needs telling.
    fileprivate static func bumpSequence(
        _ connection: SQLiteConnection,
        kind: SyncDocumentKind,
        documentID: String,
        accountID: UUID
    ) throws {
        try connection.execute(
            """
            UPDATE documents
            SET sequence = (SELECT IFNULL(MAX(sequence), 0) + 1 FROM documents)
            WHERE account_id = ? AND kind = ? AND document_id = ?
            """,
            bindings: [
                .text(accountID.uuidString),
                .text(kind.rawValue),
                .text(documentID),
            ]
        )
    }

    fileprivate static func upsert(
        _ connection: SQLiteConnection,
        _ document: SyncDocument,
        accountID: UUID
    ) throws {
        // A replaced document takes a *new* sequence number rather than keeping its old one.
        // That is what makes the cursor work: a device that has already read past the old
        // position must still be told the document changed.
        try connection.execute(
            """
            INSERT INTO documents
                (account_id, kind, document_id, updated_at, device_id, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, kind, document_id) DO UPDATE SET
                sequence = (SELECT IFNULL(MAX(sequence), 0) + 1 FROM documents),
                updated_at = excluded.updated_at,
                device_id = excluded.device_id,
                payload = excluded.payload
            """,
            bindings: [
                .text(accountID.uuidString),
                .text(document.kind.rawValue),
                .text(document.documentID),
                .real(document.updatedAt.timeIntervalSince1970),
                .text(document.deviceID.uuidString),
                .blob(document.payload),
            ]
        )
    }

    /// One page of documents above a cursor, oldest first.
    ///
    /// - Parameter excludingDeviceID: The asking device. Its own writes are omitted — it
    ///   already has them, and returning them would make every sync echo.
    /// - Returns: The documents, the cursor to resume from, and whether more remain.
    func documents(
        forAccountID accountID: UUID,
        after cursor: SyncCursor,
        excludingDeviceID: UUID,
        limit: Int
    ) throws -> Page {
        let bounded = max(1, min(limit, Self.maximumLimit))

        var results: [SyncDocument] = try withConnection { connection in
            var results: [SyncDocument] = []
            // One more row than asked for, so "is there more" comes from the same query
            // rather than a second count that could disagree with it.
            try connection.query(
                """
                SELECT sequence, kind, document_id, updated_at, device_id, payload
                FROM documents
                WHERE account_id = ? AND sequence > ? AND device_id != ?
                ORDER BY sequence ASC
                LIMIT ?
                """,
                bindings: [
                    .text(accountID.uuidString),
                    .integer(Int64(cursor.value)),
                    .text(excludingDeviceID.uuidString),
                    .integer(Int64(bounded + 1)),
                ]
            ) { row in
                if let document = Self.document(from: row) {
                    results.append(document)
                }
            }
            return results
        }

        let hasMore = results.count > bounded
        if hasMore {
            results.removeLast(results.count - bounded)
        }

        // A page can be empty because everything above the cursor came from this device. The
        // cursor still has to advance past those rows, or the device asks for them forever.
        // Advancing to the account's high-water mark is correct: it has now been offered
        // everything up to it.
        let resumeAt = results.last?.sequence ?? (hasMore ? cursor.value : lastSequence)
        return Page(documents: results, cursor: SyncCursor(value: resumeAt), hasMore: hasMore)
    }

    /// The largest page a client may ask for.
    ///
    /// A client asking for a million documents in one response would exhaust a small server's
    /// memory, and self-hosted servers are usually small. Clamped rather than rejected, since
    /// a smaller page is still a correct answer.
    internal static let maximumLimit = 2000

    /// The account-wide high-water sequence.
    var currentSequence: Int {
        lastSequence
    }

    fileprivate static func document(from row: OpaquePointer) -> SyncDocument? {
        guard let kind = row.text(1),
              let documentID = row.text(2),
              let updatedAt = row.date(3),
              let deviceID = row.uuid(4)
        else { return nil }

        return SyncDocument(
            kind: SyncDocumentKind(rawValue: kind),
            documentID: documentID,
            updatedAt: updatedAt,
            deviceID: deviceID,
            payload: row.blob(5),
            sequence: row.integer(0)
        )
    }
}
