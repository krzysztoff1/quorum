import XCTest
@testable import QuorumCore

/// The header strip over a finished run's canvas. Every number on it is the number the digest list showed,
/// derived once here rather than assembled in a view — so retiring the list changes where the run is read,
/// never what it says.
final class RunHeaderTests: XCTestCase {

    private func angle(_ id: String, _ question: String, round: Int = 1,
                       status: TopicStatus = .complete,
                       evidence: EvidenceIndex? = nil) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: question, status: status, preset: .standard,
            headline: "\(id) headline", confidenceSummary: "1 high", sourcesConsulted: 3,
            costUSD: 1, durationSeconds: 10, note: nil, notePath: nil, transcriptPath: nil,
            round: round, evidence: evidence)
    }

    private func synthesis(_ id: String, round: Int? = 1, noteAction: NoteAction? = nil,
                           conflicts: [Conflict] = [], gaps: [String] = []) -> RunReport.TopicEntry {
        RunReport.TopicEntry(
            id: id, question: "the root question", status: .complete, preset: .standard,
            headline: "\(id) headline", confidenceSummary: "2 high · 1 unverified", sourcesConsulted: 9,
            costUSD: 2, durationSeconds: 20, note: nil, notePath: nil, noteAction: noteAction,
            transcriptPath: nil, isSynthesis: true, conflicts: conflicts, gaps: gaps, round: round)
    }

    private func report(_ entries: [RunReport.TopicEntry], cost: Decimal = 5,
                        cap: Decimal = 40) -> RunReport {
        RunReport(startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
                  entries: entries, totalCostUSD: cost, runSpendCapUSD: cap)
    }

    private func diveReport() -> RunReport {
        report([
            angle("a1", "angle one"),
            angle("a2", "angle two"),
            angle("a3", "never ran", status: .skipped),
            synthesis("s1", conflicts: [Conflict(claim: "they disagree", positions: ["x", "y"])],
                      gaps: ["nobody measured retention"]),
            angle("a4", "chase the conflict", round: 2),
            synthesis("s2", round: 2, conflicts: [], gaps: ["still open"]),
        ])
    }

    func testTheHeaderCarriesTheNumbersTheDigestShowed() throws {
        let report = diveReport()
        let header = RunHeader(report: report)
        let answer = try XCTUnwrap(report.entries.last { $0.isSynthesis == true })

        XCTAssertEqual(header.question, answer.question)
        XCTAssertEqual(header.headline, answer.headline)
        XCTAssertEqual(header.confidenceSummary, answer.confidenceSummary)
        XCTAssertEqual(header.sourcesConsulted, answer.sourcesConsulted)
        XCTAssertEqual(header.conflicts, answer.conflicts?.count)
        XCTAssertEqual(header.gaps, answer.gaps?.count)
        XCTAssertEqual(header.status, answer.status)
    }

    func testTheHeaderCountsOnlyTheAnglesThatRan() {
        let header = RunHeader(report: diveReport())

        XCTAssertEqual(header.angleCount, 3)
        XCTAssertEqual(header.rounds, 2)
    }

    func testTheHeaderCarriesTheRunsSpendAgainstItsCap() {
        let header = RunHeader(report: diveReport())

        XCTAssertEqual(header.costUSD, 5)
        XCTAssertEqual(header.capUSD, 40)
        XCTAssertTrue(header.stayedUnderCap)
        XCTAssertEqual(header.durationSeconds, 60, accuracy: 0.001)
    }

    func testASpentOverCapRunSaysSo() {
        let header = RunHeader(report: diveReport().overspending())

        XCTAssertFalse(header.stayedUnderCap)
    }

    /// The last synthesis wins because the reconciliation is appended after the rounds: a multi-round dive's
    /// current answer is the fused one, not the last round's.
    func testTheReconciledAnswerIsTheOneTheHeaderReads() {
        let header = RunHeader(report: report([
            angle("a1", "angle one"),
            synthesis("s1"),
            angle("a2", "chase it", round: 2),
            synthesis("s2", round: 2),
            synthesis("fused", round: nil, noteAction: .reconciled),
        ]))

        XCTAssertEqual(header.headline, "fused headline")
        XCTAssertTrue(header.isReconciled)
        XCTAssertEqual(header.rounds, 2)
    }

    func testASingleRoundRunIsNotReconciled() {
        let header = RunHeader(report: diveReport())

        XCTAssertFalse(header.isReconciled)
    }

    /// A run with no search key captured nothing, so the strip wears the same unvalidated notice the canvas
    /// and the reader do — one sentence, defined once.
    func testARunThatCapturedNothingWearsTheUnvalidatedNotice() {
        let ungrounded = EvidenceIndex(grounding: RunGrounding.none)
        let header = RunHeader(report: report([
            angle("a1", "angle one", evidence: ungrounded),
            synthesis("s1"),
        ]))

        XCTAssertFalse(header.isValidated)
        XCTAssertEqual(header.unvalidatedNotice, EvidenceIndex(grounding: .none).unvalidatedNotice)
    }

    func testACapturedRunHasNoticeNothing() {
        let header = RunHeader(report: diveReport())

        XCTAssertTrue(header.isValidated)
        XCTAssertNil(header.unvalidatedNotice)
    }

    /// A legacy run with no synthesis at all still has a header: the question it was asked, and the angle
    /// that answered it.
    func testARunWithNoSynthesisStillHasAHeader() {
        let header = RunHeader(report: report([angle("a1", "a lone topic")]))

        XCTAssertEqual(header.question, "a lone topic")
        XCTAssertEqual(header.headline, "a1 headline")
        XCTAssertEqual(header.angleCount, 1)
        XCTAssertEqual(header.rounds, 1)
    }

    func testAValidatedRunCarriesWhatItsValidatorsLeftStanding() {
        let outstanding = RunStreamParser.ObjectionEvent(
            lens: "coverage", statement: "no 2025 pricing", severity: "blocking",
            followup: "find the pricing page")
        let report = RunReport(
            startedAt: fixedStart, finishedAt: fixedStart.addingTimeInterval(60),
            entries: [angle("a1", "angle one"), synthesis("s1")], totalCostUSD: 5, runSpendCapUSD: 40,
            validation: RunValidation(status: "validated", holds: false, blocking: 1,
                                      spendUSD: Decimal(string: "0.08")!, rounds: 2,
                                      objectionsAdmitted: 2, objectionsResolved: 1,
                                      objectionsOutstanding: [outstanding], verdicts: []))
        let header = RunHeader(report: report)

        XCTAssertEqual(header.outstandingObjections, 1)
        XCTAssertEqual(header.validation?.holds, false)
    }

    /// A run from before the validator loop makes no claim either way — it is not a run whose answer failed.
    func testARunWithNoValidatorLoopDoesNotReadAsAFailedOne() {
        let header = RunHeader(report: diveReport())

        XCTAssertNil(header.validation)
        XCTAssertEqual(header.outstandingObjections, 0)
    }
}

private extension RunReport {
    func overspending() -> RunReport {
        RunReport(startedAt: startedAt, finishedAt: finishedAt, entries: entries,
                  totalCostUSD: runSpendCapUSD + 1, runSpendCapUSD: runSpendCapUSD)
    }
}
