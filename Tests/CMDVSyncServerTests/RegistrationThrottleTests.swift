// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import CMDVSyncServer

/// The window, on its own.
///
/// The endpoint tests cover that the throttle is wired in and what a refusal looks like on the
/// wire. What is worth testing here is the arithmetic, because a rate limiter that is wrong is
/// either useless or locks out the person who owns the server, and neither shows up as a crash.
@Suite("Registration throttle")
struct RegistrationThrottleTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Attempts up to the limit are allowed")
    func underTheLimit() async {
        let throttle = RegistrationThrottle(limit: .init(attempts: 3, window: 60))
        for _ in 0 ..< 3 {
            #expect(await throttle.claim(at: instant) == .allowed)
        }
    }

    @Test("The attempt past the limit is refused, and says how long to wait")
    func atTheLimit() async {
        let throttle = RegistrationThrottle(limit: .init(attempts: 2, window: 60))
        _ = await throttle.claim(at: instant)
        _ = await throttle.claim(at: instant.addingTimeInterval(10))

        #expect(
            await throttle.claim(at: instant.addingTimeInterval(20)) == .refused(retryAfter: 40)
        )
    }

    /// The window slides rather than resetting wholesale, so the first slot frees up as soon as the
    /// attempt that took it leaves the window — not at some fixed interval boundary.
    @Test("A slot frees up as soon as the attempt that took it leaves the window")
    func windowSlides() async {
        let throttle = RegistrationThrottle(limit: .init(attempts: 2, window: 60))
        _ = await throttle.claim(at: instant)
        _ = await throttle.claim(at: instant.addingTimeInterval(30))

        #expect(await throttle.claim(at: instant.addingTimeInterval(59)) != .allowed)
        // The first attempt is now more than 60s old, so its slot is free — but the second one is
        // not, so only one slot is.
        #expect(await throttle.claim(at: instant.addingTimeInterval(61)) == .allowed)
        #expect(await throttle.claim(at: instant.addingTimeInterval(62)) != .allowed)
    }

    /// The failure mode this guards against is the nastier of the two available: if a refused
    /// attempt were recorded, a client that kept retrying would push its own window forward on
    /// every try and never get back in — and an attacker could hold the endpoint shut forever at
    /// no cost to themselves.
    @Test("A refused attempt does not extend the lockout")
    func refusalsDoNotExtendTheWindow() async {
        let throttle = RegistrationThrottle(limit: .init(attempts: 1, window: 60))
        _ = await throttle.claim(at: instant)

        // Hammered throughout the window.
        for second in 1 ..< 60 {
            #expect(await throttle.claim(at: instant.addingTimeInterval(Double(second))) != .allowed)
        }

        // And it still opens on time.
        #expect(await throttle.claim(at: instant.addingTimeInterval(61)) == .allowed)
    }

    @Test("Time passing clears the window entirely")
    func windowExpires() async {
        let throttle = RegistrationThrottle(limit: .init(attempts: 1, window: 60))
        _ = await throttle.claim(at: instant)
        #expect(await throttle.claim(at: instant) != .allowed)
        #expect(await throttle.claim(at: instant.addingTimeInterval(3600)) == .allowed)
    }

    @Test("A throttle with no limit allows everything")
    func disabled() async {
        let throttle = RegistrationThrottle.disabled
        for _ in 0 ..< 100 {
            #expect(await throttle.claim(at: instant) == .allowed)
        }
        #expect(await throttle.currentLimit == nil)
    }

    /// `disabled` hands back a fresh instance each time, so no test can see another's attempts
    /// through it.
    @Test("Each disabled throttle is its own")
    func disabledIsNotShared() async {
        let first = RegistrationThrottle.disabled
        let second = RegistrationThrottle.disabled
        #expect(first !== second)
    }

    /// Nonsense is clamped rather than trusted: a limit of zero attempts would refuse every
    /// registration forever, which is a way to lock yourself out of your own server by typo.
    @Test("A limit below one attempt is clamped to one rather than locking everyone out")
    func nonsenseLimitsAreClamped() async {
        let limit = RegistrationThrottle.Limit(attempts: 0, window: 0)
        #expect(limit.attempts == 1)
        #expect(limit.window == 1)

        let throttle = RegistrationThrottle(limit: limit)
        #expect(await throttle.claim(at: instant) == .allowed)
    }

    /// The default has to be usable by a household and useless to an attacker at the same time, so
    /// both halves are asserted rather than left to a comment.
    @Test("The default is generous against real use and severe against a guessing attack")
    func theDefaultIsBothThings() {
        let limit = RegistrationThrottle.Limit.default
        // More than anyone registering a new phone will ever need in one sitting.
        #expect(limit.attempts >= 5)
        // And under three thousand guesses a day, against a hash that costs 600,000 iterations
        // each.
        let perDay = Double(limit.attempts) * (86400 / limit.window)
        #expect(perDay < 3000)
    }
}
