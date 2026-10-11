import XCTest
@testable import QuorumCore

final class QuestionThreadTests: XCTestCase {

    func testRunsOfOneQuestionFormOneThreadOldestFirst() throws {
        let later = try RunFixture.make(question: "Q1", run: "R2", kind: "followup", created: "2026-10-09T12:00:00.000Z")
        let first = try RunFixture.make(question: "Q1", run: "R1", created: "2026-10-09T10:00:00.000Z")
        let other = try RunFixture.make(question: "Q2", run: "R3", title: "Another")

        let threads = ThreadIndex.build(runs: [later, first, other])

        XCTAssertEqual(threads.count, 2)
        let thread = try XCTUnwrap(threads.first { $0.id == "Q1" })
        XCTAssertEqual(thread.runs.map(\.id), ["R1", "R2"])
    }

    func testTheThreadIsTitledByItsQuestionAndKeepsTheWordsTheUserTyped() throws {
        let run = try RunFixture.make(title: "Personalizacja w food-tech", asked: "zrób research personalizacji")
        let thread = try XCTUnwrap(ThreadIndex.build(runs: [run]).first)
        XCTAssertEqual(thread.title, "Personalizacja w food-tech")
        XCTAssertEqual(thread.askedText, "zrób research personalizacji")
    }

    func testTheAnswerOnTopIsTheNewestOfTheInitialAndRerunsAndFollowUpsStayBeneathIt() throws {
        let initial = try RunFixture.make(run: "R1", tier: "quick", created: "2026-10-01T10:00:00.000Z")
        let followUp = try RunFixture.make(run: "R2", kind: "followup", created: "2026-10-02T10:00:00.000Z")
        let deeper = try RunFixture.make(run: "R3", kind: "rerun", tier: "deep", created: "2026-10-03T10:00:00.000Z")
        let thread = try XCTUnwrap(ThreadIndex.build(runs: [initial, followUp, deeper]).first)

        XCTAssertEqual(thread.current?.id, "R3")
        XCTAssertEqual(thread.earlierAnswers.map(\.id), ["R1"])
        XCTAssertEqual(thread.followUps.map(\.id), ["R2"])
    }

    func testAThreadIsRunningWhileAnyOfItsRunsIs() throws {
        let done = try RunFixture.make(run: "R1")
        let live = try RunFixture.make(run: "R2", kind: "followup", status: "running",
                                       created: "2026-10-09T11:00:00.000Z", finished: nil)
        let thread = try XCTUnwrap(ThreadIndex.build(runs: [done, live]).first)
        XCTAssertTrue(thread.isRunning)
        XCTAssertEqual(thread.runningRun?.id, "R2")
    }

    func testTheLatestActivityIsTheNewestFinishOrStart() throws {
        let done = try RunFixture.make(run: "R1", finished: "2026-10-09T10:04:30.000Z")
        let live = try RunFixture.make(run: "R2", kind: "followup", status: "running",
                                       created: "2026-10-09T11:00:00.000Z", finished: nil)
        let thread = try XCTUnwrap(ThreadIndex.build(runs: [done, live]).first)
        XCTAssertEqual(thread.latestActivity, Clock.date("2026-10-09T11:00:00.000Z"))
        XCTAssertEqual(thread.latestFinish, Clock.date("2026-10-09T10:04:30.000Z"))
    }

    func testTheNewestRunWithAnAnswerIsWhatTheThreadShows() throws {
        let done = try RunFixture.make(run: "R1")
        let deeperRunning = try RunFixture.make(run: "R2", kind: "rerun", status: "running", tier: "deep",
                                                created: "2026-10-09T11:00:00.000Z", finished: nil)
        let thread = try XCTUnwrap(ThreadIndex.build(runs: [done, deeperRunning]).first)
        XCTAssertEqual(thread.current?.id, "R2")
        XCTAssertEqual(thread.shownAnswer?.id, "R1")
    }
}
