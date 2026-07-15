import XCTest
@testable import QuorumCore

/// The fan-out-in-TS seam: the engine's `run` command must emit a stream the Swift `RunStreamParser`
/// reduces to the same angle + synthesis findings the app would have produced in-process. This replays
/// the engine's checked-in golden run transcript and asserts the reduction — if the engine changes its
/// run output shape, this fails.
final class EngineRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/run-transcript.ndjson")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    func testRunTranscriptReducesToAnglesAndSynthesis() throws {
        let all = try lines()
        XCTAssertFalse(all.isEmpty)

        var sawRunStart = false
        var plannedAngles = 0
        var perAngleActivity = 0
        var angleFindings: [TopicFindings] = []
        var synthesis: TopicFindings?
        var runResultTopics = 0

        for line in all {
            guard let ev = RunStreamParser.parse(line) else {
                XCTFail("engine emitted a run line the parser rejected: \(line)"); continue
            }
            switch ev {
            case .runStart: sawRunStart = true
            case .plan(let angles): plannedAngles = angles.count
            case .activity: perAngleActivity += 1
            case .topicResult(let tr):
                if tr.role == "synthesis" { synthesis = tr.toFindings() }
                else { angleFindings.append(tr.toFindings()) }
            case .runResult(let rr): runResultTopics = rr.topics.count
            default: break
            }
        }

        XCTAssertTrue(sawRunStart, "run must announce itself")
        XCTAssertEqual(plannedAngles, 2)
        XCTAssertGreaterThanOrEqual(perAngleActivity, 2, "per-angle live stream must route by angle_id")
        XCTAssertEqual(angleFindings.count, 2)
        XCTAssertTrue(angleFindings.allSatisfy { $0.status == .complete })
        XCTAssertTrue(angleFindings.allSatisfy { !$0.findings.isEmpty }, "each angle's fenced json survives parsing")
        XCTAssertNotNil(synthesis)
        XCTAssertEqual(synthesis?.status, .complete)
        XCTAssertEqual(runResultTopics, 3, "2 angles + 1 synthesis")
        // These angles ran on the BYOK engine → their sessions are synthetic (chat seeds, not --resume).
        XCTAssertTrue(angleFindings.allSatisfy { ($0.usage?.provider ?? "") != "anthropic" })
    }
}
