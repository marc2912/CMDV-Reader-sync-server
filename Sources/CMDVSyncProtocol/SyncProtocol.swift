// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The wire format, version 1.
///
/// Its own protocol rather than kosync's. kosync models reading progress and nothing
/// else — no highlights, no notes, no statistics — so compatibility would cover a
/// fraction of what has to sync and would constrain the data model in exchange for that
/// fraction. Documented here instead, so that anyone can write another implementation.
///
/// Three properties are deliberate, and everything else follows from them.
///
/// **The server does not understand the payloads.** A document is an envelope with a
/// kind, an identity, a timestamp, and opaque bytes. The server keys on the envelope and
/// relays the bytes. A newer client can introduce a kind an older server has never heard
/// of and it will still be delivered, which is what makes a self-hosted server that
/// nobody updates a workable thing to own.
///
/// **The cursor is a server sequence number, not a clock.** Two devices with clocks
/// minutes apart still exchange every document exactly once. Clocks are used for
/// *merging*, where they are unavoidable, and nowhere else.
///
/// **One request both pushes and pulls.** A sync is a single exchange, which makes it
/// atomic from the client's point of view: either the whole thing happened or none of it
/// did, and there is no state to reconcile after a failure halfway through.
public enum SyncProtocolVersion {
    /// Sent as a header on every request, so a server can refuse a version it cannot
    /// speak rather than misinterpret it.
    public static let current = 1
    public static let headerName = "X-CMDV-Sync-Version"
}

/// What a document holds.
///
/// A closed set on this client, but *not* on the wire: a document whose kind this build
/// does not recognise is stored and relayed untouched rather than dropped. That is the
/// difference between a reader losing data when they upgrade one of two devices and not.
public enum SyncDocumentKind: RawRepresentable, Sendable, Hashable, Codable {
    /// Where the reader is in a book.
    case progress
    /// A highlight, note, or bookmark, including tombstones.
    case annotation
    /// A finished reading session. Immutable.
    case session
    /// One setting, keyed by its preference name.
    case setting
    /// A catalog, without credentials. Opt-in.
    case catalog
    /// A kind introduced by a newer version.
    case unrecognized(String)

    public init(rawValue: String) {
        switch rawValue {
        case "progress": self = .progress
        case "annotation": self = .annotation
        case "session": self = .session
        case "setting": self = .setting
        case "catalog": self = .catalog
        default: self = .unrecognized(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .progress: "progress"
        case .annotation: "annotation"
        case .session: "session"
        case .setting: "setting"
        case .catalog: "catalog"
        case let .unrecognized(value): value
        }
    }

    /// Whether a document of this kind may ever be replaced by a later one.
    ///
    /// Sessions are facts about the past. Two devices cannot disagree about one, so
    /// merging is a set union and the first copy to arrive is kept — which also makes a
    /// retried push harmless.
    public var isImmutable: Bool {
        self == .session
    }
}

/// One synchronized value.
///
/// The envelope carries everything needed to merge it; the payload carries what it
/// means. Both client and server handle envelopes, only the client reads payloads.
public struct SyncDocument: Sendable, Equatable, Codable, Identifiable {
    public let kind: SyncDocumentKind

    /// Identity within the kind, stable across devices.
    ///
    /// An annotation's or session's UUID, a setting's preference name, or — for progress
    /// — a book's derived identity key, since two devices that downloaded the same book
    /// have different local row identifiers for it. See ``BookSyncKey``.
    public let documentID: String

    /// When the value was last changed, by the clock of the device that changed it.
    ///
    /// Used for last-write-wins, with all the imprecision that implies when clocks
    /// disagree. The alternative — a vector clock or a Lamport timestamp per document —
    /// would make ordering exact but would still not tell a reader which of two edits
    /// they meant to keep. The cases where being wrong actually costs something (a
    /// reading position going backwards) are handled by asking instead. See
    /// ``ProgressMerge``.
    public let updatedAt: Date

    /// Which device wrote it. Breaks ties deterministically, and lets the interface say
    /// where a change came from.
    public let deviceID: UUID

    /// The value, encoded. Opaque to the server.
    public let payload: Data

    /// The server's sequence number, assigned on storage.
    ///
    /// Absent on a document being pushed, present on one being pulled. Monotonic per
    /// account, which is what makes ``SyncCursor`` complete: a client that has seen
    /// sequence *n* has seen everything up to *n*.
    public let sequence: Int?

    public var id: String {
        "\(kind.rawValue):\(documentID)"
    }

    public init(
        kind: SyncDocumentKind,
        documentID: String,
        updatedAt: Date,
        deviceID: UUID,
        payload: Data,
        sequence: Int? = nil
    ) {
        self.kind = kind
        self.documentID = documentID
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.payload = payload
        self.sequence = sequence
    }

    /// Which of two documents for the same identity wins, on the server's dumb rule.
    ///
    /// Later timestamp wins; a tie is broken by device identifier so that two servers
    /// given the same documents in different orders reach the same state. An immutable
    /// kind never replaces what is already stored.
    ///
    /// This rule is deliberately the *server's*, and deliberately crude. The client
    /// applies its own rules on top, because only the client knows enough to ask the
    /// reader a question.
    public func supersedes(_ other: SyncDocument) -> Bool {
        guard !kind.isImmutable else { return false }
        if updatedAt != other.updatedAt {
            return updatedAt > other.updatedAt
        }
        return deviceID.uuidString > other.deviceID.uuidString
    }
}

/// Where a client has read up to.
///
/// An opaque token as far as the client is concerned — it stores what it was given and
/// sends it back. Structured as an integer only so the reference server can implement it
/// as a row sequence; another implementation may use anything it can order.
public struct SyncCursor: Sendable, Equatable, Hashable, Codable {
    public let value: Int

