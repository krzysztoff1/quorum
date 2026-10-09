import Foundation

enum EngineFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("engine/fixtures", isDirectory: true)

    static let mockRun = directory.appendingPathComponent("mock-run.ndjson")

    static func mockSource(_ name: String) -> URL {
        directory.appendingPathComponent("mock-run.sources", isDirectory: true).appendingPathComponent(name)
    }
}
