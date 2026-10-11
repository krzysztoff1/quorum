import XCTest
@testable import QuorumCore

final class ThreadPageTests: XCTestCase {

    private let calendar = Clock.calendar

    private func page(_ runs: [StoredRun], threads: Bool = true) throws -> ThreadPage {
        let thread = try XCTUnwrap(ThreadIndex.build(runs: runs).first)
        return ThreadPage(thread: thread, capabilities: threads ? EngineCapabilities(checks: [EngineDoctorCheck(id: "threads", ok: true, detail: "", fix: nil)]) : .none,
                          calendar: calendar)
    }

    func testTheScopeLineSaysHowManyChoicesTheUserMade() throws {
        XCTAssertNil(try page([RunFixture.make()]).scopeLine)
        XCTAssertEqual(try page([RunFixture.make(choices: 3)]).scopeLine, "scoped · 3 choices")
        XCTAssertEqual(try page([RunFixture.make(choices: 1)]).scopeLine, "scoped · 1 choice")
    }

    func testAnEarlierAnswerIsLabelledWithItsDepthAndDate() throws {
        let quick = try RunFixture.make(run: "R1", tier: "quick", created: "2026-10-03T10:00:00.000Z", finished: "2026-10-03T10:04:00.000Z")
        let deep = try RunFixture.make(run: "R2", kind: "rerun", tier: "deep", created: "2026-10-05T10:00:00.000Z", finished: "2026-10-05T10:20:00.000Z")
        let page = try page([quick, deep])
        XCTAssertEqual(page.answer?.id, "R2")
        XCTAssertEqual(page.earlier.map(\.label), ["earlier answer, Quick, 3 Oct"])
        XCTAssertEqual(page.earlier.map(\.runID), ["R1"])
    }

    func testFollowUpsShowTheirQuestionAndWhereTheyAre() throws {
        let initial = try RunFixture.make(run: "R1")
        let answered = try RunFixture.make(run: "R2", title: "And for B2B?", kind: "followup", created: "2026-10-09T11:00:00.000Z", finished: "2026-10-09T11:03:00.000Z")
        let running = try RunFixture.make(run: "R3", title: "And in Poland?", kind: "followup", status: "running", created: "2026-10-09T12:00:00.000Z", finished: nil)
        let page = try page([initial, answered, running])
        XCTAssertEqual(page.followUps.map(\.runID), ["R2", "R3"])
        XCTAssertEqual(page.followUps.map(\.state), [.answered, .running])
        XCTAssertEqual(page.followUps[0].question, "And for B2B?")
    }

    func testAnAnswerIsRunningWhenTheLatestRunHasNotFinished() throws {
        let running = try RunFixture.make(run: "R1", status: "running", finished: nil)
        let page = try page([running])
        XCTAssertNil(page.answer)
        XCTAssertEqual(page.running?.id, "R1")
        XCTAssertTrue(page.isWorking)
    }

    func testGoDeeperIsOfferedOnAFinishedQuickAnswerWhenTheEngineCanDoIt() throws {
        let quick = try RunFixture.make(tier: "quick")
        XCTAssertTrue(try page([quick]).canGoDeeper)
        XCTAssertFalse(try page([quick], threads: false).canGoDeeper)
        XCTAssertFalse(try page([RunFixture.make(tier: "deep")]).canGoDeeper)
        XCTAssertFalse(try page([RunFixture.make(status: "running", finished: nil)]).canGoDeeper)
    }

    func testGoDeeperReRunsTheResolvedQuestionAsDeepUnderTheSameThread() throws {
        let quick = try RunFixture.make(question: "Q1", run: "R1", tier: "quick")
        let start = try XCTUnwrap(try page([quick]).goDeeperStart())
        XCTAssertEqual(start.kind, .rerun)
        XCTAssertEqual(start.tier, .deep)
        XCTAssertEqual(start.parentRunID, "R1")
        XCTAssertEqual(start.questionID, "Q1")
        XCTAssertEqual(start.brief?.tier, .deep)
        XCTAssertEqual(start.question, quick.record.brief.question)
    }

    func testAFollowUpIsQuickAndPointsAtTheAnswerItBuildsOn() throws {
        let quick = try RunFixture.make(question: "Q1", run: "R1", tier: "deep")
        let start = try XCTUnwrap(try page([quick]).followUpStart("  and in Poland?  "))
        XCTAssertEqual(start.kind, .followup)
        XCTAssertEqual(start.tier, .quick)
        XCTAssertEqual(start.question, "and in Poland?")
        XCTAssertEqual(start.parentRunID, "R1")
        XCTAssertEqual(start.questionID, "Q1")
        XCTAssertNil(try page([quick]).followUpStart("   "))
    }

    func testFollowUpsNeedTheEngineToKnowThreadsToo() throws {
        let quick = try RunFixture.make()
        XCTAssertNil(try page([quick], threads: false).followUpStart("and?"))
        XCTAssertFalse(try page([quick], threads: false).canFollowUp)
    }

    func testResearchingAConflictPrefillsAFollowUp() throws {
        let page = try page([RunFixture.make()])
        XCTAssertEqual(page.conflictFollowUp(statement: "Is the lift 1–2% or 63%?"), "Resolve this conflict: Is the lift 1–2% or 63%?")
    }

    func testAFollowUpAnswerCanBeReadInPlaceOfTheMainAnswerAndFallsBackWhenItIsGone() throws {
        let initial = try RunFixture.make(run: "R1")
        let followUp = try RunFixture.make(run: "R2", kind: "followup", created: "2026-10-09T11:00:00.000Z", finished: "2026-10-09T11:03:00.000Z")
        let running = try RunFixture.make(run: "R3", kind: "followup", status: "running", created: "2026-10-09T12:00:00.000Z", finished: nil)
        let page = try page([initial, followUp, running])
        XCTAssertEqual(page.viewed(override: nil)?.id, "R1")
        XCTAssertEqual(page.viewed(override: "R2")?.id, "R2")
        XCTAssertEqual(page.viewed(override: "R3")?.id, "R1")
        XCTAssertEqual(page.viewed(override: "missing")?.id, "R1")
        XCTAssertEqual(page.viewingOverride("R2"), "R2")
        XCTAssertNil(page.viewingOverride("R3"))
        XCTAssertNil(page.viewingOverride(nil))
    }
}
