import Foundation

enum EngineFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("engine/fixtures", isDirectory: true)

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func lines(_ name: String) throws -> [String] {
        try String(contentsOf: url(name), encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    static let mockRun = directory.appendingPathComponent("mock-run.ndjson")

    static func mockSource(_ name: String) -> URL {
        directory.appendingPathComponent("mock-run.sources", isDirectory: true).appendingPathComponent(name)
    }
}
