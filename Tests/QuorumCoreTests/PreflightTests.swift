import XCTest
@testable import QuorumCore

final class PreflightTests: XCTestCase {

    func testMissingIsNotOkAndSaysSo() {
        let r = Preflight.check(FakeProbe(result: ProbeResult(installed: false, authenticated: nil, version: nil, detail: "not on PATH")))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("not found"))
    }

    func testInstalledAndAuthedIsReady() {
        let r = Preflight.check(FakeProbe(result: ProbeResult(installed: true, authenticated: true, version: "2.1.198", detail: "ok")))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.contains("ready"))
        XCTAssertTrue(r.message.contains("2.1.198"))
    }

    func testInstalledButUnauthedIsNotOk() {
        let r = Preflight.check(FakeProbe(result: ProbeResult(installed: true, authenticated: false, version: "2.1.198", detail: "no creds")))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("not signed in"))
    }

    func testInstalledUnknownAuthIsOkButHonest() {
        let r = Preflight.check(FakeProbe(result: ProbeResult(installed: true, authenticated: nil, version: "2.1.198", detail: "present")))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.message.contains("couldn't be confirmed"))
    }

    func testAMissingEngineRefusesTheRunAndSaysWhatWasTried() {
        let resolution = EngineResolution.resolve([], isExecutable: { _ in false }, probe: { _ in nil })
        let refusal = Preflight.engineRefusal(resolution)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.contains("can't run"))
        XCTAssertTrue(refusal!.contains(RunPipeline.engineName))
        XCTAssertTrue(refusal!.contains(resolution.refusalReason!), "says which binaries it tried and why")
        XCTAssertFalse(refusal!.lowercased().contains("fall"), "there is no degraded run to fall back to")
    }

    func testAResolvedEngineRefusesNothing() {
        let line = #"{"type":"version","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":\#(RunStreamParser.supportedProtocolVersion),"record_schema":"quorum.run/1"}"#
        let resolution = EngineResolution.resolve([EngineCandidate(path: "/e", origin: .bundle)],
                                                  isExecutable: { _ in true }, probe: { _ in line })
        XCTAssertNil(Preflight.engineRefusal(resolution))
    }
}
