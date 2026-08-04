// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation
import Testing
@testable import CMDVSyncServer

/// Password hashing, checked against published vectors.
///
/// This is the reason it was acceptable to write PBKDF2 rather than take a dependency: the
/// construction can be *demonstrated* correct against numbers published in an RFC, not merely
/// asserted to be. If these vectors pass, the implementation is PBKDF2.
@Suite("Password hashing")
struct PasswordHashingTests {
    /// RFC 6070's PBKDF2-HMAC-SHA1 test vectors.
    ///
    /// SHA-1 rather than SHA-256, deliberately: RFC 6070 is the canonical, widely cross-checked
    /// vector set for PBKDF2, and the thing under test is the *construction* — the block
    /// indexing, the iteration chain, the exclusive-or. Instantiating it with a different hash
    /// changes only which PRF is called. Production uses SHA-256; the arithmetic is the same
    /// arithmetic.
    @Test(
        "Matches RFC 6070's published vectors",
        arguments: [
            (
                password: "password",
                salt: "salt",
                iterations: 1,
                length: 20,
                expected: "0c60c80f961f0e71f3a9b524af6012062fe037a6"
            ),
            (
                password: "password",
                salt: "salt",
                iterations: 2,
                length: 20,
                expected: "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"
            ),
            (
                password: "password",
                salt: "salt",
                iterations: 4096,
                length: 20,
                expected: "4b007901b765489abead49d926f721d065a429c1"
            ),
            (
                password: "passwordPASSWORDpassword",
                salt: "saltSALTsaltSALTsaltSALTsaltSALTsalt",
                iterations: 4096,
                length: 25,
                expected: "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038"
            ),
        ]
    )
    func matchesRFC6070(
        password: String,
        salt: String,
        iterations: Int,
        length: Int,
        expected: String
    ) {
        let derived = PasswordHashing.derive(
            using: Insecure.SHA1.self,
            password: Data(password.utf8),
            salt: Data(salt.utf8),
            iterations: iterations,
            keyByteCount: length
        )
        #expect(derived.hexadecimal == expected)
    }

    /// The multi-block path, which the 25-byte vector above also exercises but only just.
    /// A key longer than the hash requires the block index to be incremented correctly, and
    /// getting that wrong produces a plausible-looking result that repeats the first block.
    @Test("A key longer than the hash is not a repeated block")
    func multiBlockIsNotRepeated() {
        let derived = PasswordHashing.derive(
            password: "correct horse battery staple",
            salt: Data("salt".utf8),
            iterations: 10,
            keyByteCount: 64
        )
        #expect(derived.count == 64)
        #expect(derived.prefix(32) != derived.suffix(32))
    }

    // MARK: Hashing and verifying

    @Test("A password verifies against its own hash")
    func verifiesCorrectPassword() {
        // A low iteration count: this is testing the plumbing, and 600,000 iterations per
        // assertion would make the suite take minutes.
        let salt = Data("a fixed salt for the test".utf8)
        let stored = PasswordHashing.StoredHash(
            iterations: 1000,
            salt: salt,
            derivedKey: PasswordHashing.derive(
                password: "a good password",
                salt: salt,
                iterations: 1000,
                keyByteCount: 32
            )
        )
        #expect(PasswordHashing.verify(password: "a good password", against: stored))
        #expect(!PasswordHashing.verify(password: "a good passwore", against: stored))
        #expect(!PasswordHashing.verify(password: "", against: stored))
    }

    /// Two readers with the same password must not have the same stored hash, or a stolen
    /// database reveals which accounts share one.
    @Test("Two hashes of the same password differ")
    func saltsDiffer() {
        // A low count: what is under test is that the salts differ, and the default would
        // spend seven seconds proving it.
        let first = PasswordHashing.hash(password: "the same password", iterations: 100)
        let second = PasswordHashing.hash(password: "the same password", iterations: 100)
        #expect(first.salt != second.salt)
        #expect(first.derivedKey != second.derivedKey)
    }

    @Test("A stored hash round-trips through its encoding")
    func encodingRoundTrips() throws {
        let original = PasswordHashing.StoredHash(
            iterations: 12345,
            salt: Data([1, 2, 3, 4]),
            derivedKey: Data([9, 8, 7, 6, 5])
        )
        let decoded = try #require(PasswordHashing.StoredHash(encoded: original.encoded))
        #expect(decoded == original)
    }

    /// The iteration count travels with the hash so it can be raised later without
    /// invalidating every existing password. This asserts a hash made at one count still
    /// verifies after the default changes.
    @Test("A hash made at a different iteration count still verifies")
    func honoursStoredIterations() {
        let salt = Data("salt".utf8)
        let stored = PasswordHashing.StoredHash(
            iterations: 500,
            salt: salt,
            derivedKey: PasswordHashing.derive(
                password: "password",
                salt: salt,
                iterations: 500,
                keyByteCount: 32
            )
        )
        #expect(stored.iterations != PasswordHashing.iterations)
        #expect(PasswordHashing.verify(password: "password", against: stored))
    }

    @Test("A malformed stored hash is rejected rather than misread", arguments: [
        "",
        "not-a-hash",
        "pbkdf2-sha256$notanumber$c2FsdA==$a2V5",
        "pbkdf2-sha256$0$c2FsdA==$a2V5",
        "pbkdf2-sha256$1000$not base64!$a2V5",
        "argon2id$1000$c2FsdA==$a2V5",
        "pbkdf2-sha256$1000$c2FsdA==",
    ])
    func rejectsMalformed(_ encoded: String) {
        #expect(PasswordHashing.StoredHash(encoded: encoded) == nil)
    }

    // MARK: Constant-time comparison

    @Test("Comparison is by value, not by identity or length alone")
    func comparison() {
        #expect(PasswordHashing.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!PasswordHashing.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!PasswordHashing.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        #expect(PasswordHashing.constantTimeEquals(Data(), Data()))
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
