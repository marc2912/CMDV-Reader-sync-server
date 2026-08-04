// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Crypto
import Foundation

/// Password hashing, PBKDF2-HMAC-SHA256.
///
/// Written here rather than taken from a package, and the reasoning is specific rather
/// than a preference for writing things. PBKDF2 is a short, completely specified
/// construction (RFC 8018 §5.2) whose correctness can be *demonstrated* against published
/// test vectors — which the tests alongside this do. A dependency for thirty lines of
/// arithmetic would be a dependency whose correctness is asserted rather than shown.
///
/// A memory-hard function — Argon2id, or scrypt — would be the better choice against an
/// attacker with a stolen database and a GPU farm, and every implementation of those is
/// long enough that writing one would be the wrong call. This is a household server whose
/// database holds reading positions, and PBKDF2 with a high iteration count is the honest
/// trade: strong enough that a stolen hash is not trivially reversible, simple enough to
/// be verifiably correct.
public enum PasswordHashing {
    /// Iterations, and why this number.
    ///
    /// 600,000, which is OWASP's 2023 guidance for PBKDF2-HMAC-SHA256.
    ///
    /// What that costs, measured rather than assumed: **about 1.35 seconds** per hash in a release
    /// build on an Apple M-series machine, and proportionally longer on the small ARM boxes a home
    /// server often is. That is far more than the "few hundred milliseconds" one might expect from
    /// a native implementation, and the reason is visible in ``derive(using:password:salt:iterations:keyByteCount:)``
    /// below: this is a plain Swift loop over swift-crypto's HMAC, not a vectorised C routine.
    ///
    /// The number stays as it is, because that cost is the entire point — it is charged to anyone
    /// attacking a stolen hash far more often than to a reader, who pays it once per device. But it
    /// has two consequences worth being explicit about, since neither is obvious from the constant:
    ///
    /// - It is why registration is rate-limited. See ``RegistrationThrottle``.
    /// - It runs inside ``SyncStore``'s actor, so a registration briefly holds up other devices'
    ///   syncs. Bounded by the throttle, harmless in practice — a sync is a background operation
    ///   that retries — but real, and worth knowing before wondering why.
    ///
    /// Configurable per deployment via `CMDV_SYNC_PASSWORD_ITERATIONS` for operators on hardware
    /// where seconds becomes tens of seconds. The count travels with each stored hash, so changing
    /// it never invalidates an existing password.
    public static let iterations = 600_000

    /// The lowest iteration count this server will accept.
    ///
    /// A floor rather than free choice, and specifically to catch a typo: 60,000 is a defensible
    /// trade on slow hardware, and 6,000 — the same value with a digit lost — is not. Ten thousand
    /// is roughly PBKDF2's decade-old guidance, which is weak but not broken, and it makes the
    /// difference between the two shapes of mistake visible.
    public static let minimumIterations = 10_000

    /// Salt length, in bytes. Sixteen: long enough that a rainbow table is useless, and
    /// what RFC 8018 recommends as a minimum.
    public static let saltByteCount = 16

    /// Derived key length, in bytes. Thirty-two, matching SHA-256's output — asking for
    /// more would require extra blocks of work for no extra entropy.
    public static let keyByteCount = 32

    /// A stored password.
    ///
    /// Everything needed to verify it later travels with it, including the iteration count:
    /// raising the count for new passwords must not invalidate existing ones, and a stored
    /// hash that does not say how it was made cannot be re-verified after the parameters
    /// change.
    public struct StoredHash: Sendable, Equatable {
        public let iterations: Int
        public let salt: Data
        public let derivedKey: Data

        public init(iterations: Int, salt: Data, derivedKey: Data) {
            self.iterations = iterations
            self.salt = salt
            self.derivedKey = derivedKey
        }

        /// The stored form: `pbkdf2-sha256$<iterations>$<salt>$<key>`, base64 for the two
        /// binary parts.
        ///
        /// A single column rather than three, so adding a second algorithm later is a
        /// change to this string's first field rather than a schema migration.
        public var encoded: String {
            [
                "pbkdf2-sha256",
                String(iterations),
                salt.base64EncodedString(),
                derivedKey.base64EncodedString(),
            ].joined(separator: "$")
        }

