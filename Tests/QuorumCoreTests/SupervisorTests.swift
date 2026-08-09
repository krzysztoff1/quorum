import XCTest
@testable import QuorumCore

/// The supervisor exercised through the seam every run path shares: the walls the CLI can't enforce itself.
final class SupervisorTests: XCTestCase {

    private func supervised(config: RunSettings, behavior: @escaping FakeExecutor.Behavior,
                            clock: TestClock) async -> TopicFindings {
        let prepared = GuardrailMapper.prepare(topic: Topic(id: "only", question: "Q"), run: config)
        let outcome = await Supervisor.supervise(prepared, executor: FakeExecutor(["only": behavior]),
                                                 clock: clock, runSpent: 0, runCap: config.runSpendCapUSD,
                                                 startedAt: clock.now())
        return outcome.findings
    }

    func testSpendWallHaltsAndKeepsLastPartial() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, runCap: 100,
                                 perTopicCap: Decimal(string: "0.50")!, deadline: nil)
        let findings = await supervised(config: config,
                                        behavior: FakeExecutor.spendWall(cost: Decimal(string: "0.90")!),
                                        clock: clock)

        XCTAssertEqual(findings.status, .haltedSpend)
        XCTAssertEqual(findings.headline, "Partial before spend halt")   // last onPartial preserved
        XCTAssertEqual(findings.costUSD, Decimal(string: "0.90")!)
        XCTAssertEqual(findings.note, "hit the per-topic spend wall — findings incomplete")
    }

    func testTimeWallHaltsAndKeepsLastPartial() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let config = standardRun(project: project, perTopicCap: 100, timeout: .seconds(10), deadline: nil)
        let findings = await supervised(config: config,
                                        behavior: FakeExecutor.timeWall(clock, advanceBy: .seconds(20)),
                                        clock: clock)

        XCTAssertEqual(findings.status, .haltedTime)
        XCTAssertEqual(findings.headline, "Partial before time halt")
        XCTAssertEqual(findings.sourcesConsulted, 1)
        XCTAssertEqual(findings.note, "hit the per-topic time wall — findings incomplete")
    }

    func testCleanCompletionIsNotHalted() async throws {
        let project = try makeTempProject()
        let clock = TestClock(now: fixedStart)
        let findings = await supervised(config: standardRun(project: project, deadline: nil),
                                        behavior: FakeExecutor.completing(), clock: clock)
        XCTAssertEqual(findings.status, .complete)
        XCTAssertEqual(findings.costUSD, Decimal(string: "0.10")!)
    }
}
