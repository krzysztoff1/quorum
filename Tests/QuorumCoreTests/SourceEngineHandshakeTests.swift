import XCTest
@testable import QuorumCore

final class SourceEngineHandshakeTests: XCTestCase {

    private let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func probe(_ candidate: EngineCandidate) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate.path)
        process.arguments = candidate.arguments + ["version"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    func testTheEngineRunFromSourceSpeaksTheProtocolThisAppReads() throws {
        let fm = FileManager.default
        guard let bun = BunLocator.find(path: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory(),
                                        isExecutable: fm.isExecutableFile(atPath:)) else {
            throw XCTSkip("bun is not installed, so the engine cannot be run from source here")
        }
        let candidates = EngineCandidate.ordered(
            override: nil, bundleResource: nil,
            executable: repoRoot.appendingPathComponent(".build/debug/Quorum"),
            bunPath: bun, fileExists: fm.fileExists(atPath:))

        let resolution = EngineResolution.resolve(candidates, isExecutable: fm.isExecutableFile(atPath:), probe: probe)

        XCTAssertNil(resolution.refusalReason)
        XCTAssertEqual(resolution.path, bun)
        XCTAssertEqual(resolution.arguments, [repoRoot.appendingPathComponent("engine/src/index.ts").path])
        XCTAssertEqual(resolution.handshake?.protocolVersion, RunStreamParser.supportedProtocolVersion)
        XCTAssertEqual(resolution.handshake?.build, "source")
    }
}