        public init?(encoded: String) {
            let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[0] == "pbkdf2-sha256",
                  let iterations = Int(parts[1]), iterations > 0,
                  let salt = Data(base64Encoded: String(parts[2])),
                  let derivedKey = Data(base64Encoded: String(parts[3]))
            else { return nil }
            self.iterations = iterations
            self.salt = salt
            self.derivedKey = derivedKey
        }
    }

    /// Hashes a password with a fresh random salt.
    ///
    /// - Parameter iterations: How much work to do. Defaults to ``iterations``; a caller
    ///   passes a smaller number only where the cost matters more than the strength, which in
    ///   practice means tests.
    public static func hash(
        password: String,
        iterations: Int = PasswordHashing.iterations
    ) -> StoredHash {
        var salt = Data(count: saltByteCount)
        // `SystemRandomNumberGenerator` is the platform CSPRNG on both Darwin and Linux.
        var generator = SystemRandomNumberGenerator()
        for index in salt.indices {
            salt[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        let work = max(1, iterations)
        return StoredHash(
            iterations: work,
            salt: salt,
            derivedKey: derive(
                password: password,
                salt: salt,
                iterations: work,
                keyByteCount: keyByteCount
            )
        )
    }

    /// Verifies a password against a stored hash.
    ///
    /// Compared in constant time. A comparison that returns early on the first differing
    /// byte leaks how much of a guess was right, which is enough to recover a hash one byte
    /// at a time given enough attempts.
    public static func verify(password: String, against stored: StoredHash) -> Bool {
        let candidate = derive(
            password: password,
            salt: stored.salt,
            iterations: stored.iterations,
            keyByteCount: stored.derivedKey.count
        )
        return constantTimeEquals(candidate, stored.derivedKey)
    }

    /// PBKDF2 with HMAC-SHA256, per RFC 8018 §5.2.
    public static func derive(
        password: String,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) -> Data {
        derive(
            using: SHA256.self,
            password: Data(password.utf8),
            salt: salt,
            iterations: iterations,
            keyByteCount: keyByteCount
        )
    }

    /// PBKDF2 over any hash function.
    ///
    /// Generic over the hash so the tests can instantiate it with SHA-1 and check it
    /// against RFC 6070's published vectors — the only vectors for PBKDF2 that are
    /// universally agreed and easy to verify by hand. The construction is what is being
    /// tested; SHA-256 is what is used.
    static func derive<Hash: HashFunction>(
        using _: Hash.Type,
        password: Data,
        salt: Data,
        iterations: Int,
        keyByteCount: Int
    ) -> Data {
        precondition(iterations > 0, "PBKDF2 requires at least one iteration")
        precondition(keyByteCount > 0, "PBKDF2 must produce at least one byte")

        let key = SymmetricKey(data: password)
        let hashLength = Hash.Digest.byteCount
        // The number of hLen-sized blocks needed, rounded up.
        let blockCount = (keyByteCount + hashLength - 1) / hashLength

        var output = Data()
        output.reserveCapacity(blockCount * hashLength)

        for blockIndex in 1 ... blockCount {
            // U1 = PRF(password, salt ‖ INT(blockIndex)), big-endian, four bytes.
            var message = salt
            message.append(UInt8(truncatingIfNeeded: blockIndex >> 24))
            message.append(UInt8(truncatingIfNeeded: blockIndex >> 16))
            message.append(UInt8(truncatingIfNeeded: blockIndex >> 8))
            message.append(UInt8(truncatingIfNeeded: blockIndex))

            var current = Data(HMAC<Hash>.authenticationCode(for: message, using: key))
            var accumulated = current

            // U2…Uc, each the HMAC of the last, all exclusive-ored together.
            for _ in 1 ..< iterations {
                current = Data(HMAC<Hash>.authenticationCode(for: current, using: key))
                for index in accumulated.indices {
                    accumulated[index] ^= current[index]
                }
            }
            output.append(accumulated)
        }

        return output.prefix(keyByteCount)
    }

    /// Compares two byte strings without revealing where they differ.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        // The lengths are not secret — a hash's length is a property of the algorithm — so
        // returning early on a mismatch leaks nothing.
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
