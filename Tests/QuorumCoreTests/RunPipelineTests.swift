import XCTest
@testable import QuorumCore

final class RunPipelineTests: XCTestCase {

    private func report(pipeline: RunPipeline?) -> RunReport {
        RunReport(
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 60),
            entries: [
                RunReport.TopicEntry(id: "s", question: "Q", status: .complete, preset: .standard,
                                     headline: "H", confidenceSummary: "1 high", sourcesConsulted: 3,
                                     costUSD: 1, durationSeconds: 60, note: nil, notePath: nil,
                                     transcriptPath: nil, isSynthesis: true),
                RunReport.TopicEntry(id: "a1", question: "Angle", status: .complete, preset: .standard,
                                     headline: "AH", confidenceSummary: "1 high", sourcesConsulted: 2,
                                     costUSD: 1, durationSeconds: 30, note: nil, notePath: nil,
                                     transcriptPath: nil),
            ],
            totalCostUSD: 2, runSpendCapUSD: 40, pipeline: pipeline)
    }

    private var supported: Int { RunStreamParser.supportedProtocolVersion }

    func testEngineRunNamesItsPipelineAndProtocol() {
        let digest = Reporter.renderDigest(report(pipeline: .engine(protocolVersion: supported)))
        XCTAssertTrue(digest.contains("**Pipeline:** quorum-engine · protocol v\(supported)"), digest)
        XCTAssertFalse(digest.contains("⚠️ stale"), digest)
    }

    func testARunWithNoRecordedPipelineSaysNothingEitherWay() {
        let digest = Reporter.renderDigest(report(pipeline: nil))
        XCTAssertFalse(digest.contains("**Pipeline:**"))
    }

    func testPipelineRoundTripsThroughReportJSON() throws {
        let encoded = try JSONEncoder().encode(report(pipeline: .engine(protocolVersion: 4)))
        let decoded = try JSONDecoder().decode(RunReport.self, from: encoded)
        XCTAssertEqual(decoded.pipeline, .engine(protocolVersion: 4))
    }

    func testOldReportJSONWithoutAPipelineStillDecodes() throws {
        let json = """
        {"startedAt":0,"finishedAt":60,"entries":[],"totalCostUSD":0,"runSpendCapUSD":40}
        """
        let decoded = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertNil(decoded.pipeline)
    }

    func testEngineRunRecordsWhichBinaryServedIt() throws {
        let handshake = EngineHandshake(engineVersion: "0.1.0", protocolVersion: supported, build: "abc1234")
        let pipeline = RunPipeline.engine(protocolVersion: supported, handshake: handshake)
        let digest = Reporter.renderDigest(report(pipeline: pipeline))
        XCTAssertTrue(digest.contains("**Pipeline:** quorum-engine 0.1.0 (abc1234) · protocol v\(supported)"), digest)

        let decoded = try JSONDecoder().decode(RunReport.self,
                                               from: JSONEncoder().encode(report(pipeline: pipeline)))
        XCTAssertEqual(decoded.pipeline?.engineVersion, "0.1.0")
        XCTAssertEqual(decoded.pipeline?.build, "abc1234")
        XCTAssertEqual(decoded.pipeline?.protocolVersion, supported)
    }

    func testAStreamThatAnnouncedNoProtocolKeepsTheOneTheHandshakeSaw() {
        let handshake = EngineHandshake(engineVersion: "0.1.0", protocolVersion: supported, build: nil)
        XCTAssertEqual(RunPipeline.engine(protocolVersion: nil, handshake: handshake).protocolVersion, supported)
    }

    func testAnOldReportFromTheRetiredInProcessPipelineStillDecodesWithoutAnyBadge() throws {
        let json = """
        {"startedAt":0,"finishedAt":60,"entries":[],"totalCostUSD":0,"runSpendCapUSD":40,
         "pipeline":{"name":"in-process","fallbackReason":"no engine"}}
        """
        let decoded = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.pipeline?.name, "in-process")
        let digest = Reporter.renderDigest(decoded)
        XCTAssertFalse(digest.contains("legacy"), digest)
        XCTAssertFalse(digest.contains("Why no engine"), digest)
    }
}
