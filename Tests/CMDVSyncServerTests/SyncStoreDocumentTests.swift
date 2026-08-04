// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import Testing
@testable import CMDVSyncServer

/// Storing documents, and the cursor that delivers them.
///
/// Split from the account and device tests next door because this is the part that has to be
/// right: a cursor that skips a document loses a reader's highlight silently, and one that fails
/// to advance makes every sync re-deliver the same page forever.
@Suite("The server's documents")
struct SyncStoreDocumentTests {
    private func makeStore() throws -> SyncStore {
        try SyncStore(path: ":memory:", passwordIterations: 1)
    }

    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func document(
        kind: SyncDocumentKind = .progress,
        id: String = "s:book-1",
        updatedAt: Date? = nil,
        deviceID: UUID,
        payload: String = "{}"
    ) -> SyncDocument {
        SyncDocument(
            kind: kind,
            documentID: id,
            updatedAt: updatedAt ?? instant,
            deviceID: deviceID,
            payload: Data(payload.utf8)
        )
    }

    /// The property the whole cursor scheme rests on.
    @Test("A device is not sent its own writes")
    func doesNotEchoOwnWrites() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let phone = UUID()
        let tablet = UUID()
        try await store.store([document(deviceID: phone)], accountID: accountID)

        let toPhone = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: phone,
            limit: 100
        )
        #expect(toPhone.documents.isEmpty)
        // But the cursor still advances, or the phone asks for the same rows forever.
        #expect(toPhone.cursor.value > 0)

        let toTablet = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: tablet,
            limit: 100
        )
        #expect(toTablet.documents.count == 1)
    }

    @Test("Documents come back in sequence order, once each")
    func deliversEachDocumentOnce() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let writer = UUID()
        let reader = UUID()
        let written = (1 ... 5).map {
            document(kind: .annotation, id: "annotation-\($0)", deviceID: writer)
        }
        try await store.store(written, accountID: accountID)

        var cursor = SyncCursor.beginning
        var received: [String] = []
        // Two at a time, so paging is exercised rather than assumed.
        while true {
            let page = try await store.documents(
                forAccountID: accountID,
                after: cursor,
                excludingDeviceID: reader,
                limit: 2
            )
            received.append(contentsOf: page.documents.map(\.documentID))
            cursor = page.cursor
            guard page.hasMore else { break }
        }

        #expect(received == written.map(\.documentID))
    }

    /// A replaced document must be re-delivered to a device that has already read past its old
    /// position, which is why an update takes a new sequence number.
    @Test("An updated document is delivered again")
    func updatedDocumentIsRedelivered() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let writer = UUID()
        let reader = UUID()
        try await store.store(
            [document(id: "s:book-1", updatedAt: instant, deviceID: writer, payload: "{\"v\":1}")],
            accountID: accountID
        )

        let first = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: reader,
            limit: 100
        )
        #expect(first.documents.count == 1)

        try await store.store(
            [
                document(
                    id: "s:book-1",
                    updatedAt: instant.addingTimeInterval(60),
                    deviceID: writer,
                    payload: "{\"v\":2}"
                ),
            ],
            accountID: accountID
        )

        let second = try await store.documents(
            forAccountID: accountID,
            after: first.cursor,
            excludingDeviceID: reader,
            limit: 100
        )
        #expect(second.documents.count == 1)
        #expect(second.documents.first?.payload == Data("{\"v\":2}".utf8))
    }

    @Test("An older document does not overwrite a newer one")
    func olderDocumentIsRefused() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let writer = UUID()
        let reader = UUID()
        try await store.store(
            [
                document(
                    updatedAt: instant.addingTimeInterval(600),
                    deviceID: writer,
                    payload: "{\"v\":\"new\"}"
                ),
            ],
            accountID: accountID
        )
        let stored = try await store.store(
            [document(updatedAt: instant, deviceID: writer, payload: "{\"v\":\"old\"}")],
            accountID: accountID
        )
        #expect(stored == 0)

        let page = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: reader,
            limit: 100
        )
        #expect(page.documents.first?.payload == Data("{\"v\":\"new\"}".utf8))
    }

    /// A session pushed twice — a retry after a timeout, say — must not disturb what is stored.
    @Test("An immutable document is never replaced")
    func immutableDocumentIsNeverReplaced() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let writer = UUID()
        let reader = UUID()
        let sessionID = UUID().uuidString
        try await store.store(
            [
                document(
                    kind: .session,
                    id: sessionID,
                    deviceID: writer,
                    payload: "{\"duration\":600}"
                ),
            ],
            accountID: accountID
        )
        let again = try await store.store(
            [
                document(
                    kind: .session,
                    id: sessionID,
                    updatedAt: instant.addingTimeInterval(1000),
                    deviceID: writer,
                    payload: "{\"duration\":9999}"
                ),
            ],
            accountID: accountID
        )
        #expect(again == 0)

        let page = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: reader,
            limit: 100
        )
        #expect(page.documents.first?.payload == Data("{\"duration\":600}".utf8))
    }

    @Test("One account cannot see another's documents")
    func accountsAreIsolated() async throws {
        let store = try makeStore()
        guard case let .created(mine) = try await store.account(
            username: "me",
            password: "a good password"
        ), case let .created(theirs) = try await store.account(
            username: "them",
            password: "another good password"
        ) else { return }

        try await store.store([document(deviceID: UUID())], accountID: theirs)
        let page = try await store.documents(
            forAccountID: mine,
            after: .beginning,
            excludingDeviceID: UUID(),
            limit: 100
        )
        #expect(page.documents.isEmpty)
    }

    /// The same identity under two accounts is two documents, which the unique constraint has
    /// to allow — it is scoped by account rather than global.
    @Test("The same document identity can exist under two accounts")
    func identitiesAreScopedByAccount() async throws {
        let store = try makeStore()
        guard case let .created(mine) = try await store.account(
            username: "me",
            password: "a good password"
        ), case let .created(theirs) = try await store.account(
            username: "them",
            password: "another good password"
        ) else { return }

        try await store.store([document(deviceID: UUID(), payload: "{\"a\":1}")], accountID: mine)
        try await store.store([document(deviceID: UUID(), payload: "{\"b\":2}")], accountID: theirs)

        let minePage = try await store.documents(
            forAccountID: mine,
            after: .beginning,
            excludingDeviceID: UUID(),
            limit: 100
        )
        #expect(minePage.documents.first?.payload == Data("{\"a\":1}".utf8))
    }

    @Test("A request for an absurd page size is clamped rather than refused")
    func clampsLimit() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }
        try await store.store([document(deviceID: UUID())], accountID: accountID)

        // Neither of these throws, and both return the one document there is.
        for limit in [-5, 0, Int.max] {
            let page = try await store.documents(
                forAccountID: accountID,
                after: .beginning,
                excludingDeviceID: UUID(),
                limit: limit
            )
            #expect(page.documents.count == 1)
        }
    }

    /// An empty payload is legitimate — a setting whose value encodes to nothing — and SQLite
    /// treats a nil blob pointer as NULL, which the NOT NULL constraint would refuse.
    @Test("A document with an empty payload can be stored")
    func storesEmptyPayload() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        try await store.store(
            [document(kind: .setting, id: "a.setting", deviceID: UUID(), payload: "")],
            accountID: accountID
        )
        let page = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: UUID(),
            limit: 100
        )
        #expect(page.documents.first?.payload == Data())
    }

    /// A kind the server has never heard of must survive storage untouched. This is the
    /// property that lets a reader's server outlive the app version it was installed for.
    @Test("An unrecognised kind is stored and returned unchanged")
    func relaysUnknownKinds() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let future = document(
            kind: SyncDocumentKind(rawValue: "reading-plan"),
            id: "plan-1",
            deviceID: UUID(),
            payload: "{\"books\":[]}"
        )
        try await store.store([future], accountID: accountID)

        let page = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: UUID(),
            limit: 100
        )
        let returned = try #require(page.documents.first)
        #expect(returned.kind.rawValue == "reading-plan")
        #expect(returned.payload == future.payload)
    }

    @Test("Storing nothing is not an error")
    func storingNothing() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }
        try #expect(await store.store([], accountID: accountID) == 0)
    }
}
