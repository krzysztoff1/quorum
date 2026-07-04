import XCTest
@testable import QuorumCore

/// Brain health check: the per-run conflict/gap logic lifted to the whole brain. `build` embeds every
/// note under a budget and finds missing `[[wikilink]]` connections deterministically; `BrainLintReport`
/// parses the model's ```json findings forgivingly. Pure logic against a temp brain — no network, no spend.
final class BrainLintTests: XCTestCase {
    private let store = DiskFindingsStore()

    @discardableResult
    private func seed(_ question: String, headline: String, id: String, into brain: URL,
                      runDir: URL, priorNotes: [URL] = []) throws -> URL {
        let f = TopicFindings(
            id: id, status: .complete, preset: .standard, headline: headline,
            findings: [Finding(claim: "A verified claim", sources: ["https://src.example"], confidence: .high)],
            sourcesConsulted: 5, costUSD: Decimal(string: "0.10")!, duration: .seconds(1),
            writeupMarkdown: "Body about \(headline).", transcript: "log", note: nil)
        return try store.write(f, question: question, brain: brain, priorNotes: priorNotes,
                               runDir: runDir, at: fixedStart).note
    }

    func testBuildEmbedsEveryNoteAndDropsExcerptUnderTinyBudget() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1", into: brain, runDir: runDir)
        try seed("Best espresso machines under 500 dollars", headline: "Espresso", id: "e1", into: brain, runDir: runDir)

        let lint = BrainLint.build(brain: brain, store: store)
        XCTAssertEqual(lint.notes.count, 2, "every note is listed")
        XCTAssertTrue(lint.prompt.contains(BrainLint.auditMarker), "the prompt carries the marker the dry-run demo detects")
        XCTAssertTrue(lint.prompt.contains("Swift Concurrency"))
        XCTAssertTrue(lint.prompt.contains("Espresso"))
        XCTAssertTrue(lint.notes.contains { !$0.excerpt.isEmpty }, "excerpts are embedded under a normal budget")

        // Under a tiny budget the excerpts are dropped (notes still listed), so the prompt can't balloon.
        let tiny = BrainLint.build(brain: brain, store: store, budget: 50)
        XCTAssertEqual(tiny.notes.count, 2)
        XCTAssertTrue(tiny.notes.allSatisfy { $0.excerpt.isEmpty })
        XCTAssertTrue(tiny.prompt.contains("excerpt omitted"))
    }

    func testConnectionFinderSurfacesRelatedUnlinkedPair() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1", into: brain, runDir: runDir)
        try seed("Swift concurrency actors and tasks", headline: "Actors", id: "a1", into: brain, runDir: runDir)

        let lint = BrainLint.build(brain: brain, store: store)
        XCTAssertEqual(lint.unlinkedCandidates.count, 1, "two overlapping, cross-unlinked notes → one candidate")
        let c = try XCTUnwrap(lint.unlinkedCandidates.first)
        XCTAssertEqual(Set([c.fromTitle, c.toTitle]), ["Swift Concurrency", "Actors"])
        XCTAssertEqual(c.id, "\(c.fromSlug)→\(c.toSlug)")
    }

    func testConnectionFinderSkipsAlreadyLinkedPair() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let actors = try seed("Swift concurrency actors and tasks", headline: "Actors", id: "a1", into: brain, runDir: runDir)
        // The second note is written WITH a related link to the first → its body carries [[<actors slug>]].
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1",
                 into: brain, runDir: runDir, priorNotes: [actors])

        let lint = BrainLint.build(brain: brain, store: store)
        XCTAssertTrue(lint.unlinkedCandidates.isEmpty, "an existing [[wikilink]] between them suppresses the candidate")
    }

    func testConnectionFinderIgnoresUnrelatedNotes() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1", into: brain, runDir: runDir)
        try seed("Best espresso machines under 500 dollars", headline: "Espresso", id: "e1", into: brain, runDir: runDir)

        let lint = BrainLint.build(brain: brain, store: store)
        XCTAssertTrue(lint.unlinkedCandidates.isEmpty, "no shared keywords → no candidate")
    }

    func testEmptyBrainProducesNothingToAuditPrompt() throws {
        let brain = try makeTempProject()
        let lint = BrainLint.build(brain: brain, store: store)
        XCTAssertTrue(lint.notes.isEmpty)
        XCTAssertTrue(lint.unlinkedCandidates.isEmpty)
        XCTAssertTrue(lint.prompt.contains("nothing to audit"), "the empty-brain branch says so plainly")
    }

    func testReportParsePopulatesFindings() {
        let text = """
        Here's what I found across your notes.

        ```json
        {
          "inconsistencies": [
            {"claim": "Timeout default disagrees", "notes": ["Onboarding", "Perf"], "detail": "20s vs 60s"}
          ],
          "gaps": ["What happens offline?", "  "],
          "questions": ["Could search and feed share a cache?"]
        }
        ```
        """
        let r = BrainLintReport.parse(text)
        XCTAssertEqual(r.inconsistencies.count, 1)
        XCTAssertEqual(r.inconsistencies.first?.notes, ["Onboarding", "Perf"])
        XCTAssertEqual(r.inconsistencies.first?.detail, "20s vs 60s")
        XCTAssertEqual(r.gaps, ["What happens offline?"], "blank entries are dropped")
        XCTAssertEqual(r.questions, ["Could search and feed share a cache?"])
    }

    func testReportParseForgivesGarbage() {
        XCTAssertEqual(BrainLintReport.parse("no json at all here"),
                       BrainLintReport(inconsistencies: [], gaps: [], questions: []))
        XCTAssertEqual(BrainLintReport.parse("```json\n{not valid json}\n```"),
                       BrainLintReport(inconsistencies: [], gaps: [], questions: []))
    }
}
