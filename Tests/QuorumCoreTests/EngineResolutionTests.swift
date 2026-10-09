import XCTest
@testable import QuorumCore

final class EngineResolutionTests: XCTestCase {

    private var supported: Int { RunStreamParser.supportedProtocolVersion }

    private func versionLine(protocol version: Int, build: String = "abc1234") -> String {
        #"{"type":"version","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":\#(version),"build":"\#(build)"}"#
    }

    func testHandshakeReadsTheVersionLine() throws {
        let handshake = try XCTUnwrap(EngineHandshake.parse(versionLine(protocol: 4) + "\n"))
        XCTAssertEqual(handshake, EngineHandshake(engineVersion: "0.1.0", protocolVersion: 4, build: "abc1234"))
    }

    func testABinaryThatPredatesTheVersionCommandStillGivesItsProtocolAway() throws {
        let staleOutput = """
        {"type":"system","subtype":"init","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":1,"session_id":"s","model":"deepseek/deepseek-chat"}
        {"type":"error","error":"No research prompt provided (pass -p \\"<topic>\\")."}
        """
        let handshake = try XCTUnwrap(EngineHandshake.parse(staleOutput))
        XCTAssertEqual(handshake.protocolVersion, 1)
        XCTAssertNil(handshake.build)
    }

    func testOutputFromSomethingElseIsNoHandshake() {
        XCTAssertNil(EngineHandshake.parse(""))
        XCTAssertNil(EngineHandshake.parse("quorum-engine 0.1.0"))
        XCTAssertNil(EngineHandshake.parse(#"{"type":"version","engine":"other","protocol_version":4}"#))
    }

    private func resolve(_ candidates: [EngineCandidate], executable: Set<String>,
                         outputs: [String: String]) -> EngineResolution {
        EngineResolution.resolve(candidates, isExecutable: { executable.contains($0) },
                                 probe: { outputs[$0] })
    }

    func testTakesTheFirstCandidateThatSpeaksTheProtocolThisAppReads() {
        let resolution = resolve(
            [EngineCandidate(path: "/override", origin: .override),
             EngineCandidate(path: "/bundle", origin: .bundle)],
            executable: ["/override", "/bundle"],
            outputs: ["/override": versionLine(protocol: supported), "/bundle": versionLine(protocol: supported)])
        XCTAssertEqual(resolution.path, "/override")
        XCTAssertEqual(resolution.handshake?.protocolVersion, supported)
        XCTAssertNil(resolution.fallbackReason)
    }

    func testAStaleBinaryIsPassedOverAndTheReasonKept() {
        let resolution = resolve(
            [EngineCandidate(path: "/repo/engine/dist/quorum-engine", origin: .devBuild),
             EngineCandidate(path: "/bundle", origin: .bundle)],
            executable: ["/repo/engine/dist/quorum-engine", "/bundle"],
            outputs: ["/repo/engine/dist/quorum-engine": versionLine(protocol: 1),
                      "/bundle": versionLine(protocol: supported)])
        XCTAssertEqual(resolution.path, "/bundle")
        XCTAssertEqual(resolution.rejections.count, 1)
        XCTAssertTrue(resolution.rejections[0].contains("protocol v1"), resolution.rejections[0])
    }

    func testNoUsableBinaryExplainsEveryCandidateItTried() throws {
        let resolution = resolve(
            [EngineCandidate(path: "/missing", origin: .override),
             EngineCandidate(path: "/mute", origin: .bundle),
             EngineCandidate(path: "/repo/engine/dist/quorum-engine", origin: .devBuild)],
            executable: ["/mute", "/repo/engine/dist/quorum-engine"],
            outputs: ["/mute": "", "/repo/engine/dist/quorum-engine": versionLine(protocol: supported + 1)])
        XCTAssertNil(resolution.path)
        let reason = try XCTUnwrap(resolution.fallbackReason)
        XCTAssertTrue(reason.contains("QUORUM_ENGINE_BIN=/missing is not an executable"), reason)
        XCTAssertTrue(reason.contains("/mute did not answer the version handshake"), reason)
        XCTAssertTrue(reason.contains("speaks protocol v\(supported + 1)"), reason)
        XCTAssertTrue(reason.contains("scripts/bundle-engine.sh"), reason)
    }

    func testNoCandidatesAtAllStillSaysWhy() throws {
        let reason = try XCTUnwrap(resolve([], executable: [], outputs: [:]).fallbackReason)
        XCTAssertTrue(reason.contains("no quorum-engine"), reason)
    }

    func testCandidatesComeInAFixedOrderOverrideThenBundleThenTheRepoBuild() {
        let repo = "/Users/me/andon"
        let existing: Set<String> = ["\(repo)/Package.swift", "\(repo)/engine/dist/quorum-engine"]
        let candidates = EngineCandidate.ordered(
            override: "/custom/quorum-engine",
            bundleResource: "/Applications/Quorum.app/Contents/Resources/quorum-engine",
            executable: URL(fileURLWithPath: "\(repo)/.build/arm64-apple-macosx/debug/Quorum"),
            fileExists: { existing.contains($0) })
        XCTAssertEqual(candidates, [
            EngineCandidate(path: "/custom/quorum-engine", origin: .override),
            EngineCandidate(path: "/Applications/Quorum.app/Contents/Resources/quorum-engine", origin: .bundle),
            EngineCandidate(path: "\(repo)/engine/dist/quorum-engine", origin: .devBuild),
        ])
    }

    func testAnInstalledAppOutsideTheRepoHasNoRepoBuildCandidate() {
        let candidates = EngineCandidate.ordered(
            override: nil, bundleResource: nil,
            executable: URL(fileURLWithPath: "/Applications/Quorum.app/Contents/MacOS/Quorum"),
            fileExists: { _ in false })
        XCTAssertTrue(candidates.isEmpty)
    }
}
