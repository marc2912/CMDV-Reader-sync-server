// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import Testing
@testable import CMDVSyncServer

/// What the server owes a device whose push it rejected.
///
/// Its own suite because the answer used to be "nothing", and because the protocol treats the
/// cause — clock skew between a reader's own devices — as ordinary rather than exceptional.
@Suite("Rejected pushes")
struct SyncStoreRejectionTests {
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

    /// A rejected push has to be answered, not merely dropped.
    ///
    /// The scenario the protocol calls ordinary, because it treats clock skew as normal. The
    /// tablet writes at t=100 and the phone reads it. The phone's clock is five minutes slow;
    /// its reader edits the same note and it pushes at t=90. The server rejects the push — the
    /// tablet's version is newer — and used to leave the winner at its old sequence, which the
    /// phone had already read past. Nothing ever told the phone it lost, so it showed the
    /// reader an edit no other device had, permanently.
    ///
    /// Re-sequencing the winner is what closes it: the phone is re-sent the version that won.
    @Test("Losing a push re-delivers the winner to the device that lost")
    func rejectedPushRedeliversTheWinner() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let phone = UUID()
        let tablet = UUID()

        // The tablet writes, and the phone reads up to that point.
        try await store.store(
            [document(updatedAt: instant, deviceID: tablet, payload: "{\"v\":\"tablet\"}")],
            accountID: accountID
        )
        let firstRead = try await store.documents(
            forAccountID: accountID,
            after: .beginning,
            excludingDeviceID: phone,
            limit: 100
        )
        #expect(firstRead.documents.count == 1)

        // The phone pushes an older edit of the same document. It must be rejected.
        let stored = try await store.store(
            [
                document(
                    updatedAt: instant.addingTimeInterval(-300),
                    deviceID: phone,
                    payload: "{\"v\":\"phone\"}"
                ),
            ],
            accountID: accountID
        )
        #expect(stored == 0, "an older document must not overwrite a newer one")

        // And the phone must now be re-sent the winner, past the cursor it had reached.
        let afterReject = try await store.documents(
            forAccountID: accountID,
            after: firstRead.cursor,
            excludingDeviceID: phone,
            limit: 100
        )
        #expect(
            afterReject.documents.count == 1,
            "the device that lost must be re-sent the version that won"
        )
        #expect(afterReject.documents.first?.deviceID == tablet)
        #expect(
            String(bytes: afterReject.documents.first?.payload ?? Data(), encoding: .utf8)
                == "{\"v\":\"tablet\"}"
        )
    }
}
