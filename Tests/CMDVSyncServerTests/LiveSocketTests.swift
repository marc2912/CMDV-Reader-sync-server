// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import HummingbirdTesting
import NIOCore
import Testing

@testable import CMDVSyncServer

/// The same server, over a real socket.
///
/// Everything else in this suite drives the router directly, which is faster and exercises every
/// handler and middleware — but not the listener, the HTTP parser, or keep-alive. This covers those
/// once, end to end, so that a change which breaks the actual server rather than the actual routing
/// is caught here.
///
/// Not skipped and not flaky: the listener binds an ephemeral port chosen by the kernel, so there is
/// no fixed port to collide with and nothing to start by hand. The suite it replaces needed a server
/// launched in a separate shell and was skipped by default, which meant in practice it was never
/// run.
@Suite("The server over a socket")
struct LiveSocketTests {
    @Test("Two devices exchange a document over the network")
    func exchangeOverASocket() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.live) { client in
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
                        payload: #"{"locator":"over-the-wire"}"#
                    ),
                ]
            )

            let pulled = try await EndpointHarness.exchange(
                client,
                token: tabletToken.token,
                deviceID: tablet
            )
            let document = try #require(pulled.documents.first)
            #expect(
                String(data: document.payload, encoding: .utf8) == #"{"locator":"over-the-wire"}"#
            )
        }
    }

    /// What `curl` does, and therefore the first thing anyone tries when a server will not connect.
    @Test("The health endpoint answers over the network")
    func healthOverASocket() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.live) { client in
            try await client.execute(uri: "/api/v1/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""status":"ok""#))
            }
        }
    }

    /// A body larger than the ceiling has to be refused rather than buffered, and over a socket is
    /// the only place that is really true: the router harness hands the whole body over at once,
    /// where a real connection streams it.
    @Test("A body far past the ceiling is refused rather than buffered")
    func oversizedBodyIsRefused() async throws {
        let harness = try EndpointHarness()
        try await harness.application.test(.live) { client in
            let token = try await EndpointHarness.register(client, deviceID: UUID())
            let oversized = ByteBuffer(
                repeating: UInt8(ascii: "a"),
                count: SyncServer.maximumBodyBytes + 1024
            )

            try await client.execute(
                uri: "/api/v1/sync",
                method: .post,
                headers: EndpointHarness.headers(token: token.token),
                body: oversized
            ) { response in
                // Refused, whatever the exact status: what matters is that it is not a success and
                // the server is still standing to say so.
                #expect(response.status.code >= 400)
            }

            // Still answering afterwards, which is the actual property being defended — a server
            // that fell over on an oversized body would fail the *next* request, not this one.
            try await client.execute(uri: "/api/v1/health", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
