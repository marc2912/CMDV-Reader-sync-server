// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HTTPTypes
import HummingbirdTesting
import Testing

@testable import CMDVSyncServer

/// The exchange endpoint, over HTTP.
///
/// One request pushes and pulls, which is what makes a sync atomic from a device's point of view:
/// either the whole thing happened or none of it did.
@Suite("Endpoint: sync exchange")
struct SyncEndpointTests {
    @Test("A document pushed by one device reaches the other")
    func documentTravels() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let phoneToken = try await EndpointHarness.register(client, deviceID: phone)
            let tabletToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: tablet
            )

            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: [
                    EndpointHarness.document(
                        deviceID: phone,
                        payload: #"{"locator":"chapter-7"}"#
                    ),
                ]
            )

            let pulled = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            let document = try #require(pulled.documents.first)
            #expect(document.kind == .progress)
            #expect(document.documentID == "book:one")
            #expect(document.deviceID == phone)
            // The payload is opaque to the server, and this is the assertion that says so: the
            // bytes come back exactly as they went in, not re-encoded.
            #expect(String(data: document.payload, encoding: .utf8) == #"{"locator":"chapter-7"}"#)
            #expect(pulled.hasMore == false)
        }
    }

    /// Returning a device its own writes would make every sync echo.
    @Test("A device is not sent its own writes")
    func ownWritesAreNotEchoed() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let token = try await EndpointHarness.register(client, deviceID: phone)
            let pushed = try await EndpointHarness.exchange(
                client,
                token: token.token,
                deviceID: phone,
                documents: [EndpointHarness.document(deviceID: phone)]
            )
            #expect(pushed.documents.isEmpty)
            // The cursor still has to advance past the device's own rows, or it asks for them
            // forever.
            #expect(pushed.cursor.value > 0)
        }
    }

    @Test("A second sync with the returned cursor is empty")
    func cursorIsComplete() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let phoneToken = try await EndpointHarness.register(client, deviceID: phone)
            let tabletToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: tablet
            )

            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: [EndpointHarness.document(deviceID: phone)]
            )
            let first = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            #expect(first.documents.count == 1)

            let second = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet,
                cursor: first.cursor
            )
            #expect(second.documents.isEmpty)
            #expect(second.cursor == first.cursor)
        }
    }

    /// A first sync against years of history has to arrive in pages, or the response is too large
    /// to hold in memory on either end.
    @Test("A long history arrives in pages")
    func historyIsPaged() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let phoneToken = try await EndpointHarness.register(client, deviceID: phone)
            let tabletToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: tablet
            )

            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: (0 ..< 7).map { index in
                    EndpointHarness.document(
                        kind: .annotation,
                        documentID: "annotation:\(index)",
                        deviceID: phone
                    )
                }
            )

            var cursor = SyncCursor.beginning
            var collected: [String] = []
            var pages = 0
            while true {
                let page = try await EndpointHarness.exchange(
                    client,
                    token: tabletToken.token,
                    deviceID: tablet,
                    cursor: cursor,
                    limit: 3
                )
                collected.append(contentsOf: page.documents.map(\.documentID))
                cursor = page.cursor
                pages += 1
                guard page.hasMore else { break }
                #expect(pages < 10, "paging did not terminate")
            }

            #expect(pages == 3)
            #expect(collected.count == 7)
            // In order and once each, which is the property the cursor exists to provide.
            #expect(collected == (0 ..< 7).map { "annotation:\($0)" })
        }
    }

    @Test("One account's documents never reach another's device")
    func accountsAreIsolated() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let mine = UUID()
            let theirs = UUID()
            let myToken = try await EndpointHarness.register(
                client,
                username: "me",
                deviceName: "My phone",
                deviceID: mine
            )
            let theirToken = try await EndpointHarness.register(
                client,
                username: "them",
                password: "another good password",
                deviceName: "Their phone",
                deviceID: theirs
            )

            _ = try await EndpointHarness.exchange(
                client,
                token: myToken.token,
                deviceID: mine,
                documents: [
                    EndpointHarness.document(deviceID: mine, payload: #"{"secret":"my reading"}"#),
                ]
            )

            let theirPull = try await EndpointHarness.exchange(
                client,
                token: theirToken.token,
                deviceID: theirs
            )
            #expect(theirPull.documents.isEmpty)
        }
    }

    /// Otherwise a device could claim another's identity and be sent that device's own writes.
    @Test("A device cannot claim another device's identity")
    func deviceCannotClaimAnotherIdentity() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let token = try await EndpointHarness.register(client, deviceID: phone)

            try await client.execute(
                uri: "/api/v1/sync",
                method: .post,
                headers: EndpointHarness.headers(token: token.token),
                body: try EndpointHarness.encode(
                    SyncExchangeRequest(
                        documents: [],
                        cursor: .beginning,
                        deviceID: UUID() // not the device the token belongs to
                    )
                )
            ) { response in
                #expect(response.status == .forbidden)
                try #expect(EndpointHarness.reason(of: response) == .malformedRequest)
            }
        }
    }

    /// The request-level check above covers the envelope around the documents. This covers the
    /// documents themselves, which it does not.
    ///
    /// Left unchecked the effect would be silent and nasty: the pull filter omits a device's own
    /// writes, so the device named in a forged attribution is the one device never sent those
    /// documents — it would show its reader a history missing the very edits it appeared to have
    /// made.
    @Test("A pushed document is attributed to the device that pushed it, whatever it claimed")
    func documentsAreAttributedToThePusher() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let phoneToken = try await EndpointHarness.register(client, deviceID: phone)
            let tabletToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: tablet
            )

            // The phone pushes, but claims the tablet wrote it.
            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: [EndpointHarness.document(deviceID: tablet)]
            )

            // The tablet must still receive it — which it only does if the server recorded the
            // phone as the author.
            let pulled = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            let document = try #require(pulled.documents.first)
            #expect(document.deviceID == phone)
        }
    }

    /// A document whose kind this server has never heard of is stored and relayed untouched. That
    /// is what lets a newer app introduce a kind without anyone updating their server.
    @Test("An unrecognised kind is relayed unchanged")
    func unknownKindIsRelayed() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let phoneToken = try await EndpointHarness.register(client, deviceID: phone)
            let tabletToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: tablet
            )

            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: [
                    EndpointHarness.document(
                        kind: SyncDocumentKind(rawValue: "something-from-2030"),
                        documentID: "future:1",
                        deviceID: phone,
                        payload: #"{"unknown":true}"#
                    ),
                ]
            )

            let pulled = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            let document = try #require(pulled.documents.first)
            #expect(document.kind.rawValue == "something-from-2030")
            #expect(String(data: document.payload, encoding: .utf8) == #"{"unknown":true}"#)
        }
    }

    /// Reported rather than corrected: rewriting timestamps would hide the symptom and leave the
    /// data wrong. The exchange still succeeds, which is what this asserts.
    @Test("A server clock far from the device's does not fail the sync")
    func clockSkewIsNotFatal() async throws {
        let skewed = EndpointHarness.instant.addingTimeInterval(3600)
        let harness = try EndpointHarness(now: { skewed })
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let token = try await EndpointHarness.register(client, deviceID: phone)
            let response = try await EndpointHarness.exchange(
                client,
                token: token.token,
                deviceID: phone
            )
            #expect(response.serverTime == skewed)
        }
    }

    /// A client asking for a million documents in one response would exhaust a small server's
    /// memory, and self-hosted servers are usually small. Clamped rather than refused, since a
    /// smaller page is still a correct answer.
    @Test("An absurd page size is clamped rather than refused")
    func absurdLimitIsClamped() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let token = try await EndpointHarness.register(client, deviceID: phone)
            let response = try await EndpointHarness.exchange(
                client,
                token: token.token,
                deviceID: phone,
                limit: 100_000_000
            )
            #expect(response.documents.isEmpty)
        }
    }
}
