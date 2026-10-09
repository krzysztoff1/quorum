import XCTest
@testable import QuorumCore

final class MapperTests: XCTestCase {

    func testPresetsMapToExpectedEffort() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).effort, .low)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).effort, .medium)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).effort, .xhigh)
        XCTAssertEqual(GuardrailMapper.spec(for: .max).effort, .max)
    }

    func testPresetsMapToExpectedSourceBudget() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).sourceBudget, 5)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).sourceBudget, 10)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).sourceBudget, 30)
        XCTAssertGreaterThanOrEqual(GuardrailMapper.spec(for: .max).sourceBudget, 50)
    }

    func testPresetsMapToExpectedSpendCaps() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).perTopicSpendCapUSD, Decimal(string: "0.15")!)
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).runSpendCapUSD, 1)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).perTopicSpendCapUSD, 10)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).runSpendCapUSD, 40)
        for preset in EffortPreset.allCases {
            let s = GuardrailMapper.spec(for: preset)
            XCTAssertLessThan(s.perTopicSpendCapUSD, s.runSpendCapUSD)
        }
        XCTAssertLessThan(GuardrailMapper.spec(for: .draft).perTopicSpendCapUSD,
                          GuardrailMapper.spec(for: .standard).perTopicSpendCapUSD)
        XCTAssertLessThan(GuardrailMapper.spec(for: .standard).perTopicSpendCapUSD,
                          GuardrailMapper.spec(for: .deep).perTopicSpendCapUSD)
        XCTAssertLessThan(GuardrailMapper.spec(for: .deep).perTopicSpendCapUSD,
                          GuardrailMapper.spec(for: .max).perTopicSpendCapUSD)
    }

    func testDraftIsScanRestThorough() {
        XCTAssertEqual(GuardrailMapper.spec(for: .draft).depth, .scan)
        XCTAssertEqual(GuardrailMapper.spec(for: .standard).depth, .thorough)
        XCTAssertEqual(GuardrailMapper.spec(for: .deep).depth, .thorough)
        XCTAssertEqual(GuardrailMapper.spec(for: .max).depth, .thorough)
    }

    func testMaxTurnsBackstopScalesWithEffort() {
        XCTAssertLessThan(GuardrailMapper.spec(for: .draft).maxTurns,
                          GuardrailMapper.spec(for: .max).maxTurns)
        XCTAssertGreaterThan(GuardrailMapper.spec(for: .draft).maxTurns, 0)
    }

    /// The number the composer promises before a cent is spent: every angle plus the synthesis at their own
    /// cap, and never past the run's.
    func testTheCostCeilingCountsTheSynthesisAndStopsAtTheRunCap() {
        XCTAssertEqual(GuardrailMapper.runCostCeiling(angles: 2, perTopicCapUSD: 10, runCapUSD: 40), 30)
        XCTAssertEqual(GuardrailMapper.runCostCeiling(angles: 5, perTopicCapUSD: 10, runCapUSD: 40), 40)
        XCTAssertEqual(GuardrailMapper.runCostCeiling(angles: 0, perTopicCapUSD: 10, runCapUSD: 40), 0)
    }
}
