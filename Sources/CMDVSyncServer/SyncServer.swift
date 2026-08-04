// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import Logging

/// The reference sync server.
///
/// Deliberately small. It stores envelopes and hands them back in order; it does not know
/// what a highlight is, and adding a new kind of synced data requires no change here at
/// all. That is the property that makes a self-hosted server something a reader can install
/// once and forget: the app can grow without the server needing to keep up.
public struct SyncServer: Sendable {
    let store: SyncStore
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void

    /// The ceiling on registration attempts. See ``RegistrationThrottle``.
    let throttle: RegistrationThrottle

    /// Usernames permitted to hold an account, or empty for any.
    let allowedUsernames: Set<String>

    /// - Parameters:
    ///   - now: Injected so tests can fix the clock. The server's clock reaches the client
    ///     in every response, which is how a device warns about skew.
    ///   - log: Where diagnostics go. A closure rather than a logging framework, because
    ///     the server writes a handful of lines and the operator decides where they land.
    ///   - throttle: Bounds how often the unauthenticated registration endpoint will derive a
    ///     key. Defaults to ``RegistrationThrottle/Limit/default``, because the one thing this
    ///     must not be is off by accident.
    ///   - allowedUsernames: Empty means any, which is the right default on a home network and
    ///     the wrong one on the open internet. See ``Configuration/allowedUsernames``.
    public init(
        store: SyncStore,
        now: @escaping @Sendable () -> Date = { Date() },
        log: @escaping @Sendable (String)
            -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
        throttle: RegistrationThrottle = RegistrationThrottle(limit: .default),
        allowedUsernames: Set<String> = []
    ) {
        self.store = store
        self.now = now
        self.log = log
        self.throttle = throttle
        self.allowedUsernames = allowedUsernames
    }

