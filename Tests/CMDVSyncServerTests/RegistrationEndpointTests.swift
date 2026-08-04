// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HTTPTypes
import HummingbirdTesting
import Testing

@testable import CMDVSyncServer

/// The registration endpoint, over HTTP.
///
/// It is the only endpoint that is both unauthenticated and expensive, which is why it has a
/// suite of its own rather than a few cases inside a larger one.
@Suite("Endpoint: registration")
struct RegistrationEndpointTests {
    @Test("A device registers and receives a token")
    func registers() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            #expect(!token.token.isEmpty)
            // URL-safe, so a token can be pasted into a configuration file or a query string
            // without escaping.
            #expect(!token.token.contains("+"))
            #expect(!token.token.contains("/"))
            #expect(!token.token.contains("="))
        }
    }

    /// Registration and sign-in are the same operation, deliberately: a household server has no
    /// sign-up flow and no administrator.
    @Test("A second device with the same password joins the same account")
    func secondDeviceJoins() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let first = UUID()
            let second = UUID()
            let firstToken = try await EndpointHarness.register(client, deviceID: first)
            let secondToken = try await EndpointHarness.register(
                client,
                deviceName: "Tablet",
                deviceID: second
            )
            #expect(firstToken.token != secondToken.token)

            // The proof they share an account is that one sees the other's writes.
            _ = try await EndpointHarness.exchange(
                client,
                token: firstToken.token,
                deviceID: first,
                documents: [EndpointHarness.document(deviceID: first)]
            )
            let pulled = try await EndpointHarness.exchange(
                client,
                token: secondToken.token,
                deviceID: second
            )
            #expect(pulled.documents.count == 1)
        }
    }

    @Test("A wrong password is refused rather than creating a second account")
    func wrongPassword() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            _ = try await EndpointHarness.register(client, deviceID: UUID())

            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: try EndpointHarness.encode(
                    DeviceRegistrationRequest(
                        username: "reader",
                        password: "the wrong password",
                        deviceName: "Phone",
                        deviceID: UUID()
                    )
                )
            ) { response in
                #expect(response.status == .unauthorized)
                try #expect(EndpointHarness.reason(of: response) == .invalidCredentials)
            }
        }
    }

    @Test("A short password is refused rather than accepted")
    func shortPassword() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: try EndpointHarness.encode(
                    DeviceRegistrationRequest(
                        username: "reader",
                        password: "short",
                        deviceName: "Phone",
                        deviceID: UUID()
                    )
                )
            ) { response in
                #expect(response.status == .badRequest)
                try #expect(EndpointHarness.reason(of: response) == .malformedRequest)
            }
        }
    }

    /// The decoding detail is returned here, and it is safe to: it describes the client's own
    /// request, which the client already has.
    @Test("A body that is not the protocol is a described refusal, not a server error")
    func malformedBody() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: .init(string: #"{"username":"reader"}"#)
            ) { response in
                #expect(response.status == .badRequest)
                try #expect(EndpointHarness.reason(of: response) == .malformedRequest)
            }
        }
    }

    /// A reader who signs out and back in on the same phone gets a new token, and the old one
    /// stops working the moment it is replaced.
    @Test("Re-registering a device replaces its token")
    func reRegistrationReplacesToken() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let deviceID = UUID()
            let first = try await EndpointHarness.register(client, deviceID: deviceID)
            let second = try await EndpointHarness.register(client, deviceID: deviceID)
            #expect(first.token != second.token)

            try await client.execute(
                uri: "/api/v1/sync",
                method: .post,
                headers: EndpointHarness.headers(token: first.token),
                body: try EndpointHarness.encode(
                    SyncExchangeRequest(documents: [], cursor: .beginning, deviceID: deviceID)
                )
            ) { response in
                #expect(response.status == .forbidden)
                try #expect(EndpointHarness.reason(of: response) == .tokenRevoked)
            }
        }
    }

    // MARK: Throttling

    /// The cost being defended against is the key derivation, so the refusal has to come before
    /// it. What this asserts is that it does: the eleventh attempt in the window is refused.
    @Test("Registration beyond the limit is refused, with how long to wait")
    func throttleRefuses() async throws {
        let harness = try EndpointHarness(
            throttle: RegistrationThrottle(limit: .init(attempts: 3, window: 300))
        )
        try await harness.application.test(.router) { client in
            for index in 0 ..< 3 {
                _ = try await EndpointHarness.register(
                    client,
                    deviceName: "Device \(index)",
                    deviceID: UUID()
                )
            }

            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: try EndpointHarness.encode(
                    DeviceRegistrationRequest(
                        username: "reader",
                        password: "a good password",
                        deviceName: "One too many",
                        deviceID: UUID()
                    )
                )
            ) { response in
                #expect(response.status == .tooManyRequests)
                try #expect(EndpointHarness.reason(of: response) == .quotaExceeded)
                // `Retry-After` in seconds, so an operator reading a log or a client with a
                // backoff has a number rather than a guess.
                let retryAfter = try #require(response.headers[.retryAfter])
                #expect(Int(retryAfter) == 300)
            }
        }
    }

    /// The limit must not be off by accident, so the *default* is asserted rather than only the
    /// injected one — a default of `nil` would leave every deployment that configures nothing
    /// wide open, and would still pass a test that supplied its own throttle.
    @Test("A server told nothing about throttling still throttles")
    func throttlingIsOnByDefault() async throws {
        let store = try SyncStore(path: ":memory:", passwordIterations: 1)
        let server = SyncServer(store: store, now: { EndpointHarness.instant }, log: { _ in })
        let limit = await server.throttle.currentLimit
        #expect(limit == RegistrationThrottle.Limit.default)
    }

    @Test("The window passing lets registration through again")
    func throttleWindowExpires() async throws {
        let clock = MutableClock(now: EndpointHarness.instant)
        let harness = try EndpointHarness(
            now: { clock.value },
            throttle: RegistrationThrottle(limit: .init(attempts: 1, window: 60))
        )
        try await harness.application.test(.router) { client in
            _ = try await EndpointHarness.register(client, deviceID: UUID())

            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: try EndpointHarness.encode(
                    DeviceRegistrationRequest(
                        username: "reader",
                        password: "a good password",
                        deviceName: "Blocked",
                        deviceID: UUID()
                    )
                )
            ) { response in
                #expect(response.status == .tooManyRequests)
            }

            clock.value = EndpointHarness.instant.addingTimeInterval(61)
            _ = try await EndpointHarness.register(
                client,
                deviceName: "Allowed again",
                deviceID: UUID()
            )
        }
    }

    // MARK: The username list

    @Test("A username that is not on the list is refused")
    func unlistedUsername() async throws {
        let harness = try EndpointHarness(allowedUsernames: ["alice", "bob"])
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/devices",
                method: .post,
                headers: EndpointHarness.headers(),
                body: try EndpointHarness.encode(
                    DeviceRegistrationRequest(
                        username: "someone-else",
                        password: "a good password",
                        deviceName: "Phone",
                        deviceID: UUID()
                    )
                )
            ) { response in
                #expect(response.status == .unauthorized)
                // The same answer as a wrong password, deliberately. Two different answers
                // together would tell anyone who asked which usernames exist here.
                try #expect(EndpointHarness.reason(of: response) == .invalidCredentials)
            }
        }
    }

    @Test("A username on the list registers as usual")
    func listedUsername() async throws {
        let harness = try EndpointHarness(allowedUsernames: ["alice", "bob"])
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(
                client,
                username: "alice",
                deviceID: UUID()
            )
            #expect(!token.token.isEmpty)
        }
    }
}

/// A clock a test can move.
///
/// A class rather than a captured `var`, because the closure the server holds is `@Sendable` and
/// has to see the change.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    var value: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    init(now: Date) {
        storage = now
    }
}
