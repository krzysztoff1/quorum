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

    func testThePhaseOfAnOldTranscriptThatWaitedOnAPersonReadsAsResearch() {
        XCTAssertEqual(FanOutPhase(wire: "awaiting_approval"), .researching)
    }

    func testJudgingTheAnswerIsItsOwnPhaseAndNotGrounding() {
        XCTAssertEqual(FanOutPhase(wire: "validating"), .validating)
    }

    func testAPhaseNobodyKnowsReadsAsResearchRatherThanStoppingTheRun() {
        XCTAssertEqual(FanOutPhase(wire: "sharpening_pencils"), .researching)
    }

    // MARK: the sentence under the question

    private func summary(_ phase: FanOutPhase) -> RunPhaseSummary {
        RunPhaseSummary(phase: phase, angleCount: 4, round: 1, runningAngles: 4, spendUSD: 1.5)
    }

    func testJudgingTheAnswerSaysWhatIsBeingJudgedAgainst() {
        XCTAssertEqual(summary(.validating).label, "checking the answer against its own sources")
    }

    func testGroundingAndJudgingAreNotTheSameSentence() {
        XCTAssertNotEqual(summary(.verifying).label, summary(.validating).label)
    }

    func testResearchSaysHowManyAgentsAreRunningAndWhatTheyHaveSpent() {
        XCTAssertEqual(summary(.researching).label, "4 blind agents in parallel · \(Format.money(Decimal(1.5)))")
    }

    func testALaterRoundNamesItself() {
        var later = summary(.researching)
        later.round = 3

        XCTAssertTrue(later.label.hasPrefix("round 3 · "))
    }

    func testPlanningCountsTheAnglesItIsDecomposingInto() {
        XCTAssertEqual(summary(.planning).label, "decomposing into 4 angles…")
    }

    func testARunThatHasNotPlannedYetHasNotLaunched() {
        XCTAssertFalse(FanOutPhase.planning.hasLaunched)
        XCTAssertTrue(FanOutPhase.researching.hasLaunched)
    }

}