    /// Builds the router.
    ///
    /// Returned rather than started, so a test can drive it in-process. That is what makes the
    /// endpoint tests exercise the real middleware stack rather than a mock of it.
    ///
    /// - Parameter logRequests: A level at which to log one line per request, or `nil` for none.
    ///   Headers and bodies are never logged at any level, and that is not configurable: the
    ///   `Authorization` header is a working credential and a sync body is a reader's data, and
    ///   neither belongs in a log that ends up pasted into a bug report.
    public func router(logRequests: Logger.Level? = nil) -> Router<BasicRequestContext> {
        let router = Router()
        // Order matters: error translation must be outermost so it also catches whatever the
        // version check and the handlers throw.
        router.add(middleware: ErrorTranslationMiddleware(log: log))
        if let logRequests {
            router.add(middleware: LogRequestsMiddleware(logRequests, includeHeaders: .none))
        }
        router.add(middleware: VersionMiddleware())

        router.post("/api/v1/devices") { request, context in
            try await register(request: request, context: context)
        }
        router.get("/api/v1/devices") { request, context in
            try await listDevices(request: request, context: context)
        }
        router.delete("/api/v1/devices/:deviceID") { request, context in
            try await revokeDevice(request: request, context: context)
        }
        router.post("/api/v1/sync") { request, context in
            try await exchange(request: request, context: context)
        }
        // Unauthenticated on purpose: this is what someone points a monitor at, and what a
        // reader's app can use to say "the address is right but you are not signed in"
        // rather than "cannot connect".
        router.get("/api/v1/health") { _, _ in
            Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(
                    byteBuffer: .init(
                        bytes: Array(#"{"status":"ok","version":\#(SyncProtocolVersion.current)}"#
                            .utf8)
                    )
                )
            )
        }
        return router
    }

    // MARK: Registration

    private func register(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        let registration: DeviceRegistrationRequest = try await decode(request, context: context)

        guard !registration.username.isEmpty, registration.password.count >= 8 else {
            // A minimum rather than a full policy. Eight characters is the shortest a
            // password can be without being guessable in an afternoon, and refusing anything
            // more is a judgement about the reader's own server that is not this code's to
            // make.
            return Self.failure(
                .badRequest,
                .malformedRequest,
                "A username and a password of at least 8 characters are required."
            )
        }

        // Checked before the key derivation and before the store is touched, which is the only
        // placement that helps: the cost being defended against *is* the derivation.
        if case let .refused(retryAfter) = await throttle.claim(at: now()) {
            log("Registration refused by the throttle; retry in \(retryAfter)s.")
            return Self.failure(
                .tooManyRequests,
                .quotaExceeded,
                """
                Too many registration attempts. Try again in \(retryAfter) seconds. \
                (This limit is global and set by CMDV_SYNC_REGISTRATION_ATTEMPTS.)
                """,
                headers: [.retryAfter: String(retryAfter)]
            )
        }

        // An empty list means any username, which is the historical behaviour. When a list is
        // set, an unlisted username is refused as a credentials failure rather than as
        // "no such account": the two answers together would tell anyone who asked which
        // usernames exist on this server.
        guard allowedUsernames.isEmpty || allowedUsernames.contains(registration.username) else {
            log("Registration refused: '\(registration.username)' is not in CMDV_SYNC_USERNAMES.")
            return Self.failure(
                .unauthorized,
                .invalidCredentials,
                "Those credentials were refused."
            )
        }

        switch try await store.account(
            username: registration.username,
            password: registration.password
        ) {
        case .passwordRejected:
            return Self.failure(.unauthorized, .invalidCredentials, "That password was refused.")

        case let .created(accountID), let .existing(accountID):
            // A token with 256 bits of entropy, and the server keeps only its hash. A
            // stolen database therefore does not yield working tokens — the same reasoning
            // that applies to passwords applies here, and a token is what actually grants
            // access.
            let token = Self.generateToken()
            try await store.registerDevice(
                deviceID: registration.deviceID,
                accountID: accountID,
                deviceName: registration.deviceName,
                tokenHash: Self.hash(token: token),
                at: now()
            )
            return try Self.json(
                DeviceToken(token: token, deviceID: registration.deviceID),
                status: .created
            )
        }
    }

    // MARK: Devices

    private func listDevices(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        let device = try await authenticate(request)
        return try await Self.json(store.devices(forAccountID: device.accountID))
    }

    private func revokeDevice(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        let device = try await authenticate(request)
        guard let parameter = context.parameters.get("deviceID"),
              let target = UUID(uuidString: parameter)
        else {
            return Self.failure(.badRequest, .malformedRequest, "That is not a device identifier.")
        }

        // Only within the caller's own account. Without this check any signed-in device
        // could revoke any other account's devices by guessing an identifier.
        let removed = try await store.revokeDevice(target, accountID: device.accountID)
        return Response(status: removed ? .noContent : .notFound)
    }

    // MARK: Exchange

    private func exchange(
        request: Request,
        context: some RequestContext
    ) async throws -> Response {
        let device = try await authenticate(request)
        let exchange: SyncExchangeRequest = try await decode(request, context: context)

        // The device identifier in the body must be the one the token belongs to. Otherwise
        // a device could claim another's identity and be sent that device's own writes back
        // — harmless in itself, but it would also let it push documents attributed to a
        // device the reader trusts.
        guard exchange.deviceID == device.deviceID else {
            return Self.failure(
                .forbidden,
                .malformedRequest,
                "The device identifier does not match the token."
            )
        }

        // Each document is stored as coming from the device that actually pushed it, whatever
        // the body claimed.
        //
        // The check above covers the request; this covers the documents inside it, which the
        // request-level check does not. Without it a device could push documents attributed to
        // another device in the same account, and the effect would be silent: the pull filter
        // omits a device's own writes, so the device named in the forgery would be the one
        // device never sent them, and it would show its reader a book history missing the very
        // edits it appeared to have made.
        //
        // Stamped rather than refused, deliberately. Refusing would fail the whole exchange for
        // a client that had some reason to send this, and there is no reason a correct client
        // would: the pushing device is the one asserting this version now, so overwriting the
        // field records the truth rather than discarding the data.
        let attributed = exchange.documents.map { document in
            document.deviceID == device.deviceID
                ? document
                : SyncDocument(
                    kind: document.kind,
                    documentID: document.documentID,
                    updatedAt: document.updatedAt,
                    deviceID: device.deviceID,
                    payload: document.payload,
                    sequence: document.sequence
                )
        }

        try await store.store(attributed, accountID: device.accountID)
        let page = try await store.documents(
            forAccountID: device.accountID,
            after: exchange.cursor,
            excludingDeviceID: device.deviceID,
            limit: exchange.limit
        )
        try await store.recordDeviceSeen(device.deviceID, at: now())

        return try Self.json(
            SyncExchangeResponse(
                documents: page.documents,
                cursor: page.cursor,
                hasMore: page.hasMore,
                serverTime: now()
            )
        )
    }

    // MARK: Authentication

    /// Resolves the bearer token on a request.
    ///
    /// - Throws: ``AuthenticationFailure`` for a missing or unknown token, which the error
    ///   middleware turns into a described response — a client's behaviour differs between
    ///   "sign in" and "your access was revoked", and it cannot tell from a bare 401.
    func authenticate(_ request: Request) async throws -> AuthenticatedDevice {
        guard let header = request.headers[.authorization],
              header.hasPrefix("Bearer ")
        else { throw AuthenticationFailure.missing }

        let token = String(header.dropFirst("Bearer ".count))
        guard let device = try await store.device(forTokenHash: Self.hash(token: token)) else {
            throw AuthenticationFailure.unknownToken
        }
        return device
    }

    enum AuthenticationFailure: Error, Equatable {
        case missing
        case unknownToken
    }

    /// A token, and only its hash is ever stored.
    ///
    /// SHA-256 with no salt and no iterations, unlike a password — and that is correct
    /// rather than an oversight. A token is 256 random bits, so there is no dictionary to
    /// attack and no benefit to slowing a lookup that happens on every single request.
    static func hash(token: String) -> String {
        Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        // URL-safe, so a token can be pasted into a query string or a configuration file
        // without escaping. Base64's `+` and `/` are the usual cause of a token that works
        // in one place and not another.
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Encoding

    private func decode<Value: Decodable>(
        _ request: Request,
        context: some RequestContext
    ) async throws -> Value {
        let body = try await request.body.collect(upTo: Self.maximumBodyBytes)
        do {
            return try SyncCoding.makeDecoder().decode(Value.self, from: Data(buffer: body))
        } catch {
            throw MalformedBody(detail: String(describing: error))
        }
    }

    /// The largest request body accepted.
    ///
    /// Sixteen megabytes: several times the largest plausible sync page, and small enough
    /// that a malicious or broken client cannot exhaust a small server's memory by
    /// streaming an endless body at it.
    static let maximumBodyBytes = 16 * 1024 * 1024

    struct MalformedBody: Error {
        let detail: String
    }

    static func json(
        _ value: some Encodable,
        status: HTTPResponse.Status = .ok
    ) throws -> Response {
        let data = try SyncCoding.makeEncoder().encode(value)
        return Response(
            status: status,
            headers: [
                .contentType: "application/json",
                versionHeaderName: String(SyncProtocolVersion.current),
            ],
            body: .init(byteBuffer: .init(bytes: Array(data)))
        )
    }

    /// - Parameter headers: Anything beyond the content type and the protocol version — in
    ///   practice only `Retry-After`. A client that does not know a header ignores it, so this
    ///   stays within the wire format rather than extending it.
    static func failure(
        _ status: HTTPResponse.Status,
        _ reason: SyncErrorResponse.Reason,
        _ message: String,
        headers: HTTPFields = [:]
    ) -> Response {
        let body = (try? SyncCoding.makeEncoder().encode(
            SyncErrorResponse(reason: reason, message: message)
        )) ?? Data()
        var fields: HTTPFields = [
            .contentType: "application/json",
            versionHeaderName: String(SyncProtocolVersion.current),
        ]
        for field in headers {
            fields[field.name] = field.value
        }
        return Response(
            status: status,
            headers: fields,
            body: .init(byteBuffer: .init(bytes: Array(body)))
        )
    }
}

/// The protocol's version header, as an `HTTPField.Name`.
///
/// Resolved once here rather than force-unwrapped at each use. The fallback is `.contentLanguage`
/// — a real header that no part of this protocol reads — so a typo in the constant would produce a
/// missing version header rather than a crash, and the test asserting that a mismatched version is
/// refused would fail and say so.
let versionHeaderName = HTTPField.Name(SyncProtocolVersion.headerName) ?? .contentLanguage

/// Refuses a protocol version this server cannot speak.
///
/// Checked before anything else, and refused rather than guessed at. A version mismatch
/// interpreted optimistically is how a newer client silently corrupts an older server's
/// data; a client told plainly that the versions differ can say so to its reader.
///
/// A request with *no* version header is allowed through as version 1, so that a plain
/// `curl` against the health endpoint — the first thing anyone does when a server will not
/// connect — is not refused for a missing header.
struct VersionMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if let header = request.headers[versionHeaderName] {
            guard let version = Int(header), version == SyncProtocolVersion.current else {
                return SyncServer.failure(
                    .conflict,
                    .versionUnsupported,
                    """
                    This server speaks version \(SyncProtocolVersion.current) of the sync \
                    protocol.
                    """
                )
            }
        }
        return try await next(request, context)
    }
}
