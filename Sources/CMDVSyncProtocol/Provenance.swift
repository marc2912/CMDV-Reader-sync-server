// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

/// Where `SyncProtocol.swift` comes from, and how it is kept honest.
///
/// The app and this server must agree about the wire format exactly. In the app's repository
/// that was guaranteed structurally: both ends imported one file. Here they cannot, because a
/// server anyone can host must build on Linux without the app's iOS-only dependencies in the
/// graph.
///
/// So `SyncProtocol.swift` in this target is a **verbatim copy** of
/// `Packages/CMDVReaderKit/Sources/CMDVSync/SyncProtocol.swift` in the app's repository —
/// byte-identical, including its comments, so that `diff` is the entire parity check. Nothing
/// in it may be edited here; a change to the wire format is made in the app and copied across.
/// `Scripts/check-protocol-parity.sh` does the comparison when both checkouts are present.
///
/// Only the envelope is copied. The app's module of the same name also contains the client,
/// the merge rules, and the payload definitions, and none of those belong on a server that by
/// design does not understand what it is storing.
///
/// The guard against silent drift is the protocol version itself: every request carries
/// ``SyncProtocolVersion/headerName``, and a mismatch is refused rather than guessed at. A
/// change to the format that forgets this file produces a refused request with an explanation,
/// not corrupted data.
enum ProtocolProvenance {}
