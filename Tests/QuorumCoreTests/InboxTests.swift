import XCTest
@testable import QuorumCore

final class InboxTests: XCTestCase {

    private let now = Clock.date("2026-10-11T14:00:00.000Z")

    private func sections(_ runs: [StoredRun], progress: [String: RunProgress] = [:], ui: UIState = UIState()) -> [InboxSection] {
        Inbox.sections(threads: ThreadIndex.build(runs: runs), progress: progress, ui: ui, now: now, calendar: Clock.calendar)
    }

    private func read(_ questions: [String]) -> UIState {
        var state = UIState()
        for question in questions { state.markRead(question: question, at: Clock.date("2026-12-01T00:00:00.000Z")) }
        return state
    }

    func testRunningQuestionsSitUnderRunningAndTheRestAreGroupedByRecency() throws {
        let running = try RunFixture.make(question: "Q1", status: "running", created: "2026-10-11T13:00:00.000Z", finished: nil)
        let today = try RunFixture.make(question: "Q2", created: "2026-10-11T08:00:00.000Z", finished: "2026-10-11T08:03:00.000Z")
        let yesterday = try RunFixture.make(question: "Q3", created: "2026-10-10T08:00:00.000Z", finished: "2026-10-10T08:03:00.000Z")
        let thisWeek = try RunFixture.make(question: "Q4", created: "2026-10-06T08:00:00.000Z", finished: "2026-10-06T08:03:00.000Z")
        let september = try RunFixture.make(question: "Q5", created: "2026-09-28T08:00:00.000Z", finished: "2026-09-28T08:03:00.000Z")

        let result = sections([september, thisWeek, yesterday, today, running])

        XCTAssertEqual(result.map(\.title), ["Running", "Today", "Yesterday", "This week", "September"])
        XCTAssertEqual(result.map { $0.rows.map(\.id) }, [["Q1"], ["Q2"], ["Q3"], ["Q4"], ["Q5"]])
    }

    func testAnOlderYearNamesItsYear() throws {
        let old = try RunFixture.make(question: "Q1", created: "2025-09-28T08:00:00.000Z", finished: "2025-09-28T08:03:00.000Z")
        XCTAssertEqual(sections([old]).map(\.title), ["September 2025"])
    }

    func testWithinAGroupTheNewestIsFirst() throws {
        let early = try RunFixture.make(question: "Q1", created: "2026-10-11T07:00:00.000Z", finished: "2026-10-11T07:03:00.000Z")
        let late = try RunFixture.make(question: "Q2", created: "2026-10-11T09:00:00.000Z", finished: "2026-10-11T09:03:00.000Z")
        XCTAssertEqual(sections([early, late])[0].rows.map(\.id), ["Q2", "Q1"])
    }

    func testAFinishedRowSaysHowFarToTrustItAndWhatIsOpen() throws {
        let run = try RunFixture.make(tier: "deep", trust: "moderate", conflicts: 1)
        let row = try XCTUnwrap(sections([run]).first?.rows.first)
        XCTAssertEqual(row.tier, .deep)
        XCTAssertEqual(row.parts, ["Moderate", "1 open conflict"])
        XCTAssertEqual(row.state, .answered(.moderate))
    }

    func testConflictsArePluralisedAndFollowUpsAreCounted() throws {
        let initial = try RunFixture.make(run: "R1", trust: "shaky", conflicts: 2, created: "2026-10-11T07:00:00.000Z", finished: "2026-10-11T07:03:00.000Z")
        let one = try RunFixture.make(run: "R2", kind: "followup", created: "2026-10-11T08:00:00.000Z", finished: "2026-10-11T08:02:00.000Z")
        let two = try RunFixture.make(run: "R3", kind: "followup", created: "2026-10-11T09:00:00.000Z", finished: "2026-10-11T09:02:00.000Z")
        let row = try XCTUnwrap(sections([initial, one, two]).first?.rows.first)
        XCTAssertEqual(row.parts, ["Shaky", "2 open conflicts", "2 follow-ups"])
        XCTAssertEqual(sections([initial, one])[0].rows[0].parts.last, "1 follow-up")
    }

    func testARunningRowShowsItsEstimateOrItsStage() throws {
        let run = try RunFixture.make(status: "running", tier: "deep", created: "2026-10-11T13:00:00.000Z", finished: nil)
        let withEta = RunProgress(stage: "research", stageIndex: 2, stageCount: 5, tasksDone: 1, tasksTotal: 3, sourcesRead: 4, etaSeconds: 540)
        let withoutEta = RunProgress(stage: "check", stageIndex: 4, stageCount: 5, tasksDone: 3, tasksTotal: 3, sourcesRead: 9)

        XCTAssertEqual(sections([run], progress: ["R1": withEta])[0].rows[0].parts, ["~9 min left"])
        XCTAssertEqual(sections([run], progress: ["R1": withoutEta])[0].rows[0].parts, ["Checking"])
        XCTAssertEqual(sections([run])[0].rows[0].parts, ["Starting"])
        XCTAssertEqual(sections([run])[0].rows[0].state, .running)
    }

