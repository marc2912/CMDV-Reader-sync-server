// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import Testing

@testable import CMDVSyncServer

/// The sequence, which is the cursor.
///
/// A suite of its own because the sequence is the one number in this server that cannot be
/// slightly wrong. A client that has seen sequence *n* believes it has seen everything up to *n*,
/// so a row that lands *below* a cursor already handed out is a document silently never delivered
/// — a highlight that exists on one device and, permanently, nowhere else. Nothing about that
/// failure is visible at the time it happens.
///
/// The column is `INTEGER PRIMARY KEY AUTOINCREMENT`, and two operations assign to it by hand:
/// replacing a document, and bumping a losing push's winner to the end. Mixing SQLite's own
/// allocation with manual assignment is the specific thing under test here.
@Suite("The sequence is monotonic and unique")
struct SequenceIntegrityTests {
    private let device = UUID()
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    /// A store with one account, whose identifier documents can reference.
    ///
    /// `documents.account_id` is a foreign key onto `accounts`, so storing a document against an
    /// account that was never created fails rather than being quietly orphaned.
    private func makeStore(
        username: String = "reader"
    ) async throws -> (store: SyncStore, account: UUID) {
        let store = try SyncStore(path: ":memory:", passwordIterations: 1)
        let account = try await accountID(in: store, username: username)
        return (store, account)
    }

    /// - Returns: The account's identifier, whether it was created or already existed.
    ///
    /// `try #require` rather than a `guard ... else { return }`: a setup step that returns early
    /// on failure makes the test pass without having tested anything, which is worse than a
    /// failure because nobody ever looks at it again.
    private func accountID(in store: SyncStore, username: String) async throws -> UUID {
        let resolution = try await store.account(
            username: username,
            password: "a good password"
        )
        switch resolution {
        case let .created(id), let .existing(id):
            return id
        case .passwordRejected:
            throw SequenceTestFailure.accountNotCreated
        }
    }

    enum SequenceTestFailure: Error {
        case accountNotCreated
    }

    private func document(
        _ id: String,
        at offset: TimeInterval = 0,
        deviceID: UUID? = nil
    ) -> SyncDocument {
        SyncDocument(
            kind: .annotation,
            documentID: id,
            updatedAt: instant.addingTimeInterval(offset),
            deviceID: deviceID ?? device,
            payload: Data(id.utf8)
        )
    }

    /// Reads every row's sequence, which is what all of these assert against.
    private func sequences(
        in store: SyncStore,
        account: UUID,
        reader: UUID
    ) async throws -> [String: Int] {
        let page = try await store.documents(
            forAccountID: account,
            after: .beginning,
            excludingDeviceID: reader,
            limit: 1000
        )
        return Dictionary(
            uniqueKeysWithValues: page.documents.compactMap { document in
                document.sequence.map { (document.documentID, $0) }
            }
        )
    }

    /// A new insert after a manual bump has to land above everything, not reuse a number.
    ///
    /// This is the case where SQLite's `AUTOINCREMENT` counter and the manual assignment can
    /// disagree: `AUTOINCREMENT` remembers the highest rowid it has *issued*, and a manual
    /// `UPDATE` to a higher number is not something it issued.
    @Test("A document inserted after a bump lands above the bumped one")
    func insertAfterBump() async throws {
        let (store, account) = try await makeStore()
        let other = UUID()

        try await store.store([document("a"), document("b")], accountID: account)
        // An older version of `a` loses, so the stored winner is bumped to the end to re-deliver
        // it to the device that lost.
        try await store.store([document("a", at: -60)], accountID: account)
        try await store.store([document("c")], accountID: account)

        let sequences = try await sequences(in: store, account: account, reader: other)
        let a = try #require(sequences["a"])
        let b = try #require(sequences["b"])
        let c = try #require(sequences["c"])

        #expect(Set([a, b, c]).count == 3, "sequences collided: \(sequences)")
        // `c` arrived last, so it must be last. If `AUTOINCREMENT` handed it a number below the
        // bumped `a`, a device holding a cursor at `a` would never be sent `c`.
        #expect(c > a, "a later insert landed below an earlier bump: \(sequences)")
        #expect(a > b, "the bumped document did not move to the end: \(sequences)")
    }

    /// The same question for the other manual assignment: replacing a document.
    @Test("A document inserted after a replacement lands above it")
    func insertAfterReplacement() async throws {
        let (store, account) = try await makeStore()
        let other = UUID()

        try await store.store([document("a"), document("b")], accountID: account)
        // A newer version of `a` wins and takes a *new* sequence, so a device that has read past
        // the old position is still told it changed.
        try await store.store([document("a", at: 60)], accountID: account)
        try await store.store([document("c")], accountID: account)

        let sequences = try await sequences(in: store, account: account, reader: other)
        let a = try #require(sequences["a"])
        let c = try #require(sequences["c"])
        #expect(c > a, "a later insert landed below a replacement: \(sequences)")
    }

    /// Repeated across many operations, because a numbering fault that appears once every few
    /// rows would pass a test that only did three.
    @Test("Sequences stay unique and rising across many replacements and bumps")
    func manyOperations() async throws {
        let (store, account) = try await makeStore()
        let other = UUID()
        var seen: Set<Int> = []
        var highest = 0

        for round in 0 ..< 25 {
            // A fresh document, a replacement of an old one, and a losing push — the three paths
            // that assign a sequence, interleaved.
            try await store.store([document("new-\(round)")], accountID: account)
            try await store.store(
                [document("new-0", at: TimeInterval(round + 1))],
                accountID: account
            )
            try await store.store([document("new-0", at: -1000)], accountID: account)

            let sequences = try await sequences(in: store, account: account, reader: other)
            for (id, sequence) in sequences where !seen.contains(sequence) {
                seen.insert(sequence)
                #expect(sequence > 0, "\(id) has a non-positive sequence")
            }
            let roundHighest = sequences.values.max() ?? 0
            #expect(roundHighest >= highest)
            highest = roundHighest
        }

        // Every row has a distinct sequence at the end, which is what the cursor depends on.
        let final = try await sequences(in: store, account: account, reader: other)
        #expect(Set(final.values).count == final.count, "duplicate sequences: \(final)")
    }

    /// Two accounts share one sequence counter, which is fine — a pull filters by account, so the
    /// gaps are invisible. What must hold is that the ordering is still global, so one account's
    /// writes can never be numbered below a cursor the *other* account has already been given.
    @Test("Two accounts sharing the counter never overlap")
    func accountsShareTheCounterSafely() async throws {
        let (store, account) = try await makeStore()
        let otherAccount = try await accountID(in: store, username: "someone-else")
        let reader = UUID()

        try await store.store([document("mine")], accountID: account)
        try await store.store([document("theirs")], accountID: otherAccount)
        try await store.store([document("mine-again")], accountID: account)

        let mine = try await sequences(in: store, account: account, reader: reader)
        let theirs = try await store.documents(
            forAccountID: otherAccount,
            after: .beginning,
            excludingDeviceID: reader,
            limit: 1000
        )

        let theirSequence = try #require(theirs.documents.first?.sequence)
        let firstMine = try #require(mine["mine"])
        let secondMine = try #require(mine["mine-again"])
        #expect(firstMine < theirSequence)
        #expect(theirSequence < secondMine)
    }
}