    /// The cursor a device that has never synced sends.
    public static let beginning = SyncCursor(value: 0)

    public init(value: Int) {
        self.value = value
    }
}

/// A sync, in one request.
public struct SyncExchangeRequest: Sendable, Equatable, Codable {
    /// Everything this device has changed since it last synced.
    public let documents: [SyncDocument]

    /// Where this device has read up to.
    public let cursor: SyncCursor

    /// This device, so the server can omit documents it wrote itself.
    public let deviceID: UUID

    /// A limit on how many documents to return, so a first sync of a long history
    /// arrives in pages rather than in one response too large to hold in memory.
    public let limit: Int

    /// How many documents a single exchange moves.
    ///
    /// Five hundred: large enough that an ordinary sync is one round trip, small enough
    /// that a first sync against years of history stays within a few megabytes per
    /// response.
    public static let defaultLimit = 500

    public init(
        documents: [SyncDocument],
        cursor: SyncCursor,
        deviceID: UUID,
        limit: Int = SyncExchangeRequest.defaultLimit
    ) {
        self.documents = documents
        self.cursor = cursor
        self.deviceID = deviceID
        self.limit = limit
    }
}

/// What the server had that this device did not.
public struct SyncExchangeResponse: Sendable, Equatable, Codable {
    public let documents: [SyncDocument]

    /// Where to resume. Advanced past everything in ``documents``.
    public let cursor: SyncCursor

    /// Whether more remains beyond the limit, so the client knows to go again rather
    /// than waiting for the next scheduled sync to deliver the rest.
    public let hasMore: Bool

    /// The server's clock, so a client can warn about a skew large enough to make
    /// last-write-wins misbehave.
    public let serverTime: Date

    public init(
        documents: [SyncDocument],
        cursor: SyncCursor,
        hasMore: Bool,
        serverTime: Date
    ) {
        self.documents = documents
        self.cursor = cursor
        self.hasMore = hasMore
        self.serverTime = serverTime
    }
}

/// A device registering itself, in exchange for a token.
public struct DeviceRegistrationRequest: Sendable, Equatable, Codable {
    public let username: String
    public let password: String

    /// A name the reader will recognise in the device list, so revoking the right one is
    /// possible. The device's own name, not a serial number.
    public let deviceName: String

    public let deviceID: UUID

    public init(username: String, password: String, deviceName: String, deviceID: UUID) {
        self.username = username
        self.password = password
        self.deviceName = deviceName
        self.deviceID = deviceID
    }
}

/// A token for one device.
///
/// Per-device rather than per-account so a lost phone can be cut off without changing a
/// password and re-pairing everything else.
public struct DeviceToken: Sendable, Equatable, Codable {
    public let token: String
    public let deviceID: UUID

    public init(token: String, deviceID: UUID) {
        self.token = token
        self.deviceID = deviceID
    }
}

/// A device with access to an account.
public struct SyncDeviceInfo: Sendable, Equatable, Codable, Identifiable {
    public let deviceID: UUID
    public let deviceName: String
    public let registeredAt: Date
    public let lastSeenAt: Date?

    public var id: UUID {
        deviceID
    }

    public init(deviceID: UUID, deviceName: String, registeredAt: Date, lastSeenAt: Date?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
    }
}

/// A failure the server chose to describe.
///
/// A machine-readable reason alongside the prose, because the client's response to "your
/// token was revoked" is to ask the reader to sign in again, and to "the server is
/// full" is not — and neither can be told from an HTTP status alone.
public struct SyncErrorResponse: Sendable, Equatable, Codable {
    public let reason: Reason
    public let message: String

    public enum Reason: String, Sendable, Codable {
        case invalidCredentials
        case tokenRevoked
        case versionUnsupported
        case malformedRequest
        case quotaExceeded
        case serverError
    }

    public init(reason: Reason, message: String) {
        self.reason = reason
        self.message = message
    }
}

/// The one encoder and decoder both ends use.
///
/// Written down rather than left to defaults, because the wire format is a contract with
/// implementations that are not this one. Two choices matter: dates are ISO 8601 with
/// fractional seconds, so a document written twice in the same second still orders
/// correctly; and keys are used exactly as declared, so renaming a Swift property is a
/// visible protocol change rather than a silent one.
public enum SyncCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseDate(text) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Not an ISO 8601 instant: \(text)"
                    )
                )
            }
            return date
        }
        return decoder
    }

    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the format style is
    /// a `Sendable` value, where the formatter is a reference type that cannot be held in
    /// a shared constant under strict concurrency without a lock it does not need.
    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt
    )

    /// Accepts an instant without fractional seconds.
    ///
    /// This client always writes them, but another implementation may not, and refusing a
    /// whole exchange over a missing `.000` would be an interoperability failure with no
    /// upside.
    private static let wholeSecond = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt
    )

    static func parseDate(_ text: String) -> Date? {
        (try? fractional.parse(text)) ?? (try? wholeSecond.parse(text))
    }

    static func string(from date: Date) -> String {
        fractional.format(date)
    }
}
