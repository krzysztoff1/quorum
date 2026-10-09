import XCTest
@testable import QuorumCore

/// What the header is allowed to say the run is doing. The wire's phases and the sentence a person reads
/// are one mapping, tested here, because a run that says "researching" while it waits on a human — or
/// while it argues with its own draft — is lying about the only thing the header is for.
final class RunPhaseTests: XCTestCase {

    func testEveryWirePhaseHasAPhaseItMeans() {
        XCTAssertEqual(FanOutPhase(wire: "planning"), .planning)
        XCTAssertEqual(FanOutPhase(wire: "researching"), .researching)
        XCTAssertEqual(FanOutPhase(wire: "synthesizing"), .synthesizing)
        XCTAssertEqual(FanOutPhase(wire: "reconciling"), .synthesizing)
        XCTAssertEqual(FanOutPhase(wire: "grounding"), .verifying)
        XCTAssertEqual(FanOutPhase(wire: "done"), .done)
    }

    func testWaitingOnAPersonIsItsOwnPhaseAndNotResearch() {
        XCTAssertEqual(FanOutPhase(wire: "awaiting_approval"), .awaitingApproval)
    }

    func testJudgingTheAnswerIsItsOwnPhaseAndNotGrounding() {
        XCTAssertEqual(FanOutPhase(wire: "validating"), .validating)
    }

    func testAPhaseNobodyKnowsReadsAsResearchRatherThanStoppingTheRun() {
        XCTAssertEqual(FanOutPhase(wire: "sharpening_pencils"), .researching)
    }

    // MARK: the sentence under the question

    private func summary(_ phase: FanOutPhase, pendingApprovals: Int = 0,
                         proposedAngles: Int = 0) -> RunPhaseSummary {
        RunPhaseSummary(phase: phase, angleCount: 4, proposedAngles: proposedAngles,
                        pendingApprovals: pendingApprovals, round: 1, runningAngles: 4, spendUSD: 1.5)
    }

    func testWaitingOnAPersonSaysSoAndCountsWhatItIsWaitingFor() {
        let label = summary(.awaitingApproval, pendingApprovals: 2).label

        XCTAssertEqual(label, "waiting on you — 2 proposed inquiries")
    }

    func testOneProposedInquiryIsNotPluralised() {
        XCTAssertEqual(summary(.awaitingApproval, pendingApprovals: 1).label,
                       "waiting on you — 1 proposed inquiry")
    }

    func testAPlanUnderReviewStillReadsAsAPlanUnderReview() {
        XCTAssertEqual(summary(.awaitingApproval, proposedAngles: 4).label,
                       "4 angles — edit them on the canvas, then research")
    }

    func testTheLabelNeverClaimsResearchWhileTheRunIsBlockedOnAHuman() {
        let blocked = summary(.awaitingApproval, pendingApprovals: 2)

        XCTAssertFalse(blocked.label.contains("parallel"))
        XCTAssertFalse(blocked.label.contains("researching"))
        XCTAssertTrue(blocked.blockedOnAPerson)
        XCTAssertFalse(blocked.showsProgress)
    }

    func testJudgingTheAnswerSaysWhatIsBeingJudgedAgainst() {
        XCTAssertEqual(summary(.validating).label, "checking the answer against its own sources")
        XCTAssertTrue(summary(.validating).showsProgress)
        XCTAssertFalse(summary(.validating).blockedOnAPerson)
    }

    func testGroundingAndJudgingAreNotTheSameSentence() {
        XCTAssertNotEqual(summary(.verifying).label, summary(.validating).label)
    }

    func testAWaveThatCarriesOnAroundAPendingOfferStillSaysItIsResearching() {
        let label = summary(.researching, pendingApprovals: 2).label

        XCTAssertEqual(label, "4 blind agents in parallel · \(Reporter.money(1.5))")
    }

    func testALaterRoundNamesItself() {
        var later = summary(.researching)
        later.round = 3

        XCTAssertTrue(later.label.hasPrefix("round 3 · "))
    }

    func testPlanningCountsTheAnglesItIsDecomposingInto() {
        XCTAssertEqual(summary(.planning).label, "decomposing into 4 angles…")
    }

}
