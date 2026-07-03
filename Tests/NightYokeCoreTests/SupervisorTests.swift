import XCTest
@testable import NightYokeCore

/// The supervisor exercised through the seam: the walls the CLI can't enforce itself.
final class SupervisorTests: XCTestCase {

    func testSpendWallHaltsAndKeepsLastPartial() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, runCap: 100,
                                   perTopicCap: Decimal(string: "0.50")!, deadline: nil)
        let exec = FakeExecutor(["only": FakeExecutor.spendWall(cost: Decimal(string: "0.90")!)])
        let report = await runBatch(config: config, topics: [Topic(id: "only", question: "Q")],
                                    executor: exec, clock: clock, store: DiskFindingsStore(),
                                    power: SpyPower(), notifier: SpyNotifier())

        let e = report.entries[0]
        XCTAssertEqual(e.status, .haltedSpend)
        XCTAssertEqual(e.headline, "Partial before spend halt")   // last onPartial preserved
        XCTAssertEqual(e.costUSD, Decimal(string: "0.90")!)
        XCTAssertEqual(e.note, "hit the per-topic spend wall — findings incomplete")
    }

    func testTimeWallHaltsAndKeepsLastPartial() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, perTopicCap: 100, timeout: .seconds(10), deadline: nil)
        let exec = FakeExecutor(["only": FakeExecutor.timeWall(clock, advanceBy: .seconds(20))]) // exceeds 10s
        let report = await runBatch(config: config, topics: [Topic(id: "only", question: "Q")],
                                    executor: exec, clock: clock, store: DiskFindingsStore(),
                                    power: SpyPower(), notifier: SpyNotifier())

        let e = report.entries[0]
        XCTAssertEqual(e.status, .haltedTime)
        XCTAssertEqual(e.headline, "Partial before time halt")
        XCTAssertEqual(e.sourcesConsulted, 1)
        XCTAssertEqual(e.note, "hit the per-topic time wall — findings incomplete")
    }

    func testCleanCompletionIsNotHalted() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, deadline: nil)
        let report = await runBatch(config: config, topics: [Topic(id: "only", question: "Q")],
                                    executor: FakeExecutor([:]), clock: clock,
                                    store: DiskFindingsStore(), power: SpyPower(), notifier: SpyNotifier())
        XCTAssertEqual(report.entries[0].status, .complete)
        XCTAssertEqual(report.entries[0].costUSD, Decimal(string: "0.10")!)
    }
}
