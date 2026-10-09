// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QVSDecode",
    platforms: [.macOS(.v14)],
    products: [.library(name: "QVSDecode", targets: ["QVSDecode"])],
    targets: [
        .target(name: "QVSDecode"),
        .testTarget(name: "QVSDecodeTests", dependencies: ["QVSDecode"]),
    ]
)
