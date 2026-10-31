// swift-tools-version: 6.0
//
// RoomEQ — personal macOS menu-bar app that captures system audio through a
// Core Audio process tap and plays it back (later: with room-correction EQ).
//
// Build the .app with ./build.sh, run the unit tests with ./run-tests.sh
// (or `swift test`).

import PackageDescription

let package = Package(
    name: "RoomEQ",
    platforms: [
        // macOS 15 is the minimum because the real-time parameters use the
        // standard-library `Synchronization.Atomic` type (macOS 15+).
        // The process-tap APIs themselves need 14.2; `bundleIDs` needs 26
        // and is guarded with `#available`.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "RoomEQ", targets: ["RoomEQ"])
    ],
    targets: [
        // Pure, hardware-independent logic: render kernel (real-time path),
        // channel layout math, latency math, small value types. Unit-tested.
        // Stage 3 adds the biquad DSP and the REW parser here.
        .target(
            name: "RoomEQCore"
        ),

        // The application: Core Audio tap + aggregate device engine,
        // the @MainActor controller, and the (placeholder) menu-bar UI.
        // Swift 5 language mode: the Core Audio C callbacks and listener
        // blocks are not annotated for Swift 6 strict concurrency; thread
        // confinement is documented and enforced with dispatchPrecondition.
        .executableTarget(
            name: "RoomEQ",
            dependencies: ["RoomEQCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "RoomEQCoreTests",
            dependencies: ["RoomEQCore"]
        ),
    ]
)
