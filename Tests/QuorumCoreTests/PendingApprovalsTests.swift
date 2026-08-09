import XCTest
@testable import QuorumCore

/// Offers the run has left on the canvas, counted for the pill and announced once each. The wave never
/// waits on one, so the only way an offer gets seen is for the app to say it is there — and the only way
/// that stays bearable is for it to say it exactly once, and never while the person is already looking.
final class PendingApprovalsTests: XCTestCase {

    private func graph(pending: [(id: String, title: String)]) -> ResearchGraph {
        var graph = ResearchGraph.planning(question: "How should we price it?")
        graph.propose([ResearchAngle(id: "a1", title: "Competitor pricing", prompt: "look")])
        graph.approvePlan()
        for offer in pending {
            graph.insert(GraphNode(id: offer.id, kind: .question, title: offer.title,
                                   state: .asked(.pending), origin: .spawn, depth: 2))
            graph.connect(GraphEdge(from: "a1", to: offer.id, kind: .spawned))
        }
        return graph
    }

    func testAnEmptyFrontierHasNothingToSayAndNothingToShow() {
        var approvals = PendingApprovals()

        let alert = approvals.observe(graph(pending: []), appIsActive: false)

        XCTAssertNil(alert)
        XCTAssertEqual(approvals.count, 0)
        XCTAssertNil(approvals.pillLabel)
        XCTAssertFalse(approvals.showsBulkActions)
    }

    func testAPlannedAngleAwaitingApprovalIsNotAnOfferTheRunMade() {
        var planning = ResearchGraph.planning(question: "How should we price it?")
        planning.propose([ResearchAngle(id: "a1", title: "Competitor pricing", prompt: "look")])
        var approvals = PendingApprovals()

        let alert = approvals.observe(planning, appIsActive: false)

        XCTAssertNil(alert)
        XCTAssertEqual(approvals.count, 0)
    }

    func testAnOfferRaisedWhileNobodyIsLookingAnnouncesItself() {
        var approvals = PendingApprovals()

        let alert = approvals.observe(graph(pending: [("q1", "What did the 2024 filing say?")]),
                                      appIsActive: false)

        XCTAssertEqual(alert?.body, "What did the 2024 filing say?")
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.pillLabel, "1 waiting on you")
        XCTAssertFalse(approvals.showsBulkActions)
    }

    func testTheSameOfferIsAnnouncedOnceAndThenLeftAlone() {
        var approvals = PendingApprovals()
        let pending = graph(pending: [("q1", "What did the 2024 filing say?")])

        XCTAssertNotNil(approvals.observe(pending, appIsActive: false))
        XCTAssertNil(approvals.observe(pending, appIsActive: false))
    }

    func testAnOfferRaisedInFrontOfThePersonIsNotAlsoShoutedAtThem() {
        var approvals = PendingApprovals()
        let pending = graph(pending: [("q1", "What did the 2024 filing say?")])

        XCTAssertNil(approvals.observe(pending, appIsActive: true))
        XCTAssertEqual(approvals.count, 1)
        XCTAssertNil(approvals.observe(pending, appIsActive: false),
                     "they already saw it — walking away is not a reason to be told again")
    }

    func testASecondOfferIsWorthAnotherWordAndCountsBothOfThem() {
        var approvals = PendingApprovals()
        _ = approvals.observe(graph(pending: [("q1", "What did the 2024 filing say?")]), appIsActive: false)

        let alert = approvals.observe(graph(pending: [("q1", "What did the 2024 filing say?"),
                                                      ("q2", "Which tier did they drop?")]),
                                      appIsActive: false)

        XCTAssertEqual(alert?.body, "2 proposed inquiries are waiting on you")
        XCTAssertEqual(approvals.count, 2)
        XCTAssertEqual(approvals.pillLabel, "2 waiting on you")
        XCTAssertTrue(approvals.showsBulkActions)
    }

    func testAnOfferThatWasRuledOnLeavesTheCountAndThePill() {
        var approvals = PendingApprovals()
        var pending = graph(pending: [("q1", "What did the 2024 filing say?")])
        _ = approvals.observe(pending, appIsActive: false)

        pending.steer(.approve(id: "q1"))
        _ = approvals.observe(pending, appIsActive: false)

        XCTAssertEqual(approvals.count, 0)
        XCTAssertNil(approvals.pillLabel)
    }

    func testTheOffersAreHandedOverInTheOrderTheRunRaisedThem() {
        var approvals = PendingApprovals()
        _ = approvals.observe(graph(pending: [("q1", "first"), ("q2", "second")]), appIsActive: true)

        XCTAssertEqual(approvals.ids, ["q1", "q2"])
    }
}
