import XCTest
@testable import QuorumCore

/// "Sources consulted" means one thing — distinct cited URLs — and every surface reads it from the same
/// place, so the digest, the note's frontmatter and report.json can never disagree about a run.
final class SourceCountTests: XCTestCase {

    private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func findings(_ sources: [[String]]) -> [Finding] {
        sources.enumerated().map { Finding(claim: "claim \($0.offset)", sources: $0.element, confidence: .high) }
    }

    private func topic(_ id: String, headline: String, claims: [[String]], claimed: Int) -> TopicFindings {
        TopicFindings(id: id, status: .complete, preset: .standard, headline: headline,
                      findings: findings(claims), sourcesConsulted: claimed, costUSD: 0, duration: .seconds(1),
                      writeupMarkdown: "Body for \(headline).", transcript: "log \(id)", note: nil)
    }

    func testDistinctSourcesCountsTheSamePageOnce() {
        let counted = Reporter.distinctSources(findings([
            ["https://Example.com/a/", "https://example.com/a"],
            ["http://www.example.com/a", "https://example.com/b"],
            [""],
        ]))
        XCTAssertEqual(counted, 2, "case, scheme, www and a trailing slash are the same page")
    }

    func testAModelsSelfReportedCountNeverReachesTheReport() {
        let entry = entry(from: topic("a1", headline: "Angle", claims: [["https://a.example"], ["https://b.example"]],
                                      claimed: 20),
                          question: "Angle", notePath: nil, noteAction: nil, transcriptPath: nil)
        XCTAssertEqual(entry.sourcesConsulted, 2, "what it cited, not what it says it read")
        XCTAssertEqual(entry.sources?.count, 2)
    }

    func testDigestFrontmatterAndReportAgreeOnOneRun() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let angles = [
            topic("a1", headline: "One", claims: [["https://a.example", "https://shared.example"]], claimed: 20),
            topic("a2", headline: "Two", claims: [["https://b.example", "https://shared.example/"]], claimed: 12),
        ]
        let summary = topic("s", headline: "Answer", claims: [["https://shared.example"]], claimed: 3)

        let entries = persistFanOutRound(synthesis: summary, angleFindings: angles,
                                         angleTitles: ["One", "Two"], question: "Big question",
                                         config: RunSettings(projectURL: project, runSpendCapUSD: 40,
                                                             perTopicSpendCapUSD: 10,
                                                             perTopicTimeout: .seconds(60),
                                                             defaultPreset: .standard),
                                         store: store,
                                         runDir: runDir, priorNotes: [], round: nil, at: fixedStart)

        let synth = try XCTUnwrap(entries.first { $0.isSynthesis == true })
        XCTAssertEqual(synth.sourcesConsulted, 3, "a.example, b.example and shared.example — counted once each")
        XCTAssertEqual(entries.first { $0.question == "One" }?.sourcesConsulted, 2)

        let note = try String(contentsOf: URL(fileURLWithPath: try XCTUnwrap(synth.notePath)), encoding: .utf8)
        XCTAssertTrue(note.contains("sources: 3"), "the note's frontmatter reads the same number")
        XCTAssertTrue(note.contains("3 source(s)"), "and so does its section header")

        let report = RunReport(startedAt: fixedStart, finishedAt: fixedStart, entries: entries,
                               totalCostUSD: 0, runSpendCapUSD: 40)
        let digest = Reporter.renderDigest(report)
        XCTAssertTrue(digest.contains("**Sources consulted:** 2 angles · 3 distinct sources"), digest)
        XCTAssertTrue(digest.contains("**Sources consulted:** 2\n") || digest.contains("**Sources consulted:** 2  "),
                      "an angle reports its own")
    }

    func testAnAngleArtifactHeaderCountsWhatTheAngleCited() throws {
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let res = try store.writeSynthesis(topic("s", headline: "Answer", claims: [[]], claimed: 0),
                                           question: "Q",
                                           angles: [topic("a1", headline: "One",
                                                          claims: [["https://a.example", "https://a.example/"]],
                                                          claimed: 20)],
                                           angleTitles: ["One"], brain: project, priorNotes: [],
                                           runDir: runDir, at: fixedStart)
        let text = try String(contentsOf: try XCTUnwrap(res.angleArtifacts.first), encoding: .utf8)
        XCTAssertTrue(text.contains("1 source(s)"), text)
        XCTAssertFalse(text.contains("20 source(s)"))
    }
}
