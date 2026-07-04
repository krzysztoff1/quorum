import XCTest
@testable import QuorumCore

final class StoreReporterTests: XCTestCase {

    private func sample(_ id: String, status: TopicStatus, findings: [Finding], headline: String,
                        cost: Decimal, note: String? = nil) -> TopicFindings {
        TopicFindings(id: id, status: status, preset: .deep, headline: headline, findings: findings,
                      sourcesConsulted: findings.count * 3, costUSD: cost, duration: .seconds(42),
                      writeupMarkdown: "Body for \(headline).", transcript: "raw transcript", note: note)
    }

    func testWritesDurableNoteWithFrontmatterAndTranscript() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)

        let f = sample("t1", status: .complete, findings: [
            Finding(claim: "The sky is blue", sources: ["https://a.example", "https://b.example"], confidence: .high),
            Finding(claim: "Might rain", sources: [], confidence: .unverified),
        ], headline: "Weather", cost: Decimal(string: "0.20")!)

        let res = try store.write(f, question: "Why is the sky blue?", brain: project,
                                  priorNotes: [], runDir: dir, at: fixedStart)
        XCTAssertEqual(res.action, .created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.note.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: res.transcript.path))
        XCTAssertTrue(res.note.path.contains("/Quorum/notes/"))     // notes live in the brain, not the run dir

        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---"))                            // portable frontmatter
        XCTAssertTrue(text.contains("question: \"Why is the sky blue?\""))
        XCTAssertTrue(text.contains("Weather"))
        XCTAssertTrue(text.contains("The sky is blue"))
        XCTAssertTrue(text.contains("https://a.example"))
        XCTAssertTrue(text.contains("[high]"))
        XCTAssertTrue(text.contains("[unverified]"))
    }

    func testHaltedNoteCarriesIncompleteBanner() throws {
        // A halted topic's partial (built by the supervisor) is filed verbatim, banner intact.
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let f = TopicFindings(id: "h", status: .haltedTime, preset: .draft, headline: "cut off",
                              findings: [], sourcesConsulted: 1, costUSD: 0, duration: .seconds(1),
                              writeupMarkdown: "> ⚠️ **Incomplete** — hit the time wall\n\npartial", transcript: "",
                              note: "hit the time wall")
        let res = try store.write(f, question: "some halted topic", brain: project,
                                  priorNotes: [], runDir: dir, at: fixedStart)
        let text = try String(contentsOf: res.note, encoding: .utf8)
        XCTAssertTrue(text.contains("Incomplete"))
    }

    func testDigestContainsRequiredPerTopicFieldsAndTotals() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let dir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)

        let report = RunReport(
            startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(600),
            entries: [
                RunReport.TopicEntry(id: "t1", question: "How fast is Swift?", status: .complete,
                    preset: .deep, headline: "Fast enough", confidenceSummary: "2 high · 1 unverified",
                    sourcesConsulted: 18, costUSD: Decimal(string: "0.30")!, durationSeconds: 120,
                    note: nil, notePath: "/tmp/x/t1.md", noteAction: .extended, transcriptPath: "/tmp/x/t1.transcript.md"),
                RunReport.TopicEntry(id: "t2", question: "Skipped one", status: .skipped,
                    preset: .standard, headline: "—", confidenceSummary: "—", sourcesConsulted: 0,
                    costUSD: 0, durationSeconds: 0, note: "run time budget reached before this topic ran",
                    notePath: nil, transcriptPath: nil),
            ],
            totalCostUSD: Decimal(string: "0.30")!, runSpendCapUSD: Decimal(string: "5.00")!)

        let briefURL = try store.writeDigest(report, inRunDirectory: dir)
        let brief = try String(contentsOf: briefURL, encoding: .utf8)

        XCTAssertTrue(brief.contains("How fast is Swift?"))
        XCTAssertTrue(brief.contains("Fast enough"))          // headline
        XCTAssertTrue(brief.contains("2 high · 1 unverified")) // confidence
        XCTAssertTrue(brief.contains("18"))                    // sources consulted
        XCTAssertTrue(brief.contains("Deep"))                  // effort preset
        XCTAssertTrue(brief.contains("$0.30"))                 // cost
        XCTAssertTrue(brief.contains("complete"))              // wall status
        XCTAssertTrue(brief.contains("t1.md"))                 // note link
        XCTAssertTrue(brief.contains("extended an existing note")) // how the brain grew (stories 30–32)
        XCTAssertTrue(brief.contains("skipped"))               // skip status shown
        XCTAssertTrue(brief.contains("run time budget reached")) // skip reason shown
        XCTAssertTrue(brief.contains("$0.30 / $5.00"))         // totals vs cap

        // structured report persisted for history reload
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("report.json").path))
    }

    func testRunFolderTitleStampRoundTrip() {
        let stamp = "2026-07-03-114402"
        // Legacy bare-stamp folder: no title, stamp is the whole name.
        XCTAssertNil(RunFolder.title(stamp))
        XCTAssertEqual(RunFolder.stamp(stamp), stamp)
        // Titled folder: title parses back, stamp stays the stable trailing 17 chars.
        let named = RunFolder.name(title: "Best Rust Async Runtimes", stamp: stamp)
        XCTAssertEqual(named, "Best Rust Async Runtimes \(stamp)")
        XCTAssertEqual(RunFolder.title(named), "Best Rust Async Runtimes")
        XCTAssertEqual(RunFolder.stamp(named), stamp)
        // Path-illegal chars are sanitized; an empty title falls back to the bare stamp.
        XCTAssertEqual(RunFolder.name(title: "a/b:c", stamp: stamp), "a b c \(stamp)")
        XCTAssertEqual(RunFolder.name(title: "  ", stamp: stamp), stamp)
    }

    func testListRunsNewestFirst() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        _ = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        _ = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart.addingTimeInterval(3600))
        let runs = store.listRuns(projectURL: project)
        XCTAssertEqual(runs.count, 2)
        XCTAssertGreaterThan(runs[0].lastPathComponent, runs[1].lastPathComponent) // newest first
    }

    func testMarkdownFilesUnderSkipsHiddenAndDependencyDirs() throws {
        let project = try makeTempProject()
        let fm = FileManager.default
        func put(_ rel: String) throws {
            let url = project.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content".write(to: url, atomically: true, encoding: .utf8)
        }
        try put("README.md")
        try put("docs/setup.md")
        try put("Quorum/notes/topic.md")
        try put("notes.txt")                       // not markdown → excluded
        try put(".hidden/secret.md")               // hidden dir → excluded
        try put("node_modules/pkg/readme.md")      // dependency dump → excluded
        try put("Quorum/runs/x-abc123.transcript.md")  // raw run log → excluded

        let found = DiskFindingsStore.markdownFiles(under: project).map(\.lastPathComponent)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.contains("README.md"))
        XCTAssertTrue(found.contains("setup.md"))
        XCTAssertTrue(found.contains("topic.md"))
        XCTAssertFalse(found.contains("secret.md"))
        XCTAssertFalse(found.contains("readme.md"))
        XCTAssertFalse(found.contains("notes.txt"))
        XCTAssertFalse(found.contains("x-abc123.transcript.md"))
    }

    func testNoteTreeMirrorsFolderStructureDirsFirst() throws {
        let project = try makeTempProject()
        let fm = FileManager.default
        func put(_ rel: String) throws {
            let url = project.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content".write(to: url, atomically: true, encoding: .utf8)
        }
        try put("README.md")
        try put("docs/setup.md")
        try put("docs/guide/intro.md")
        try put("Quorum/notes/topic.md")
        try put("Quorum/runs/only-a.transcript.md")   // transcript-only dir → pruned from the tree

        let tree = DiskFindingsStore.noteTree(under: project)
        // Top level: directories first (alpha, case-insensitive), then files.
        XCTAssertEqual(tree.map(\.name), ["docs", "Quorum", "README.md"])
        XCTAssertEqual(tree.map(\.isDirectory), [true, true, false])

        let docs = try XCTUnwrap(tree.first { $0.name == "docs" })
        XCTAssertEqual(docs.children.map(\.name), ["guide", "setup.md"])   // subdir before file
        let guide = try XCTUnwrap(docs.children.first { $0.name == "guide" })
        XCTAssertEqual(guide.children.map(\.name), ["intro.md"])
        XCTAssertNil(guide.children[0].childrenOrNil)                      // leaf → no disclosure triangle

        // The runs/ folder held only a transcript, so it's gone; Quorum keeps just notes/.
        let quorum = try XCTUnwrap(tree.first { $0.name == "Quorum" })
        XCTAssertEqual(quorum.children.map(\.name), ["notes"])
    }

    func testConfidenceSummary() {
        XCTAssertEqual(Reporter.confidenceSummary([]), "no verified findings")
        let summary = Reporter.confidenceSummary([
            Finding(claim: "a", sources: [], confidence: .high),
            Finding(claim: "b", sources: [], confidence: .high),
            Finding(claim: "c", sources: [], confidence: .unverified),
        ])
        XCTAssertEqual(summary, "2 high · 1 unverified")
    }
}
