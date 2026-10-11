import XCTest
@testable import QuorumCore

final class RunConfigTests: XCTestCase {

    private func json(_ start: RunStart, store: String = "/tmp/brain") throws -> [String: Any] {
        let config = EngineRunConfig(start: start, brainDir: URL(fileURLWithPath: store), deadlineSeconds: 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
    }

    private func brief(tier: Tier = .quick) -> Brief {
        Brief(asked: "waht is bun", question: "What is Bun?", title: "Bun", language: "en", tier: tier,
              suggestedTier: .quick, tierReason: "", clarifications: [])
    }

    func testANewQuestionCarriesItsBriefAndTierAndNothingAboutAThread() throws {
        let sent = try json(RunStart(question: "What is Bun?", brief: brief(), tier: .quick))
        XCTAssertEqual(sent["question"] as? String, "What is Bun?")
        XCTAssertEqual(sent["tier"] as? String, "quick")
        XCTAssertEqual(sent["kind"] as? String, "initial")
        XCTAssertEqual(sent["brainDir"] as? String, "/tmp/brain")
        XCTAssertNil(sent["parent_run_id"])
        XCTAssertNil(sent["question_id"])
        XCTAssertNotNil(sent["brief"])
    }

    func testAFollowUpNamesItsParentAndItsThread() throws {
        let start = RunStart(question: "and for B2B?", brief: nil, tier: .quick, kind: .followup, parentRunID: "R1", questionID: "Q1")
        let sent = try json(start)
        XCTAssertEqual(sent["kind"] as? String, "followup")
        XCTAssertEqual(sent["parent_run_id"] as? String, "R1")
        XCTAssertEqual(sent["question_id"] as? String, "Q1")
        XCTAssertEqual(sent["tier"] as? String, "quick")
    }

    func testGoingDeeperReRunsTheSameQuestionAsDeep() throws {
        let start = RunStart(question: "What is Bun?", brief: brief(tier: .deep), tier: .deep, kind: .rerun, parentRunID: "R1", questionID: "Q1")
        let sent = try json(start)
        XCTAssertEqual(sent["kind"] as? String, "rerun")
        XCTAssertEqual(sent["tier"] as? String, "deep")
        XCTAssertEqual((sent["brief"] as? [String: Any])?["tier"] as? String, "deep")
    }

    func testTheDepthPicksTheAnglesAndRoundsNotAPreset() throws {
        let quick = TierPlan.plan(for: .quick)
        let deep = TierPlan.plan(for: .deep)
        XCTAssertEqual(quick.angleCount, 3)
        XCTAssertEqual(deep.angleCount, 5)
        XCTAssertLessThan(quick.rounds, deep.rounds)
        let sent = try json(RunStart(question: "q", brief: nil, tier: .deep))
        XCTAssertEqual(sent["angleCount"] as? Int, 5)
        XCTAssertEqual(sent["rounds"] as? Int, deep.rounds)
    }

    func testARunWithADeadlineCarriesItInSeconds() throws {
        let config = EngineRunConfig(start: RunStart(question: "q", brief: nil, tier: .quick), brainDir: URL(fileURLWithPath: "/tmp"), deadlineSeconds: 900)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
        XCTAssertEqual(sent["runDeadlineSec"] as? Int, 900)
    }

    func testTheClarificationsOfARunStartedWithoutABriefAreSent() throws {
        let start = RunStart(question: "q", brief: nil, tier: .quick, clarifications: [Clarification(question: "Which?", answer: "This")])
        let sent = try json(start)
        XCTAssertEqual((sent["clarifications"] as? [[String: Any]])?.first?["answer"] as? String, "This")
    }
}

final class EngineCapabilitiesTests: XCTestCase {

    func testThreadsAreAvailableOnlyWhenDoctorSaysTheEngineSupportsThem() {
        let supported = [EngineDoctorCheck(id: "threads", ok: true, detail: "kind and parent_run_id", fix: nil)]
        XCTAssertTrue(EngineCapabilities(checks: supported).threads)
        XCTAssertFalse(EngineCapabilities(checks: [EngineDoctorCheck(id: "threads", ok: false, detail: "", fix: nil)]).threads)
        XCTAssertFalse(EngineCapabilities(checks: []).threads)
        XCTAssertFalse(EngineCapabilities(checks: [EngineDoctorCheck(id: "store", ok: true, detail: "", fix: nil)]).threads)
    }
}
