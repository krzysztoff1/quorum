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
    dependencies: [
        // Live-styled Markdown editor (TextKit 2) + HighlighterSwift-backed code blocks. Pre-1.0 → pin to the minor.
        // ponytail: skipping MarkdownEngineLatex (no formulas in our notes) — add it if that changes.
        .package(url: "https://github.com/nodes-app/swift-markdown-engine", .upToNextMinor(from: "0.8.0")),
    ],
    targets: [
        .target(
            name: "QuorumCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Quorum",
            dependencies: [
                "QuorumCore",
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
            ],
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
