import XCTest
@testable import NightYokeCore

final class MapperTests: XCTestCase {

    func testPresetsMapToExpectedEffort() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).effort, .low)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).effort, .high)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).effort, .xhigh)
        XCTAssertEqual(GuardrailMapper.spec(for: .max).effort, .max)
    }

    func testPresetsMapToExpectedSourceBudget() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).sourceBudget, 5)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).sourceBudget, 15)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).sourceBudget, 30)
        XCTAssertGreaterThanOrEqual(GuardrailMapper.spec(for: .max).sourceBudget, 50)
    }

    func testDraftIsScanRestThorough() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).depth, .scan)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).depth, .thorough)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).depth, .thorough)
        XCTAssertEqual(GuardrailMapper.spec(for: .max).depth, .thorough)
    }

    func testAllowlistIsReadOnlyNeverAWriteTool() {
        let cfg = GuardrailMapper.runConfig(preset: .standard, perTopicSpendCap: 1,
                                            perTopicTimeout: .seconds(60), depthOverride: nil)
        let forbidden = ["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash"]
        for tool in cfg.allowedTools {
            XCTAssertFalse(forbidden.contains(tool), "\(tool) must never be allowed in a research run")
        }
        // and it does grant the read-only trio it needs
        XCTAssertTrue(cfg.allowedTools.contains("WebSearch"))
        XCTAssertTrue(cfg.allowedTools.contains("WebFetch"))
        XCTAssertTrue(cfg.allowedTools.contains("Read"))
    }

    func testEveryPresetProducesReadOnlyAllowlist() {
        for preset in EffortPreset.allCases {
            let cfg = GuardrailMapper.runConfig(preset: preset, perTopicSpendCap: 1,
                                                perTopicTimeout: .seconds(60), depthOverride: nil)
            XCTAssertFalse(cfg.allowedTools.contains("Write"))
            XCTAssertFalse(cfg.allowedTools.contains("Bash"))
        }
    }

    func testPerTopicPresetOverrideBeatsNightDefault() {
        let run = standardRun(project: URL(fileURLWithPath: "/tmp/x"), preset: .standard)
        let topic = Topic(id: "t", question: "Q", presetOverride: .max)
        let prepared = GuardrailMapper.prepare(topic: topic, run: run)
        XCTAssertEqual(prepared.preset, .max)
        XCTAssertEqual(prepared.runConfig.effort, .max)
    }

    func testNightDefaultUsedWhenNoOverride() {
        let run = standardRun(project: URL(fileURLWithPath: "/tmp/x"), preset: .deep)
        let prepared = GuardrailMapper.prepare(topic: Topic(question: "Q"), run: run)
        XCTAssertEqual(prepared.preset, .deep)
        XCTAssertEqual(prepared.runConfig.effort, .xhigh)
    }

    func testPerTopicDepthOverride() {
        let run = standardRun(project: URL(fileURLWithPath: "/tmp/x"), preset: .standard) // default depth thorough
        let topic = Topic(question: "Q", depth: .scan)
        let prepared = GuardrailMapper.prepare(topic: topic, run: run)
        XCTAssertEqual(prepared.runConfig.depth, .scan)
    }

    func testMaxTurnsBackstopScalesWithEffort() {
        XCTAssertLessThan(GuardrailMapper.spec(for: .draft).maxTurns,
                          GuardrailMapper.spec(for: .max).maxTurns)
        XCTAssertGreaterThan(GuardrailMapper.spec(for: .draft).maxTurns, 0)
    }

    func testCapsAndProjectFlowThrough() {
        let project = URL(fileURLWithPath: "/tmp/proj")
        let run = standardRun(project: project, perTopicCap: Decimal(string: "0.75")!, timeout: .seconds(120))
        let prepared = GuardrailMapper.prepare(topic: Topic(question: "Q", useProjectContext: true), run: run)
        XCTAssertEqual(prepared.runConfig.perTopicSpendCapUSD, Decimal(string: "0.75")!)
        XCTAssertEqual(prepared.runConfig.perTopicTimeout, .seconds(120))
        XCTAssertEqual(prepared.projectURL, project)
        XCTAssertTrue(prepared.useProjectContext)
    }
}