    func testFailedStoppedAndPartialRunsSayWhatHappenedInOneWord() throws {
        let failed = try RunFixture.make(question: "Q1", status: "failed")
        let crashed = try RunFixture.make(question: "Q2", status: "crashed")
        let stopped = try RunFixture.make(question: "Q3", status: "halted")
        let cancelled = try RunFixture.make(question: "Q4", status: "cancelled")
        let partial = try RunFixture.make(question: "Q5", status: "partial")
        let rows = Dictionary(uniqueKeysWithValues: sections([failed, crashed, stopped, cancelled, partial]).flatMap(\.rows).map { ($0.id, $0) })

        XCTAssertEqual(rows["Q1"]?.parts, ["Couldn't finish"])
        XCTAssertEqual(rows["Q1"]?.state, .failed)
        XCTAssertEqual(rows["Q2"]?.state, .failed)
        XCTAssertEqual(rows["Q3"]?.parts.first, "Stopped")
        XCTAssertEqual(rows["Q3"]?.state, .stopped)
        XCTAssertEqual(rows["Q4"]?.state, .stopped)
        XCTAssertEqual(rows["Q5"]?.parts.first, "Partial")
        XCTAssertEqual(rows["Q5"]?.state, .partial)
    }

    func testARateLimitedRunSaysTheLimitInsteadOfJustStopped() throws {
        let limited = try RunFixture.make(question: "Q6", status: "halted", refusal: (kind: "rate_limited", reason: "limit"))
        let row = try XCTUnwrap(sections([limited]).flatMap(\.rows).first)
        XCTAssertEqual(row.parts.first, "Usage limit")
        XCTAssertEqual(row.state, .stopped)
    }

    func testTheTimeIsTheClockTodayTheWeekdayThisWeekAndTheDateBeyond() throws {
        let today = try RunFixture.make(question: "Q1", created: "2026-10-11T08:00:00.000Z", finished: "2026-10-11T08:31:00.000Z")
        let yesterday = try RunFixture.make(question: "Q2", created: "2026-10-10T08:00:00.000Z", finished: "2026-10-10T08:03:00.000Z")
        let week = try RunFixture.make(question: "Q3", created: "2026-10-06T08:00:00.000Z", finished: "2026-10-06T08:03:00.000Z")
        let old = try RunFixture.make(question: "Q4", created: "2026-09-28T08:00:00.000Z", finished: "2026-09-28T08:03:00.000Z")
        let rows = Dictionary(uniqueKeysWithValues: sections([today, yesterday, week, old]).flatMap(\.rows).map { ($0.id, $0.when) })

        XCTAssertEqual(rows["Q1"], "08:31")
        XCTAssertEqual(rows["Q2"], "Sat")
        XCTAssertEqual(rows["Q3"], "Tue")
        XCTAssertEqual(rows["Q4"], "28 Sep")
    }

    func testAnAnswerNotYetOpenedIsUnreadAndOpeningItClearsTheDot() throws {
        let run = try RunFixture.make(question: "Q1")
        XCTAssertTrue(sections([run])[0].rows[0].unread)
        XCTAssertFalse(sections([run], ui: read(["Q1"]))[0].rows[0].unread)
    }

    func testARunningQuestionIsNeverUnread() throws {
        let run = try RunFixture.make(question: "Q1", status: "running", created: "2026-10-11T13:00:00.000Z", finished: nil)
        XCTAssertFalse(sections([run])[0].rows[0].unread)
    }

    func testTheRowKeepsTheQuestionsTitleEvenWhenAFollowUpIsNewer() throws {
        let initial = try RunFixture.make(run: "R1", title: "Original question")
        let followUp = try RunFixture.make(run: "R2", title: "Original question", kind: "followup", created: "2026-10-11T09:00:00.000Z", finished: "2026-10-11T09:02:00.000Z")
        XCTAssertEqual(sections([initial, followUp]).flatMap(\.rows).map(\.title), ["Original question"])
    }

    func testTheFlatOrderIsWhatTheNumberKeysAndTheArrowsWalk() throws {
        let running = try RunFixture.make(question: "Q1", status: "running", created: "2026-10-11T13:00:00.000Z", finished: nil)
        let today = try RunFixture.make(question: "Q2", created: "2026-10-11T08:00:00.000Z", finished: "2026-10-11T08:03:00.000Z")
        let yesterday = try RunFixture.make(question: "Q3", created: "2026-10-10T08:00:00.000Z", finished: "2026-10-10T08:03:00.000Z")
        XCTAssertEqual(Inbox.order(sections([yesterday, today, running])), ["Q1", "Q2", "Q3"])
    }

    func testStepMovesThroughTheOrderAndStopsAtTheEnds() {
        let order = ["Q1", "Q2", "Q3"]
        XCTAssertEqual(Inbox.step(from: "Q1", by: 1, in: order), "Q2")
        XCTAssertEqual(Inbox.step(from: "Q3", by: 1, in: order), "Q3")
        XCTAssertEqual(Inbox.step(from: "Q1", by: -1, in: order), "Q1")
        XCTAssertEqual(Inbox.step(from: nil, by: 1, in: order), "Q1")
        XCTAssertEqual(Inbox.step(from: nil, by: -1, in: order), "Q3")
        XCTAssertNil(Inbox.step(from: nil, by: 1, in: []))
    }

    func testTheNthQuestionIsOneBased() {
        XCTAssertEqual(Inbox.nth(2, in: ["Q1", "Q2"]), "Q2")
        XCTAssertNil(Inbox.nth(3, in: ["Q1", "Q2"]))
        XCTAssertNil(Inbox.nth(0, in: ["Q1"]))
    }

    func testTheMenuBarSummarySaysWhatIsRunningThenWhatIsNew() {
        XCTAssertEqual(Inbox.menuSummary(running: 2, unread: 5), "2 running")
        XCTAssertEqual(Inbox.menuSummary(running: 0, unread: 3), "3 new")
        XCTAssertEqual(Inbox.menuSummary(running: 0, unread: 0), "Nothing running")
    }
}
