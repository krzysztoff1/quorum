import XCTest
@testable import QuorumCore

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
        let dir = brain.appendingPathComponent("Quorum/notes")
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
        XCTAssertTrue(text.contains("More on the model."))     // the new run's writeup landed
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

    // MARK: reconciliation — the reconciled-write assembly, tested as pure string logic (no executor)

    func testReconciliationCollapsesDiveRoundsAndPreservesPriorDives() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        // A prior dive's dated section — immutable history that must survive the reconciliation.
        let note = try seed("How does X work?", headline: "PRIORDIVE", id: "p1", into: brain, runDir: runDir)
        let preDiveBody = try XCTUnwrap(store.noteBody(matching: "How does X work?", in: brain),
                                        "the pre-dive snapshot captures the prior dive's body")

        // This dive then appended two per-round sections (rounds 1 & 2)…
        for i in 1...2 {
            let f = TopicFindings(id: "r\(i)", status: .complete, preset: .standard, headline: "Round \(i)",
                                  findings: [], sourcesConsulted: 1, costUSD: 0, duration: .seconds(1),
                                  writeupMarkdown: "ROUND\(i)BODY", transcript: "", note: nil)
            _ = try store.write(f, question: "How does X work?", brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)
        }
        // …now reconciliation collapses THIS dive's rounds into one section on top of the pre-dive body.
        let reconciled = TopicFindings(id: "rec", status: .complete, preset: .deep, headline: "Reconciled X",
                                       findings: [Finding(claim: "CURRENTANSWER", sources: ["https://s.example"], confidence: .high)],
                                       conflicts: [Conflict(claim: "STILLOPEN", positions: ["a", "b"])], gaps: [],
                                       sourcesConsulted: 7, costUSD: Decimal(string: "0.30")!, duration: .seconds(2),
                                       writeupMarkdown: "CURRENTANSWER bottom line", transcript: "log", note: nil)
        let res = try store.writeReconciliation(reconciled, question: "How does X work?", relatedLinks: [],
                                                brain: brain, runDir: runDir, preDiveBody: preDiveBody, at: fixedStart)

        XCTAssertEqual(res.action, .reconciled)
        XCTAssertEqual(res.note.resolvingSymlinksInPath(), note.resolvingSymlinksInPath(), "wrote the SAME note file")

        let text = try String(contentsOf: note, encoding: .utf8)
        let dated = text.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }
        XCTAssertEqual(dated.count, 2, "prior dive's section + ONE reconciled section — the dive's two rounds collapsed")
        XCTAssertTrue(text.contains("PRIORDIVE"), "prior dive preserved above the reconciled answer")
        XCTAssertTrue(text.contains("CURRENTANSWER"), "current answer survives in the reconciled body")
        XCTAssertFalse(text.contains("ROUND1BODY") || text.contains("ROUND2BODY"), "the dive's per-round sections are gone")
        XCTAssertFalse(text.contains("### Open conflicts"), "reconciled notes should not add conflict scaffolding")
        XCTAssertFalse(text.contains("### Open questions"), "reconciled notes should not add question scaffolding")
        XCTAssertEqual(text.components(separatedBy: "_Effort:").count - 1, 1,
                       "reconciliation should not add a second run-log metadata block")
    }

    func testNoteSectionIsProseWithCalloutsNotAFindingsDump() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let f = TopicFindings(
            id: "s9", status: .complete, preset: .standard, headline: "Answer",
            findings: [Finding(claim: "A claim the prose already states", sources: ["https://cited.example/paper"], confidence: .high)],
            conflicts: [Conflict(claim: "DISPUTED", positions: ["angle 1: X", "angle 2: Y"])],
            gaps: ["What about Z?"],
            sourcesConsulted: 5, costUSD: 0, duration: .seconds(1),
            writeupMarkdown: "PROSEBODY with the claim cited inline.", transcript: "", note: nil)
        let res = try store.write(f, question: "A question about prose notes", brain: brain,
                                  priorNotes: [], runDir: runDir, at: fixedStart)

        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertTrue(text.contains("PROSEBODY"))
        XCTAssertTrue(text.contains("Open conflicts"), "disagreement stays visible on the note")
        XCTAssertTrue(text.contains("What about Z?"), "open questions stay on the note — they drive follow-ups")
        XCTAssertFalse(text.contains("### Findings"),
                       "the note is the answer — the structured findings dump lives in report.json, not stacked under the prose")
        XCTAssertFalse(text.contains("- **[high]**"), "no per-claim restatement below the cited prose")
    }

    func testReconciliationOnAFreshTopicIsExactlyOneSection() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let reconciled = TopicFindings(id: "rec", status: .complete, preset: .standard, headline: "Answer",
                                       findings: [Finding(claim: "CURRENTANSWER", sources: [], confidence: .high)],
                                       sourcesConsulted: 3, costUSD: 0, duration: .seconds(1),
                                       writeupMarkdown: "CURRENTANSWER", transcript: "", note: nil)
        let res = try store.writeReconciliation(reconciled, question: "Brand new topic", relatedLinks: [],
                                                brain: brain, runDir: runDir, preDiveBody: nil, at: fixedStart)

        XCTAssertEqual(res.action, .reconciled)
        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("## ") && $0.contains("—") }.count, 1,
                       "no prior body → exactly one reconciled section")
        XCTAssertTrue(text.contains("runs: 1"), "a fresh reconciled note starts its lineage at one")
        XCTAssertTrue(text.contains("CURRENTANSWER"))
        XCTAssertFalse(text.contains("### Open conflicts"))
        XCTAssertFalse(text.contains("### Open questions"))
        XCTAssertFalse(text.contains("_Effort:"), "a fresh reconciled note should not expose run-log metadata")
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

    // MARK: PRD 03 — the note stays a portable document whose footnotes render in Obsidian

    private func cited(_ writeup: String, headline: String = "Cited answer") -> TopicFindings {
        TopicFindings(
            id: "e1", status: .complete, preset: .standard, headline: headline,
            findings: [Finding(claim: "A cited claim", sources: ["https://nature.com/x"], confidence: .high,
                               citationIDs: ["c1"])],
            sourcesConsulted: 2, costUSD: 0, duration: .seconds(1),
            writeupMarkdown: writeup, transcript: "", note: nil,
            evidence: EvidenceIndex(
                documents: [SourceDocument(sourceID: "s1", url: "https://nature.com/x", title: "Nature",
                                           contentType: .pdf, snapshotPath: "sources/s1.md")],
                citations: [Citation(id: "c1", sourceID: "s1", quote: "latency fell 40%",
                                     start: 10, end: 26, match: .exact, page: 4)]))
    }

    func testNoteAppendsFootnoteDefinitionsUnderASourcesHeading() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let res = try store.write(cited("Cold starts fell 40% [^c1]."), question: "Do cold starts fall?",
                                  brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)

        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertTrue(text.contains("Cold starts fell 40% [^c1]."), "the marker stays in the prose")
        XCTAssertTrue(text.contains("## Sources"))
        XCTAssertTrue(text.contains("[^c1]: [Nature](https://nature.com/x) — p. 4 — “latency fell 40%”"),
                      "a standard markdown footnote definition, so Obsidian renders it with no Quorum involved")
    }

    func testWriteupThatAlreadyHasASourcesHeadingGetsNoSecondOne() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let res = try store.write(cited("Claim [^c1].\n\n## Sources\n\n1. nature.com"),
                                  question: "Heading already there", brain: brain, priorNotes: [],
                                  runDir: runDir, at: fixedStart)

        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "## Sources").count - 1, 1, "the model's own heading is reused")
        XCTAssertTrue(text.contains("[^c1]: "))
    }

    func testALegacyOrUnresolvableWriteupGetsNoSourcesSection() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let plain = try store.write(cited("No markers in this body."), question: "Legacy shape",
                                    brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)
        XCTAssertFalse(try String(contentsOf: plain.note, encoding: .utf8).contains("## Sources"))

        let ghost = TopicFindings(id: "g1", status: .complete, preset: .standard, headline: "Ghost",
                                  findings: [], sourcesConsulted: 0, costUSD: 0, duration: .seconds(1),
                                  writeupMarkdown: "Claim [^zz9].", transcript: "", note: nil)
        let res = try store.write(ghost, question: "A wholly different question", brain: brain,
                                  priorNotes: [], runDir: runDir, at: fixedStart)
        XCTAssertFalse(try String(contentsOf: res.note, encoding: .utf8).contains("## Sources"),
                       "a marker the run never resolved gets no fabricated footnote")
    }

    func testExtendingAndReconcilingKeepFootnotesWithTheirSection() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let question = "Do cold starts fall on Kubernetes?"
        _ = try seed(question, headline: "Cold starts", id: "p1", into: brain, runDir: runDir)

        let extended = try store.write(cited("Round two says 40% [^c1]."), question: question, brain: brain,
                                       priorNotes: [], runDir: runDir, at: fixedStart)
        XCTAssertEqual(extended.action, .extended, "footnotes must not disturb the extend/create decision")
        let extendedText = try String(contentsOf: extended.note, encoding: .utf8)
        XCTAssertTrue(extendedText.hasPrefix("---"), "frontmatter survives")
        XCTAssertTrue(extendedText.contains("runs: 2"))
        XCTAssertTrue(extendedText.contains("[^c1]: [Nature]"))

        let rec = try store.writeReconciliation(cited("One current answer [^c1]."), question: question,
                                                relatedLinks: [], brain: brain, runDir: runDir,
                                                preDiveBody: "PRIORBODY", at: fixedStart)
        XCTAssertEqual(rec.action, .reconciled)
        let recText = try String(contentsOf: rec.note, encoding: .utf8)
        XCTAssertTrue(recText.contains("PRIORBODY"))
        XCTAssertTrue(recText.contains("[^c1]: [Nature]"), "a reconciled note is portable too")
    }

    func testAngleArtifactsCarryTheirOwnFootnotes() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let res = try store.writeSynthesis(cited("Synthesis [^c1]."), question: "Fan-out question",
                                          angles: [cited("Angle one says 40% [^c1].", headline: "Angle")],
                                          angleTitles: ["Latency"], brain: brain, priorNotes: [],
                                          runDir: runDir, at: fixedStart)
        let artifact = try XCTUnwrap(res.angleArtifacts.first)
        let text = try String(contentsOf: artifact, encoding: .utf8)
        XCTAssertTrue(text.contains("Angle one says 40% [^c1]."))
        XCTAssertTrue(text.contains("[^c1]: [Nature]"), "an angle writeup opens as a valid cited document too")
    }

    func testWikilinkSlugsExtractsReferencedNotesDeduped() {
        let body = """
        See [[agent-frameworks]] and [[docker-networking]].
        Alias form [[terraform-state|Terraform state]] and heading [[swift-concurrency#tasks]].
        Repeat [[agent-frameworks]] should dedupe.
        """
        XCTAssertEqual(DiskFindingsStore.wikilinkSlugs(in: body),
                       ["agent-frameworks", "docker-networking", "terraform-state", "swift-concurrency"])
    }

    func testNestedNotesAreVisibleToMatchingAndBodyLookups() throws {
        let brain = try makeTempProject()
        let nested = brain.appendingPathComponent("Quorum/notes/research/swift-concurrency.md")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        ---
        title: "Swift Concurrency"
        question: "Swift structured concurrency model"
        created: 2026-07-04
        updated: 2026-07-04
        runs: 1
        preset: standard
        sources: 3
        confidence: "high"
        cost: $0.10
        ---
        Body about nested notes.
        """.write(to: nested, atomically: true, encoding: .utf8)

        let canonicalNested = nested.resolvingSymlinksInPath().path
        XCTAssertEqual(store.allNotes(in: brain).map { $0.resolvingSymlinksInPath().path }, [canonicalNested],
                       "nested markdown notes should be discovered")
        XCTAssertNotNil(store.existingNote(matching: "Swift concurrency in practice", in: brain),
                        "nested notes should still match questions")
        XCTAssertEqual(store.noteBody(matching: "Swift concurrency in practice", in: brain)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "Body about nested notes.")

        let related = store.relatedNotes(to: "Swift concurrency", in: brain)
        XCTAssertEqual(related.map { $0.resolvingSymlinksInPath().path }, [canonicalNested],
                       "nested notes should be eligible as prior context")
    }
}
