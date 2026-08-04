// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Foundation
import Testing
@testable import CMDVSyncServer

/// The server's storage.
///
/// Every test opens its own in-memory database, so nothing leaks between them and the suite
/// runs in milliseconds. The cursor behaviour is the substance here: a cursor that skips a
/// document loses a reader's highlight silently, and a cursor that fails to advance makes
/// every sync re-deliver the same page forever.
@Suite("The server's storage")
struct SyncStoreTests {
    /// A store with cheap password hashing.
    ///
    /// At the production iteration count this suite would spend most of its time deriving
    /// keys, and what is being tested here is the storage rather than the hashing — which has
    /// its own suite, run against published vectors at a realistic cost.
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

    // MARK: Accounts

    @Test("The first device to use a username creates the account")
    func firstUseCreatesAccount() async throws {
        let store = try makeStore()
        let created = try await store.account(username: "reader", password: "a good password")
        guard case let .created(id) = created else {
            Issue.record("Expected a created account, got \(created)")
            return
        }

        // And the second device with the same password joins it rather than creating another.
        let joined = try await store.account(username: "reader", password: "a good password")
        #expect(joined == .existing(id))
    }

    @Test("A wrong password is refused rather than creating a second account")
    func wrongPasswordRefused() async throws {
        let store = try makeStore()
        _ = try await store.account(username: "reader", password: "a good password")
        #expect(
            try await store.account(username: "reader", password: "the wrong one")
                == .passwordRejected
        )
    }

    @Test("An account can be asked about before committing to it")
    func canCheckExistence() async throws {
        let store = try makeStore()
        try #expect(await !store.accountExists(username: "reader"))
        _ = try await store.account(username: "reader", password: "a good password")
        try #expect(await store.accountExists(username: "reader"))
    }

    // MARK: Devices

    @Test("A registered device is found by its token")
    func findsDeviceByToken() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else {
            Issue.record("Could not create an account")
            return
        }

        let deviceID = UUID()
        try await store.registerDevice(
            deviceID: deviceID,
            accountID: accountID,
            deviceName: "Phone",
            tokenHash: "hash-1",
            at: instant
        )

        let found = try await store.device(forTokenHash: "hash-1")
        #expect(found == AuthenticatedDevice(deviceID: deviceID, accountID: accountID))
        try #expect(await store.device(forTokenHash: "hash-2") == nil)
    }

    /// Signing out and back in on the same phone is the ordinary case, and the old token must
    /// stop working the moment it is replaced.
    @Test("Re-registering a device replaces its token")
    func reregisteringReplacesToken() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let deviceID = UUID()
        try await store.registerDevice(
            deviceID: deviceID,
            accountID: accountID,
            deviceName: "Phone",
            tokenHash: "old",
            at: instant
        )
        try await store.registerDevice(
            deviceID: deviceID,
            accountID: accountID,
            deviceName: "Phone",
            tokenHash: "new",
            at: instant
        )

        try #expect(await store.device(forTokenHash: "old") == nil)
        try #expect(await store.device(forTokenHash: "new") != nil)
        try #expect(await store.devices(forAccountID: accountID).count == 1)
    }

    @Test("A revoked device's token stops working")
    func revocationWorks() async throws {
        let store = try makeStore()
        guard case let .created(accountID) = try await store.account(
            username: "reader",
            password: "a good password"
        ) else { return }

        let deviceID = UUID()
        try await store.registerDevice(
            deviceID: deviceID,
            accountID: accountID,
            deviceName: "Old phone",
            tokenHash: "hash",
            at: instant
        )
        try #expect(await store.revokeDevice(deviceID, accountID: accountID))
        try #expect(await store.device(forTokenHash: "hash") == nil)
        // Revoking it again is not an error, but reports that nothing was removed.
        try #expect(await !store.revokeDevice(deviceID, accountID: accountID))
    }

    /// Without the account check, any signed-in device could revoke another account's devices
    /// by guessing an identifier.
    @Test("A device cannot be revoked from another account")
    func cannotRevokeAcrossAccounts() async throws {
        let store = try makeStore()
        guard case let .created(mine) = try await store.account(
            username: "me",
            password: "a good password"
        ), case let .created(theirs) = try await store.account(
            username: "them",
            password: "another good password"
        ) else { return }

        let theirDevice = UUID()
        try await store.registerDevice(
            deviceID: theirDevice,
            accountID: theirs,
            deviceName: "Their phone",
            tokenHash: "their-hash",
            at: instant
        )

        try #expect(await !store.revokeDevice(theirDevice, accountID: mine))
        try #expect(await store.device(forTokenHash: "their-hash") != nil)
    }
}
