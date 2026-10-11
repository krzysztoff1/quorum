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

    func testJudgingTheAnswerIsItsOwnPhaseAndNotGrounding() {
        XCTAssertEqual(FanOutPhase(wire: "validating"), .validating)
    }

    func testAPhaseNobodyKnowsReadsAsResearchRatherThanStoppingTheRun() {
        XCTAssertEqual(FanOutPhase(wire: "sharpening_pencils"), .researching)
    }
}
