import XCTest
@testable import QuorumCore

/// The small things that make an exported note read as a document rather than a dump: a title you can see
/// in a file list, each open question stated once, and a conflict attributed to whoever actually disagreed.
final class NotePolishTests: XCTestCase {

    private let fixedStart = Date(timeIntervalSince1970: 1_700_000_000)
    private let store = DiskFindingsStore()

    private func makeTempProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func findings(headline: String, writeup: String, conflicts: [Conflict] = [],
                          gaps: [String] = []) -> TopicFindings {
        TopicFindings(id: "t1", status: .complete, preset: .standard, headline: headline,
                      findings: [], conflicts: conflicts, gaps: gaps, sourcesConsulted: 0, costUSD: 0,
                      duration: .seconds(1), writeupMarkdown: writeup, transcript: "", note: nil)
    }

    // MARK: title vs headline

    func testFrontmatterTitleIsTheTopicAndTheHeadlineHasItsOwnKey() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let headline = String(repeating: "a long one-line takeaway that keeps going ", count: 6)
        let question = "How do modern food delivery platforms build real-time personalization systems "
                     + "across recommendation, pricing and search surfaces"
        let res = try store.write(findings(headline: headline, writeup: "Body."), question: question,
                                  brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)

        let fields = DiskFindingsStore.splitFrontmatter(try String(contentsOf: res.note, encoding: .utf8)).fields
        XCTAssertEqual(fields["title"], RunTitle.fromQuestion(question))
        XCTAssertLessThanOrEqual(try XCTUnwrap(fields["title"]).count, 60)
        XCTAssertEqual(fields["headline"], headline.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(fields["question"], question, "the full question is still kept")
    }

    func testExtendingANoteKeepsItsTitleAndRefreshesTheHeadline() throws {
        let brain = try makeTempProject()
        let runDir = try store.makeRunDirectory(projectURL: brain, startedAt: fixedStart)
        let question = "Do cold starts fall on Kubernetes with a warm pool"
        _ = try store.write(findings(headline: "First take", writeup: "One."), question: question,
                            brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)
        let again = try store.write(findings(headline: "Second take", writeup: "Two."), question: question,
                                    brain: brain, priorNotes: [], runDir: runDir, at: fixedStart)

        let fields = DiskFindingsStore.splitFrontmatter(try String(contentsOf: again.note, encoding: .utf8)).fields
        XCTAssertEqual(again.action, .extended)
        XCTAssertEqual(fields["title"], RunTitle.fromQuestion(question), "lineage: the topic doesn't drift")
        XCTAssertEqual(fields["headline"], "Second take", "but the current answer's one-liner does")
    }

    // MARK: gaps stated once

    func testAGapTheWriteupAlreadyStatesIsNotRepeatedUnderItsOwnHeading() {
        let section = DiskFindingsStore.renderSection(
            findings(headline: "H",
                     writeup: "## Konflikty i luki\n\n- Brak danych o rynku PL\n- Nieznany horyzont",
                     gaps: ["Brak danych o rynku PL", "Jak wygląda zwrot z inwestycji"]),
            date: fixedStart, relatedLinks: [], sources: 0)

        XCTAssertEqual(section.components(separatedBy: "Brak danych o rynku PL").count - 1, 1,
                       "the writeup already said it")
        XCTAssertTrue(section.contains("- Jak wygląda zwrot z inwestycji"), "the one it didn't say is added")
    }

    func testTheGapsHeadingIsDroppedWhenTheWriteupCoveredThemAll() {
        let section = DiskFindingsStore.renderSection(
            findings(headline: "H", writeup: "Body.\n\n- Only open question", gaps: ["Only open question"]),
            date: fixedStart, relatedLinks: [], sources: 0)
        XCTAssertFalse(section.contains("### Gaps & open questions"))
    }

    // MARK: who actually disagreed

    func testAConflictBetweenAnAnglesOwnSourcesSaysSo() {
        let conflict = Conflict(claim: "Grocery lift", positions: ["angle 2: McKinsey says 1–2%",
                                                                   "Angle 2 — vendors say 30%"])
        XCTAssertEqual(Reporter.conflictAttribution(conflict), "sources within Angle 2 disagree")
    }

    func testAConflictAcrossAnglesStillReadsAsTheAnglesDisagreeing() {
        let conflict = Conflict(claim: "Grocery lift", positions: ["angle 1: says X", "angle 3: says Y"])
        XCTAssertEqual(Reporter.conflictAttribution(conflict), "the angles disagree")
    }

    func testAnUnattributedConflictClaimsNothingAboutWho() {
        let conflict = Conflict(claim: "Grocery lift", positions: ["McKinsey says 1–2%", "vendors say 30%"])
        XCTAssertEqual(Reporter.conflictAttribution(conflict), "sources disagree")
    }

    func testTheNoteAttributesEachConflictRatherThanBlamingTheAngles() {
        let section = DiskFindingsStore.renderSection(
            findings(headline: "H", writeup: "Body.",
                     conflicts: [Conflict(claim: "Grocery lift",
                                          positions: ["angle 2: McKinsey 1–2%", "angle 2: vendors 30%"])]),
            date: fixedStart, relatedLinks: [], sources: 0)

        XCTAssertTrue(section.contains("sources within Angle 2 disagree"), section)
        XCTAssertFalse(section.contains("the angles disagreed"))
    }

    func testAnAngleArtifactFromATranscriptWithBothLeaksHasOneH1AndNoNarration() throws {
        let final = """
        I have enough depth now (~13 sources fetched/searched with substantive content). Let me write the final report.

        # Personalization ROI & Monetization in Food Tech

        ## Measurable business outcomes

        Delivery Hero reported an 85% jump in conversions.[^c1]

        ```json
        {"headline":"Personalization drives 5-15% revenue lift","status":"complete","findings":[{"claim":"85% jump","sources":["https://www.braze.com/customers/delivery-hero"],"confidence":"medium","citations":["c1"]}]}
        ```
        """
        let parsed = ResearchOutputParser.parseFinal(final)
        let angle = TopicFindings(id: "a2", status: .complete, preset: .standard, headline: parsed.headline,
                                  findings: parsed.findings, sourcesConsulted: 1, costUSD: 0,
                                  duration: .seconds(1), writeupMarkdown: parsed.writeup, transcript: "",
                                  note: nil)
        let summary = TopicFindings(id: "s", status: .complete, preset: .standard, headline: "Answer",
                                    findings: [], sourcesConsulted: 0, costUSD: 0, duration: .seconds(1),
                                    writeupMarkdown: "Answer.", transcript: "", note: nil)
        let project = try makeTempProject()
        let store = DiskFindingsStore()
        let runDir = try store.makeRunDirectory(projectURL: project, startedAt: fixedStart)
        let written = try store.writeSynthesis(summary, question: "Q", angles: [angle], angleTitles: ["ROI"],
                                               brain: project, priorNotes: [], runDir: runDir, at: fixedStart)
        let artifact = try String(contentsOf: try XCTUnwrap(written.angleArtifacts.first), encoding: .utf8)
        let h1s = artifact.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        XCTAssertEqual(h1s.count, 1, artifact)
        XCTAssertTrue(h1s[0].hasPrefix("# Angle 1:"))
        XCTAssertFalse(artifact.contains("Let me write the final report"), artifact)
        XCTAssertTrue(artifact.contains("## Personalization ROI & Monetization in Food Tech"))
    }
}
