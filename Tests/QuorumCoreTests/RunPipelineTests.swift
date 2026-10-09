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
        XCTAssertFalse(digest.contains(RunPipeline.legacyBadge))
        XCTAssertNil(RunPipeline.engine(protocolVersion: supported).badge)
    }

    func testABinaryBehindTheAppSaysSoRatherThanQuietlySkippingStages() throws {
        let stale = RunPipeline.engine(protocolVersion: supported - 1)
        XCTAssertTrue(try XCTUnwrap(stale.badge).contains("stale engine"))
        XCTAssertTrue(Reporter.renderDigest(report(pipeline: stale)).contains("stale engine"))
        XCTAssertNil(RunPipeline.engine(protocolVersion: nil).badge,
                     "a stream that announced no version is unknown, not proven stale")
    }

    func testFallbackRunIsBadgedInTheDigestAndOnEveryEntry() {
        let digest = Reporter.renderDigest(report(pipeline: .inProcess))
        XCTAssertTrue(digest.contains("**Pipeline:** in-process"), digest)
        let badges = digest.components(separatedBy: RunPipeline.legacyBadge).count - 1
        XCTAssertEqual(badges, 3, "once in the header and once on each of the two entries")
    }

    func testARunWithNoRecordedPipelineSaysNothingEitherWay() {
        let digest = Reporter.renderDigest(report(pipeline: nil))
        XCTAssertFalse(digest.contains("**Pipeline:**"))
        XCTAssertFalse(digest.contains(RunPipeline.legacyBadge))
    }

    func testPipelineRoundTripsThroughReportJSON() throws {
        let encoded = try JSONEncoder().encode(report(pipeline: .engine(protocolVersion: 4)))
        let decoded = try JSONDecoder().decode(RunReport.self, from: encoded)
        XCTAssertEqual(decoded.pipeline, .engine(protocolVersion: 4))
        XCTAssertTrue(decoded.pipeline?.validates == true)
    }

    func testOldReportJSONWithoutAPipelineStillDecodes() throws {
        let json = """
        {"startedAt":0,"finishedAt":60,"entries":[],"totalCostUSD":0,"runSpendCapUSD":40}
        """
        let decoded = try JSONDecoder().decode(RunReport.self, from: Data(json.utf8))
        XCTAssertNil(decoded.pipeline)
    }

    func testHeaderCarriesTheBadgeSoTheCanvasCanSayIt() {
        XCTAssertEqual(RunHeader(report: report(pipeline: .inProcess)).pipelineNotice, RunPipeline.legacyBadge)
        XCTAssertNil(RunHeader(report: report(pipeline: .engine(protocolVersion: 4))).pipelineNotice)
        XCTAssertNil(RunHeader(report: report(pipeline: nil)).pipelineNotice)
    }
}
