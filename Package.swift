// swift-tools-version: 6.0
import PackageDescription

// Quorum — native macOS overnight research shift.
// QuorumCore: pure logic (runNight, walls, mapper, store, reporter) — no AppKit, unit-tested.
// Quorum: the SwiftUI app + the real Claude Code subprocess executor and macOS services.
// Swift 5 language mode: async/await without strict-concurrency ceremony (the seam is the executor
// subprocess boundary, not the type system). ponytail: revisit if we need full data-race safety.
let package = Package(
    name: "Quorum",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "QuorumCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Quorum",
            dependencies: ["QuorumCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuorumCoreTests",
            dependencies: ["QuorumCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
