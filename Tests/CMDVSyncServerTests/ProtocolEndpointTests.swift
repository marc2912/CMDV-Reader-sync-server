// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HTTPTypes
import HummingbirdTesting
import Testing

@testable import CMDVSyncServer

/// The version header, the health endpoint, and what an unknown path does.
///
/// These are the parts an operator meets before anything else works, and the parts another
/// implementation of the protocol has to get right.
@Suite("Endpoint: protocol and health")
struct ProtocolEndpointTests {
    /// A version mismatch interpreted optimistically is how a newer client silently corrupts an
    /// older server's data. Refused, and said plainly.
    @Test("A version this server does not speak is refused")
    func refusesUnknownVersion() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/health",
                method: .get,
                headers: [versionHeaderName: "99"]
            ) { response in
                #expect(response.status == .conflict)
                try #expect(EndpointHarness.reason(of: response) == .versionUnsupported)
            }
        }
    }

    @Test("A version header that is not a number is refused rather than ignored")
    func refusesNonNumericVersion() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/health",
                method: .get,
                headers: [versionHeaderName: "one"]
            ) { response in
                #expect(response.status == .conflict)
            }
        }
    }

    /// The first thing anyone does when a server will not connect is `curl` it, and a health check
    /// refused for a missing header would send them looking in the wrong place.
    @Test("The health endpoint answers without a version header or a token")
    func healthNeedsNothing() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(uri: "/api/v1/health", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains(#""status":"ok""#))
                #expect(body.contains(#""version":\#(SyncProtocolVersion.current)"#))
            }
        }
    }

    /// A path the proxy does not strip is a misconfiguration, and the reader needs to be told that
    /// rather than shown a server error they cannot act on.
    @Test("A path this server does not serve is a not-found, not a server failure")
    func unknownPathIsNotAServerError() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/cmdv-sync/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers()
            ) { response in
                #expect(response.status == .notFound)
                try #expect(EndpointHarness.reason(of: response) == .malformedRequest)
            }
        }
    }

    /// So a client can notice a server that has moved on without it, even on a response it did not
    /// have to authenticate for.
    @Test("Responses carry the protocol version")
    func responsesCarryTheVersion() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            #expect(!token.token.isEmpty)

            try await client.execute(
                uri: "/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers(token: token.token)
            ) { response in
                #expect(response.headers[versionHeaderName] == String(SyncProtocolVersion.current))
            }
        }
    }

    /// The wire format's one interoperability requirement that is easy to get wrong and invisible
    /// when it is.
    ///
    /// Asserted here rather than left to the encoder's defaults because this is the assertion that
    /// fails on Linux if `Date.ISO8601FormatStyle` ever behaves differently there — which is the
    /// platform this actually ships on, and the one a developer on a Mac never exercises.
    @Test("Dates on the wire are ISO 8601 in UTC with fractional seconds")
    func datesAreISO8601() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let token = try await EndpointHarness.register(client, deviceID: phone)

            try await client.execute(
                uri: "/api/v1/sync",
                method: .post,
                headers: EndpointHarness.headers(token: token.token),
                body: try EndpointHarness.encode(
                    SyncExchangeRequest(documents: [], cursor: .beginning, deviceID: phone)
                )
            ) { response in
                // 1_700_000_000 is 2023-11-14T22:13:20Z. Written out rather than derived, so this
                // is a test of the format and not of the same code that produced it.
                let body = String(buffer: response.body)
                #expect(body.contains(#""serverTime":"2023-11-14T22:13:20.000Z""#))
            }
        }
    }

    /// A document written twice in the same second still has to order correctly, which is the whole
    /// reason the format carries fractional seconds.
    @Test("A timestamp with fractional seconds survives the round trip")
    func fractionalSecondsSurvive() async throws {
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

            let precise = Date(timeIntervalSince1970: 1_700_000_000.125)
            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone,
                documents: [EndpointHarness.document(updatedAt: precise, deviceID: phone)]
            )

            let pulled = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            let document = try #require(pulled.documents.first)
            #expect(document.updatedAt == precise)
        }
    }
}
