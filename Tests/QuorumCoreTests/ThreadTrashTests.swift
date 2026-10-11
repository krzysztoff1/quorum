import XCTest
@testable import QuorumCore

final class ThreadTrashTests: XCTestCase {

    private func brainWith(question: String, status: String) throws -> (URL, QuestionThread) {
        let brain = try makeTempProject()
        let run = try RunFixture.make(question: question, run: "R1", status: status)
        let questionDir = brain.appendingPathComponent("questions/\(question)", isDirectory: true)
        try FileManager.default.createDirectory(at: questionDir.appendingPathComponent("runs/R1"), withIntermediateDirectories: true)
        let answers = brain.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try Data("# a".utf8).write(to: answers.appendingPathComponent("a-title-\(question.suffix(5).lowercased()).md"))
        try Data("# b".utf8).write(to: answers.appendingPathComponent("b-other-zzzzz.md"))
        let stored = StoredRun(runDir: questionDir.appendingPathComponent("runs/R1"), record: run.record, question: run.question)
        return (brain, QuestionThread(id: question, runs: [stored]))
    }

    func testAFinishedThreadIsTrashedAndItsExportGoesWithIt() async throws {
        let (brain, thread) = try brainWith(question: "QQQQQ12345", status: "complete")
        var trashed: [URL] = []

        let outcome = await ThreadTrash.perform(thread: thread, brain: brain, stop: { _ in XCTFail("nothing to stop") },
                                                isStillRunning: { _ in false }, trash: { trashed.append($0) }, pause: {})

        XCTAssertEqual(outcome, .trashed)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["QQQQQ12345"])
        XCTAssertNil(AnswerExport.url(forQuestion: "QQQQQ12345", in: brain))
        XCTAssertNotNil(AnswerExport.url(forQuestion: "ZZZZZ", in: brain), "another question's export stays")
    }

    func testARunningThreadIsStoppedAndTheFolderIsOnlyTrashedOnceTheRecordIsNoLongerRunning() async throws {
        let (brain, thread) = try brainWith(question: "QQQQQ12345", status: "running")
        var stopped: [String] = []
        var polls = 0
        var trashedAtPoll: Int?

        let outcome = await ThreadTrash.perform(thread: thread, brain: brain, stop: { stopped.append($0) },
                                                isStillRunning: { _ in polls += 1; return polls < 3 },
                                                trash: { _ in trashedAtPoll = polls }, pause: {})

        XCTAssertEqual(outcome, .trashed)
        XCTAssertEqual(stopped, ["R1"])
        XCTAssertEqual(trashedAtPoll, 3)
    }

    func testARunThatWillNotStopLeavesTheThreadAlone() async throws {
        let (brain, thread) = try brainWith(question: "QQQQQ12345", status: "running")
        var trashed = false

        let outcome = await ThreadTrash.perform(thread: thread, brain: brain, stop: { _ in },
                                                isStillRunning: { _ in true }, trash: { _ in trashed = true }, pause: {}, attempts: 5)

        XCTAssertEqual(outcome, .stillRunning)
        XCTAssertFalse(trashed)
        XCTAssertNotNil(AnswerExport.url(forQuestion: "QQQQQ12345", in: brain))
    }

    func testAFailedTrashKeepsTheExport() async throws {
        let (brain, thread) = try brainWith(question: "QQQQQ12345", status: "complete")

        let outcome = await ThreadTrash.perform(thread: thread, brain: brain, stop: { _ in }, isStillRunning: { _ in false },
                                                trash: { _ in throw CocoaError(.fileWriteNoPermission) }, pause: {})

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(AnswerExport.url(forQuestion: "QQQQQ12345", in: brain))
    }
}
