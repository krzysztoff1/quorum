import XCTest
@testable import QuorumCore

/// The richer mock transcript that drives the dev-only "Mock TS core" toggle must reduce through the same
/// `RunStreamParser` the live engine uses — exercising the shapes a happy-path golden run doesn't: two
/// rounds, a halted angle, and a synthesis carrying conflicts + gaps. If the fixture is mis-authored or the
/// parser stops handling one of these, this fails.
final class MockRunTranscriptTests: XCTestCase {

    private func lines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mock-run.ndjson")
        return try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
    }

    func testRicherTranscriptReducesAcrossRoundsWithHaltAndConflicts() throws {
        let all = try lines()

        var plans = 0, rounds = 0, activity = 0
        var research: [TopicFindings] = []
        var syntheses: [TopicFindings] = []
        var runResultTopics = 0

        for line in all {
            guard let ev = RunStreamParser.parse(line) else {
                XCTFail("mock transcript emitted a line the parser rejected: \(line)"); continue
            }
            switch ev {
            case .plan(let a): plans += 1; XCTAssertEqual(a.count, 2)
            case .round(let r, let a): rounds += 1; XCTAssertEqual(r, 2); XCTAssertEqual(a.count, 1)
            case .activity: activity += 1
            case .topicResult(let tr):
                tr.role == "synthesis" ? syntheses.append(tr.toFindings()) : research.append(tr.toFindings())
            case .runResult(let rr): runResultTopics = rr.topics.count
            default: break
            }
        }

        XCTAssertEqual(plans, 1, "round 1 is announced with a plan event")
        XCTAssertEqual(rounds, 1, "round 2 is announced with a round event")
        XCTAssertGreaterThanOrEqual(activity, 3, "each round's angles stream live, routed by angle_id")

        XCTAssertEqual(research.count, 3, "a1 + a2 (round 1) + a3 (round 2)")
        XCTAssertEqual(research.filter { $0.status == .haltedSpend }.count, 1, "one angle halted on its spend cap")
        XCTAssertEqual(research.filter { $0.status == .complete }.count, 2)

        XCTAssertEqual(syntheses.count, 2, "one synthesis per round")
        XCTAssertTrue(syntheses.contains { !$0.conflicts.isEmpty && !$0.gaps.isEmpty },
                      "round 1's synthesis surfaces conflicts and gaps its fenced json carried")

        XCTAssertEqual(runResultTopics, 4, "3 angles + the final synthesis")
    }
}
