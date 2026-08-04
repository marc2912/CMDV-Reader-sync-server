// swift-tools-version: 6.0
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

/// The reference sync server for CMDV Reader.
///
/// A standalone package, and that is the point of this repository. The server was extracted
/// from the app's own repository, where it depended on the app's `CMDVSync` module by path —
/// which meant you could not build the server without checking out the whole app, and the
/// app's iOS-only dependencies stood between this and a Linux container.
///
/// The wire format is therefore vendored here as ``CMDVSyncProtocol``, byte-identical to the
/// app's copy so a `diff` is the whole parity check. See `Scripts/check-protocol-parity.sh`
/// and `Sources/CMDVSyncProtocol/Provenance.swift`.
let package = Package(
    name: "CMDVSyncServer",
    // macOS is declared so the suite runs headlessly on a developer's Mac. Linux needs no
    // declaration and is the platform this actually ships on, in the container.
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmdv-sync-server", targets: ["cmdv-sync-server"]),
        .library(name: "CMDVSyncServer", targets: ["CMDVSyncServer"]),
        // Exported so another implementation of the protocol — or a test harness in another
        // repository — can build against the same definitions rather than a transcription.
        .library(name: "CMDVSyncProtocol", targets: ["CMDVSyncProtocol"]),
    ],
    dependencies: [
        // Hummingbird 2, and the only third-party runtime dependency here.
        //
        // Justified rather than assumed: an HTTP/1.1 server with keep-alive and chunked
        // transfer is thousands of lines of exacting work that has nothing to do with this
        // product, and getting it subtly wrong is a security problem rather than a bug.
        // Hummingbird over Vapor because it is markedly smaller, has no ORM or templating to
        // carry, and is built on async/await rather than futures. Apache-2.0, which is
        // compatible with this package's MPL-2.0.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Apple's swift-crypto, for HMAC-SHA256 under the password hashing. CryptoKit would do
        // on macOS and does not exist on Linux, and a server anyone can host has to build on
        // Linux. Apache-2.0.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // swift-log, which Hummingbird already requires and which is therefore not a new
        // dependency in any meaningful sense — declared explicitly so that importing `Logging`
        // to parse a log level is legitimate rather than reliant on a transitive re-export.
        // Apache-2.0.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // SQLite's C API, portably.
        //
        // `import SQLite3` is Apple-only, and a server anyone can host must build on Linux. A
        // shim target with a header and a link flag is the whole cost of being portable, and
        // it adds no dependency.
        .target(
            name: "CSQLiteShim",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // The wire format. Pure Foundation, no dependencies, deliberately.
        //
        // That constraint is what lets this build on Linux at all: the app's module of the
        // same name also carries the client and the merge rules, which reach URLSession and
        // the app's own domain types. Only the envelope belongs on a server.
        .target(
            name: "CMDVSyncProtocol",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),

        // The server itself, as a library so it can be started in-process by a test.
        //
        // That is the point of the split: the tests that matter drive the real router with no
        // network and no fixtures, and they can only do that if the server is a value
        // something else can construct.
        .target(
            name: "CMDVSyncServer",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                "CMDVSyncProtocol",
                "CSQLiteShim",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .executableTarget(
            name: "cmdv-sync-server",
            dependencies: ["CMDVSyncServer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CMDVSyncServerTests",
            dependencies: [
                "CMDVSyncServer",
                "CMDVSyncProtocol",
                // Hummingbird's own test support, which drives the real router in-process.
                // The app's HTTP client used to play this part; it cannot follow the server
                // into a repository that does not contain the app, and a router exercised
                // over real HTTP semantics is the better test regardless.
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
