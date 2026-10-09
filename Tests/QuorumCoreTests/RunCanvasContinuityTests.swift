import XCTest
@testable import QuorumCore

/// One canvas, from the angles being suggested to the answer being judged. The cards a reader edited are
/// the cards that then run: the engine names an angle by the id the plan gave it, so its node grows a
/// state instead of a second node appearing beside it. The paths that grow no graph of their own — the
/// in-process fallback, a replay from disk — put what they do know on that same surface.
final class RunCanvasContinuityTests: XCTestCase {

    private func plannedGraph(_ angles: [ResearchAngle]) -> ResearchGraph {
        var graph = ResearchGraph.planning(question: "Where should we host?", angleCount: angles.count)
        graph.propose(angles, costCeilingUSD: 8)
        return graph
    }

    private func inquiryEvent(_ id: String, title: String, status: String = "queued")
        -> RunStreamParser.Event {
        .graphNode(RunStreamParser.GraphNodeEvent(
            id: id, kind: "inquiry", title: title, parentIDs: [], depth: 1, round: 1,
            status: status, origin: "planner", why: nil, provokedBy: nil, rejectedReason: nil,
            estimatedCostUSD: nil, costUSD: nil, lens: nil, objections: []))
    }

    func testTheEngineNamingAnApprovedAngleGrowsItsCardRatherThanDrawingASecondOne() {
        let angles = [ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing"),
                      ResearchAngle(id: "a2", title: "Latency", prompt: "compare regions")]
        var graph = plannedGraph(angles)
        graph.approvePlan()

        graph.apply(inquiryEvent("a1", title: "Cost"))
        graph.apply(inquiryEvent("a2", title: "Latency"))

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1", "a2"])
        XCTAssertEqual(graph.edges.filter { $0.kind == .decomposes }.count, 2)
    }

    func testApprovingThePlanLeavesTheAnglesAsQueuedWorkOnTheSameCanvas() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing")])
        graph.approvePlan()

        XCTAssertEqual(graph.node("a1")?.state, .worked(.queued))
        XCTAssertTrue(graph.proposedAngles.isEmpty)
        XCTAssertEqual(graph.node(ResearchGraph.rootID)?.state, .asked(.approved))
    }

    func testARunNobodyIsNarratingStillSaysWhichAngleIsWorking() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing")])
        graph.approvePlan()

        graph.mark("a1", .running)
        XCTAssertEqual(graph.node("a1")?.state, .worked(.running))

        graph.mark("a1", .complete)
        XCTAssertEqual(graph.node("a1")?.state, .worked(.complete))
    }

    func testMarkingIgnoresAnIdTheCanvasNeverDrew() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing")])
        graph.mark("nope", .running)
        XCTAssertNil(graph.node("nope"))
    }

    func testTheSynthesisJoinsTheCanvasFedByTheAnglesItReconciles() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p"),
                                  ResearchAngle(id: "a2", title: "Latency", prompt: "p")])
        graph.approvePlan()

        graph.stageSynthesis(feeding: ["a1", "a2"], round: 1)

        let synthesis = graph.nodes(of: .synthesis)
        XCTAssertEqual(synthesis.count, 1)
        XCTAssertEqual(synthesis.first?.id, "synthesis")   // the engine's own word for it
        XCTAssertEqual(synthesis.first?.state, .worked(.running))
        XCTAssertEqual(graph.edges.filter { $0.kind == .synthesizes }.map(\.from), ["a1", "a2"])
        XCTAssertGreaterThan(synthesis.first?.depth ?? 0, 1)
    }

    func testTheSynthesisIsStagedOncePerRoundHoweverOftenThePhaseIsRepeated() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])
        graph.approvePlan()

        graph.stageSynthesis(feeding: ["a1"], round: 1)
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.edges.filter { $0.kind == .synthesizes }.count, 1)
    }

    /// The engine re-announces the one answer node each round rather than hanging a second answer beside
    /// it, so a round staged here does the same: one node, one more wire into it.
    func testALaterRoundFeedsTheSameAnswerNode() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])
        graph.approvePlan()
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        graph.mark("a2", .queued)
        graph.stageSynthesis(feeding: ["a1", "a2"], round: 2)

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.nodes(of: .synthesis).first?.id, "synthesis")
    }

    /// The engine announces the question before it announces the angles under it. Folded onto the graph the
    /// plan was approved on, that opening must not empty the canvas for the frames in between: the reader
    /// watches the cards they just edited start working, and a card that blinks out has been re-drawn.
    func testTheEngineOpeningItsOwnNarrationNeverEmptiesTheApprovedCanvas() {
        let angles = [ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing"),
                      ResearchAngle(id: "a2", title: "Latency", prompt: "compare regions")]
        var graph = plannedGraph(angles)
        graph.approvePlan()

        let opening: [RunStreamParser.Event] = [
            .runStart(sessionID: "s", protocolVersion: 4, grounding: .captured),
            .phase("planning"),
            .plan(angles.map { .init(angleID: $0.id, title: $0.title, prompt: $0.prompt) }),
            .graphNode(RunStreamParser.GraphNodeEvent(
                id: ResearchGraph.rootID, kind: "question", title: "Where should we host?", parentIDs: [],
                depth: 0, round: 1, status: "approved", origin: "root", why: nil, provokedBy: nil,
                rejectedReason: nil, estimatedCostUSD: nil, costUSD: nil, lens: nil, objections: [])),
            inquiryEvent("a1", title: "Cost"),
            inquiryEvent("a2", title: "Latency"),
            .angleStatus(angleID: "a1", status: "running"),
        ]

        for event in opening {
            graph.apply(event)
            XCTAssertNotNil(graph.node(ResearchGraph.rootID), "the question after \(event)")
            XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1", "a2"], "the angles after \(event)")
        }
        XCTAssertEqual(graph.node("a1")?.state, .worked(.running))
    }

    /// A run that says it is writing its answer has an answer node, from that word alone. The fold stages it
    /// too — not just the app above the fold — because the fold is what replaces the canvas on every event,
    /// and a node only the app staged would blink out on the next line the engine sends.
    func testTheRunSayingItIsWritingTheAnswerPutsTheAnswerOnTheCanvas() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p"),
                                  ResearchAngle(id: "a2", title: "Latency", prompt: "p")])
        graph.approvePlan()

        graph.apply(.phase("synthesizing"))

        XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["synthesis"])
        XCTAssertEqual(graph.edges.filter { $0.kind == .synthesizes }.map(\.from), ["a1", "a2"])
    }

    /// Reconciling is the same stretch of the run under the engine's other word for it, and a run with no
    /// angles yet has nothing to reconcile — neither should draw a stray answer node.
    func testOnlyAnAnswerBeingWrittenStagesOne() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])
        graph.approvePlan()

        graph.apply(.phase("researching"))
        XCTAssertTrue(graph.nodes(of: .synthesis).isEmpty)

        graph.apply(.phase("reconciling"))
        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)

        var empty = ResearchGraph.planning(question: "q")
        empty.apply(.phase("synthesizing"))
        XCTAssertTrue(empty.nodes(of: .synthesis).isEmpty)
    }

    /// The engine narrates its own synthesis, and it uses the same id — so the node the app staged is the
    /// node the engine then updates, never a duplicate under a different name.
    func testTheEngineOwnSynthesisLandsOnTheStagedNode() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])
        graph.approvePlan()
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        graph.apply(.graphNodeUpdate(id: "synthesis", status: "complete", costUSD: 2))

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.nodes(of: .synthesis).first?.state, .worked(.complete))
    }
}
