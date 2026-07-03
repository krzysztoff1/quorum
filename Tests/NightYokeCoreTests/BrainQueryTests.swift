import XCTest
@testable import NightYokeCore

/// "Ask your brain" (story 40): the matcher pre-selects the relevant notes and the prompt is assembled
/// notes-first, web-only-for-the-gap. Pure logic against a temp brain — no network, no spend.
final class BrainQueryTests: XCTestCase {
    private let store = DiskFindingsStore()

    private func seed(_ question: String, headline: String, id: String, into brain: URL, runDir: URL) throws {
        let f = TopicFindings(
            id: id, status: .complete, preset: .standard, headline: headline,
            findings: [Finding(claim: "A verified claim", sources: ["https://src.example"], confidence: .high)],
            sourcesConsulted: 5, costUSD: Decimal(string: "0.10")!, duration: .seconds(1),
            writeupMarkdown: "Body about \(headline).", transcript: "log", note: nil)
        _ = try store.write(f, question: question, brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)
    }

    func testBuildPicksMatchingNoteAndAssemblesNotesFirstPrompt() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1", into: brain, runDir: runDir)

        let bq = BrainQuery.build(question: "What do I know about Swift concurrency?", brain: brain, store: store)

        XCTAssertEqual(bq.notes.count, 1, "the matcher pre-selected the related note")
        XCTAssertEqual(bq.notes.first?.title, "Swift Concurrency", "title read from the note's frontmatter")
        XCTAssertFalse(bq.notes.first?.excerpt.isEmpty ?? true, "the excerpt is embedded for the prompt")
        // The prompt embeds the note and instructs notes-first / web-only-for-the-gap.
        XCTAssertTrue(bq.prompt.contains("QUESTION:"))
        XCTAssertTrue(bq.prompt.contains("Swift Concurrency"))
        XCTAssertTrue(bq.prompt.contains("Body about Swift Concurrency"), "the note body is in the prompt")
        XCTAssertTrue(bq.prompt.contains("ONLY to fill"), "web is the fallback, not the default")
    }

    func testEmptyBrainFallsBackToWebPrompt() throws {
        let brain = try makeTempProject()
        let bq = BrainQuery.build(question: "Best espresso machines under 500 dollars", brain: brain, store: store)

        XCTAssertTrue(bq.notes.isEmpty, "nothing in the brain matches")
        XCTAssertTrue(bq.prompt.contains("NO notes matching"), "the prompt tells the agent the brain is empty here")
        XCTAssertTrue(bq.prompt.contains("Explore every angle"), "and suggests capturing it")
    }

    func testBudgetBoundsEmbeddedNoteText() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift Concurrency", id: "s1", into: brain, runDir: runDir)

        // Under a tiny budget the excerpt is dropped (note still listed), so the prompt can't balloon.
        let bq = BrainQuery.build(question: "Swift concurrency", brain: brain, store: store, budget: 50)
        XCTAssertEqual(bq.notes.count, 1)
        XCTAssertEqual(bq.notes.first?.excerpt, "")
        XCTAssertTrue(bq.prompt.contains("excerpt omitted"))
    }

    func testEmptyQuestionMatchesNothing() {
        let brain = URL(fileURLWithPath: NSTemporaryDirectory())
        let bq = BrainQuery.build(question: "   ", brain: brain, store: store)
        XCTAssertTrue(bq.notes.isEmpty)
        XCTAssertTrue(bq.prompt.contains("NO notes matching"))
    }
}
