import XCTest
@testable import QuorumCore

final class EngineCommandTests: XCTestCase {

    private let store = URL(fileURLWithPath: "/Users/me/Quorum", isDirectory: true)

    func testARunIsAlwaysStartedDetachedInTheBrainFolder() {
        XCTAssertEqual(EngineCommand.detachedRun(store: store), ["run", "--detach", "--store", "/Users/me/Quorum"])
    }

    func testADevReplayRidesAlongOnTheDetachedRun() {
        XCTAssertEqual(EngineCommand.detachedRun(store: store, replay: "/fixtures/mock-run.ndjson"),
                       ["run", "--detach", "--store", "/Users/me/Quorum", "--replay", "/fixtures/mock-run.ndjson"])
    }

    func testCancelNamesTheRunAndTheStoreItLivesIn() {
        XCTAssertEqual(EngineCommand.cancel(runID: "01RUN", store: store), ["cancel", "01RUN", "--store", "/Users/me/Quorum"])
    }

    func testListAndDoctorAskTheEngineAboutTheStore() {
        XCTAssertEqual(EngineCommand.list(store: store), ["list", "--store", "/Users/me/Quorum"])
        XCTAssertEqual(EngineCommand.doctor(store: store), ["doctor", "--json", "--store", "/Users/me/Quorum"])
    }

    func testTheLaunchPutsItsOwnArgumentsFirst() {
        let launch = EngineLaunch(executable: "/usr/local/bin/bun", arguments: ["/repo/engine/src/index.ts"])

        XCTAssertEqual(launch.arguments(for: EngineCommand.cancel(runID: "R", store: store)),
                       ["/repo/engine/src/index.ts", "cancel", "R", "--store", "/Users/me/Quorum"])
    }

    func testRunCreatedNamesTheRunAndItsDirectory() {
        let stdout = #"{"type":"run.created","protocol_version":5,"question_id":"01Q","run_id":"01R","dir":"/Users/me/Quorum/questions/01Q/runs/01R","pid":4242}"# + "\n"

        guard case let .success(created) = EngineReply.runCreated(stdout) else { return XCTFail("expected a created run") }
        XCTAssertEqual(created, RunCreated(runID: "01R", questionID: "01Q",
                                           runDir: URL(fileURLWithPath: "/Users/me/Quorum/questions/01Q/runs/01R", isDirectory: true),
                                           pid: 4242))
    }

    func testAnEngineThatCouldNotStartTheRunSaysWhy() {
        let stdout = #"{"type":"error","error":"the engine did not start the run within 15s: no output"}"# + "\n"

        XCTAssertEqual(EngineReply.runCreated(stdout), .failure(EngineFailure(reason: "the engine did not start the run within 15s: no output")))
    }

    func testSilenceIsAFailureToo() {
        XCTAssertEqual(EngineReply.runCreated(""), .failure(EngineFailure(reason: "quorum-engine said nothing when asked to start the run")))
    }

    func testTheRunIndexListsEveryRunWithItsLiveness() {
        let stdout = """
        {"type":"run","question_id":"Q2","run_id":"R2","dir":"/b/questions/Q2/runs/R2","title":"Second","status":"running","created_at":"2026-10-10T09:00:00.000Z","updated_at":"2026-10-10T09:01:00.000Z","pid":777,"heartbeat_at":"2026-10-10T09:01:00.000Z","cost_usd":0.4}
        {"type":"run","question_id":"Q1","run_id":"R1","dir":"/b/questions/Q1/runs/R1","title":"First","status":"crashed","created_at":"2026-10-10T08:00:00.000Z","updated_at":"2026-10-10T08:02:00.000Z","cost_usd":0}
        garbage
        """

        let entries = EngineReply.runIndex(stdout)

        XCTAssertEqual(entries.map(\.runID), ["R2", "R1"])
        XCTAssertEqual(entries[0], RunIndexEntry(runID: "R2", questionID: "Q2", runDir: URL(fileURLWithPath: "/b/questions/Q2/runs/R2", isDirectory: true),
                                                title: "Second", status: "running", pid: 777))
        XCTAssertEqual(entries[1].status, "crashed")
    }

    func testOnlyRunningRunsNotAlreadyBeingWatchedAreReattached() {
        let entries = [
            RunIndexEntry(runID: "R1", questionID: "Q1", runDir: URL(fileURLWithPath: "/b/1"), title: "A", status: "running", pid: 1),
            RunIndexEntry(runID: "R2", questionID: "Q2", runDir: URL(fileURLWithPath: "/b/2"), title: "B", status: "running", pid: 2),
            RunIndexEntry(runID: "R3", questionID: "Q3", runDir: URL(fileURLWithPath: "/b/3"), title: "C", status: "crashed", pid: nil),
            RunIndexEntry(runID: "R4", questionID: "Q4", runDir: URL(fileURLWithPath: "/b/4"), title: "D", status: "complete", pid: nil),
        ]

        XCTAssertEqual(EngineReply.toReattach(entries, watching: ["R2"]).map(\.runID), ["R1"])
    }

    func testTheCancelReplySaysWhetherTheEngineWasReached() {
        XCTAssertNil(EngineReply.cancelled(#"{"ok":true,"run_id":"R","signalled":"group"}"#))
        XCTAssertEqual(EngineReply.cancelled(#"{"ok":false,"run_id":"R","error":"the run already finished as complete"}"#),
                       EngineFailure(reason: "the run already finished as complete"))
        XCTAssertEqual(EngineReply.cancelled(""), EngineFailure(reason: "quorum-engine said nothing when asked to cancel the run"))
    }

    func testTheDoctorReplyBecomesRowsWithTheirFixes() {
        let stdout = #"{"ok":false,"checks":[{"id":"claude_login","ok":false,"detail":"the claude CLI is not signed in","fix":"Run `claude` once and sign in."},{"id":"store","ok":true,"detail":"/b is writable","fix":null}]}"#

        XCTAssertEqual(EngineReply.doctor(stdout), [
            EngineDoctorCheck(id: "claude_login", ok: false, detail: "the claude CLI is not signed in", fix: "Run `claude` once and sign in."),
            EngineDoctorCheck(id: "store", ok: true, detail: "/b is writable", fix: nil),
        ])
    }
}
