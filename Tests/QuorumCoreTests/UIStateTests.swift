import XCTest
@testable import QuorumCore

final class UIStateTests: XCTestCase {

    func testAnAnswerFinishedAfterTheLastReadIsUnread() {
        var state = UIState()
        state.markRead(question: "Q1", at: Clock.date("2026-10-09T10:00:00.000Z"))
        XCTAssertTrue(state.isUnread(question: "Q1", latestFinish: Clock.date("2026-10-09T10:05:00.000Z")))
        XCTAssertFalse(state.isUnread(question: "Q1", latestFinish: Clock.date("2026-10-09T09:59:00.000Z")))
    }

    func testAQuestionNeverOpenedIsUnreadOnceItHasAnAnswer() {
        let state = UIState()
        XCTAssertTrue(state.isUnread(question: "Q1", latestFinish: Clock.date("2026-10-09T10:05:00.000Z")))
        XCTAssertFalse(state.isUnread(question: "Q1", latestFinish: nil))
    }

    func testReadingNeverMovesTheMarkerBackwards() {
        var state = UIState()
        state.markRead(question: "Q1", at: Clock.date("2026-10-09T12:00:00.000Z"))
        state.markRead(question: "Q1", at: Clock.date("2026-10-09T10:00:00.000Z"))
        XCTAssertFalse(state.isUnread(question: "Q1", latestFinish: Clock.date("2026-10-09T11:00:00.000Z")))
    }

    func testTheFileSurvivesARoundTripInTheBrainFolder() throws {
        let brain = try makeTempProject()
        var state = UIState()
        state.markRead(question: "Q1", at: Clock.date("2026-10-09T10:00:00.000Z"))
        try state.save(in: brain)

        XCTAssertEqual(UIState.load(in: brain), state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brain.appendingPathComponent("ui-state.json").path))
    }

    func testAMissingOrBrokenFileIsAnEmptyState() throws {
        let brain = try makeTempProject()
        XCTAssertEqual(UIState.load(in: brain), UIState())
        try Data("not json".utf8).write(to: brain.appendingPathComponent("ui-state.json"))
        XCTAssertEqual(UIState.load(in: brain), UIState())
    }

    func testTheFirstLaunchMarksEverythingAlreadyThereAsRead() throws {
        let brain = try makeTempProject()
        let run = try RunFixture.make(question: "Q1")
        let threads = ThreadIndex.build(runs: [run])

        let seeded = UIState.loadOrSeed(in: brain, threads: threads)

        XCTAssertFalse(seeded.isUnread(question: "Q1", latestFinish: threads[0].latestFinish))
        XCTAssertTrue(FileManager.default.fileExists(atPath: brain.appendingPathComponent("ui-state.json").path))
    }

    func testAnExistingFileIsNotSeededOver() throws {
        let brain = try makeTempProject()
        try UIState().save(in: brain)
        let threads = ThreadIndex.build(runs: [try RunFixture.make(question: "Q1")])

        let loaded = UIState.loadOrSeed(in: brain, threads: threads)

        XCTAssertTrue(loaded.isUnread(question: "Q1", latestFinish: threads[0].latestFinish))
    }

    func testACorruptFileIsTreatedLikeAFirstLaunchAndRewritten() throws {
        let brain = try makeTempProject()
        let file = brain.appendingPathComponent(UIState.file)
        try Data("{ not json".utf8).write(to: file)
        let run = try RunFixture.make(question: "Q1", finished: "2026-10-09T10:04:30.000Z")
        let threads = ThreadIndex.build(runs: [run])

        let state = UIState.loadOrSeed(in: brain, threads: threads)

        XCTAssertFalse(state.isUnread(question: "Q1", latestFinish: threads[0].latestFinish))
        XCTAssertEqual(UIState.load(in: brain), state)
    }

    func testAFileFromAnotherSchemaIsNotTrusted() throws {
        let brain = try makeTempProject()
        try Data(#"{"schema":"quorum.ui/9","read_at":{}}"#.utf8).write(to: brain.appendingPathComponent(UIState.file))
        let run = try RunFixture.make(question: "Q1")
        let threads = ThreadIndex.build(runs: [run])

        let state = UIState.loadOrSeed(in: brain, threads: threads)

        XCTAssertFalse(state.isUnread(question: "Q1", latestFinish: threads[0].latestFinish))
    }
}
