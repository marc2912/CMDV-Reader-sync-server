// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HTTPTypes
import HummingbirdTesting
import Testing

@testable import CMDVSyncServer

/// Listing and revoking devices, and what authentication refuses.
///
/// Each device holds its own token so a lost phone can be cut off without changing a password and
/// re-pairing everything else. That only works if revocation is exact, which is what most of this
/// suite is about.
@Suite("Endpoint: devices")
struct DeviceEndpointTests {
    @Test("Devices are listed with the names their readers gave them")
    func listsDevices() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let phone = UUID()
            let tablet = UUID()
            let token = try await EndpointHarness.register(
                client,
                deviceName: "Marc's phone",
                deviceID: phone
            )
            _ = try await EndpointHarness.register(
                client,
                deviceName: "Kitchen tablet",
                deviceID: tablet
            )

            try await client.execute(
                uri: "/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers(token: token.token)
            ) { response in
                #expect(response.status == .ok)
                let devices = try EndpointHarness.decode([SyncDeviceInfo].self, from: response)
                #expect(devices.map(\.deviceName) == ["Marc's phone", "Kitchen tablet"])
                #expect(devices.map(\.deviceID) == [phone, tablet])
                // Never synced, so never seen. The distinction is what tells a reader which of
                // two devices in the list is the one they stopped using.
                #expect(devices.allSatisfy { $0.lastSeenAt == nil })
            }

            _ = try await EndpointHarness.exchange(client, token: token.token, deviceID: phone)

            try await client.execute(
                uri: "/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers(token: token.token)
            ) { response in
                let devices = try EndpointHarness.decode([SyncDeviceInfo].self, from: response)
                #expect(devices.first?.lastSeenAt == EndpointHarness.instant)
            }
        }
    }

    @Test("A revoked device can no longer sync, and the others still can")
    func revocation() async throws {
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

            try await client.execute(
                uri: "/api/v1/devices/\(tablet.uuidString)",
                method: .delete,
                headers: EndpointHarness.headers(token: phoneToken.token)
            ) { response in
                #expect(response.status == .noContent)
            }

            try await client.execute(
                uri: "/api/v1/sync",
                method: .post,
                headers: EndpointHarness.headers(token: tabletToken.token),
                body: try EndpointHarness.encode(
                    SyncExchangeRequest(documents: [], cursor: .beginning, deviceID: tablet)
                )
            ) { response in
                #expect(response.status == .forbidden)
                try #expect(EndpointHarness.reason(of: response) == .tokenRevoked)
            }

            // The device that did the revoking is unaffected.
            _ = try await EndpointHarness.exchange(
                client,
                token: phoneToken.token,
                deviceID: phone
            )
        }
    }

    /// Without the account check any signed-in device could revoke any other account's devices by
    /// guessing an identifier.
    @Test("A device cannot be revoked from another account")
    func revocationIsWithinAnAccount() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let mine = UUID()
            let theirs = UUID()
            let myToken = try await EndpointHarness.register(
                client,
                username: "me",
                deviceID: mine
            )
            let theirToken = try await EndpointHarness.register(
                client,
                username: "them",
                password: "another good password",
                deviceName: "Their phone",
                deviceID: theirs
            )

            try await client.execute(
                uri: "/api/v1/devices/\(theirs.uuidString)",
                method: .delete,
                headers: EndpointHarness.headers(token: myToken.token)
            ) { response in
                // Not found rather than forbidden: a forbidden would confirm that the identifier
                // names a real device on somebody else's account.
                #expect(response.status == .notFound)
            }

            // And their device still works.
            _ = try await EndpointHarness.exchange(
                client,
                token: theirToken.token,
                deviceID: theirs
            )
        }
    }

    @Test("Revoking a device that does not exist is a not-found, not a silent success")
    func revokingNothing() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            try await client.execute(
                uri: "/api/v1/devices/\(UUID().uuidString)",
                method: .delete,
                headers: EndpointHarness.headers(token: token.token)
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("A device identifier that is not a UUID is refused as malformed")
    func revokingNonsense() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            try await client.execute(
                uri: "/api/v1/devices/not-a-uuid",
                method: .delete,
                headers: EndpointHarness.headers(token: token.token)
            ) { response in
                #expect(response.status == .badRequest)
                try #expect(EndpointHarness.reason(of: response) == .malformedRequest)
            }
        }
    }

    // MARK: Authentication

    /// A client's behaviour differs between "sign in" and "your access was revoked", and it cannot
    /// tell them apart from a bare 401 — which is the whole reason every refusal here names a
    /// machine-readable reason.
    @Test("A request with no token is told to sign in")
    func missingToken() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers()
            ) { response in
                #expect(response.status == .unauthorized)
                try #expect(EndpointHarness.reason(of: response) == .invalidCredentials)
            }
        }
    }

    @Test("A token that is not known is reported as a revocation")
    func unknownToken() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            try await client.execute(
                uri: "/api/v1/devices",
                method: .get,
                headers: EndpointHarness.headers(token: "not-a-real-token")
            ) { response in
                // Deliberately the same answer for a token that never existed and one that was
                // revoked: distinguishing them would confirm which tokens once existed.
                #expect(response.status == .forbidden)
                try #expect(EndpointHarness.reason(of: response) == .tokenRevoked)
            }
        }
    }

    @Test("An Authorization header that is not a bearer token is not accepted")
    func wrongAuthorizationScheme() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.router) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            var headers = EndpointHarness.headers()
            headers[.authorization] = "Basic \(token.token)"

            try await client.execute(uri: "/api/v1/devices", method: .get, headers: headers) {
                response in
                #expect(response.status == .unauthorized)
                try #expect(EndpointHarness.reason(of: response) == .invalidCredentials)
            }
        }
    }
}
