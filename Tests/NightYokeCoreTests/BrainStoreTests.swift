import XCTest
@testable import NightYokeCore

/// The moat (stories 30–32): given a brain with notes, a near-duplicate topic *extends* the existing
/// note (dated section, wikilink, one file) rather than duplicating; an unrelated topic creates a new
/// note; the "already researched" match is detected. All against a temp brain dir — no network, no spend.
final class BrainStoreTests: XCTestCase {

    private let store = DiskFindingsStore()

    /// File a note into the brain and return its URL (seeds the brain for a test).
    @discardableResult
    private func seed(_ question: String, headline: String, id: String,
                      into brain: URL, runDir: URL, priorNotes: [URL] = []) throws -> URL {
        let f = TopicFindings(
            id: id, status: .complete, preset: .standard, headline: headline,
            findings: [Finding(claim: "A verified claim", sources: ["https://src.example"], confidence: .high)],
            sourcesConsulted: 5, costUSD: Decimal(string: "0.10")!, duration: .seconds(1),
            writeupMarkdown: "Body about \(headline).", transcript: "log", note: nil)
        return try store.write(f, question: question, brain: brain, priorNotes: priorNotes,
                               runDir: runDir, at: fixedStart).note
    }

    private func notes(in brain: URL) throws -> [URL] {
        let dir = brain.appendingPathComponent("NightYoke/notes")
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    func testUnrelatedTopicCreatesANewNote() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift concurrency", id: "s1",
                 into: brain, runDir: runDir)

        let f = TopicFindings(id: "s2", status: .complete, preset: .standard, headline: "Espresso",
                              findings: [], sourcesConsulted: 3, costUSD: 0, duration: .seconds(1),
                              writeupMarkdown: "beans", transcript: "", note: nil)
        let res = try store.write(f, question: "Best espresso machines under 500 dollars", brain: brain,
                                  priorNotes: [], runDir: runDir, at: fixedStart)

        XCTAssertEqual(res.action, .created)
        XCTAssertEqual(try notes(in: brain).count, 2, "unrelated topic → a second note")
    }

    func testNearDuplicateExtendsTheExistingNote() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let seeded = try seed("Swift structured concurrency model internals", headline: "Swift concurrency",
                              id: "s1", into: brain, runDir: runDir)

        let f = TopicFindings(id: "s2", status: .complete, preset: .deep, headline: "Concurrency, deeper",
                              findings: [Finding(claim: "New detail", sources: ["https://n.example"], confidence: .high)],
                              sourcesConsulted: 9, costUSD: Decimal(string: "0.20")!, duration: .seconds(2),
                              writeupMarkdown: "More on the model.", transcript: "", note: nil)
        let res = try store.write(f, question: "Swift structured concurrency performance and internals",
                                  brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)

        XCTAssertEqual(res.action, .extended)
        XCTAssertEqual(res.note.resolvingSymlinksInPath(), seeded.resolvingSymlinksInPath(), "extended the SAME file")
        XCTAssertEqual(try notes(in: brain).count, 1, "the topic deepened into ONE note, not two")

        let text = try String(contentsOf: seeded, encoding: .utf8)
        let datedSections = text.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }
        XCTAssertEqual(datedSections.count, 2, "two dated sections")
        XCTAssertTrue(text.contains("runs: 2"))
        XCTAssertTrue(text.contains("New detail"))     // the new run's finding landed
    }

    func testExistingNoteDetectsAlreadyResearched() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Rust memory safety guarantees", headline: "Rust safety", id: "r1", into: brain, runDir: runDir)

        XCTAssertNotNil(store.existingNote(matching: "Rust memory safety in practice", in: brain),
                        "a close topic is flagged as already researched")
        XCTAssertNil(store.existingNote(matching: "Python packaging tools", in: brain),
                     "an unrelated topic is not")
    }

    func testRelatedNotesReturnsContextEvenBelowExtendThreshold() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        try seed("Swift structured concurrency model", headline: "Swift concurrency", id: "r1",
                 into: brain, runDir: runDir)

        // Shares one keyword ("swift") — related context, but not the same topic (won't extend).
        let related = store.relatedNotes(to: "Swift compile times", in: brain)
        XCTAssertEqual(related.count, 1)
        XCTAssertNil(store.existingNote(matching: "Swift compile times", in: brain))
    }

    func testNewNoteLinksToPriorNotesAsWikilinks() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let prior = try seed("Docker networking basics", headline: "Docker networking", id: "d1",
                             into: brain, runDir: runDir)

        // Unrelated topic (so it's created), but handed the prior note as related context → wikilink.
        let f = TopicFindings(id: "d2", status: .complete, preset: .standard, headline: "Terraform state",
                              findings: [], sourcesConsulted: 4, costUSD: 0, duration: .seconds(1),
                              writeupMarkdown: "state backends", transcript: "", note: nil)
        let res = try store.write(f, question: "Terraform remote state management", brain: brain,
                                  priorNotes: [prior], runDir: runDir, at: fixedStart)

        XCTAssertEqual(res.action, .created)
        let text = try String(contentsOf: res.note, encoding: .utf8)
        let priorSlug = prior.deletingPathExtension().lastPathComponent
        XCTAssertTrue(text.contains("[[\(priorSlug)]]"), "portable wikilink to the related note")
    }
}
