// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CMDVSyncProtocol
import Hummingbird

/// Turns a thrown error into a response the client can act on.
///
/// Hummingbird's default is a bare status with no body, which is exactly what the client
/// cannot work with: a 401 could be a wrong password or a revoked token, and the reader's
/// next step differs. Every failure the server produces therefore names a machine-readable
/// reason.
///
/// Anything unrecognised becomes a 500 with no detail. An unexpected error's description can
/// contain a file path, a query, or a fragment of a reader's data, and none of that belongs
/// in a response.
struct ErrorTranslationMiddleware<Context: RequestContext>: RouterMiddleware {
    let log: @Sendable (String) -> Void

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let failure as SyncServer.AuthenticationFailure {
            switch failure {
            case .missing:
                return SyncServer.failure(
                    .unauthorized,
                    .invalidCredentials,
                    "This request needs a bearer token."
                )
            case .unknownToken:
                // Deliberately the same answer for a token that never existed and one that
                // was revoked: distinguishing them would confirm which tokens once existed.
                return SyncServer.failure(
                    .forbidden,
                    .tokenRevoked,
                    "That token is not valid. Sign in again on this device."
                )
            }
        } catch let malformed as SyncServer.MalformedBody {
            // The decoding detail is returned here, and it is safe to: it describes the
            // *client's* own request, which the client already has.
            return SyncServer.failure(.badRequest, .malformedRequest, malformed.detail)
        } catch let httpError as HTTPError {
            // Hummingbird signals a missing route or an unacceptable request by throwing, and
            // without this those all arrived as 500s — so a client could not tell "no such
            // device" from "the server broke", and a URL typed with a missing path segment
            // looked like a server fault.
            return SyncServer.failure(
                httpError.status,
                httpError.status.code == 404 ? .malformedRequest : .serverError,
                httpError.body ?? "The server could not handle that request."
            )
        } catch let storeError as SyncStore.StoreError {
            log("Storage failure: \(storeError)")
            return SyncServer.failure(
                .internalServerError,
                .serverError,
                "The server could not store or read that. Nothing was lost."
            )
        } catch {
            log("Unhandled failure: \(error)")
            return SyncServer.failure(
                .internalServerError,
                .serverError,
                "The server failed to handle that request."
            )
        }
    }
}
