import XCTest
@testable import QuorumCore

final class BrainSnapshotTests: XCTestCase {

    private func brain() throws -> URL {
        let brain = try makeTempProject()
        let record = try Data(contentsOf: EngineFixtures.url("record/validated.run.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        let question = try XCTUnwrap(object["question_id"] as? String)
        let run = try XCTUnwrap(object["id"] as? String)
        let dir = brain.appendingPathComponent("questions/\(question)/runs/\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try record.write(to: dir.appendingPathComponent("run.json"))
        let answers = brain.appendingPathComponent("answers", isDirectory: true)
        try FileManager.default.createDirectory(at: answers, withIntermediateDirectories: true)
        try Data("# x".utf8).write(to: answers.appendingPathComponent("title-\(question.suffix(5).lowercased()).md"))
        return brain
    }

    func testOneLoadGivesTheThreadsTheReadStateAndTheExports() throws {
        let brain = try brain()

        let snapshot = BrainSnapshot.load(brain: brain)

        XCTAssertEqual(snapshot.threads.count, 1)
        let thread = try XCTUnwrap(snapshot.threads.first)
        XCTAssertEqual(snapshot.exports[thread.id]?.pathExtension, "md")
        XCTAssertFalse(snapshot.ui.isUnread(question: thread.id, latestFinish: thread.latestFinish))
        XCTAssertTrue(snapshot.unreadable.isEmpty)
    }

    func testAQuestionWithoutAnExportHasNoEntry() throws {
        let brain = try brain()
        try FileManager.default.removeItem(at: brain.appendingPathComponent("answers"))

        XCTAssertTrue(BrainSnapshot.load(brain: brain).exports.isEmpty)
    }

    func testAnEmptyFolderLoadsAsAnEmptyBrain() throws {
        let snapshot = BrainSnapshot.load(brain: try makeTempProject())
        XCTAssertTrue(snapshot.threads.isEmpty)
        XCTAssertTrue(snapshot.runs.isEmpty)
    }

    func testRunsTheAppCannotOpenBecomeRowsThatSayWhy() {
        let old = UnreadableRun(runDir: URL(fileURLWithPath: "/b/questions/Q2/runs/R2"), reason: .needsUpgrade(from: "quorum.run/1"))
        let newer = UnreadableRun(runDir: URL(fileURLWithPath: "/b/questions/Q3/runs/R3"), reason: .newerThanThisApp(schema: "quorum.run/9"))
        let broken = UnreadableRun(runDir: URL(fileURLWithPath: "/b/questions/Q4/runs/R4"), reason: .undecodable)

        let rows = Inbox.unreadableRows([old, newer, broken])

        XCTAssertEqual(rows.map(\.title), ["Q2", "Q3", "Q4"])
        XCTAssertEqual(rows.map(\.reason), ["Waiting for an upgrade", "Needs a newer Quorum", "Couldn't open"])
        XCTAssertEqual(rows[1].explanation, newer.explanation)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }
}
