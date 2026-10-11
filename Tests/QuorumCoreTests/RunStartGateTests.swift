import XCTest
@testable import QuorumCore

final class RunStartGateTests: XCTestCase {

    private func deeper(_ question: String = "Q1") -> RunStart {
        RunStart(question: "What is Bun?", brief: nil, tier: .deep, kind: .rerun, parentRunID: "R1", questionID: question)
    }

    private func fresh() -> RunStart { RunStart(question: "What is Bun?", brief: nil, tier: .quick) }

    func testASecondStartForTheSameQuestionIsRefusedWhileTheFirstIsStillStarting() {
        var gate = RunStartGate()
        XCTAssertTrue(gate.begin(deeper(), runningQuestions: []))
        XCTAssertFalse(gate.begin(deeper(), runningQuestions: []))
        XCTAssertTrue(gate.isPending(question: "Q1"))
    }

    func testFinishingAStartLetsTheQuestionStartAgain() {
        var gate = RunStartGate()
        XCTAssertTrue(gate.begin(deeper(), runningQuestions: []))
        gate.finish(deeper())
        XCTAssertFalse(gate.isPending(question: "Q1"))
        XCTAssertTrue(gate.begin(deeper(), runningQuestions: []))
    }

    func testOtherQuestionsAreNotBlocked() {
        var gate = RunStartGate()
        XCTAssertTrue(gate.begin(deeper("Q1"), runningQuestions: []))
        XCTAssertTrue(gate.begin(deeper("Q2"), runningQuestions: []))
    }

    func testAQuestionThatIsAlreadyRunningRefusesAnotherStart() {
        var gate = RunStartGate()
        XCTAssertFalse(gate.begin(deeper("Q1"), runningQuestions: ["Q1"]))
        XCTAssertFalse(gate.isPending(question: "Q1"))
    }

    func testOnlyOneNewQuestionIsStartedAtATime() {
        var gate = RunStartGate()
        XCTAssertTrue(gate.begin(fresh(), runningQuestions: []))
        XCTAssertFalse(gate.begin(fresh(), runningQuestions: ["Q9"]))
        gate.finish(fresh())
        XCTAssertTrue(gate.begin(fresh(), runningQuestions: []))
    }
}

final class AttachPlanTests: XCTestCase {

    func testAThreadStartNeverTouchesTheComposerDraft() {
        let plan = AttachPlan.decide(origin: .thread("Q1"), selectionAtStart: .question("Q1"), selectionNow: .question("Q1"))
        XCTAssertFalse(plan.resetComposer)
        XCTAssertTrue(plan.select)
    }

    func testAComposerStartConsumesTheComposerAndOpensTheNewQuestion() {
        let plan = AttachPlan.decide(origin: .composer, selectionAtStart: .new, selectionNow: .new)
        XCTAssertTrue(plan.resetComposer)
        XCTAssertTrue(plan.select)
    }

    func testSelectionStaysWhereTheUserWentWhileTheRunWasStarting() {
        let thread = AttachPlan.decide(origin: .thread("Q1"), selectionAtStart: .question("Q1"), selectionNow: .question("Q7"))
        XCTAssertFalse(thread.select)
        XCTAssertFalse(thread.resetComposer)
        let composer = AttachPlan.decide(origin: .composer, selectionAtStart: .new, selectionNow: .question("Q7"))
        XCTAssertFalse(composer.select)
        XCTAssertTrue(composer.resetComposer)
    }
}

final class FollowUpRequestsTests: XCTestCase {

    func testASeedAndTheFocusRequestBelongToOneQuestion() {
        var requests = FollowUpRequests()
        requests.request(question: "Q1", seed: "Resolve this conflict: x")
        XCTAssertEqual(requests.count(for: "Q1"), 1)
        XCTAssertEqual(requests.count(for: "Q2"), 0)
        XCTAssertNil(requests.takeSeed(for: "Q2"))
        XCTAssertEqual(requests.takeSeed(for: "Q1"), "Resolve this conflict: x")
        XCTAssertNil(requests.takeSeed(for: "Q1"))
    }

    func testAskingForFocusAgainBumpsOnlyThatQuestionsCounter() {
        var requests = FollowUpRequests()
        requests.request(question: "Q1")
        requests.request(question: "Q1")
        requests.request(question: "Q2")
        XCTAssertEqual(requests.count(for: "Q1"), 2)
        XCTAssertEqual(requests.count(for: "Q2"), 1)
    }
}

final class ExpiringTests: XCTestCase {

    func testAValueIsReusedUntilItsTimeToLiveRunsOut() {
        var cache = Expiring<String>(ttl: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(cache.value(at: start))
        cache.store("ok", at: start)
        XCTAssertEqual(cache.value(at: start.addingTimeInterval(29)), "ok")
        XCTAssertNil(cache.value(at: start.addingTimeInterval(31)))
    }

    func testInvalidatingForgetsTheValueAtOnce() {
        var cache = Expiring<Int>(ttl: 30)
        let start = Date(timeIntervalSince1970: 1_000)
        cache.store(1, at: start)
        cache.invalidate()
        XCTAssertNil(cache.value(at: start))
    }
}
