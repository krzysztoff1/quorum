// swift-tools-version: 6.0
import PackageDescription

// NightYoke — native macOS overnight research shift.
// NightYokeCore: pure logic (runNight, walls, mapper, store, reporter) — no AppKit, unit-tested.
// NightYoke: the SwiftUI app + the real Claude Code subprocess executor and macOS services.
// Swift 5 language mode: async/await without strict-concurrency ceremony (the seam is the executor
// subprocess boundary, not the type system). ponytail: revisit if we need full data-race safety.
let package = Package(
    name: "NightYoke",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "NightYokeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NightYoke",
            dependencies: ["NightYokeCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NightYokeCoreTests",
            dependencies: ["NightYokeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
