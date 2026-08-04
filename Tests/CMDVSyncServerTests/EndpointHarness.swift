// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CMDVSyncServer

/// Drives the real router over real HTTP semantics.
///
/// In the app's repository these tests drove the app's own `HTTPSyncClient` against this
/// router, which made one test cover both ends. That is not available here — the client reaches
/// URLSession and the app's domain types, neither of which belongs in a Linux container — and
/// the replacement is better for this repository anyway: it asserts the *wire*, byte for byte,
/// rather than asserting that two pieces of Swift agree. Anyone writing another client has this
/// file to read.
///
/// Requests go through `Application.test(.router)`, so the whole middleware stack runs —
/// version check, error translation, throttling — with no socket to make the suite flaky.
/// ``LiveSocketTests`` covers the socket separately.
struct EndpointHarness {
    let server: SyncServer
    let application: Application<RouterResponder<BasicRequestContext>>

    /// A fixed clock. The server's time reaches the client in every response, and a test that
    /// asserts on it cannot do so against `Date()`.
    static let instant = Date(timeIntervalSince1970: 1_700_000_000)

    /// - Parameters:
    ///   - now: The server's clock.
    ///   - throttle: Registration throttling. Off by default, because almost every test
    ///     registers several devices in a row from the same address and would otherwise be
    ///     asserting about the throttle rather than about the endpoint.
    ///   - allowedUsernames: An empty set means any username, as in the default configuration.
    init(
        now: @escaping @Sendable () -> Date = { EndpointHarness.instant },
        throttle: RegistrationThrottle = .disabled,
        allowedUsernames: Set<String> = []
    ) throws {
        // One iteration, not 600,000. At the production count a suite that registers a few
        // dozen accounts spends all its time in key derivation and nothing else.
        let store = try SyncStore(path: ":memory:", passwordIterations: 1)
        server = SyncServer(
            store: store,
            now: now,
            log: { _ in },
            throttle: throttle,
            allowedUsernames: allowedUsernames
        )
        application = Application(router: server.router())
    }

    // MARK: Requests

    /// Registers a device and returns its token.
    static func register(
        _ client: some TestClientProtocol,
        username: String = "reader",
        password: String = "a good password",
        deviceName: String = "Phone",
        deviceID: UUID
    ) async throws -> DeviceToken {
        try await client.execute(
            uri: "/api/v1/devices",
            method: .post,
            headers: Self.headers(),
            body: Self.encode(
                DeviceRegistrationRequest(
                    username: username,
                    password: password,
                    deviceName: deviceName,
                    deviceID: deviceID
                )
            )
        ) { response in
            #expect(response.status == .created)
            return try Self.decode(DeviceToken.self, from: response)
        }
    }

    /// Pushes and pulls in one exchange, as the protocol requires.
    static func exchange(
        _ client: some TestClientProtocol,
        token: String,
        deviceID: UUID,
        documents: [SyncDocument] = [],
        cursor: SyncCursor = .beginning,
        limit: Int = SyncExchangeRequest.defaultLimit
    ) async throws -> SyncExchangeResponse {
        try await client.execute(
            uri: "/api/v1/sync",
            method: .post,
            headers: Self.headers(token: token),
            body: Self.encode(
                SyncExchangeRequest(
                    documents: documents,
                    cursor: cursor,
                    deviceID: deviceID,
                    limit: limit
                )
            )
        ) { response in
            #expect(response.status == .ok)
            return try Self.decode(SyncExchangeResponse.self, from: response)
        }
    }

    // MARK: Values

    static func document(
        kind: SyncDocumentKind = .progress,
        documentID: String = "book:one",
        updatedAt: Date = EndpointHarness.instant,
        deviceID: UUID,
        payload: String = #"{"locator":"chapter-3"}"#
    ) -> SyncDocument {
        SyncDocument(
            kind: kind,
            documentID: documentID,
            updatedAt: updatedAt,
            deviceID: deviceID,
            payload: Data(payload.utf8)
        )
    }

    // MARK: Encoding

    /// The version header on every request, as a real client sends it.
    static func headers(token: String? = nil) -> HTTPFields {
        var headers: HTTPFields = [
            .contentType: "application/json",
            versionHeaderName: String(SyncProtocolVersion.current),
        ]
        if let token {
            headers[.authorization] = "Bearer \(token)"
        }
        return headers
    }

    static func encode(_ value: some Encodable) throws -> ByteBuffer {
        ByteBuffer(bytes: Array(try SyncCoding.makeEncoder().encode(value)))
    }

    static func decode<Value: Decodable>(
        _: Value.Type,
        from response: TestResponse
    ) throws -> Value {
        try SyncCoding.makeDecoder().decode(Value.self, from: Data(buffer: response.body))
    }

    /// The reason on a described failure.
    ///
    /// Asserted by reason rather than by status throughout, because the reason is what a client
    /// branches on: "sign in again" and "the server is full" are both refusals and a status
    /// alone cannot tell them apart.
    static func reason(of response: TestResponse) throws -> SyncErrorResponse.Reason {
        try decode(SyncErrorResponse.self, from: response).reason
    }
}
