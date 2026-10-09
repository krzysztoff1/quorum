import XCTest
@testable import QuorumCore

final class RunCanvasContinuityTests: XCTestCase {

    private func plannedGraph(_ angles: [ResearchAngle]) -> ResearchGraph {
        ResearchGraph.staged(angles: angles)
    }

    private func inquiryEvent(_ id: String, title: String, status: String = "queued")
        -> RunStreamParser.Event {
        .graphNode(RunStreamParser.GraphNodeEvent(
            id: id, kind: "inquiry", title: title, parentIDs: [], depth: 1, round: 1,
            status: status, origin: "planner", why: nil, provokedBy: nil, rejectedReason: nil,
            estimatedCostUSD: nil, costUSD: nil, lens: nil, objections: []))
    }

    func testTheEngineNamingAPlannedAngleGrowsItsCardRatherThanDrawingASecondOne() {
        let angles = [ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing"),
                      ResearchAngle(id: "a2", title: "Latency", prompt: "compare regions")]
        var graph = plannedGraph(angles)

        graph.apply(inquiryEvent("a1", title: "Cost"))
        graph.apply(inquiryEvent("a2", title: "Latency"))

        XCTAssertEqual(graph.nodes.count, 3)
        XCTAssertEqual(graph.nodes(of: .inquiry).map(\.id), ["a1", "a2"])
        XCTAssertEqual(graph.edges.filter { $0.kind == .decomposes }.count, 2)
    }

    func testAnAngleStatusForAnIdTheCanvasNeverDrewIsIgnored() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing")])
        graph.apply(.angleStatus(angleID: "nope", status: "running"))
        XCTAssertNil(graph.node("nope"))
        XCTAssertEqual(graph.node("a1")?.state, .worked(.queued))
    }

    func testTheSynthesisJoinsTheCanvasFedByTheAnglesItReconciles() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p"),
                                  ResearchAngle(id: "a2", title: "Latency", prompt: "p")])

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

        graph.stageSynthesis(feeding: ["a1"], round: 1)
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.edges.filter { $0.kind == .synthesizes }.count, 1)
    }

    /// The engine re-announces the one answer node each round rather than hanging a second answer beside
    /// it, so a round staged here does the same: one node, one more wire into it.
    func testALaterRoundFeedsTheSameAnswerNode() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        graph.stageSynthesis(feeding: ["a1"], round: 2)

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.nodes(of: .synthesis).first?.id, "synthesis")
    }

    func testTheEngineOpeningItsOwnNarrationNeverEmptiesTheCanvas() {
        let angles = [ResearchAngle(id: "a1", title: "Cost", prompt: "compare pricing"),
                      ResearchAngle(id: "a2", title: "Latency", prompt: "compare regions")]
        var graph = plannedGraph(angles)

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

        graph.apply(.phase("synthesizing"))

        XCTAssertEqual(graph.nodes(of: .synthesis).map(\.id), ["synthesis"])
        XCTAssertEqual(graph.edges.filter { $0.kind == .synthesizes }.map(\.from), ["a1", "a2"])
    }

    /// Reconciling is the same stretch of the run under the engine's other word for it, and a run with no
    /// angles yet has nothing to reconcile — neither should draw a stray answer node.
    func testOnlyAnAnswerBeingWrittenStagesOne() {
        var graph = plannedGraph([ResearchAngle(id: "a1", title: "Cost", prompt: "p")])

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
        graph.stageSynthesis(feeding: ["a1"], round: 1)

        graph.apply(.graphNodeUpdate(id: "synthesis", status: "complete", costUSD: 2))

        XCTAssertEqual(graph.nodes(of: .synthesis).count, 1)
        XCTAssertEqual(graph.nodes(of: .synthesis).first?.state, .worked(.complete))
    }
}
