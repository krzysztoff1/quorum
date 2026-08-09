import XCTest
@testable import QuorumCore

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

    // MARK: PRD 03 — a claim with no resolved quote is floored, never dropped

    private let paper = SourceDocument(sourceID: "s1", url: "https://real.example", title: "Paper",
                                       contentType: .html, snapshotPath: "sources/s1.md")

    /// One angle that captured a snapshot and resolved one quote in it, plus one it could not find.
    private func citingAngle() -> TopicFindings {
        TopicFindings(id: "a1", status: .complete, preset: .standard, headline: "H",
                      findings: [Finding(claim: "c", sources: ["https://real.example"], confidence: .high,
                                         citationIDs: ["c1"])],
                      sourcesConsulted: 1, costUSD: 0, duration: .seconds(0),
                      writeupMarkdown: "body [^c1]", transcript: "", note: nil,
                      evidence: EvidenceIndex(documents: [paper], citations: [
                        Citation(id: "c1", sourceID: "s1", quote: "q", start: 10, end: 20, match: .exact),
                        Citation(id: "c2", sourceID: "s1", quote: "not in the snapshot", match: .unresolved),
                      ]))
    }

    private func synth(_ findings: [Finding], evidence: EvidenceIndex = EvidenceIndex()) -> TopicFindings {
        TopicFindings(id: "synthesis-1", status: .complete, preset: .standard, headline: "S",
                      findings: findings, sourcesConsulted: 1, costUSD: 0, duration: .seconds(0),
                      writeupMarkdown: "Reconciled.", transcript: "", note: nil, evidence: evidence)
    }

    func testAClaimWithoutAResolvedQuoteIsFlooredToUnverified() async throws {
        let synthesis = synth([
            Finding(claim: "backed by a located quote", sources: ["https://real.example"], confidence: .high, citationIDs: ["c1"]),
            Finding(claim: "quote could not be located", sources: ["https://real.example"], confidence: .high, citationIDs: ["c2"]),
            Finding(claim: "cites an id the run never resolved", sources: ["https://real.example"], confidence: .medium, citationIDs: ["c9"]),
            Finding(claim: "cites nothing at all", sources: ["https://real.example"], confidence: .low, citationIDs: []),
        ])
        let exec = VerifyCounter()
        let out = await groundCitations(synthesis, angles: [citingAngle()],
                                        config: standardRun(project: try makeTempProject(), runCap: 100),
                                        executor: exec, clock: TestClock(now: fixedStart),
                                        ledger: RunLedger(cap: 100))

        XCTAssertEqual(exec.verifyCalls, 0, "every URL is traceable — flooring is free and deterministic")
        XCTAssertEqual(out.findings.map(\.confidence), [.high, .unverified, .unverified, .unverified])
        XCTAssertEqual(out.findings.count, 4, "doubt is surfaced as data — no claim is dropped")
        XCTAssertEqual(out.findings.map(\.citationIDs), [["c1"], ["c2"], ["c9"], []], "markers survive the flooring")
        XCTAssertFalse(out.evidence.isEmpty, "the run's evidence rides along for the reader")
    }

    func testARunThatCapturedNoEvidenceKeepsItsConfidence() async throws {
        // Built-in search (no key) captures no document text — there is nothing to verify a quote against,
        // so the old confidence stands rather than every claim reading as unverified.
        let angle = angle(id: "a1", sources: [["https://real.example"]])
        let synthesis = synth([Finding(claim: "merged", sources: ["https://real.example"], confidence: .high)])
        let out = await groundCitations(synthesis, angles: [angle],
                                        config: standardRun(project: try makeTempProject(), runCap: 100),
                                        executor: VerifyCounter(), clock: TestClock(now: fixedStart),
                                        ledger: RunLedger(cap: 100))
        XCTAssertEqual(out.findings.map(\.confidence), [.high])
    }

    func testARepairedSynthesisIsAlsoFlooredAndKeepsItsEvidence() async throws {
        /// Returns a corrected finding whose quote the run never resolved.
        struct RepairingExecutor: ResearchExecutor {
            func run(_ topic: PreparedTopic, _ ctx: RunContext) async throws -> TopicFindings {
                TopicFindings(id: topic.id, status: .complete, preset: topic.preset, headline: "v",
                              findings: [Finding(claim: "corrected", sources: ["https://real.example"],
                                                 confidence: .high, citationIDs: ["c2"])],
                              sourcesConsulted: 0, costUSD: 0, duration: .seconds(0),
                              writeupMarkdown: "", transcript: "", note: nil)
            }
        }
        let synthesis = synth([Finding(claim: "fabricated", sources: ["https://made-up.example"],
                                       confidence: .high, citationIDs: ["c1"])])
        let out = await groundCitations(synthesis, angles: [citingAngle()],
                                        config: standardRun(project: try makeTempProject(), runCap: 100),
                                        executor: RepairingExecutor(), clock: TestClock(now: fixedStart),
                                        ledger: RunLedger(cap: 100))
        XCTAssertEqual(out.findings.map(\.claim), ["corrected"], "the repair's findings replaced the originals")
        XCTAssertEqual(out.findings.map(\.confidence), [.unverified], "and the repair is held to the same bar")
        XCTAssertEqual(out.evidence.citations.count, 2, "grounding never strips the run's evidence")
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
