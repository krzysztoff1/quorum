import XCTest
@testable import QuorumCore

final class DoctorReportTests: XCTestCase {
    private func resolution(build: String?, protocolVersion: Int? = nil) -> EngineResolution {
        let candidate = EngineCandidate(path: "/App/Contents/Resources/quorum-engine", origin: .bundle)
        let line = #"{"type":"version","engine":"quorum-engine","engine_version":"0.1.0","protocol_version":\#(protocolVersion ?? RunStreamParser.supportedProtocolVersion),"record_schema":"quorum.run/1","build":"\#(build ?? "")"}"#
        return EngineResolution.resolve([candidate], isExecutable: { _ in true }, probe: { _ in line })
    }

    func testAHealthyInstallReportsEveryLineOkAndPasses() {
        let report = DoctorReport(engine: resolution(build: "abc1234"),
                                  claude: PreflightResult(ok: true, message: "Claude Code ready (v2.1.295)."),
                                  appBuild: "abc1234")
        XCTAssertTrue(report.ok)
        XCTAssertTrue(report.text.contains("app build abc1234"))
        XCTAssertTrue(report.text.contains("ok    engine"))
        XCTAssertTrue(report.text.contains("protocol v\(RunStreamParser.supportedProtocolVersion)"))
        XCTAssertTrue(report.text.contains("build abc1234"))
        XCTAssertTrue(report.text.contains("ok    claude"))
    }

    func testAMissingEngineFailsAndSaysWhy() {
        let none = EngineResolution.resolve([], isExecutable: { _ in false }, probe: { _ in nil })
        let report = DoctorReport(engine: none, claude: PreflightResult(ok: true, message: "ready"), appBuild: nil)
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.text.contains("FAIL  engine"))
        XCTAssertTrue(report.text.contains("no quorum-engine"))
    }

    func testALoggedOutClaudeFailsTheReport() {
        let report = DoctorReport(engine: resolution(build: "abc1234"),
                                  claude: PreflightResult(ok: false, message: "Claude Code is installed but not signed in."),
                                  appBuild: "abc1234")
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.text.contains("FAIL  claude"))
        XCTAssertTrue(report.text.contains("not signed in"))
    }
}
