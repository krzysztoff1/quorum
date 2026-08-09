import XCTest
@testable import QuorumCore

/// The engine (PRD 01) must emit a stream the existing parser turns into a valid `TopicFindings`
/// unchanged. This replays the checked-in golden transcript through exactly the reduction the
/// executor performs (parse each line → accumulate cost/usage → parseFinal) and asserts the result.
/// When the engine records a real transcript, it replaces this fixture and this test still must pass.
final class EngineTranscriptTests: XCTestCase {

    private func fixtureLines() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/engine-transcript.ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    func testEngineTranscriptReducesToValidFindings() throws {
        let lines = try fixtureLines()
        XCTAssertFalse(lines.isEmpty)

        var sawHandshake = false
        var toolUses = 0
        var maxCost = Decimal(0)
        var steps: [ResearchOutputParser.StepUsage] = []
        var finalResult: String?

        for line in lines {
            guard let ev = ResearchOutputParser.parseStreamLine(line) else {
                XCTFail("engine emitted a line the parser rejected: \(line)"); continue
            }
            if ev.type == "system" { sawHandshake = true }
            toolUses += ev.toolUses.count
            if let t = ev.totalCostUSD, t > maxCost { maxCost = t }   // cumulative + monotonic
            if let u = ev.usage { steps.append(u) }
            if ev.type == "result", let r = ev.result { finalResult = r }
        }

        XCTAssertTrue(sawHandshake, "first event must announce engine + protocol version")
        XCTAssertGreaterThanOrEqual(toolUses, 2, "expected at least a search and a fetch")

        let usage = TopicUsage.from(steps: steps)
        XCTAssertNotNil(usage, "per-step usage events must be present (R5)")
        XCTAssertEqual(usage?.provider, "deepseek")
        XCTAssertGreaterThan(usage?.searchCalls ?? 0, 0)
        XCTAssertGreaterThan(usage?.fetchCalls ?? 0, 0)
        XCTAssertGreaterThan(maxCost, 0, "total_cost_usd must stream")
        let costGap = (usage!.costUSD - maxCost).magnitude
        XCTAssertLessThan(costGap, Decimal(string: "0.0001")!, "summed step cost tracks the run total")

        let out = ResearchOutputParser.parseFinal(finalResult ?? "")
        XCTAssertEqual(out.status, .complete)
        XCTAssertFalse(out.findings.isEmpty, "the fenced json summary must survive parsing")
        XCTAssertEqual(out.findings.first?.confidence, .high)
    }
}
