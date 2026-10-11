import XCTest
@testable import QuorumCore

final class StageStripTests: XCTestCase {

    private let started = Clock.date("2026-10-11T13:00:00.000Z")
    private let now = Clock.date("2026-10-11T13:04:10.000Z")

    private func strip(_ progress: RunProgress?, tier: Tier? = .deep, choices: Int = 3) -> StageStrip {
        StageStrip(progress: progress, tier: tier, choices: choices, startedAt: started, now: now, calendar: Clock.calendar)
    }

    private let researching = RunProgress(stage: "research", stageIndex: 2, stageCount: 5, tasksDone: 2, tasksTotal: 3,
                                          sourcesRead: 31, etaSeconds: 540)

    func testTheRunReadsAsFivePlainSteps() {
        XCTAssertEqual(strip(researching).stages.map(\.name), ["Scope", "Research", "Draft", "Check", "Answer"])
    }

    func testStepsBeforeTheCurrentOneAreDoneAndAfterItPending() {
        XCTAssertEqual(strip(researching).stages.map(\.state), [.done, .current, .pending, .pending, .pending])
        let checking = RunProgress(stage: "check", stageIndex: 4, stageCount: 5, tasksDone: 3, tasksTotal: 3, sourcesRead: 40)
        XCTAssertEqual(strip(checking).stages.map(\.state), [.done, .done, .done, .current, .pending])
    }

    func testTheCurrentStepFillsAsItsTasksFinish() throws {
        let stages = strip(researching).stages
        XCTAssertEqual(stages[0].fraction, 1)
        XCTAssertEqual(stages[1].fraction, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(stages[2].fraction, 0)
    }

    func testResearchSaysHowManyAnglesAreDoneAndHowManySourcesWereRead() {
        XCTAssertEqual(strip(researching).stages[1].detail, "2 of 3 angles · 31 sources")
        let drafting = RunProgress(stage: "draft", stageIndex: 3, stageCount: 5, tasksDone: 3, tasksTotal: 3, sourcesRead: 31)
        XCTAssertEqual(strip(drafting).stages[1].detail, "3 angles · 31 sources")
        XCTAssertEqual(strip(nil).stages[1].detail, "angles in parallel")
    }

    func testScopeNamesTheChoicesTheUserMade() {
        XCTAssertEqual(strip(researching, choices: 3).stages[0].detail, "3 choices")
        XCTAssertEqual(strip(researching, choices: 1).stages[0].detail, "1 choice")
        XCTAssertEqual(strip(researching, choices: 0).stages[0].detail, "your question")
    }

    func testQuickChecksQuotesAndDeepAlsoRunsCritics() {
        XCTAssertEqual(strip(researching, tier: .quick).stages[3].detail, "quotes")
        XCTAssertEqual(strip(researching, tier: .deep).stages[3].detail, "critics + quotes")
    }

    func testTheLastStepNamesTheExpectedFinishTimeWhenTheEngineEstimates() {
        XCTAssertEqual(strip(researching).stages[4].detail, "~13:13")
        let noEstimate = RunProgress(stage: "research", stageIndex: 2, stageCount: 5, tasksDone: 0, tasksTotal: 3, sourcesRead: 0)
        XCTAssertEqual(strip(noEstimate).stages[4].detail, "")
    }

    func testTheHeadlineAndTheClockLine() {
        XCTAssertEqual(strip(researching).headline, "Researching")
        XCTAssertEqual(strip(researching).clock, "4 min in · about 9 min left")
        let noEstimate = RunProgress(stage: "research", stageIndex: 2, stageCount: 5, tasksDone: 0, tasksTotal: 3, sourcesRead: 0)
        XCTAssertEqual(strip(noEstimate).clock, "4 min in")
        XCTAssertEqual(strip(nil).headline, "Starting")
        XCTAssertEqual(strip(nil).clock, "4 min in")
    }

    func testTheFirstMinuteIsNotCountedInMinutes() {
        let early = StageStrip(progress: nil, tier: .quick, choices: 0, startedAt: started,
                               now: started.addingTimeInterval(20), calendar: Clock.calendar)
        XCTAssertEqual(early.clock, "just started")
    }
}
