// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// A ceiling on how often the registration endpoint will derive a key.
///
/// `POST /api/v1/devices` is the one endpoint that is unauthenticated *and* expensive: it runs
/// PBKDF2 at 600,000 iterations, which is the whole point of the iteration count and also means a
/// single request costs — measured, in a release build on an Apple M-series machine — about **1.35
/// seconds** of CPU, and longer on the small ARM boxes this is meant to run on. Left open that is
/// two problems rather than one: an attacker can pin the CPU of a household server with a handful
/// of requests, and can grind at a password without anything slowing them down.
///
/// **Global, not per-address, and that is deliberate.** Per-address counting is the usual
/// reflex, and here it would be worse than nothing: this server is meant to sit behind a reverse
/// proxy, so every request arrives from the proxy's address and a per-address limit either
/// throttles the whole household as one or has to be taught to trust a forwarded header —
/// a header an attacker can set. A global limit needs no address, no header to trust, no
/// per-key bookkeeping to grow without bound, and it holds against a distributed attempt that
/// per-address counting would wave through.
///
/// The cost of that choice, stated rather than hidden: somebody hammering this endpoint can stop
/// *you* from registering a new device until the window passes. For a household server that is
/// the right way round — a delay you wait out, rather than a machine that stops answering — and
/// the window is short and configurable.
///
/// Every attempt counts, successful or not. Refusing only failures would leave the CPU attack
/// wide open, since an attacker who can create accounts makes every one of their requests a
/// success.
public actor RegistrationThrottle {
    /// How many attempts, over how long.
    public struct Limit: Sendable, Equatable {
        public let attempts: Int
        public let window: TimeInterval

        public init(attempts: Int, window: TimeInterval) {
            self.attempts = max(1, attempts)
            self.window = max(1, window)
        }

        /// Ten attempts per five minutes.
        ///
        /// Generous against real use and severe against an attack, because the two look nothing
        /// alike here. A household registers a device when someone gets a new phone — a handful
        /// of times ever, and rarely two in a minute. Ten in five minutes is more headroom than
        /// that needs, and is nowhere near enough to grind at a password: at this rate an
        /// attacker manages under three thousand guesses a day against a hash that also costs
        /// them 600,000 iterations each.
        public static let `default` = Limit(attempts: 10, window: 300)
    }

    /// When the recent attempts happened. Bounded by ``Limit/attempts``, since anything older
    /// than the window is dropped on every check and nothing is recorded once the limit is hit.
    private var attempts: [Date] = []

    /// `nil` disables throttling entirely.
    private let limit: Limit?

    public init(limit: Limit?) {
        self.limit = limit
    }

    /// The limit in force, or `nil` when throttling is off.
    ///
    /// Exposed so a test can assert that a server configured with nothing still has a limit. That
    /// is worth asserting directly: a default of `nil` would leave every deployment that
    /// configures nothing unprotected, and would still pass every test that supplied its own
    /// throttle.
    public var currentLimit: Limit? {
        limit
    }

    /// No ceiling at all.
    ///
    /// For tests that register many devices in a row, and for an operator who has put this
    /// behind something that already rate-limits. A fresh instance each time rather than one
    /// shared value, so no test can observe another's state through it.
    public static var disabled: RegistrationThrottle {
        RegistrationThrottle(limit: nil)
    }

    /// Whether an attempt may proceed.
    public enum Decision: Sendable, Equatable {
        case allowed
        /// Refused, with how long until the oldest recorded attempt leaves the window.
        ///
        /// Reported as whole seconds so it can be sent as `Retry-After`, which is defined in
        /// seconds and has no fractional form.
        case refused(retryAfter: Int)
    }

    /// Records an attempt and says whether it may go ahead.
    ///
    /// - Parameter now: Injected so a test can assert on the window without waiting for it.
    public func claim(at now: Date) -> Decision {
        guard let limit else { return .allowed }

        let cutoff = now.addingTimeInterval(-limit.window)
        // Dropped rather than counted-and-ignored, which is what keeps this array small
        // regardless of how long the process has been running.
        attempts.removeAll { $0 <= cutoff }

        guard attempts.count >= limit.attempts else {
            attempts.append(now)
            return .allowed
        }

        // The refused attempt is *not* recorded. Recording it would push the window forward on
        // every rejected request, so a client that kept retrying would extend its own lockout
        // indefinitely — and an attacker could hold the endpoint shut forever at no cost.
        let oldest = attempts.first ?? now
        let remaining = limit.window - now.timeIntervalSince(oldest)
        return .refused(retryAfter: max(1, Int(remaining.rounded(.up))))
    }
}
