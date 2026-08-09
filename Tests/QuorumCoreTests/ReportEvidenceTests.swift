import XCTest
@testable import QuorumCore

/// A finished run's evidence, read the way the rail reads it: one node at a time. Opening a thirty-node run
/// draws thirty cards and reads exactly one writeup, so building thirty citation indexes to show one is
/// twenty-nine runs' worth of work nobody asked for (PRD 09 R6).
final class ReportEvidenceTests: XCTestCase {

    private func document(_ id: String) -> SourceDocument {
        SourceDocument(sourceID: id, url: "https://example.com/\(id)", title: id, contentType: .html,
                       snapshotPath: "sources/\(id).md")
    }

    private func angle(_ id: String, citation: String) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: "q \(id)", status: .complete, preset: .standard, headline: "h \(id)",
            confidenceSummary: "", sourcesConsulted: 1, costUSD: 1, durationSeconds: 1, note: nil,
            notePath: nil, transcriptPath: "/tmp/quorum-run/\(id).jsonl", round: 1,
            evidence: EvidenceIndex(documents: [document("s-\(id)")],
                                    citations: [Citation(id: citation, sourceID: "s-\(id)", quote: "q",
                                                         start: 0, end: 1, match: .exact)]))
    }

    private func synthesis(_ id: String) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: "the question", status: .complete, preset: .standard, headline: "answer",
            confidenceSummary: "", sourcesConsulted: 0, costUSD: 2, durationSeconds: 2, note: nil,
            notePath: nil, transcriptPath: "/tmp/quorum-run/\(id).jsonl", isSynthesis: true, round: 1,
            evidence: EvidenceIndex())
    }

    private func wideRun(angles: Int = 29, validation: RunValidation? = nil) -> RunReport {
        let entries = (1...angles).map { angle("a\($0)", citation: "a\($0)c1") } + [synthesis("synthesis")]
        return RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                         entries: entries, totalCostUSD: 5, runSpendCapUSD: 40, validation: validation)
    }

    func testOpeningARunReadsNobodysEvidenceUntilARailAsksForIt() {
        let evidence = ReportEvidence(report: wideRun())

        XCTAssertEqual(evidence.loadedNodes, [], "thirty nodes on a canvas, nothing indexed")
    }

    func testARailOpenIndexesOnlyTheNodeItOpenedOn() {
        let evidence = ReportEvidence(report: wideRun())

        _ = evidence.reading(for: "a7")

        XCTAssertEqual(evidence.loadedNodes, ["a7"])
    }

    func testTheSameNodeReopenedIsReadOnlyOnce() {
        let evidence = ReportEvidence(report: wideRun())

        let first = evidence.reading(for: "a7")
        let second = evidence.reading(for: "a7")

        XCTAssertEqual(first, second)
        XCTAssertEqual(evidence.loadedNodes, ["a7"])
    }

    /// A node that kept nothing is remembered as having kept nothing, rather than re-walking the report on
    /// every redraw to find that out again.
    func testANodeWithNothingToReadIsAskedAboutOnlyOnce() {
        let evidence = ReportEvidence(report: wideRun())

        XCTAssertNil(evidence.reading(for: "synthesis-that-never-ran"))
        XCTAssertEqual(evidence.loadedNodes, ["synthesis-that-never-ran"])
    }

    // MARK: what each node is allowed to read

    func testAnAngleReadsItsOwnCitationsAndTheAnswerReadsEveryAngles() {
        let evidence = ReportEvidence(report: wideRun(angles: 3))

        XCTAssertEqual(evidence.reading(for: "a2")?.index.citations.map(\.id), ["a2c1"])
        XCTAssertEqual(evidence.reading(for: "synthesis")?.index.citations.map(\.id).sorted(),
                       ["a1c1", "a2c1", "a3c1"])
    }

    func testEvidenceIsReadFromTheRunsOwnDirectory() {
        let evidence = ReportEvidence(report: wideRun(angles: 1))

        XCTAssertEqual(evidence.reading(for: "a1")?.directory.path, "/tmp/quorum-run/evidence")
    }

    /// The quotes the loop could not stand a claim up on arrive with the answer that ships them, so a chip
    /// in the rail is drawn on the same ladder the run's validators left behind (PRD 09 R3).
    func testTheAnswerCarriesTheQuotesItsClaimsCouldNotStandOn() {
        let validation = RunValidation(status: "validated", holds: false, blocking: 1, spendUSD: 0, rounds: 1,
                                       objectionsAdmitted: 1, objectionsResolved: 0,
                                       objectionsOutstanding: [], verdicts: [],
                                       unsupportedCitationIDs: ["a2c1"])
        let evidence = ReportEvidence(report: wideRun(angles: 3, validation: validation))

        let index = try? XCTUnwrap(evidence.reading(for: "synthesis")?.index)

        XCTAssertEqual(index?.tier("a2c1"), .unsupported)
        XCTAssertEqual(index?.tier("a1c1"), .supported)
    }
}
