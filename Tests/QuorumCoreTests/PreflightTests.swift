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

    func testAMissingEngineIsWarnedAboutBeforeTheRunNotAfter() {
        let notice = Preflight.engineNotice(engineBinaryFound: false)
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains(RunPipeline.engineName))
        XCTAssertTrue(notice!.contains(RunPipeline.legacyBadge))
        XCTAssertTrue(notice!.contains("QUORUM_ENGINE_BIN"))
    }

    func testAResolvedEngineSaysNothing() {
        XCTAssertNil(Preflight.engineNotice(engineBinaryFound: true))
    }
}
