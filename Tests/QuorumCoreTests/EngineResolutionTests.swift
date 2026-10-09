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

    private final class ProbeRecorder: @unchecked Sendable { var seen: [EngineCandidate] = [] }

    private func resolve(_ candidates: [EngineCandidate], executable: Set<String>,
                         outputs: [String: String]) -> EngineResolution {
        EngineResolution.resolve(candidates, isExecutable: { executable.contains($0) },
                                 probe: { outputs[$0.path] })
    }

    func testTakesTheFirstCandidateThatSpeaksTheProtocolThisAppReads() {
        let resolution = resolve(
            [EngineCandidate(path: "/override", origin: .override),
             EngineCandidate(path: "/bundle", origin: .bundle)],
            executable: ["/override", "/bundle"],
            outputs: ["/override": versionLine(protocol: supported), "/bundle": versionLine(protocol: supported)])
        XCTAssertEqual(resolution.path, "/override")
        XCTAssertEqual(resolution.handshake?.protocolVersion, supported)
        XCTAssertNil(resolution.refusalReason)
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
        let reason = try XCTUnwrap(resolution.refusalReason)
        XCTAssertTrue(reason.contains("QUORUM_ENGINE_BIN=/missing is not an executable"), reason)
        XCTAssertTrue(reason.contains("/mute did not answer the version handshake"), reason)
        XCTAssertTrue(reason.contains("speaks protocol v\(supported + 1)"), reason)
        XCTAssertTrue(reason.contains("scripts/bundle-engine.sh"), reason)
    }

    func testNoCandidatesAtAllStillSaysWhy() throws {
        let reason = try XCTUnwrap(resolve([], executable: [], outputs: [:]).refusalReason)
        XCTAssertTrue(reason.contains("no quorum-engine"), reason)
    }

    func testCandidatesComeInAFixedOrderOverrideThenSourceThenBundleThenTheRepoBuild() {
        let repo = "/Users/me/andon"
        let existing: Set<String> = ["\(repo)/Package.swift", "\(repo)/engine/dist/quorum-engine",
                                    "\(repo)/engine/src/index.ts"]
        let candidates = EngineCandidate.ordered(
            override: "/custom/quorum-engine",
            bundleResource: "/Applications/Quorum.app/Contents/Resources/quorum-engine",
            executable: URL(fileURLWithPath: "\(repo)/.build/arm64-apple-macosx/debug/Quorum"),
            bunPath: "/opt/homebrew/bin/bun", includesSource: true,
            fileExists: { existing.contains($0) })
        XCTAssertEqual(candidates, [
            EngineCandidate(path: "/custom/quorum-engine", origin: .override),
            EngineCandidate(path: "/opt/homebrew/bin/bun", origin: .source, arguments: ["\(repo)/engine/src/index.ts"]),
            EngineCandidate(path: "/Applications/Quorum.app/Contents/Resources/quorum-engine", origin: .bundle),
            EngineCandidate(path: "\(repo)/engine/dist/quorum-engine", origin: .devBuild),
        ])
    }

    func testAShippedAppInsideACheckoutNeverPrefersTheSourceEngineOverItsBundle() {
        let repo = "/Users/me/andon"
        let existing: Set<String> = ["\(repo)/Package.swift", "\(repo)/engine/src/index.ts"]
        let candidates = EngineCandidate.ordered(
            override: nil, bundleResource: "\(repo)/build/Quorum.app/Contents/Resources/quorum-engine",
            executable: URL(fileURLWithPath: "\(repo)/build/Quorum.app/Contents/MacOS/Quorum"),
            bunPath: "/opt/homebrew/bin/bun", includesSource: false, fileExists: { existing.contains($0) })
        XCTAssertEqual(candidates.map(\.origin), [.bundle])
    }

    func testACheckoutWithoutBunStillListsTheSourceCandidateSoTheRefusalCanSayWhy() throws {
        let repo = "/Users/me/andon"
        let existing: Set<String> = ["\(repo)/Package.swift", "\(repo)/engine/src/index.ts"]
        let candidates = EngineCandidate.ordered(
            override: nil, bundleResource: nil,
            executable: URL(fileURLWithPath: "\(repo)/.build/arm64-apple-macosx/debug/Quorum"),
            bunPath: nil, includesSource: true, fileExists: { existing.contains($0) })
        XCTAssertEqual(candidates, [
            EngineCandidate(path: "bun", origin: .source, arguments: ["\(repo)/engine/src/index.ts"]),
        ])
        let resolution = resolve(candidates, executable: [], outputs: [:])
        let reason = try XCTUnwrap(resolution.refusalReason)
        XCTAssertTrue(reason.contains("bun was not found"), reason)
    }

    func testAnEngineRunFromSourceIsLaunchedThroughBunAndStillHandshakesExactly() {
        let source = EngineCandidate(path: "/opt/homebrew/bin/bun", origin: .source,
                                     arguments: ["/repo/engine/src/index.ts"])
        let probed = ProbeRecorder()
        let resolution = EngineResolution.resolve(
            [source], isExecutable: { $0 == "/opt/homebrew/bin/bun" },
            probe: { candidate in probed.seen.append(candidate); return self.versionLine(protocol: self.supported) })
        XCTAssertEqual(resolution.path, "/opt/homebrew/bin/bun")
        XCTAssertEqual(resolution.arguments, ["/repo/engine/src/index.ts"])
        XCTAssertEqual(probed.seen, [source])

        let stale = EngineResolution.resolve([source], isExecutable: { _ in true },
                                             probe: { _ in self.versionLine(protocol: self.supported - 1) })
        XCTAssertNil(stale.path)
        XCTAssertTrue(stale.refusalReason?.contains("protocol v\(supported - 1)") == true)
    }

    func testASourceEngineThatCannotStartPointsAtBunInstallNotTheBundleScript() throws {
        let source = EngineCandidate(path: "/opt/homebrew/bin/bun", origin: .source,
                                     arguments: ["/repo/engine/src/index.ts"])
        let reason = try XCTUnwrap(EngineResolution.resolve([source], isExecutable: { _ in true },
                                                            probe: { _ in nil }).refusalReason)
        XCTAssertTrue(reason.contains("bun install"), reason)
        XCTAssertFalse(reason.contains("bundle-engine.sh"), reason)
    }

    func testEveryCandidateCheckedIsKeptWithItsVerdictForTheDoctor() {
        let resolution = resolve(
            [EngineCandidate(path: "/stale", origin: .devBuild),
             EngineCandidate(path: "/bundle", origin: .bundle),
             EngineCandidate(path: "/never-probed", origin: .override)],
            executable: ["/stale", "/bundle", "/never-probed"],
            outputs: ["/stale": versionLine(protocol: 1), "/bundle": versionLine(protocol: supported)])
        XCTAssertEqual(resolution.checks.map(\.candidate.path), ["/stale", "/bundle"])
        XCTAssertEqual(resolution.checks.map(\.accepted), [false, true])
        XCTAssertTrue(resolution.checks[0].detail.contains("protocol v1"), resolution.checks[0].detail)
        XCTAssertTrue(resolution.checks[1].detail.contains("protocol v\(supported)"), resolution.checks[1].detail)
    }

    func testRefusalReasonIsNilWheneverAnEngineWasFound() {
        let resolution = resolve([EngineCandidate(path: "/e", origin: .bundle)], executable: ["/e"],
                                 outputs: ["/e": versionLine(protocol: supported)])
        XCTAssertNil(resolution.refusalReason)
    }

    func testAnInstalledAppOutsideTheRepoHasNeitherARepoBuildNorASourceCandidate() {
        let candidates = EngineCandidate.ordered(
            override: nil, bundleResource: nil,
            executable: URL(fileURLWithPath: "/Applications/Quorum.app/Contents/MacOS/Quorum"),
            bunPath: nil, includesSource: true, fileExists: { _ in false })
        XCTAssertTrue(candidates.isEmpty)
    }

    func testBunIsFoundOnPathThenWhereGuiAppsNeverLook() {
        let existing: Set<String> = ["/Users/me/.bun/bin/bun", "/opt/homebrew/bin/bun"]
        XCTAssertEqual(BunLocator.find(path: "/usr/bin:/opt/homebrew/bin", home: "/Users/me",
                                       isExecutable: { existing.contains($0) }), "/opt/homebrew/bin/bun")
        XCTAssertEqual(BunLocator.find(path: nil, home: "/Users/me",
                                       isExecutable: { existing.contains($0) }), "/Users/me/.bun/bin/bun")
        XCTAssertNil(BunLocator.find(path: "/usr/bin", home: "/Users/me", isExecutable: { _ in false }))
    }

    func testTheDoctorListsEveryCandidateWithItsVerdict() {
        let resolution = resolve(
            [EngineCandidate(path: "/missing", origin: .override),
             EngineCandidate(path: "/bundle", origin: .bundle)],
            executable: ["/bundle"], outputs: ["/bundle": versionLine(protocol: supported, build: "f00ba12")])
        XCTAssertEqual(resolution.doctorRows.map(\.ok), [false, true])
        XCTAssertTrue(resolution.doctorRows[0].title.contains("QUORUM_ENGINE_BIN"), resolution.doctorRows[0].title)
        XCTAssertTrue(resolution.doctorRows[0].detail.contains("not an executable"), resolution.doctorRows[0].detail)
        XCTAssertTrue(resolution.doctorRows[1].detail.contains("build f00ba12"), resolution.doctorRows[1].detail)
    }

    func testTheDoctorSaysSoWhenThereWasNothingToCheck() {
        let rows = resolve([], executable: [], outputs: [:]).doctorRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].ok)
        XCTAssertTrue(rows[0].detail.contains("no quorum-engine"), rows[0].detail)
    }
}
