import XCTest
@testable import NightYokeCore

/// The synthesis-quality additions: source corroboration, structured conflict parsing, and the
/// deterministic citation-grounding tripwire + its gated cheap repair. All offline via fakes.
final class CitationGroundingTests: XCTestCase {

    private func angle(id: String, sources: [[String]]) -> TopicFindings {
        TopicFindings(id: id, status: .complete, preset: .standard, headline: "H \(id)",
                      findings: sources.map { Finding(claim: "c", sources: $0, confidence: .high) },
                      sourcesConsulted: sources.count, costUSD: 0, duration: .seconds(0),
                      writeupMarkdown: "body \(id)", transcript: "", note: nil)
    }

    // MARK: 1b — corroboration table

    func testCorroborationCountsDistinctAnglesAndDedupes() {
        let angles = [
            angle(id: "a1", sources: [["https://x.example", "https://x.example"], ["https://y.example"]]),
            angle(id: "a2", sources: [["https://x.example/"]]),                 // trailing slash → same as x
            angle(id: "a3", sources: [["HTTPS://X.EXAMPLE"]]),                  // case → same as x
        ]
        let table = corroboration(angles)
        let x = table.first { $0.url.contains("x.example") }
        XCTAssertEqual(x?.count, 3, "x.example cited by all 3 angles despite dupes/slash/case")
        XCTAssertEqual(table.first?.url, x?.url, "most-corroborated sorts first")
        XCTAssertEqual(table.filter { $0.url.contains("y.example") }.first?.count, 1)
        // No duplicate rows for the same normalized URL.
        XCTAssertEqual(Set(table.map(\.url)).count, table.count)
    }

    // MARK: 2a — conflict parsing

    func testParsesConflictsArray() {
        let text = """
        Some prose.
        ```json
        {"headline":"h","status":"complete","sourcesConsulted":2,
        "findings":[{"claim":"c","sources":["https://a"],"confidence":"high"}],
        "conflicts":[{"claim":"Is X true?","positions":["angle 1: yes","angle 2: no"]}]}
        ```
        """
        let out = ResearchOutputParser.parseFinal(text)
        XCTAssertEqual(out.conflicts.count, 1)
        XCTAssertEqual(out.conflicts.first?.claim, "Is X true?")
        XCTAssertEqual(out.conflicts.first?.positions, ["angle 1: yes", "angle 2: no"])
    }

    func testMissingOrEmptyConflictsDegradesToEmpty() {
        let noField = "```json\n{\"headline\":\"h\",\"status\":\"complete\",\"findings\":[]}\n```"
        XCTAssertEqual(ResearchOutputParser.parseFinal(noField).conflicts, [])
        // A conflict with no positions is dropped, not surfaced as a bogus empty conflict.
        let empty = "```json\n{\"conflicts\":[{\"claim\":\"c\",\"positions\":[]}]}\n```"
        XCTAssertEqual(ResearchOutputParser.parseFinal(empty).conflicts, [])
    }

    // MARK: 2b/2c — citation grounding

    /// Records how many `.verify` calls it received; returns empty findings so repair keeps the original.
    private final class VerifyCounter: ResearchExecutor, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var verifyCalls = 0
        func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
            if topic.role == .verify { lock.withLock { verifyCalls += 1 } }
            return TopicFindings(id: topic.id, status: .complete, preset: topic.preset, headline: "v",
                                 findings: [], sourcesConsulted: 0, costUSD: 0, duration: .seconds(0),
                                 writeupMarkdown: "", transcript: "", note: nil)
        }
    }

    private func synth(sources: [String]) -> TopicFindings {
        TopicFindings(id: "synthesis-1", status: .complete, preset: .standard, headline: "S",
                      findings: [Finding(claim: "merged", sources: sources, confidence: .high)],
                      sourcesConsulted: sources.count, costUSD: 0, duration: .seconds(0),
                      writeupMarkdown: "Reconciled.", transcript: "", note: nil)
    }

    func testUntraceableCitationIsFlaggedAndFiresGatedCall() async throws {
        let angles = [angle(id: "a1", sources: [["https://real.example"]])]
        let synthesis = synth(sources: ["https://real.example", "https://made-up.example"])
        let exec = VerifyCounter()
        let out = await groundCitations(synthesis, angles: angles,
                                        config: standardRun(project: try makeTempProject(), runCap: 100),
                                        executor: exec, clock: TestClock(now: fixedStart),
                                        ledger: RunLedger(cap: 100))
        XCTAssertEqual(exec.verifyCalls, 1, "a fabricated citation fires exactly one gated repair call")
        XCTAssertTrue(out.writeupMarkdown.contains("Citation check"), "flag surfaced in the note")
        XCTAssertTrue(out.writeupMarkdown.contains("made-up.example"))
        XCTAssertFalse(out.writeupMarkdown.contains("real.example"), "traceable citation is not flagged")
        XCTAssertNotNil(out.note)
    }

    func testAllTraceableCitationsSkipTheGatedCall() async throws {
        let angles = [angle(id: "a1", sources: [["https://real.example", "https://other.example"]])]
        let synthesis = synth(sources: ["https://real.example/"])   // slash-variant still matches
        let exec = VerifyCounter()
        let out = await groundCitations(synthesis, angles: angles,
                                        config: standardRun(project: try makeTempProject(), runCap: 100),
                                        executor: exec, clock: TestClock(now: fixedStart),
                                        ledger: RunLedger(cap: 100))
        XCTAssertEqual(exec.verifyCalls, 0, "clean citations cost nothing extra")
        XCTAssertFalse(out.writeupMarkdown.contains("Citation check"))
    }
}
