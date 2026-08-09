import XCTest
@testable import QuorumCore

final class QuickSwitchTests: XCTestCase {

    func testEmptyQueryMatchesEverythingAtBaseScore() {
        XCTAssertEqual(QuickSwitch.score("", "New run"), 0)
        XCTAssertEqual(QuickSwitch.score("   ", "anything at all"), 0)
    }

    func testPrefixBeatsWordBoundaryBeatsSubstring() {
        XCTAssertEqual(QuickSwitch.score("new", "New run"), 0)   // title prefix
        XCTAssertEqual(QuickSwitch.score("run", "New run"), 1)   // after a space
        XCTAssertEqual(QuickSwitch.score("ew", "New run"), 2)    // mid-word
    }

    func testNoMatchIsNil() {
        XCTAssertNil(QuickSwitch.score("xyz", "New run"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(QuickSwitch.score("RUN", "New run"), 1)
        XCTAssertEqual(QuickSwitch.score("nEw", "New run"), 0)
    }

    func testRankedIndicesFilterAndOrderByScoreThenPosition() {
        let titles = ["New run", "Runbook", "Deep run archive", "unrelated"]
        XCTAssertEqual(QuickSwitch.rankedIndices("run", titles), [1, 0, 2])
    }

    func testRankedIndicesEmptyQueryKeepsInputOrder() {
        XCTAssertEqual(QuickSwitch.rankedIndices("", ["a", "b", "c"]), [0, 1, 2])
    }

    func testRankedIndicesNoMatches() {
        XCTAssertEqual(QuickSwitch.rankedIndices("zzz", ["a", "b"]), [])
    }
}

/// ⌘K inside the run that is open: the same ranking, over the nodes on the canvas. A run of any size is
/// searchable by what a node is called, so a deep branch is reachable without hunting for it.
final class RunNodeSearchTests: XCTestCase {

    private func run() -> ResearchGraph {
        var graph = ResearchGraph.planning(question: "How should we price it?")
        graph.propose([ResearchAngle(id: "a1", title: "Competitor pricing", prompt: "look"),
                       ResearchAngle(id: "a2", title: "Willingness to pay", prompt: "ask")])
        graph.approvePlan()
        graph.insert(GraphNode(id: "s1", kind: .source, title: "Pricing page, 2025", state: .derived,
                               depth: 2))
        graph.connect(GraphEdge(from: "a1", to: "s1", kind: .cites))
        return graph
    }

    func testNodesAreFoundByWhatTheyAreCalled() {
        XCTAssertEqual(run().nodesMatching("willing").map(\.id), ["a2"])
    }

    func testTheStructureRanksAheadOfTheDetailHangingOffIt() {
        XCTAssertEqual(run().nodesMatching("prici").map(\.id), ["a1", "s1"])
    }

    func testAnEmptyQueryOffersTheWholeRunStructureFirst() {
        XCTAssertEqual(run().nodesMatching("").map(\.id), ["root", "a1", "a2", "s1"])
    }

    func testAQueryNothingIsCalledFindsNothing() {
        XCTAssertEqual(run().nodesMatching("kubernetes").map(\.id), [])
    }
}
